//
//  OnboardingWindowController.swift
//  Norra (AppKit rewrite)
//
//  First run. The old first run was the Settings window: a grid asking for
//  email, password and a VIN typed by hand, saved without ever trying the
//  login — a wrong password showed up as "--" in the menu bar half a minute
//  later, with nothing saying why.
//
//  This asks for the two things only the user knows, signs in while they
//  watch, and then offers the cars the account actually reports. The VIN
//  survives as a fallback for an account the lookup can't read, not as the
//  front door.
//
//  Unlike the Settings window this one is branded to match the website —
//  the orange, the flat 2 pt corners, the same first sentence. Only the
//  title bar is left to the system.
//

import AppKit
import NorraShared

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    // MARK: Brand

    /// Volvo's own colour tokens, taken from `@volvo-cars/css` — the package
    /// their web properties are built on — rather than eyeballed from a
    /// screenshot. Each is named for the token it comes from, so a future
    /// version of that package can be diffed against this list.
    ///
    /// Polaris drew these from Polestar's site: an orange accent on warm
    /// off-white. Volvo's is a blue accent on true white, and the dark theme
    /// lightens the blue rather than reusing the light one, which is why both
    /// variants are spelled out.
    private enum Brand {
        /// --v-color-surface-accent-blue. The one colour anyone would
        /// recognise as Volvo's.
        static let accentLight = NSColor(srgbRed: 0x0b / 255, green: 0x2d / 255, blue: 0xed / 255, alpha: 1)
        static let accentDark = NSColor(srgbRed: 0x33 / 255, green: 0x54 / 255, blue: 0xff / 255, alpha: 1)
        /// --v-color-background-secondary.
        static let panelLight = NSColor(srgbRed: 0xfa / 255, green: 0xfa / 255, blue: 0xfa / 255, alpha: 1)
        static let panelDark = NSColor(srgbRed: 0x17 / 255, green: 0x17 / 255, blue: 0x17 / 255, alpha: 1)
        /// --v-color-surface-feedback-red / --v-color-foreground-feedback-red.
        static let dangerLight = NSColor(srgbRed: 0xcd / 255, green: 0x23 / 255, blue: 0x14 / 255, alpha: 1)
        static let dangerDark = NSColor(srgbRed: 0xef / 255, green: 0x66 / 255, blue: 0x58 / 255, alpha: 1)
    }

    static let accent = NSColor(name: nil) { appearance in
        appearance.isDark ? Brand.accentDark : Brand.accentLight
    }
    /// The flat fill behind car rows and the menu bar preview.
    static let panel = NSColor(name: nil) { appearance in
        appearance.isDark ? Brand.panelDark : Brand.panelLight
    }
    private static let hairline = NSColor(name: nil) { appearance in
        // --v-color-ornament-primary is #0000001f; the inverted form is the
        // same alpha on white.
        appearance.isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)
    }
    /// Red has to lighten in dark mode too — Volvo's #cd2314 on black fails
    /// contrast, which is why they ship a second value for it.
    private static let danger = NSColor(name: nil) { appearance in
        appearance.isDark ? Brand.dangerDark : Brand.dangerLight
    }
    static let hairlineColor = hairline
    /// Volvo's UI rounds at 4 px, a touch softer than Polestar's 2.
    private static let radius: CGFloat = 4

    // MARK: State

    private enum Step { case signIn, cars, finish }
    private var step: Step = .signIn

    private let api: VolvoAPI
    private let onFinish: () -> Void
    private let onManualVIN: () -> Void
    /// Runs the browser consent flow. Owned by AppDelegate, which holds the
    /// listener — this screen only asks for it and reports what came back.
    private let onSignIn: (@escaping (Result<Void, Error>) -> Void) -> Void
    private var discovered: [CarSummary] = []
    private var selectedVin: String?
    private var isWorking = false

    private let displayPopup = NSPopUpButton()
    /// The text inside the menu bar preview, so changing the popup shows
    /// what the bar will actually read rather than leaving a stale sample.
    private let previewLabel = NSTextField(labelWithString: "")
    private let launchCheckbox = NSButton(checkboxWithTitle: L("Open Norra at login"),
                                          target: nil, action: nil)
    private var errorText: String?

    /// The step's content, rebuilt wholesale on every transition. Three
    /// screens of a handful of views each is not worth the bookkeeping of
    /// keeping them all alive and hidden.
    private let container = NSView()

    /// Views that should span the window rather than hug their content.
    /// Recorded while the step is built and constrained in one pass, once
    /// the stack is in the hierarchy and has a width to be equal to.
    private var fullWidth: [NSView] = []

    init(api: VolvoAPI,
         onSignIn: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void,
         onFinish: @escaping () -> Void,
         onManualVIN: @escaping () -> Void) {
        self.api = api
        self.onSignIn = onSignIn
        self.onFinish = onFinish
        self.onManualVIN = onManualVIN

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Norra"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(container)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: content.topAnchor),
                container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                container.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Rendering

    private func render() {
        container.subviews.forEach { $0.removeFromSuperview() }
        fullWidth.removeAll()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultHigh, for: .vertical)

        switch step {
        case .signIn: buildSignIn(into: stack)
        case .cars:   buildCarPicker(into: stack)
        case .finish: buildFinish(into: stack)
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -30),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24)
        ])
        for view in fullWidth {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Each step is a different height; the window follows rather than
        // leaving one screen padded out to the tallest.
        if let content = window?.contentView {
            content.layoutSubtreeIfNeeded()
            let height = stack.fittingSize.height + 50
            var frame = window!.frame
            let delta = height - content.frame.height
            frame.size.height += delta
            frame.origin.y -= delta        // grow downwards, title bar stays put
            window?.setFrame(frame, display: true, animate: false)
        }

    }

    // MARK: Step 1 — sign in

    /// No email or password field: Volvo's flow sends the user to their own
    /// browser, on Volvo's own domain, and hands back an authorization code.
    /// Norra never sees the credentials — which is the point, and worth
    /// saying on the screen rather than leaving the button unexplained.
    private func buildSignIn(into stack: NSStackView) {
        stack.addArrangedSubview(title(L("Sign in")))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(sub(L("Norra opens Volvo ID in your browser. Your password is never typed into Norra.")))
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)

        if !VolvoCredentials.current.isConfigured {
            // Nothing can happen without an application key, and the reason
            // is not guessable — say so here rather than letting the button
            // fail with a 401.
            stack.addArrangedSubview(errorRow(L("Add your Volvo application key in Settings first.")))
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        }

        if let errorText {
            stack.addArrangedSubview(errorRow(errorText))
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        }

        if isWorking {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let row = NSStackView(views: [spinner, sub(L("Waiting for your browser…"))])
            row.orientation = .horizontal
            row.spacing = 9
            stack.addArrangedSubview(row)
        } else {
            let button = primaryButton(L("Sign In with Volvo ID"), action: #selector(signInAction))
            button.isEnabled = VolvoCredentials.current.isConfigured
            stack.addArrangedSubview(fill(button, in: stack))
        }
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(fill(separator(), in: stack))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(fill(privacyNote(), in: stack))
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(stepBars(1))
    }

    @objc private func signInAction() {
        guard !isWorking else { return }
        errorText = nil
        isWorking = true
        render()

        onSignIn { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            switch result {
            case .success:
                let cars = self.api.cars
                guard !cars.isEmpty else {
                    // Consent that works but reports no cars is a real case
                    // (a car sold, or an account that only has an order).
                    // Typing the VIN is the only way forward.
                    self.errorText = L("No cars on this account. You can enter a VIN manually in Settings.")
                    self.render()
                    return
                }
                self.discovered = cars
                self.selectedVin = cars.first?.vin
                self.step = .cars
                self.render()
            case .failure(let error):
                self.errorText = error.localizedDescription
                self.render()
            }
        }
    }

    // MARK: Step 2 — choose a car

    private func buildCarPicker(into stack: NSStackView) {
        stack.addArrangedSubview(title(L("Choose your car")))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        let count = discovered.count
        let blurb = count == 1
            ? L("One car on this account.")
            : String(format: L("%d cars on this account. You can switch any time from the menu."), count)
        stack.addArrangedSubview(sub(blurb))
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        for car in discovered {
            let row = CarRow(car: car, image: nil, selected: car.vin == selectedVin) { [weak self] in
                self?.selectedVin = car.vin
                self?.render()
            }
            stack.addArrangedSubview(fill(row, in: stack))
            stack.setCustomSpacing(9, after: row)
        }
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)

        let manual = secondaryButton(L("Enter VIN Manually…"), action: #selector(manualVinAction))
        let cont = primaryButton(L("Continue"), action: #selector(continueFromCarsAction))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [manual, spacer, cont])
        row.orientation = .horizontal
        row.spacing = 14
        stack.addArrangedSubview(fill(row, in: stack))
        stack.setCustomSpacing(20, after: row)
        stack.addArrangedSubview(stepBars(2))
    }

    @objc private func continueFromCarsAction() {
        guard let vin = selectedVin else { return }
        selectedVin = vin
        step = .finish
        render()
    }

    /// The escape hatch for an account whose cars the API won't list. It
    /// hands off to Settings, which already has a VIN field and the rest of
    /// the account plumbing — no second copy of it here.
    @objc private func manualVinAction() {
        commit(vin: "")
        close()
        onManualVIN()
    }

    // MARK: Step 3 — where it went

    private func buildFinish(into stack: NSStackView) {
        stack.addArrangedSubview(title(L("Lives in the menu bar")))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(sub(L("No Dock icon, no window. Your battery sits in the menu bar — click it for range, charging and the doors.")))
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(menuBarPreview())
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        displayPopup.removeAllItems()
        for option in DisplayOption.allCases { displayPopup.addItem(withTitle: option.title) }
        displayPopup.selectItem(at: DisplayOption.allCases.firstIndex(of: Preferences.displayOption) ?? 0)
        displayPopup.target = self
        displayPopup.action = #selector(displayOptionChanged)
        stack.addArrangedSubview(label(L("SHOW IN THE MENU BAR")))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(displayPopup)
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        launchCheckbox.state = .on      // the default for a menu bar app
        stack.addArrangedSubview(launchCheckbox)
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)

        let done = primaryButton(L("Done"), action: #selector(doneAction))
        stack.addArrangedSubview(fill(done, in: stack))
        stack.setCustomSpacing(20, after: done)
        stack.addArrangedSubview(stepBars(3))
    }

    @objc private func displayOptionChanged() {
        previewLabel.stringValue = sampleBarTitle()
    }

    /// A plausible reading for the chosen option. Invented numbers, because
    /// the car hasn't been polled yet at this point in the flow — the point
    /// is the shape of the text, not the value.
    private func sampleBarTitle() -> String {
        let option = displayPopup.indexOfSelectedItem >= 0
            ? DisplayOption.allCases[displayPopup.indexOfSelectedItem]
            : Preferences.displayOption
        switch option {
        case .batteryPercentage:
            return "72%"
        case .rangeKm:
            let unit = Preferences.distanceUnit
            return "\(unit.convert(km: 412))\(unit.suffix)"
        case .chargeTime:
            return "1h 20min"
        }
    }

    @objc private func doneAction() {
        if displayPopup.indexOfSelectedItem >= 0 {
            Preferences.displayOption = DisplayOption.allCases[displayPopup.indexOfSelectedItem]
        }
        Preferences.launchAtLogin = (launchCheckbox.state == .on)
        commit(vin: selectedVin ?? "")
        close()
        onFinish()
    }

    /// Everything the rest of the app reads to consider itself configured.
    /// Written in one place at the end rather than field by field, so an
    /// abandoned onboarding leaves no half-account behind.
    ///
    /// No password is stored, because none was typed: the refresh token
    /// VolvoAPI wrote to the Keychain during sign-in is the whole session.
    /// The account is keyed by the first car's VIN rather than an email —
    /// Volvo's consent flow never tells us the address, and `Accounts` only
    /// needs a stable identifier to hang the car list on.
    private func commit(vin: String) {
        let account = discovered.first?.vin ?? vin
        Preferences.email = account
        Preferences.vin = vin
        Accounts.add(account)
        Accounts.setCars(discovered, for: account)
    }

    // MARK: - Pieces

    private func title(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 22, weight: .semibold)
        l.maximumNumberOfLines = 2
        return l
    }

    private func sub(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 12.5)
        l.textColor = .secondaryLabelColor
        l.isSelectable = false
        return l
    }

    /// The site's uppercase, letterspaced field labels.
    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .kern: 1.1]
        )
        return l
    }

    private func primaryButton(_ title: String, action: Selector) -> NSButton {
        let b = FlatButton(title: title, target: self, action: action)
        b.fillColor = Self.accent
        b.titleColor = .white
        return b
    }

    /// The quieter of the two: same metrics as the primary, hairline border
    /// instead of a fill, so the pair reads as one row of buttons.
    private func secondaryButton(_ title: String, action: Selector) -> NSButton {
        let b = FlatButton(title: title, target: self, action: action)
        b.fillColor = .clear
        b.borderColor = Self.hairline
        b.titleColor = .labelColor
        return b
    }

    private func errorRow(_ text: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Self.danger
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = Self.danger
        let row = NSStackView(views: [icon, l])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        return row
    }

    private func privacyNote() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let l = NSTextField(wrappingLabelWithString:
            L("Stored in the macOS Keychain, sent only to Volvo. Norra has no server of its own."))
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, l])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    /// The real status item, drawn in place — this screen exists because a
    /// menu-bar-only app looks like nothing happened after install, and
    /// naming the icon in prose is not the same as showing it.
    private func menuBarPreview() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: StatusItemController.icon(for: nil),
                                              accessibilityDescription: nil) ?? NSImage())
        previewLabel.font = .systemFont(ofSize: 13, weight: .medium)
        previewLabel.stringValue = sampleBarTitle()
        let row = PanelStack(views: [icon, previewLabel])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 16)
        return row
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        return v
    }

    /// Three flat bars, the site's progress marker.
    private func stepBars(_ current: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 5
        for i in 1...3 {
            let bar = SwatchView(color: i <= current ? Self.accent : Self.hairline)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 26).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 2).isActive = true
            row.addArrangedSubview(bar)
        }
        return row
    }

    /// NSStackView aligns to the leading edge; anything that should span the
    /// window has to say so.
    private func fill(_ view: NSView, in stack: NSStackView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        fullWidth.append(view)
        return view
    }
}

