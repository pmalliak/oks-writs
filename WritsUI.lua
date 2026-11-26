-- WritsUI.lua: the writ list. Filter by the delivery NPC's zone, profession and
-- writs you hold, tick writs, and add the items they ask for to a buy list.
local _, ns = ...

local ROWS, ROW_H = 16, 20
local W, H = 1070, 520
local UNKNOWN = "?"
local COLS = { -- x offset, width
    check = { 6, 20 }, writ = { 30, 200 }, item = { 234, 180 }, prof = { 418, 82 }, npc = { 504, 124 },
    zone = { 632, 104 }, coords = { 740, 58 }, spot = { 802, 34 },
    rep = { 840, 40 }, perRep = { 884, 86 }, total = { 976, 70 },
}

local frame, rows, shown, offset = nil, {}, {}, 0
local page, planPage, tabs -- the Writs tab's page, the Crates & Receipts page, the tab buttons

-- The writs the list shows now (the price scan covers these).
function ns.ShownWrits()
    return shown
end
local selected = {}
local ui = {}

-- Data -----------------------------------------------------------------------

local function ItemNameOf(w)
    local fallback = w.name:gsub("^Craftsman's Writ: ", "")
    w.itemName = ns.ItemName(w.item, fallback)
    return w.itemName
end

local Holding = ns.HaveWrit

local function ZoneOf(w)
    return w.zone or UNKNOWN
end

local function Distance(w)
    if not (w.map and w.x) then return nil end
    local pos = C_Map.GetPlayerMapPosition(w.map, "player")
    if not pos then return nil end
    local px, py = pos:GetXY()
    if not px or (px == 0 and py == 0) then return nil end
    local dx, dy = px * 100 - w.x, py * 100 - w.y
    return math.sqrt(dx * dx + dy * dy)
end

local SORTS = {
    zone = { label = "Zone, then position", fn = function(a, b)
        local za, zb = ZoneOf(a), ZoneOf(b)
        if za ~= zb then
            if za == UNKNOWN or zb == UNKNOWN then return zb == UNKNOWN end
            return za < zb
        end
        if (a.spot or 99) ~= (b.spot or 99) then return (a.spot or 99) < (b.spot or 99) end
        local xa, xb = a.x or 999, b.x or 999
        if math.abs(xa - xb) > 0.05 then return xa < xb end
        if (a.y or 999) ~= (b.y or 999) then return (a.y or 999) < (b.y or 999) end
        return a.itemName < b.itemName
    end },
    spot = { label = "Busiest spots first", fn = function(a, b)
        local sa, sb = a.spotWrits or 0, b.spotWrits or 0
        if sa ~= sb then return sa > sb end
        local za, zb = ZoneOf(a), ZoneOf(b)
        if za ~= zb then return za < zb end
        if (a.spot or 99) ~= (b.spot or 99) then return (a.spot or 99) < (b.spot or 99) end
        return a.itemName < b.itemName
    end },
    near = { label = "Nearest to me", fn = function(a, b)
        local da, db = a.dist or 1e9, b.dist or 1e9
        if da ~= db then return da < db end
        return a.itemName < b.itemName
    end },
    item = { label = "Item name", fn = function(a, b) return a.itemName < b.itemName end },
    price = { label = "Cheapest total", fn = function(a, b)
        local ta, tb = a.cost or 1e12, b.cost or 1e12
        if ta ~= tb then return ta < tb end
        return a.itemName < b.itemName
    end },
}

-- Clicking a column header sorts by that column; clicking again reverses it.
local COL_SORT = {
    writ = function(w) return w.name end,
    item = function(w) return w.itemName end,
    prof = function(w) return w.prof end,
    npc = function(w) return w.npc end,
    zone = function(w) return w.zone and (w.zone .. (" %02d %06.2f"):format(w.spot or 99, w.x or 999)) end,
    coords = function(w) return w.x and (w.x * 1000 + (w.y or 0)) end,
    -- Spot size first, then zone and spot, so each spot's writs stay together.
    spot = function(w) return w.spotWrits and ("%03d %s %02d"):format(w.spotWrits, w.zone or "", w.spot or 0) end,
    rep = function(w) return ns.Plan.WRIT_REP[w.rank] end,
    perRep = function(w) local r = ns.Plan.WRIT_REP[w.rank] return w.cost and r and w.cost / r end,
    total = function(w) return w.cost end,
}

-- A, B, ... Z, then AA, AB, ...
local function SpotTag(n)
    local tag = ""
    repeat
        n = n - 1
        tag = string.char(65 + n % 26) .. tag
        n = math.floor(n / 26)
    until n == 0
    return tag
end

