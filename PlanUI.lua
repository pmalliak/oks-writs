-- PlanUI.lua: the Crates & Receipts tab of the Writ Shopper window. Left:
-- Waylaid Crates ranked by cost per Merchant's Favor, and a favor goal. Right: a
-- reputation goal met with Forged Delivery Receipts.
local _, ns = ...

local W = 640                 -- the left (crates) column
local RX, RW = 660, 394       -- the right (receipts) column: x offset and width
local ROWS, ROW_H = 14, 20
local COLS = { name = { 8, 180 }, favor = { 192, 44 }, bundle = { 240, 170 }, cost = { 414, 90 }, per = { 508, 100 } }

local frame, rows, offset, ui = nil, {}, 0, {}
local crates, favorPlan, repPlan = {}, nil, nil
local Render

local Plan = function() return ns.Plan end

local function Text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
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

local function NumberBox(parent, width, initial, onChange)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    e:SetNumeric(true)
    e:SetMaxLetters(6)
    e:SetText(tostring(initial or 0))
    e:SetScript("OnEnterPressed", e.ClearFocus)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnTextChanged", function(self, user) if user then onChange(tonumber(self:GetText()) or 0) end end)
    return e
end

local function Check(parent, label, get, set, tip)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(22, 22)
    c:SetChecked(get())
    c:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        Render()
    end)
    local t = Text(c, "GameFontHighlightSmall")
    t:SetPoint("LEFT", c, "RIGHT", 2, 0)
    t:SetText(label)
    if tip then
        c:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(label)
            GameTooltip:AddLine(tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", GameTooltip_Hide)
    end
    return c
end

local M = function(c) return ns.ShortMoney(c) end

-- Crate rows -------------------------------------------------------------------

local function NewRow(i)
    local row = CreateFrame("Frame", nil, frame)
    row:SetSize(W - 24, ROW_H)
    row:SetPoint("TOPLEFT", ui.crateHeader, "BOTTOMLEFT", 0, -(i - 1) * ROW_H - 2)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    for col, c in pairs(COLS) do
        local right = col == "cost" or col == "per" or col == "favor"
        row[col] = Text(row, nil, right and "RIGHT" or "LEFT")
        row[col]:SetPoint("LEFT", c[1], 0)
        row[col]:SetWidth(c[2])
    end
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        local o = self.option
        if not o then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(o.crate.name, 1, 0.82, 0)
        GameTooltip:AddLine(("Pays %d Merchant's Favor and %s back. Needs level %d."):format(o.favor,
            ns.Money(o.money), o.crate.level or 0), 1, 1, 1, true)
        GameTooltip:AddDoubleLine("Crate", o.crateP and ns.Money(o.crateP) or "no price", 1, 1, 1, 1, 1, 1)
        GameTooltip:AddLine("Bundles (any one fills it):", 0.8, 0.8, 0.8)
        for _, b in ipairs(o.crate.bundles) do
            local p = ns.Price(b.item)
            local best = o.bundle == b and " |cff55ff55(cheapest)|r" or ""
            GameTooltip:AddDoubleLine(("  %dx %s%s"):format(b.qty, ns.ItemName(b.item), best),
                p and ns.Money(p * b.qty) or "no price", 1, 1, 1, 0.8, 0.8, 0.8)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, d)
        offset = math.max(0, math.min(offset - d * 2, #crates - ROWS))
        Render()
    end)
    return row
end

local function FillRows()
    offset = math.max(0, math.min(offset, #crates - ROWS))
    for i = 1, ROWS do
        rows[i] = rows[i] or NewRow(i)
        local row, o = rows[i], crates[offset + i]
        row.option = o
        if not o then
            row:Hide()
        else
            row:Show()
            local dim = o.tooHigh or not o.perFavor
            row.bg:SetColorTexture(1, 1, 1, (offset + i) % 2 == 0 and 0.04 or 0)
            row.name:SetText((dim and "|cff888888" or (o.crate.quality == 2 and "|cff1eff00" or "|cffffffff"))
                .. Plan().CrateName(o.crate) .. "|r")
            row.favor:SetText(o.favor)
            row.bundle:SetText(o.bundle and ("%dx %s"):format(o.bundle.qty, ns.ItemName(o.bundle.item)) or "|cff888888no prices|r")
            row.cost:SetText(o.cost and M(o.cost) or M(nil))
            row.per:SetText(o.perFavor and (M(o.perFavor) .. (o.tooHigh and " |cffff5555lvl|r" or "")) or M(nil))
        end
    end
end

-- Summaries ------------------------------------------------------------------------

local function FavorSummary()
    local db = ns.DB()
    local goal = db.favorGoal or 0
    if goal <= 0 then return "Type how much favor you want to earn." end
    if not favorPlan then return "|cffff5555No crate has both prices yet. Scan prices at the auction house.|r" end
    local parts = {}
    for _, p in ipairs(favorPlan.picks) do
        parts[#parts + 1] = ("%dx %s (%s)"):format(p.n, Plan().CrateName(p.option.crate), ns.ItemName(p.option.bundle.item))
    end
    return ("%d favor: pay about %s at the auction house, %s comes back from the sealed crates, so %s in the end.  %s"):format(
        favorPlan.favor, ns.Money(favorPlan.spend or favorPlan.cost), ns.Money(favorPlan.back or 0), ns.Money(favorPlan.cost),
        table.concat(parts, ", "))
end

local function RepLines()
    local p = repPlan
    if not p then return "", "" end
    local R = Plan().RECEIPT
    local rate = p.receiptCost and ("One receipt: %d favor + 1 empty crate (%s) = about %s, so %s per rep."):format(R.favor,
        Plan().CrateName(p.empty.crate), ns.Money(p.receiptCost), ns.Money(math.floor(p.receiptPerRep + 0.5)))
        or "|cffff5555No crate prices yet. Press Scan prices at the auction house.|r"
    local planTxt
    if (p.target or 0) <= 0 then
        planTxt = "Type how much reputation you want."
    elseif p.receipts > 0 then
        planTxt = ("%d receipts = %d rep:  %d empty crates + %d favor%s.\n\nPay about %s at the auction house (what the buy list shows). %s comes back when you hand in the sealed crates and receipts, so it costs %s in the end."):format(p.receipts,
            p.receipts * R.rep, p.receipts, p.favorNeed or 0,
            (p.favor and #p.favor.picks > 0) and (" (" .. #p.favor.picks .. " crate types to fill)") or "",
            "|cffffffff" .. ns.Money(p.spend or p.receiptTotal or 0) .. "|r", ns.Money(p.back or 0), ns.Money(p.receiptTotal or 0))
    else
        planTxt = "|cffff5555Can't plan receipts without crate prices.|r"
    end
    return rate, planTxt
end

function Render()
    if not (frame and frame:IsVisible()) then return end
    local db, P = ns.DB(), Plan()
    crates = P.Crates()
    FillRows()
    ui.have:SetText(("You have %d Merchant's Favor."):format(P.CurrentFavor()))
    favorPlan = P.Favor(db.favorGoal or 0, crates)
    ui.favorSummary:SetText(FavorSummary())
    ui.addFavor:SetEnabled(favorPlan ~= nil and #favorPlan.picks > 0)

    local s = P.Standing()
    ui.standing:SetText(s and ("%s: %s %d / %d"):format(s.name, _G["FACTION_STANDING_LABEL" .. s.reaction] or "", s.value, s.max) or "")
    repPlan = P.Rep(db.repGoal or 0, { useFavor = db.repUseFavor, noWrits = true })
    local a, b = RepLines()
    ui.repCompare:SetText(a)
    ui.repPlan:SetText(b)
    ui.addRep:SetEnabled(repPlan and repPlan.receipts > 0 or false)
end
ns.RefreshPlan = Render

-- Builds the tab's page inside the Writ Shopper window and returns it.
function ns.BuildPlanPage(parent)
    frame = CreateFrame("Frame", "WritShopperPlanFrame", parent)
    frame:Hide()
    frame:SetAllPoints()
    local db = ns.DB()

    -- Crates
    local h1 = Text(frame, "GameFontNormal")
    h1:SetPoint("TOPLEFT", 14, -32)
    h1:SetText("Waylaid Crates: cheapest Merchant's Favor")
    ui.crateHeader = CreateFrame("Frame", nil, frame)
    ui.crateHeader:SetSize(W - 24, 16)
    ui.crateHeader:SetPoint("TOPLEFT", 12, -52)
    local heads = { name = "Crate", favor = "Favor", bundle = "Cheapest bundle", cost = "Cost", per = "Per favor" }
    for col, label in pairs(heads) do
        local right = col == "cost" or col == "per" or col == "favor"
        local fs = Text(ui.crateHeader, "GameFontNormalSmall", right and "RIGHT" or "LEFT")
        fs:SetPoint("LEFT", COLS[col][1], 0)
        fs:SetWidth(COLS[col][2])
        fs:SetText(label)
    end

    local y = -52 - 16 - ROWS * ROW_H - 10
    local fl = Text(frame, "GameFontHighlight")
    fl:SetPoint("TOPLEFT", 16, y - 3)
    fl:SetText("Favor to earn:")
    ui.favorBox = NumberBox(frame, 60, db.favorGoal or 0, function(v)
        db.favorGoal = v
        Render()
    end)
    ui.favorBox:SetPoint("LEFT", fl, "RIGHT", 10, 0)
    ui.have = Text(frame, "GameFontDisableSmall")
    ui.have:SetPoint("LEFT", ui.favorBox, "RIGHT", 10, 0)
    ui.addFavor = Button(frame, "Add crates to buy list", 170, function()
        if favorPlan then Plan().AddFavor(favorPlan) end
    end)
    ui.addFavor:SetPoint("TOPLEFT", W - 170 - 12, y)
    ui.favorSummary = Text(frame, "GameFontHighlightSmall")
    ui.favorSummary:SetPoint("TOPLEFT", 16, y - 28)
    ui.favorSummary:SetWidth(W - 32)
    ui.favorSummary:SetWordWrap(true)
    ui.favorSummary:SetJustifyV("TOP")
    ui.favorSummary:SetHeight(42)

    -- Reputation, in the right column
    local line = frame:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetWidth(1)
    line:SetPoint("TOPLEFT", RX - 10, -32)
    line:SetPoint("BOTTOMLEFT", RX - 10, 70)
    local h2 = Text(frame, "GameFontNormal")
    h2:SetPoint("TOPLEFT", RX, -32)
    h2:SetText("Reputation with Forged Delivery Receipts")
    ui.standing = Text(frame, "GameFontDisableSmall")
    ui.standing:SetPoint("TOPLEFT", RX, -50)
    local each = Text(frame, "GameFontDisableSmall")
    each:SetPoint("TOPLEFT", RX, -64)
    each:SetText("Each receipt: 15 Merchant's Favor + 1 empty Waylaid Crate = 50 rep.")

    y = -92
    local rl = Text(frame, "GameFontHighlight")
    rl:SetPoint("TOPLEFT", RX, y - 3)
    rl:SetText("Reputation wanted:")
    ui.repBox = NumberBox(frame, 70, db.repGoal or 0, function(v)
        db.repGoal = v
        Render()
    end)
    ui.repBox:SetPoint("LEFT", rl, "RIGHT", 10, 0)
    ui.addRep = Button(frame, "Add receipts to buy list", 170, function()
        if repPlan then Plan().AddRep(repPlan) end
    end)
    ui.addRep:SetPoint("TOPRIGHT", -14, y)

    y = y - 28
    local c2 = Check(frame, "Count the favor I have", function() return db.repUseFavor end,
        function(v) db.repUseFavor = v end, "Take your current Merchant's Favor off what the receipts need.")
    c2:SetPoint("TOPLEFT", RX - 2, y)

    y = y - 34
    ui.repCompare = Text(frame, "GameFontHighlightSmall")
    ui.repCompare:SetPoint("TOPLEFT", RX, y)
    ui.repCompare:SetWidth(RW)
    ui.repCompare:SetWordWrap(true)
    ui.repCompare:SetJustifyV("TOP")
    ui.repCompare:SetHeight(44)
    ui.repPlan = Text(frame, "GameFontHighlightSmall")
    ui.repPlan:SetPoint("TOPLEFT", RX, y - 52)
    ui.repPlan:SetWidth(RW)
    ui.repPlan:SetWordWrap(true)
    ui.repPlan:SetJustifyV("TOP")
    ui.repPlan:SetHeight(90)

    local note = Text(frame, "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 16, 44)
    note:SetWidth(W + 60)
    note:SetWordWrap(true)
    note:SetText("After a scan, plans price buying many the way the auction house does (cheapest listings first). Without one they use one price per item from Auctionator, TSM or Naowh.")
    local scan = ns.ScanButton(frame, 130)
    scan:SetPoint("BOTTOMRIGHT", -14, 40)

    frame:SetScript("OnShow", Render)
    frame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
    frame:RegisterEvent("UPDATE_FACTION")
    frame:SetScript("OnEvent", function() Render() end)
    ns.OnChange(Render)
    return frame
end
