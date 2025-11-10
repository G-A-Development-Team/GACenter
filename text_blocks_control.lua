-- home_panel: reusable Home tab control (scrollable updates)
-- Completely self-contained and reusable across different UIs.
--
-- API:
--   local home = home_panel.new(parent, id, x, y, w, h, opts)
--     opts.active_when -> function() return true when the control should paint (e.g., when visible)
--     opts.scale       -> UI scale (defaults to 0.85)
--     opts.colors      -> optional color overrides (see default_colors)
--     opts.per_page    -> weeks per page (default 5)
--     opts.data_source -> function() -> string|table (JSON text or decoded {weeks=[...]})
--     opts.updates     -> table, decoded {weeks=[...]} used directly (overrides data_source)
--
--   Methods:
--     home:set_bounds(x, y, w, h)
--     home:set_active_when(fn)
--     home:set_scale(scale)
--     home:set_colors(colors_tbl)
--     home:set_per_page(n)
--     home:set_page(n)
--     home:get_page() -> n
--     home:set_data_source(fn_or_nil)
--     home:set_updates(tbl_or_nil) -- set decoded data directly
--     home:scroll_to_top()
--     home:destroy()
--
local M = {}

-- utils
local function clamp(v,a,b) if v<a then return a elseif v>b then return b else return v end end
local function pointInRect(px, py, x1, y1, x2, y2) return px>=x1 and py>=y1 and px<x2 and py<y2 end

-- Minimal JSON ensure (uses global using('json') if available)
local function ensure_json()
  if type(json) == "table" and type(json.decode) == "function" then return true end
  if type(using) == "function" then
    local ok = pcall(using, "json")
    if ok and type(json) == "table" and type(json.decode) == "function" then return true end
  end
  return false
end

local default_colors = {
  bg={17,25,39,255}, header={220,220,230,255}, box_bg={14,16,22,240}, box_border={70,90,130,130},
  text={210,220,235,255}, week={200,210,225,255}, author={190,210,240,240}, rule={60,80,120,140},
  pager_label={200,210,225,255}, btn_prev_bg={60,90,150,180}, btn_prev_hover={80,120,200,200},
  btn_prev_dis={30,40,60,140}, btn_text={230,235,245,255},
}

local function create_fonts(S)
  return {
    title = draw.CreateFont("Segoe UI", S(16), 600),
    mono  = draw.CreateFont("Consolas", S(13), 400),
  }
end

local function fetch_updates_json()
  local content
  if http and http.Get then
    local ok2, res2 = pcall(http.Get, "https://raw.githubusercontent.com/G-A-Development-Team/GACenter/refs/heads/main/updates.json")
    if ok2 and type(res2) == "string" and res2 ~= "" then
      content = res2
    end
  end
  if not content or content == "" then
    content = [[
{
  "weeks": [
    {
      "week": "2025-11-03",
      "title": "This Week’s Highlights",
      "author": "Rovo Dev",
      "items": [
        "Added sm_plus_control clipping for subtitles",
        "Improved button hover states and scrollbar visuals",
        "Refactored list rendering order for clarity"
      ]
    },
    {
      "week": "2025-10-27",
      "title": "Stability & Polish",
      "author": "Rovo Dev",
      "items": [
        "Fix: Subtitle no longer overlaps icons or buttons",
        "Fix: Proper space reservation for action buttons",
        "Tweak: Minor spacing and scaling tuning"
      ]
    }
  ]
}
    ]]
  end
  return content
end

local function to_updates_table(data_source, direct_tbl)
  -- direct table takes precedence if provided
  if type(direct_tbl) == "table" then return direct_tbl end
  -- data_source can return json string or already-decoded table
  local raw
  if type(data_source) == "function" then
    local ok,res = pcall(data_source)
    if ok then raw = res end
  end
  if type(raw) == "table" then return raw end
  local text = type(raw) == "string" and raw or fetch_updates_json()
  if ensure_json() then
    local ok, decoded = pcall(json.decode, text)
    if ok and type(decoded) == "table" then return decoded end
  end
  return { weeks = {} }
