import XCTest
@testable import Norra

/// Points Preferences and Accounts at a scratch UserDefaults domain for the
/// whole test run.
///
/// Without this the suite reads and writes the app's real settings: running
/// `swift test` on a Mac with Norra signed in wiped the account and VIN, and
/// every fresh xctest binary asking for the keychain item raised a password
/// prompt. Tests should not be able to sign you out.
final class TestDefaults: NSObject, XCTestObservation {

    private static let domain = "com.weareheavy.norra.tests"

    /// Runs once, before any test, via the principal-class hook below.
    override init() {
        super.init()
        let scratch = UserDefaults(suiteName: Self.domain)!
        scratch.removePersistentDomain(forName: Self.domain)
        Preferences.d = scratch
        Accounts.d = scratch
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        UserDefaults.standard.removePersistentDomain(forName: Self.domain)
    }
}
