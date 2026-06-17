--* pipeline/filter.lua
--*
--* Stage 2. The guard INVERTS relative to Vermilion (SPEC §8.2): Vermilion
--* dropped events with no valid source (env damage mis-attributed to the
--* player). Verditer's concern is the opposite end — the source is now an
--* enemy, and source_unit_id == 0 means environmental/self (fall, lava, trap).
--* A survival tool should COUNT "the lava killed me", so we KEEP zero-source
--* and merely tag it for a future env/self split (BACKLOG H). The landed-result
--* membership check already happened at the subscription handler (pipeline.lua).

Verditer = Verditer or {}
local Verditer = Verditer

Verditer.Pipeline = Verditer.Pipeline or {}
Verditer.Pipeline.Filter = {}
local M = Verditer.Pipeline.Filter

local bump = Verditer.Diagnostics.bump   -- no-op in release (DEBUG=false)
local KIND_DMG_IN = Verditer.Constants.ABILITY_KIND.DMG_IN

function M.allow(ev)
  if ev.kind == KIND_DMG_IN and (ev.source_unit_id or 0) <= 0 then
    bump("filter.env_self")   -- tag, do NOT drop (environmental/self is real)
  end
  return true
end
