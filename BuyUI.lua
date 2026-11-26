-- BuyUI.lua: the Writ Shopper buy list beside the auction house.
-- Check Prices searches every item, then each click buys the next one.
-- Starting a purchase is protected (needs a real mouse click), so it is one
-- click per commodity quote plus one to confirm, and one click per auction
-- for single items such as crafted gear.
local _, ns = ...

local W, ROWS, ROW_H = 370, 16, 22
local SEARCH_TIMEOUT, BUY_TIMEOUT = 5, 15
local THROTTLE_WAIT, SEARCH_GAP = 0.5, 0.3
local MAX_TRIES = 2
local OVERPRICED = 1.10 -- warn when the final quote is 10% over the checked price
local PRICE_SORT = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
local EVENTS = {
    "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
    "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED",
    "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_SHOW_ERROR",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
}

local panel, rows, offset = nil, {}, 0
local Build
local run -- the current check/buy run, nil when idle
local ui = {}
local Render

local function AHOpen()
    return AuctionHouseFrame and AuctionHouseFrame:IsShown()
end

local function Current()
    return run and run.items[run.index]
end

local function Gen()
    run.gen = run.gen + 1
    return run.gen
end

local function After(seconds, state, fn)
    local r, gen = run, run.gen
    C_Timer.After(seconds, function()
        if run == r and run.gen == gen and run.state == state then fn() end
    end)
end

-- Checking prices ------------------------------------------------------------

local CheckNext

local function NextCheck()
    Gen()
    After(SEARCH_GAP, "checking", CheckNext)
end

local function Throttled(retry)
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        run.waiting = retry
        After(THROTTLE_WAIT, run.state, function()
            if run.waiting == retry then
                run.waiting = nil
                retry()
            end
        end)
        return true
    end
end

local function Search(e, key)
    if Throttled(function() Search(e, key) end) then return end
    Gen()
    e.key = key or e.key or C_AuctionHouse.MakeItemKey(e.item)
    C_AuctionHouse.SendSearchQuery(e.key, PRICE_SORT, true)
    local state = run.state
    After(SEARCH_TIMEOUT, state, function()
        e.tries = (e.tries or 0) + 1
        if state == "checking" then
            if e.tries < MAX_TRIES then run.index = run.index - 1 end
            NextCheck()
        else
            run.state = "noanswer"
            Render()
        end
    end)
end

local function Browse(e)
    if Throttled(function() Browse(e) end) then return end
    Gen()
    e.browsed = true
    C_AuctionHouse.SendBrowseQuery({ searchString = ns.ItemName(e.item), sorts = PRICE_SORT, filters = {}, itemClassFilters = {} })
    After(SEARCH_TIMEOUT, run.state, function()
        e.found, e.cost = 0, 0
        NextCheck()
    end)
end

function CheckNext()
    run.index = run.index + 1
    local e = Current()
    if not e then
        run.state, run.index = "checked", 0
        return Render()
    end
    Search(e)
    Render()
end