local function Filter()
    wipe(shown)
    local db = ns.DB()
    for _, w in ipairs(ns.WRITS) do
        ItemNameOf(w)
        local ok = next(db.zones) == nil or db.zones[ZoneOf(w)]
        ok = ok and (db.prof == "ALL" or (w.prof or ""):find(db.prof, 1, true))
        ok = ok and (not db.onlyMine or Holding(w))
        if ok then
            w.dist = db.sort == "near" and Distance(w) or nil
            local total, _, _, missing = ns.WritCost(w)
            w.cost = not missing and total or nil
            shown[#shown + 1] = w
        end
    end
    if db.sortCol and COL_SORT[db.sortCol] then
        local value, desc = COL_SORT[db.sortCol], db.sortDesc
        table.sort(shown, function(a, b)
            local va, vb = value(a), value(b)
            if va == nil or vb == nil then
                if va == vb then return a.itemName < b.itemName end
                return vb == nil -- unknown values always last
            end
            if va ~= vb then
                if desc then return va > vb end
                return va < vb
            end
            return a.itemName < b.itemName
        end)
    else
        table.sort(shown, (SORTS[db.sort] or SORTS.zone).fn)
    end
    -- A ticked writ that a filter now hides is unticked, so "Add" only adds what you see.
    local inView = {}
    for _, w in ipairs(shown) do inView[w.id] = true end
    for id in pairs(selected) do if not inView[id] then selected[id] = nil end end
    -- Give each multi-writ spot in view the next colour and its own letter. There are
    -- more spots than colours, so the letter tells two spots of the same colour apart.
    local colorOf, nextColor = {}, 0
    for _, w in ipairs(shown) do
        w.color, w.tag = nil, nil
        if (w.spotWrits or 0) > 1 then
            local key = w.zone .. "#" .. w.spot
            if not colorOf[key] then
                nextColor = nextColor + 1
                colorOf[key] = nextColor
            end
            w.color = colorOf[key]
            w.tag = SpotTag(w.color)
        end
    end
    offset = math.max(0, math.min(offset, #shown - ROWS))
end

local function Counts(field)
    local counts, keys = {}, {}
    for _, w in ipairs(ns.WRITS) do
        local values = field == "zone" and { ZoneOf(w) } or { strsplit("/", w.prof or UNKNOWN) }
        for _, v in ipairs(values) do
            if not counts[v] then keys[#keys + 1] = v end
            counts[v] = (counts[v] or 0) + 1
        end
    end
    table.sort(keys, function(a, b)
        if a == UNKNOWN or b == UNKNOWN then return b == UNKNOWN end
        return a < b
    end)
    return keys, counts
end

-- Widgets --------------------------------------------------------------------

local function Text(parent, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", size or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function Button(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

-- A dropdown using the game's menu system, or a button that cycles values when
-- that is missing.
local function Dropdown(parent, width, options, get, set)
    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    if ok and dd and dd.SetupMenu then
        dd:SetWidth(width)
        dd:SetupMenu(function(_, root)
            for _, o in ipairs(options()) do
                root:CreateRadio(o.label, function() return get() == o.value end, function() set(o.value) end)
            end
        end)
        dd.Refresh = function(self)
            if self.GenerateMenu then self:GenerateMenu() end
        end
        return dd
    end
    local b = Button(parent, "", width, nil)
    b.Refresh = function(self)
        for _, o in ipairs(options()) do
            if o.value == get() then self:SetText(o.label) end
        end
    end
    b:SetScript("OnClick", function(self)
        local list, cur = options(), get()
        for i, o in ipairs(list) do
            if o.value == cur then
                set(list[i % #list + 1].value)
                break
            end
        end
        self:Refresh()
    end)
    return b
end

-- The zone filter is multi-select: tick any number of zones, none ticked means all.
local function ZoneLabel()
    local zones, n, one = ns.DB().zones, 0, nil
    for z in pairs(zones) do n, one = n + 1, z end
    if n == 0 then return "All zones" end
    if n == 1 then return one == UNKNOWN and "NPC unknown" or one end
    return n .. " zones"
end

local function ZoneDropdown(parent, width, onChange)
    local zones = ns.DB().zones
    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    if not (ok and dd and dd.SetupMenu) then
        -- No menu system: a button that steps through single zones.
        local b = Button(parent, "", width, nil)
        b.Refresh = function(self) self:SetText(ZoneLabel()) end
        b:SetScript("OnClick", function(self)
            local keys = Counts("zone")
            local cur = next(zones)
            wipe(zones)
            local idx = 0
            for i, k in ipairs(keys) do if k == cur then idx = i end end
            if keys[idx + 1] then zones[keys[idx + 1]] = true end
            self:Refresh()
            onChange()
        end)
        return b
    end
    dd:SetWidth(width)
    dd.Refresh = function(self)
        if self.OverrideText then self:OverrideText(ZoneLabel())
        elseif self.SetDefaultText then self:SetDefaultText(ZoneLabel()) end
    end
    dd:SetupMenu(function(_, root)
        root:CreateButton(("All zones (%d)"):format(#ns.WRITS), function()
            wipe(zones)
            dd:Refresh()
            onChange()
        end)
        local keys, counts = Counts("zone")
        local best = {}
        for _, w in ipairs(ns.WRITS) do
            if w.zone then best[w.zone] = math.max(best[w.zone] or 0, w.spotWrits or 0) end
        end
        for _, k in ipairs(keys) do
            local together = (best[k] or 0) > 1 and (", %d at one spot"):format(best[k]) or ""
            root:CreateCheckbox(("%s (%d%s)"):format(k == UNKNOWN and "NPC unknown" or k, counts[k], together),
                function() return zones[k] == true end,
                function()
                    zones[k] = not zones[k] or nil
                    dd:Refresh()
                    onChange()
                end)
        end
    end)
    return dd
end

local function ProfOptions()
    local keys, counts = Counts("prof")
    local out = { { value = "ALL", label = "All professions" } }
    for _, k in ipairs(keys) do
        out[#out + 1] = { value = k, label = ("%s (%d)"):format(k, counts[k]) }
    end
    return out
end

local function SortOptions()
    local out = {}
    local db = ns.DB()
    if db.sortCol and ui.headLabels then
        out[1] = { value = "col", label = "Column: " .. ui.headLabels[db.sortCol] .. (db.sortDesc and " (down)" or " (up)") }
    end
    for _, key in ipairs({ "zone", "spot", "near", "item", "price" }) do out[#out + 1] = { value = key, label = SORTS[key].label } end
    return out
end

-- Rows -----------------------------------------------------------------------

local function SelectedList()
    local out = {}
    for _, w in ipairs(ns.WRITS) do
        if selected[w.id] then out[#out + 1] = w end
    end
    return out
end
ns.SelectedWrits = SelectedList

local Render


-- Hand-ins close together share a spot (see tools/build_data.py). Spots with
-- more than one writ get a colour, so a group like Gadgetzan stands out.
local SPOT_COLORS = {
    { 1, 0.2, 0.2 },    -- red
    { 0.25, 0.55, 1 },  -- blue
    { 1, 0.9, 0.1 },    -- yellow
    { 0.2, 0.95, 0.2 }, -- green
    { 1, 0.3, 1 },      -- magenta
    { 0.1, 0.95, 0.95 },-- cyan
    { 1, 0.55, 0 },     -- orange
    { 0.65, 0.4, 1 },   -- purple
    { 1, 1, 1 },        -- white
    { 1, 0.65, 0.75 },  -- pink
}
local function SpotColor(w)
    if not w.color then return nil end
    local c = SPOT_COLORS[(w.color - 1) % #SPOT_COLORS + 1]
    return c[1], c[2], c[3]
end

ns.SpotColor = SpotColor

local function PriceLine(label, item, mult)
    local p, source, at, days = ns.Price(item)
    if not p then
        GameTooltip:AddDoubleLine(label, "no price yet", 1, 1, 1, 0.6, 0.6, 0.6)
        return
    end
    local ago = ns.Ago(at, days)
    local age = ago and (source .. ", " .. ago) or source
    if ns.NotOnAH(item) then
        local t = ns.DB().missing[item]
        GameTooltip:AddDoubleLine(label, ("|cffff5555none on the AH|r (scan %s)"):format(ns.Ago(t)), 1, 1, 1, 1, 1, 1)
        return
    end
    GameTooltip:AddDoubleLine(label .. " |cff888888(" .. age .. ")|r", ns.Money(p * (mult or 1)), 1, 1, 1, 1, 1, 1)
end

-- Row tooltip: our own text only. The item tooltip is rebuilt by the game and
-- other addons after it loads, which pushed appended lines outside its frame,
-- so items get their own tooltip from the icon/name hover areas instead.
local function OnRowEnter(row)
    local w = row.writ
    if not w then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(w.name, 1, 0.82, 0)
    GameTooltip:AddLine(("Wants %dx %s"):format(w.count, w.itemName), 1, 1, 1)
    if w.npc then
        GameTooltip:AddLine(("Deliver to %s"):format(w.npc) .. (w.learned and " |cff88ccff(learned when you handed it in)|r" or ""), 1, 1, 1)
        GameTooltip:AddLine(("%s %s"):format(w.zone, w.x and ("%.1f, %.1f"):format(w.x, w.y) or ""), 0.8, 0.8, 0.8)
    else
        GameTooltip:AddLine("Delivery NPC not known yet.", 0.7, 0.7, 0.7)
    end
    if w.bop then GameTooltip:AddLine("Binds when picked up: cannot be bought.", 1, 0.3, 0.3) end
    if (w.spotWrits or 0) > 1 then
        GameTooltip:AddLine(" ")
        local r, g, b = SpotColor(w)
        GameTooltip:AddLine(("Spot %s: %d writs, %d NPCs"):format(w.tag or "", w.spotWrits, w.spotNPCs), r or 1, g or 1, b or 1)
        for _, o in ipairs(ns.WRITS) do
            if o ~= w and o.zone == w.zone and o.spot == w.spot then
                GameTooltip:AddDoubleLine("  " .. (o.itemName or o.name), o.npc, 0.85, 0.85, 0.85, 0.6, 0.6, 0.6)
            end
        end
    end
    GameTooltip:AddLine(" ")
    PriceLine("Writ", w.id)
    PriceLine((w.count > 1 and (w.count .. "x ") or "") .. "Item", w.item, w.count)
    local total, _, _, missing = ns.WritCost(w)
    GameTooltip:AddDoubleLine("Total" .. (ns.HaveWrit(w) and " (writ already yours)" or ""),
        ns.Money(total) .. (missing and " +?" or ""), 1, 0.82, 0, 1, 0.82, 0)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: tick.  Right-click: waypoint + map.  Shift-click: link.", 0.5, 0.8, 1)
    GameTooltip:AddLine("Hover the writ or item name for its item tooltip.", 0.5, 0.8, 1)
    GameTooltip:Show()
end

-- An area over a name cell that shows that item's own tooltip but lets clicks
-- and the mouse wheel through to the row.
local function ItemHover(row, col, itemOf)
    local f = CreateFrame("Frame", nil, row)
    f:SetPoint("LEFT", row, "LEFT", COLS[col][1], 0)
    f:SetSize(COLS[col][2], ROW_H)
    if f.SetMouseClickEnabled then
        f:SetMouseClickEnabled(false)
        f:SetMouseMotionEnabled(true)
    else
        f:EnableMouse(true)
    end
    if f.SetPropagateMouseClicks then f:SetPropagateMouseClicks(true) end
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta) frame:GetScript("OnMouseWheel")(frame, delta) end)
    f:SetScript("OnEnter", function(self)
        if not row.writ then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(itemOf(row.writ))
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", GameTooltip_Hide)
    return f
end

local function OnRowClick(row, button)
    local w = row.writ
    if not w then return end
    if IsModifiedClick("CHATLINK") then
        local _, link = C_Item.GetItemInfo(w.item)
        if link then ChatEdit_InsertLink(link) end
        return
    end
    if button == "RightButton" then
        ns.Waypoint(w)
        if ns.ShowOnMap and ns.DB().mapPins ~= false then ns.ShowOnMap(w) end
        return
    end
    selected[w.id] = not selected[w.id] or nil
    Render()
end

local function Cell(row, col, justify)
    local fs = Text(row, nil, justify)
    local icon = (col == "item" or col == "writ") and 20 or 0
    fs:SetPoint("LEFT", row, "LEFT", COLS[col][1] + icon, 0)
    fs:SetWidth(COLS[col][2] - icon)
    return fs
end

local function NewRow(i)
    local row = CreateFrame("Button", nil, page)
    row:SetSize(W - 24, ROW_H)
    row:SetPoint("TOPLEFT", ui.header, "BOTTOMLEFT", 0, -(i - 1) * ROW_H - 2)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("LEFT", COLS.check[1], 0)
    row.check:SetScript("OnClick", function(cb)
        if row.writ then selected[row.writ.id] = cb:GetChecked() or nil end
        Render()
    end)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", COLS.item[1], 0)
    row.item = Cell(row, "item")
    row.writIcon = row:CreateTexture(nil, "ARTWORK")
    row.writIcon:SetSize(16, 16)
    row.writIcon:SetPoint("LEFT", COLS.writ[1], 0)
    row.writName = Cell(row, "writ")
    row.prof = Cell(row, "prof")
    row.npc = Cell(row, "npc")
    row.zone = Cell(row, "zone")
    row.coords = Cell(row, "coords", "RIGHT")
    row.spot = Cell(row, "spot", "CENTER")
    row.stripe = row:CreateTexture(nil, "BORDER")
    row.stripe:SetPoint("TOPLEFT", 0, 0)
    row.stripe:SetPoint("BOTTOMLEFT", 0, 0)
    row.stripe:SetWidth(6)
    row.rep = Cell(row, "rep", "RIGHT")
    row.perRep = Cell(row, "perRep", "RIGHT")
    row.total = Cell(row, "total", "RIGHT")
    row:SetScript("OnEnter", OnRowEnter)
    ItemHover(row, "writ", function(w) return w.id end)
    ItemHover(row, "item", function(w) return w.item end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", OnRowClick)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta) frame:GetScript("OnMouseWheel")(frame, delta) end)
    return row
end

local function FillRow(row, w, index)
    row.writ = w
    if not w then return row:Hide() end
    row:Show()
    local sel = selected[w.id]
    local cr, cg, cb = SpotColor(w)
    if sel then
        row.bg:SetColorTexture(0.2, 0.5, 1, 0.3)
    elseif cr then
        row.bg:SetColorTexture(cr, cg, cb, 0.12)
    else
        row.bg:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
    end
    row.check:SetChecked(sel and true or false)
    row.icon:SetTexture(ns.ItemIcon(w.item))
    local itemText = (w.count > 1 and (w.count .. "x ") or "") .. w.itemName
    if not w.bop and ns.NotOnAH(w.item) then itemText = "|cffff5555" .. itemText .. "|r" end -- none on the AH now
    row.item:SetText(itemText .. (w.bop and " |cffff5555(BoP)|r" or ""))
    row.prof:SetText(w.prof or "")
    row.npc:SetText(w.npc or "|cff888888unknown|r")
    row.zone:SetText(w.zone or "")
    local coords = w.x and ("%.1f, %.1f"):format(w.x, w.y) or ""
    if w.dist then coords = ("|cff88ccff%d|r  "):format(w.dist) .. coords end
    row.coords:SetText(coords)
    local r, g, b = SpotColor(w)
    if r then
        row.stripe:SetColorTexture(r, g, b, 0.9)
        row.stripe:Show()
        row.spot:SetText((w.tag or "") .. " " .. w.spotWrits)
        row.spot:SetTextColor(r, g, b)
    else
        row.stripe:Hide()
        row.spot:SetText("") -- alone at its spot: nothing to group
    end
    row.writIcon:SetTexture(ns.ItemIcon(w.id))
    local held = Holding(w)
    row.writName:SetText((w.name:gsub("^Craftsman's ", "")))
    if held then row.writName:SetTextColor(0.4, 1, 0.4)
    elseif ns.NotOnAH(w.id) then row.writName:SetTextColor(1, 0.33, 0.33)
    else row.writName:SetTextColor(1, 0.82, 0) end
    local total, _, _, missing = ns.WritCost(w)
    local rep = ns.Plan.WRIT_REP[w.rank]
    row.rep:SetText(rep or "")
    row.perRep:SetText(w.bop and "|cffff5555BoP|r" or ((rep and total > 0) and (ns.ShortMoney(total / rep)
        .. (missing and "|cffff5555+|r" or "")) or ns.ShortMoney(nil)))
    row.total:SetText(total > 0 and (ns.ShortMoney(total) .. (missing and "|cffff5555+|r" or "")) or ns.ShortMoney(nil))
end


function Render()
    if not (frame and frame:IsShown()) then return end
    Filter()
    for i = 1, ROWS do
        rows[i] = rows[i] or NewRow(i)
        FillRow(rows[i], shown[offset + i], offset + i)
    end
    local sel = SelectedList()
    local nSel, sum, gaps, rep = #sel, 0, false, 0
    for _, w in ipairs(sel) do
        local total, _, _, missing = ns.WritCost(w)
        sum, gaps = sum + total, gaps or missing
        rep = rep + (ns.Plan.WRIT_REP[w.rank] or 0)
    end
    local perRep = rep > 0 and sum / rep or nil
    local rc = ns.Plan.Receipt()
    local rcPer = rc and rc / ns.Plan.RECEIPT.rep
    local S, M = ui.stats, ns.ShortMoney
    S.shown:Set(#shown)
    S.ticked:Set(nSel > 0 and nSel or "-")
    S.rep:Set(nSel > 0 and rep or "-")
    S.total:Set(nSel > 0 and (M(sum) .. (gaps and " |cffff5555+?|r" or "")) or "-")
    S.per:Set(perRep and M(perRep) or "-")
    S.receipt:Set(rcPer and M(rcPer) or "|cff888888scan crates|r")
    -- Tint whichever way is cheaper per rep, so the choice is easy to see.
    local writsCheaper = perRep and rcPer and perRep <= rcPer
    S.per.value:SetTextColor(writsCheaper and 0.4 or 1, 1, writsCheaper and 0.4 or 1)
    S.receipt.value:SetTextColor((perRep and rcPer and not writsCheaper) and 0.4 or 1, 1,
        (perRep and rcPer and not writsCheaper) and 0.4 or 1)
    -- Where the prices of the shown writs come from, and how old they are.
    local src, n = {}, 0
    for _, w in ipairs(shown) do
        for _, item in ipairs({ w.id, (not w.bop) and w.item or nil }) do
            local p, source, at, days = ns.Price(item)
            source = p and source or "No price"
            local e = src[source] or { n = 0 }
            src[source] = e
            e.n, n = e.n + 1, n + 1
            if at and (not e.newest or at > e.newest) then e.newest = at end
            if at and (not e.oldest or at < e.oldest) then e.oldest = at end
            if days and (not e.days or days > e.days) then e.days = days end
        end
    end
    local order = {}
    for source, e in pairs(src) do if source ~= "No price" then order[#order + 1] = source end end
    table.sort(order, function(a, b) return src[a].n > src[b].n end)
    local main = order[1] and src[order[1]]
    local mainAgo = main and (main.newest and ns.Ago(main.newest) or ns.Ago(nil, main.days))
    S.prices:Set(main and ((order[1] == "Writ Shopper scan" and "Your scan" or order[1]) .. (mainAgo and ("|cff888888, " .. mainAgo .. "|r") or ""))
        or "|cff888888none, scan|r")
    ui.priceLines = {}
    for _, source in ipairs(order) do
        local e = src[source]
        local age
        if e.newest then
            local a, b = ns.Ago(e.newest), ns.Ago(e.oldest)
            age = a == b and a or ("%s to %s"):format(a, b)
        elseif e.days then
            age = "up to " .. ns.Ago(nil, e.days)
        else
            age = "age not given"
        end
        ui.priceLines[#ui.priceLines + 1] = { source, ("%d prices, %s"):format(e.n, age) }
    end
    if src["No price"] then ui.priceLines[#ui.priceLines + 1] = { "No price", src["No price"].n .. " items" } end
    local db = ns.DB()
    for col, h in pairs(ui.heads or {}) do
        local active = db.sortCol == col
        h.fs:SetText(active and (h.label .. (db.sortDesc and " v" or " ^")) or h.label)
        h.fs:SetTextColor(active and 1 or 1, active and 1 or 0.82, active and 1 or 0)
    end
    ui.page:SetText(#shown > ROWS and ("%d-%d of %d"):format(offset + 1, math.min(offset + ROWS, #shown), #shown) or "")
    ui.add:SetEnabled(nSel > 0)
    ui.buyCount:SetText(ns.ListCount() > 0 and ("Buy list: %d items"):format(ns.ListCount()) or "")
    if ns.RefreshMap and WorldMapFrame and WorldMapFrame:IsShown() then ns.RefreshMap() end
end
ns.RefreshWrits = Render

-- Window ---------------------------------------------------------------------

local function Build()
    frame = CreateFrame("Frame", "WritShopperFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:Hide() -- new frames start shown; the toggle below shows it once it is built
    frame:SetSize(W, H)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true) -- clicking it brings it in front of the buy list
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "WritShopperFrame")
    local title = frame.TitleText or Text(frame, "GameFontNormal")
    if not frame.TitleText then title:SetPoint("TOP", 0, -5) end
    title:SetText("OKS Writ Shopper")
    ui.title = title
    page = CreateFrame("Frame", nil, frame)
    page:SetAllPoints()

    local db = ns.DB()
    local function Set(key)
        return function(v)
            db[key] = v
            offset = 0
            Render()
        end
    end

    ui.zone = ZoneDropdown(page, 200, function()
        offset = 0
        Render()
    end)
    ui.zone:SetPoint("TOPLEFT", 14, -32)
    ui.prof = Dropdown(page, 160, ProfOptions, function() return db.prof end, Set("prof"))
    ui.prof:SetPoint("LEFT", ui.zone, "RIGHT", 8, 0)
    ui.sort = Dropdown(page, 170, SortOptions, function() return db.sortCol and "col" or db.sort end, function(v)
        if v == "col" then return end
        db.sortCol = nil
        Set("sort")(v)
    end)
    ui.sort:SetPoint("LEFT", ui.prof, "RIGHT", 8, 0)

    ui.mine = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    ui.mine:SetSize(24, 24)
    ui.mine:SetPoint("LEFT", ui.sort, "RIGHT", 10, 0)
    ui.mine:SetChecked(db.onlyMine)
    ui.mine:SetScript("OnClick", function(cb) Set("onlyMine")(cb:GetChecked() and true or false) end)
    local mineText = Text(page, "GameFontHighlightSmall")
    mineText:SetPoint("LEFT", ui.mine, "RIGHT", 2, 0)
    mineText:SetText("Only writs I have")

    ui.mapPins = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    ui.mapPins:SetSize(24, 24)
    ui.mapPins:SetPoint("LEFT", mineText, "RIGHT", 14, 0)
    ui.mapPins:SetChecked(db.mapPins ~= false)
    ui.mapPins:SetScript("OnClick", function(cb)
        db.mapPins = cb:GetChecked() and true or false
        if ns.RefreshMap then ns.RefreshMap() end
    end)
    ui.mapPins:SetScript("OnEnter", function(cb)
        GameTooltip:SetOwner(cb, "ANCHOR_TOP")
        GameTooltip:SetText("Show on map")
        GameTooltip:AddLine("Pin the NPCs of the ticked writs (or all shown) on the world map. Right-click a writ to open the map there.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    ui.mapPins:SetScript("OnLeave", GameTooltip_Hide)
    local mapText = Text(page, "GameFontHighlightSmall")
    mapText:SetPoint("LEFT", ui.mapPins, "RIGHT", 2, 0)
    mapText:SetText("Show on map")

    ui.header = CreateFrame("Frame", nil, page)
    ui.header:SetSize(W - 24, 18)
    ui.header:SetPoint("TOPLEFT", 12, -62)
    local heads = { spot = "Spot", rep = "Rep", perRep = "Gold/rep", total = "Total", writ = "Writ", item = "Item to deliver", prof = "Profession", npc = "NPC", zone = "Zone", coords = "Coords" }
    ui.heads = {}
    for col, label in pairs(heads) do
        local right = col == "coords" or col == "rep" or col == "perRep" or col == "total"
        local b = CreateFrame("Button", nil, ui.header)
        b:SetPoint("LEFT", COLS[col][1], 0)
        b:SetSize(COLS[col][2], 18)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local fs = Text(b, "GameFontNormalSmall", right and "RIGHT" or (col == "spot" and "CENTER" or "LEFT"))
        fs:SetAllPoints()
        b.fs, b.label = fs, label
        fs:SetText(label)
        b:SetScript("OnClick", function()
            if db.sortCol == col then
                db.sortDesc = not db.sortDesc
            else
                db.sortCol, db.sortDesc = col, (col == "spot")
            end
            offset = 0
            if ui.sort.Refresh then ui.sort:Refresh() end
            Render()
        end)
        ui.heads[col] = b
    end
    ui.headLabels = heads

    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        if not page:IsShown() then return end
        offset = math.max(0, math.min(offset - delta * 3, #shown - ROWS))
        Render()
    end)

    -- Summary bar: label above, value below, in boxes across the window.
    local bar = CreateFrame("Frame", nil, page)
    bar:SetPoint("TOPLEFT", ui.header, "BOTTOMLEFT", 0, -(ROWS * ROW_H) - 6)
    bar:SetSize(W - 24, 38)
    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0, 0, 0, 0.45)
    ui.stats = {}
    local function Stat(key, x, width, label, tip)
        local f = CreateFrame("Frame", nil, bar)
        f:SetPoint("TOPLEFT", x, 0)
        f:SetSize(width, 38)
        f.label = Text(f, "GameFontDisableSmall")
        f.label:SetPoint("TOPLEFT", 8, -4)
        f.label:SetText(label)
        f.value = Text(f, "GameFontHighlightMedium")
        f.value:SetPoint("BOTTOMLEFT", 8, 4)
        f.value:SetWidth(width - 10)
        f.Set = function(self, v) self.value:SetText(tostring(v)) end
        if x > 0 then
            local sep = f:CreateTexture(nil, "ARTWORK")
            sep:SetColorTexture(1, 1, 1, 0.12)
            sep:SetPoint("TOPLEFT", 0, -4)
            sep:SetPoint("BOTTOMLEFT", 0, 4)
            sep:SetWidth(1)
        end
        if tip then
            f:EnableMouse(true)
            f:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(label)
                GameTooltip:AddLine(tip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            f:SetScript("OnLeave", GameTooltip_Hide)
        end
        ui.stats[key] = f
    end
    Stat("shown", 0, 90, "Shown")
    Stat("ticked", 90, 90, "Ticked")
    Stat("rep", 180, 110, "Rep")
    Stat("total", 290, 170, "Total cost")
    Stat("per", 460, 150, "Writs: gold / rep", "What the ticked writs cost per reputation point.")
    Stat("receipt", 610, 170, "Receipts: gold / rep",
        "Forged Delivery Receipt: 15 Merchant's Favor + an empty Waylaid Crate for 50 reputation, at the cheapest crate prices. Open Crates & Receipts to plan and buy it.")
    Stat("prices", 780, 170, "Prices from")
    ui.stats.prices:EnableMouse(true)
    ui.stats.prices:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Prices of the writs shown")
        for _, l in ipairs(ui.priceLines or {}) do GameTooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 0.8, 0.8, 0.8) end
        GameTooltip:AddLine("Your own scan wins for an hour, then Auctionator, TSM, Naowh, then your older scan.", 0.5, 0.8, 1, true)
        GameTooltip:Show()
    end)
    ui.stats.prices:SetScript("OnLeave", GameTooltip_Hide)
    local legend = Text(bar, "GameFontDisableSmall", "RIGHT")
    legend:SetPoint("TOPRIGHT", -8, -4)
    legend:SetText("|cff66ff66Green|r held  |cffff5555Red|r not on AH")
    ui.page = Text(bar, "GameFontDisableSmall", "RIGHT")
    ui.page:SetPoint("BOTTOMRIGHT", -8, 4)

    local allShown = Button(page, "Tick all shown", 120, function()
        for _, w in ipairs(shown) do if not w.bop then selected[w.id] = true end end
        Render()
    end)
    allShown:SetPoint("BOTTOMLEFT", 14, 12)
    local none = Button(page, "Untick all", 90, function()
        wipe(selected)
        Render()
    end)
    none:SetPoint("LEFT", allShown, "RIGHT", 6, 0)

    local scan = ns.ScanButton(page, 130)
    scan:SetPoint("BOTTOMRIGHT", -14, 40)

    ui.add = Button(page, "Add to buy list", 140, function()
        local list = SelectedList()
        if #list == 0 then return end
        ns.AddWrits(list)
        wipe(selected)
        Render()
    end)
    ui.add:SetPoint("LEFT", none, "RIGHT", 16, 0)

    local open = Button(frame, "Open buy list", 120, function() ns.ShowBuy() end)
    open:SetPoint("BOTTOMRIGHT", -14, 12)
    ui.buyCount = Text(frame, "GameFontHighlightSmall", "RIGHT")
    ui.buyCount:SetPoint("RIGHT", open, "LEFT", -8, 0)

    -- Tabs under the window, like the character window: Writs, Crates & Receipts.
    planPage = ns.BuildPlanPage(frame)
    tabs = {}
    for i, label in ipairs({ "Writs", "Crates & Receipts" }) do
        local t = CreateFrame("Button", "WritShopperFrameTab" .. i, frame, "PanelTabButtonTemplate")
        t:SetID(i)
        t:SetText(label)
        if PanelTemplates_TabResize then PanelTemplates_TabResize(t, 0) end
        if i == 1 then t:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
        else t:SetPoint("LEFT", tabs[i - 1], "RIGHT", -16, 0) end
        t:SetScript("OnClick", function() ns.ShowTab(i) end)
        tabs[i] = t
    end
    frame.Tabs = tabs
    if PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(frame, #tabs) end

    frame:SetScript("OnShow", function()
        for _, dd in ipairs({ ui.zone, ui.prof, ui.sort }) do if dd.Refresh then dd:Refresh() end end
        ns.ShowTab(ns.DB().tab or 1)
    end)
    frame:RegisterEvent("BAG_UPDATE_DELAYED")
    frame:RegisterEvent("QUEST_LOG_UPDATE")
    frame:SetScript("OnEvent", function() if frame:IsShown() then Render() end end)
    ns.OnChange(Render)
end

-- Show tab 1 (Writs) or 2 (Crates & Receipts) and remember it.
function ns.ShowTab(i)
    if not frame then Build() end
    ns.DB().tab = i
    page:SetShown(i == 1)
    planPage:SetShown(i == 2)
    if PanelTemplates_SetTab then PanelTemplates_SetTab(frame, i) end
    ui.title:SetText(i == 1 and "OKS Writ Shopper: Craftsman's Writs" or "OKS Writ Shopper: Crates & Receipts")
    if i == 1 then Render() elseif ns.RefreshPlan then ns.RefreshPlan() end
end

function ns.ToggleWrits()
    if not frame then Build() end
    if frame:IsShown() and (ns.DB().tab or 1) ~= 1 then return ns.ShowTab(1) end
    frame:SetShown(not frame:IsShown())
end

function ns.TogglePlan()
    if not frame then Build() end
    if frame:IsShown() and ns.DB().tab == 2 then return frame:Hide() end
    ns.DB().tab = 2
    if frame:IsShown() then ns.ShowTab(2) else frame:Show() end
end