end

local _HOME_PANEL_AUTO_ID = _HOME_PANEL_AUTO_ID or 0

function M.new(parent, id, x, y, w, h, opts)
  opts = opts or {}
  if id == nil or id == "" then
    _HOME_PANEL_AUTO_ID = (_HOME_PANEL_AUTO_ID or 0) + 1
    id = "home_panel_" .. tostring(_HOME_PANEL_AUTO_ID)
  end
  local INST = {
    scale = tonumber(opts.scale) or 0.85,
    colors = opts.colors or default_colors,
    per_page = clamp(tonumber(opts.per_page) or 5, 1, 50),
    active_when = type(opts.active_when) == "function" and opts.active_when or function() return true end,
    data_source = opts.data_source,
    direct_updates = opts.updates,
    header_text = opts.title or opts.header_text or "Home",
    show_header = opts.show_header ~= false,
    scroll = 0,
    page = 1,
  }

  local function S(v) return math.floor(v*INST.scale + 0.5) end
  local fonts = create_fonts(S)

  local function draw_wrapped(text, x, y, maxw, lineH)
    local curY = y
    local acc = ""
    for token in tostring(text):gmatch("%S+%s*") do
      local candidate = (acc == "" and token) or (acc .. token)
      local w = ({draw.GetTextSize(candidate)})[1] or 0
      if w <= maxw then
        acc = candidate
      else
        if acc ~= "" then draw.Text(x, curY, (acc:gsub("%s+$",""))) end
        curY = curY + lineH
        acc = token
      end
    end
    if acc ~= "" then draw.Text(x, curY, (acc:gsub("%s+$",""))) end
    return curY + lineH
  end

  local function measure_wrapped(text, x, y, maxw, lineH)
    local curY = y
    local acc = ""
    for token in tostring(text):gmatch("%S+%s*") do
      local candidate = (acc == "" and token) or (acc .. token)
      local w = ({draw.GetTextSize(candidate)})[1] or 0
      if w <= maxw then
        acc = candidate
      else
        curY = curY + lineH
        acc = token
      end
    end
    return curY + lineH
  end

  local function paint(px, py, px2, py2, active)
    if not INST.active_when() then return end

    -- background
    local c = INST.colors
    draw.Color(c.bg[1],c.bg[2],c.bg[3],c.bg[4])
    draw.RoundedRectFill(px,py,px2,py2,4,1,1,1,1)

    local header_h = 0
    if INST.show_header and INST.header_text and INST.header_text ~= "" then
      draw.SetFont(fonts.title)
      draw.Color(c.header[1],c.header[2],c.header[3],c.header[4])
      draw.Text(px + S(10), py + S(8), tostring(INST.header_text))
      header_h = S(26)
    end

    local pad = S(10)
    local cx1, cy1 = px + pad, py + header_h + S(8)
    local cx2, cy2 = px2 - pad, py2 - pad
    local cw, ch = math.max(0, cx2 - cx1), math.max(0, cy2 - cy1)
    local contentRight = cx2 - S(10)

    -- clip to content
    do
      local x=math.floor(cx1+0.5); local y=math.floor(cy1+0.5)
      local w=math.max(0, math.floor(cw+1.5))
      local h=math.max(0, math.floor(ch+1.5))
      draw.SetScissorRect(x,y,w,h)
    end

    draw.SetFont(fonts.mono)
    local updates = to_updates_table(INST.data_source, INST.direct_updates)
    local lineH = S(18)
    local weekGap = S(14)
    local bulletGap = S(10)
    local bulletPad = S(8)

    local all_weeks = updates.weeks or {}
    local total_weeks = #all_weeks
    local total_pages = math.max(1, math.ceil(total_weeks / INST.per_page))
    INST.page = math.max(1, math.min(INST.page or 1, total_pages))
    local page = INST.page
    local start_idx = (page - 1) * INST.per_page + 1
    local end_idx = math.min(total_weeks, start_idx + INST.per_page - 1)
    local page_weeks = {}
    for i = start_idx, end_idx do page_weeks[#page_weeks+1] = all_weeks[i] end

    local function measure_content_height()
      local ty = cy1
      for _, wk in ipairs(page_weeks or {}) do
        ty = ty + lineH
        local author = wk.author and tostring(wk.author) or ""
        author = author:gsub("^%s+"," "):gsub("%s+$","")
        if author ~= "" then
          ty = ty + math.max(S(14), math.floor(lineH))
          ty = ty + S(1)
        end
        local boxY1 = ty + S(4)
        local tmpY = boxY1 + bulletPad
        for _, item in ipairs(wk.items or {}) do
          tmpY = measure_wrapped(tostring(item), (cy1 + S(0)) + bulletPad + S(14), tmpY, (contentRight - cx1) - S(14), lineH)
          tmpY = tmpY + bulletGap
        end
        tmpY = tmpY - bulletGap + bulletPad
        local boxY2 = tmpY
        ty = boxY2 + weekGap
      end
      return math.max(0, ty - cy1)
    end

    local content_h = measure_content_height()
    INST.scroll = math.max(0, math.min(INST.scroll or 0, math.max(0, content_h - ch)))
    local scroll = INST.scroll
    local y = cy1 - scroll

    for _, wk in ipairs(page_weeks or {}) do
      draw.Color(c.week[1],c.week[2],c.week[3],c.week[4])
      local ty = y
      draw.Text(cx1, ty, string.format("%s — %s", tostring(wk.week or ""), tostring(wk.title or "")))
      ty = ty + lineH
      local author = wk.author and tostring(wk.author) or ""
      author = author:gsub("^%s+"," "):gsub("%s+$","")
      if author ~= "" then
        draw.Color(c.author[1],c.author[2],c.author[3],c.author[4])
        draw.Text(cx1, ty, string.format("by %s", author))
        ty = ty + math.max(S(14), math.floor(lineH))
        draw.Color(c.rule[1],c.rule[2],c.rule[3],c.rule[4])
        draw.FilledRect(cx1, ty - S(4), cx2, ty - S(3))
      end

      local boxX1 = cx1
      local boxY1 = ty + S(4)
      local boxX2 = cx2

      -- First draw box background and border
      local measureY = boxY1 + bulletPad
      for _, item in ipairs(wk.items or {}) do
        measureY = measure_wrapped(tostring(item), boxX1 + bulletPad + S(14), measureY, (contentRight - cx1) - S(14), lineH)
        measureY = measureY + bulletGap
      end
      measureY = measureY - bulletGap + bulletPad
      local boxY2 = measureY

      draw.Color(c.box_bg[1],c.box_bg[2],c.box_bg[3],c.box_bg[4])
      draw.FilledRect(boxX1, boxY1, boxX2, boxY2)
      draw.Color(c.box_border[1],c.box_border[2],c.box_border[3],c.box_border[4])
      draw.OutlinedRect(boxX1, boxY1, boxX2, boxY2)

      -- Then draw the text content on top
      draw.Color(c.text[1],c.text[2],c.text[3],c.text[4])
      local tmpY = boxY1 + bulletPad
      for _, item in ipairs(wk.items or {}) do
        draw.Text(boxX1 + bulletPad, tmpY, "• ")
        tmpY = draw_wrapped(tostring(item), boxX1 + bulletPad + S(14), tmpY, (contentRight - cx1) - S(14), lineH)
        tmpY = tmpY + bulletGap
      end

      y = boxY2 + weekGap
    end

    -- mouse wheel scroll inside content rect
    local mx,my = input.GetMousePos()
    if pointInRect(mx,my,cx1,cy1,cx2,cy2) then
      local delta = input.GetMouseWheelDelta() or 0
      if delta ~= 0 then
        local maxScroll = math.max(0, content_h - ch)
        INST.scroll = math.max(0, math.min((INST.scroll or 0) - delta * S(40), maxScroll))
      end
    end

    -- reset clip
    do local sw,sh=draw.GetScreenSize(); draw.SetScissorRect(0,0,sw,sh) end

    -- Pagination controls
    local label = string.format("Page %d / %d", INST.page, math.max(1, math.ceil(total_weeks / INST.per_page)))
    draw.SetFont(fonts.mono)
    draw.Color(c.pager_label[1],c.pager_label[2],c.pager_label[3],c.pager_label[4])
    local tw, th = draw.GetTextSize(label)
    local midX = math.floor((cx1 + cx2) * 0.5)
    local btnW, btnH = S(56), S(18)
    local gap = S(10)
    local bottomPad = S(4)
    local prevY1 = cy2 - bottomPad - btnH

    local prevX1 = midX - gap/2 - btnW
    local prevX2 = prevX1 + btnW
    local prevY2 = prevY1 + btnH
    local nextX1 = midX + gap/2
    local nextY1 = prevY1
    local nextX2 = nextX1 + btnW
    local nextY2 = prevY1 + btnH

    local groupCenter = math.floor(((prevX1 + nextX2) / 2) + 0.5)
    local labelY = prevY1 - S(12)
    draw.Text(groupCenter - math.floor(tw/2), labelY, label)

    local mx2,my2 = input.GetMousePos()
    local overPrev = pointInRect(mx2,my2,prevX1,prevY1,prevX2,prevY2)
    local overNext = pointInRect(mx2,my2,nextX1,nextY1,nextX2,nextY2)

    local function drawBtn(x1,y1,x2,y2,text,enabled,hover)
      local bg = enabled and (hover and c.btn_prev_hover or c.btn_prev_bg) or c.btn_prev_dis
      local fg = enabled and c.btn_text or {160,170,190,180}
      draw.Color(bg[1],bg[2],bg[3],bg[4])
      draw.RoundedRectFill(x1,y1,x2,y2,S(3),1,1,1,1)
      draw.Color(fg[1],fg[2],fg[3],fg[4])
      local w,h = draw.GetTextSize(text)
      draw.Text(x1 + math.floor((x2-x1-w)/2), y1 + math.floor((y2-y1-h)/2), text)
    end

    drawBtn(prevX1, prevY1, prevX2, prevY2, "Prev", page > 1, overPrev)
    drawBtn(nextX1, nextY1, nextX2, nextY2, "Next", page < total_pages, overNext)

    if input.IsButtonReleased and input.IsButtonReleased(1) then
      if overPrev and page > 1 then
        INST.page = math.max(1, page - 1)
        INST.scroll = 0
      elseif overNext and page < total_pages then
        INST.page = math.min(total_pages, page + 1)
        INST.scroll = 0
      end
    end
  end

  local custom = gui.Custom(parent, tostring(id or "home_panel"), x, y, w, h, paint, nil, nil)

  local inst = { _custom = custom, _state = INST }

  function inst:set_bounds(nx, ny, nw, nh)
    if self._custom and self._custom.SetPosX then
      self._custom:SetPosX(nx)
      self._custom:SetPosY(ny)
      self._custom:SetWidth(nw)
      self._custom:SetHeight(nh)
    end
  end
  function inst:set_active_when(fn) if type(fn)=="function" then self._state.active_when=fn end end
  function inst:set_scale(s) s=tonumber(s); if s and s>0 then self._state.scale=s end end
  function inst:set_colors(tbl) if type(tbl)=="table" then self._state.colors=tbl end end
  function inst:set_per_page(n) n=tonumber(n); if n then self._state.per_page=clamp(n,1,50) end end
  function inst:set_page(n) n=tonumber(n); if n then self._state.page=math.max(1,math.floor(n)) end end
  function inst:get_page() return self._state.page end
  function inst:set_data_source(fn) if fn==nil or type(fn)=="function" then self._state.data_source=fn end end
  function inst:set_updates(tbl) if tbl==nil or type(tbl)=="table" then self._state.direct_updates=tbl end end
  function inst:scroll_to_top() self._state.scroll=0 end
  function inst:destroy() self._custom=nil end

  return inst
end

return M
