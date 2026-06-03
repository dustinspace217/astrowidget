// astrowidget — Übersicht widget (macOS desktop overlay)
//
// Übersicht (https://tracesof.net/uebersicht/) is the macOS analog to a KDE
// plasmoid or a Rainmeter skin: a small always-on-desktop widget written in
// HTML/CSS/JS. A widget is an ES module that EXPORTS a few well-known members;
// Übersicht calls them on a timer and paints the returned JSX onto the wallpaper.
//
// This widget is a pure PRESENTATION layer over the same state.json the fetcher
// writes for the desktop app and the plasmoid — no astrowidget code runs here.
// It shows, per configured site, tonight's verdict (BB+NB / NB only / Neither),
// the broadband + narrowband scores, a compact weather line, the "best clear"
// gamble window (when the night is partly cloudy), and a REMOTE badge for hosted
// dome sites.
//
// Install + scheduling instructions live in the repo README ("macOS — Übersicht").

import { css } from "uebersicht";

// ─────────────────────────────────────────────────────────────────────────────
// Übersicht contract (the exported members Übersicht looks for)
// ─────────────────────────────────────────────────────────────────────────────

// `command` is a shell string Übersicht runs every refresh; its STDOUT is handed
// to render() as `output`. We simply cat the fetcher's state.json. The fetcher
// writes it to Qt's GenericCacheLocation, which on macOS is ~/Library/Caches —
// the SAME file the cross-platform desktop app reads, so the two never desync.
// `$HOME` expands because the command runs in a shell; the path is double-quoted
// so a space anywhere in it can't split the argument. `2>/dev/null` keeps a
// "file not found" (fetcher hasn't run yet) from polluting the widget with a
// shell error — render() handles the empty case.
export const command =
  `cat "$HOME/Library/Caches/astrowidget/state.json" 2>/dev/null`;

// Milliseconds between command runs. The fetcher only rewrites state.json a few
// times a day, but re-reading a sub-kilobyte file is effectively free, and a
// short cadence makes a manual fetch (or a "leave by" edit) appear promptly
// rather than hours later. 60s is a good balance; it is NOT tied to the fetcher's
// schedule on purpose (decouple the UI refresh from the data refresh).
export const refreshFrequency = 60000;

// ─────────────────────────────────────────────────────────────────────────────
// Verdict → color. Explicit map (not a clever expression) so the mapping is
// obvious and reviewable. The `?? GREY` fallback matters: if the fetcher ever
// emits an unexpected recommendation string, we get a neutral card instead of
// `undefined` styling. Mirrors the plasmoid/desktop theme-color choices.
// ─────────────────────────────────────────────────────────────────────────────
const GREY = "#94a3b8";
const ACCENT = {
  "BB+NB": "#4ade80",   // green — broadband + narrowband both viable
  "NB only": "#fbbf24", // amber — narrowband only (moonlight / light pollution)
  "Neither": "#f87171", // red   — stand down
};
const accentFor = (rec) => ACCENT[rec] ?? GREY;

// ─────────────────────────────────────────────────────────────────────────────
// Small helpers (pure functions — no Übersicht magic)
// ─────────────────────────────────────────────────────────────────────────────

