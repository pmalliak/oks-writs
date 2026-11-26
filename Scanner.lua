-- Scanner.lua: one background price scan for everything the addon prices:
-- the writs shown in the writ list, the items they ask for, every Waylaid
-- Crate and every crate bundle. It records the cheapest price of each and
-- shows its progress on every "Scan prices" button. It buys nothing.
-- It also keeps the cheapest listings, so plans can price buying many.
local _, ns = ...

local SEARCH_TIMEOUT, GAP, THROTTLE_WAIT = 4, 0.25, 0.5
local FRESH = 3600 -- skip items scanned in the last hour (shift-click scans them anyway)
local PRICE_SORT = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
local EVENTS = { "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "AUCTION_HOUSE_CLOSED" }

local scan -- { queue = { itemID, ... }, index, gen, found, browsing }
local buttons = {}
local events = CreateFrame("Frame")

local function AHOpen()
    return AuctionHouseFrame and AuctionHouseFrame:IsShown()
end

function ns.Scanning()
    return scan ~= nil
end

local function Refresh()
    for _, b in ipairs(buttons) do
        if scan then
            b:SetText(("Scanning %d / %d"):format(math.min(scan.index, #scan.queue), #scan.queue))
        else
            b:SetText(b.idleLabel)
        end
    end
end

local function RefreshViews()
    if ns.RefreshWrits then ns.RefreshWrits() end
    if ns.RefreshPlan then ns.RefreshPlan() end
end

local function Finish(stopped)
    local s = scan
    scan = nil
    for _, ev in ipairs(EVENTS) do pcall(events.UnregisterEvent, events, ev) end
    Refresh()
    RefreshViews()
    if s then
        ns.Print("Price scan %s: %d of %d items found on the auction house.", stopped and "stopped" or "done",
            s.found, math.min(s.index, #s.queue))
    end
end

local Next

local function After(seconds, fn)
    local s, gen = scan, scan.gen
    C_Timer.After(seconds, function()
        if scan == s and scan.gen == gen then fn() end
    end)
end

local function Advance()
    scan.gen = scan.gen + 1
    scan.browsing = nil
    if scan.index % 10 == 0 then RefreshViews() end
    After(GAP, Next)
end

local function Throttled(retry)
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        scan.waiting = retry
        After(THROTTLE_WAIT, function()
            if scan.waiting == retry then
                scan.waiting = nil
                retry()
            end
        end)
        return true
    end
end

local function Search()
    if Throttled(Search) then return end
    scan.gen = scan.gen + 1
    C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(scan.queue[scan.index]), PRICE_SORT, false)
    After(SEARCH_TIMEOUT, Advance)
end

local function Browse()
    if Throttled(Browse) then return end
    scan.gen = scan.gen + 1
    scan.browsing = true
    C_AuctionHouse.SendBrowseQuery({ searchString = ns.ItemName(scan.queue[scan.index]), sorts = PRICE_SORT,
        filters = {}, itemClassFilters = {} })
    After(SEARCH_TIMEOUT, Advance)
end

function Next()
    if not AHOpen() then return Finish(true) end
    scan.index = scan.index + 1
    Refresh()
    if scan.index > #scan.queue then return Finish(false) end
    Search()
end

local function Found(item, copperEach)
    if copperEach and copperEach > 0 then
        ns.RecordPrice(item, copperEach)
        scan.found = scan.found + 1
    end
end

events:SetScript("OnEvent", function(_, event, a)
    if not scan then return end
    if event == "AUCTION_HOUSE_CLOSED" then return Finish(true) end
    if event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        local retry = scan.waiting
        scan.waiting = nil
        if retry then retry() end
        return
    end
    local item = scan.queue[scan.index]
    if not item then return end
    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" and a == item and not scan.browsing then
        local rows = {}
        for i = 1, math.min(60, C_AuctionHouse.GetNumCommoditySearchResults(item) or 0) do
            local r = C_AuctionHouse.GetCommoditySearchResultInfo(item, i)
            local n = r and (r.quantity or 0) - (r.numOwnerItems or 0) or 0
            if n > 0 and (r.unitPrice or 0) > 0 then rows[#rows + 1] = { r.unitPrice, n } end
        end
        ns.RecordDepth(item, rows)
        if rows[1] then Found(item, rows[1][1]) else ns.RecordMissing(item) end
        Advance()
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" and type(a) == "table" and a.itemID == item then
        local best, rows = nil, {}
        for i = 1, C_AuctionHouse.GetNumItemSearchResults(a) or 0 do
            local r = C_AuctionHouse.GetItemSearchResultInfo(a, i)
            if r and (r.buyoutAmount or 0) > 0 and not r.containsOwnerItem then
                local each = r.buyoutAmount / (r.quantity or 1)
                rows[#rows + 1] = { each, r.quantity or 1 }
                if not best or each < best then best = each end
            end
        end
        ns.RecordDepth(item, rows)
        if best then
            Found(item, best)
            Advance()
        elseif not scan.browsing and not scan.browsed then
            -- The plain item key can miss items listed with an item level: look it up by name.
            scan.browsed = true
            Browse()
        else
            ns.RecordMissing(item)
            Advance()
        end
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" and scan.browsing then
        local hit
        for _, r in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
            if r.itemKey and r.itemKey.itemID == item and (r.minPrice or 0) > 0 then
                Found(item, r.minPrice)
                hit = true
                break
            end
        end
        if not hit then ns.RecordMissing(item) end
        scan.browsed = nil
        Advance()
    end
end)

-- What a full scan covers: the writs shown (or all), their items, all crates and bundles.
local function Targets()
    local set, list = {}, {}
    local function Add(item)
        if item and not set[item] then
            set[item] = true
            list[#list + 1] = item
        end
    end
    for _, w in ipairs(ns.ShownWrits and ns.ShownWrits() or ns.WRITS) do
        Add(w.id)
        if not w.bop then Add(w.item) end
    end
    for _, crate in ipairs(ns.CRATES) do
        Add(crate.id)
        for _, b in ipairs(crate.bundles) do Add(b.item) end
    end
    return list
end

function ns.StartScan(all)
    if scan then return Finish(true) end
    if not AHOpen() then return ns.Print("Open the auction house to scan prices.") end
    if ns.BuyBusy and ns.BuyBusy() then return ns.Print("The buy list is checking or buying. Stop it first.") end
    local queue, now, prices = {}, time(), ns.DB().prices
    for _, item in ipairs(Targets()) do
        local p = prices[item]
        if all or not (p and now - p.t < FRESH) then queue[#queue + 1] = item end
    end
    if #queue == 0 then
        return ns.Print("Every price is less than an hour old. Shift-click Scan prices to scan again anyway.")
    end
    scan = { queue = queue, index = 0, gen = 0, found = 0 }
    for _, ev in ipairs(EVENTS) do pcall(events.RegisterEvent, events, ev) end
    Next()
end

-- A "Scan prices" button for any window; all of them show the same progress.
function ns.ScanButton(parent, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b.idleLabel = "Scan prices"
    b:SetText(b.idleLabel)
    b:SetScript("OnClick", function() ns.StartScan(IsShiftKeyDown()) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Scan prices")
        GameTooltip:AddLine("At the auction house: search the writs shown, their items, and every Waylaid Crate and bundle, and remember the cheapest price of each. Click again to stop.", 1, 1, 1, true)
        GameTooltip:AddLine("Prices under an hour old are skipped; shift-click to scan everything.", 0.5, 0.8, 1, true)
        GameTooltip:AddLine("Auctionator, TSM or Naowh prices are used when you have no recent scan.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    buttons[#buttons + 1] = b
    return b
end
