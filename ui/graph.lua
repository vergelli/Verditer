Verditer = Verditer or {}
Verditer.Graph = {}
local M = Verditer.Graph

local api  = Verditer.zenimax.api
local zui  = Verditer.zenimax.ui
local zc   = Verditer.zenimax.constants
local zev  = Verditer.zenimax.events
local WINDOW_MANAGER             = zui.WINDOW_MANAGER
local GetGameTimeMilliseconds    = api.GetGameTimeMilliseconds
local GetString                  = api.GetString
local math_max                   = math.max
local math_min                   = math.min
local math_floor                 = math.floor
local string_format              = string.format

local log               = Verditer.Log.for_module("graph")
local TOPLEFT           = zc.TOPLEFT
local BOTTOMLEFT        = zc.BOTTOMLEFT
local BOTTOM            = zc.BOTTOM
local BOTTOMRIGHT       = zc.BOTTOMRIGHT
local CENTER            = zc.CENTER
local GuiRoot           = zc.GuiRoot
local CT_TEXTURE        = zc.CT_TEXTURE
local CT_LABEL          = zc.CT_LABEL
local TEXT_ALIGN_LEFT   = zc.TEXT_ALIGN_LEFT
local TEXT_ALIGN_CENTER = zc.TEXT_ALIGN_CENTER
local TEXT_ALIGN_BOTTOM = zc.TEXT_ALIGN_BOTTOM

-- Brand-blue identity (HANDOFF §2). Red = HP lost, blue = shield lost.
local C_DTPS      = { r = 0.90, g = 0.30, b = 0.25, a = 0.92 }  -- DANGER red (reached HP)
local C_ABS       = { r = 0.18, g = 0.42, b = 0.88, a = 0.90 }  -- VERDITER blue (shield ate it)
local C_LINE_DTPS = { r = 1.00, g = 0.46, b = 0.40, a = 1.00 }  -- bright red frontier
local C_LINE_ABS  = { r = 0.44, g = 0.66, b = 1.00, a = 1.00 }  -- bright blue frontier
local C_LINE_TOP  = { r = 0.80, g = 0.88, b = 1.00, a = 1.00 }  -- pale-blue DTPS frontier (type view)
local C_BASELINE  = { r = 0.78, g = 0.86, b = 1.00, a = 0.55 }  -- shared axis (Outcome)
local C_CHROME    = { r = 0.46, g = 0.60, b = 0.95, a = 0.80 }  -- blue chrome wash
local C_VIEWPORT  = { r = 0.30, g = 0.45, b = 0.85 }            -- viewport tint (blue)

-- Survival views
local C_HP        = { r = 0.30, g = 0.80, b = 0.45, a = 0.92 }  -- green: HP remaining
local C_HP_LOST   = { r = 0.42, g = 0.44, b = 0.50, a = 0.80 }  -- grey: standing wound
local C_HP_FRESH  = { r = 0.90, g = 0.30, b = 0.25, a = 0.92 }  -- red: HP lost this tick
local C_FULL_LINE = { r = 0.55, g = 0.95, b = 0.65, a = 0.45 }  -- the 100% reference line

local FILL_TEXTURE   = "EsoUI/Art/UnitAttributeVisualizer/attributeBar_dynamic_fill.dds"
local FILL_T, FILL_B = 0, 0.53125
local LINE_THICKNESS = 2

local N_HGRID      = 3
local N_VGRID      = 3
local TIME_STRIP_H = 18
local C_GRID_LINE = { r = 0.55, g = 0.58, b = 0.70, a = 0.25 }
local C_GRID_LBL  = { r = 0.82, g = 0.85, b = 0.90, a = 0.92 }
local C_TIME_LBL  = { r = 0.68, g = 0.70, b = 0.75, a = 0.85 }

-- state
local controls           = {}
local recording_start_ms = 0

local VIEW_OUTCOME        = 1
local VIEW_BY_DAMAGE_TYPE = 2
local VIEW_SURVIVAL       = 3   -- HP green/red/grey bars
local VIEW_BY_SOURCE      = 4   -- stacked by attacker ("who's killing me")
local VIEW_MIN, VIEW_MAX  = VIEW_OUTCOME, VIEW_BY_SOURCE
local VIEW_LABELS         = { "OUTCOME", "TYPE", "SURVIVAL", "SOURCE" }
local current_view        = VIEW_OUTCOME

local prev_hp = -1   -- previous sample's hp_pct, for the fresh-loss (red) band

-- small helpers
local function fmt_val(v)
  return ZO_AbbreviateAndLocalizeNumber(math_floor(v), 0, false)
end

local function fmt_secs(ms)
  local s = math_floor(ms / 1000)
  if s >= 60 then return string_format("%d:%02d", math_floor(s / 60), s % 60) end
  return s .. "s"
end

local function fmt_readout(v)
  return ZO_AbbreviateAndLocalizeNumber(math_floor(v + 0.5), 1, false)
