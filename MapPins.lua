-- MapPins.lua: writ NPCs on the world map. Each gets a hand-in icon with its
-- spot's letter and colour (the same as the writ list), for the writs you
-- ticked, or all writs shown when none are. Zone and continent maps both show them.
-- (Flight points are not drawn: the game's taxi data lists paths Forever lacks.)
local _, ns = ...

local NPC_ICON = "Interface\\GossipFrame\\ActiveQuestIcon"

local provider
local npcPins = {}

local function Enabled()
    return ns.DB().mapPins ~= false
end

local function Canvas()
    return WorldMapFrame and WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas()
end

local function CanvasScale()
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    return sc and sc.GetCanvasScale and sc:GetCanvasScale() or 1
end

-- Where a point of map `from` (0-1 coords) falls on map `to`, or nil.
local function Translate(from, x, y, to)
    if from == to then return x, y end
    if not (C_Map.GetMapRectOnMap) then return nil end
    local ok, left, right, top, bottom = pcall(C_Map.GetMapRectOnMap, from, to)
    if not ok or not left or right == left then return nil end
    return left + x * (right - left), top + y * (bottom - top)
end

local function NewPin(pool, icon, size)
    local pin = CreateFrame("Button", nil, Canvas())
    pin:SetSize(size, size)
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetAllPoints()
    pin.icon:SetTexture(icon)
    pin.base = size
    pool[#pool + 1] = pin
    return pin
end

local function Place(pin, x, y)
    local canvas = Canvas()
    local scale = 1 / CanvasScale()
    pin:SetScale(scale)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", canvas, "TOPLEFT", x * canvas:GetWidth() / scale, -y * canvas:GetHeight() / scale)
    pin:SetFrameLevel((canvas:GetFrameLevel() or 1) + 2000)
    pin:Show()
end

local function NpcTooltip(pin)
    local g = pin.wsGroup
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    GameTooltip:SetText(g.npc .. (g.tag and ("  |cffffffff(spot %s)|r"):format(g.tag) or ""), 1, 0.82, 0)
    GameTooltip:AddLine(("%s %.1f, %.1f"):format(g.zone or "", g.x, g.y), 0.8, 0.8, 0.8)
    for _, w in ipairs(g.writs) do
        local held = ns.HaveWrit(w)
        GameTooltip:AddDoubleLine("  " .. (w.itemName or w.name), held and "have writ" or "",
            1, 1, 1, 0.4, 1, 0.4)
    end
    GameTooltip:AddLine("Click: set a waypoint", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

-- The writs to pin: the ticked ones, or all shown in the list.
local function Writs()
    local list = ns.SelectedWrits and ns.SelectedWrits() or {}
    if #list == 0 then list = ns.ShownWrits and ns.ShownWrits() or {} end
    if #list == 0 then list = ns.WRITS end
    return list
end

local function Refresh()
    for _, p in ipairs(npcPins) do p:Hide() end
    if not (Enabled() and WorldMapFrame and WorldMapFrame:IsShown() and Canvas()) then return end
    local map = WorldMapFrame:GetMapID()
    if not map then return end

    -- One pin per NPC (several writs can share one).
    local groups, order = {}, {}
    for _, w in ipairs(Writs()) do
        if w.map and w.x and w.y and w.npc then
            local key = w.map .. ":" .. w.npc
            local g = groups[key]
            if not g then
                g = { npc = w.npc, zone = w.zone, map = w.map, x = w.x, y = w.y, writs = {}, color = w.color, tag = w.tag }
                groups[key], order[#order + 1] = g, key
            end
            g.writs[#g.writs + 1] = w
        end
    end
    local n = 0
    for _, key in ipairs(order) do
        local g = groups[key]
        local x, y = Translate(g.map, g.x / 100, g.y / 100, map)
        if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            n = n + 1
            local pin = npcPins[n] or NewPin(npcPins, NPC_ICON, 18)
            if not rawget(pin, "wsLabel") then
                pin.wsLabel = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                pin.wsLabel:SetPoint("LEFT", pin, "RIGHT", -2, -4)
                pin:SetScript("OnEnter", NpcTooltip)
                pin:SetScript("OnLeave", GameTooltip_Hide)
                pin:SetScript("OnClick", function(self) ns.Waypoint(self.wsGroup.writs[1]) end)
            end
            pin.wsGroup = g
            local r, gg, b = 1, 1, 1
            if g.color and ns.SpotColor then r, gg, b = ns.SpotColor({ color = g.color }) end
            pin.wsLabel:SetText(g.tag or "")
            pin.wsLabel:SetTextColor(r, gg, b)
            Place(pin, x, y)
        end
    end
end
ns.RefreshMap = Refresh

-- Open the world map at a writ's zone.
function ns.ShowOnMap(w)
    if not (w and w.map and WorldMapFrame) then return end
    if not WorldMapFrame:IsShown() then
        if ToggleWorldMap then ToggleWorldMap() else WorldMapFrame:Show() end
    end
    if WorldMapFrame.SetMapID then WorldMapFrame:SetMapID(w.map) end
    Refresh()
end

-- Hook the map once it exists: redraw when it opens, changes map or zooms.
local function Hook()
    if provider or not WorldMapFrame then return end
    if WorldMapFrame.AddDataProvider and MapCanvasDataProviderMixin then
        provider = CreateFromMixins(MapCanvasDataProviderMixin)
        provider.RefreshAllData = function() Refresh() end
        provider.RemoveAllData = function()
            for _, p in ipairs(npcPins) do p:Hide() end
        end
        provider.OnCanvasScaleChanged = function() Refresh() end
        provider.OnMapChanged = function() Refresh() end
        WorldMapFrame:AddDataProvider(provider)
    else
        provider = true
        WorldMapFrame:HookScript("OnShow", Refresh)
        if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", Refresh) end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function() pcall(Hook) end)
ns.OnChange(function() if WorldMapFrame and WorldMapFrame:IsShown() then Refresh() end end)
