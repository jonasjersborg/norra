//
//  CarData.swift
//  Norra
//
//  One reading of the car, and the small amount of reasoning that belongs to
//  a reading rather than to whoever displays it.
//
//  This lived inside the Polestar client. It moved out when that client was
//  replaced: the menu bar, the widget, the notifier and the low-battery
//  tracker all speak in terms of a CarData, and none of them should have to
//  import a particular carmaker's API to say so.
//

import Foundation
import NorraShared

struct CarData {
    let batteryPercentage: Double
    let rangeKm: Int
    let chargingStatus: String
    let estimatedChargingTimeToFullMinutes: Int?
    let modelName: String?
    let modelYear: String?
    let registrationNo: String?
    let vin: String?
    let ownerFirstName: String?
    /// Usable pack size in kWh, from the car's own description. Turns a
    /// percentage into an amount of energy, which is the number that
    /// actually tells you how far you can go.
    let batteryCapacityKWh: Double?
    /// What the car is charging toward, which is not always 100 — an EV left
    /// on an 80% limit is charging correctly, and a menu that only said
    /// "Charging" would leave you wondering why it stopped.
    let targetChargePercentage: Double?
    /// "Powder Blue". Shown under the title, where it reads as the name of
    /// the car rather than a spec.
    let paintName: String?
    /// Central lock state. Nil when the scope wasn't granted — which is a
    /// different thing from a car that didn't answer, and both are different
    /// from "unlocked". A row that guessed here would be the worst kind of
    /// wrong.
    let isLocked: Bool?
    /// Wheels whose pressure the car is unhappy about, label to status.
    /// Empty when all four are fine, which is the normal case.
    let tyrePressures: [String: String]
    /// kWh per 100 km, as the car computes it. Nil without the trip
    /// statistics scope.
    let averageConsumption: Double?
    /// Metres, as the car reports them. Kept at full resolution because the
    /// movement test below lives or dies on it: rounded to whole kilometres,
    /// a car crossing town at 25 km/h looks stationary for minutes at a time.
    let odometerMeters: Int?
    let daysToService: Int?
    /// The unit `daysToService` is actually in. Volvo reports the service
    /// interval in months on an EX30 and the field name is a leftover from
    /// the Polestar client, which assumed days — so 9 months rendered as
    /// "in 9 days", in warning orange, on a car with most of a year to go.
    let serviceIntervalUnit: String?
    let distanceToServiceKm: Int?
    let serviceWarning: Bool
    let fluidWarnings: [String]
    let imageData: Data?
    let lastUpdated: Date
    /// When the car itself last reported battery data (API event timestamp).
    /// `lastUpdated` is merely when we fetched; a garaged car can be hours older.
    let carReportedAt: Date?
    /// When the car last reported its odometer. The only live sign of use we
    /// get: a driving car pushes odometer updates, a parked one goes quiet.
    let odometerReportedAt: Date?
    /// Extra fields from the gRPC battery service; nil when it's unreachable.
    let grpcExtras: GrpcBatteryExtras?

    /// Status with the CHARGING_STATUS_ / CHARGING_STATUS_V2_ prefix stripped,
    /// e.g. "CHARGING", "IDLE", "DONE".
    var statusKey: String {
        chargingStatus
            .replacingOccurrences(of: "CHARGING_STATUS_V2_", with: "")
            .replacingOccurrences(of: "CHARGING_STATUS_", with: "")
    }

    var isCharging: Bool {
        statusKey == "CHARGING" || statusKey == "SMART_CHARGING"
    }

    /// Energy in the pack right now. Nil when the car didn't say how big
    /// its battery is — better no row than a number derived from a guess.
    var batteryKWh: Double? {
        batteryCapacityKWh.map { $0 * batteryPercentage / 100 }
    }

    /// What the menu and the widget show. Whole kilometres, the way the car's
    /// own dashboard reads.
    var odometerKm: Int? { odometerMeters.map { $0 / 1000 } }

    /// Resolved in `driving(comparedTo:)` when a reading is applied, because
    /// movement can only be seen by comparing two readings.
    var isDriving = false

    /// How old the car's own odometer report may be before the car counts as
    /// parked, whatever the numbers say.
    private static let freshReport: TimeInterval = 600
    /// How far apart two odometer reports may be for the distance between them
    /// to still describe *now* rather than some drive in between.
    private static let comparableReports: TimeInterval = 300
    /// Without a second reading to compare against, only a report this new is
    /// worth guessing "in use" from.
    private static let justReported: TimeInterval = 180

    /// The charging status stays IDLE while driving (confirmed on a PS4 2026),
    /// so "in use" has to be inferred, and two things have to hold: the car
    /// reported its odometer moments ago, and that odometer is higher than the
    /// one in the reading before it.
    ///
    /// Both halves earn their place. A parked car keeps re-reporting the same
    /// odometer with a fresh timestamp, so freshness alone left the car stuck
    /// "in use" forever — the number itself has to move. And a number that has
    /// moved only says the car drove *somewhere between the two readings*,
    /// which is precisely what a Mac that slept through the drive sees when it
    /// wakes up beside a car that has been parked for ten minutes. So the two
    /// reports also have to be close enough together to be talking about now.
    func driving(comparedTo previous: CarData?) -> Bool {
        guard !isCharging, isPluggedIn != true, let reportedAt = odometerReportedAt,
              Date().timeIntervalSince(reportedAt) < Self.freshReport else { return false }

        guard let previousReportedAt = previous?.odometerReportedAt,
              reportedAt.timeIntervalSince(previousReportedAt) < Self.comparableReports,
              let now = odometerMeters, let before = previous?.odometerMeters
        else {
            // Nothing comparable to hand: the first poll after launch, a car
            // switch, or a wake from sleep. A report this new is the best
            // guess available, and the next poll a minute later settles it.
            return Date().timeIntervalSince(reportedAt) < Self.justReported
        }
        // Greater, not merely different: an odometer that fell belongs to
        // another car, not to a drive.
        return now > before
    }

    /// Developer aid: `defaults write com.weareheavy.norra debug_drive -bool
    /// YES` logs the numbers behind every verdict. Whether a parked car keeps
    /// pushing odometer reports, and for how long, is the one thing the API
    /// documents nowhere — the windows above can only be tuned by watching a
    /// real car park.
    func logDriveSignal(comparedTo previous: CarData?) {
        guard UserDefaults.standard.bool(forKey: "debug_drive") else { return }
        func age(_ date: Date?) -> String {
            guard let date else { return "-" }
            return String(format: "%.0fs", Date().timeIntervalSince(date))
        }
        var delta = "-"
        if let now = odometerMeters, let before = previous?.odometerMeters {
            delta = "\(now - before)m"
        }
        let parts = [
            "drive:", isDriving ? "in-use" : "parked",
            "odo=" + (odometerMeters.map { "\($0)" } ?? "-"),
            "delta=" + delta,
            "report=" + age(odometerReportedAt),
            "prev=" + age(previous?.odometerReportedAt),
            "status=" + statusKey,
            "plug=" + (isPluggedIn.map { $0 ? "yes" : "no" } ?? "-")
        ]
        NSLog("[Norra] " + parts.joined(separator: " "))
    }

    var isPluggedIn: Bool? {
        switch grpcExtras?.chargerConnectionStatus {
        case "CONNECTED", "FAULT": return true
        case "DISCONNECTED": return false
        default: return nil
        }
    }
}

/// One car on the account, for the menu's car switcher.
struct CarSummary: Equatable {
    let vin: String
    let title: String   // e.g. "Volvo EX30 · 2025"
}