end

-- Header readout: ITP (incoming total pressure). Defensive-themed icon.
local ITP_ICON_IDLE   = "/esoui/art/treeicons/collection_indexicon_armor_up.dds"
local ITP_ICON_ACTIVE = "/esoui/art/treeicons/collection_indexicon_armor_down.dds"

local function update_header(itp)
  controls.readout:SetText(fmt_readout(itp))
  controls.itp_icon:SetTexture(itp > 0 and ITP_ICON_ACTIVE or ITP_ICON_IDLE)
end

local function header_tick()
  if controls.window:IsHidden() then return end
  local now = GetGameTimeMilliseconds()
  update_header(Verditer.Metrics.ITP(now))
end

local Pool = Verditer.lib.plot.Pool

local function fill_factory(c)
  c:SetTexture(FILL_TEXTURE)
  c:SetTextureCoords(0, 1, FILL_T, FILL_B)
  c:SetPixelRoundingEnabled(false)
end

local function fill_reset(c) c:SetHidden(true) end

local function line_factory(line) line:SetThickness(LINE_THICKNESS) end

local function line_reset(line)
  line:SetHidden(true)
  line:ClearAnchors()
end

local function make_fill_pool(name_prefix)
  return Pool.new(name_prefix, controls.canvas, CT_TEXTURE, fill_factory, fill_reset)
end

local function make_line_pool(name_prefix)
  return Pool.new_virtual(name_prefix, controls.canvas, "VerditerGraphLineTemplate", line_factory, line_reset)
end

local function create_grid(prefix, parent_ctrl)
  local WM  = WINDOW_MANAGER
  local obj = { hlines = {}, vlines = {}, ylabels = {} }

  for i = 1, N_HGRID do
    local gl = WM:CreateControl(prefix .. "H" .. i, parent_ctrl, CT_TEXTURE)
    gl:SetTexture(FILL_TEXTURE)
    gl:SetTextureCoords(0, 1, 0, 0.05)
    gl:SetHeight(1)
    gl:SetColor(C_GRID_LINE.r, C_GRID_LINE.g, C_GRID_LINE.b, C_GRID_LINE.a)
    gl:SetHidden(true)
    obj.hlines[i] = gl

    local lbl = WM:CreateControl(prefix .. "YL" .. i, parent_ctrl, CT_LABEL)
    lbl:SetFont("ZoFontGameSmall")
    lbl:SetHorizontalAlignment(TEXT_ALIGN_LEFT)
    lbl:SetVerticalAlignment(TEXT_ALIGN_BOTTOM)
    lbl:SetColor(C_GRID_LBL.r, C_GRID_LBL.g, C_GRID_LBL.b, C_GRID_LBL.a)
    lbl:SetDimensions(54, 10)
    lbl:SetHidden(true)
    obj.ylabels[i] = lbl
  end

  for i = 1, N_VGRID do
    local vl = WM:CreateControl(prefix .. "V" .. i, parent_ctrl, CT_TEXTURE)
    vl:SetTexture(FILL_TEXTURE)
    vl:SetTextureCoords(0, 0.05, 0, 1)
    vl:SetWidth(1)
    vl:SetColor(C_GRID_LINE.r, C_GRID_LINE.g, C_GRID_LINE.b, C_GRID_LINE.a)
    vl:SetHidden(true)
    obj.vlines[i] = vl
  end

  local function make_time_lbl(name, align)
    local t = WM:CreateControl(name, parent_ctrl, CT_LABEL)
    t:SetFont("ZoFontGameSmall")
    t:SetHorizontalAlignment(align)
    t:SetVerticalAlignment(TEXT_ALIGN_BOTTOM)
    t:SetColor(C_TIME_LBL.r, C_TIME_LBL.g, C_TIME_LBL.b, C_TIME_LBL.a)
    t:SetDimensions(44, 10)
    t:SetHidden(true)
    return t
  end
  obj.time_l = make_time_lbl(prefix .. "TL", TEXT_ALIGN_LEFT)
  obj.time_m = make_time_lbl(prefix .. "TM", TEXT_ALIGN_CENTER)
  obj.time_r = make_time_lbl(prefix .. "TR", TEXT_ALIGN_RIGHT)

  return obj
end

local function hide_grid(grid)
  for i = 1, N_HGRID do
    grid.hlines[i]:SetHidden(true)
    grid.ylabels[i]:SetHidden(true)
  end
  for i = 1, N_VGRID do grid.vlines[i]:SetHidden(true) end
  grid.time_l:SetHidden(true)
  grid.time_m:SetHidden(true)
  grid.time_r:SetHidden(true)
end

