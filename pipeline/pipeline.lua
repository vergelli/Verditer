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
local ACTION_RESULT_DAMAGE_SHIELDED   = C.ACTION_RESULT_DAMAGE_SHIELDED

local Log = Verditer.Log.for_module("pipeline")

local prof_enter = Verditer.Profiler.enter
local prof_exit  = Verditer.Profiler.exit

local function bump(key) Verditer.Diagnostics.bump(key) end

local function release(ev)
  if ev then Verditer.Metrics.release_event(ev) end
end

local now = Acquisition.now

-- R_land membership (SPEC §4.1): reached HP. BLOCKED_DAMAGE = residual after a
-- partial block; full BLOCK arrives with hit=0 and is dropped by the hit guard.
local function is_landed(r)
  return r == ACTION_RESULT_DAMAGE
      or r == ACTION_RESULT_DOT_TICK
      or r == ACTION_RESULT_CRITICAL_DAMAGE
      or r == ACTION_RESULT_DOT_TICK_CRITICAL
      or r == ACTION_RESULT_BLOCKED_DAMAGE
end

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

  -- Subscription A: landed incoming damage (reached HP). One registration with
  -- an in-handler result switch (cf. §15.6: vs per-result registration; measure
  -- which is cheaper live). Hardware-filtered to TARGET = the local player.
  E.register("Verditer_E_DmgIn", EVENT_COMBAT_EVENT, function(...)
    local r = ...
    if is_landed(r) then M.dispatch_dmg_in(...) end
  end)
  E.add_filter("Verditer_E_DmgIn", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_TARGET_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
  E.add_filter("Verditer_E_DmgIn", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_IS_ERROR, false)

  -- Subscription B: shielded (the player's own shield absorbing).
  E.register("Verditer_E_AbsIn", EVENT_COMBAT_EVENT, M.dispatch_abs_in)
  E.add_filter("Verditer_E_AbsIn", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_COMBAT_RESULT, ACTION_RESULT_DAMAGE_SHIELDED)
  E.add_filter("Verditer_E_AbsIn", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_TARGET_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
  E.add_filter("Verditer_E_AbsIn", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_IS_ERROR, false)

  Log:info("init complete; 2 combat-event handlers registered (TARGET=PLAYER)")
end
