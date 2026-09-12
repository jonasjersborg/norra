import XCTest
@testable import Norra

/// The parts of the Volvo layer that decide what the menu bar says, tested
/// against the shapes Volvo's API actually sends. The client itself isn't
/// exercised here — that needs a live account — but everything between the
/// JSON and `CarData` is, because that is where a wrong guess shows up as a
/// confidently wrong number rather than an error.
final class VolvoFieldTests: XCTestCase {

    func testDecodesValueTimestampAndUnit() {
        let field = VolvoField([
            "value": 64.0,
            "timestamp": "2026-09-13T08:14:22.123Z",
            "unit": "percentage",
            "status": "OK"
        ])
        XCTAssertEqual(field?.doubleValue, 64)
        XCTAssertEqual(field?.unit, "percentage")
        XCTAssertNotNil(field?.timestamp)
    }

    /// Volvo sends fractional seconds on some fields and not on others.
    func testParsesBothTimestampFormats() {
        XCTAssertNotNil(VolvoField.parseDate("2026-09-13T08:14:22.123Z"))
        XCTAssertNotNil(VolvoField.parseDate("2026-09-13T08:14:22Z"))
        XCTAssertNil(VolvoField.parseDate("not a date"))
    }

    /// The important one: a non-OK status still carries a value, and reading
    /// it is how a charging car ends up displaying 0 kW.
    func testRejectsValueWhoseStatusIsNotOK() {
        let stale = VolvoField(["value": 0, "status": "ERROR"])
        XCTAssertFalse(stale!.isUsable)
        XCTAssertNil(stale?.intValue)

        let usable = VolvoField(["value": 11000, "status": "OK"])
        XCTAssertEqual(usable?.intValue, 11000)
    }

    /// Connected-vehicle endpoints omit `status` entirely; a value there is
    /// good as long as it exists.
    func testStatuslessFieldIsUsable() {
        let field = VolvoField(["value": 12480])
        XCTAssertTrue(field!.isUsable)
        XCTAssertEqual(field?.intValue, 12480)
    }

    func testCoercesNumbersAcrossTypes() {
        XCTAssertEqual(VolvoField(["value": 42])?.doubleValue, 42)
        XCTAssertEqual(VolvoField(["value": "42.5"])?.doubleValue, 42.5)
        XCTAssertEqual(VolvoField(["value": 41.6])?.intValue, 42)
        XCTAssertNil(VolvoField(["value": "eleven"])?.doubleValue)
    }

    func testRejectsNonObject() {
        XCTAssertNil(VolvoField("just a string"))
        XCTAssertNil(VolvoField(nil))
    }
}

final class VolvoStatusTests: XCTestCase {

    func testTranslatesChargingSystemStatus() {
        XCTAssertEqual(VolvoStatus.systemStatus("CHARGING_SYSTEM_CHARGING"), "CHARGING")
        XCTAssertEqual(VolvoStatus.systemStatus("CHARGING_SYSTEM_IDLE"), "IDLE")
        XCTAssertEqual(VolvoStatus.systemStatus("CHARGING_SYSTEM_DONE"), "DONE")
        XCTAssertEqual(VolvoStatus.systemStatus("CHARGING_SYSTEM_FAULT"), "FAULT")
        XCTAssertEqual(VolvoStatus.systemStatus("CHARGING_SYSTEM_SCHEDULED"), "SCHEDULED")
    }

    /// A status Volvo adds later must not be shown to the user raw.
    func testUnknownStatusBecomesUnspecified() {
        XCTAssertEqual(VolvoStatus.systemStatus("CHARGING_SYSTEM_TELEPORTING"), "UNSPECIFIED")
        XCTAssertEqual(VolvoStatus.systemStatus(nil), "UNSPECIFIED")
    }

    /// The translated keys have to be the ones `CarData.isCharging` reads,
    /// or a charging car never looks like it is charging.
    func testTranslatedStatusDrivesIsCharging() {
        let charging = Self.car(status: VolvoStatus.systemStatus("CHARGING_SYSTEM_CHARGING"))
        XCTAssertTrue(charging.isCharging)
        let idle = Self.car(status: VolvoStatus.systemStatus("CHARGING_SYSTEM_IDLE"))
        XCTAssertFalse(idle.isCharging)
    }

    func testPlugStatus() {
        XCTAssertEqual(VolvoStatus.isPluggedIn("CONNECTION_STATUS_CONNECTED_AC"), true)
        XCTAssertEqual(VolvoStatus.isPluggedIn("CONNECTION_STATUS_CONNECTED_DC"), true)
        XCTAssertEqual(VolvoStatus.isPluggedIn("CONNECTION_STATUS_DISCONNECTED"), false)
        // A faulted connector is physically in the car.
        XCTAssertEqual(VolvoStatus.isPluggedIn("CONNECTION_STATUS_FAULT"), true)
    }