local function draw_time_strip(grid, canvas, span_ms)
  if span_ms > 0 then
    grid.time_l:ClearAnchors()
    grid.time_l:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, 2, 0)
    grid.time_l:SetText("0s")
    grid.time_l:SetHidden(false)
    grid.time_m:ClearAnchors()
    grid.time_m:SetAnchor(BOTTOM, canvas, BOTTOM, 0, 0)
    grid.time_m:SetText(fmt_secs(span_ms / 2))
    grid.time_m:SetHidden(false)
    grid.time_r:ClearAnchors()
    grid.time_r:SetAnchor(BOTTOMRIGHT, canvas, BOTTOMRIGHT, -2, 0)
    grid.time_r:SetText(fmt_secs(span_ms))
    grid.time_r:SetHidden(false)
  else
    grid.time_l:SetHidden(true)
    grid.time_m:SetHidden(true)
    grid.time_r:SetHidden(true)
  end
end

-- bottom-anchored grid (stacked views: BY_DAMAGE_TYPE)
local function draw_grid(grid, canvas, max_val, span_ms)
  local cw = canvas:GetWidth()
  local ch = canvas:GetHeight()
  if cw <= 0 or ch <= 0 then hide_grid(grid) return end

  local has_y    = (max_val > 0)
  local has_time = (span_ms > 0)
  if not has_y and not has_time then hide_grid(grid) return end

  local y_base  = has_time and TIME_STRIP_H or 0
  local ch_plot = math_max(1, ch - y_base)

  if has_y then
    for i = 1, N_HGRID do
      local frac = i / (N_HGRID + 1)
      local y    = y_base + math_floor(ch_plot * frac)
      local gl = grid.hlines[i]
      gl:ClearAnchors()
      gl:SetAnchor(BOTTOMLEFT,  canvas, BOTTOMLEFT,  0, -y)
      gl:SetAnchor(BOTTOMRIGHT, canvas, BOTTOMRIGHT, 0, -y)
      gl:SetColor(C_GRID_LINE.r, C_GRID_LINE.g, C_GRID_LINE.b, C_GRID_LINE.a)
      gl:SetHidden(false)
      local lbl = grid.ylabels[i]
      lbl:ClearAnchors()
      lbl:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, 2, -(y + 1))
      lbl:SetText(fmt_val(max_val * frac))
      lbl:SetHidden(false)
    end
  else
    for i = 1, N_HGRID do
      grid.hlines[i]:SetHidden(true)
      grid.ylabels[i]:SetHidden(true)
    end
  end

  for i = 1, N_VGRID do
    local frac = i / (N_VGRID + 1)
    local x    = math_floor(cw * frac)
    local vl = grid.vlines[i]
    vl:ClearAnchors()
    vl:SetAnchor(TOPLEFT,    canvas, TOPLEFT,    x, 0)
    vl:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, x, -y_base)
    vl:SetHidden(false)
  end

  draw_time_strip(grid, canvas, span_ms)
end

-- diverging grid (Outcome): a bright shared baseline mid-plot, faint quartiles
-- above/below, max labels at the two tips, plus the time strip.
local function draw_grid_diverging(grid, canvas, baseline_y, half, max_dtps, max_abs, span_ms)
  local cw = canvas:GetWidth()
  local ch = canvas:GetHeight()
  if cw <= 0 or ch <= 0 then hide_grid(grid) return end

  local function hline(i, y, c)
    local gl = grid.hlines[i]
    gl:ClearAnchors()
    gl:SetAnchor(BOTTOMLEFT,  canvas, BOTTOMLEFT,  0, -y)
    gl:SetAnchor(BOTTOMRIGHT, canvas, BOTTOMRIGHT, 0, -y)
    gl:SetColor(c.r, c.g, c.b, c.a)
    gl:SetHidden(false)
  end

  hline(1, baseline_y, C_BASELINE)                 -- shared axis
  hline(2, baseline_y + math_floor(half * 0.5), C_GRID_LINE)   -- DTPS quartile
  hline(3, baseline_y - math_floor(half * 0.5), C_GRID_LINE)   -- ABS quartile

  -- y labels: 0 at the baseline, max DTPS up, max ABS down — each its own scale
  grid.ylabels[1]:ClearAnchors()
  grid.ylabels[1]:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, 2, -(baseline_y + 1))
  grid.ylabels[1]:SetText("0")
  grid.ylabels[1]:SetHidden(false)

  grid.ylabels[2]:ClearAnchors()
  grid.ylabels[2]:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, 2, -(baseline_y + half))
  grid.ylabels[2]:SetText(max_dtps > 0 and fmt_val(max_dtps) or "")
  grid.ylabels[2]:SetHidden(false)

  grid.ylabels[3]:ClearAnchors()
  grid.ylabels[3]:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, 2, -(baseline_y - half + 10))
  grid.ylabels[3]:SetText(max_abs > 0 and fmt_val(max_abs) or "")
  grid.ylabels[3]:SetHidden(false)

  for i = 1, N_VGRID do
    local frac = i / (N_VGRID + 1)
    local x    = math_floor(cw * frac)
    local vl = grid.vlines[i]
    vl:ClearAnchors()
    vl:SetAnchor(TOPLEFT,    canvas, TOPLEFT,    x, 0)
    vl:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, x, -TIME_STRIP_H)
    vl:SetHidden(false)
  end

  draw_time_strip(grid, canvas, span_ms)