// Compact "3h ago" / "5m ago" from an ISO timestamp, for the staleness line.
// Returns "" on anything unparseable so a bad timestamp never throws.
function ago(iso) {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return "";
  const mins = Math.max(0, Math.round((Date.now() - t) / 60000));
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.round(hrs / 24)}d ago`;
}

// Convert the fetcher's UTC ISO time (e.g. "2026-06-04T07:00") to the Mac's
// local clock as "11:30pm". The fetcher emits naive-UTC strings (no offset), so
// we append "Z" before parsing; the browser then localizes for display — the
// same approach the QML "Astro dark" line uses.
function localTime(iso) {
  if (!iso) return "";
  const s = /[zZ]|[+-]\d\d:?\d\d$/.test(iso) ? iso : iso + "Z";
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return "";
  let h = d.getHours();
  const m = d.getMinutes();
  const ap = h >= 12 ? "pm" : "am";
  h = h % 12 || 12;
  return m === 0 ? `${h}${ap}` : `${h}:${String(m).padStart(2, "0")}${ap}`;
}

// The "best clear" window is worth showing ONLY when it is a real GAP — i.e. the
// night is partly cloudy and the clear stretch is meaningfully shorter than the
// whole dark window. On a fully-clear night best_window ≈ the dark window (so the
// dark-window line already conveys it); on an overcast night there's no window.
// Same 85%-of-dark-window rule the QML uses, kept in one place here.
function bestClearText(night) {
  if (!night || !night.best_window || !night.dark_window) return "";
  const bw = night.best_window;
  const dwMin = night.dark_window.duration_minutes || 0;
  const start = Date.parse((bw.start || "") + "Z");
  const end = Date.parse((bw.end || "") + "Z");
  if (Number.isNaN(start) || Number.isNaN(end) || dwMin <= 0) return "";
  const bwMin = (end - start) / 60000;
  if (bwMin >= dwMin * 0.85) return ""; // basically the whole night — redundant
  return `Best clear: ${localTime(bw.start)} → ${localTime(bw.end)}`;
}

// ─────────────────────────────────────────────────────────────────────────────
// render — Übersicht hands us the command's STDOUT as `output`. We parse it and
// return JSX. A torn read (the fetcher writing while we cat) makes JSON.parse
// throw; we catch it and show a calm placeholder rather than a broken widget.
// (The fetcher also writes atomically, so torn reads should be rare.)
// ─────────────────────────────────────────────────────────────────────────────
export const render = ({ output }) => {
  let state;
  try {
    state = JSON.parse(output);
  } catch (e) {
    return (
      <div className={panel}>
        <div className={header}>
          <span className={title}>astrowidget</span>
        </div>
        <div className={muted}>Waiting for forecast data…</div>
      </div>
    );
  }

  const sites = (state && Array.isArray(state.sites) ? state.sites : []);
  return (
    <div className={panel}>
      <div className={header}>
        <span className={title}>astrowidget</span>
        <span className={muted}>
          {state.lastUpdated ? ago(state.lastUpdated) : ""}
        </span>
      </div>
      {sites.length === 0 && <div className={muted}>No sites configured.</div>}
      {sites.map((site) => (
        <SiteRow key={site.id || site.label} site={site} />
      ))}
    </div>
  );
};

// One site card. Reads tonight = nights[0]. Degrades to an "Error" pill when the
// fetcher marked the site status:"error" or there's no usable night.
function SiteRow({ site }) {
  const night = site.nights && site.nights[0] ? site.nights[0] : null;
  const ok = site.status === "ok" && night !== null;
  const rec = ok ? (night.recommendation || "Neither") : "Error";
  const accent = ok ? accentFor(night.recommendation) : GREY;

  const df = ok ? night.displayFactors || null : null;
  const bb = ok && night.broadband ? night.broadband.score : null;
  const nb = ok && night.narrowband ? night.narrowband.score : null;
  const best = ok ? bestClearText(night) : "";

  return (
    <div className={card} style={{ borderLeft: `3px solid ${accent}` }}>
      <div className={cardHead}>
        <span className={siteName}>{site.label || site.id}</span>
        {ok && night.managed === true && <span className={badge}>REMOTE</span>}
        <span className={pill} style={{ background: accent }}>{rec}</span>
      </div>

      {!ok && (
        <div className={muted}>
          {site.error ? String(site.error) : "No forecast for tonight."}
        </div>
      )}

      {ok && (
        <>
          <div className={scores}>
            <span>BB <b style={{ color: accent }}>{bb}</b></span>
            <span>NB <b style={{ color: accent }}>{nb}</b></span>
            {df && (
              <span className={wx}>
                {df.cloudPct != null ? `${df.cloudPct}% cloud` : ""}
                {df.seeing && df.seeing.label ? ` · ${df.seeing.label} seeing` : ""}
              </span>
            )}
          </div>
          {best && <div className={bestLine}>{best}</div>}
        </>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// `className` positions the widget root on the desktop (absolute screen coords,
// origin just below the menu bar). Pinned top-right. Übersicht uses Emotion under
// the hood; `css` from the bundled "uebersicht" module turns these template
// strings into class names. The cards carry their OWN semi-opaque background so
// the widget stays legible over ANY wallpaper (light or dark) — never assume a
// dark desktop.
// ─────────────────────────────────────────────────────────────────────────────
export const className = `
  top: 24px;
  right: 24px;
  font-family: -apple-system, "Helvetica Neue", sans-serif;
`;

const panel = css`
  width: 260px;
  padding: 12px 14px;
  border-radius: 14px;
  background: rgba(20, 22, 30, 0.74);
  backdrop-filter: blur(14px);
  -webkit-backdrop-filter: blur(14px);
  color: #e8eaf0;
  box-shadow: 0 8px 28px rgba(0, 0, 0, 0.45);
  border: 1px solid rgba(255, 255, 255, 0.08);
`;

const header = css`
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  margin-bottom: 8px;
`;

const title = css`
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.3px;
`;

const muted = css`
  font-size: 11px;
  opacity: 0.6;
`;

const card = css`
  background: rgba(255, 255, 255, 0.05);
  border-radius: 9px;
  padding: 8px 10px;
  margin-top: 7px;
`;

const cardHead = css`
  display: flex;
  align-items: center;
  gap: 7px;
`;

const siteName = css`
  font-size: 13px;
  font-weight: 600;
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
`;

const badge = css`
  font-size: 9px;
  letter-spacing: 0.5px;
  opacity: 0.8;
  border: 1px solid rgba(232, 234, 240, 0.4);
  border-radius: 4px;
  padding: 1px 5px;
`;

const pill = css`
  font-size: 10.5px;
  font-weight: 700;
  color: #14161e;
  border-radius: 999px;
  padding: 2px 9px;
  white-space: nowrap;
`;

const scores = css`
  display: flex;
  gap: 12px;
  align-items: baseline;
  margin-top: 6px;
  font-size: 12px;
  opacity: 0.92;
`;

const wx = css`
  opacity: 0.7;
  font-size: 11px;
`;

const bestLine = css`
  margin-top: 3px;
  font-size: 11.5px;
  font-weight: 600;
  color: #34d399;
`;
