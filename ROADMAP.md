# Roadmap

What's planned for Norra, roughly in the order it's likely to happen.
Nothing here is a promise with a date attached — it's a single developer and
a personal project.

Each item links to an issue. Comment there if you want it, or if you can
help; that's more useful than a wish sent anywhere else.

## How issues are worked

An issue is closed by the release that ships it, not by the commit that
writes the code — until it's tagged, nothing is out with users. So:

1. The work lands on `main` and CI goes green.
2. `make release VERSION=x.y.z` tags it and Actions builds the release.
3. Then, on each issue the release closes: a comment saying what actually
   shipped and in which version, and what deliberately didn't — then close it.

Don't put `Closes #…` in a commit message. GitHub acts on it the moment the
commit reaches `main`, which closes the issue a release too early and skips
the comment that was the whole point. Reference the issue by number instead.

Everything public is written in English — issues, comments, releases, this
file. The people asking are from all over Volvo's markets, and a reply in
Danish is a reply only Simon can read.

The comment is the point. A silently closed issue tells the person who asked
nothing, and this roadmap's "Shipped" list is only trustworthy if every entry
has a version next to it. An issue that got *partly* solved stays open with a
comment describing where it now stands.

## Next

- **[A better "in use" signal](https://github.com/jonasjersborg/norra/issues/3)** — the API's charging status reads `IDLE`
  whether the car is parked or on the motorway, so driving is inferred from
  the odometer moving. v2.8.1 made that inference sharper — metres rather
  than whole kilometres, and readings too far apart to describe the present
  are no longer treated as movement — but it is still an inference. Closing
  this needs a field that reports drive state directly, and neither the
  GraphQL telematics nor the gRPC battery service has one.

## Being looked at

These depend on what the API actually exposes, which is not something that
can be promised before someone has tried it.

- **[Charging history](https://github.com/jonasjersborg/norra/issues/5)** — a log of recent sessions rather than only what's
  happening right now.
- **[Climate / preconditioning status](https://github.com/jonasjersborg/norra/issues/6)** — whether the car reports it at all is
  still an open question.
- **[Multiple accounts](https://github.com/jonasjersborg/norra/issues/7)** — distinct from multiple cars, which already works.

## Shipped

Nothing yet — this fork has made no release. The features listed under
[Features in the README](README.md#features) are inherited from Polaris and
work, but they have not been through a tagged Norra build.

Polaris's own release history lives in
[its repository](https://github.com/simonbusborg/polaris/releases) and is not
reproduced here: those versions shipped a different app against a different
API, and listing them as Norra's would be a claim about work this project
hasn't done.

## Not planned

- **Remote commands** (unlock, start charging, climate on) — Norra is
  read-only by design. A menu bar app that can unlock a car is a different
  and much more careful piece of software.
- **iOS / iPadOS** — this is a macOS menu bar app.
- **Telemetry** — no analytics, no crash reporting, no phoning home.