end

local function release_all_pools()
  controls.pool_type_seg:ReleaseAllObjects()
  controls.pool_type_line:ReleaseAllObjects()
  controls.pool_up:ReleaseAllObjects()
  controls.pool_down:ReleaseAllObjects()
  controls.pool_line_up:ReleaseAllObjects()
  controls.pool_line_down:ReleaseAllObjects()
end

local function slot_geometry(cw)
  local capacity = Verditer.TemporalBuffer.capacity()
  local n        = Verditer.TemporalBuffer.count()
  local slot_w   = cw / capacity                 -- float; gates polyline density
  local bar_gap  = (slot_w > 3) and 1 or 0
  local offset   = capacity - n
  return slot_w, bar_gap, offset
end

-- Pixel-snapped bar rect (BACKLOG L): integer left + width via cumulative
-- rounding, so bars tile the pixel grid exactly and never beat into the
-- "thicker bar every N" moiré that float positions/widths produce.
local function slot_rect(offset, i, slot_w, bar_gap)
  local left  = math_floor((offset + i - 1) * slot_w + 0.5)
  local right = math_floor((offset + i)     * slot_w + 0.5)
  return left, math_max(1, right - left - bar_gap)
end

-- extents over the window
local function extent_dtps()
  local max_dtps = 0
  local t_first, t_last = 0, 0
  Verditer.TemporalBuffer.iterate(function(i, s)
    if s.DTPS > max_dtps then max_dtps = s.DTPS end
    if i == 1 then t_first = s.t end
    t_last = s.t
  end)
  return max_dtps, (t_last - t_first)
end

-- Outcome uses INDEPENDENT per-side scales (Federico, in-game 2026-06-17): the
-- top half fills to max(DTPS), the bottom half to max(ABS), so each side reads
-- against its own peak and the full opening encodes max(DTPS) + max(ABS). (This
-- supersedes SPEC §5.1's shared-scale note, which compressed the smaller side.)
local function extent_outcome()
  local max_dtps, max_abs = 0, 0
  local t_first, t_last = 0, 0
  Verditer.TemporalBuffer.iterate(function(i, s)
    if s.DTPS > max_dtps then max_dtps = s.DTPS end
    if s.ABS  > max_abs  then max_abs  = s.ABS  end
    if i == 1 then t_first = s.t end
    t_last = s.t
  end)
  return max_dtps, max_abs, (t_last - t_first)
end

-- hoisted scratch (see Vermilion: avoid per-frame array alloc at high capacity)
local rt_xs, rt_top_hs              = {}, {}
local ro_xs, ro_up_hs, ro_down_ys   = {}, {}, {}

-- Shared stacked-bar renderer: per-tick column of height ∝ DTPS, segmented by a
-- group set. View 2 (BY_DAMAGE_TYPE) keys it on `type_groups`, View 4 (BY_SOURCE)
-- on `source_groups` — identical geometry, different grouping. Each group slot
-- carries its own colour, so the renderer never knows what it's stacking.
local function render_stacked(groups_field)
  release_all_pools()

  local n = Verditer.TemporalBuffer.count()
  if n == 0 then
    controls.no_data:SetHidden(false)
    hide_grid(controls.grid)
    return
  end
  controls.no_data:SetHidden(true)

  local canvas = controls.canvas
  local cw, ch = canvas:GetWidth(), canvas:GetHeight()
  if cw <= 4 or ch <= 4 then return end
  local ch_plot = math_max(4, ch - TIME_STRIP_H)

  local max_dtps, span_ms = extent_dtps()
  if max_dtps <= 0 then hide_grid(controls.grid) return end
  draw_grid(controls.grid, canvas, max_dtps, span_ms)

  local slot_w, bar_gap, offset = slot_geometry(cw)
  local xs, top_hs = rt_xs, rt_top_hs

  Verditer.TemporalBuffer.iterate(function(i, s)
    local x, bw = slot_rect(offset, i, slot_w, bar_gap)
    local col_h = math_max(0, math_floor(ch_plot * (s.DTPS / max_dtps) + 0.5))
    xs[i]     = x + bw * 0.5
    top_hs[i] = col_h

    local y_off  = 0
    local groups = s[groups_field]
    for g = 1, (groups.count or 0) do
      local grp   = groups[g]
      local seg_h = math_max(1, math_floor(col_h * grp.share + 0.5))
      local t = controls.pool_type_seg:AcquireObject()
      t:ClearAnchors()
      t:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, x, -(y_off + TIME_STRIP_H))
      t:SetWidth(bw)
      t:SetHeight(seg_h)
      t:SetColor(grp.r, grp.g, grp.b, grp.a)
      t:SetHidden(false)
      y_off = y_off + seg_h
    end
  end)

  if slot_w >= 3 then
    for i = 2, n do
      local lt = controls.pool_type_line:AcquireObject()
      lt:ClearAnchors()
      lt:SetAnchor(BOTTOMLEFT,  canvas, BOTTOMLEFT, xs[i-1], -(top_hs[i-1] + TIME_STRIP_H))
      lt:SetAnchor(BOTTOMRIGHT, canvas, BOTTOMLEFT, xs[i],   -(top_hs[i]   + TIME_STRIP_H))
      lt:SetColor(C_LINE_TOP.r, C_LINE_TOP.g, C_LINE_TOP.b, C_LINE_TOP.a)
      lt:SetThickness(LINE_THICKNESS)
      lt:SetHidden(false)
    end
  end
