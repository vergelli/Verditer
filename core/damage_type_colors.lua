--* core/damage_type_colors.lua
--*
--* Replaces Vermilion's open-ended, hand-maintained skill_colors map with a
--* fixed O(1) lookup over the 13 DAMAGE_TYPE_* enum values (SPEC §10). The key
--* space is closed and engine-determined, so classification is TOTAL — there is
--* no Unknown bucket and nothing for the user to assign (SPEC §10.1).

Verditer = Verditer or {}
local Verditer = Verditer

local zc = Verditer.zenimax.constants

local DTC = {}
Verditer.DamageTypeColors = DTC

-- additive build (skip any nil constant rather than risk a [nil]=... crash that
-- would break the whole addon load if ZOS ever renames a damage type).
local function put(dt, r, g, b)
  if dt ~= nil then DTC[dt] = { r = r, g = g, b = b, a = 0.90 } end
end

put(zc.DAMAGE_TYPE_FIRE,     0.95, 0.45, 0.20)  -- flame orange
put(zc.DAMAGE_TYPE_COLD,     0.55, 0.80, 0.95)  -- frost cyan
put(zc.DAMAGE_TYPE_SHOCK,    0.70, 0.55, 0.95)  -- violet
put(zc.DAMAGE_TYPE_POISON,   0.55, 0.80, 0.30)  -- venom green
put(zc.DAMAGE_TYPE_DISEASE,  0.65, 0.60, 0.45)  -- sickly tan
put(zc.DAMAGE_TYPE_BLEED,    0.75, 0.15, 0.20)  -- dark red
put(zc.DAMAGE_TYPE_PHYSICAL, 0.85, 0.80, 0.70)  -- bone/steel
put(zc.DAMAGE_TYPE_MAGIC,    0.40, 0.55, 0.95)  -- arcane blue
put(zc.DAMAGE_TYPE_OBLIVION, 0.60, 0.10, 0.60)  -- daedric magenta (ignores resist!)
put(zc.DAMAGE_TYPE_EARTH,    0.55, 0.40, 0.25)  -- earthen brown
put(zc.DAMAGE_TYPE_DROWN,    0.25, 0.45, 0.55)  -- deep water
put(zc.DAMAGE_TYPE_GENERIC,  0.70, 0.70, 0.70)  -- grey
put(zc.DAMAGE_TYPE_NONE,     0.50, 0.50, 0.50)  -- fold to GENERIC if it never appears

local FALLBACK = { r = 0.70, g = 0.70, b = 0.70, a = 0.90 }

-- The only honest "just in case" (SPEC §10.1): a value outside the 13 (e.g. a
-- damage type ZOS adds in a future patch) returns FALLBACK and bumps a
-- diagnostic counter so the DEBUG probe surfaces it. No assignment UI, ever.
function DTC.lookup(dt)
  local c = DTC[dt]
  if c then return c end
  if Verditer.Diagnostics then Verditer.Diagnostics.bump("metrics.damage_type_fallback") end
  return FALLBACK
end

-- Short display names for the 13 types (CSV export + recap hover). Defensive
-- build (skip nil enum keys), single source of truth so export/recap don't drift.
local DT_NAMES = {}
local function nm(dt, s) if dt ~= nil then DT_NAMES[dt] = s end end
nm(zc.DAMAGE_TYPE_GENERIC, "Generic")  nm(zc.DAMAGE_TYPE_PHYSICAL, "Physical")
nm(zc.DAMAGE_TYPE_FIRE,    "Fire")     nm(zc.DAMAGE_TYPE_SHOCK,    "Shock")
nm(zc.DAMAGE_TYPE_OBLIVION,"Oblivion") nm(zc.DAMAGE_TYPE_COLD,     "Cold")
nm(zc.DAMAGE_TYPE_EARTH,   "Earth")    nm(zc.DAMAGE_TYPE_MAGIC,    "Magic")
nm(zc.DAMAGE_TYPE_DROWN,   "Drown")    nm(zc.DAMAGE_TYPE_DISEASE,  "Disease")
nm(zc.DAMAGE_TYPE_POISON,  "Poison")   nm(zc.DAMAGE_TYPE_BLEED,    "Bleed")
nm(zc.DAMAGE_TYPE_NONE,    "None")

function DTC.name(dt)
  return DT_NAMES[dt] or "Unknown"
end
