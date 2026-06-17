--* pipeline/processing.lua
--*
--* Stage 3. Routes a filtered VerditerEvent to the appropriate metrics ingestor.
--* The event becomes the buffer's owned entry from this point — the caller MUST
--* NOT release it. Buffer trim (on_evict) returns it to the pool when the time
--* window passes.

Verditer = Verditer or {}
local Verditer = Verditer

Verditer.Pipeline = Verditer.Pipeline or {}
Verditer.Pipeline.Processing = {}
local M = Verditer.Pipeline.Processing

local AK = Verditer.Constants.ABILITY_KIND
local KIND_DMG_IN = AK.DMG_IN
local KIND_ABS_IN = AK.ABS_IN

function M.process(ev)
  local k = ev.kind
  if k == KIND_DMG_IN then
    Verditer.Metrics.ingest_dmg_in(ev)
  elseif k == KIND_ABS_IN then
    Verditer.Metrics.ingest_abs_in(ev)
  end
end
