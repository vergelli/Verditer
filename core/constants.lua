Verditer = Verditer or {}
local Verditer = Verditer

Verditer.Constants = {
  ADDON_NAME    = "Verditer",
  VERSION       = "0.1.0",
  SLASH_COMMAND = "/verditer",

  DEBUG         = true,

  SV_TABLE   = "VerditerSavedVars",
  SV_VERSION = 1,

  -- Acquisition probe (EXPLORATION §1). Focused on the incoming tuple: a single
  -- TARGET=PLAYER subscription, unfiltered by result, dumping CSV via CopyBox.
  PROBE = {
    ROW_LIMIT        = 6000,   -- ring of captured rows (bounded for the CopyBox cap)
    CHAT_INTERVAL_MS = 500,
  },

  TEMPORAL = {
    UPDATE_NAME          = "VerditerTemporalSample",
    SAMPLE_RATE_DEFAULT  = 1000,
    TIME_WINDOW_DEFAULT  = 60,     -- (seconds)
  },

  METRICS = {
    DAMAGE_WINDOW_MS = 5000,    -- DTPS rolling window
    SHIELD_WINDOW_MS = 30000,   -- ABS window, wider for shield-event sparsity
  },

  POOL = {
    -- Incoming volume can exceed Vermilion's outgoing worst case (a trial boss
    -- AoE-ing the group). Revisit upward if engine.pool.exhausted trips (§15.5).
    EVENT_CAPACITY = 4096,
  },

  ABILITY_KIND = {
    DMG_IN = 1,   -- reached HP   (DTPS)
    ABS_IN = 2,   -- ate by shield (ABS)
  },

  -- Brand palette (HANDOFF §2). True blue, NOT the aquamarine namesake.
  BRAND = {
    BLUE      = { r = 0.18,  g = 0.42,  b = 0.88,  a = 1.0 },  -- #2E6BE0 primary
    BLUE_DEEP = { r = 0.12,  g = 0.28,  b = 0.66,  a = 1.0 },  -- #1E47A8 borders
    TINT      = { r = 0.043, g = 0.063, b = 0.125, a = 1.0 },  -- #0B1020 window bg
    ACCENT    = { r = 0.435, g = 0.659, b = 1.0,   a = 1.0 },  -- #6FA8FF lines
    DANGER    = { r = 0.90,  g = 0.30,  b = 0.25,  a = 1.0 },  -- #E64D40 HP stripe
  },

  PROFILER_BUDGETS_MS = {
    ["pipeline.combat_event"]             = 5.0,
    ["pipeline.combat_event.acquisition"] = 2.0,
    ["pipeline.combat_event.filter"]      = 2.0,
    ["pipeline.combat_event.processing"]  = 3.0,
    ["pipeline.render_tick"]              = 10.0,
    ["graph.sample_tick"]                 = 15.0,
  },
}
