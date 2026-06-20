--* core/gc.lua  (APOD lever #3 — GC pacing, addresses F6)
--*
--* The Assess proved the everyday hitches are Lua GC ATOMIC pauses landing inside
--* render frames (F6: budget breaches with a negative heap-delta = a collection ran
--* mid-render). Lua's incremental collector only steps when the heap crosses a
--* threshold, so it bursts. The fix (lua-users "GC In Real-Time Games") is to drive a
--* small step every frame so the collector stays ahead and never needs a big pause.
--*
--* Conservative + tunable (Constants.GC). Ships in release (it's a real optimization,
--* not DEBUG-only), but is instrumented so /verditer report can show whether it helps:
--* re-run the F6 BG test and compare budget-breach count / fps min vs the pre-pacing
--* baseline. Flip Constants.GC.PACING=false to A/B.

Verditer = Verditer or {}
local Verditer = Verditer

Verditer.GC = {}
local M = Verditer.GC

local collectgarbage = collectgarbage

local C        = Verditer.Constants.GC or {}
local ENABLED  = (C.PACING ~= false)
local STEP_KB  = C.STEP_KB     or 2
local INTERVAL = C.INTERVAL_MS or 0

local steps, cycles = 0, 0

-- one small GC step; returns true (counted) when a full cycle completes
local function tick()
  steps = steps + 1
  if collectgarbage("step", STEP_KB) then cycles = cycles + 1 end
end

function M.init()
  steps, cycles = 0, 0
  if not ENABLED then return end
  Verditer.zenimax.events.register_update("VerditerGCStep", INTERVAL, tick)
end

-- (DEBUG visibility) steps driven + cycles completed since init
function M.stats() return steps, cycles, ENABLED end

function M.report_lines()
  return { string.format("[gc] pacing=%s step=%dKB interval=%dms  steps=%d cycles=%d",
                         tostring(ENABLED), STEP_KB, INTERVAL, steps, cycles) }
end
