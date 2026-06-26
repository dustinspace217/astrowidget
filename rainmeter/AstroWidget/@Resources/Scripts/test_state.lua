-- test_state.lua — offline unit test for state.lua's parsing + formatting.
--
-- Rainmeter itself has no test runner, so we exercise the pure logic with a
-- standalone Lua interpreter. Run from this folder:
--     luajit test_state.lua      (or: lua5.1 test_state.lua)
-- Exits non-zero on any failure.
--
-- It uses a SYNTHETIC state.json (round-number coords — never a real site) that
-- covers the cases that matter: a HOME partly-cloudy night with a best-clear gap,
-- a REMOTE clear night (badge, no best-clear line), and an errored site.

local here = (arg[0] or 'test_state.lua'):gsub('[^/\\]+$', '')
local json = dofile(here .. 'json.lua')
dofile(here .. 'state.lua')           -- defines _TEST + the global accessors
local T = _TEST

local fails = 0
local function check(label, got, want)
  if tostring(got) ~= tostring(want) then
    fails = fails + 1
    print(string.format('FAIL  %s\n        got:  %s\n        want: %s', label, tostring(got), tostring(want)))
  else
    print('ok    ' .. label)
  end
end

-- ── Time helpers (PDT-independent: we assert against os.date of a known epoch so
--    the test passes in ANY timezone, not just the author's). ─────────────────
-- 2026-06-04T07:00Z as a real epoch, formatted the same way localClock should.
local epoch = T.localClock and nil
do
  -- Build the expected local string the same way localClock does, but from a
  -- timegm we trust here, so the assertion is timezone-agnostic.
  local function expect(iso)
    local Y,Mo,D,H,Mi = iso:match('(%d+)-(%d+)-(%d+)T(%d+):(%d+)')
    -- days-from-civil (same as state.lua) → epoch → os.date local
    local function dfc(y,m,d) y=(m<=2) and y-1 or y; local era=math.floor((y>=0 and y or y-399)/400)
      local yoe=y-era*400; local doy=math.floor((153*((m>2) and m-3 or m+9)+2)/5)+d-1
      local doe=yoe*365+math.floor(yoe/4)-math.floor(yoe/100)+doy; return era*146097+doe-719468 end
    local e=dfc(tonumber(Y),tonumber(Mo),tonumber(D))*86400+tonumber(H)*3600+tonumber(Mi)*60
    local out=os.date('%I:%M%p', e):gsub('^0',''):lower()
    return (out:gsub(':00(%a%a)$','%1'))
  end
  check('localClock 07:00Z', T.localClock('2026-06-04T07:00'), expect('2026-06-04T07:00'))
  check('localClock 06:30Z', T.localClock('2026-06-04T06:30'), expect('2026-06-04T06:30'))
  check('localClock bad input', T.localClock('nonsense'), '')
end

-- ── bestClear: show a real gap, hide a near-full or absent window. ────────────
check('bestClear: 1.5h gap in 6h dark shows',
  T.bestClear({ dark_window={duration_minutes=360},
                best_window={start='2026-06-04T07:30', ['end']='2026-06-04T09:00'} }) ~= '', true)
check('bestClear: near-full window hidden',
  T.bestClear({ dark_window={duration_minutes=360},
                best_window={start='2026-06-04T06:00', ['end']='2026-06-04T11:30'} }), '')
check('bestClear: null window hidden',
  T.bestClear({ dark_window={duration_minutes=360}, best_window=nil }), '')

-- ── build(): a synthetic 3-site state. ───────────────────────────────────────
local FIXTURE = [[
{
  "schemaVersion": 2,
  "lastUpdated": "2026-06-04T05:00",
  "sites": [
    { "id": "home", "label": "Backyard", "status": "ok",
      "nights": [ { "label": "Tonight", "recommendation": "NB only",
        "broadband": { "score": 48 }, "narrowband": { "score": 71 },
        "managed": false,
        "dark_window": { "duration_minutes": 360 },
        "best_window": { "start": "2026-06-04T07:30", "end": "2026-06-04T09:00" },
        "displayFactors": { "cloudPct": 62, "seeing": { "label": "Good" } } } ] },
    { "id": "dome", "label": "Remote Dome", "status": "ok",
      "nights": [ { "label": "Tonight", "recommendation": "BB+NB",
        "broadband": { "score": 88 }, "narrowband": { "score": 93 },
        "managed": true,
        "dark_window": { "duration_minutes": 600 }, "best_window": null,
        "displayFactors": { "cloudPct": 3 },
        "smoke": { "aodMean": 0.12, "firesNearby": { "count": 4, "nearestKm": 60, "radiusKm": 150 } } } ] },
    { "id": "down", "label": "Offline Site", "status": "error",
      "error": "API failure", "nights": [] }
  ]
}
]]

local state = json.decode(FIXTURE)
local rows = T.build(state)
check('build: site count', #rows, 3)
check('build: site1 ok', rows[1].ok, true)
check('build: site1 rec', rows[1].rec, 'NB only')
check('build: site1 bb', rows[1].bb, 48)
check('build: site1 cloud', rows[1].cloud, 62)
check('build: site1 not managed', rows[1].managed, false)
check('build: site1 best non-empty', rows[1].best ~= '', true)
check('build: site2 managed', rows[2].managed, true)
check('build: site2 best hidden (clear)', rows[2].best, '')
check('build: site2 aod', rows[2].aod, 0.12)
check('build: site2 fireCount', rows[2].fireCount, 4)
check('build: site3 not ok', rows[3].ok, false)
check('build: site3 error text', rows[3].err, 'API failure')

-- ── Meter-facing accessors: install the built rows, then assert the exact
--    strings/colors the meters will render. ─────────────────────────────────────
T.setRows(rows, T.ago(state.lastUpdated))
check('Count()', Count(), 3)
check('LineA(1) plain', LineA(1), 'Backyard   NB only')
check('LineA(2) REMOTE badge', LineA(2), 'Remote Dome   [REMOTE]   BB+NB')
check('LineB(1) detail', LineB(1):match('^BB 48   NB 71   62%% cloud   Best clear:') ~= nil, true)
check('LineB(2) clear + fire/AOD', LineB(2), 'BB 88   NB 93   3% cloud   ! 4 fires 60km   AOD 0.12')
check('LineB(3) shows error', LineB(3), 'API failure')
check('Color(1) amber (NB only)', Color(1), '235,175,45,255')
check('Color(2) green (BB+NB)', Color(2), '80,200,120,255')
check('Color(3) grey (error)', Color(3), '150,160,175,255')
check('LineA(9) out-of-range empty', LineA(9), '')

if fails == 0 then
  print('\nALL PASS')
  os.exit(0)
else
  print(string.format('\n%d FAILURE(S)', fails))
  os.exit(1)
end
