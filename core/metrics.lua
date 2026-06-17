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
local GENERIC

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
  GENERIC = Verditer.zenimax.constants.DAMAGE_TYPE_GENERIC

  log:info("init: dmg_window=", W_MS, "ms abs_window=", W_SHIELD_MS, "ms pool=", cap)
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
  if ev.amount > 0 then dmg_in_buf:push(ev) else event_pool:release(ev) end
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
