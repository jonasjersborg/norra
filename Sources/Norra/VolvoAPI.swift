//
//  VolvoAPI.swift
//  Norra
//
//  Talks to Volvo's official developer APIs. Three of them, because the data
//  the menu bar shows is split across three:
//
//    energy/v2/vehicles/{vin}/state       battery, range, charging, power
//    connected-vehicle/v2/vehicles/{vin}  identity, odometer, diagnostics
//    volvoid.eu.volvocars.com             OAuth2 + OIDC
//
//  Unlike the Polestar client this was forked from, nothing here is
//  reverse-engineered: Volvo documents these. The documentation is not
//  exact, though — four Energy v2 field names differ from the published
//  specification, and the ones used below were read off a real EX30. Where
//  they differ, both spellings are accepted. No HTML scraping, at least, and
//  no login form to re-find when they redesign it.
//
//  What it costs instead is credentials. Volvo issues a client_id only after
//  a manual app review, and every request also carries a per-application
//  `vcc-api-key`. Both live in Secrets.swift, which is gitignored — see
//  README for how to get your own.
//

import Foundation
import CryptoKit
import NorraShared

final class VolvoAPI {

    // MARK: - Endpoints

    private let apiBaseURL = URL(string: "https://api.volvocars.com")!
    private let connectedPath = "/connected-vehicle/v2/vehicles"
    private let energyPath = "/energy/v2/vehicles"

    // Volvo ID is a standard OIDC provider and does serve a discovery
    // document at /.well-known/openid-configuration. These two endpoints are
    // named directly anyway: they are the only ones needed, they are
    // documented and stable, and fetching discovery first would spend a
    // request on every launch to learn what is written here. Both were
    // checked against the live document — if sign-in ever starts failing for
    // everyone at once, that is the first thing to re-read.
    private let authorizeURL = URL(string: "https://volvoid.eu.volvocars.com/as/authorization.oauth2")!
    private let tokenURL = URL(string: "https://volvoid.eu.volvocars.com/as/token.oauth2")!

    /// Everything the menu bar and widget need, and nothing else. Each scope
    /// is consented to by name in Volvo's browser prompt, so an app asking for
    /// door locks it never uses is asking the user to grant door locks it
    /// never uses.
    static let readScopes = [
        "openid",
        "energy:state:read",
        "energy:capability:read",
        "conve:vehicle_relation",
        "conve:odometer_status",
        // The service interval lives behind diagnostics_workshop, not
        // diagnostics_engine_status — that one is granted happily and the
        // endpoint still answers 403. Checked against a real token.
        "conve:diagnostics_workshop",
        "conve:brake_status",
        "conve:warnings",
        "conve:lock_status",
        "conve:tyre_status",
        "conve:trip_statistics",
        "conve:doors_status",
        "conve:windows_status",
        "conve:connectivity_status"
    ]

    /// Requested only when the user turns commands on in Settings. Kept apart
    /// from `readScopes` on purpose: a menu bar battery gauge should not hold
    /// the authority to unlock a car unless its owner deliberately said so.
    static let commandScopes = [
        "conve:lock",
        "conve:unlock",
        "conve:honk_flash",
        "conve:command_accessibility"
    ]

    // MARK: - Session

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    private var codeVerifier: String = ""

    /// Cars on the account, for the menu's car switcher.
    private(set) var cars: [CarSummary] = []
    private(set) var vehicle: VolvoVehicle?

    /// What this particular car actually serves, from the capabilities
    /// endpoint. The EX30 reports no target-charge-level; asking for it
    /// anyway earns a 404 every poll, forever.
    private(set) var capabilities: Set<String> = []

    /// The studio render, fetched once per car and kept. It is a static
    /// picture of a configuration that cannot change, so re-downloading it
    /// every five minutes would be pure waste.
    private var carImage: Data?

    private let session: URLSession
    private let credentials: VolvoCredentials

    init(credentials: VolvoCredentials = .current, session: URLSession? = nil) {
        self.credentials = credentials
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
    }

    /// Whether there is a live access token. False before sign-in and after
    /// a refresh that Volvo rejected.
    var isAuthenticated: Bool { accessToken != nil }

    /// Point the client at another car on the same account. Identity and
    /// capabilities are per-car, so both are refetched; the session is not
    /// touched, because one consent covers every car on the account.
    func selectCar(vin: String) async {
        vehicle = nil
        capabilities = []
        try? await loadVehicle(vin: vin)
    }

