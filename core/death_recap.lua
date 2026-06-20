--* core/death_recap.lua  (BACKLOG C — the soul)
--*
--* Captures a rich death recap by fusing TWO sources:
--*   1. the server's authoritative killing-attacks list (clean ability names +
--*      icons + attacker identity), read ~2 s after EVENT_PLAYER_DEAD, and
--*   2. our own metrics snapshot taken AT the instant of death (DTPS/ABS/by-type
--*      pressure + overkill), before the rolling windows decay.
--*
--* This module owns the data model + a small ring of recent deaths for prev/next
--* navigation. The window (`ui/recap.lua`) renders a record; it is source-agnostic
--* so the DEBUG `simulate()` (synthetic record) previews the full layout with no
--* death. The lead-up "film" (rec.lead) is synthetic for now; the always-on ring
--* that feeds it for real is increment 2 (BACKLOG C / SPEC §lead-up).

Verditer = Verditer or {}
local Verditer = Verditer

Verditer.DeathRecap = {}
local M = Verditer.DeathRecap

local api = Verditer.zenimax.api
local zc  = Verditer.zenimax.constants
local ev  = Verditer.zenimax.events
local C   = Verditer.Constants

local GetGameTimeMilliseconds       = api.GetGameTimeMilliseconds
local GetNumKillingAttacks          = api.GetNumKillingAttacks
local GetKillingAttackInfo          = api.GetKillingAttackInfo
local DoesKillingAttackHaveAttacker = api.DoesKillingAttackHaveAttacker
local GetKillingAttackerInfo        = api.GetKillingAttackerInfo
local IsUnitDead                    = api.IsUnitDead
local GetCurrentMapZoneIndex        = api.GetCurrentMapZoneIndex
local GetZoneNameByIndex            = api.GetZoneNameByIndex

local table_sort  = table.sort
local table_remove = table.remove
local math_max    = math.max
local math_floor  = math.floor
local math_ceil   = math.ceil

local log = Verditer.Log.for_module("death_recap")

