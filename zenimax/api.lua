--* ZOS API surface used by Verditer. Functions are forwarded by value
--* (M.X = X), captured at module load — same call cost as the bare global with
--* the wrapper benefit of a namespace. Consumers may local-cache hot-path entries:
--*   local GetGameTimeMs = Verditer.zenimax.api.GetGameTimeMilliseconds

Verditer = Verditer or {}
Verditer.zenimax = Verditer.zenimax or {}
local Verditer = Verditer

Verditer.zenimax.api = {}
local M = Verditer.zenimax.api

M.GetGameTimeMilliseconds = GetGameTimeMilliseconds
M.GetAPIVersion           = GetAPIVersion
M.GetWorldName            = GetWorldName

M.GetString = GetString

M.GetUnitName             = GetUnitName
M.GetUnitDisplayName      = GetUnitDisplayName
M.GetUnitClass            = GetUnitClass
M.GetUnitRace             = GetUnitRace
M.GetUnitLevel            = GetUnitLevel
M.GetUnitChampionPoints   = GetUnitChampionPoints
M.GetUnitAlliance         = GetUnitAlliance

-- Health / survivability (View 4 groundwork, v0.2)
M.GetUnitPower            = GetUnitPower
M.IsUnitDead              = IsUnitDead

-- Death Recap (BACKLOG C). Server-authoritative killing-attacks snapshot, read
-- ~2 s after EVENT_PLAYER_DEAD (DEATH_RECAP_DELAY). See esoui deathrecap.lua.
M.GetNumKillingAttacks          = GetNumKillingAttacks
M.GetKillingAttackInfo          = GetKillingAttackInfo
M.DoesKillingAttackHaveAttacker = DoesKillingAttackHaveAttacker
M.GetKillingAttackerInfo        = GetKillingAttackerInfo

M.GetCurrentMapZoneIndex  = GetCurrentMapZoneIndex
M.GetZoneNameByIndex      = GetZoneNameByIndex

M.GetAbilityName          = GetAbilityName
M.GetAbilityIcon          = GetAbilityIcon

M.GetUIMousePosition = GetUIMousePosition

-- Perf observability (DEBUG bench/ledger). Frame rate is the user-visible symptom
-- the compute/graphics lenses ultimately answer to.
M.GetFramerate = GetFramerate