local function StartCheck(only)
    if not AHOpen() then return ns.Print("Open the auction house first.") end
    if ns.Scanning and ns.Scanning() then return ns.Print("A price scan is running. Wait for it or click Scan prices to stop it.") end
    local items = {}
    for item, qty in pairs(only or ns.List()) do items[#items + 1] = { item = item, qty = qty } end
    if #items == 0 then return end
    table.sort(items, function(a, b) return ns.ItemName(a.item) < ns.ItemName(b.item) end)
    run = { state = "checking", items = items, index = 0, gen = 0, bought = 0, spent = 0, scanOnly = only ~= nil }
    CheckNext()
end

function ns.BuyBusy()
    return run ~= nil
end

local function ReadCommodity(e)
    local have, total, rows = 0, 0, {}
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(e.item) or 0 do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(e.item, i)
        if r then
            local listed = (r.quantity or 0) - (r.numOwnerItems or 0)
            if listed > 0 and i <= 60 then rows[#rows + 1] = { r.unitPrice, listed } end
            local n = math.min(listed, e.qty - have)
            if n > 0 then have, total = have + n, total + n * r.unitPrice end
            if have >= e.qty then break end
        end
    end
    if have < e.qty and not C_AuctionHouse.HasFullCommoditySearchResults(e.item) then
        C_AuctionHouse.RequestMoreCommoditySearchResults(e.item)
        return false
    end
    e.kind, e.found, e.cost = "commodity", have, total
    ns.RecordDepth(e.item, rows)
    if not rows[1] then ns.RecordMissing(e.item) end
    if rows[1] then ns.RecordPrice(e.item, rows[1][1]) end -- the price of one; plans walk the listings for more
    return true
end

local function ReadItems(e, key)
    local list = {}
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(key) or 0 do
        local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
        if r and (r.buyoutAmount or 0) > 0 and not r.containsOwnerItem then
            list[#list + 1] = { id = r.auctionID, price = r.buyoutAmount, qty = r.quantity or 1 }
        end
    end
    table.sort(list, function(a, b) return a.price / a.qty < b.price / b.qty end)
    local have, total, take = 0, 0, {}
    for _, a in ipairs(list) do
        if have >= e.qty then break end
        take[#take + 1] = a
        have, total = have + a.qty, total + a.price
    end
    if have < e.qty and C_AuctionHouse.HasFullItemSearchResults and not C_AuctionHouse.HasFullItemSearchResults(key) then
        C_AuctionHouse.RequestMoreItemSearchResults(key)
        return false
    end
    e.kind, e.key, e.auctions = "item", key, take
    e.found, e.cost = math.min(have, e.qty), total
    local rows = {}
    for i = 1, math.min(#list, 60) do rows[i] = { list[i].price / list[i].qty, list[i].qty } end
    ns.RecordDepth(e.item, rows)
    if have > 0 then ns.RecordPrice(e.item, take[1].price / take[1].qty) end
    return true
end

-- Buying ---------------------------------------------------------------------

local Act

local function NextBuy()
    repeat
        run.index = run.index + 1
    until not Current() or (Current().found or 0) > 0
    local e = Current()
    if not e then
        run.state = "done"
    elseif e.kind == "item" then
        -- Search again so the auction IDs and prices are fresh before a click buys one.
        run.state = "refreshing"
        Search(e, e.key)
    else
        run.state = "ready"
    end
    Render()
end

local function Bought(e, qty, cost)
    run.bought = run.bought + qty
    run.spent = run.spent + (cost or 0)
    local left = (ns.List()[e.item] or 0) - qty
    e.qty = math.max(0, e.qty - qty)
    ns.ListSet(e.item, left)
end

local function Quote(e)
    run.state = "quoting"
    Gen()
    C_AuctionHouse.StartCommoditiesPurchase(e.item, e.found)
    After(SEARCH_TIMEOUT, "quoting", function()
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
        run.state = "noanswer"
        Render()
    end)
    Render()
end

local function Confirm(e)
    if GetMoney() < (run.total or 0) then return ns.Print("Not enough gold.") end
    run.state = "buying"
    Gen()
    C_AuctionHouse.ConfirmCommoditiesPurchase(e.item, e.found)
    After(BUY_TIMEOUT, "buying", function()
        run.state = "unconfirmed"
        Render()
    end)
    Render()
end

local function BuyAuction(e)
    local a = e.auctions and e.auctions[1]
    if not a then return NextBuy() end
    if GetMoney() < a.price then return ns.Print("Not enough gold.") end
    run.state, run.auction = "buying", a
    Gen()
    C_AuctionHouse.PlaceBid(a.id, a.price)
    After(BUY_TIMEOUT, "buying", function()
        run.state = "unconfirmed"
        Render()
    end)
    Render()
end

-- One hardware click: do whatever the run needs next.
function Act()
    if not run then return StartCheck() end
    local state, e = run.state, Current()
    if state == "checked" and run.scanOnly then
        run = nil
        if ns.RefreshWrits then ns.RefreshWrits() end
        if ns.RefreshPlan then ns.RefreshPlan() end
        return Render()
    end
    if state == "checked" then
        run.index = 0
        NextBuy()
        e = Current()
        if run.state == "ready" and e then return Quote(e) end
        return
    end
    if state == "done" then
        run = nil
        return Render()
    end
    if not e then return end
    if state == "ready" or state == "noanswer" or state == "unconfirmed" or state == "failed" then
        if e.kind == "item" then return BuyAuction(e) end
        return Quote(e)
    end
    if state == "quoted" then return Confirm(e) end
end

local function Skip()
    if run and run.state == "quoted" or (run and run.state == "quoting") then
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    end
    if run and run.index > 0 then NextBuy() end
end

local function Cancel()
    if run and (run.state == "quoting" or run.state == "quoted") then
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    end
    run = nil
    Render()
end

local function OnEvent(event, a, b)
    if not run then return end
    if event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        local retry = run.waiting
        run.waiting = nil
        if retry then retry() end
        return
    end
    local e, state = Current(), run.state
    if not e then return end
    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" and a == e.item and (state == "checking" or state == "refreshing") then
        if ReadCommodity(e) then
            if state == "checking" then NextCheck() else run.state = "ready" end
            Render()
        end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" and type(a) == "table" and a.itemID == e.item
        and (state == "checking" or state == "refreshing") then
        if not ReadItems(e, a) then return end
        if e.found == 0 and not e.browsed and state == "checking" then
            -- The plain item key can miss items listed with an item level; find the real key by name.
            return Browse(e)
        end
        if state == "checking" then
            NextCheck()
        else
            run.state = e.found > 0 and "ready" or "gone"
            if e.found == 0 then return NextBuy() end
        end
        Render()
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" and state == "checking" and e.browsed and not e.key2 then
        for _, r in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
            if r.itemKey and r.itemKey.itemID == e.item then
                e.key2 = true
                return Search(e, r.itemKey)
            end
        end
        e.found, e.cost = 0, 0
        NextCheck()
    elseif event == "COMMODITY_PRICE_UPDATED" and state == "quoting" then
        run.state, run.unit, run.total = "quoted", a, b
        run.warn = e.cost and e.cost > 0 and b > e.cost * OVERPRICED
        Render()
    elseif event == "COMMODITY_PRICE_UNAVAILABLE" and state == "quoting" then
        run.state = "unavailable"
        e.found = 0
        Render()
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" and (state == "buying" or state == "unconfirmed") and e.kind == "commodity" then
        Bought(e, e.found, run.total)
        NextBuy()
    elseif event == "COMMODITY_PURCHASE_FAILED" and state == "buying" then
        run.state = "failed"
        Render()
    elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" and (state == "buying" or state == "unconfirmed") and e.kind == "item" then
        local bought = run.auction
        if bought and (a == nil or a == bought.id) then
            table.remove(e.auctions, 1)
            Bought(e, bought.qty, bought.price)
            e.found = e.found - bought.qty
            run.auction = nil
            if e.qty > 0 and #e.auctions > 0 then
                run.state = "ready"
                Render()
            else
                NextBuy()
            end
        end
    elseif event == "AUCTION_HOUSE_SHOW_ERROR" and state == "buying" then
        run.state = "failed"
        Render()
    end
end

-- Panel ----------------------------------------------------------------------

local function Status(e)
    if not run then return "" end
    if e.found == nil then return Current() == e and "|cffaaaaaachecking...|r" or "" end
    if e.found == 0 then return "|cffff5555not on AH|r" end
    local s = ns.Money(e.cost)
    if e.found < e.qty then s = s .. (" |cffffaa00(only %d)|r"):format(e.found) end
    return s
end

local function Label()
    if not run then return "Check prices", AHOpen() and ns.ListCount() > 0 end
    local e, state = Current(), run.state
    local name = e and ns.ItemName(e.item) or ""
    if state == "checking" then return ("Checking %d / %d"):format(run.index, #run.items), false end
    if state == "checked" and run.scanOnly then return "Scan done (click to close)", true end
    if state == "checked" then
        local total, n = 0, 0
        for _, it in ipairs(run.items) do
            if (it.found or 0) > 0 then total, n = total + it.cost, n + 1 end
        end
        if n == 0 then return "Nothing to buy", false end
        return ("Buy %d items, %s"):format(n, ns.Money(total)), true
    end
    if state == "refreshing" then return "Checking " .. name, false end
    if state == "quoting" then return "Getting price...", false end
    if state == "quoted" then return ("Confirm %dx %s"):format(e.found, name), true end
    if state == "buying" then return "Buying...", false end
    if state == "done" then return ("Done: %d bought"):format(run.bought), true end
    if e and e.kind == "item" then
        local a = e.auctions and e.auctions[1]
        return ("Buy %s, %s"):format(name, a and ns.Money(a.price) or "?"), a ~= nil
    end
    if state == "unavailable" then return "Gone. Skip it", false end
    return ("Buy %dx %s"):format(e and e.found or 0, name), true
end

local function Note()
    if not run then
        if not AHOpen() then return "Open the auction house to check prices." end
        return ns.ListCount() == 0 and "Add writs from /writs first." or ""
    end
    local s = run.state
    if s == "quoted" then
        local note = "Final price " .. ns.Money(run.total)
        if run.warn then note = note .. " |cffff5555(over 10% more than checked)|r" end
        return note
    end
    if s == "noanswer" then return "|cffffaa00No answer from the auction house. Click to try again.|r" end
    if s == "failed" then return "|cffff5555Purchase failed. Click to try again or Skip.|r" end
    if s == "unconfirmed" then return "|cffffaa00Purchase not confirmed yet. Check your mail.|r" end
    if s == "done" then return "Spent " .. ns.Money(run.spent) .. ". Purchases arrive in the mail." end
    if s == "checked" and ns.Plan then
        local rep, writs, receipts = ns.Plan.ListRep(ns.List())
        if rep > 0 then
            local total = 0
            for _, it in ipairs(run.items) do total = total + (it.cost or 0) end
            local parts = {}
            if writs > 0 then parts[#parts + 1] = writs .. " writs" end
            if receipts > 0 then parts[#parts + 1] = receipts .. " receipts" end
            return ("|cff88ff88%d rep|r (%s), %s per rep"):format(rep, table.concat(parts, " + "), ns.ShortMoney(total / rep))
        end
    end
    return ""
end

-- The list can be edited unless a check or purchase is under way. Editing after a
-- check drops that check, since its prices were for the old amounts.
local function Editable()
    return not run or run.state == "checked" or run.state == "done"
end

local function Edit(item, qty)
    if not Editable() then return end
    run = nil
    ns.ListSet(item, qty)
end

local function NewRow(i)
    local row = CreateFrame("Button", nil, panel)
    row:SetSize(W - 24, ROW_H)
    row:SetPoint("TOPLEFT", 12, -30 - (i - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 2, 0)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 24, 0)
    row.name:SetWidth(178)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.status:SetPoint("RIGHT", -56, 0)
    row.status:SetWidth(100)
    row.status:SetJustifyH("RIGHT")
    row.status:SetWordWrap(false)
    row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButtonNoScripts")
    row.remove:SetSize(16, 16)
    row.remove:SetPoint("RIGHT", 0, 0)
    row.remove:SetScript("OnClick", function()
        if row.item then Edit(row.item, 0) end
    end)
    local function Step(label, by, x)
        local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        b:SetSize(18, 18)
        b:SetPoint("RIGHT", x, 0)
        b:SetText(label)
        b:SetScript("OnClick", function()
            if row.item then Edit(row.item, math.max(1, (ns.List()[row.item] or 0) + by)) end
        end)
        return b
    end
    row.minus = Step("-", -1, -36)
    row.plus = Step("+", 1, -18)
    row:SetScript("OnEnter", function(self)
        if not self.item then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.item)
        GameTooltip:AddLine("Use - and + to change the amount, X to remove.", 0.5, 0.8, 1)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta * 2)
        Render()
    end)
    row:SetScript("OnClick", function(self)
        if IsModifiedClick("CHATLINK") and self.item then
            local _, link = C_Item.GetItemInfo(self.item)
            if link then ChatEdit_InsertLink(link) end
        end
    end)
    return row
end

local function Entries()
    if run then return run.items end
    local items = {}
    for item, qty in pairs(ns.List()) do items[#items + 1] = { item = item, qty = qty } end
    table.sort(items, function(a, b) return ns.ItemName(a.item) < ns.ItemName(b.item) end)
    return items
end

function Render()
    if not (panel and panel:IsShown()) then return end
    local items = Entries()
    offset = math.max(0, math.min(offset, #items - ROWS))
    local cur = Current()
    for i = 1, ROWS do
        rows[i] = rows[i] or NewRow(i)
        local row, e = rows[i], items[offset + i]
        row.item = e and e.item
        if e then
            row:Show()
            row.icon:SetTexture(ns.ItemIcon(e.item))
            local done = run and e.qty == 0
            row.name:SetText(("%s%dx %s|r"):format(e == cur and "|cff33bbff" or (done and "|cff55ff55" or "|cffffffff"),
                e.qty, ns.ItemName(e.item)))
            row.status:SetText(done and "|cff55ff55bought|r" or Status(e))
            row.remove:SetShown(Editable())
            row.minus:SetShown(Editable())
            row.plus:SetShown(Editable())
        else
            row:Hide()
        end
    end
    local label, enabled = Label()
    ui.primary:SetText(label)
    ui.primary:SetEnabled(enabled and true or false)
    ui.note:SetText(Note())
    ui.skip:SetShown(run ~= nil and run.index > 0 and run.state ~= "done")
    -- Stop only while it is working; after a check the list stays editable.
    ui.cancel:SetShown(not Editable())
    ui.clear:SetShown(Editable() and ns.ListCount() > 0)
    ui.count:SetText(#items > ROWS and ("%d items, showing %d-%d (scroll for more)"):format(#items, offset + 1,
        math.min(offset + ROWS, #items)) or (#items .. " items"))
    local shownRows = math.max(1, math.min(ROWS, #items))
    panel:SetHeight(30 + shownRows * ROW_H + 96)
end
ns.RefreshBuy = Render

local function Place()
    panel:ClearAllPoints()
    local pos = ns.DB().buyPos -- where the player last dragged it, kept between sessions
    if type(pos) == "table" and pos[1] then
        panel:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        return
    end
    if AHOpen() then
        panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
    elseif WritShopperFrame and WritShopperFrame:IsShown() then
        panel:SetPoint("TOPLEFT", WritShopperFrame, "TOPRIGHT", 4, 0)
    else
        panel:SetPoint("CENTER", 300, 0)
    end
end

function Build()
    panel = CreateFrame("Frame", "WritShopperBuyFrame", UIParent, "BasicFrameTemplateWithInset")
    panel:Hide() -- new frames start shown; callers Show() it so OnShow places it
    panel:SetSize(W, 200)
    -- Above other auction house addons' windows (they use HIGH or DIALOG), below tooltips.
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetToplevel(true)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        ns.DB().buyPos = { point, relPoint, x, y }
    end)
    local title = panel.TitleText or panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if not panel.TitleText then title:SetPoint("TOP", 0, -5) end
    title:SetText("OKS Writ Shopper: Buy List")

    ui.primary = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    ui.primary:SetSize(W - 24, 26)
    ui.primary:SetPoint("BOTTOMLEFT", 12, 38)
    ui.primary:SetScript("OnClick", function() Act() end)

    ui.skip = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    ui.skip:SetSize(80, 22)
    ui.skip:SetPoint("BOTTOMLEFT", 12, 12)
    ui.skip:SetText("Skip")
    ui.skip:SetScript("OnClick", Skip)

    ui.cancel = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    ui.cancel:SetSize(80, 22)
    ui.cancel:SetPoint("LEFT", ui.skip, "RIGHT", 6, 0)
    ui.cancel:SetText("Stop")
    ui.cancel:SetScript("OnClick", Cancel)

    ui.clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    ui.clear:SetSize(90, 22)
    ui.clear:SetPoint("BOTTOMRIGHT", -12, 12)
    ui.clear:SetText("Clear list")
    ui.clear:SetScript("OnClick", function()
        run = nil
        ns.ListClear()
    end)

    ui.count = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.count:SetPoint("BOTTOMLEFT", ui.primary, "TOPLEFT", 0, 20)
    ui.count:SetJustifyH("LEFT")

    ui.note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.note:SetPoint("BOTTOMLEFT", ui.primary, "TOPLEFT", 0, 4)
    ui.note:SetWordWrap(false)
    ui.note:SetWidth(W - 24)
    ui.note:SetJustifyH("LEFT")

    panel:SetScript("OnShow", function()
        panel:Raise()
        Place()
        Render()
    end)
    panel:SetScript("OnHide", function()
        if run and run.state ~= "checking" then Cancel() end
    end)
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta * 2)
        Render()
    end)
    panel:RegisterEvent("BAG_UPDATE_DELAYED")
    panel:SetScript("OnEvent", function() Render() end)
    ns.OnChange(Render)
end

function ns.ToggleBuy()
    if not panel then Build() end
    panel:SetShown(not panel:IsShown())
end

-- Show the buy list and bring it to the front (it may be open behind the writ window).
function ns.ShowBuy()
    if not panel then Build() end
    if panel:IsShown() then
        panel:Raise()
        Render()
    else
        panel:Show()
    end
end

function ns.BuyInit()
    local events = CreateFrame("Frame")
    events:RegisterEvent("AUCTION_HOUSE_SHOW")
    events:RegisterEvent("AUCTION_HOUSE_CLOSED")
    events:SetScript("OnEvent", function(self, event, a, b)
        if event == "AUCTION_HOUSE_SHOW" then
            for _, ev in ipairs(EVENTS) do pcall(self.RegisterEvent, self, ev) end
            if ns.ListCount() > 0 then
                if not panel then Build() end
                panel:Show()
                Place()
                Render()
            end
        elseif event == "AUCTION_HOUSE_CLOSED" then
            for _, ev in ipairs(EVENTS) do pcall(self.UnregisterEvent, self, ev) end
            if run then Cancel() end
            if panel then panel:Hide() end
        else
            OnEvent(event, a, b)
        end
    end)
end
