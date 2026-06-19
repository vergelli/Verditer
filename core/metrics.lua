Verditer = Verditer or {}
local Verditer = Verditer

Verditer.Metrics = {}

local M = Verditer.Metrics
local W_MS        = 5000
local W_SHIELD_MS = 30000

local dmg_in_buf  -- reached HP   (DTPS)
local abs_in_buf  -- ate by shield (ABS)
local event_pool
local log = Verditer.Log.for_module("metrics")

local DamageTypeColors
local SourcePalette
local GENERIC

-- health tracking (Survival views). hp_cur = latest fraction; hp_min = lowest
-- fraction seen since the last sample tick (the spike-preserving reducer,
-- HANDOFF §7 — never average the dip that nearly killed you). -1 = unknown.
local GetUnitPower
local HEALTH
local hp_cur, hp_min = -1, -1

-- Most recent lethal overflow (overkill) for the Death Recap. The killing hit is
-- the last dmg_in event carrying overflow>0; we keep it with its timestamp so the
-- recap can read "how far past dead" only if it's fresh (within a few seconds).
local last_overflow, last_overflow_ms = 0, 0

local pairs     = pairs
local math_floor = math.floor

function M.acquire_event()  return event_pool:acquire()   end
function M.release_event(ev) event_pool:release(ev)       end
function M.pool_in_use()    return event_pool:in_use()    end
function M.pool_capacity()  return event_pool:capacity()  end

local function release_to_pool(entry) event_pool:release(entry) end

function M.init()
  local MC = Verditer.Constants.METRICS or {}
  W_MS        = MC.DAMAGE_WINDOW_MS or 5000
  W_SHIELD_MS = MC.SHIELD_WINDOW_MS or 30000

  local cap  = (Verditer.Constants.POOL and Verditer.Constants.POOL.EVENT_CAPACITY) or 4096
  event_pool = Verditer.lib.mem.BufferPool.new(Verditer.lib.mem.Event.factory, cap, "event_pool")

  local RingBuffer = Verditer.lib.mem.RingBuffer
  dmg_in_buf = RingBuffer.new(W_MS,        2048, release_to_pool)
  abs_in_buf = RingBuffer.new(W_SHIELD_MS,  512, release_to_pool)

  DamageTypeColors = Verditer.DamageTypeColors
  SourcePalette    = Verditer.SourcePalette
  GENERIC = Verditer.zenimax.constants.DAMAGE_TYPE_GENERIC

  GetUnitPower = Verditer.zenimax.api.GetUnitPower
  HEALTH = Verditer.zenimax.constants.COMBAT_MECHANIC_FLAGS_HEALTH

  log:info("init: dmg_window=", W_MS, "ms abs_window=", W_SHIELD_MS, "ms pool=", cap)
end

-- Fed by EVENT_POWER_UPDATE (pipeline) to catch sub-tick dips between samples.
function M.note_health(value, max)
  if not max or max <= 0 then return end
  local f = value / max
  hp_cur = f
  if hp_min < 0 or f < hp_min then hp_min = f end
end

-- Called once per sample tick. Returns the MIN HP fraction over the interval
-- (the worst moment), then resets the window. Polls once for freshness in case
-- no EVENT_POWER_UPDATE fired this interval. Returns -1 if HP is unknown.
function M.hp_sample()
  if GetUnitPower then
    local cur, mx = GetUnitPower("player", HEALTH)
    if mx and mx > 0 then
      hp_cur = cur / mx
      if hp_min < 0 or hp_cur < hp_min then hp_min = hp_cur end
    end
  end
  local s = (hp_min >= 0) and hp_min or hp_cur
  hp_min = hp_cur                  -- reset the dip window to the current level
  return s
end

-- Flush any stale dip (e.g. before a fresh recording starts).
function M.hp_reset()
  if GetUnitPower then
    local cur, mx = GetUnitPower("player", HEALTH)
    if mx and mx > 0 then hp_cur = cur / mx end
  end
  hp_min = hp_cur
end

function M.set_window(ms)
  W_MS = ms or 5000
  dmg_in_buf.window_ms = W_MS
  log:info("dmg window ->", W_MS, "ms")
end

function M.set_shield_window(ms)
  W_SHIELD_MS = ms or 30000
  abs_in_buf.window_ms = W_SHIELD_MS
  log:info("abs window ->", W_SHIELD_MS, "ms")
end

function M.window_seconds() return W_MS / 1000 end

function M.ingest_dmg_in(ev)
  if ev.amount > 0 then
    if (ev.overflow or 0) > 0 then last_overflow = ev.overflow; last_overflow_ms = ev.t end
    dmg_in_buf:push(ev)
  else
    event_pool:release(ev)
  end
end

-- Death Recap helpers. recent_overflow returns the last lethal overkill if it
-- happened within max_age_ms (else 0); max_health is the player's max HP pool.
function M.recent_overflow(now_ms, max_age_ms)
  if last_overflow_ms > 0 and (now_ms - last_overflow_ms) <= (max_age_ms or 3000) then
    return last_overflow
  end
  return 0
end

function M.max_health()
  if GetUnitPower then
    local _cur, mx = GetUnitPower("player", HEALTH)
    if mx and mx > 0 then return mx end
  end
  return 0
end

-- Current HP fraction (0..1), polled fresh. Unlike hp_sample() this does NOT
-- touch hp_min — it's for the always-on Death Recap lead ring, which must not
-- disturb the graph's min-per-bucket reducer.
function M.hp_current()
  if GetUnitPower then
    local cur, mx = GetUnitPower("player", HEALTH)
    if mx and mx > 0 then return cur / mx end
  end
  return hp_cur
end