end

-- View 2 — BY_DAMAGE_TYPE: stacked by damageType (fire/shock/…).
local function render_by_damage_type() render_stacked("type_groups") end

-- View 4 — BY_SOURCE: stacked by attacker ("who's killing me"). Same column
-- height (DTPS), segments coloured by the stable per-uid hash; top-7 + Other.
local function render_by_source() render_stacked("source_groups") end

-- View 1 — OUTCOME (diverging shared-axis): DTPS grows UP (red) from a shared
-- baseline, ABS grows DOWN (blue). One frontier polyline per side. The shield
-- break reads spatially: blue collapses below while red jumps above.
local function render_outcome()
  release_all_pools()

  local n = Verditer.TemporalBuffer.count()
  if n == 0 then
    controls.no_data:SetHidden(false)
    hide_grid(controls.grid)
    return
  end
  controls.no_data:SetHidden(true)

  local canvas = controls.canvas
  local cw, ch = canvas:GetWidth(), canvas:GetHeight()
  if cw <= 4 or ch <= 4 then return end
  local ch_plot = math_max(4, ch - TIME_STRIP_H)
  local half       = math_floor(ch_plot / 2)
  local baseline_y = TIME_STRIP_H + half   -- height above canvas bottom

  local max_dtps, max_abs, span_ms = extent_outcome()
  if max_dtps <= 0 and max_abs <= 0 then hide_grid(controls.grid) return end
  draw_grid_diverging(controls.grid, canvas, baseline_y, half, max_dtps, max_abs, span_ms)

  -- per-side pixels-per-unit; 0 when a side has no data (avoids div-by-zero)
  local up_scale   = (max_dtps > 0) and (half / max_dtps) or 0
  local down_scale = (max_abs  > 0) and (half / max_abs)  or 0

  local slot_w, bar_gap, offset = slot_geometry(cw)
  local xs, up_hs, down_ys = ro_xs, ro_up_hs, ro_down_ys

  Verditer.TemporalBuffer.iterate(function(i, s)
    local x, bw   = slot_rect(offset, i, slot_w, bar_gap)
    local up_h    = math_min(half, math_max(0, math_floor(s.DTPS * up_scale   + 0.5)))
    local down_h  = math_min(half, math_max(0, math_floor(s.ABS  * down_scale + 0.5)))
    xs[i]      = x + bw * 0.5
    up_hs[i]   = up_h
    down_ys[i] = baseline_y - down_h

    if up_h > 0 then
      local tu = controls.pool_up:AcquireObject()
      tu:ClearAnchors()
      tu:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, x, -baseline_y)  -- bottom edge on baseline
      tu:SetWidth(bw)
      tu:SetHeight(up_h)                                           -- grows up
      tu:SetColor(C_DTPS.r, C_DTPS.g, C_DTPS.b, C_DTPS.a)
      tu:SetHidden(false)
    end

    if down_h > 0 then
      local td = controls.pool_down:AcquireObject()
      td:ClearAnchors()
      td:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, x, -(baseline_y - down_h))  -- bottom edge below baseline
      td:SetWidth(bw)
      td:SetHeight(down_h)
      td:SetColor(C_ABS.r, C_ABS.g, C_ABS.b, C_ABS.a)
      td:SetHidden(false)
    end
  end)

  if slot_w >= 3 then
    for i = 2, n do
      local lu = controls.pool_line_up:AcquireObject()
      lu:ClearAnchors()
      lu:SetAnchor(BOTTOMLEFT,  canvas, BOTTOMLEFT, xs[i-1], -(baseline_y + up_hs[i-1]))
      lu:SetAnchor(BOTTOMRIGHT, canvas, BOTTOMLEFT, xs[i],   -(baseline_y + up_hs[i]))
      lu:SetColor(C_LINE_DTPS.r, C_LINE_DTPS.g, C_LINE_DTPS.b, C_LINE_DTPS.a)
      lu:SetThickness(LINE_THICKNESS)
      lu:SetHidden(false)

      local ld = controls.pool_line_down:AcquireObject()
      ld:ClearAnchors()
      ld:SetAnchor(BOTTOMLEFT,  canvas, BOTTOMLEFT, xs[i-1], -down_ys[i-1])
      ld:SetAnchor(BOTTOMRIGHT, canvas, BOTTOMLEFT, xs[i],   -down_ys[i])
      ld:SetColor(C_LINE_ABS.r, C_LINE_ABS.g, C_LINE_ABS.b, C_LINE_ABS.a)
      ld:SetThickness(LINE_THICKNESS)
      ld:SetHidden(false)
    end
  end
