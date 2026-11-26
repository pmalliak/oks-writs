-- Core.lua: saved settings, prices, the buy list and the slash command.
local ADDON, ns = ...

local PREFIX = "|cffffd100OKS|r |cff33bbffWrit Shopper|r: "
local MAX_QTY = 9999

ns.listeners = {}

local DEFAULTS = {
    zones = {},           -- zone filter: set of zone names, empty means all
    prof = "ALL",
    onlyMine = false,
    sort = "zone",
    lists = {},           -- [playerGUID] = { [itemID] = qty }
    favorGoal = 0,
    repGoal = 0,
    repUseFavor = true,
    prices = {},          -- our own scans: [itemID] = { p = copper per item, t = time() }
    learned = {},         -- delivery NPCs seen in game for writs the data lacks: [questID] = { npc, npcID, map, zone, x, y }
    missing = {},         -- items a scan found no listings for: [itemID] = time()
    depth = {},           -- AH listings from our scans: [itemID] = { t = time(), rows = { { copper each, qty }, ... } }
}

function ns.Print(fmt, ...)
    print(PREFIX .. (select("#", ...) > 0 and fmt:format(...) or fmt))
end

function ns.DB()
    return WritShopperDB
end

local function InitDB()
    if type(WritShopperDB) ~= "table" then WritShopperDB = {} end
    for k, v in pairs(DEFAULTS) do
        if WritShopperDB[k] == nil then
            WritShopperDB[k] = type(v) == "table" and {} or v
        end
    end
    -- Sending to Naowh's Shopping List was removed in 0.9.7.
    WritShopperDB.useNaowh, WritShopperDB.naowhReset = nil, nil
    for item, t in pairs(WritShopperDB.missing) do
        if type(t) ~= "number" or time() - t > 86400 then WritShopperDB.missing[item] = nil end
    end
    -- Listings older than a day are no use: drop them so the saved file stays small.
    for item, d in pairs(WritShopperDB.depth) do
        if type(d) ~= "table" or not d.t or time() - d.t > 86400 then WritShopperDB.depth[item] = nil end
    end
    -- v0.1 kept one zone in db.zone.
    if type(WritShopperDB.zone) == "string" then
        if WritShopperDB.zone ~= "ALL" then WritShopperDB.zones[WritShopperDB.zone] = true end
        WritShopperDB.zone = nil
    end
end

-- Item helpers ------------------------------------------------------------

local pendingNames = {}

function ns.ItemName(item, fallback)
    local name = C_Item.GetItemNameByID(item)
    if not name then
        pendingNames[item] = true
        C_Item.RequestLoadItemDataByID(item)
    end
    return name or fallback or ("item " .. item)
end

function ns.ItemIcon(item)
    return C_Item.GetItemIconByID(item) or 134400
end

-- Stackable items trade as commodities on the auction house; single items
-- (crafted gear) are separate auctions. Unknown until the item data loads.
function ns.IsStackable(item)
    local _, _, _, _, _, _, _, stack = C_Item.GetItemInfo(item)
    if stack == nil then return nil end
    return stack > 1
end

function ns.Owned(item)
    return C_Item.GetItemCount(item, true, false, true) or 0
end

function ns.Money(copper)
    copper = math.floor((copper or 0) + 0.5)
    return C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString and C_CurrencyInfo.GetCoinTextureString(copper)
        or GetMoneyString(copper, true)
end

-- A writ you hold in your bags, or whose quest is already in your log.
function ns.HaveWrit(w)
    return (C_Item.GetItemCount(w.id) or 0) > 0 or (C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(w.quest)) or false
end

-- Prices -----------------------------------------------------------------------

local CALLER = "WritShopper"
local FRESH = 3600 -- our own scan wins over other addons for an hour

local function Positive(v)
    return type(v) == "number" and v > 0 and v or nil
end

