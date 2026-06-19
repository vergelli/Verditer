--* core/source_palette.lua
--*
--* Colours for the BY_SOURCE view (SPEC §2.2, BACKLOG G). Unlike damage types,
--* attackers have NO natural grouping or intrinsic colour, and the key space is
--* open (any unitId). So we map source_unit_id -> a fixed high-contrast palette
--* by a STABLE hash: the same enemy keeps the same colour for the whole fight
--* (deterministic, zero per-call alloc). Two distinct enemies can collide on a
--* colour (12 slots) — acceptable; the legend disambiguates by name.
--*
--* Two reserved, fixed colours sit outside the hash wheel:
--*   ENV   — source_unit_id == 0  => environmental / self (fall, lava, traps).
--*   OTHER — the top-N "Other" fold bucket (set by Metrics.source_groups_into).

Verditer = Verditer or {}
local Verditer = Verditer

local SP = {}
Verditer.SourcePalette = SP

-- Vivid, evenly-spread categorical palette for attackers. Deliberately BOLDER /
-- more saturated than the (soft, semantic) damage-type palette, so a SOURCE stack
-- never reads as a TYPE stack — the two feel categorically different at a glance
-- (Federico: their colours were getting confused). Hues step by the golden angle
-- so even consecutively-hashed attackers land far apart on the wheel.
local math_floor = math.floor

local function hsv(h, s, v)
  h = h - math_floor(h)                       -- frac → hue in [0,1)
  local i = math_floor(h * 6)
  local f = h * 6 - i
  local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  i = i % 6
  if     i == 0 then return v, t, p
  elseif i == 1 then return q, v, p
  elseif i == 2 then return p, v, t
  elseif i == 3 then return p, q, v
  elseif i == 4 then return t, p, v
  else               return v, p, q end
end

local N = 12
local PALETTE = {}
for i = 1, N do
  local r, g, b = hsv(i * 0.61803398875, 0.82, 0.98)   -- bold: high sat + bright
  PALETTE[i] = { r = r, g = g, b = b, a = 0.92 }
end

-- Reserved buckets (exported so the metric can colour its Other fold).
SP.ENV   = { r = 0.55, g = 0.55, b = 0.58, a = 0.85 }  -- neutral grey: environment/self
SP.OTHER = { r = 0.40, g = 0.42, b = 0.48, a = 0.80 }  -- darker slate: folded remainder

-- Stable colour for an attacker. uid 0 (or nil) => the reserved ENV grey.
function SP.lookup(uid)
  if not uid or uid == 0 then return SP.ENV end
  if uid < 0 then return SP.OTHER end          -- sentinel used by the Other fold
  return PALETTE[(uid % N) + 1]
end
