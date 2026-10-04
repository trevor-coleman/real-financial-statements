-- Run with any Lua 5.1-5.4 / LuaJIT:   lua tests/test_accounting.lua
-- Exercises tcoleman_financial_statements_1/content/finance/accounting.lua with synthetic data
-- that follows the game's sign convention (income > 0, costs < 0).

package.path = "./tcoleman_financial_statements_1/content/finance/?.lua;" .. package.path
local A = require "accounting"

local failures = 0
local function eq(actual, expected, msg)
	if actual ~= expected then
		failures = failures + 1
		print(("FAIL: %s (expected %s, got %s)"):format(msg, tostring(expected), tostring(actual)))
	end
end

-- Scenario, 2 periods (column 1 = "Y1", column 2 = "Y2"):
--   Y1: revenue 1000, running costs -300, infra upkeep -100, build track -5000, buy vehicles -2000,
--       take loan +6000, interest -50, repay principal 0           => cash change +ss
--   Y2: revenue 1500, running -350, upkeep -100, station -800, bulldozer -40, loan repay -1000, interest -40
local fd = {
	headers = { "Y1", "Y2" },
	entries = {
		{ source = "transport", type = "INCOME", values = { 1000, 1500 } },
		{ source = "transport", type = "MAINTENANCE", maint = "VEHICLE", values = { -300, -350 } },
		{ source = "transport", type = "MAINTENANCE", maint = "INFRASTRUCTURE", construction = "TRACK", values = { -100, -100 } },
		{ source = "investment", type = "CONSTRUCTION", construction = "TRACK", values = { -5000, 0 } },
		{ source = "investment", type = "CONSTRUCTION", construction = "STATION", values = { 0, -800 } },
		{ source = "investment", type = "CONSTRUCTION", construction = "BULLDOZER", values = { 0, -40 } },
		{ source = "investment", type = "ACQUISITION", values = { -2000, 0 } },
	},
	interest = { -50, -40 },
	loanBorrowing = { 6000, 0 },
	loanRepayment = { 0, -1000 },
}
-- game "Earnings" (total) = everything except loan principal
fd.total = { 1000 - 300 - 100 - 5000 - 2000 - 50, 1500 - 350 - 100 - 800 - 40 - 40 }
-- bank balance: start 10000
fd.balance = { 10000 + fd.total[1] + 6000, 0 }
fd.balance[2] = fd.balance[1] + fd.total[2] - 1000
fd.loan = { 6000, 5000 }

local c = A.compute(fd)

-- income statement
eq(c.totalRevenue[1], 1000, "Y1 revenue")
eq(c.totalOpex[1], -400, "Y1 opex excludes capex")
eq(c.ebitda[1], 600, "Y1 EBITDA")
eq(c.netIncome[1], 550, "Y1 net income = EBITDA - interest, capex excluded")
eq(c.totalOpex[2], -350 - 100 - 40, "Y2 opex includes demolition, not station capex")
eq(c.netIncome[2], 1500 - 490 - 40, "Y2 net income")
eq(c.totalCapex[1], -7000, "Y1 capex")
eq(c.totalCapex[2], -800, "Y2 capex")

-- loans never touch income
eq(c.financing[1], 6000, "Y1 financing = loan taken")
eq(c.financing[2], -1000, "Y2 financing = principal repaid")

-- cash flow reconciles
eq(c.unmapped[1], 0, "Y1 nothing unmapped")
eq(c.unmapped[2], 0, "Y2 nothing unmapped")
eq(c.netChange[1], 550 - 7000 + 6000, "Y1 net change in cash")
eq(c.closing[1], fd.balance[1], "Y1 closing cash equals bank balance")
eq(c.opening[1], 10000, "Y1 opening cash derived")
eq(c.opening[2], c.closing[1], "Y2 opening == Y1 closing")

local checks = A.cashFlowChecks(c, fd.balance[2])
for _, ch in ipairs(checks) do eq(ch.ok, true, "check: " .. ch.text) end