end

-- View 3 — SURVIVAL: per-tick HP column. Green = HP remaining (min in the tick),
-- red = HP lost this tick, grey = standing wound; HP empties top-down. The death/
-- respawn reads as the green collapsing to nothing then refilling. (Shields are
-- NOT shown here — they live in the OUTCOME view; this stays pure HP.)
local function render_survival_bars()
  release_all_pools()

  local n = Verditer.TemporalBuffer.count()
  if n == 0 then controls.no_data:SetHidden(false); hide_grid(controls.grid); return end
  controls.no_data:SetHidden(true)

  local canvas = controls.canvas
  local cw, ch = canvas:GetWidth(), canvas:GetHeight()
  if cw <= 4 or ch <= 4 then return end

  local ch_plot = math_max(4, ch - TIME_STRIP_H)
  local hp_zone = math_max(4, ch_plot - 12)         -- 12px headroom for the 100% label
  local y100    = TIME_STRIP_H + hp_zone            -- full-HP line, above canvas bottom

  local _, span_ms = extent_dtps()                  -- only the time span is needed here

  -- grid: bright 100% line + faint 50% line + time strip
  hide_grid(controls.grid)
  local g = controls.grid
  g.hlines[1]:ClearAnchors()
  g.hlines[1]:SetAnchor(BOTTOMLEFT,  canvas, BOTTOMLEFT,  0, -y100)
  g.hlines[1]:SetAnchor(BOTTOMRIGHT, canvas, BOTTOMRIGHT, 0, -y100)
  g.hlines[1]:SetColor(C_FULL_LINE.r, C_FULL_LINE.g, C_FULL_LINE.b, C_FULL_LINE.a)
  g.hlines[1]:SetHidden(false)
  local y50 = TIME_STRIP_H + math_floor(hp_zone * 0.5)
  g.hlines[2]:ClearAnchors()
  g.hlines[2]:SetAnchor(BOTTOMLEFT,  canvas, BOTTOMLEFT,  0, -y50)
  g.hlines[2]:SetAnchor(BOTTOMRIGHT, canvas, BOTTOMRIGHT, 0, -y50)
  g.hlines[2]:SetColor(C_GRID_LINE.r, C_GRID_LINE.g, C_GRID_LINE.b, C_GRID_LINE.a)
  g.hlines[2]:SetHidden(false)
  g.ylabels[1]:ClearAnchors()
  g.ylabels[1]:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, 2, -(y100 + 1))
  g.ylabels[1]:SetText("100%")
  g.ylabels[1]:SetHidden(false)
  draw_time_strip(g, canvas, span_ms)

  local slot_w, bar_gap, offset = slot_geometry(cw)

  Verditer.TemporalBuffer.iterate(function(i, s)
    local x, bw = slot_rect(offset, i, slot_w, bar_gap)
    local hp = s.hp_pct
    if hp < 0 then hp = 1 elseif hp > 1 then hp = 1 end
    local drop = s.hp_drop or 0
    if drop < 0 then drop = 0 end

    local green_h = math_max(0, math_floor(hp * hp_zone + 0.5))
    local deficit = 1 - hp
    local red_f   = math_min(drop, deficit)
    local red_h   = math_max(0, math_floor(red_f * hp_zone + 0.5))
    local grey_h  = math_max(0, math_floor((deficit - red_f) * hp_zone + 0.5))

    if green_h > 0 then
      local t = controls.pool_type_seg:AcquireObject()
      t:ClearAnchors(); t:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, x, -TIME_STRIP_H)
      t:SetWidth(bw); t:SetHeight(green_h)
      t:SetColor(C_HP.r, C_HP.g, C_HP.b, C_HP.a); t:SetHidden(false)
    end
    if red_h > 0 then
      local t = controls.pool_type_seg:AcquireObject()
      t:ClearAnchors(); t:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, x, -(TIME_STRIP_H + green_h))
      t:SetWidth(bw); t:SetHeight(red_h)
      t:SetColor(C_HP_FRESH.r, C_HP_FRESH.g, C_HP_FRESH.b, C_HP_FRESH.a); t:SetHidden(false)
    end
    if grey_h > 0 then
      local t = controls.pool_type_seg:AcquireObject()
      t:ClearAnchors(); t:SetAnchor(BOTTOMLEFT, canvas, BOTTOMLEFT, x, -(TIME_STRIP_H + green_h + red_h))
      t:SetWidth(bw); t:SetHeight(grey_h)
      t:SetColor(C_HP_LOST.r, C_HP_LOST.g, C_HP_LOST.b, C_HP_LOST.a); t:SetHidden(false)
    end
  end)
