-- state.lua — Rainmeter Script measure for astrowidget (Windows desktop skin).
--
-- Reads the fetcher's state.json (the SAME file the KDE plasmoid and the
-- cross-platform desktop app read) and exposes per-site verdict lines + colors
-- to the skin's meters via inline Lua, e.g. [&MeasureState:LineA(1)].
--
-- WHY a vendored JSON decoder: Rainmeter ships Lua 5.1 with `require` DISABLED
-- and no external libraries, so there is no `import json`. The real state.json is
-- nested (sites[] -> nights[] -> broadband{}), which is fragile to pattern-match
-- by hand, so we decode it properly with rxi/json.lua (MIT, vendored alongside
-- this file) loaded via `dofile` -- the supported include mechanism here.
--
-- The skin stays a pure PRESENTATION layer: it only READS state.json. Nothing in
-- Rainmeter runs the fetcher; Task Scheduler keeps state.json fresh (see README).

-- ── Module state ─────────────────────────────────────────────────────────────
local json            -- the decoder, set in Initialize()
local PATH = ''       -- absolute path to state.json, resolved in Initialize()
local ROWS = {}       -- normalized per-site rows (see build())
local UPDATED = ''    -- relative age string for the header ("3h ago")

-- Recommendation -> Rainmeter FontColor (R,G,B,A). Explicit map so the mapping is
-- obvious and reviewable; the GREY fallback covers Error / unexpected strings.
local GREY = '150,160,175,255'
local ACCENT = {
  ['BB+NB']   = '80,200,120,255',   -- green — broadband + narrowband viable
  ['NB only'] = '235,175,45,255',   -- amber — narrowband only
  ['Neither'] = '225,80,80,255',    -- red   — stand down
}

-- ── Pure helpers (no Rainmeter dependency — unit-testable with plain luajit) ──