// MARK: - Appearance-aware layer views

/// A CGColor is resolved against whatever appearance was current when it was
/// asked for, and then never changes — a window left open across a light/dark
/// switch keeps the old fills. Anything that paints a dynamic NSColor into a
/// layer therefore has to repaint on `viewDidChangeEffectiveAppearance`.

/// A flat rectangle of one colour. Used for the step bars.
private final class SwatchView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}

/// The site's flat panel: --panel fill, hairline border, 2 pt corners.
private final class PanelStack: NSStackView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.borderWidth = 1
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = OnboardingWindowController.panel.cgColor
            layer?.borderColor = OnboardingWindowController.hairlineColor.cgColor
        }
    }
}

// MARK: - Flat controls

/// AppKit's push button carries its own gradient and 6 pt radius, neither of
/// which is ours. Drawing the fill in a layer is less code than a full
/// NSButtonCell subclass and keeps the title, keyboard and accessibility
/// behaviour of a real button.
private final class FlatButton: NSButton {
    var fillColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var titleColor: NSColor = .white { didSet { restyle() } }

    /// NSButton sizes itself to the title with barely any room either side;
    /// the site's buttons carry 20 pt of it.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 40
        return size
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        common()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        restyle()
    }

    private func common() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 2
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    override var wantsUpdateLayer: Bool { true }

    private func restyle() {
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                         .foregroundColor: titleColor]
        )
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isHighlighted ? fillColor.withAlphaComponent(0.85) : fillColor).cgColor
            layer?.borderWidth = borderColor == nil ? 0 : 1
            layer?.borderColor = borderColor?.cgColor
        }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One car in the picker: render plate, model title, masked VIN, and a tick
