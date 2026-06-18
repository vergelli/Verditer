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

-- 12 distinct categorical hues, kept clear of the survival semantics (HP green,
-- fresh-hit red) so a SOURCE stack never reads as an HP bar. Alpha matches the
-- damage-type stacks (0.90) for a consistent stacked look.
local PALETTE = {
  { r = 0.90, g = 0.50, b = 0.30, a = 0.90 },  -- amber
  { r = 0.40, g = 0.70, b = 0.95, a = 0.90 },  -- sky
  { r = 0.80, g = 0.55, b = 0.90, a = 0.90 },  -- orchid
  { r = 0.55, g = 0.85, b = 0.55, a = 0.90 },  -- sage
  { r = 0.95, g = 0.80, b = 0.35, a = 0.90 },  -- gold
  { r = 0.45, g = 0.75, b = 0.80, a = 0.90 },  -- teal
  { r = 0.90, g = 0.60, b = 0.65, a = 0.90 },  -- rose
  { r = 0.65, g = 0.65, b = 0.95, a = 0.90 },  -- periwinkle
  { r = 0.80, g = 0.70, b = 0.45, a = 0.90 },  -- sand
  { r = 0.55, g = 0.80, b = 0.70, a = 0.90 },  -- mint
  { r = 0.90, g = 0.45, b = 0.55, a = 0.90 },  -- coral
  { r = 0.70, g = 0.80, b = 0.40, a = 0.90 },  -- lime
}
local N = #PALETTE

-- Reserved buckets (exported so the metric can colour its Other fold).
SP.ENV   = { r = 0.55, g = 0.55, b = 0.58, a = 0.85 }  -- neutral grey: environment/self
SP.OTHER = { r = 0.40, g = 0.42, b = 0.48, a = 0.80 }  -- darker slate: folded remainder

-- Stable colour for an attacker. uid 0 (or nil) => the reserved ENV grey.
function SP.lookup(uid)
  if not uid or uid == 0 then return SP.ENV end
  if uid < 0 then return SP.OTHER end          -- sentinel used by the Other fold
  return PALETTE[(uid % N) + 1]
end
