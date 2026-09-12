//
//  VolvoModels.swift
//  Norra
//
//  The shapes Volvo's APIs actually return, and the errors they raise.
//
//  Every Volvo endpoint wraps its payload the same way: a `data` object whose
//  each member is a *field* — a value with the timestamp at which the car
//  reported it, and sometimes a unit and a per-field status. That wrapper is
//  the reason this file exists rather than a pile of ad-hoc dictionaries: the
//  timestamp is not decoration. A garaged car keeps answering with values it
//  reported hours ago, and the menu says so instead of implying the reading
//  is live.
//

import Foundation
import NorraShared

// MARK: - Errors

enum VolvoError: Error, LocalizedError {
    case http(String)
    case parse(String)
    case authenticationFailed
    /// Volvo rejected the refresh token: the session is gone and only a new
    /// browser consent can bring it back. Distinct from
    /// `authenticationFailed` because nothing is wrong with the credentials.
    case sessionExpired
    case notConfigured
    /// The car is on the account but doesn't serve this resource. The EX30,
    /// for one, has no target-charge-level or charging-current-limit. Not an
    /// error worth showing — the caller leaves the field empty.
    case unsupported(String)
    /// Volvo caps a published app at 10,000 calls/day and 100/minute per
    /// user. Worth its own case so the UI can say "slow down" rather than
    /// "something went wrong".
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .http(let m): return String(format: L("HTTP error: %@"), m)
        case .parse(let m): return String(format: L("Parse error: %@"), m)
        case .authenticationFailed: return L("Authentication failed — sign in again")
        case .sessionExpired: return L("Session expired — signing in again")
        case .notConfigured: return L("Not configured — open Settings")
        case .unsupported(let f): return String(format: L("Not supported by this car: %@"), f)
        case .rateLimited: return L("Too many requests — Volvo is rate limiting")
        }
    }
}

// MARK: - The field wrapper

/// One reading: the value, when the *car* reported it, and how the API rates
/// it. `status` is absent on the older v1/connected-vehicle endpoints and
/// present on Energy v2, where it flags a field the car couldn't supply.
struct VolvoField {
    let value: Any?
    let timestamp: Date?
    let unit: String?
    let status: String?

    /// Energy v2 marks a field it couldn't read with a status other than OK,
    /// and still sends a `value` — usually a stale one. Reading that as
    /// current is how a charging car ends up showing 0 kW.
    var isUsable: Bool {
        guard let status else { return value != nil }
        return value != nil && status.uppercased() == "OK"
    }

    var doubleValue: Double? {
        guard isUsable else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    var intValue: Int? { doubleValue.map { Int($0.rounded()) } }

    var stringValue: String? {
        guard isUsable else { return nil }
        if let s = value as? String { return s }
        if let d = value as? Double { return String(d) }
        if let i = value as? Int { return String(i) }
        return nil
    }

    init(value: Any?, timestamp: Date?, unit: String?, status: String?) {
        self.value = value
        self.timestamp = timestamp
        self.unit = unit
        self.status = status
    }

    /// Decodes one `{ value, timestamp, unit, status }` object. Volvo sends
    /// ISO-8601 with fractional seconds on some fields and without on others,
    /// so both are tried rather than assuming.
    init?(_ raw: Any?) {
        guard let dict = raw as? [String: Any] else { return nil }
        self.value = dict["value"]
        self.unit = dict["unit"] as? String
        self.status = dict["status"] as? String
        self.timestamp = (dict["timestamp"] as? String).flatMap(VolvoField.parseDate)
    }

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }
}

/// A `data` envelope decoded into fields, keyed the way Volvo names them.
typealias VolvoFields = [String: VolvoField]

// MARK: - Vehicle identity

/// Static description of the car, from `connected-vehicle/v2/vehicles/{vin}`.
/// Fetched once per session — none of it changes while the app runs.
struct VolvoVehicle {
    let vin: String
    let modelName: String?
    let modelYear: String?
    let batteryCapacityKWh: Double?
    /// "fuelType" — BEV, PLUGIN_HYBRID, etc. An EX30 is BEV; the distinction
    /// decides whether range comes from the battery or the tank.
    let fuelType: String?
    let externalColour: String?

