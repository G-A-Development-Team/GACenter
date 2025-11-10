-- sm_plus_control: reusable tabbed script manager control
-- API:
--   local sm = sm_plus_control.new(parentWindow, id, x, y, w, h, opts)
--   sm:refresh()
--   sm:set_title(title)
--   sm:set_active_tab("Home"|"Settings")
--   sm:set_providers{ data_provider=function(folder)->items, on_action=function(action, entry, state) }
--   sm:register_button_provider(function(entry, inst) -> { {icon="?", id="custom", on_click=function(entry, btn) end}, ... })
--   sm:get_state() -> { loadedSet=..., failedSet=..., failedReason=... }
--   sm:destroy()
--
-- Buttons extension notes:
-- - Additional buttons can be injected per entry via:
--     1) Entry.extra_buttons = { {icon=..., id=...,[on_click=function] }, ... } OR a function(entry)->table
--     2) sm:register_button_provider(function(entry, inst) return {...} end)
-- - Click handling order: explicit btn.on_click -> providers.on_action("button", entry, {id=btn.id, btn=btn})
-- - Default actions "load"/"unload" are still supported
--
-- Notes:
-- - Mirrors the Home (list) + Settings structure from GA_Development_Center.lua
-- - Designed so you can create multiple instances in different windows/positions
-- - Keeps visuals similar; simplified icon rendering (fallback vector only)

local M = {}

local function clamp(v,a,b) if v<a then return a elseif v>b then return b else return v end end
local function pointInRect(px, py, x1, y1, x2, y2) return px>=x1 and py>=y1 and px<x2 and py<y2 end
local function normalize_path(p) p=tostring(p or ""):gsub("\\","/"):gsub("/+","/") return p end
local function clipResetToScreen() local sw,sh=draw.GetScreenSize() draw.SetScissorRect(0,0,sw,sh) end
local function clipRect(x,y,w,h)
  x=math.floor(x+0.5); y=math.floor(y+0.5)
  w=math.max(0,math.floor(w+1.5)); h=math.max(0,math.floor(h+1.5))
  draw.SetScissorRect(x,y,w,h)
end
-- Compute intersection of two rects A(ax,ay,aw,ah) and B(bx,by,bw,bh)
local function intersectRect(ax, ay, aw, ah, bx, by, bw, bh)
  local ax2, ay2 = ax + aw, ay + ah
  local bx2, by2 = bx + bw, by + bh
  local ix1 = math.max(ax, bx)
  local iy1 = math.max(ay, by)
  local ix2 = math.min(ax2, bx2)
  local iy2 = math.min(ay2, by2)
  local iw = math.max(0, ix2 - ix1)
  local ih = math.max(0, iy2 - iy1)
  return ix1, iy1, iw, ih
end