    /// "Unknown" and "unplugged" are different, and the widget draws them
    /// differently — nil must not collapse into false.
    func testUnspecifiedPlugStatusIsUnknownNotUnplugged() {
        XCTAssertNil(VolvoStatus.isPluggedIn("CONNECTION_STATUS_UNSPECIFIED"))
        XCTAssertNil(VolvoStatus.isPluggedIn(nil))
    }

    func testCurrentKind() {
        XCTAssertEqual(VolvoStatus.currentKind("CONNECTION_STATUS_CONNECTED_AC"), "AC")
        XCTAssertEqual(VolvoStatus.currentKind("CONNECTION_STATUS_CONNECTED_DC"), "DC")
        XCTAssertNil(VolvoStatus.currentKind("CONNECTION_STATUS_DISCONNECTED"))
    }

    func testConnectorFault() {
        XCTAssertTrue(VolvoStatus.isConnectorFault("CONNECTION_STATUS_FAULT"))
        XCTAssertFalse(VolvoStatus.isConnectorFault("CONNECTION_STATUS_CONNECTED_AC"))
        XCTAssertFalse(VolvoStatus.isConnectorFault(nil))
    }

    private static func car(status: String) -> CarData {
        CarData(batteryPercentage: 64, rangeKm: 210, chargingStatus: status,
                estimatedChargingTimeToFullMinutes: nil, modelName: nil, modelYear: nil,
                registrationNo: nil, vin: nil, ownerFirstName: nil, odometerMeters: nil,
                daysToService: nil, distanceToServiceKm: nil, serviceWarning: false,
                fluidWarnings: [], imageData: nil, lastUpdated: Date(),
                carReportedAt: nil, odometerReportedAt: nil, grpcExtras: nil)
    }
}

/// The exact shapes a real Volvo EX30 returns, recorded from
/// `energy/v2/vehicles/{vin}/state` on 2026-09-13. Four of these names differ
/// from Volvo's published specification, which is how the menu bar spent its
/// first live session showing "UNSPECIFIED" beside a perfectly good battery
/// percentage. Pinned here so the next refactor can't quietly undo it.
final class LiveEnergyShapeTests: XCTestCase {

    private let live: [String: Any] = [
        "batteryChargeLevel": ["status": "OK", "value": 77.0, "unit": "percentage",
                               "updatedAt": "2026-09-12T21:53:55Z"],
        "electricRange": ["status": "OK", "value": 274.0, "unit": "km",
                          "updatedAt": "2026-09-12T21:53:55Z"],
        "chargerConnectionStatus": ["status": "OK", "value": "DISCONNECTED",
                                    "updatedAt": "2026-09-12T21:53:55Z"],
        "chargingStatus": ["status": "OK", "value": "IDLE",
                           "updatedAt": "2026-09-12T21:53:55Z"],
        "chargingType": ["status": "OK", "value": "NONE",
                         "updatedAt": "2026-09-12T21:53:55Z"],
        "estimatedChargingTimeToTargetBatteryChargeLevel":
            ["status": "OK", "value": 2, "unit": "minutes",
             "updatedAt": "2026-09-12T21:53:55Z"],
        // The EX30 serves neither of these.
        "chargingCurrentLimit": ["status": "ERROR", "code": "PROPERTY_NOT_SUPPORTED"],
        "chargingPower": ["status": "ERROR", "code": "PROPERTY_NOT_FOUND"]
    ]

    private func fields() -> [String: VolvoField] {
        live.compactMapValues { VolvoField($0) }
    }

    /// The bug: the app read `chargingSystemStatus`, the car sends
    /// `chargingStatus`, and a missing field became "UNSPECIFIED".
    func testChargingStatusIsReadUnderTheNameTheCarUses() {
        let status = fields()["chargingStatus"]?.stringValue
        XCTAssertEqual(status, "IDLE")
        XCTAssertEqual(VolvoStatus.systemStatus(status), "IDLE")
        XCTAssertNotEqual(VolvoStatus.systemStatus(status), "UNSPECIFIED")
    }

    func testConnectionIsReadUnderTheNameTheCarUses() {
        let connection = fields()["chargerConnectionStatus"]?.stringValue
        XCTAssertEqual(connection, "DISCONNECTED")
        XCTAssertEqual(VolvoStatus.isPluggedIn(connection), false)
    }

    /// Values arrive bare, without the CHARGING_SYSTEM_ / CONNECTION_STATUS_
    /// prefixes the specification shows.
    func testBareValuesTranslateAsWellAsPrefixedOnes() {
        XCTAssertEqual(VolvoStatus.systemStatus("CHARGING"), "CHARGING")
        XCTAssertEqual(VolvoStatus.systemStatus("CHARGING_SYSTEM_CHARGING"), "CHARGING")
        XCTAssertEqual(VolvoStatus.isPluggedIn("CONNECTED_AC"), true)
        XCTAssertEqual(VolvoStatus.isPluggedIn("CONNECTION_STATUS_CONNECTED_AC"), true)
    }