end

local function render_current_view()
  if current_view == VIEW_OUTCOME then
    render_outcome()
  elseif current_view == VIEW_BY_DAMAGE_TYPE then
    render_by_damage_type()
  elseif current_view == VIEW_BY_SOURCE then
    render_by_source()
  else
    render_survival_bars()
  end
end

local function refresh_button_colors()
  local recording = Verditer.TemporalBuffer.is_recording()
  controls.btn_record:SetEnabled(not recording)
  controls.btn_stop:SetEnabled(recording)
end

local function persist_view()
  local sv = Verditer.SavedVars
  if sv then sv.graph = sv.graph or {} ; sv.graph.view_idx = current_view end
end

local function set_view(v)
  current_view = v
  controls.view_label:SetText(VIEW_LABELS[v])
  persist_view()
  if Verditer.TemporalBuffer.count() == 0 then
    controls.no_data:SetHidden(false)
    return
  end
  controls.no_data:SetHidden(true)
  render_current_view()
end

local prof_enter = Verditer.Profiler.enter
local prof_exit  = Verditer.Profiler.exit

local sample_type_scratch   = { count = 0 }
local sample_source_scratch = { count = 0 }

local function on_sample_update()
  prof_enter("graph.sample_tick")
  local now  = GetGameTimeMilliseconds()
  local dtps = Verditer.Metrics.DTPS(now)
  local abs  = Verditer.Metrics.ABS(now)
  Verditer.Metrics.type_groups_into(sample_type_scratch, now)
  Verditer.Metrics.source_groups_into(sample_source_scratch, now)

  local hp_pct  = Verditer.Metrics.hp_sample()    -- min HP fraction over the interval
  local hp_drop = (prev_hp >= 0 and hp_pct >= 0) and math_max(0, prev_hp - hp_pct) or 0
  prev_hp = hp_pct
  Verditer.TemporalBuffer.push(now, dtps, abs, sample_type_scratch, hp_pct, hp_drop, sample_source_scratch)

  update_header(dtps + abs)

  local elapsed = math_floor((now - recording_start_ms) / 1000)
  controls.status:SetText(string_format("%d:%02d", math_floor(elapsed / 60), elapsed % 60))

  if not controls.window:IsHidden() then
    render_current_view()
  end
  prof_exit("graph.sample_tick")
end

function M.current_view() return current_view end

function M.on_record_click()
  if Verditer.TemporalBuffer.is_recording() then return end
  log:info("record click")
  Verditer.TemporalBuffer.clear()
  release_all_pools()
  hide_grid(controls.grid)
  controls.no_data:SetHidden(false)
  Verditer.TemporalBuffer.start_recording()
  recording_start_ms = GetGameTimeMilliseconds()
  Verditer.Metrics.hp_reset()   -- flush any stale dip before this recording
  prev_hp = -1
  local sv       = Verditer.SavedVars
  local interval = (sv and sv.temporal and sv.temporal.sample_rate_ms)
                   or Verditer.Constants.TEMPORAL.SAMPLE_RATE_DEFAULT
  zev.register_update(Verditer.Constants.TEMPORAL.UPDATE_NAME, interval, on_sample_update)
  refresh_button_colors()
  controls.status:SetText("0:00")
end

function M.on_stop_click()
  if not Verditer.TemporalBuffer.is_recording() then return end
  log:info("stop click")
  Verditer.TemporalBuffer.stop_recording()
  zev.unregister_update(Verditer.Constants.TEMPORAL.UPDATE_NAME)
  refresh_button_colors()
  render_current_view()
end

function M.on_flush_click()
  if Verditer.TemporalBuffer.is_recording() then
    zev.unregister_update(Verditer.Constants.TEMPORAL.UPDATE_NAME)
    Verditer.TemporalBuffer.stop_recording()
  end
  Verditer.TemporalBuffer.clear()
  release_all_pools()
  hide_grid(controls.grid)
  refresh_button_colors()
  controls.status:SetText("")
  update_header(0)
  controls.no_data:SetHidden(false)
end

function M.on_close_click()
  Verditer.Visibility.set("graph", false)
  release_all_pools()
end

function M.on_move_stop()
  local sv = Verditer.SavedVars
  if not sv then return end
  sv.graph = sv.graph or {}
  local x, y = controls.window:GetCenter()
  sv.graph.x = x
  sv.graph.y = y
end

function M.on_resize_stop()
  local sv = Verditer.SavedVars
  if sv then
    sv.graph = sv.graph or {}
    local w, h = controls.window:GetDimensions()
    sv.graph.w = w
    sv.graph.h = h
  end
  if not controls.window:IsHidden() then render_current_view() end
end

function M.prev_view()
  local v = current_view - 1
  if v < VIEW_MIN then v = VIEW_MAX end
  release_all_pools()
  set_view(v)
end

