---* Event Pipeline Orchestrator.
---*
---* Isolates the core logic from the noise of the raw ZOS API. Handles the raw
---* ingest, fast-fail validation (errors, zero-hits, active modes), diagnostic
---* counters, and drives an event through its three phases:
---* Acquisition -> Filter -> Processing.
---*
---* The pivotal difference from Vermilion: the subscription filter is
---* REGISTER_FILTER_TARGET_COMBAT_UNIT_TYPE = COMBAT_UNIT_TYPE_PLAYER (incoming),
---* not SOURCE (outgoing). Entry points:
---*   M.dispatch_dmg_in - incoming damage that reached the player's HP.
---*   M.dispatch_abs_in - incoming damage absorbed by the player's own shield.
---*   M.init            - bootstraps ZOS subscriptions and API hardware filters.

Verditer = Verditer or {}
local Verditer = Verditer

Verditer.Pipeline = Verditer.Pipeline or {}
local M = Verditer.Pipeline

local Acquisition = Verditer.Pipeline.Acquisition
local Filter      = Verditer.Pipeline.Filter
local Processing  = Verditer.Pipeline.Processing

local C = Verditer.zenimax.constants
local EVENT_COMBAT_EVENT          = C.EVENT_COMBAT_EVENT
local REGISTER_FILTER_TARGET_COMBAT_UNIT_TYPE = C.REGISTER_FILTER_TARGET_COMBAT_UNIT_TYPE
local REGISTER_FILTER_COMBAT_RESULT           = C.REGISTER_FILTER_COMBAT_RESULT
local REGISTER_FILTER_IS_ERROR                = C.REGISTER_FILTER_IS_ERROR
local COMBAT_UNIT_TYPE_PLAYER     = C.COMBAT_UNIT_TYPE_PLAYER
local ACTION_RESULT_DAMAGE            = C.ACTION_RESULT_DAMAGE
local ACTION_RESULT_DOT_TICK          = C.ACTION_RESULT_DOT_TICK
local ACTION_RESULT_CRITICAL_DAMAGE   = C.ACTION_RESULT_CRITICAL_DAMAGE
local ACTION_RESULT_DOT_TICK_CRITICAL = C.ACTION_RESULT_DOT_TICK_CRITICAL
local ACTION_RESULT_BLOCKED_DAMAGE    = C.ACTION_RESULT_BLOCKED_DAMAGE
local ACTION_RESULT_FALL_DAMAGE       = C.ACTION_RESULT_FALL_DAMAGE
local ACTION_RESULT_DAMAGE_SHIELDED   = C.ACTION_RESULT_DAMAGE_SHIELDED

local Log = Verditer.Log.for_module("pipeline")

local prof_enter = Verditer.Profiler.enter
local prof_exit  = Verditer.Profiler.exit

local function bump(key) Verditer.Diagnostics.bump(key) end

local function release(ev)
  if ev then Verditer.Metrics.release_event(ev) end
end

local now = Acquisition.now

-- R_land (SPEC §4.1, validated by the live probe 2026-06-17): the incoming
-- results that reach HP. We register ONE hardware-filtered subscription per code
-- (below) so the C engine drops the ~90% non-damage stream (buffs/heals/effects/
-- snares) BEFORE it ever wakes our Lua — strictly less main-thread work than a
-- single unfiltered handler filtering in Lua. LibCombat does the same; this
-- resolves SPEC §15.6. BLOCKED_DAMAGE = residual after a partial block; a full
-- BLOCK arrives with hit=0 and is dropped by the hit>0 guard anyway.
-- FALL_DAMAGE is included (probe 2026-06-17 caught FALL=2420 in a BG): a survival
-- tool should count "the fall hit me". It is self/environmental — the filter
-- tags it (source<=0) for the future env/self split, but it still counts in DTPS.
local LANDED_RESULTS = {
  ACTION_RESULT_DAMAGE,
  ACTION_RESULT_DOT_TICK,
  ACTION_RESULT_CRITICAL_DAMAGE,
  ACTION_RESULT_DOT_TICK_CRITICAL,
  ACTION_RESULT_BLOCKED_DAMAGE,
  ACTION_RESULT_FALL_DAMAGE,
}

local function run_stages(ev, accepted_key)
  if not ev then
    bump("engine.pool.exhausted")
    Log:warn("event pool exhausted")
    return
  end
  prof_enter("pipeline.combat_event.filter")
  local allowed = Filter.allow(ev)
  prof_exit("pipeline.combat_event.filter")
  if allowed then
    bump(accepted_key)
    prof_enter("pipeline.combat_event.processing")
    Processing.process(ev)
    prof_exit("pipeline.combat_event.processing")
  else
    release(ev)
  end
end