    /// "Volvo EX30 · 2025", or as much of it as the car reported.
    var title: String {
        let name = ["Volvo", modelName].compactMap { $0 }.joined(separator: " ")
        guard let modelYear else { return name }
        return "\(name) · \(modelYear)"
    }

    var isElectric: Bool {
        guard let fuelType else { return true }
        let t = fuelType.uppercased()
        return t.contains("ELECTRIC") || t == "BEV" || t.contains("PETROL/ELECTRIC")
    }

    init?(data: [String: Any], vin: String) {
        self.vin = vin
        let descriptions = data["descriptions"] as? [String: Any]
        self.modelName = descriptions?["model"] as? String
        self.externalColour = descriptions?["exteriorColour"] as? String ?? descriptions?["exterior"] as? String

        // modelYear arrives as a number on some accounts and a string on
        // others; normalise rather than picking one and being wrong later.
        if let y = data["modelYear"] as? String {
            self.modelYear = y
        } else if let y = data["modelYear"] as? Int {
            self.modelYear = String(y)
        } else {
            self.modelYear = nil
        }

        if let kwh = data["batteryCapacityKWH"] as? Double {
            self.batteryCapacityKWh = kwh
        } else if let kwh = data["batteryCapacityKWH"] as? Int {
            self.batteryCapacityKWh = Double(kwh)
        } else {
            self.batteryCapacityKWh = nil
        }

        self.fuelType = data["fuelType"] as? String
    }
}

// MARK: - Status vocabulary

/// Volvo's charging vocabulary, mapped onto the words the rest of the app
/// already speaks.
///
/// The app was written against Polestar, whose statuses are CHARGING / IDLE /
/// DONE / FAULT / SCHEDULED. Volvo says the same things with longer names
/// (`CHARGING_SYSTEM_CHARGING`), so the translation happens here, once, and
/// every menu string, widget layout and notification downstream keeps working
/// untouched. The alternative — teaching the whole app a second vocabulary —
/// would have meant editing every one of them.
enum VolvoStatus {

    /// `chargingSystemStatus` → the app's status key.
    static func systemStatus(_ raw: String?) -> String {
        guard let raw else { return "UNSPECIFIED" }
        let key = raw.uppercased()
            .replacingOccurrences(of: "CHARGING_SYSTEM_", with: "")
        switch key {
        case "CHARGING": return "CHARGING"
        case "DONE": return "DONE"
        case "IDLE": return "IDLE"
        case "SCHEDULED": return "SCHEDULED"
        case "FAULT": return "FAULT"
        default: return "UNSPECIFIED"
        }
    }

    /// `chargingConnectionStatus` → plugged in or not.
    ///
    /// Returns nil for UNSPECIFIED rather than false: "we don't know" and
    /// "the cable is out" are different, and the widget shows a plug icon for
    /// one and not the other.
    static func isPluggedIn(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        let key = raw.uppercased()
            .replacingOccurrences(of: "CONNECTION_STATUS_", with: "")
        switch key {
        case "CONNECTED_AC", "CONNECTED_DC": return true
        case "DISCONNECTED": return false
        // A faulted connector is physically in the car — reporting "not
        // plugged in" would be wrong, and the fault shows via the system
        // status anyway.
        case "FAULT": return true
        default: return nil
        }
    }

    /// Whether the connected charger is AC or DC, which the menu shows beside
    /// the power. Nil when disconnected or unspecified.
    static func currentKind(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let key = raw.uppercased().replacingOccurrences(of: "CONNECTION_STATUS_", with: "")
        if key == "CONNECTED_AC" { return "AC" }
        if key == "CONNECTED_DC" { return "DC" }
        return nil
    }

    /// True when the connector itself reports a fault, which is worth a
    /// notification — a car left plugged in overnight that never charged is
    /// exactly the thing you want to be told about.
    static func isConnectorFault(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.uppercased().contains("FAULT")
    }
}
