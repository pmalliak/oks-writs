-- Plan.lua: Waylaid Crates -> Merchant's Favor, and the cheapest way to a
-- reputation goal: Craftsman's Writs, Forged Delivery Receipts, or both.
--
-- How it works in Forever (values from WaylaidHelper, MIT, and WaylaidCost):
-- - A Waylaid Crate filled with any one of its bundles becomes a Sealed Crate.
--   Turning that in pays Merchant's Favor (currency 3402) and a little money,
--   by tier and colour (white = gathering crate, green = crafting crate).
-- - A Forged Delivery Receipt costs 15 Merchant's Favor and one empty Waylaid
--   Crate, and pays 50 reputation with the trade faction (and 1s back).
-- - A Craftsman's Writ pays 75 / 125 / 200 reputation by rank, once a day each.
--
-- Buying many of one thing gets dearer as the cheapest listings run out. After a
-- scan (Scan prices or the buy list's Check prices) plans walk up the listings
-- seen, as the auction house will; without one they use one price per item.
local _, ns = ...

local Plan = {}
ns.Plan = Plan

Plan.FAVOR_CURRENCY = 3402
Plan.FACTIONS = { Alliance = 2586, Horde = 2587 }
Plan.RECEIPT = { item = 262902, favor = 15, rep = 50, cashback = 100 }
Plan.WRIT_REP = { journeyman = 75, expert = 125, artisan = 200 }
local FAVOR = { apprentice = { 5, 10 }, journeyman = { 10, 20 }, expert = { 15, 30 }, artisan = { 20, 40 } }
local MONEY = { apprentice = { 250, 500 }, journeyman = { 500, 1000 }, expert = { 750, 1500 }, artisan = { 1000, 2000 } }
local UNIT = 5 -- every crate pays a multiple of 5 favor

function Plan.CurrentFavor()
    local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(Plan.FAVOR_CURRENCY)
    return info and info.quantity or 0
end

function Plan.CrateName(crate)
    return (crate.name:gsub("^Waylaid Crate: ", ""))
end

-- Every crate with what filling it costs:
-- { crate, favor, money, crateP, bundle, bundleP, cost, perFavor, tooHigh }
-- cost = crate + cheapest bundle - money paid back; nil when a price is missing.
function Plan.Crates()
    local level = UnitLevel and UnitLevel("player") or 60
    local out = {}
    for _, crate in ipairs(ns.CRATES) do
        local o = { crate = crate, favor = FAVOR[crate.tier][crate.quality], money = MONEY[crate.tier][crate.quality],
            tooHigh = (crate.level or 0) > level }
        o.crateP = ns.Price(crate.id)
        for _, b in ipairs(crate.bundles) do
            local p = ns.Price(b.item)
            if p and (not o.bundleP or p * b.qty < o.bundleP) then o.bundle, o.bundleP = b, p * b.qty end
        end
        if o.crateP and o.bundleP then
            o.cost = math.max(0, o.crateP + o.bundleP - o.money)
            o.perFavor = o.cost / o.favor
        end
        out[#out + 1] = o
    end
    table.sort(out, function(a, b)
        if (a.perFavor ~= nil) ~= (b.perFavor ~= nil) then return a.perFavor ~= nil end
        if a.perFavor and a.perFavor ~= b.perFavor then return a.perFavor < b.perFavor end
        return a.crate.name < b.crate.name
    end)
    return out
end

-- What n of a crate option costs: n crates and n of its bundle, walking up the
-- listings, less the money the sealed crates pay back. nil when a price is missing.
local function OptionCost(o, n)
    if n <= 0 then return 0 end
    local c = ns.CostFor(o.crate.id, n)
    local b = ns.CostFor(o.bundle.item, o.bundle.qty * n)
    if not (c and b) then return nil end
    return math.max(0, c + b - o.money * n)
end
Plan.OptionCost = OptionCost

-- What n of a crate option costs to buy, before any money comes back.
local function OptionSpend(o, n)
    local c, b = ns.CostFor(o.crate.id, n), ns.CostFor(o.bundle.item, o.bundle.qty * n)
    return (c or 0) + (b or 0)
end

-- Cheapest set of crates worth at least `target` favor, in steps of 5 favor.
-- Each crate's cost for 1, 2, 3... grows as its cheapest listings run out, so this
-- tries every count of each crate (a knapsack over crates). Very big targets fall
-- back to one price per crate. Returns { picks = { { option, n, cost } }, favor, cost } or nil.
local favorCache = {}
function Plan.Favor(target, crates)
    if not target or target <= 0 then return { picks = {}, favor = 0, cost = 0 } end
    local options = {}
    for _, o in ipairs(crates or Plan.Crates()) do
        if o.cost and not o.tooHigh then options[#options + 1] = o end
    end
    if #options == 0 then return nil end
    local N = math.ceil(target / UNIT)
    local key = table.concat({ target, ns.priceVersion or 0, math.floor(time() / 60), #options }, ":")
    if favorCache.key == key then return favorCache.plan end

    -- costs[i][k]: k of option i (k = 0 .. enough to reach the target alone)
    local costs, work = {}, 0
    for i, o in ipairs(options) do
        local K = math.ceil(N / (o.favor / UNIT))
        work = work + K * N
        costs[i] = K
    end
    local flat = work > 1500000
    for i, o in ipairs(options) do
        local K, t = costs[i], { [0] = 0 }
        for k = 1, K do t[k] = flat and o.cost * k or (OptionCost(o, k) or o.cost * k) end
        costs[i] = t
    end

    local dp, choice = { [0] = 0 }, {}
    for x = 1, N do dp[x] = math.huge end
    for i, o in ipairs(options) do
        local w, t, nd, ch = o.favor / UNIT, costs[i], {}, {}
        for x = 0, N do
            local best, bk = dp[x], 0
            for k = 1, #t do
                local c = dp[math.max(0, x - k * w)] + t[k]
                if c < best then best, bk = c, k end
                if x - k * w <= 0 then break end
            end
            nd[x], ch[x] = best, bk
        end
        dp, choice[i] = nd, ch
    end

    local picks, x, favor, spend = {}, N, 0, 0
    for i = #options, 1, -1 do
        local k = choice[i][x]
        if k > 0 then
            local o = options[i]
            picks[#picks + 1] = { option = o, n = k, cost = costs[i][k] }
            favor, spend = favor + o.favor * k, spend + OptionSpend(o, k)
            x = math.max(0, x - k * o.favor / UNIT)
        end
    end
    table.sort(picks, function(a, b) return a.option.perFavor < b.option.perFavor end)
    -- cost is what it costs in the end; spend is what you pay at the auction house
    -- first, before the sealed crates pay `back` when handed in.
    local plan = { picks = picks, favor = favor, cost = dp[N], spend = spend, back = math.max(0, spend - dp[N]) }
    favorCache.key, favorCache.plan = key, plan
    return plan
end

-- What one Forged Delivery Receipt costs: 15 favor at the cheapest crate's
-- rate, plus the cheapest empty crate. Returns cost, empty crate option, favor option.
function Plan.Receipt(crates)
    crates = crates or Plan.Crates()
    local bestFavor, empty
    for _, o in ipairs(crates) do
        if o.perFavor and not o.tooHigh and (not bestFavor or o.perFavor < bestFavor.perFavor) then bestFavor = o end
        if o.crateP and (not empty or o.crateP < empty.crateP) then empty = o end
    end
    if not (bestFavor and empty) then return nil end
    local R = Plan.RECEIPT
    return math.max(0, R.favor * bestFavor.perFavor + empty.crateP - R.cashback), empty, bestFavor
end

function Plan.DoneToday(w)
    return C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(w.quest) or false
end

-- Writs that can be done today, with their cost per reputation, cheapest first.
function Plan.Writs(zonesOnly)
    local zones = ns.DB().zones
    local out = {}
    for _, w in ipairs(ns.WRITS) do
        local rep = Plan.WRIT_REP[w.rank]
        local okZone = not zonesOnly or next(zones) == nil or zones[w.zone or "?"]
        if rep and okZone and not w.bop and not Plan.DoneToday(w) then
            local total, _, _, missing = ns.WritCost(w)
            if not missing then
                out[#out + 1] = { writ = w, rep = rep, cost = total, perRep = total / rep }
            end
        end
    end
    table.sort(out, function(a, b) return a.perRep < b.perRep end)
    return out
end

-- The cheapest mix for `target` reputation. Writs are taken while they beat a
-- receipt per reputation (or while no receipt can be priced); receipts cover
-- the rest. opts: zonesOnly, useFavor (count the favor you hold), noWrits, noReceipts.
function Plan.Rep(target, opts)
    opts = opts or {}
    local crates = Plan.Crates()
    local receiptCost, empty = Plan.Receipt(crates)
    local receiptPerRep = receiptCost and receiptCost / Plan.RECEIPT.rep
    local plan = { target = target, writs = {}, writRep = 0, writCost = 0, receipts = 0,
        receiptCost = receiptCost, receiptPerRep = receiptPerRep, empty = empty, available = 0 }
    local left = target or 0
    if not opts.noWrits then
        local writs = Plan.Writs(opts.zonesOnly)
        plan.available = #writs
        plan.bestWrit = writs[1]
        for _, c in ipairs(writs) do
            if left <= 0 then break end
            if opts.noReceipts or not receiptPerRep or c.perRep <= receiptPerRep then
                plan.writs[#plan.writs + 1] = c.writ
                plan.writRep, plan.writCost = plan.writRep + c.rep, plan.writCost + c.cost
                left = left - c.rep
            end
        end
    end
    if left > 0 and receiptCost and not opts.noReceipts then
        plan.receipts = math.ceil(left / Plan.RECEIPT.rep)
        local favorNeed = plan.receipts * Plan.RECEIPT.favor - (opts.useFavor and Plan.CurrentFavor() or 0)
        plan.favorNeed = math.max(0, favorNeed)
        plan.favor = Plan.Favor(plan.favorNeed, crates)
        -- Empty crates: the crate whose listings give `receipts` of them cheapest,
        -- after any of the same crate the favor plan already buys.
        local already = {}
        for _, p in ipairs(plan.favor and plan.favor.picks or {}) do already[p.option.crate.id] = p.n end
        local bestEmpty, bestCost
        for _, o in ipairs(crates) do
            if o.crateP then
                local before = already[o.crate.id] or 0
                local a, b = ns.CostFor(o.crate.id, before + plan.receipts), ns.CostFor(o.crate.id, before)
                local c = a and b and a - b
                if c and (not bestCost or c < bestCost) then bestEmpty, bestCost = o, c end
            end
        end
        plan.empty, plan.emptyCost = bestEmpty or empty, bestCost or plan.receipts * empty.crateP
        plan.receiptTotal = plan.emptyCost + (plan.favor and plan.favor.cost or 0)
            - plan.receipts * Plan.RECEIPT.cashback
        plan.back = (plan.favor and plan.favor.back or 0) + plan.receipts * Plan.RECEIPT.cashback
        plan.spend = plan.receiptTotal + plan.back
        left = left - plan.receipts * Plan.RECEIPT.rep
    end
    plan.short = math.max(0, left)
    plan.total = plan.writCost + (plan.receiptTotal or 0)
    return plan
end

-- Buy-list needs for a favor plan: each crate and the bundle it is filled with.
function Plan.FavorNeeds(favorPlan, want)
    want = want or {}
    for _, p in ipairs(favorPlan and favorPlan.picks or {}) do
        local o = p.option
        want[o.crate.id] = (want[o.crate.id] or 0) + p.n
        want[o.bundle.item] = (want[o.bundle.item] or 0) + o.bundle.qty * p.n
    end
    return want
end

function Plan.AddFavor(favorPlan)
    return ns.AddNeeds(Plan.FavorNeeds(favorPlan), ("Crates for %d favor"):format(favorPlan.favor))
end

function Plan.AddRep(plan)
    local want = ns.WritNeeds(plan.writs, {})
    if plan.receipts > 0 then
        want[plan.empty.crate.id] = (want[plan.empty.crate.id] or 0) + plan.receipts
        Plan.FavorNeeds(plan.favor, want)
    end
    return ns.AddNeeds(want, ("Plan for %d reputation"):format(plan.target))
end

-- Reputation that buying a list ({ [item] = qty }) leads to, counting what you
-- already own: writs whose item is there too, and Forged Delivery Receipts from
-- its Waylaid Crates (crates with their bundle pay favor, the rest are empty
-- crates). Returns rep, writs, receipts.
function Plan.ListRep(list)
    local function Have(item) return (list[item] or 0) + ns.Owned(item) end
    local rep, writs = 0, 0
    for _, w in ipairs(ns.WRITS) do
        local r = Plan.WRIT_REP[w.rank]
        if r and list[w.item] then
            local scrolls = Have(w.id) + ((C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(w.quest)) and 1 or 0)
            local n = math.min(scrolls, math.floor(Have(w.item) / w.count), 1) -- each writ once a day
            rep, writs = rep + n * r, writs + n
        end
    end
    local favor, empties, anyCrate = 0, 0, false
    for _, crate in ipairs(ns.CRATES) do
        local q = list[crate.id] or 0
        if q > 0 then
            anyCrate = true
            local filled = 0
            for _, b in ipairs(crate.bundles) do
                if list[b.item] then filled = filled + math.floor(Have(b.item) / b.qty) end
            end
            filled = math.min(q, filled)
            favor = favor + filled * FAVOR[crate.tier][crate.quality]
            empties = empties + q - filled
        end
    end
    local receipts = 0
    if anyCrate then
        if ns.DB().repUseFavor then favor = favor + Plan.CurrentFavor() end
        receipts = math.min(empties, math.floor(favor / Plan.RECEIPT.favor))
        rep = rep + receipts * Plan.RECEIPT.rep
    end
    return rep, writs, receipts
end

-- Your standing with your side's trade faction, or nil.
function Plan.Standing()
    local id = Plan.FACTIONS[UnitFactionGroup and UnitFactionGroup("player") or ""]
    if not (id and C_Reputation and C_Reputation.GetFactionDataByID) then return nil end
    local d = C_Reputation.GetFactionDataByID(id)
    if not (d and d.name) then return nil end
    return { name = d.name, reaction = d.reaction, value = d.currentStanding - (d.currentReactionThreshold or 0),
        max = (d.nextReactionThreshold or 0) - (d.currentReactionThreshold or 0) }
end