-- handler arg order (after eventCode, which the events façade swallows):
-- result, isError, abilityName, abilityGraphic, abilityActionSlotType,
-- sourceName, sourceType, targetName, targetType, hitValue, powerType,
-- damageType, log, sourceUnitId, targetUnitId, abilityId, overflow
function M.dispatch_dmg_in(result, isError, _name, _g, _slot,
                           _src, _srcType, _tgt, _tgtType, hit,
                           _pt, damageType, _log, sourceUnitId, _tgtUid, abilityId, overflow)
  prof_enter("pipeline.combat_event")
  bump("engine.dmg_in.in")
  if isError then bump("engine.dmg_in.dropped_error") prof_exit("pipeline.combat_event") return end
  if (hit or 0) <= 0 then bump("engine.dmg_in.dropped_noise") prof_exit("pipeline.combat_event") return end
  if not Verditer.Mode.uses("dmg_in") then
    bump("engine.dmg_in.dropped_mode") prof_exit("pipeline.combat_event") return
  end

  local t = now()
  prof_enter("pipeline.combat_event.acquisition")
  local ev = Acquisition.acquire_dmg_in(t, hit, sourceUnitId, damageType, abilityId, result, overflow)
  prof_exit("pipeline.combat_event.acquisition")
  run_stages(ev, "engine.dmg_in.accepted")
  prof_exit("pipeline.combat_event")
end

function M.dispatch_abs_in(result, isError, _name, _g, _slot,
                           _src, _srcType, _tgt, _tgtType, hit,
                           _pt, damageType, _log, sourceUnitId, _tgtUid, abilityId)
  prof_enter("pipeline.combat_event")
  bump("engine.abs_in.in")
  if isError then bump("engine.abs_in.dropped_error") prof_exit("pipeline.combat_event") return end
  if (hit or 0) <= 0 then bump("engine.abs_in.dropped_noise") prof_exit("pipeline.combat_event") return end
  if not Verditer.Mode.uses("abs_in") then
    bump("engine.abs_in.dropped_mode") prof_exit("pipeline.combat_event") return
  end

  local t = now()
  prof_enter("pipeline.combat_event.acquisition")
  local ev = Acquisition.acquire_abs_in(t, hit, sourceUnitId, damageType, abilityId)
  prof_exit("pipeline.combat_event.acquisition")
  run_stages(ev, "engine.abs_in.accepted")
  prof_exit("pipeline.combat_event")
end

function M.init()
  local E = Verditer.zenimax.events

  Verditer.Diagnostics.init()
  Verditer.Metrics.init()

  -- Subscription set A: landed incoming damage (reached HP). ONE hardware-
  -- filtered registration per result code — the engine filters in C, so our
  -- handler only wakes for actual damage (not the buff/heal/effect flood). Each
  -- is also filtered to TARGET = the local player and non-error.
  for i = 1, #LANDED_RESULTS do
    local name = "Verditer_E_DmgIn" .. i
    E.register(name, EVENT_COMBAT_EVENT, M.dispatch_dmg_in)
    E.add_filter(name, EVENT_COMBAT_EVENT,
      REGISTER_FILTER_COMBAT_RESULT, LANDED_RESULTS[i])
    E.add_filter(name, EVENT_COMBAT_EVENT,
      REGISTER_FILTER_TARGET_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
    E.add_filter(name, EVENT_COMBAT_EVENT,
      REGISTER_FILTER_IS_ERROR, false)
  end

  -- Subscription B: shielded (the player's own shield absorbing).
  E.register("Verditer_E_AbsIn", EVENT_COMBAT_EVENT, M.dispatch_abs_in)
  E.add_filter("Verditer_E_AbsIn", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_COMBAT_RESULT, ACTION_RESULT_DAMAGE_SHIELDED)
  E.add_filter("Verditer_E_AbsIn", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_TARGET_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
  E.add_filter("Verditer_E_AbsIn", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_IS_ERROR, false)

  -- Subscription C: player health, for the Survival views. Event-driven (catches
  -- sub-tick dips); the graph also polls at the sample tick. Filtered to the
  -- player's health power only.
  E.register("Verditer_E_HealthIn", C.EVENT_POWER_UPDATE, function(_unitTag, _idx, _ptype, value, maxv)
    Verditer.Metrics.note_health(value, maxv)
  end)
  E.add_filter("Verditer_E_HealthIn", C.EVENT_POWER_UPDATE,
    C.REGISTER_FILTER_UNIT_TAG, "player")
  E.add_filter("Verditer_E_HealthIn", C.EVENT_POWER_UPDATE,
    C.REGISTER_FILTER_POWER_TYPE, C.COMBAT_MECHANIC_FLAGS_HEALTH)

  Log:info("init complete; ", #LANDED_RESULTS, " landed + 1 shielded + 1 health handlers registered (hardware-filtered, TARGET=PLAYER)")
end