-- an unknown category must surface as unmapped/unclassified rather than silently vanish
local fd2 = { headers = { "Y1" }, entries = {
	{ source = "transport", type = "FUTURE_TYPE", values = { -77 } },
}, interest = { 0 }, total = { -77 }, balance = { 100 }, loanBorrowing = { 0 }, loanRepayment = { 0 } }
local c2 = A.compute(fd2)
eq(c2.unclassified[1], -77, "unknown category is classified as unclassified")
eq(c2.unmapped[1], 0, "and therefore still reconciles to game earnings")

-- balance sheet, using both periods as the all-time window
local live = { cash = fd.balance[2], loan = 5000, vehicleBookValue = 1500 }
local b = A.balanceSheet(fd, live)
eq(b.vehicleCost, 2000, "vehicle cost")
eq(b.infrastructureCost, 5800, "infrastructure cost = track + station, demolition excluded")
eq(b.accumulatedDepreciation, 500, "accumulated depreciation = cost - book value")
eq(b.totalAssets, live.cash + 1500 + 5800, "total assets")
eq(b.totalLiabilities, 5000, "liabilities = loans")
eq(b.balances, true, "A = L + E")
eq(b.contributedCapital, 10000, "contributed capital derived from cash roll-forward")
eq(b.unreconciled, 0, "loan flows in window match live debt")
eq(b.retainedEarnings, (550 + 970) - 500, "retained earnings = cumulative net income - accumulated depreciation")

-- if live debt disagrees with the window's loan flows it must show up as unreconciled
local b2 = A.balanceSheet(fd, { cash = fd.balance[2], loan = 4000, vehicleBookValue = 1500 })
eq(b2.unreconciled, 1000, "loan mismatch is exposed (window loan flows 5000 vs live debt 4000)")

-- depreciation from the year-end ledger ---------------------------------------------------------------
do
	local fdd = {}
	for k, v in pairs(fd) do fdd[k] = v end
	fdd.headers = { "1900", "1901" }
	-- vehicles bought for 2000 in 1900; book value 1800 at end of 1900 (started at 0); live value 1500 in 1901
	fdd.ledger = { nbvEnd = { [1899] = 0, [1900] = 1800 }, currentYear = 1901, liveNbv = 1500 }
	local cd = A.compute(fdd)
	eq(cd.depreciation[1], -200, "1900 depreciation = 0 + 2000 purchases - 1800")
	eq(cd.depreciation[2], -300, "1901 depreciation = 1800 + 0 - 1500")
	eq(cd.depreciationComplete, true, "ledger covers both periods")
	eq(cd.ebit[1], cd.ebitda[1] - 200, "EBIT = EBITDA + depreciation (cost is negative)")
	eq(cd.netIncome[1], 550 - 200, "depreciation reduces net income")
	eq(cd.unmapped[1], 0, "non-cash depreciation is added back, so Earnings still reconcile")
	eq(cd.netChange[1], 550 - 7000 + 6000, "depreciation does not change net cash")
	eq(cd.operatingCash[1], 550, "operating cash excludes the non-cash charge")

	-- a sale refunds the depreciated value: 1901 sells a vehicle (book 300) -> +300 net spend -300, no gain/loss
	local fds = {}
	for k, v in pairs(fdd) do fds[k] = v end
	fds.entries = {}
	for _, e in ipairs(fdd.entries) do fds.entries[#fds.entries + 1] = e end
	fds.entries[#fds.entries + 1] = { source = "investment", type = "ACQUISITION", values = { 0, 300 } }
	fds.ledger = { nbvEnd = { [1899] = 0, [1900] = 1800 }, currentYear = 1901, liveNbv = 1500 - 0 }
	local cs = A.compute(fds)
	-- start 1800, spend -300 (proceeds), end 1500 -> depreciation = -(1800 - 300 - 1500) = 0
	eq(cs.depreciation[2], 0, "selling at book value gives no gain/loss and no extra depreciation")

	-- missing ledger history is reported, not invented
	fdd.ledger = { nbvEnd = { [1900] = 1800 }, currentYear = 1901, liveNbv = 1500 }
	local ci = A.compute(fdd)
	eq(ci.depreciation[1], 0, "no opening value for 1900 -> shown as 0")
	eq(ci.depreciationComplete, false, "and flagged incomplete")
end

if failures == 0 then
	print("all accounting tests passed")
else
	print(failures .. " failure(s)")
	os.exit(1)
end
