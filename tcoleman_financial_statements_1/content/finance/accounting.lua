-- Pure accounting logic for the three-statement finance report.
-- No game API is used in this file, so it can be unit-tested with a stock Lua interpreter
-- (see tests/test_accounting.lua).
--
-- INPUT MODEL ("normalized finance data", produced by statements.script.lua from the engine's FinanceData):
--   fd = {
--     headers = { "2031", ... },          -- one per period column (game-provided labels)
--     entries = {                         -- one per (source, key) row of the game's finance table
--       { source = "transport"|"investment"|"other",
--         type = "INCOME"|"MAINTENANCE"|"ACQUISITION"|"CONSTRUCTION"|"SUBSIDY"|"LOAN"|"INTEREST"|"OTHER"|"UNKNOWN",
--         maint = "VEHICLE"|"INFRASTRUCTURE"|"VEHICLE_MAINTENANCE"|"OTHER"|nil,
--         construction = "STREET"|"TRACK"|"SIGNAL"|"STATION"|"DEPOT"|"BULLDOZER"|"WAREHOUSE"|"OTHER"|nil,
--         values = { n numbers } },
--     },
--     interest = { n }, total = { n }, balance = { n }, loan = { n },
--     loanBorrowing = { n }, loanRepayment = { n },
--   }
-- Sign convention is the game's: income > 0, costs < 0.

local M = {}

-- Translation hook. In the game `_` looks the text up in the mod's strings.json (English text is the key, so a
-- missing translation shows English). Outside the game (unit tests) `_` is not defined and text passes through.
local function T(text)
	if _ ~= nil then return _(text) end
	return text
end

-- ---------------------------------------------------------------------------
-- classification
-- ---------------------------------------------------------------------------

-- Maps one game journal key to an accounting line id.
function M.classify(e)
	local t = e.type
	if t == "INCOME" then
		return "revenue"
	elseif t == "SUBSIDY" then
		return "subsidy"
	elseif t == "MAINTENANCE" then
		if e.maint == "VEHICLE" then return "opex_running" end
		if e.maint == "VEHICLE_MAINTENANCE" then return "opex_vehicle_maintenance" end
		if e.maint == "INFRASTRUCTURE" then return "opex_infrastructure" end
		return "opex_other"
	elseif t == "ACQUISITION" then
		return "capex_vehicles"
	elseif t == "CONSTRUCTION" then
		local c = e.construction
		if c == "STREET" then return "capex_roads" end
		if c == "TRACK" then return "capex_tracks" end
		if c == "STATION" then return "capex_stations" end
		if c == "DEPOT" then return "capex_depots" end
		if c == "SIGNAL" then return "capex_signals" end
		if c == "WAREHOUSE" then return "capex_warehouses" end
		if c == "BULLDOZER" then return "opex_demolition" end -- a cost of removing assets, not a new asset
		return "capex_other"
	elseif t == "INTEREST" then
		return "interest"
	elseif t == "LOAN" then
		return "loan_principal"
	elseif t == "OTHER" then
		return "other_operating"
	end
	-- anything the game adds later that we do not know about
	if e.source == "other" then return "other_operating" end
	return "unclassified"
end

-- Line ids in display order per statement section.
M.REVENUE_LINES = { "revenue", "subsidy" }
M.OPEX_LINES = { "opex_running", "opex_vehicle_maintenance", "opex_infrastructure", "opex_other", "opex_demolition" }
M.CAPEX_LINES = {
	"capex_vehicles", "capex_tracks", "capex_roads", "capex_stations", "capex_depots",
	"capex_signals", "capex_warehouses", "capex_other",
}