-- state ───────────────────────────────────────────────────────────────────────
local deaths  = {}    -- recent deaths, oldest..newest, capped at RECAP.MAX_DEATHS
local sel_idx = 0     -- index currently shown in the window (1..#deaths)

-- always-on lead-up ring: samples HP/DTPS/ABS at a fixed cadence so a death can
-- freeze the last LEAD_SECONDS as the recap "film" — independent of whether the
-- user is Recording. Slots are mutated in place (no per-tick alloc).
local lead_ring = {}
local lead_cap, lead_ms = 0, 250
local lead_w, lead_n = 1, 0

-- pressure snapshot scratch (reused; copied into each record)
local type_scratch = { count = 0 }
local src_scratch  = { count = 0 }

local function current_zone()
  if GetCurrentMapZoneIndex and GetZoneNameByIndex then
    local idx = GetCurrentMapZoneIndex()
    if idx then
      local n = GetZoneNameByIndex(idx)
      if n and n ~= "" then return zo_strformat("<<1>>", n) end
    end
  end
  return ""
end

-- Count real attackers in a source-group scratch: exclude the environment/self
-- bucket (uid 0 = fall/lava/trap) so "# attackers" means enemies, not hazards.
-- The "Other" fold (uid -1) is a real-attacker remainder, so it counts as ≥1.
local function count_attackers(scratch)
  local c = 0
  for i = 1, (scratch.count or 0) do
    local g = scratch[i]
    if g and g.uid ~= 0 then c = c + 1 end
  end
  return c
end

local function copy_types(out_arr, scratch)
  local n = scratch.count or 0
  for i = 1, n do
    local s = scratch[i]
    local dst = out_arr[i]
    if not dst then dst = {}; out_arr[i] = dst end
    dst.r = s.r; dst.g = s.g; dst.b = s.b; dst.a = s.a; dst.share = s.share; dst.dt = s.dt
  end
  out_arr.count = n
end

-- Clean attacker label from the server attacker tuple (PvP names carry ^Mx markup
-- and realm codes; players prefer the primary @account/character name).
local function attacker_name(i)
  local rawName, _cp, _lvl, _ava, isPlayer, _isBoss, _alliance, minionName, displayName
        = GetKillingAttackerInfo(i)
  local nm
  if isPlayer and ZO_GetPrimaryPlayerName then
    nm = ZO_GetPrimaryPlayerName(displayName, rawName)
  else
    nm = rawName
  end
  nm = nm or ""
  if nm ~= "" then nm = zo_strformat(SI_UNIT_NAME, nm) end
  if (minionName or "") ~= "" then
    nm = nm .. " (" .. zo_strformat(SI_UNIT_NAME, minionName) .. ")"
  end
  return nm
end

-- always-on lead ring tick (registered in init, runs forever, very cheap)
local function lead_tick()
  local now     = GetGameTimeMilliseconds()
  local Metrics = Verditer.Metrics
  local slot    = lead_ring[lead_w]
  slot.t    = now
  slot.hp   = Metrics.hp_current()
  slot.dtps = Metrics.DTPS(now)
  slot.abs  = Metrics.ABS(now)
  lead_w = (lead_w % lead_cap) + 1
  if lead_n < lead_cap then lead_n = lead_n + 1 end
end

-- Freeze the ring (oldest..newest) into rec.lead at the death instant. Also
-- derives the TRUE peak DTPS over the window and the shield-break frame (the last
-- sample where ABS was still being eaten — the moment the shield collapsed).
local function freeze_lead(rec)
  local lead   = rec.lead
  local n      = lead_n
  local cap    = lead_cap
  local oldest = (n >= cap) and lead_w or 1
  local peak, last_shield = 0, 0
  local prev_hp = -1
  for i = 1, n do
    local idx = ((oldest - 1 + i - 1) % cap) + 1
    local s   = lead_ring[idx]
    local d   = lead[i]
    if not d then d = {}; lead[i] = d end
    d.t = s.t; d.hp = s.hp; d.dtps = s.dtps; d.abs = s.abs
    -- fresh HP lost this frame = the drop from the previous sample. Drawn as a red
    -- band capping the green silhouette (the chunk torn off that 250 ms).
    local hp = s.hp or 0
    d.hp_drop = (prev_hp >= 0 and hp >= 0) and math_max(0, prev_hp - hp) or 0
    prev_hp = hp
    if (s.dtps or 0) > peak then peak = s.dtps end
    if (s.abs or 0) > 0 then last_shield = i end
  end

  -- Append an exact hp=0 frame at the death instant. The 250 ms ring rarely lands
  -- on the exact moment of death, so the silhouette would otherwise stop short of
  -- the floor. This final frame plunges to 0; its hp_drop = the last living HP, so
  -- the killing fall reads as a tall red column reaching down to where HP was.
  if n > 0 then
    local last = lead[n]
    local zi   = n + 1
    local d    = lead[zi]
    if not d then d = {}; lead[zi] = d end
    d.t       = (last.t or 0) + lead_ms
    d.hp      = 0
    d.dtps    = last.dtps or 0
    d.abs     = 0
    d.hp_drop = math_max(0, last.hp or 0)
    n = zi
  end

  lead.count        = n
  lead.shield_break = (last_shield > 0 and last_shield < n) and last_shield or nil
  if peak > 0 and rec.pressure then rec.pressure.peak_dtps = peak end
end

local function commit(rec)
  deaths[#deaths + 1] = rec
  while #deaths > (C.RECAP.MAX_DEATHS or 5) do table_remove(deaths, 1) end
  sel_idx = #deaths
  log:info("death committed: attacks=", #rec.attacks, " killer=",
           rec.killer and rec.killer.name or "?")
  if Verditer.Recap then Verditer.Recap.show_record(sel_idx) end
  -- a new death exists → make the graph's "Deaths" browser button discoverable
  if Verditer.Graph and Verditer.Graph.notify_deaths_changed then
    Verditer.Graph.notify_deaths_changed()
  end
end

-- Read the server killing-attacks list and finalize the pending record.
local function finalize(rec)
  local n = GetNumKillingAttacks and GetNumKillingAttacks() or 0
  local cap = C.RECAP.MAX_ATTACKS or 6
  for i = 1, n do
    local name, dmg, icon, kb, _castAgo, _dur, hits = GetKillingAttackInfo(i)
    local who = ""
    if DoesKillingAttackHaveAttacker and DoesKillingAttackHaveAttacker(i) then
      who = attacker_name(i)
    end
    rec.attacks[#rec.attacks + 1] = {
      name     = name or "",
      icon     = icon,
      dmg      = dmg or 0,
      kb       = kb and true or false,
      hits     = hits or 1,
      attacker = who,
    }
  end

  -- biggest hits first; the killing blow is flagged but not forced to the top
  table_sort(rec.attacks, function(a, b) return a.dmg > b.dmg end)
  while #rec.attacks > cap do table_remove(rec.attacks) end

  -- verdict = the killing blow (fallback: biggest hit)
  local verdict
  for i = 1, #rec.attacks do
    if rec.attacks[i].kb then verdict = rec.attacks[i]; break end
  end
  rec.killer = verdict or rec.attacks[1]

  commit(rec)
end

local function on_player_dead()
  if not (IsUnitDead and IsUnitDead("player")) then return end
  local now     = GetGameTimeMilliseconds()
  local Metrics = Verditer.Metrics

  Metrics.type_groups_into(type_scratch, now)
  Metrics.source_groups_into(src_scratch, now)
  local maxhp    = Metrics.max_health()
  local overkill = Metrics.recent_overflow(now, 3000)

  local rec = {
    ts           = now,
    zone         = current_zone(),
    overkill_pct = (maxhp > 0 and overkill > 0) and (overkill / maxhp) or 0,
    pressure     = {
      dtps      = Metrics.DTPS(now),
      abs       = Metrics.ABS(now),
      peak_dtps = Metrics.DTPS(now),     -- true peak needs the lead ring (incr. 2)
      attackers = count_attackers(src_scratch),   -- enemies only (env bucket excluded)
      types     = {},
    },
    attacks = {},
    killer  = nil,
    lead    = {},
  }
  copy_types(rec.pressure.types, type_scratch)
  freeze_lead(rec)   -- snapshot the lead-up film AT the death instant

  -- the server list is only readable after the engine's delay; one-shot timer
  ev.register_update("VerditerRecapServerRead", C.RECAP.SERVER_DELAY_MS, function()
    ev.unregister_update("VerditerRecapServerRead")
    finalize(rec)
  end)
end

-- navigation API for the window ─────────────────────────────────────────────────
function M.count()        return #deaths        end
function M.get(idx)       return deaths[idx]    end
function M.selected_idx() return sel_idx        end
function M.select(idx)
  if idx >= 1 and idx <= #deaths then sel_idx = idx; return true end
  return false
end

-- Drop every recorded death. A "session" = ONE recording (Record → Stop/Flush),
-- so Flush ends the session and its recaps belong to it: discard them to free
-- memory (they live in their own ring, independent of the metrics FIFO). Closes
-- the window if it was showing a now-gone death and updates the graph button.
function M.clear()
  for i = #deaths, 1, -1 do deaths[i] = nil end
  sel_idx = 0
  if Verditer.Recap and Verditer.Recap.on_close then Verditer.Recap.on_close() end
  if Verditer.Graph and Verditer.Graph.notify_deaths_changed then
    Verditer.Graph.notify_deaths_changed()
  end
  log:info("deaths cleared")
end

-- Respawn: keep the recap visible WHILE dead, but hide it the moment we revive.
-- (Hide only — the ring is NOT cleared here; Flush owns clearing, see M.clear.)
local function on_player_alive()
  if Verditer.Recap and Verditer.Recap.on_close then Verditer.Recap.on_close() end
end

-- DEBUG: synthesize a believable death so the window can be previewed with no
-- actual death (probe-first discipline). Includes a fake lead-up film.
function M.simulate()
  local now = GetGameTimeMilliseconds()
  local DTC = Verditer.DamageTypeColors
  local function tcol(dt, share)
    local c = DTC.lookup(dt)
    return { r = c.r, g = c.g, b = c.b, a = c.a, share = share, dt = dt }
  end
  local ICON_KB = "/esoui/art/treeicons/collection_indexicon_armor_down.dds"
  local ICON    = "/esoui/art/treeicons/collection_indexicon_armor_up.dds"

  local rec = {
    ts = now, zone = "Cyrodiil",
    overkill_pct = 1.40,
    pressure = {
      dtps = 14213, abs = 2105, peak_dtps = 18420, attackers = 3,
      types = {
        tcol(zc.DAMAGE_TYPE_SHOCK,    0.44),
        tcol(zc.DAMAGE_TYPE_MAGIC,    0.31),
        tcol(zc.DAMAGE_TYPE_PHYSICAL, 0.18),
        tcol(zc.DAMAGE_TYPE_POISON,   0.07),
      },
    },
    attacks = {
      { name = "Crushing Shock",  icon = ICON_KB, dmg = 8420, kb = true,  hits = 1, attacker = "Nightblade Assassin" },
      { name = "Surprise Attack", icon = ICON,    dmg = 6110, kb = false, hits = 2, attacker = "Nightblade Assassin" },
      { name = "Soul Assault",    icon = ICON,    dmg = 4300, kb = false, hits = 4, attacker = "Sorcerer Bomber"     },
      { name = "Fall Damage",     icon = ICON,    dmg = 1200, kb = false, hits = 1, attacker = ""                    },
    },
    lead = {},
  }
  rec.pressure.types.count = 4
  rec.killer = rec.attacks[1]

  -- synthetic lead-up film: HP accelerating to 0, shield gone at ~70% through
  local N = 40
  local prev = -1
  for i = 1, N do
    local f  = i / N
    local hp = math_max(0, 1.0 - f * f * 1.05)
    if i == N then hp = 0 end
    rec.lead[i] = {
      t       = now - (N - i) * 250,
      hp      = hp,
      dtps    = 4000 + 14000 * f,
      abs     = (f < 0.7) and (2000 * (1 - f)) or 0,
      hp_drop = (prev >= 0) and math_max(0, prev - hp) or 0,
    }
    prev = hp
  end
  rec.lead.count        = N
  rec.lead.shield_break = math_floor(N * 0.7)

  commit(rec)
end

function M.init()
  -- size + start the always-on lead ring
  lead_ms  = C.RECAP.LEAD_SAMPLE_MS or 250
  lead_cap = math_max(2, math_ceil((C.RECAP.LEAD_SECONDS or 10) * 1000 / lead_ms))
  for i = 1, lead_cap do lead_ring[i] = { t = 0, hp = -1, dtps = 0, abs = 0 } end
  lead_w, lead_n = 1, 0
  ev.register_update("VerditerRecapLead", lead_ms, lead_tick)

  ev.register("VerditerRecapDead", zc.EVENT_PLAYER_DEAD, on_player_dead)
  ev.register("VerditerRecapAlive", zc.EVENT_PLAYER_ALIVE, on_player_alive)
  log:info("init: lead ring cap=", lead_cap, " @", lead_ms, "ms")
end