/// when it's the chosen one. Clicking anywhere in the row selects it.
private final class CarRow: NSView {
    private let onSelect: () -> Void
    private let selected: Bool

    init(car: CarSummary, image: NSImage?, selected: Bool, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        self.selected = selected
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.borderWidth = 1
        restyle()

        // The studio render, when the app happens to have one. It is fetched
        // one car at a time and only for the selected VIN, so during
        // onboarding there usually isn't one — and an empty plate holding a
        // generic car glyph says nothing the model name doesn't already say.
        // Better to have no plate than a plate of nothing.
        var leading: [NSView] = []
        if let image {
            let plate = NSImageView(image: image)
            plate.imageScaling = .scaleProportionallyUpOrDown
            plate.wantsLayer = true
            plate.layer?.cornerRadius = 2
            plate.translatesAutoresizingMaskIntoConstraints = false
            plate.widthAnchor.constraint(equalToConstant: 76).isActive = true
            plate.heightAnchor.constraint(equalToConstant: 44).isActive = true
            leading.append(plate)
        }

        let name = NSTextField(labelWithString: car.title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail

        let vin = NSTextField(labelWithString: Self.mask(car.vin))
        vin.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        vin.textColor = .secondaryLabelColor

        let meta = NSStackView(views: [name, vin])
        meta.orientation = .vertical
        meta.alignment = .leading
        meta.spacing = 2

        // A spacer, so the tick sits at the trailing edge rather than
        // crowding the model name.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: leading + [meta, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 13
        row.edgeInsets = NSEdgeInsets(top: 15, left: 16, bottom: 15, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false

        if selected {
            let tick = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill",
                                                  accessibilityDescription: nil) ?? NSImage())
            tick.contentTintColor = OnboardingWindowController.accent
            row.addArrangedSubview(tick)
        }

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = selected
                ? OnboardingWindowController.accent.cgColor
                : NSColor(white: 0.5, alpha: 0.28).cgColor
            layer?.backgroundColor = selected
                ? OnboardingWindowController.accent.withAlphaComponent(0.05).cgColor
                : NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) { onSelect() }

    /// A VIN is an identifier for a physical car parked somewhere; the last
    /// three characters are enough to tell two of them apart on this screen.
    static func mask(_ vin: String) -> String {
        guard vin.count > 6 else { return vin }
        return vin.prefix(vin.count - 6) + "•••" + vin.suffix(3)
    }
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