    private func debugLog(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "debug_logging") else { return }
        NSLog("[VolvoAPI] %@", message)
    }

    // MARK: - Authorization

    /// The URL to open in the user's browser to begin consent.
    ///
    /// PKCE is not optional here even though Volvo issues a client secret: a
    /// desktop app cannot keep a secret, and the verifier is what stops an
    /// intercepted redirect from being redeemed by anyone else.
    func authorizationURL(includeCommands: Bool) -> URL? {
        codeVerifier = Self.randomURLSafeString()
        var scopes = Self.readScopes
        if includeCommands { scopes += Self.commandScopes }

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientId),
            URLQueryItem(name: "redirect_uri", value: credentials.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: Self.randomURLSafeString()),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url
    }

    /// Complete the flow with the `code` the redirect came back with.
    /// Once the session exists the account is known, and the refresh token
    /// has to be filed under it. Saving during the token exchange — before
    /// onboarding commits the account — writes it under the unscoped name,
    /// and a second car signing in later would then overwrite the first.
    private func rescopeStoredToken() {
        guard let account = cars.first?.vin, !account.isEmpty,
              let token = refreshToken else { return }
        if Preferences.email.isEmpty { Preferences.email = account }
        try? Keychain.saveSessionToken(token)
    }

    func authenticate(callbackURL: URL, vin: String) async throws {
        guard let code = Self.queryValue("code", from: callbackURL) else {
            // Volvo reports a declined consent as ?error= rather than a
            // failure status, so surface its reason instead of a generic one.
            let reason = Self.queryValue("error_description", from: callbackURL)
                ?? Self.queryValue("error", from: callbackURL)
                ?? "no authorization code in callback"
            throw VolvoError.http(reason)
        }
        try await exchangeCodeForToken(code)
        try await loadVehicle(vin: vin)
        rescopeStoredToken()
    }

    /// Resume with the refresh token in the Keychain — no browser, no consent
    /// prompt. Throws when nothing is stored or Volvo rejects it; the caller
    /// falls back to a full authorization. A rejected token is deleted so it
    /// isn't retried on every launch.
    func restoreSession(vin: String) async throws {
        guard let stored = ((try? Keychain.readSessionToken()) ?? nil), !stored.isEmpty else {
            throw VolvoError.authenticationFailed
        }
        refreshToken = stored
        do {
            try await refreshAccessToken()
        } catch {
            try? Keychain.deleteSessionToken()
            refreshToken = nil
            throw VolvoError.sessionExpired
        }
        try await loadVehicle(vin: vin)
    }

    private func exchangeCodeForToken(_ code: String) async throws {
        let fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": credentials.redirectURI,
            "code_verifier": codeVerifier
        ]
        try await requestToken(fields: fields)
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken else { throw VolvoError.sessionExpired }
        try await requestToken(fields: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
    }

    /// Both grants post to the same endpoint and parse the same response.
    ///
    /// Volvo authenticates the client with HTTP Basic rather than body
    /// parameters — client_id/client_secret in the Authorization header.
    private func requestToken(fields: [String: String]) async throws {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credentials.vccApiKey, forHTTPHeaderField: "vcc-api-key")

        let basic = "\(credentials.clientId):\(credentials.clientSecret)"
        if let encoded = basic.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = fields
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VolvoError.http("Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            debugLog("token: status \(http.statusCode)")
            // A stale refresh token comes back as 400, not 401 — treating it
            // as a generic HTTP failure would leave the user staring at an
            // error instead of being signed back in.
            if http.statusCode == 400 || http.statusCode == 401 {
                throw VolvoError.sessionExpired
            }
            throw VolvoError.http("Token request failed (\(http.statusCode))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw VolvoError.parse("No access token in response")
        }

        accessToken = token
        if let refreshed = json["refresh_token"] as? String {
            refreshToken = refreshed
            try? Keychain.saveSessionToken(refreshed)
        }
        // Refresh a minute early: a token that expires mid-request is a
        // failed poll, and the clock is not guaranteed to agree with Volvo's.
        let lifetime = (json["expires_in"] as? Double) ?? 1800
        tokenExpiry = Date().addingTimeInterval(lifetime - 60)
        debugLog("token: ok, expires in \(Int(lifetime))s")
    }

    private func validToken() async throws -> String {
        if let expiry = tokenExpiry, Date() < expiry, let accessToken {
            return accessToken
        }
        try await refreshAccessToken()
        guard let accessToken else { throw VolvoError.sessionExpired }
        return accessToken
    }

    // MARK: - Requests

    /// GET one resource and hand back its decoded `data` envelope.
    private func get(_ path: String) async throws -> [String: Any] {
        let token = try await validToken()
        var request = URLRequest(url: apiBaseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.vccApiKey, forHTTPHeaderField: "vcc-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VolvoError.http("Invalid response")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw VolvoError.sessionExpired
        case 404:
            // Volvo answers 404 for a resource this model doesn't have, which
            // is a fact about the car and not a failure.
            throw VolvoError.unsupported(path)
        case 429:
            throw VolvoError.rateLimited
        default:
            debugLog("GET \(path): status \(http.statusCode)")
            throw VolvoError.http("Request failed (\(http.statusCode))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VolvoError.parse("Malformed JSON from \(path)")
        }
        return json
    }

    /// Most endpoints wrap their fields in `data`; Energy v2 `state` returns
    /// them at the top level.
    private func getFields(_ path: String, unwrapping key: String? = "data") async throws -> VolvoFields {
        let json = try await get(path)
        let container = key.flatMap { json[$0] as? [String: Any] } ?? json
        return container.compactMapValues { VolvoField($0) }
    }

    // MARK: - Vehicle identity

    /// Fetch the car list, the chosen car's description, and what it supports.
    /// Runs once per session — none of it changes while the app is open.
    private func loadVehicle(vin: String) async throws {
        await loadCarList()

        do {
            let json = try await get("\(connectedPath)/\(vin)")
            if let data = json["data"] as? [String: Any] {
                vehicle = VolvoVehicle(data: data, vin: vin)
            }
        } catch {
            // Identity is decoration: the menu can say "Volvo" and still show
            // a battery percentage. Not worth failing a sign-in over.
            debugLog("vehicle details unavailable: \(error)")
        }

        await loadCapabilities(vin: vin)
        await loadCarImage()
    }

    /// Volvo serves the render from its own image host, unauthenticated, so
    /// this is a plain GET. Failure is silent: a menu without a picture of
    /// the car is still a working menu.
    private func loadCarImage() async {
        carImage = nil
        guard let url = vehicle?.exteriorImageURL else { return }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode), !data.isEmpty else { return }
            carImage = data
            debugLog("car image: \(data.count) bytes")
        } catch {
            debugLog("car image unavailable: \(error)")
        }
    }

    private func loadCarList() async {
        guard let json = try? await get(connectedPath),
              let list = json["data"] as? [[String: Any]] else { return }

        cars = list.compactMap { entry in
            guard let vin = entry["vin"] as? String else { return nil }
            return CarSummary(vin: vin, title: vin)
        }
        debugLog("account has \(cars.count) car(s)")
    }

    /// Ask the car what it serves rather than assuming. The EX30 has no
    /// target-charge-level and no charging-current-limit; other models do.
    private func loadCapabilities(vin: String) async {
        guard let json = try? await get("\(energyPath)/\(vin)/capabilities") else { return }
        let container = (json["getEnergyState"] as? [String: Any])
            ?? (json["data"] as? [String: Any])
            ?? json

        capabilities = Set(container.compactMap { key, value in
            guard let entry = value as? [String: Any] else { return nil }
            let supported = (entry["isSupported"] as? Bool)
                ?? ((entry["status"] as? String)?.uppercased() == "OK")
            return supported ? key : nil
        })
        debugLog("capabilities: \(capabilities.sorted().joined(separator: ", "))")
    }

    // MARK: - The poll

    /// One reading, assembled from the endpoints the car actually serves.
    ///
    /// Energy state is the only required call — without it there is no
    /// battery percentage and nothing to show. Odometer, diagnostics and
    /// warnings are each allowed to fail on their own without taking the
    /// reading down with them, because a car that reports a battery level but
    /// no service interval is still worth a menu bar.
    func fetchCarData(vin: String) async throws -> CarData {
        let energy = try await getFields("\(energyPath)/\(vin)/state", unwrapping: nil)

        async let odometerFields = try? getFields("\(connectedPath)/\(vin)/odometer")
        async let diagnosticFields = try? getFields("\(connectedPath)/\(vin)/diagnostics")
        async let warningFields = try? getFields("\(connectedPath)/\(vin)/warnings")
        async let engineFields = try? getFields("\(connectedPath)/\(vin)/engine")
        async let brakeFields = try? getFields("\(connectedPath)/\(vin)/brakes")
        async let tyreFields = try? getFields("\(connectedPath)/\(vin)/tyres")
        async let doorFields = try? getFields("\(connectedPath)/\(vin)/doors")
        async let statsFields = try? getFields("\(connectedPath)/\(vin)/statistics")

        let odometer = await odometerFields ?? [:]
        let diagnostics = await diagnosticFields ?? [:]
        // washerFluidLevelWarning arrives with the service interval rather
        // than with the other warnings, whatever the grouping suggests.
        // Fluids and bulbs are spread across three endpoints rather than one,
        // and each is allowed to 403 on its own when a scope is missing.
        let warnings = (await warningFields ?? [:])
            .merging(await engineFields ?? [:]) { a, _ in a }
            .merging(await brakeFields ?? [:]) { a, _ in a }
            .merging(diagnostics.filter { $0.key.hasSuffix("LevelWarning") }) { a, _ in a }
        let tyres = await tyreFields ?? [:]
        let doors = await doorFields ?? [:]
        let stats = await statsFields ?? [:]

        // These names are what the API actually sends, which is not what the
        // published specification documents — it calls them
        // chargingConnectionStatus and chargingSystemStatus. Checked against a
        // real EX30; the documented spellings are read as a fallback so a car
        // or a future version that uses them still works.
        let connection = energy["chargerConnectionStatus"]?.stringValue
            ?? energy["chargingConnectionStatus"]?.stringValue
        let systemStatus = energy["chargingStatus"]?.stringValue
            ?? energy["chargingSystemStatus"]?.stringValue

        // Volvo reports charging power in watts on some models and kilowatts
        // on others, and says which in the field's own `unit`. Normalising to
        // watts here keeps the guess out of the UI.
        let power = energy["chargingPower"]
        let powerWatts: Int? = power?.doubleValue.map { value in
            let unit = (power?.unit ?? "W").uppercased()
            return unit.hasPrefix("KW") ? Int(value * 1000) : Int(value)
        }

        // The charging detail Polestar could only get from a separate gRPC
        // service arrives here in the same Energy v2 response. It is still
        // carried in `GrpcBatteryExtras` because every consumer — menu rows,
        // widget, notifications — already reads it from there, and a car that
        // reports its charging power in one call rather than two is not a
        // reason to rewrite all of them.
        let extras = GrpcBatteryExtras(
            chargerConnectionStatus: Self.connectionKey(connection),
            chargingPowerWatts: powerWatts,
            chargingCurrentAmps: energy["chargingCurrent"]?.intValue,
            chargingVoltageVolts: energy["chargingVoltage"]?.intValue,
            // The car names the current directly ("AC"/"DC"/"NONE"), which
            // beats inferring it from the connector — a DC charger reports
            // CONNECTED_DC only while it is actually delivering.
            chargingType: energy["chargingType"]?.stringValue.flatMap(VolvoStatus.chargingType)
                ?? VolvoStatus.currentKind(connection)
        )

        return CarData(
            batteryPercentage: energy["batteryChargeLevel"]?.doubleValue ?? 0,
            rangeKm: energy["electricRange"]?.intValue
                ?? energy["distanceToEmptyBattery"]?.intValue ?? 0,
            chargingStatus: VolvoStatus.systemStatus(systemStatus),
            estimatedChargingTimeToFullMinutes:
                energy["estimatedChargingTimeToTargetBatteryChargeLevel"]?.intValue
                ?? energy["estimatedChargingTime"]?.intValue,
            modelName: vehicle?.modelName,
            modelYear: vehicle?.modelYear,
            registrationNo: nil,
            vin: vin,
            ownerFirstName: nil,
            batteryCapacityKWh: vehicle?.batteryCapacityKWh,
            targetChargePercentage: energy["targetBatteryChargeLevel"]?.doubleValue,
            paintName: vehicle?.externalColour,
            isLocked: Self.lockState(doors),
            tyrePressures: Self.tyrePressures(tyres),
            // kWh/100km. The single most useful number an EV reports that a
            // battery percentage cannot tell you.
            averageConsumption: stats["averageEnergyConsumptionAutomatic"]?.doubleValue,
            // The connected-vehicle odometer is in kilometres, while CarData
            // holds metres — the drive detection compares two readings and
            // whole kilometres would hide a car crossing town.
            odometerMeters: odometer["odometer"]?.doubleValue.map { Int($0 * 1000) },
            daysToService: diagnostics["timeToService"]?.intValue,
            serviceIntervalUnit: diagnostics["timeToService"]?.unit,
            distanceToServiceKm: diagnostics["distanceToService"]?.intValue,
            serviceWarning: Self.serviceWarning(from: diagnostics),
            fluidWarnings: Self.fluidWarnings(from: warnings),
            imageData: carImage,
            lastUpdated: Date(),
            carReportedAt: energy["batteryChargeLevel"]?.timestamp,
            odometerReportedAt: odometer["odometer"]?.timestamp,
            grpcExtras: extras
        )
    }

    /// `CarData.isPluggedIn` reads the Polestar vocabulary — CONNECTED /
    /// DISCONNECTED / FAULT — so Volvo's longer names are translated into it
    /// rather than teaching that property a second dialect.
    private static func connectionKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if VolvoStatus.isConnectorFault(raw) { return "FAULT" }
        switch VolvoStatus.isPluggedIn(raw) {
        case true: return "CONNECTED"
        case false: return "DISCONNECTED"
        default: return nil
        }
    }

    /// Whether the car is locked. Volvo reports a central lock state plus a
    /// state per door; the central one is what a menu row should say, and
    /// nil means the scope wasn't granted rather than "unknown state".
    private static func lockState(_ doors: VolvoFields) -> Bool? {
        guard let value = (doors["centralLock"] ?? doors["carLocked"])?.stringValue else { return nil }
        switch value.uppercased() {
        case "LOCKED": return true
        case "UNLOCKED": return false
        default: return nil
        }
    }

    /// Tyre pressure per wheel, keyed the way Volvo names them. Only the
    /// ones that aren't NORMAL are interesting — four rows saying "fine" is
    /// four rows of noise.
    private static func tyrePressures(_ tyres: VolvoFields) -> [String: String] {
        let wheels = [
            "frontLeft": "Front left", "frontRight": "Front right",
            "rearLeft": "Rear left", "rearRight": "Rear right"
        ]
        var out: [String: String] = [:]
        for (key, label) in wheels {
            guard let status = tyres[key]?.stringValue?.uppercased() else { continue }
            guard !Self.isFine(status) else { continue }
            out[label] = status
        }
        return out
    }

    /// The several ways Volvo says "nothing wrong here". NO_WARNING is what
    /// an EX30 actually sends; the others appear on different models and
    /// different endpoints. Missing one means showing a warning row that
    /// says NO_WARNING, which is exactly how this was found.
    static func isFineForTesting(_ status: String) -> Bool { isFine(status) }

    private static func isFine(_ status: String) -> Bool {
        ["NO_WARNING", "NORMAL", "UNSPECIFIED", "OK", "NONE", "CLOSED", "LOCKED"]
            .contains(status.uppercased())
    }

    /// Volvo reports each fluid as its own field with a status string. Only
    /// the ones that aren't "NORMAL" are worth the menu's attention.
    private static func fluidWarnings(from warnings: VolvoFields) -> [String] {
        let interesting = [
            "brakeFluidLevelWarning": "Brake fluid",
            "engineCoolantLevelWarning": "Coolant",
            "oilLevelWarning": "Oil",
            "washerFluidLevelWarning": "Washer fluid"
        ]
        return interesting.compactMap { key, label in
            guard let value = warnings[key]?.stringValue?.uppercased() else { return nil }
            guard !Self.isFine(value) else { return nil }
            return label
        }.sorted()
    }

    private static func serviceWarning(from diagnostics: VolvoFields) -> Bool {
        guard let status = diagnostics["serviceWarning"]?.stringValue?.uppercased() else { return false }
        return !isFine(status)
    }

    // MARK: - Commands

    /// Lock, unlock, honk, flash. Each needs its own scope, granted only if
    /// the user opted into commands at sign-in; without it Volvo answers 403
    /// and the menu says the session needs re-authorizing.
    @discardableResult
    func executeCommand(_ command: String, vin: String) async throws -> String {
        let token = try await validToken()
        let url = apiBaseURL.appendingPathComponent("\(connectedPath)/\(vin)/commands/\(command)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.vccApiKey, forHTTPHeaderField: "vcc-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VolvoError.http("Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw VolvoError.sessionExpired
            }
            if http.statusCode == 429 { throw VolvoError.rateLimited }
            throw VolvoError.http("\(command) failed (\(http.statusCode))")
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = (json?["data"] as? [String: Any])?["invokeStatus"] as? String
        debugLog("command \(command): \(result ?? "ok")")
        return result ?? "COMPLETED"
    }

    // MARK: - Helpers

    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    static func queryValue(_ name: String, from url: URL?) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first { $0.name == name }?.value
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// `base64URLEncoded` is file-private over in the Polestar client; PKCE needs
/// it here too and duplicating four lines beats widening that file's surface.
private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