M.LABELS = {
	revenue = "Transport revenue",
	subsidy = "Subsidies",
	opex_running = "Vehicle running costs",
	opex_vehicle_maintenance = "Vehicle maintenance",
	opex_infrastructure = "Infrastructure upkeep",
	opex_other = "Other upkeep",
	other_operating = "Other operating items",
	unclassified = "Unclassified (unknown game category)",
	capex_vehicles = "Vehicles (purchases, net of sales)",
	capex_tracks = "Tracks",
	capex_roads = "Roads",
	capex_stations = "Stations",
	capex_depots = "Depots",
	capex_signals = "Signals",
	capex_warehouses = "Warehouses",
	capex_other = "Other infrastructure",
	opex_demolition = "Demolition / bulldozer",
}

-- Translated display label for a line id (looked up at call time so the current game language is used).
function M.label(id)
	local text = M.LABELS[id]
	if text == nil then return id end
	return T(text)
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function zeros(n)
	local z = {}
	for i = 1, n do z[i] = 0 end
	return z
end

local function addInto(dst, src, n)
	for i = 1, n do
		dst[i] = dst[i] + (src and src[i] or 0)
	end
end

local function vec(src, n)
	local v = {}
	for i = 1, n do v[i] = (src and src[i]) or 0 end
	return v
end

local function sumVecs(list, n)
	local s = zeros(n)
	for _, v in ipairs(list) do addInto(s, v, n) end
	return s
end

local function neg(v, n)
	local r = {}
	for i = 1, n do r[i] = -v[i] end
	return r
end

local function sub(a, b, n)
	local r = {}
	for i = 1, n do r[i] = a[i] - b[i] end
	return r
end

local function periods(fd)
	local n = #(fd.headers or {})
	local function upd(arr)
		if arr and #arr > n then n = #arr end
	end
	upd(fd.total); upd(fd.balance); upd(fd.interest); upd(fd.loan)
	for _, e in ipairs(fd.entries or {}) do upd(e.values) end
	return n
end

-- Aggregates entries into a { lineId = { n values } } map.
function M.aggregate(fd)
	local n = periods(fd)
	local lines = {}
	for _, e in ipairs(fd.entries or {}) do
		local id = M.classify(e)
		if id ~= "interest" and id ~= "loan_principal" then
			if not lines[id] then lines[id] = zeros(n) end
			addInto(lines[id], e.values, n)
		end
	end
	return lines, n
end