    /// `updatedAt`, not `timestamp` — a field whose time reads nil is how a
    /// day-old reading passes for a live one.
    func testTimestampIsReadFromUpdatedAt() {
        XCTAssertNotNil(fields()["batteryChargeLevel"]?.timestamp)
        // The documented spelling still works, for any car that uses it.
        XCTAssertNotNil(VolvoField(["value": 1, "timestamp": "2026-09-12T21:53:55Z"])?.timestamp)
    }

    func testEstimatedTimeIsReadUnderItsLongName() {
        XCTAssertEqual(fields()["estimatedChargingTimeToTargetBatteryChargeLevel"]?.intValue, 2)
    }

    /// A car that can't supply a field still sends it, with an ERROR status.
    /// Reading the value anyway is how a parked car reports 0 kW as fact.
    func testUnsupportedFieldsAreNotRead() {
        XCTAssertNil(fields()["chargingPower"]?.intValue)
        XCTAssertNil(fields()["chargingCurrentLimit"]?.intValue)
    }

    /// NONE means "not charging", not a kind of current.
    func testChargingTypeNoneIsNil() {
        XCTAssertNil(VolvoStatus.chargingType(fields()["chargingType"]?.stringValue))
        XCTAssertEqual(VolvoStatus.chargingType("AC"), "AC")
        XCTAssertEqual(VolvoStatus.chargingType("DC"), "DC")
    }

    func testTheWholeReadingLandsWhereTheMenuExpectsIt() {
        let f = fields()
        XCTAssertEqual(f["batteryChargeLevel"]?.doubleValue, 77)
        XCTAssertEqual(f["electricRange"]?.intValue, 274)
        XCTAssertEqual(VolvoStatus.systemStatus(f["chargingStatus"]?.stringValue), "IDLE")
    }
}

final class VolvoVehicleTests: XCTestCase {

    func testBuildsTitleFromDescriptions() {
        let vehicle = VolvoVehicle(data: [
            "descriptions": ["model": "EX30"],
            "modelYear": "2025",
            "fuelType": "ELECTRIC"
        ], vin: "YV4EK3")
        XCTAssertEqual(vehicle?.title, "Volvo EX30 · 2025")
        XCTAssertTrue(vehicle!.isElectric)
    }

    /// modelYear comes back as a number on some accounts and a string on
    /// others.
    func testNormalisesNumericModelYear() {
        let vehicle = VolvoVehicle(data: [
            "descriptions": ["model": "EX30"],
            "modelYear": 2025
        ], vin: "YV4EK3")
        XCTAssertEqual(vehicle?.modelYear, "2025")
        XCTAssertEqual(vehicle?.title, "Volvo EX30 · 2025")
    }

    /// A car that reports almost nothing still has to produce a usable title.
    func testTitleSurvivesMissingFields() {
        let vehicle = VolvoVehicle(data: [:], vin: "YV4EK3")
        XCTAssertEqual(vehicle?.title, "Volvo")
    }
}

final class CallbackListenerTests: XCTestCase {

    func testExtractsRequestTarget() {
        let request = "GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        XCTAssertEqual(CallbackListener.requestTarget(in: request),
                       "/callback?code=abc123&state=xyz")
    }

    func testIgnoresNonGET() {
        XCTAssertNil(CallbackListener.requestTarget(in: "POST /callback HTTP/1.1\r\n\r\n"))
        XCTAssertNil(CallbackListener.requestTarget(in: "garbage"))
    }

    /// The browser fetches /favicon.ico on the way to rendering the page;
    /// treating that as the callback would resolve sign-in with no code.
    func testFaviconIsNotTheCallback() {
        let target = CallbackListener.requestTarget(in: "GET /favicon.ico HTTP/1.1\r\n\r\n")
        XCTAssertEqual(target, "/favicon.ico")
        XCTAssertFalse(target!.hasPrefix("/callback"))
    }

    func testReadsCodeFromCallbackURL() {
        let url = URL(string: "http://127.0.0.1:9631/callback?code=abc123&state=xyz")!
        XCTAssertEqual(VolvoAPI.queryValue("code", from: url), "abc123")
        XCTAssertNil(VolvoAPI.queryValue("error", from: url))
    }

    func testReadsDeclinedConsent() {
        let url = URL(string: "http://127.0.0.1:9631/callback?error=access_denied")!
        XCTAssertEqual(VolvoAPI.queryValue("error", from: url), "access_denied")
        XCTAssertNil(VolvoAPI.queryValue("code", from: url))
    }
}
