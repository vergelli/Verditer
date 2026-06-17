Verditer = Verditer or {}

-- Keybinding label shown in ESO Controls settings
ZO_CreateStringId("SI_BINDING_NAME_VERDITER_TOGGLE", "Toggle Verditer Window")

-- Status strings
ZO_CreateStringId("VERDITER_BUFFER_CLEARED", "Buffers cleared.")
ZO_CreateStringId("VERDITER_LOADED",         "Verditer v%s loaded. Type %s to toggle.")

-- Settings panel
ZO_CreateStringId("VERDITER_SETTINGS_TITLE",         "Verditer Settings")
ZO_CreateStringId("VERDITER_SETTINGS_RESET",         "Reset to Defaults")
ZO_CreateStringId("VERDITER_SETTING_SAMPLE_RATE",    "Sampling Rate")
ZO_CreateStringId("VERDITER_SETTING_TIME_WINDOW",    "Time Window")
ZO_CreateStringId("VERDITER_SETTING_VIEWPORT_ALPHA", "Viewport Alpha")
ZO_CreateStringId("VERDITER_SETTINGS_LOGO_ON",       "Logo: Visible")
ZO_CreateStringId("VERDITER_SETTINGS_LOGO_OFF",      "Logo: Hidden")
ZO_CreateStringId("VERDITER_LOGO_HINT",              "Logo hidden. Bind a key to Verditer under Settings > Controls > Keybindings (Add-Ons), or type /verditer.")

-- Heavy buffer warning (in chat) — args: window_s, hz, capacity.
ZO_CreateStringId("VERDITER_WARN_HEAVY_BUFFER", "%ds x %d Hz = %d samples may impact FPS. Consider a lower sample rate for long windows.")

-- Help command output
ZO_CreateStringId("VERDITER_HELP_HEADER",  "Verditer commands:")
ZO_CreateStringId("VERDITER_HELP_GRAPH",   "  /verditer         toggle the incoming-damage analytics window")
ZO_CreateStringId("VERDITER_HELP_HELP",    "  /verditer help    show this list")

-- Graph window
ZO_CreateStringId("VERDITER_GRAPH_TITLE",   "Incoming Analysis")
ZO_CreateStringId("VERDITER_GRAPH_RECORD",  "Record")
ZO_CreateStringId("VERDITER_GRAPH_STOP",    "Stop")
ZO_CreateStringId("VERDITER_GRAPH_FLUSH",   "Flush")
ZO_CreateStringId("VERDITER_GRAPH_NO_DATA", "No data — press Record while taking damage.")