local function pick(lines, ids, n)
	local out = {}
	for _, id in ipairs(ids) do
		out[#out + 1] = { id = id, values = vec(lines[id], n) }
	end
	return out
end

local function anyNonZero(v)
	for i = 1, #v do if v[i] ~= 0 then return true end end
	return false
end

-- ---------------------------------------------------------------------------
-- Income statement + Cash flow (shared computation)
-- ---------------------------------------------------------------------------

-- Vehicle depreciation per period from year-end vehicle book values (see README, "depreciation ledger").
--   headers:   period labels (calendar years as strings/numbers)
--   netSpend:  net vehicle purchases per period (cost, positive; sales proceeds already netted)
--   ledger:    { nbvEnd = { [year] = book value at the end of that year }, currentYear = n, liveNbv = n }
-- Depreciation(year) = book value at start + net purchases - book value at end. A vehicle sale refunds exactly
-- the depreciated value in this game, so it cancels out (no gain/loss).
-- Returns values in the game's sign convention (cost < 0) and whether every period was computable.
function M.depreciationFromLedger(headers, netSpend, ledger)
	local dep, complete = {}, true
	for i = 1, #headers do
		local y = tonumber(headers[i])
		local startValue = y and ledger.nbvEnd[y - 1] or nil
		local endValue = nil
		if y then
			if y == ledger.currentYear and ledger.liveNbv ~= nil then
				endValue = ledger.liveNbv
			else
				endValue = ledger.nbvEnd[y]
			end
		end
		if startValue ~= nil and endValue ~= nil then
			dep[i] = -(startValue + (netSpend[i] or 0) - endValue)
		else
			dep[i] = 0
			complete = false
		end
	end
	return dep, complete
end

-- Returns a structure with every subtotal both statements need.
-- fd.ledger (optional) enables depreciation; without it depreciation is 0.
function M.compute(fd)
	local lines, n = M.aggregate(fd)

	local revenue = pick(lines, M.REVENUE_LINES, n)
	local opex = pick(lines, M.OPEX_LINES, n)
	local other = vec(lines.other_operating, n)
	local unclassified = vec(lines.unclassified, n)
	local capex = pick(lines, M.CAPEX_LINES, n)

	local totalRevenue = sumVecs({ revenue[1].values, revenue[2].values }, n)
	local opexVecs = {}
	for _, l in ipairs(opex) do opexVecs[#opexVecs + 1] = l.values end
	local totalOpex = sumVecs(opexVecs, n)

	-- Operating profit before depreciation (EBITDA). Depreciation is not distinguishable in the
	-- game's journal (see README, "Accounting compromises"), so EBIT == EBITDA in this version.
	local ebitda = sumVecs({ totalRevenue, totalOpex, other, unclassified }, n)
	-- game sign convention: a cost is negative. Needs net vehicle spend, i.e. -capex_vehicles.
	local depreciation, depreciationComplete = zeros(n), true
	local hasLedger = fd.ledger ~= nil
	if hasLedger then
		local netSpend = {}
		for i = 1, n do netSpend[i] = -((lines.capex_vehicles and lines.capex_vehicles[i]) or 0) end
		depreciation, depreciationComplete = M.depreciationFromLedger(fd.headers or {}, netSpend, fd.ledger)
		for i = #depreciation + 1, n do depreciation[i] = 0 end
	end
	local ebit = sumVecs({ ebitda, depreciation }, n)
	local interest = vec(fd.interest, n)
	local netIncome = sumVecs({ ebit, interest }, n)

	local capexVecs = {}
	for _, l in ipairs(capex) do capexVecs[#capexVecs + 1] = l.values end
	local totalCapex = sumVecs(capexVecs, n)

	local borrow = vec(fd.loanBorrowing, n)
	local repay = vec(fd.loanRepayment, n)
	local financing = sumVecs({ borrow, repay }, n)

	-- Anything in the game's own "Earnings" total we did not map into net income or capex. Depreciation is a
	-- non-cash charge, so it is added back before comparing with the game's cash-based total.
	local gameTotal = vec(fd.total, n)
	local unmapped = sub(gameTotal, sumVecs({ netIncome, neg(depreciation, n), totalCapex }, n), n)

	-- depreciation is non-cash: add it back (it is 0 in this version)
	local operatingCash = sumVecs({ netIncome, neg(depreciation, n), unmapped }, n)
	local netChange = sumVecs({ operatingCash, totalCapex, financing }, n)
	local closing = vec(fd.balance, n)
	local opening = sub(closing, netChange, n)

	return {
		n = n,
		headers = fd.headers or {},
		revenue = revenue, totalRevenue = totalRevenue,
		opex = opex, totalOpex = totalOpex,
		other = other, unclassified = unclassified,
		ebitda = ebitda, depreciation = depreciation, ebit = ebit,
		hasLedger = hasLedger, depreciationComplete = depreciationComplete,
		interest = interest, netIncome = netIncome,
		capex = capex, totalCapex = totalCapex,
		borrow = borrow, repay = repay, financing = financing,
		gameTotal = gameTotal, unmapped = unmapped,
		operatingCash = operatingCash, netChange = netChange,
		opening = opening, closing = closing,
	}
end

-- ---------------------------------------------------------------------------
-- Checks (reconciliation)
-- ---------------------------------------------------------------------------

local function allZero(v, tol)
	for i = 1, #v do
		if math.abs(v[i]) > (tol or 0) then return false end
	end
	return true
end

-- liveCash: current bank balance (nil = infinite money / sandbox).
-- Returns a list of { ok = bool, text = string }.
function M.cashFlowChecks(c, liveCash)
	local checks = {}

	checks[#checks + 1] = {
		ok = allZero(c.unmapped, 0),
		text = T("Net income (before non-cash depreciation) + investing == game 'Earnings' in every period"),
	}

	-- opening(i) must equal closing of the neighbouring period, in either column order.
	local n = c.n
	local function continuity(dir)
		for i = 1, n - 1 do
			local a, b = i, i + 1
			-- dir = 1: column i+1 is the earlier period; dir = -1: column i is the earlier period
			if dir == 1 then
				if c.opening[a] ~= c.closing[b] then return false end
			else
				if c.opening[b] ~= c.closing[a] then return false end
			end
		end
		return true
	end
	if n > 1 then
		checks[#checks + 1] = {
			ok = continuity(1) or continuity(-1),
			text = T("Opening cash of each period equals closing cash of the previous period"),
		}
	end

	if liveCash ~= nil and n > 0 then
		checks[#checks + 1] = {
			ok = (c.closing[1] == liveCash) or (c.closing[n] == liveCash),
			text = T("Latest closing cash equals the live bank balance"),
		}
	end
	return checks
end

-- ---------------------------------------------------------------------------
-- Balance sheet (single "as of now" column)
-- ---------------------------------------------------------------------------
-- allTime: normalized fd covering the widest available window (many period columns).
-- live: { cash = number|nil, loan = number, vehicleBookValue = number }
function M.balanceSheet(allTime, live)
	local c = M.compute(allTime)
	local n = c.n

	local function total(v)
		local s = 0
		for i = 1, n do s = s + (v[i] or 0) end
		return s
	end

	local vehicleCost = 0
	local infraCost = 0
	for _, l in ipairs(c.capex) do
		local spent = -total(l.values) -- capex is negative cash flow => positive asset cost
		if l.id == "capex_vehicles" then
			vehicleCost = vehicleCost + spent
		else
			infraCost = infraCost + spent
		end
	end

	local cash = live.cash
	local infiniteMoney = cash == nil
	cash = cash or 0

	local nbv = live.vehicleBookValue or 0
	local accumulatedDepreciation = vehicleCost - nbv

	local totalAssets = cash + nbv + infraCost
	local loans = live.loan or 0
	local totalLiabilities = loans
	local totalEquity = totalAssets - totalLiabilities

	-- Equity decomposition (derived, see README):
	local cumulativeNetIncomePreDep = total(c.netIncome) + total(c.unmapped)
	local cumulativeFinancing = total(c.financing)
	local cumulativeCashFlowExFinancing = total(c.netChange) - cumulativeFinancing
	-- contributed capital = cash at the start of the window, derived from the roll-forward
	local contributedCapital = cash - total(c.netChange)
	local retainedEarnings = cumulativeNetIncomePreDep - accumulatedDepreciation
	-- what the identity leaves over: loan flows in the window vs the live loan balance
	local unreconciled = totalEquity - (contributedCapital + retainedEarnings)

	return {
		infiniteMoney = infiniteMoney,
		cash = cash,
		vehicleCost = vehicleCost,
		accumulatedDepreciation = accumulatedDepreciation,
		vehicleBookValue = nbv,
		infrastructureCost = infraCost,
		totalAssets = totalAssets,
		loans = loans,
		totalLiabilities = totalLiabilities,
		contributedCapital = contributedCapital,
		retainedEarnings = retainedEarnings,
		unreconciled = unreconciled,
		totalEquity = totalEquity,
		windowPeriods = n,
		windowFirst = c.headers[1],
		windowLast = c.headers[n],
		-- Assets == Liabilities + Equity by construction (equity is derived); "unreconciled" exposes
		-- the only real data check: loan flows in the window vs the live loan balance.
		balances = math.abs(totalAssets - (totalLiabilities + totalEquity)) < 1,
		cumulativeCashFlowExFinancing = cumulativeCashFlowExFinancing,
	}
end

M.anyNonZero = anyNonZero

return M