function M.new(parent, id, x, y, w, h, opts)
  opts = opts or {}
  id = tostring(id or ("ctrl_"..tostring(math.random(1000,9999))))

  local SCALE = opts.scale or 0.9
  local function s(v) return math.floor(v*SCALE+0.5) end

  local colors = opts.colors or {
    bg={17,25,39,255}, header_bg={30,33,39,255}, header_text={220,220,220,255},
    row_hover={45,49,58,255}, title={235,235,235,255}, subtitle={160,162,168,255}, icon_file={150,158,168,255},
    header_btn_bg={64,70,84,255}, header_btn_hover={86,93,110,255}, header_btn_border={110,118,135,200},
    btn_border={20,20,22,200}, btn_text={240,240,240,255},
    btn_load_bg={32,140,85,255}, btn_load_hover={38,165,100,255}, btn_unload_bg={176,56,56,255}, btn_unload_hover={200,70,70,255},
    scrollbar_track={45,50,59,120}, scrollbar_thumb={110,116,128,210},
  }

  local fontTitle = draw.CreateFont("Segoe UI", s(15), 500)
  local fontSub   = draw.CreateFont("Segoe UI", s(12), 400)
  local fontHeader= draw.CreateFont("Segoe UI", s(16), 600)

  local GAP      = s(6)

  local inst = {
    title = opts.title or "GA Development Center",
    USER = { icon_size = clamp(tonumber(opts.icon_size) or 34, 12, 96) },
    loadedSet = {}, failedSet = {}, failedReason = {},
  }

  -- External predicate to control when the list should paint (e.g., active tab)
  local should_paint = type(opts.active_when) == "function" and opts.active_when or function() return true end

  -- Providers (can be overridden)
  local function read_manifest(path)
    local ok,data=pcall(function() return file.Read(path) end)
    if not ok or type(data)~="string" then return nil end
    local head=data:sub(1,2048)
    local m={}
    m.name=head:match("%-%-+%s*sm_name%s*:%s*([^\r\n]+)")
    m.icon=head:match("%-%-+%s*sm_icon%s*:%s*([^\r\n]+)")
    m.icon_type=head:match("%-%-+%s*sm_icon_type%s*:%s*([^\r\n]+)")
    if m.name or m.icon or m.icon_type then return m end
    return nil
  end

  -- Default provider returns any items external caller specifies via opts.items_provider
  local function default_list_files(folder)
    if type(opts.items_provider)=="function" then
      local ok, list = pcall(function() return opts.items_provider(folder) end)
      if ok and type(list)=="table" then
        return list
      end
    end
    -- Fallback: keep original local-file scan as a backward-compat option
    local show_all = folder == "<all>"; folder = show_all and "" or normalize_path(folder)
    local items,seen={},{}
    pcall(function()
      file.Enumerate(function(path)
        path=normalize_path(path)
        if type(path)=="string" and path:lower():sub(-4)==".lua" then
          if show_all or path:sub(1,#folder+1)==folder.."/" then
            local base=path:match("([^/]+)$") or path
            if base:lower() ~= "script_manager_plus.lua" then
              if not seen[path] then
                seen[path]=true
                local m=read_manifest(path)
                table.insert(items,{
                  name=base, full=path, display_name=m and m.name or base, icon=m and m.icon or nil, icon_type=m and m.icon_type or nil,
                })
              end
            end
          end
        end
      end)
    end)
    table.sort(items,function(a,b)
      local an=(a.display_name or a.name):lower(); local bn=(b.display_name or b.name):lower(); return an<bn
    end)
    return items
  end

  -- By default, the control does not execute anything. The host must provide opts.on_action.
  local function default_on_action(action, entry, state)
    return false, "No on_action handler provided"
  end

  local providers = {
    data_provider = opts.data_provider or default_list_files,
    on_action = opts.on_action or default_on_action,
  }

  local button_providers = {}
  function inst:register_button_provider(fn)
    if type(fn) == "function" then table.insert(button_providers, fn) end
  end

  -- Data model
  local folders={"<all>"}
  do -- rebuild folders
    local seen={ ["<all>"]=true }
    pcall(function()
      file.Enumerate(function(path)
        path=normalize_path(path)
        local dir=path:match("^([^/]+)/")
        if dir and not seen[dir] then seen[dir]=true; table.insert(folders,dir) end
      end)
    end)
  end
  local activeFolderIndex=1
  local entries={}
  local function set_entries(files)
    entries={}
    for i=1,#files do
      local f=files[i]
      local loadKey = f.full or f.link or (f.exec and tostring(f.exec))
      local isLoaded = (loadKey~=nil) and (inst.loadedSet[loadKey]==true) or false
      local disp = f.display_name or f.name or (f.full or f.link or "Item "..i)
      local default_buttons = isLoaded and {{icon="▶",action="load"},{icon="■",action="unload"}} or {{icon="▶",action="load"}}

      -- collect extra buttons from entry.extra_buttons or providers
      local extra = {}
      if type(f.extra_buttons) == "function" then
        local ok, res = pcall(f.extra_buttons, f)
        if ok and type(res) == "table" then extra = res end
      elseif type(f.extra_buttons) == "table" then
        extra = f.extra_buttons
      end
      -- from registered providers
      for _,fn in ipairs(button_providers) do
        local ok, res = pcall(fn, f, inst)
        if ok and type(res) == "table" then
          for _,btn in ipairs(res) do table.insert(extra, btn) end
        end
      end

      table.insert(entries,{
        title = disp..(isLoaded and " (loaded)" or ""),
        full = f.full,
        link = f.link,
        exec = f.exec,
        key = loadKey,
        subtitle = f.subtitle or f.full or f.link or "",
        icon = f.icon,
        icon_type = f.icon_type,
        -- propagate update feed fields so Info popup can access them
        ["updates.json"] = f["updates.json"],
        updates_json = f.updates_json,
        updates = f.updates,
        -- keep original source for any future needs
        _source = f,
        buttons = default_buttons,
        extra_buttons = extra,
      })
    end
  end
  function inst:refresh()
    local folder = folders[activeFolderIndex] or "<all>"
    local files = providers.data_provider(folder)
    if type(files) ~= "table" then files = {} end
    set_entries(files)

    if entries[1] then  end
  end
  function inst:set_title(t) self.title=tostring(t or self.title) end
  -- removed: set_active_tab (tabs managed externally)
  function inst:set_providers(p) if p then providers.data_provider=p.data_provider or providers.data_provider; providers.on_action=p.on_action or providers.on_action end end
  function inst:get_state() return { loadedSet=self.loadedSet, failedSet=self.failedSet, failedReason=self.failedReason } end

  -- List UI state
  local scrollOffset=0
  local rowHeight=s(46)
  local iconSize=s(inst.USER.icon_size)
  local contentPadding=s(14)
  local buttonWidth,buttonHeight,buttonGap=s(30),s(24),s(8)
  local cornerRadius=s(4)
  local hoveredRow, hoveredButtonIndex=-1,-1
  -- Animation state (ported from script_manager.lua)
  local _clickGuardUntil = 0
  local _rowHoverAnim = {}
  local _lastTime = (common and common.Time and common.Time() or 0)
  local function approach(v, target, delta)
    if v < target then v = v + delta; if v > target then v = target end
    elseif v > target then v = v - delta; if v < target then v = target end
    end
    return v
  end

  -- Icon texture cache
  local _iconCache = {}
  local function get_icon_texture(icon, icon_type)
    if type(icon) ~= "string" or #icon == 0 then return false end
    local key = icon .. "|" .. tostring(icon_type or "")
    if _iconCache[key] ~= nil then return _iconCache[key] end
    local function safe_decode(doit)
      local ok, a,b,c = pcall(doit)
      if ok then return a,b,c end
      return nil
    end
    local lower = icon:lower()
    local forced = icon_type and icon_type:lower() or nil
    local tex = nil
    local function make_texture_from_rgba(rgba, iw, ih)
      if rgba and iw and ih then
        local ok, t = pcall(draw.CreateTexture, rgba, iw, ih)
        if ok then return t end
      end
      return nil
    end
    if lower:find("^https?://") then
      local body = safe_decode(function() return http.Get(icon) end)
      if type(body) == "string" and #body > 0 then
        local isSVG = (forced == "svg") or (not forced and lower:match("%.svg$") ~= nil)
        local isPNG = (forced == "png") or (not forced and lower:match("%.png$") ~= nil)
        local isJPG = (forced == "jpg") or (forced == "jpeg") or (not forced and lower:match("%.jpe?g$") ~= nil)
        if isSVG and common and common.RasterizeSVG then
          local rgba, iw, ih = safe_decode(function() return common.RasterizeSVG(body) end)
          tex = make_texture_from_rgba(rgba, iw, ih)
        elseif (isPNG or isJPG) and common then
          local rgba, iw, ih
          if isPNG and common.DecodePNG then rgba, iw, ih = safe_decode(function() return common.DecodePNG(body) end) end
          if (not rgba) and isJPG and common.DecodeJPEG then rgba, iw, ih = safe_decode(function() return common.DecodeJPEG(body) end) end
          tex = make_texture_from_rgba(rgba, iw, ih)
        elseif common then
          local rgba, iw, ih = nil,nil,nil
          if common.DecodePNG then rgba, iw, ih = safe_decode(function() return common.DecodePNG(body) end) end
          if (not rgba) and common.DecodeJPEG then rgba, iw, ih = safe_decode(function() return common.DecodeJPEG(body) end) end
          tex = make_texture_from_rgba(rgba, iw, ih)
        end
      end
    else
      local content = safe_decode(function() return file.Read(icon) end)
      if type(content) == "string" and #content > 0 then
        if (forced == "svg") or (not forced and lower:match("%.svg$")) then
          if common and common.RasterizeSVG then
            local rgba, iw, ih = safe_decode(function() return common.RasterizeSVG(content) end)
            tex = make_texture_from_rgba(rgba, iw, ih)
          end
        elseif common then
          local rgba, iw, ih = nil,nil,nil
          if (forced == "png") or (not forced and lower:match("%.png$")) then
            if common.DecodePNG then rgba, iw, ih = safe_decode(function() return common.DecodePNG(content) end) end
          else
            if common.DecodeJPEG then rgba, iw, ih = safe_decode(function() return common.DecodeJPEG(content) end) end
          end
          tex = make_texture_from_rgba(rgba, iw, ih)
        end
      end
    end
    _iconCache[key] = tex or false
    return _iconCache[key]
  end

  -- Header painter removed (managed externally)

  -- Tabs painter removed (managed externally)

  -- List painter
  local function paintList(px,py,px2,py2,active)
    if not should_paint() then return end
    local width,height = px2-px, py2-py
    -- Ensure no stale scissor from other painters
    clipResetToScreen()
    draw.SetTexture(nil)
    -- Apply scissor for list content to prevent bleed
    clipRect(px,py,width,height)
    local rowH=rowHeight
    local iconSZ = math.max(s(12), math.min(iconSize, rowH - s(8)))

    draw.Color(colors.bg[1],colors.bg[2],colors.bg[3],colors.bg[4])
    draw.RoundedRectFill(px,py,px2,py2,cornerRadius,1,1,1,1)

    local mx,my=input.GetMousePos()
    local mouseIn=pointInRect(mx,my,px,py,px2,py2)
    local allow_modal = (opts and opts.allow_input_when_modal) == true
    local input_blocked = (_G and _G.GADC_INFO_MODAL and _G.GADC_INFO_MODAL.visible) and (not allow_modal) or false
    if input_blocked then mouseIn=false end
    local wheel=input.GetMouseWheelDelta()
    if (not input_blocked) and mouseIn and wheel~=0 then
      scrollOffset = math.max(0, math.min(scrollOffset - wheel * s(40), math.max(0,(#entries*rowHeight)-height)))
    end
    hoveredRow, hoveredButtonIndex=-1,-1

    -- Anim timing
    local now = (common and common.Time and common.Time() or 0)
    local dt = math.max(0, math.min(0.05, now - _lastTime))
    _lastTime = now

    clipRect(px,py,width,height)
    local contentLeft=px + contentPadding
    local contentRight=px2 - contentPadding

    for idx,e in ipairs(entries) do
      local top = py + (idx-1)*rowH - scrollOffset
      local bottom = top + rowH
      if bottom>=py and top<=py2 then
        local isHover = mouseIn and pointInRect(mx,my,px,top,px2,bottom)
        if isHover then hoveredRow=idx end

        -- Animated hover background
        local anim = _rowHoverAnim[idx] or 0
        local target = isHover and 1 or 0
        local speedIn, speedOut = (1/0.15), (1/0.20)
        local speed = (target > anim) and speedIn or speedOut
        anim = approach(anim, target, dt * speed)
        _rowHoverAnim[idx] = anim
        if anim > 0.001 then
          clipRect(px,py,width,height)
          local c=colors.row_hover
          local a = math.floor((c[4] or 255) * anim + 0.5)
          draw.Color(c[1],c[2],c[3],a)
          draw.FilledRect(px, top, px2 - s(8), bottom)
          clipRect(px,py,width,height)
        end

        -- icon (remote/local with optional type), fallback to vector
        local iconX=contentLeft
        local iconY=top + math.floor((rowH - iconSZ)/2)
        local tex=nil
        if e.icon then
          tex = get_icon_texture(e.icon, e.icon_type)
          if tex==false then tex=nil end
        end
        if tex then
          draw.SetTexture(tex)
          draw.Color(255,255,255,255)
          draw.FilledRect(iconX, iconY, iconX + iconSZ, iconY + iconSZ)
          draw.SetTexture(nil)
        else
          -- fallback vector icon
          draw.Color(colors.icon_file[1],colors.icon_file[2],colors.icon_file[3],colors.icon_file[4])
          draw.FilledRect(iconX+2,iconY+2,iconX+iconSZ-2,iconY+iconSZ-2)
          draw.Color(colors.bg[1],colors.bg[2],colors.bg[3],colors.bg[4])
          draw.Triangle(iconX+iconSZ-8,iconY+2,iconX+iconSZ-2,iconY+2,iconX+iconSZ-2,iconY+8)
        end

        -- text
        local textLeft = iconX + iconSZ + s(10)
        draw.SetFont(fontTitle)
        local isSelected = (inst.selectedPath ~= nil and e.key ~= nil and inst.selectedPath == e.key)
        local titleColor = isSelected and {80,220,150,255} or colors.title
        draw.Color(titleColor[1],titleColor[2],titleColor[3],titleColor[4])
        -- draw title plainly for visibility
        local tY = top + s(6)
        draw.Text(textLeft, tY, e.title or "")

        draw.SetFont(fontSub)
        draw.Color(colors.subtitle[1],colors.subtitle[2],colors.subtitle[3],colors.subtitle[4])
        do
          local sub = e.subtitle or ""
          local textY = top + s(24)
          -- Reserve space for right-side buttons (default + extra) so subtitle never goes under them
          local availRight = contentRight - s(8)
          do
            local nb = (e.buttons and #e.buttons or 0)
            local ne = (e.extra_buttons and #e.extra_buttons or 0)
            local total = nb + ne
            if total > 0 then
              local reserve=(total*buttonWidth) + math.max(0,(total-1))*buttonGap + s(8)
              availRight = availRight - reserve
            end
          end
          local availWidth = math.max(0, availRight - textLeft)
          local tw, th = draw.GetTextSize(sub)

          -- Clip subtitle strictly inside [textLeft, availRight]
          if availWidth > 0 then
            clipRect(textLeft, top, availWidth, rowH)
          end

          if tw <= availWidth or availWidth <= 0 then
            draw.Text(textLeft, textY, sub)
          else
            if isHover then
              local tnow = (common and common.Time and common.Time() or 0)
              local speed = s(40)
              local overflow = tw - availWidth
              if overflow < 1 then
                draw.Text(textLeft, textY, sub)
              else
                local loop = overflow * 2
                local off = (tnow * speed) % loop
                if off > overflow then off = loop - off end
                off = math.max(0, math.min(off, overflow))
                draw.Text(textLeft - math.floor(off + 0.5), textY, sub)
              end
            else
              draw.Text(textLeft, textY, sub)
            end
          end

          -- Restore list clipping
          clipRect(px,py,width,height)
        end

        -- buttons (default + extra)
        if isHover then
          local btnRight = contentRight - s(8)
          local btnY = top + math.floor((rowH - buttonHeight)/2)
          local function paint_button(btn, idx)
            local bx1,by1 = btnRight - buttonWidth, btnY
            local bx2,by2 = btnRight, btnY + buttonHeight
            local bHover = mouseIn and pointInRect(mx,my,bx1,by1,bx2,by2)
            local fill
            if btn.action=="load" then fill = bHover and colors.btn_load_hover or colors.btn_load_bg
            elseif btn.action=="unload" then fill = bHover and colors.btn_unload_hover or colors.btn_unload_bg
            else fill = bHover and colors.header_btn_hover or colors.header_btn_bg end
            draw.Color(fill[1],fill[2],fill[3],fill[4])
            draw.RoundedRectFill(bx1,by1,bx2,by2,s(4),1,1,1,1)
            local bc=colors.btn_border
            draw.Color(bc[1],bc[2],bc[3],bc[4])
            draw.RoundedRect(bx1,by1,bx2,by2,s(4),1,1,1,1)
            local tc=colors.btn_text
            draw.Color(tc[1],tc[2],tc[3],tc[4])
            local pad = s(6)
            local cx1, cy1 = bx1 + pad, by1 + pad
            local cx2, cy2 = bx2 - pad, by2 - pad
            if btn.action=="load" then
              local innerH = cy2 - cy1
              local triW = math.floor(innerH * 0.6 + 0.5)
              local px1 = math.floor((bx1 + bx2 - triW) / 2)
              local py1 = cy1
              local py2 = cy2
              local midY = math.floor((py1 + py2) / 2)
              draw.Triangle(px1, py1, px1, py2, px1 + triW, midY)
            elseif btn.action=="unload" then
              local w2 = cx2 - cx1
              local h2 = cy2 - cy1
              local sz = math.floor(math.min(w2, h2) * 0.6 + 0.5)
              local cxm = math.floor((bx1 + bx2) / 2)
              local cym = math.floor((by1 + by2) / 2)
              local sx1 = cxm - math.floor(sz / 2)
              local sy1 = cym - math.floor(sz / 2)
              draw.FilledRect(sx1, sy1, sx1 + sz, sy1 + sz)
            else
              draw.SetFont(fontSub)
              local tw, th = draw.GetTextSize(btn.icon or "")
              draw.Text(bx1 + math.floor((buttonWidth - tw) / 2), by1 + math.floor((buttonHeight - th) / 2), btn.icon or "")
            end
            if bHover then hoveredButtonIndex=idx end
            btnRight = bx1 - buttonGap
          end
          -- default buttons (rightmost)
          if e.buttons then
            for b=#e.buttons,1,-1 do paint_button(e.buttons[b], b) end
          end
          -- then extra buttons to the left
          if e.extra_buttons and #e.extra_buttons>0 then
            for b=#e.extra_buttons,1,-1 do paint_button(e.extra_buttons[b], 1000 + b) end
          end
        end
      end
    end

    -- Draw vertical scrollbar (from script_manager_plus style)
    do
      local contentH = #entries * rowH
      if contentH > height then
        local barW = s(6)
        local pad = s(4)
        local trackX1 = px2 - pad - barW
        local trackX2 = px2 - pad
        local trackY1 = py
        local trackY2 = py + height
        -- track
        draw.Color(colors.scrollbar_track[1], colors.scrollbar_track[2], colors.scrollbar_track[3], colors.scrollbar_track[4])
        draw.RoundedRectFill(trackX1, trackY1, trackX2, trackY2, s(3), 1, 1, 1, 1)
        -- thumb size/pos
        local thumbH = math.max(s(14), math.floor((height * height) / contentH + 0.5))
        local maxScroll = math.max(1, contentH - height)
        local t = math.max(0, math.min(1, scrollOffset / maxScroll))
        local thumbY1 = trackY1 + math.floor((height - thumbH) * t + 0.5)
        local thumbY2 = thumbY1 + thumbH
        draw.Color(colors.scrollbar_thumb[1], colors.scrollbar_thumb[2], colors.scrollbar_thumb[3], colors.scrollbar_thumb[4])
        draw.RoundedRectFill(trackX1 + 1, thumbY1, trackX2 - 1, thumbY2, s(3), 1, 1, 1, 1)
      end
    end

    clipResetToScreen()

    if (not (_G and _G.GADC_INFO_MODAL and _G.GADC_INFO_MODAL.visible)) and mouseIn and hoveredRow>0 and hoveredButtonIndex>0 and input.IsButtonReleased(1) then
      local e = entries[hoveredRow]
      local btn = nil
      local is_extra = false
      if e and hoveredButtonIndex >= 1000 then
        local idx = hoveredButtonIndex - 1000
        btn = e.extra_buttons and e.extra_buttons[idx]
        is_extra = true
      else
        btn = e and e.buttons and e.buttons[hoveredButtonIndex]
      end
      if btn then
        local handled = false
        -- built-in actions
        if btn.action == "load" then
          if type(e.exec) == "function" then
            local ok, err = pcall(e.exec)
            if not ok then  end
          else
            --print("[sm_plus_control] no exec defined for this item")
          end
          handled = true
        elseif btn.action == "unload" then
          if type(e.exec_unload) == "function" then
            local ok, err = pcall(e.exec_unload)
            if not ok then  end
          end
          handled = true
        end
        -- custom on_click on the button
        if not handled and type(btn.on_click) == "function" then
          local ok, err = pcall(btn.on_click, e, btn)
          if not ok then end
          handled = true
        end
        -- provider on_action fallback
        if not handled and type(providers.on_action) == "function" then
          local ok, err = pcall(providers.on_action, "button", e, {id=btn.id or btn.action, btn=btn})
          if not ok then  end
        end
        -- select item and refresh
        if e then inst.selectedPath = e.key or e.full or e.link end
        inst:refresh()
      end
    end

    if (not (_G and _G.GADC_INFO_MODAL and _G.GADC_INFO_MODAL.visible)) and mouseIn and hoveredRow>0 and hoveredButtonIndex<=0 and input.IsButtonReleased(1) then
      local e=entries[hoveredRow]
      if e then inst.selectedPath = e.key or e.full or e.link end
    end
  end

  -- Settings painter
  local hoveredDec,hoveredInc,hoveredReset=false,false,false
  local function paintSettings(px,py,px2,py2,active)
    if inst.activeTab ~= "Settings" then return end
    draw.Color(colors.bg[1],colors.bg[2],colors.bg[3],colors.bg[4])
    draw.RoundedRectFill(px,py,px2,py2,s(4),1,1,1,1)
    local mx,my=input.GetMousePos()
    local pad=s(12)
    local line=py + pad
    draw.SetFont(fontHeader)
    draw.Color(colors.header_text[1],colors.header_text[2],colors.header_text[3],colors.header_text[4])
    draw.Text(px + pad, line, "Settings")
    line = line + s(28)

    draw.SetFont(fontSub)
    draw.Color(colors.subtitle[1],colors.subtitle[2],colors.subtitle[3],colors.subtitle[4])
    draw.Text(px + pad, line, "Icon size")
    local btnW,btnH=s(26),s(22)
    local gap=s(8)
    local bx=px + pad + s(120)
    local by=line - s(4)

    local decX1,decY1,decX2,decY2=bx,by,bx+btnW,by+btnH
    hoveredDec=pointInRect(mx,my,decX1,decY1,decX2,decY2)
    local decbg=hoveredDec and colors.header_btn_hover or colors.header_btn_bg
    draw.Color(decbg[1],decbg[2],decbg[3],decbg[4])
    draw.RoundedRectFill(decX1,decY1,decX2,decY2,s(4),1,1,1,1)
    draw.Color(colors.header_btn_border[1],colors.header_btn_border[2],colors.header_btn_border[3],colors.header_btn_border[4])
    draw.RoundedRect(decX1,decY1,decX2,decY2,s(4),1,1,1,1)
    draw.Color(colors.btn_text[1],colors.btn_text[2],colors.btn_text[3],colors.btn_text[4])
    draw.Text(decX1 + s(9), decY1 + s(2), "-")

    local valX = decX2 + gap
    draw.SetFont(fontSub)
    local valStr = tostring(inst.USER.icon_size)
    local vW, vH = draw.GetTextSize(valStr)
    draw.Text(valX, by + s(2), valStr)

    local incX1=valX + vW + gap
    local incX2=incX1 + btnW
    local incY1,incY2=decY1,decY2
    hoveredInc=pointInRect(mx,my,incX1,incY1,incX2,incY2)
    local incbg=hoveredInc and colors.header_btn_hover or colors.header_btn_bg
    draw.Color(incbg[1],incbg[2],incbg[3],incbg[4])
    draw.RoundedRectFill(incX1,incY1,incX2,incY2,s(4),1,1,1,1)
    draw.Color(colors.header_btn_border[1],colors.header_btn_border[2],colors.header_btn_border[3],colors.header_btn_border[4])
    draw.RoundedRect(incX1,incY1,incX2,incY2,s(4),1,1,1,1)
    draw.Color(colors.btn_text[1],colors.btn_text[2],colors.btn_text[3],colors.btn_text[4])
    draw.Text(incX1 + s(8), incY1 + s(2), "+")

    local resetW=s(60)
    local resetX1=incX2 + gap*2
    local resetX2=resetX1 + resetW
    local resetY1,resetY2=decY1,decY2
    hoveredReset=pointInRect(mx,my,resetX1,resetY1,resetX2,resetY2)
    local rbg=hoveredReset and colors.header_btn_hover or colors.header_btn_bg
    draw.Color(rbg[1],rbg[2],rbg[3],rbg[4])
    draw.RoundedRectFill(resetX1,resetY1,resetX2,resetY2,s(4),1,1,1,1)
    draw.Color(colors.header_btn_border[1],colors.header_btn_border[2],colors.header_btn_border[3],colors.header_btn_border[4])
    draw.RoundedRect(resetX1,resetY1,resetX2,resetY2,s(4),1,1,1,1)
    draw.Color(colors.btn_text[1],colors.btn_text[2],colors.btn_text[3],colors.btn_text[4])
    draw.Text(resetX1 + s(10), resetY1 + s(2), "Reset")

    if input.IsButtonReleased(1) then
      local clampv=function(v) return clamp(v,12,96) end
      if hoveredDec then inst.USER.icon_size=clampv(inst.USER.icon_size-2) end
      if hoveredInc then inst.USER.icon_size=clampv(inst.USER.icon_size+2) end
      if hoveredReset then inst.USER.icon_size=34 end
      iconSize = s(inst.USER.icon_size)
    end
  end

  -- Create only the list control; header/tabs managed by GA_Development_Center
  local list   = gui.Custom(parent, id..".list", x, y, w, h, paintList, nil, nil)
 inst._list = list
 function inst:set_bounds(nx, ny, nw, nh)
   if self._list and self._list.SetPosX then
     self._list:SetPosX(nx)
     self._list:SetPosY(ny)
     self._list:SetWidth(nw)
     self._list:SetHeight(nh)
   end
 end

 function inst:destroy()
    -- No explicit destroy in this environment; caller can SetActive(false) on parent or ignore
 end

 -- initial
 inst:refresh()
 return inst
end

return M