-- Days from the civil date to 1970-01-01 (Howard Hinnant's algorithm). Pure
-- integer math — no os.time, so no DST/timezone interference.
local function daysFromCivil(y, m, d)
  y = (m <= 2) and (y - 1) or y
  local era = math.floor((y >= 0 and y or (y - 399)) / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * ((m > 2) and (m - 3) or (m + 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- The fetcher emits NAIVE-UTC ISO strings ("2026-06-04T07:00", no offset). We
-- convert UTC wall-time -> a real epoch with pure arithmetic (timegm), then let
-- os.date(epoch) render LOCAL time -- os.date IS reliably DST-aware for display;
-- it's os.time-on-a-table (mktime) that mishandles DST, which is why we never use
-- it here. Returns nil on a bad string.
local function utcEpoch(iso)
  if type(iso) ~= 'string' then return nil end
  local Y, Mo, D, H, Mi = iso:match('(%d+)-(%d+)-(%d+)T(%d+):(%d+)')
  if not Y then return nil end
  return daysFromCivil(tonumber(Y), tonumber(Mo), tonumber(D)) * 86400
    + tonumber(H) * 3600 + tonumber(Mi) * 60
end

-- UTC ISO -> local "11:30pm" / "12am". os.date localizes the real epoch (DST
-- correct); we then prettify: strip the leading zero, lowercase the meridiem, and
-- drop ":00".
local function localClock(iso)
  local e = utcEpoch(iso)
  if not e then return '' end
  local out = os.date('%I:%M%p', e):gsub('^0', ''):lower()
  return (out:gsub(':00(%a%a)$', '%1'))   -- "12:00am" -> "12am"; "11:30pm" stays
end

-- "3h ago" from the fetcher's lastUpdated. '' on bad input.
local function ago(iso)
  local e = utcEpoch(iso)
  if not e then return '' end
  local mins = math.floor((os.time() - e) / 60)
  if mins < 1 then return 'just now' end
  if mins < 60 then return mins .. 'm ago' end
  local hrs = math.floor(mins / 60 + 0.5)
  if hrs < 24 then return hrs .. 'h ago' end
  return math.floor(hrs / 24 + 0.5) .. 'd ago'
end

-- "Best clear: 11:30pm-1:00am" — shown ONLY when the clear stretch is a real gap
-- (best_window present AND shorter than ~85% of the dark window), matching the
-- plasmoid/desktop rule. '' otherwise (fully clear, or overcast = no window).
local function bestClear(night)
  local bw = night.best_window
  local dw = night.dark_window
  if type(bw) ~= 'table' or type(dw) ~= 'table' then return '' end
  local s = utcEpoch(bw.start)
  local e = utcEpoch(bw['end'])
  if not s or not e then return '' end
  local dwMin = tonumber(dw.duration_minutes) or 0
  if dwMin <= 0 or (e - s) / 60 >= dwMin * 0.85 then return '' end
  return 'Best clear: ' .. localClock(bw.start) .. '-' .. localClock(bw['end'])
end

-- Normalize a decoded state table into flat ROWS the meters consume. Pure +
-- testable: takes the decoded table, returns (rows, updatedString).
local function build(state)
  local rows = {}
  if type(state) ~= 'table' then return rows, '' end
  local updated = ago(state.lastUpdated or '')
  for _, site in ipairs(state.sites or {}) do
    local night = site.nights and site.nights[1] or nil
    local ok = site.status == 'ok' and night ~= nil
    local row = { label = site.label or site.id or '?', ok = ok, rec = 'Error' }
    if ok then
      row.rec = night.recommendation or 'Neither'
      row.bb = night.broadband and night.broadband.score or 0
      row.nb = night.narrowband and night.narrowband.score or 0
      row.managed = night.managed == true
      local df = night.displayFactors
      row.cloud = (type(df) == 'table') and df.cloudPct or nil
      row.best = bestClear(night)
      row.err = nil
    else
      row.err = site.error or 'No forecast tonight.'
    end
    rows[#rows + 1] = row
  end
  return rows, updated
end

-- ── Meter-facing accessors (called inline by meters; need DynamicVariables=1) ──
-- All return '' / GREY for an out-of-range slot so unused meter slots render
-- blank and the skin degrades gracefully when there are fewer sites than slots.

function Count() return #ROWS end
function Updated() return UPDATED end

-- Line A: "Bainbridge  [REMOTE]   Neither"
function LineA(i)
  local r = ROWS[tonumber(i)]
  if not r then return '' end
  return r.label .. (r.managed and '   [REMOTE]' or '') .. '   ' .. r.rec
end

-- Line B (detail): "BB 46   NB 40   94% cloud   Best clear: 11:30pm-1:00am"
-- or the error text for a failed site.
function LineB(i)
  local r = ROWS[tonumber(i)]
  if not r then return '' end
  if not r.ok then return r.err or '' end
  local s = 'BB ' .. r.bb .. '   NB ' .. r.nb
  if r.cloud ~= nil then s = s .. '   ' .. r.cloud .. '% cloud' end
  if r.best and r.best ~= '' then s = s .. '   ' .. r.best end
  return s
end

-- FontColor (R,G,B,A) for slot i, by recommendation.
function Color(i)
  local r = ROWS[tonumber(i)]
  if not r then return GREY end
  return ACCENT[r.rec] or GREY
end

-- Pixel height the skin background should cover: header + one block per site.
-- Header band is 40px; each site block is 36px (two text lines). Read with
-- DynamicVariables=1 so the background auto-sizes as the site count changes.
function SkinHeight() return 40 + #ROWS * 36 + 6 end

-- ── Rainmeter entry points ───────────────────────────────────────────────────

function Initialize()
  -- @Resources absolute path comes from the built-in '@' variable.
  json = dofile(SKIN:GetVariable('@') .. 'Scripts\\json.lua')
  -- STATEFILE may be overridden in the skin [Variables]; otherwise build the
  -- canonical Windows path: %LOCALAPPDATA%\cache\astrowidget\state.json (this is
  -- Qt's GenericCacheLocation on Windows — exactly where the fetcher writes).
  PATH = SKIN:GetVariable('STATEFILE', '')
  if PATH == '' then
    local lad = os.getenv('LOCALAPPDATA')
    if not lad then
      local up = os.getenv('USERPROFILE') or 'C:'
      lad = up .. '\\AppData\\Local'
    end
    PATH = lad .. '\\cache\\astrowidget\\state.json'
  end
end

function Update()
  local f = io.open(PATH, 'r')
  if not f then              -- fetcher hasn't written it yet
    ROWS, UPDATED = {}, ''
    return 0
  end
  local raw = f:read('*all')
  f:close()
  -- Decode defensively: a torn read (fetcher mid-write) makes decode throw; keep
  -- the last good frame instead of blanking the widget. The fetcher also writes
  -- atomically, so torn reads should be rare.
  local ok, state = pcall(function() return json.decode(raw) end)
  if not ok or type(state) ~= 'table' then
    return #ROWS
  end
  ROWS, UPDATED = build(state)
  return #ROWS
end

-- Exposed for the offline luajit test harness (test_state.lua); harmless in
-- Rainmeter (these globals are simply never read there). setRows lets the test
-- install a ROWS table so it can exercise the meter-facing accessors (LineA /
-- LineB / Color / Count), which read the module-local ROWS that Update() fills.
_TEST = {
  build = build, localClock = localClock, ago = ago, bestClear = bestClear,
  setRows = function(r, updated) ROWS = r or {}; UPDATED = updated or '' end,
}