-- Price of one item on the AH: our own fresh scan, then Auctionator, TSM,
-- Naowh's Auction Prices, then our own older scan. Returns price, source, scan time
-- (when known) and, for Auctionator, how many days ago it last saw the item.
function ns.Price(item)
    local own = ns.DB().prices[item]
    if own and time() - own.t < FRESH then return own.p, "Writ Shopper scan", own.t end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.GetAuctionPriceByItemID then
        local ok, v = pcall(api.GetAuctionPriceByItemID, CALLER, item)
        if ok and Positive(v) then
            local days
            if api.GetAuctionAgeByItemID then
                local okAge, d = pcall(api.GetAuctionAgeByItemID, CALLER, item)
                if okAge and type(d) == "number" then days = d end
            end
            return v, "Auctionator", nil, days
        end
    end
    if TSM_API and TSM_API.GetCustomPriceValue then
        for _, source in ipairs({ "dbminbuyout", "dbmarket" }) do
            local ok, v = pcall(TSM_API.GetCustomPriceValue, source, "i:" .. item)
            if ok and Positive(v) then return v, "TSM" end
        end
    end
    local nf = _G.NaowhForever
    if type(nf) == "table" and type(nf.AuctionPrice) == "function" then
        local ok, v, at = pcall(nf.AuctionPrice, item)
        if ok and Positive(v) then return v, "Naowh", at end
    end
    if own then return own.p, "Writ Shopper scan", own.t end
end

-- "12 min ago", "3 h ago", "2 days ago" from a scan time, or from Auctionator's day count.
function ns.Ago(at, days)
    if at then
        local s = math.max(0, time() - at)
        if s < 60 then return "just now" end
        if s < 3600 then return ("%d min ago"):format(s / 60) end
        if s < 86400 then return ("%d h ago"):format(s / 3600) end
        days = math.floor(s / 86400)
    end
    if not days then return nil end
    if days < 1 then return "today" end
    return days == 1 and "1 day ago" or ("%d days ago"):format(days)
end

ns.priceVersion = 0 -- goes up whenever a price is recorded, so plans know to recompute

function ns.RecordPrice(item, copperEach)
    if Positive(copperEach) then
        ns.DB().prices[item] = { p = math.floor(copperEach), t = time() }
        ns.DB().missing[item] = nil
        ns.priceVersion = ns.priceVersion + 1
    end
end

-- A scan found nobody selling this item right now.
function ns.RecordMissing(item)
    ns.DB().missing[item] = time()
    ns.DB().depth[item] = nil
    ns.priceVersion = ns.priceVersion + 1
end

-- True when the last scan (within the hour) found none of this item on the AH.
function ns.NotOnAH(item)
    local t = ns.DB().missing[item]
    return t ~= nil and time() - t < FRESH
end

