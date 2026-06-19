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

local log = Verditer.Log.for_module("death_recap")

-- state ───────────────────────────────────────────────────────────────────────
local deaths  = {}    -- recent deaths, oldest..newest, capped at RECAP.MAX_DEATHS
local sel_idx = 0     -- index currently shown in the window (1..#deaths)

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

local function commit(rec)
  deaths[#deaths + 1] = rec
  while #deaths > (C.RECAP.MAX_DEATHS or 5) do table_remove(deaths, 1) end
  sel_idx = #deaths
  log:info("death committed: attacks=", #rec.attacks, " killer=",
           rec.killer and rec.killer.name or "?")
  if Verditer.Recap then Verditer.Recap.show_record(sel_idx) end
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
      attackers = src_scratch.count or 0,
      types     = {},
    },
    attacks = {},
    killer  = nil,
    lead    = { count = 0 },             -- filled for real in increment 2
  }
  copy_types(rec.pressure.types, type_scratch)

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
  for i = 1, N do
    local f  = i / N
    local hp = math_max(0, 1.0 - f * f * 1.05)
    rec.lead[i] = {
      t    = now - (N - i) * 250,
      hp   = (i == N) and 0 or hp,
      dtps = 4000 + 14000 * f,
      abs  = (f < 0.7) and (2000 * (1 - f)) or 0,
    }
  end
  rec.lead.count        = N
  rec.lead.shield_break = math_floor(N * 0.7)

  commit(rec)
end

function M.init()
  ev.register("VerditerRecapDead", zc.EVENT_PLAYER_DEAD, on_player_dead)
  log:info("init")
end
