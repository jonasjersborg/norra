# Norra

Your Volvo, in the menu bar.

Norra is a tiny native macOS app that shows your Volvo's battery, range, and
charging status in the menu bar, and on the desktop as a widget. Pure AppKit —
no Electron, no background services; the widget is SwiftUI because WidgetKit
leaves no choice. It talks only to Volvo's official developer APIs.

Forked from [Polaris](https://github.com/simonbusborg/polaris) by
[@simonbusborg](https://github.com/simonbusborg) — the same app for Polestar,
itself grown from his [Teslaris](https://github.com/simonbusborg/teslaris).
Almost everything good about the way this app is built is his; the Volvo API
layer is the part that is new. See [Credits](#credits).

Built and tested against a Volvo EX30.

## Features

- Battery %, range (km/mi), charging status and time-to-full — refreshed every
  5 minutes, or every minute while charging
- Charger connection, live charging power and whether it's AC or DC
- Odometer, service interval and fluid warnings
- Lock, unlock, honk and flash, if you grant those scopes at sign-in — off by
  default, and unlock asks before it acts
- Notifications when charging starts, completes, or the charger reports a fault
- A desktop widget in three sizes: small for battery, range and state, medium
  for those beside your car, large for everything the menu shows. It reads what
  the app last fetched rather than polling on its own, so adding one doesn't add
  a request to your car
- Choose what the menu bar shows
- Follows the system language in twelve languages: English, Danish, Swedish,
  Norwegian, German, Spanish, Italian, Dutch, Finnish, French, Portuguese and
  Polish. Adding one is a single `Resources/<lang>.lproj/Localizable.strings`
  file; a test fails the build if any language falls behind the others
- Sign-in happens in your browser, on Volvo's own domain. Norra never sees your
  password, and none is stored — the refresh token in the macOS Keychain is the
  whole session, and it is resumed on launch
- OAuth2/OIDC with PKCE against Volvo ID; no third parties, no analytics, no
  tracking
- Launch at login (optional)
- A single small binary

See [ROADMAP.md](ROADMAP.md) for what's planned and what deliberately isn't.

## Getting Volvo credentials

Unlike Polestar's, Volvo's API is official and documented — which means it is
also credentialed. There is no key to ship inside the app, so you bring your
own. It is free for non-commercial use.

1. Register at [developer.volvocars.com](https://developer.volvocars.com/account/)
   and create an application. The **VCC API key** is issued immediately.
2. Set the application's redirect URI to `http://localhost:9631/callback`.
   Norra listens there during sign-in and nowhere else.
3. Publishing the application gets you a **client ID and secret**. Volvo
   reviews this by hand and it takes 14–21 days.
4. Copy `Resources/templates/Secrets.example.swift` to
   `Sources/Norra/Secrets.swift` and fill it in. That file is gitignored.

Credentials can also come from the environment (`VOLVO_VCC_API_KEY`,
`VOLVO_CLIENT_ID`, `VOLVO_CLIENT_SECRET`) or be typed into Settings; see
[VolvoCredentials.swift](Sources/Norra/VolvoCredentials.swift) for the order
they are read in.

Two limits worth knowing before you start: a published application is capped at
10,000 calls a day (Norra's 5-minute poll uses about 290), and only cars in
Europe, the Middle East and Africa are reachable once published.

## Install

Norra isn't packaged for distribution — it needs credentials only you can get
(see above), so build it yourself:

```bash
git clone <your fork>
cd norra
cp Resources/templates/Secrets.example.swift Sources/Norra/Secrets.swift
# fill in your Volvo application key
make app
open Norra.app
```

Then click the menu bar icon → Settings… → enter your VIN → **Sign In with
Volvo ID**. Your browser opens Volvo's consent page; approving it sends you
back to Norra and the menu fills in.

## Build from source

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/simonbusborg/norra
cd norra
make app
open Norra.app
```

`make run` builds and runs the bare binary for quick iteration (launch-at-login,
notifications and the widget are unavailable in that mode). `make test` (or
`swift test`) runs the test suite.

`make install` replaces the copy in `/Applications`, restarts the app and the
widget host, and reopens it — the loop for working on the widget, and less
error-prone than copying the bundle by hand.

The widget reads what the app writes, and how they share it depends on how the
build is signed:

- **A release** shares an App Group container. On macOS the identifier carries
  the Team ID prefix, so pass `TEAM_ID=ABCDE12345` to reproduce that locally
  (the release workflow passes it from `NOTARY_TEAM_ID`). No provisioning
  profile is needed and the group doesn't have to be registered in the
  developer portal — a Developer ID build carrying the entitlement notarizes
  and the container resolves at runtime.
- **A plain `make app`** shares `~/Library/Application Support/Norra`
  instead, and the widget is signed with a sandbox exception for that folder.
  This isn't a shortcut: macOS validates an app group against the team in the
  signature, and an ad-hoc build has none, so it would be handed a container
  URL and then denied every read. The sandbox itself stays either way —
  WidgetKit won't register an unsandboxed extension, and a widget that isn't
  registered never appears in the gallery at all.

## Releasing

One command from a clean working tree — it bumps `Info.plist`, commits, tags
and pushes, and GitHub Actions builds the app and attaches `Norra.dmg` and
`Norra.zip` to the release:

```bash
make release VERSION=1.0.0
```

Don't tag by hand. The release workflow checks the tag against
`CFBundleShortVersionString` and fails if they disagree, because the update
checker compares the two — a release whose plist says something else would nag
every user forever. `make release` bumps the plist as part of the same commit,
which is what keeps them in step.

Pushing a `preview-*` tag builds the same thing without publishing anything:
signed, notarized and attached to the workflow run as an artifact. It's the
only way to test the widget's App Group, which macOS honours for a properly
signed build and denies for an ad-hoc one.

```bash
git tag preview-widget-1 && git push origin preview-widget-1
```

Releases are signed and notarized when these repository secrets are configured
(without them the workflow falls back to an ad-hoc-signed build):

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12` | Base64 of a "Developer ID Application" certificate + private key (`.p12`) |
| `MACOS_CERT_PASSWORD` | Password of that `.p12` |
| `NOTARY_APPLE_ID` | Apple ID email used for notarization |
| `NOTARY_TEAM_ID` | 10-character Apple Developer Team ID |
| `NOTARY_APP_PASSWORD` | App-specific password for that Apple ID |

Two more secrets are optional and independent of signing: `SPARKLE_PRIVATE_KEY`
signs the build for the update feed, and `HOMEBREW_TAP_TOKEN` — a token with
`contents: write` on [simonbusborg/homebrew-norra](https://github.com/simonbusborg/homebrew-norra) —
lets the workflow point the cask at the new DMG. Both steps run after the
release is published and neither can fail it.

## Debug flags

Off by default, and none of them alter what the API returns:

```bash
defaults write com.weareheavy.norra debug_logging -bool YES
defaults delete com.weareheavy.norra debug_logging   # turn it off again
```

| Key | Effect |
| --- | --- |
| `debug_logging` | Logs each Volvo request's outcome and the capabilities the car reports (`log show --info --last 10m \| grep VolvoAPI`). Status codes and field names only — no tokens, no VIN |
| `debug_drive` | Logs the numbers behind each "in use" verdict — odometer in metres, the distance since the last reading, and how old both odometer reports are (`log show --info --last 10m \| grep "drive:"`). The one way to see what a parked car's odometer stream actually does |
| `debug_charging_type` | A string (`AC`, `DC`, `WIRELESS`) that renders the charging rows on a parked car. It invents its numbers in the menu layer, so it demonstrates the layout and nothing about the wire format — and it hides the real Power row while set |
| `debug_demo_car` | Adds a pretend second car mirroring the real one, so the multi-car switcher can be exercised on a single-car account |

Not every field the Energy API documents is served by every car — the EX30
reports no target charge level or charging current limit, for instance. Norra
asks the capabilities endpoint at sign-in rather than assuming, and
`debug_logging` prints what came back.

## Support

Norra is free and MIT licensed. If it's earning its place in your menu bar,
you're welcome to chip in — it's never expected.

[![Donate with PayPal](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/donate/?hosted_button_id=U6P5Y4A5ZHHVY)

## Credits

Norra is a fork of **[Polaris](https://github.com/simonbusborg/polaris)** by
[Simon Busborg](https://github.com/simonbusborg), the same app for Polestar,
which he in turn grew out of his
[Teslaris](https://github.com/simonbusborg/teslaris) for Tesla. The menu bar,
the widget, the notification logic, the hand-assembled app bundle, the release
pipeline and the twelve translations are all his work, and the fork kept them
almost untouched — the first commit in this repository is his code verbatim, so
`git log` shows exactly what changed.

What is new here is the Volvo layer: [VolvoAPI](Sources/Norra/VolvoAPI.swift),
[VolvoModels](Sources/Norra/VolvoModels.swift) and the browser
[CallbackListener](Sources/Norra/CallbackListener.swift) that Volvo's OAuth flow
needs and Polestar's didn't.

Volvo's API shapes were read from their published
[developer portal](https://developer.volvocars.com/) and their official
[API samples](https://github.com/volvo-cars/developer-portal-api-samples).

## Disclaimer

Not affiliated with Volvo. Use at your own risk.

## License

[MIT](LICENSE)

The MIT license covers the source code, and the copyright notice covers both
Simon's original work and this fork's changes. It does not grant rights to the
Norra name or the app icon — please pick your own if you ship a fork of this
one. "Volvo" is a trademark of Volvo Car Corporation, which is not affiliated
with this project.