-- Keep the cheapest listings seen in a scan ({ { copper each, qty }, ... }, cheapest
-- first), so buying many can be priced the way the auction house will charge it.
local DEPTH_ROWS = 60
function ns.RecordDepth(item, rows)
    if #rows == 0 then return end
    table.sort(rows, function(a, b) return a[1] < b[1] end)
    local keep = {}
    for i = 1, math.min(#rows, DEPTH_ROWS) do keep[i] = { math.floor(rows[i][1]), rows[i][2] } end
    ns.DB().depth[item] = { t = time(), rows = keep }
    ns.priceVersion = ns.priceVersion + 1
end

-- What `qty` of an item costs. With listings from a scan in the last hour it walks
-- up them like a real purchase (anything past the listings seen is priced at the
-- last one, and the second return is true). Otherwise qty x ns.Price; nil if unknown.
function ns.CostFor(item, qty)
    if qty <= 0 then return 0 end
    local d = ns.DB().depth[item]
    if d and d.rows and #d.rows > 0 and time() - d.t < FRESH then
        local total, left, last = 0, qty, 0
        for _, r in ipairs(d.rows) do
            local n = math.min(left, r[2])
            total, left, last = total + n * r[1], left - n, r[1]
            if left <= 0 then return total end
        end
        return total + left * last, true
    end
    local p = ns.Price(item)
    return p and p * qty or nil
end

-- Short money text for narrow columns: 12g 34s, 56s 7c, 89c.
function ns.ShortMoney(c)
    if not c then return "|cff888888?|r" end
    c = math.floor(c + 0.5)
    local g, s, cp = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    if g > 0 then return ("%d|cffffd700g|r %d|cffc7c7cfs|r"):format(g, s) end
    if s > 0 then return ("%d|cffc7c7cfs|r %d|cffeda55fc|r"):format(s, cp) end
    return ("%d|cffeda55fc|r"):format(cp)
end

-- What a writ costs to do: the writ (unless you hold it) plus its items.
-- Returns total, writ price, item price each, and whether a price is missing.
function ns.WritCost(w)
    local writP = ns.Price(w.id)
    local itemP = ns.Price(w.item)
    local held = ns.HaveWrit(w)
    local total, missing = 0, false
    if not held then
        if writP then total = total + writP else missing = true end
    end
    if itemP then total = total + itemP * w.count else missing = true end
    return total, writP, itemP, missing, held
end

-- Our own buy list ---------------------------------------------------------

local function MyKey()
    return UnitGUID("player") or "unknown"
end

function ns.List()
    local lists = ns.DB().lists
    local key = MyKey()
    if type(lists[key]) ~= "table" then lists[key] = {} end
    return lists[key]
end

function ns.Changed()
    for i = 1, #ns.listeners do ns.listeners[i]() end
end

function ns.OnChange(fn)
    ns.listeners[#ns.listeners + 1] = fn
end

function ns.ListAdd(item, qty)
    local list = ns.List()
    list[item] = math.min(MAX_QTY, (list[item] or 0) + qty)
    ns.Changed()
end

function ns.ListSet(item, qty)
    ns.List()[item] = qty > 0 and math.min(MAX_QTY, qty) or nil
    ns.Changed()
end

function ns.ListClear()
    wipe(ns.List())
    ns.Changed()
end

function ns.ListCount()
    local n = 0
    for _ in pairs(ns.List()) do n = n + 1 end
    return n
end

-- Adding writs ---------------------------------------------------------------

-- Writs the player can turn in for each: the writ itself (unless held or its
-- quest is in the log) and the item it asks for. Adds into `want`.
function ns.WritNeeds(writs, want)
    want = want or {}
    for _, w in ipairs(writs) do
        want[w.item] = (want[w.item] or 0) + w.count
        if not (C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(w.quest)) then
            want[w.id] = (want[w.id] or 0) + 1
        end
    end
    return want
end

-- Put `want` ({ [item] = qty }) on the buy list, less what you already own.
function ns.AddNeeds(want, what)
    local added, skipped = 0, 0
    for item, qty in pairs(want) do
        local need = qty - ns.Owned(item)
        if need <= 0 then
            skipped = skipped + 1
        else
            ns.ListAdd(item, need)
            added = added + 1
        end
    end
    local parts = {}
    if added > 0 then parts[#parts + 1] = added .. " on the buy list" end
    if skipped > 0 then parts[#parts + 1] = skipped .. " already in your bags or bank" end
    ns.Print("%s, %d items: %s.", what, added + skipped,
        #parts > 0 and table.concat(parts, ", ") or "nothing to add")
    return added, skipped
end

function ns.AddWrits(writs)
    return ns.AddNeeds(ns.WritNeeds(writs), #writs .. " writs")
end

-- Map waypoints --------------------------------------------------------------

function ns.Waypoint(w)
    if not (w.map and w.x and w.y) then
        ns.Print("No coordinates known for %s.", w.npc or w.name)
        return
    end
    local title = (w.npc or "") .. " (" .. (w.itemName or w.name) .. ")"
    if TomTom and TomTom.AddWaypoint then
        TomTom:AddWaypoint(w.map, w.x / 100, w.y / 100, { title = title, persistent = false })
    end
    if C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(w.map) then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(w.map, w.x / 100, w.y / 100))
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
    end
    ns.Print("Waypoint: %s, %s %.1f, %.1f", w.npc or "?", w.zone or "?", w.x, w.y)
end

-- Learning unknown NPCs -------------------------------------------------------

-- Some writs have no known delivery NPC. When you hand one in, remember who took
-- it and where you stood, and use that from then on.
local function ApplyLearned()
    for _, w in ipairs(ns.WRITS) do
        local l = ns.DB().learned[w.quest]
        if l and not w.npc then
            w.npc, w.npcID, w.map, w.zone, w.x, w.y, w.learned = l.npc, l.npcID, l.map, l.zone, l.x, l.y, true
        end
    end
end

local function LearnTurnIn()
    local quest = GetQuestID and GetQuestID()
    if not quest or quest == 0 then return end
    local writ
    for _, w in ipairs(ns.WRITS) do if w.quest == quest then writ = w break end end
    if not writ or (writ.npc and not writ.learned) then return end
    local name = UnitName("npc")
    local guid = UnitGUID("npc")
    local npcID = guid and tonumber((select(6, strsplit("-", guid))))
    local map = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local info = map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
    -- Inside a cave or building map, use the zone it belongs to (map type 3 = zone).
    while info and (info.mapType or 3) > 3 and (info.parentMapID or 0) > 0 do
        map = info.parentMapID
        info = C_Map.GetMapInfo(map)
    end
    local pos = map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, "player")
    if not (name and pos) then return end
    local x, y = pos:GetXY()
    local l = { npc = name, npcID = npcID, map = map, zone = info and info.name or GetZoneText(),
        x = math.floor(x * 1000 + 0.5) / 10, y = math.floor(y * 1000 + 0.5) / 10 }
    local first = not ns.DB().learned[quest]
    ns.DB().learned[quest] = l
    writ.npc = nil
    ApplyLearned()
    if first then
        ns.Print("Learned where %s is handed in: %s, %s %.1f, %.1f.", writ.name, l.npc, l.zone or "?", l.x, l.y)
    end
    if ns.RefreshWrits then ns.RefreshWrits() end
end

-- Events and slash command ---------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("ITEM_DATA_LOAD_RESULT")
events:RegisterEvent("QUEST_COMPLETE") -- the reward window: the NPC is still your "npc" unit
events:SetScript("OnEvent", function(_, event, a)
    if event == "ADDON_LOADED" and a == ADDON then
        InitDB()
        ApplyLearned()
        if ns.BuyInit then ns.BuyInit() end
    elseif event == "QUEST_COMPLETE" then
        pcall(LearnTurnIn)
    elseif event == "ITEM_DATA_LOAD_RESULT" and pendingNames[a] then
        pendingNames[a] = nil
        if ns.RefreshWrits then ns.RefreshWrits() end
        if ns.RefreshBuy then ns.RefreshBuy() end
    end
end)

SLASH_WRITSHOPPER1 = "/writs"
SLASH_WRITSHOPPER2 = "/ws"
SlashCmdList.WRITSHOPPER = function(msg)
    msg = strtrim((msg or ""):lower())
    if msg == "buy" or msg == "list" then
        ns.ToggleBuy()
    elseif msg == "rep" or msg == "crates" or msg == "plan" then
        ns.TogglePlan()
    elseif msg == "clear" then
        ns.ListClear()
        ns.Print("Buy list cleared.")
    elseif msg == "reset" then
        ns.DB().buyPos = nil
        ns.Print("Buy list position reset.")
        if WritShopperBuyFrame and WritShopperBuyFrame:IsShown() then WritShopperBuyFrame:Hide(); WritShopperBuyFrame:Show() end
    elseif msg == "learned" then
        local n = 0
        for quest, l in pairs(ns.DB().learned) do
            n = n + 1
            ns.Print("quest %d: %s, %s %.1f, %.1f", quest, l.npc or "?", l.zone or "?", l.x or 0, l.y or 0)
        end
        if n == 0 then ns.Print("No NPCs learned yet. Hand in a writ whose NPC shows as unknown.") end
    elseif msg == "help" then
        ns.Print("/writs opens the writ list. /writs buy opens the buy list. /writs rep opens Crates & Reputation. /writs clear empties the buy list. /writs reset puts the buy list back next to the auction house. /writs learned lists NPCs learned at hand-in.")
    else
        ns.ToggleWrits()
    end
end

function WritShopper_OnCompartmentClick()
    ns.ToggleWrits()
end