function M.next_view()
  local v = current_view + 1
  if v > VIEW_MAX then v = VIEW_MIN end
  release_all_pools()
  set_view(v)
end

function M.set_viewport_alpha(a)
  VerditerGraphWindowViewportBg:SetCenterColor(C_VIEWPORT.r, C_VIEWPORT.g, C_VIEWPORT.b, a)
end

function M.toggle()
  local now_visible = not Verditer.Visibility.get("graph")
  log:info("toggle ->", now_visible and "show" or "hide")
  Verditer.Visibility.set("graph", now_visible)
  if now_visible then
    render_current_view()
  else
    release_all_pools()
  end
end

function M.init()
  controls.window        = VerditerGraphWindow
  controls.title         = VerditerGraphWindowTitleLabel
  controls.btn_record    = VerditerGraphWindowRecordBtn
  controls.btn_stop      = VerditerGraphWindowStopBtn
  controls.btn_flush     = VerditerGraphWindowFlushBtn
  controls.status        = VerditerGraphWindowStatusLabel
  controls.btn_prev_view = VerditerGraphWindowPrevViewBtn
  controls.view_label    = VerditerGraphWindowViewLabel
  controls.btn_next_view = VerditerGraphWindowNextViewBtn
  controls.viewport      = VerditerGraphWindowViewport
  controls.canvas        = VerditerGraphWindowViewportCanvas
  controls.no_data       = VerditerGraphWindowViewportNoDataLabel
  controls.readout       = VerditerGraphWindowReadoutLabel
  controls.itp_icon      = VerditerGraphWindowItpIcon

  local sv = Verditer.SavedVars
  sv.graph = sv.graph or {}
  if sv.graph.view_idx and sv.graph.view_idx >= VIEW_MIN
     and sv.graph.view_idx <= VIEW_MAX then
    current_view = sv.graph.view_idx
  end
  if sv.graph.x then
    controls.window:ClearAnchors()
    controls.window:SetAnchor(CENTER, GuiRoot, TOPLEFT, sv.graph.x, sv.graph.y)
  end
  if sv.graph.w then
    controls.window:SetDimensions(sv.graph.w, sv.graph.h)
  end
  controls.window:SetDimensionConstraints(360, 240, 1000, 700)

  VerditerGraphWindowBg:SetCenterColor(0, 0, 0, 0)
  VerditerGraphWindowChromeTop   :SetColor(C_CHROME.r, C_CHROME.g, C_CHROME.b, C_CHROME.a)
  VerditerGraphWindowChromeBottom:SetColor(C_CHROME.r, C_CHROME.g, C_CHROME.b, C_CHROME.a)
  VerditerGraphWindowChromeLeft  :SetColor(C_CHROME.r, C_CHROME.g, C_CHROME.b, C_CHROME.a)
  VerditerGraphWindowChromeRight :SetColor(C_CHROME.r, C_CHROME.g, C_CHROME.b, C_CHROME.a)
  VerditerGraphWindowBg:SetEdgeColor(0.30, 0.50, 0.95, 1.0)
  local sv_a = (sv.graph and sv.graph.viewport_alpha_pct) or 30
  VerditerGraphWindowViewportBg:SetCenterColor(C_VIEWPORT.r, C_VIEWPORT.g, C_VIEWPORT.b, sv_a / 100)

  controls.grid = create_grid("VerditerGrid", controls.canvas)

  controls.pool_type_seg  = make_fill_pool("VerditerTypeSeg")
  controls.pool_type_line = make_line_pool("VerditerTypeLine")
  controls.pool_up        = make_fill_pool("VerditerUpFill")
  controls.pool_down      = make_fill_pool("VerditerDownFill")
  controls.pool_line_up   = make_line_pool("VerditerLineUp")
  controls.pool_line_down = make_line_pool("VerditerLineDown")

  controls.title:SetText(GetString(VERDITER_GRAPH_TITLE))
  controls.title:SetColor(0.78, 0.84, 0.95, 1)
  controls.btn_record:SetText(GetString(VERDITER_GRAPH_RECORD))
  controls.btn_stop:SetText(GetString(VERDITER_GRAPH_STOP))
  controls.btn_flush:SetText(GetString(VERDITER_GRAPH_FLUSH))
  controls.status:SetText("")
  controls.status:SetColor(0.65, 0.65, 0.65, 1)
  controls.no_data:SetText(GetString(VERDITER_GRAPH_NO_DATA))
  controls.no_data:SetColor(0.45, 0.45, 0.45, 1)
  controls.no_data:SetHidden(false)
  controls.view_label:SetText(VIEW_LABELS[current_view])
  controls.view_label:SetColor(0.78, 0.84, 0.95, 1)

  controls.readout:SetColor(C_LINE_ABS.r, C_LINE_ABS.g, C_LINE_ABS.b, 0.95)
  update_header(0)
  zev.register_update("VerditerHeaderTick", 1000, header_tick)
  refresh_button_colors()
end
