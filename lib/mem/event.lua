
Verditer = Verditer or {}
Verditer.lib = Verditer.lib or {}
Verditer.lib.mem = Verditer.lib.mem or {}

local Event = {}
Verditer.lib.mem.Event = Event

-- VerditerEvent (SPEC §7.1). Pooled, mutated in place, never allocated in the
-- hot path. The incoming-damage schema: damage_type / source_unit_id / overflow
-- replace Vermilion's target_* fields (the target is always the player here).
function Event.factory()
  return {
    t              = 0,
    kind           = 0,   -- ABILITY_KIND.DMG_IN | ABILITY_KIND.ABS_IN
    result         = 0,   -- ACTION_RESULT code
    amount         = 0,   -- hitValue
    damage_type    = 0,   -- DAMAGE_TYPE_*           (View 2 key)
    ability_id     = 0,   -- abilityId               (View 3 key; icon/name lookup)
    source_unit_id = 0,   -- attacker; 0 => environmental/self  (BY_SOURCE key)
    source_name    = "",  -- attacker display name (raw; cleaned lazily for the legend)
    overflow       = 0,   -- overkill on lethal hit  (Death Recap); 0 otherwise
  }
end
