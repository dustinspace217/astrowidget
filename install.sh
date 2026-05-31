#!/usr/bin/env bash
# astrowidget installer
#
# Runs the steps documented in README §Installation in one shot. Idempotent:
# safe to re-run after every change. Does NOT touch ~/.config/astrowidget/config.toml
# if it already exists (so re-runs never clobber user data).
#
# Usage:  bash install.sh         # build + install + enable + smoke
#         bash install.sh --no-fetch  # skip the initial fetcher run

set -euo pipefail

# Resolve paths relative to this script's location so the installer works
# from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIDGET_DIR="$SCRIPT_DIR"
SCORING_DIR="$WIDGET_DIR/scoring"   # self-contained vendored Dart scoring engine
PLASMOID_DIR="$WIDGET_DIR/plasmoid/space.dustin.astrowidget"
BIN_DIR="$WIDGET_DIR/bin"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/astrowidget"

# ─────────────────────────────────────────────────────────────────────────────
# Sanity checks — fail loudly on missing prerequisites.
# ─────────────────────────────────────────────────────────────────────────────
require() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "astrowidget install: missing required command: $1" >&2
		exit 1
	}
}
require dart
require kpackagetool6
require systemctl
require python3

# Python ≥ 3.11 is required (tomllib stdlib only landed in 3.11). Without
# this check the fetcher would fail with an obscure ImportError on older
# distributions.
if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)" 2>/dev/null; then
	pyver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
	echo "astrowidget install: python3 must be 3.11 or newer (found $pyver)." >&2
	echo "  Fedora 41+ ships 3.13; on older distributions install Python 3.11+." >&2
	exit 1
fi

if [[ ! -f "$SCORING_DIR/bin/score_location.dart" ]]; then
	echo "astrowidget install: vendored scoring engine missing at $SCORING_DIR" >&2
	echo "  Expected scoring/bin/score_location.dart in the repo (it is self-contained)." >&2
	exit 1
fi

if ! python3 -c "import requests" 2>/dev/null; then
	echo "astrowidget install: python3 'requests' module not available." >&2
	echo "  Install via:  pip install --user 'requests>=2.32.4'" >&2
	echo "  Or via dnf:   sudo dnf install python3-requests" >&2
	exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. Build the Dart scoring binary from the self-contained scoring/ package.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Compiling Dart scoring binary (from vendored scoring/ engine)..."
mkdir -p "$BIN_DIR"
# LOAD-BEARING COMMENT — do NOT "simplify" to `dart compile exe`. The scoring
# package's dependency graph (geoengine) contains packages with build hooks.
# `dart compile exe` does NOT support build hooks and fails with "does not
# support build hooks, use 'dart build' instead." `dart build cli` is the
# correct command and produces a standalone binary in bundle/bin/<entry>.
# Verified 2026-05-28; re-verified for the vendored package 2026-05-31.
BUILD_TMP="$(mktemp -d -t astrowidget-build.XXXXXX)"
trap 'rm -rf "$BUILD_TMP"' EXIT
(cd "$SCORING_DIR" && dart pub get && dart build cli \
	-t bin/score_location.dart \
	-o "$BUILD_TMP/")
cp "$BUILD_TMP/bundle/bin/score_location" "$BIN_DIR/astrowidget-score"
chmod +x "$BIN_DIR/astrowidget-score"
echo "    OK: $BIN_DIR/astrowidget-score"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Install / upgrade the plasmoid package.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Installing plasmoid..."
# `upgrade` is idempotent (works for both fresh installs and updates).
if kpackagetool6 --type Plasma/Applet --list 2>/dev/null \
	| grep -q "^space\.dustin\.astrowidget$"; then
	kpackagetool6 --type Plasma/Applet --upgrade "$PLASMOID_DIR"
else
	kpackagetool6 --type Plasma/Applet --install "$PLASMOID_DIR"
fi
echo "    OK: space.dustin.astrowidget"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Install systemd user units and enable the timer.
#
# Templates the actual install path into the service unit's ExecStart so
# the widget works regardless of where the user cloned the repo. Previously
# the unit hardcoded `%h/Claude/astrowidget/...` which broke for anyone
# installing outside the canonical layout (code-reviewer #20).
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Installing systemd user units..."
mkdir -p "$SYSTEMD_USER_DIR"
# Substitute the WIDGET_DIR value into the service unit. The sed expression
# replaces any line starting with ExecStart= with one that points at the
# actual install location's fetcher.
sed -E "s|^ExecStart=.*|ExecStart=$WIDGET_DIR/fetcher/astrowidget_fetch.py|" \
	"$WIDGET_DIR/systemd/astrowidget-fetch.service" \
	> "$SYSTEMD_USER_DIR/astrowidget-fetch.service"
cp "$WIDGET_DIR/systemd/astrowidget-fetch.timer" "$SYSTEMD_USER_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now astrowidget-fetch.timer
echo "    OK: timer enabled and active"
echo "    NOTE: for the timer to fire when you're logged out (e.g., overnight)"
echo "          enable lingering:  loginctl enable-linger $USER"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Create config from template if it doesn't exist.
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config.toml" ]]; then
	echo "==> Creating config.toml from template..."
	cp "$WIDGET_DIR/config.example.toml" "$CONFIG_DIR/config.toml"
	chmod 600 "$CONFIG_DIR/config.toml"
	echo "    OK: $CONFIG_DIR/config.toml"
	echo "    NOTE: edit this file and add your Astrospheric API key + sites."
else
	echo "==> Config already exists, leaving alone: $CONFIG_DIR/config.toml"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Initial fetcher run (optional).
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" != "--no-fetch" ]]; then
	echo "==> Running fetcher once to populate state.json..."
	# Don't fail the installer if the fetcher errors (e.g., config still has
	# placeholder values). The user gets a clear next-step in the output.
	if "$WIDGET_DIR/fetcher/astrowidget_fetch.py"; then
		echo "    OK: state.json written"
	else
		echo "    NOTE: fetcher exited non-zero. Likely the config still has"
		echo "    placeholder values. Edit $CONFIG_DIR/config.toml and re-run:"
		echo "      systemctl --user start astrowidget-fetch.service"
	fi
fi

echo ""
echo "Install complete. Next steps:"
echo "  1. Edit $CONFIG_DIR/config.toml with your API key and sites."
echo "  2. Add the widget to your panel:"
echo "       right-click panel → 'Add or Manage Widgets' → search 'astrowidget'"
echo "  3. Trigger a manual refresh any time:"
echo "       systemctl --user start astrowidget-fetch.service"
echo "  4. (Optional) For the timer to fire while you're logged out:"
echo "       loginctl enable-linger $USER"
