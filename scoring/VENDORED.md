# Vendored scoring engine

The Dart code in `lib/` is **vendored** (a frozen copy) from the
[astroplan](https://github.com/dustinspace217/astroplan) project. astrowidget
reuses astroplan's astronomy/scoring *ideas and methods* but is a **separate,
independent application** — it does not depend on astroplan at build or run
time, and changes here do not flow back to astroplan (and vice-versa).

## What's here

- `bin/score_location.dart` — astrowidget's own CLI wrapper (reads a JSON
  scoring request on stdin, writes the per-site verdict JSON to stdout). This
  is astrowidget code; it was never part of the astroplan app.
- `lib/` — 20 engine files (the transitive closure of what the wrapper needs):
  `scoring/`, `astro/`, `weather/`, `seeing/`, `visual/`, `logging/`.

## Differences from upstream astroplan (deliberate, astrowidget-only)

- `lib/logging/app_logger.dart` — `kReleaseMode` is defined as
  `const bool kReleaseMode = bool.fromEnvironment('dart.vm.product')` instead of
  importing `package:flutter/foundation.dart`. This lets the engine compile as a
  pure-Dart native binary with no Flutter SDK. (Behaviourally identical to
  Flutter's own `kReleaseMode`.) Upstream astroplan keeps the Flutter import.
- `bin/score_location.dart` — astrowidget-specific scoring logic that is **not**
  in upstream: peak-precipitation veto over the sunset→sunrise exposure window,
  `precip_peak_pct` output, and `_localizeReasons()` (renders the "Best window"
  reason in the host's local time zone rather than UTC).

`lib/astro/visibility.dart` here includes `horizonWindow()` (sunset→sunrise
window). That helper is also a legitimate addition to upstream astroplan, so it
exists in both — independently maintained.

## Building the binary

From this directory:

```
dart pub get
dart build cli -t bin/score_location.dart -o build
cp build/bundle/bin/score_location ../bin/astrowidget-score
```

`dart build cli` (not `dart compile exe`) is required because `geoengine` ships
native assets that need its build/link hooks. The produced binary
(`../bin/astrowidget-score`) is gitignored; this source is what's tracked.

## Re-vendoring (if you ever pull a fix from astroplan)

The vendored set is the transitive import closure of `bin/score_location.dart`
within astroplan's `lib/`. Re-copy those files, re-apply the two deliberate
differences above, and rewrite the 6 `package:astroplan/…` imports in
`score_location.dart` to `package:astrowidget_scoring/…`.