function M.ingest_abs_in(ev)
  if ev.amount > 0 then abs_in_buf:push(ev) else event_pool:release(ev) end
end

function M.DTPS(now_ms) return dmg_in_buf:sum(now_ms, "amount") / (W_MS        / 1000) end
function M.ABS(now_ms)  return abs_in_buf:sum(now_ms, "amount") / (W_SHIELD_MS / 1000) end
function M.ITP(now_ms)  return M.DTPS(now_ms) + M.ABS(now_ms)                          end

-- By-damage-type breakdown (View 2). Buckets landed (HP) damage by damage_type,
-- normalized to a share of total DTPS. Closed 13-key space, zero per-call alloc.
local accum_buckets = {}

local function accumulate_types(now_ms, buckets)
  for k in pairs(buckets) do buckets[k] = nil end   -- reset in place for zero alloc
  local ws    = W_MS / 1000
  local total = 0
  dmg_in_buf:trim(now_ms)
  for i = dmg_in_buf.head, dmg_in_buf.tail do
    local e   = dmg_in_buf.entries[i]
    local amt = e.amount or 0
    if amt > 0 then
      local r  = amt / ws
      local dt = e.damage_type or GENERIC
      buckets[dt] = (buckets[dt] or 0) + r
      total = total + r
    end
  end
  return total
end

function M.type_groups_into(out, now_ms)
  local buckets = accum_buckets
  local total   = accumulate_types(now_ms, buckets)
  local n = 0
  if total > 0 then
    for dt, val in pairs(buckets) do
      n = n + 1
      local slot = out[n]
      if not slot then slot = {}; out[n] = slot end
      local c = DamageTypeColors.lookup(dt)
      slot.r = c.r; slot.g = c.g; slot.b = c.b; slot.a = c.a
      slot.share = val / total
      slot.dt    = dt           -- kept for a future legend / hover
    end

    -- out is reused, so its tail holds stale slots from bigger calls.
    -- sort by hand over 1..n; table.sort would order #out and drag the tail in.
    for i = 2, n do
      local key = out[i]
      local j = i - 1
      while j >= 1 and out[j].share < key.share do
        out[j + 1] = out[j]
        j = j - 1
      end
      out[j + 1] = key
    end
  end
  out.count = n   -- readers loop 1..count, never #out
  return n
end

-- By-source breakdown (View 4, BACKLOG G). Buckets landed (HP) damage by
-- source_unit_id, normalized to a share of total DTPS, then folds the long tail
-- into one "Other" slot (top-N over an OPEN key space — the structural difference
-- from type_groups_into's fixed 13). The name is carried by reference for a future
-- legend; colour is the stable per-uid hash. Zero per-call alloc (scratch reused).
local accum_src_buckets = {}
local accum_src_names   = {}
local SOURCE_MAX = 8   -- top (SOURCE_MAX-1) attackers shown + 1 "Other" fold slot

local function accumulate_sources(now_ms, buckets, names)
  for k in pairs(buckets) do buckets[k] = nil end   -- reset in place (zero alloc)
  for k in pairs(names)   do names[k]   = nil end
  local ws    = W_MS / 1000
  local total = 0
  dmg_in_buf:trim(now_ms)
  for i = dmg_in_buf.head, dmg_in_buf.tail do
    local e   = dmg_in_buf.entries[i]
    local amt = e.amount or 0
    if amt > 0 then
      local r   = amt / ws
      local uid = e.source_unit_id or 0
      buckets[uid] = (buckets[uid] or 0) + r
      if names[uid] == nil then names[uid] = e.source_name or "" end
      total = total + r
    end
  end
  return total
end

function M.source_groups_into(out, now_ms)
  local buckets = accum_src_buckets
  local names   = accum_src_names
  local total   = accumulate_sources(now_ms, buckets, names)
  local n = 0
  if total > 0 then
    for uid, val in pairs(buckets) do
      n = n + 1
      local slot = out[n]
      if not slot then slot = {}; out[n] = slot end
      local c = SourcePalette.lookup(uid)
      slot.r = c.r; slot.g = c.g; slot.b = c.b; slot.a = c.a
      slot.share = val / total
      slot.uid   = uid
      slot.name  = names[uid] or ""
    end

    -- sort by share desc, by hand over 1..n (same reasoning as type_groups_into:
    -- table.sort would order #out and drag stale tail slots in).
    for i = 2, n do
      local key = out[i]
      local j = i - 1
      while j >= 1 and out[j].share < key.share do
        out[j + 1] = out[j]
        j = j - 1
      end
      out[j + 1] = key
    end

    -- top-N + Other fold: keep the top (SOURCE_MAX-1) attackers individually,
    -- collapse the remaining tail into one slate "Other" slot (uid = -1 sentinel).
    if n > SOURCE_MAX then
      local keep  = SOURCE_MAX - 1
      local other = 0
      for i = keep + 1, n do other = other + out[i].share end
      local slot = out[keep + 1]
      if not slot then slot = {}; out[keep + 1] = slot end
      local c = SourcePalette.OTHER
      slot.r = c.r; slot.g = c.g; slot.b = c.b; slot.a = c.a
      slot.share = other
      slot.uid   = -1
      slot.name  = "Other"
      n = SOURCE_MAX
    end
  end
  out.count = n   -- readers loop 1..count, never #out
  return n
end

function M.reset()
  log:info("reset: dmg_in=", dmg_in_buf:size(), "abs_in=", abs_in_buf:size(),
           "pool_in_use=", event_pool:in_use())
  dmg_in_buf:reset()
  abs_in_buf:reset()
end

function M.size_snapshot()
  return {
    dmg_in = dmg_in_buf:size(),
    abs_in = abs_in_buf:size(),
  }
end
