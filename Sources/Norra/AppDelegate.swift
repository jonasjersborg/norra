//
//  AppDelegate.swift
//  Norra (AppKit rewrite)
//

import AppKit
import ServiceManagement
import NorraShared

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusController: StatusItemController!
    private var settingsController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?

    private let api = VolvoAPI()
    private var signIn: CallbackListener?
    private let notifier = Notifier()
    private var refreshTimer: Timer?
    private var latest: CarData?
    private var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        Preferences.migrateLegacyPassword()
        Accounts.migrateSingleAccount()

        statusController = StatusItemController(
            onRefresh: { [weak self] in self?.refreshNow() },
            onSettings: { [weak self] in self?.showSettings() }
        )
        statusController.onSelectCar = { [weak self] vin in self?.switchCar(to: vin) }
        if Preferences.commandsEnabled {
            statusController.onCommand = { [weak self] command in self?.runCommand(command) }
        }
        statusController.render(data: nil, error: nil, authenticated: false)
        notifier.requestAuthorizationIfNeeded()

        if hasCredentials {
            startSession()
        } else {
            // First run: ask for the account, not for a VIN. Settings is
            // still where an existing setup is changed — it is just no
            // longer the first thing anyone meets.
            showOnboarding()
        }
    }

    /// norra://open — sent by a click on the desktop widget.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "norra" }) else { return }
        statusController.popMenu()
    }

    /// Menu-bar-only apps have no visible main menu, but key equivalents
    /// (⌘C/⌘V/⌘X/⌘A/⌘Z) are routed through NSApp.mainMenu — without an
    /// Edit menu, paste doesn't work in our settings window.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit Norra"),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// Enough to attempt a session: an application key, a car, and a stored
    /// refresh token. There is no password — Volvo signs in through the
    /// browser, and what persists afterwards is the refresh token alone.
    private var hasCredentials: Bool {
        guard VolvoCredentials.current.isConfigured, !Preferences.vin.isEmpty else { return false }
        return ((try? Keychain.readSessionToken()) ?? nil)?.isEmpty == false
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard VolvoCredentials.current.isConfigured, !Preferences.vin.isEmpty else {
            statusController.render(data: nil, error: L("Not configured"), authenticated: false)
            showSettings()
            return
        }
        let vin = Preferences.vin

        statusController.showLoading()
        Task {
            do {
                // The only way back in without a browser. When Volvo has
                // retired the refresh token this throws, and the user has to
                // consent again — there is no password to replay.
                try await api.restoreSession(vin: vin)
                let data = try await api.fetchCarData(vin: vin)
                await MainActor.run { self.apply(data) }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.statusController.render(data: self.latest, error: error.localizedDescription, authenticated: false)
                    self.settingsController?.updateStatus(data: self.latest,
                                                          error: error.localizedDescription,
                                                          authenticated: false)
                    // A dead session is "not signed in", not a transient
                    // error: open Settings so the fix is in reach instead
                    // of only an error row in the menu.
                    if Self.isSignedOut(error) { self.showSettings() }
                }
            }
        }
    }

    /// Open Volvo's consent page in the user's browser and wait for the
    /// redirect. Completion runs on the main actor with the outcome, so
    /// Settings and onboarding can both report it in their own way.
    func beginBrowserSignIn(includeCommands: Bool = Preferences.commandsEnabled,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        guard VolvoCredentials.current.isConfigured else {
            completion(.failure(VolvoError.notConfigured))
            return
        }
        guard let url = api.authorizationURL(includeCommands: includeCommands) else {
            completion(.failure(VolvoError.authenticationFailed))
            return
        }

        // Only one sign-in at a time: a second would try to bind the same
        // port and fail in a way that looks like the first one broke.
        signIn?.cancel()
        let listener = CallbackListener()
        signIn = listener

        Task {
            do {
                async let callback = listener.waitForCallback()
                await MainActor.run { NSWorkspace.shared.open(url) }
                let redirected = try await callback
                try await api.authenticate(callbackURL: redirected, vin: Preferences.vin)
                await MainActor.run {
                    self.signIn = nil
                    completion(.success(()))
                    self.refreshNow()
                }
            } catch {
                await MainActor.run {
                    self.signIn = nil
                    completion(.failure(error))
                }
            }
        }
    }

    /// True when the session is gone rather than the network being flaky —
    /// no stored credentials, or Volvo rejecting the refresh token.
    static func isSignedOut(_ error: Error) -> Bool {
        switch error {
        case VolvoError.notConfigured, VolvoError.authenticationFailed, VolvoError.sessionExpired:
            return true
        default:
            return false
        }
    }

    func refreshNow() {
        guard api.isAuthenticated else { startSession(); return }
        let vin = Preferences.vin
        Task {
            do {
                let data = try await api.fetchCarData(vin: vin)
                await MainActor.run { self.apply(data) }
            } catch {
                await MainActor.run {
                    // A refresh token Volvo has retired can't be nursed back
                    // by polling it every minute, and there is no password to
                    // replay — the user has to consent again, so put Settings
                    // in front of them rather than an error row that never
                    // resolves.
                    if Self.isSignedOut(error) {
                        self.signedOut()
                        self.showSettings()
                        return
                    }
                    self.lastError = error.localizedDescription
                    self.statusController.render(data: self.latest, error: error.localizedDescription, authenticated: true)
                    self.settingsController?.updateStatus(data: self.latest,
                                                          error: error.localizedDescription,
                                                          authenticated: true)
                }
            }
        }
    }

    /// Send a command to the car.
    ///
    /// Unlock asks first. The others are recoverable — a honk is over in a
    /// second, a lock can be undone — but an unlocked car in a car park is
    /// not something to do by accident from a menu.
    private func runCommand(_ command: String) {
        guard api.isAuthenticated else { startSession(); return }

        if command == "unlock" {
            let alert = NSAlert()
            alert.messageText = L("Unlock the car?")
            alert.informativeText = L("The car will be unlocked immediately.")
            alert.addButton(withTitle: L("Unlock"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let vin = Preferences.vin
        Task {
            do {
                let result = try await api.executeCommand(command, vin: vin)
                await MainActor.run {
                    // Volvo accepts the request and reports what the car did
                    // with it; a rejected command still returns 200, so the
                    // invoke status is the only thing worth believing.
                    let ok = result.uppercased().contains("COMPLETED")
                        || result.uppercased().contains("SUCCESS")
                    if !ok {
                        self.lastError = String(format: L("%@ failed: %@"), command, result)
                        self.redrawStatusItem()
                    }
                    // Locking changes what the car reports, so pull a fresh
                    // reading rather than leaving the menu showing the old one.
                    self.refreshNow()
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.redrawStatusItem()
                    if Self.isSignedOut(error) { self.showSettings() }
                }
            }
        }
    }

    private func apply(_ data: CarData) {
        var data = data
        data.isDriving = data.driving(comparedTo: latest)
        data.logDriveSignal(comparedTo: latest)
        notifier.carDataDidUpdate(old: latest, new: data)
        latest = data
        lastError = nil
        // The switcher lists every car the user has ever signed in to, not
        // just this account's — that's the whole point of adding a second
        // one. Refreshing the cache here is what keeps the other account's
        // entry alive while it's signed out.
        Accounts.setCars(api.cars, for: Accounts.active)
        statusController.cars = Accounts.allCars
        statusController.activeVin = Preferences.vin
        statusController.render(data: data, error: nil, authenticated: true)
        settingsController?.updateStatus(data: data, error: nil, authenticated: true)
        WidgetBridge.publish(data)
        scheduleRefresh()
    }

    /// Point the app at another car: persist the VIN, refetch identity +
    /// image, then reload live data. A car belonging to a different account
    /// means a different session, so that case starts over from the login
    /// rather than just swapping the VIN.
    private func switchCar(to vin: String) {
        latest = nil   // old car's data must not seed notifications
        statusController.showLoading()

        if let owner = Accounts.owner(ofVin: vin), owner != Accounts.active {
            Preferences.email = owner
            Preferences.vin = vin
            startSession()
            return
        }

        Preferences.vin = vin
        Task {
            await api.selectCar(vin: vin)
            await MainActor.run { self.refreshNow() }
        }
    }

    /// Poll every minute while charging or driving (the numbers actually move,
    /// and a short cycle keeps "In use" from lingering after parking); at the
    /// pace chosen in Settings otherwise.
    private func scheduleRefresh() {
        let idle = TimeInterval(Preferences.refreshInterval.rawValue)
        let interval: TimeInterval =
            (latest?.isCharging == true || latest?.isDriving == true) ? min(60, idle) : idle
        if let timer = refreshTimer, timer.isValid, timer.timeInterval == interval { return }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    // MARK: - First run

    /// Everything the app was holding about a car it no longer has a login
    /// for. Without this the menu keeps offering the signed-out car in its
    /// switcher and the widget keeps showing its last reading.
    private func signedOut() {
        latest = nil
        lastError = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        statusController.cars = Accounts.allCars
        statusController.activeVin = Preferences.vin
        statusController.render(data: nil, error: nil, authenticated: false)
        WidgetBridge.clear()
        settingsController?.close()
        // A fresh controller, so onboarding opens on its first step rather
        // than wherever the last run left it.
        onboardingController = nil
        showOnboarding()
    }

    private func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(
                api: api,
                onSignIn: { [weak self] completion in
                    self?.beginBrowserSignIn(completion: completion)
                },
                onFinish: { [weak self] in
                    self?.applyLaunchAtLogin()
                    self?.startSession()
                },
                onManualVIN: { [weak self] in
                    self?.showSettings()
                }
            )
        }
        onboardingController?.show()
    }

    // MARK: - Settings

    func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                onChange: { [weak self] in
                    // Instant apply: the pane has already written the
                    // preference, so this only has to act on it. No refetch —
                    // the numbers didn't change, only how they're shown.
                    self?.applyLaunchAtLogin()
                    self?.redrawStatusItem()
                    // A new refresh pace takes effect on the next tick, not
                    // after the old timer has run its full course.
                    self?.scheduleRefresh()
                },
                onAccountChange: { [weak self] in
                    guard let self else { return }
                    self.applyLaunchAtLogin()
                    // Signing out of the last account leaves nothing to
                    // start a session with. Send them back to the front
                    // door rather than to an error row in the menu.
                    if self.hasCredentials {
                        self.startSession()
                    } else {
                        self.signedOut()
                    }
                }
,
                onSignIn: { [weak self] completion in
                    self?.beginBrowserSignIn(completion: completion)
                }
            )
        }
        settingsController?.show()
        settingsController?.updateStatus(data: latest, error: lastError,
                                         authenticated: api.isAuthenticated)
    }

    /// Re-render the menu bar from what the app already knows.
    private func redrawStatusItem() {
        statusController.render(data: latest, error: lastError,
                                authenticated: api.isAuthenticated)
    }

    private func applyLaunchAtLogin() {
        // SMAppService only works from a real .app bundle (make app),
        // not when running the bare binary via `swift run`.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            if Preferences.launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}
