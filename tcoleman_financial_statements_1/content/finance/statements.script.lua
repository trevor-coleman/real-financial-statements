-- Three-statement finance report (Income Statement / Cash Flow / Balance Sheet).
--
-- Replaces the recipe behind the "Finances" tab of the vanilla finance window (finances_table.tl).
-- It only READS engine data (computeFinanceTable, account balance/loan, vehicle depreciated value);
-- it never books journal entries, sends commands or stores state, so the save game is untouched.
--
-- The vanilla recipe is registered under the same name ("FinancesTable") on purpose: that makes the
-- vanilla stylesheet selectors (R::FinancesTable ...) apply to the table markup below.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local content_card = ug_require "::/gui/main/content_card.tl"
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl"
local original_finances_table = ug_require "::/game_mechanics/finance/finances_table.tl"
local accounting = ug_require "tcoleman_financial_statements_1::/finance/accounting.lua"

-- Translation helper. NEVER call the game's `_()` directly in this file: Lua code here uses `_` as a
-- throwaway loop variable (for _, x in ipairs(...)), which would shadow the global function with a number.
-- `tr` is defined at file level, where `_` is still the global translation function.
local function tr(text)
	return _(text)
end

local JE = api.type.JournalEntry

-- ---------------------------------------------------------------------------
-- engine FinanceData  ->  plain tables understood by accounting.lua
-- ---------------------------------------------------------------------------

local function nameOf(pairsList, value, default)
	for _, p in ipairs(pairsList) do
		if p[1] == value then return p[2] end
	end
	return default
end

local TYPE_NAMES = {
	{ JE.Type.LOAN, "LOAN" }, { JE.Type.INTEREST, "INTEREST" }, { JE.Type.CONSTRUCTION, "CONSTRUCTION" },
	{ JE.Type.ACQUISITION, "ACQUISITION" }, { JE.Type.MAINTENANCE, "MAINTENANCE" }, { JE.Type.INCOME, "INCOME" },
	{ JE.Type.OTHER, "OTHER" }, { JE.Type.SUBSIDY, "SUBSIDY" },
}
local MAINT_NAMES = {
	{ JE.Maintenance.VEHICLE, "VEHICLE" }, { JE.Maintenance.INFRASTRUCTURE, "INFRASTRUCTURE" },
	{ JE.Maintenance.OTHER, "OTHER" }, { JE.Maintenance.VEHICLE_MAINTENANCE, "VEHICLE_MAINTENANCE" },
}
local CONSTRUCTION_NAMES = {
	{ JE.Construction.STREET, "STREET" }, { JE.Construction.TRACK, "TRACK" }, { JE.Construction.SIGNAL, "SIGNAL" },
	{ JE.Construction.STATION, "STATION" }, { JE.Construction.DEPOT, "DEPOT" },
	{ JE.Construction.BULLDOZER, "BULLDOZER" }, { JE.Construction.WAREHOUSE, "WAREHOUSE" },
	{ JE.Construction.OTHER, "OTHER" },
}
local CARRIER_NAMES = {
	{ JE.Carrier.ROAD, "ROAD" }, { JE.Carrier.RAIL, "RAIL" }, { JE.Carrier.TRAM, "TRAM" },
	{ JE.Carrier.WATER, "WATER" }, { JE.Carrier.AIR, "AIR" }, { JE.Carrier.OTHER, "OTHER" },
}

local function copyArray(src)
	local out = {}
	if src ~= nil then
		for i = 1, #src do out[i] = src[i] end
	end
	return out
end

local function normalize(fd)
	local out = {
		headers = copyArray(fd.header),
		entries = {},
		interest = copyArray(fd.interest),
		total = copyArray(fd.total),
		balance = copyArray(fd.balance),
		loan = copyArray(fd.loan),
		loanBorrowing = copyArray(fd.loanBorrowing),
		loanRepayment = copyArray(fd.loanRepayment),
	}

	local function addKeyed(source, key, values, carrierName)
		local unfolded = fd:unfoldKey(key)
		out.entries[#out.entries + 1] = {
			source = source,
			carrier = carrierName,
			type = nameOf(TYPE_NAMES, unfolded[1], "UNKNOWN"),
			maint = nameOf(MAINT_NAMES, unfolded[2], nil),
			construction = nameOf(CONSTRUCTION_NAMES, unfolded[3], nil),
			values = copyArray(values),
		}
	end

	-- Iterate only the carriers the engine reports (like the vanilla table does). Asking for a fixed list
	-- double counts: foreach_transport(TRAM) returns the same rows as foreach_transport(ROAD).
	local presentCarriers = {}
	fd:foreach_carrier(function(carrier)
		presentCarriers[#presentCarriers + 1] = carrier
	end)
	for _, carrier in ipairs(presentCarriers) do
		local carrierName = nameOf(CARRIER_NAMES, carrier, "?")
		fd:foreach_transport(function(key, values)
			addKeyed("transport", key, values, carrierName)
		end, carrier)
	end
	fd:foreach_investment(function(key, values)
		addKeyed("investment", key, values)
	end)
	fd:foreach_other(function(_, values)
		out.entries[#out.entries + 1] = { source = "other", type = "OTHER", values = copyArray(values) }
	end)

	return out
end

-- ---------------------------------------------------------------------------
-- engine state readers
-- ---------------------------------------------------------------------------

-- Same view as the vanilla table: 4 period columns.
local function makePeriodState()
	local config = api.type.ChartConfig.new()
	config.count = 4
	return api.engine.util.finance.computeFinanceTable(api.engine.util.getPlayer(), config)
end

local function totalVehicleBookValue()
	local total = 0
	for _, vehicle in ipairs(api.engine.util.vehicle.getVehicles()) do
		local ok, value = pcall(api.engine.util.vehicle.getDepreciatedValue, vehicle)
		if ok and value then total = total + value end
	end
	return total
end

-- Year-end vehicle book values recorded by finance/ledger.gs.lua. Returns { [year] = value } or nil when
-- the game script is not running (e.g. mod added before the game script was instantiated).
local LEDGER_GS = "tcoleman_financial_statements_1::/finance/ledger.gs"
local function readLedgerYears()
	local map = {}
	local ok, ends = pcall(function()
		local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(LEDGER_GS)
		if entity == nil or entity < 0 then return nil end
		local component = api.engine.getComponent(entity, api.type.ComponentType.GAME_SCRIPT)
		local state = component and component.state or nil
		return state and state.nbvEnd or nil
	end)
	if not ok or ends == nil then return nil end
	local thisYear = api.engine.util.getYear()
	for year = thisYear - 80, thisYear do
		local okValue, value = pcall(function() return ends[tostring(year)] end)
		if okValue and value ~= nil then map[year] = value end
	end
	return map
end

local function ledgerEqual(a, b)
	if a == nil or b == nil then return a == b end
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k, v in pairs(b) do if a[k] ~= v then return false end end
	return true
end

-- Balance sheet: widest available history (for cumulative capex / retained earnings) plus live values.
local FIRST_GAME_YEAR = 1840
local function makeBalanceState()
	local player = api.engine.util.getPlayer()
	local config = api.type.ChartConfig.new()
	local years = api.engine.util.getYear() - FIRST_GAME_YEAR + 1
	if years < 4 then years = 4 end
	if years > 250 then years = 250 end
	config.count = years
	local fd = api.engine.util.finance.computeFinanceTable(player, config)

	local account = api.engine.getComponent(player, api.type.ComponentType.ACCOUNT)
	local loan = account and account.loan or 0

	local bookValue = totalVehicleBookValue()

	return {
		fd = fd,
		cash = api.engine.util.finance.getPlayersBalance(player), -- nil == infinite money
		loan = loan,
		vehicleBookValue = bookValue,
	}
end

local function periodStateEqual(a, b)
	return a == b
end

local function balanceStateEqual(a, b)
	if a == nil or b == nil then return a == b end
	return a.cash == b.cash and a.loan == b.loan and a.vehicleBookValue == b.vehicleBookValue and a.fd == b.fd
end

-- ---------------------------------------------------------------------------
-- table rendering (mirrors the markup of the vanilla finance table so vanilla styles apply)
-- ---------------------------------------------------------------------------

local StatementCell = react.RegisterRecipe("StatementCell", function(param)
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.TextView{
				meta = { class = param.class },
				text = param.text,
			},
		},
	}
end)

local function rowClass(index, variant, isFirst, isLast)
	local variantClass = nil
	if variant == "First" then
		if isFirst then variantClass = "upper-left-corner"
		elseif isLast then variantClass = "upper-right-corner"
		else variantClass = "header" end
	elseif variant == "Last" then
		if isFirst then variantClass = "lower-left-corner"
		elseif isLast then variantClass = "lower-right-corner"
		else variantClass = "footer" end
	end
	local class = (index % 2 == 0) and "even" or "odd"
	if variantClass then class = class .. ", " .. variantClass end
	if variant == nil then
		if isLast then class = class .. ", right-edge"
		elseif isFirst then class = class .. ", left-edge" end
	end
	return class
end

local function money(value)
	if value == nil then return "-" end
	return api.util.formatMoney(math.floor(value + (value >= 0 and 0.5 or -0.5)))
end

local function makeRow(rowKey, texts, classes, index, variant, sumLine)
	local cells = {}
	for i, text in ipairs(texts) do
		local textClass = "font-scale-body"
		if classes[i] then textClass = textClass .. ", " .. classes[i] end
		cells[i] = StatementCell{
			meta = { class = "cell, view, " .. rowClass(index, variant, i == 1, i == #texts)
				.. (sumLine and ", sum-line" or "") },
			class = textClass,
			text = text,
		}
	end
	return builtin.Row{ meta = { localKey = rowKey }, cells = cells }
end

local ARROW_RIGHT = "::/game_mechanics/finance/icons/slim_arrow_right.tga"
local ARROW_DOWN = "::/game_mechanics/finance/icons/slim_arrow_down.tga"

-- A clickable section-header cell (same markup as the vanilla table's expandable rows).
local SectionCell = react.RegisterRecipe("SectionCell", function(param)
	local buttonRef = react.useNodeRef()
	local content
	if param.isFirst then
		content = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				builtin.ImageView{
					meta = { class = "text-icon-size-hack, category" },
					path = param.expanded and ARROW_DOWN or ARROW_RIGHT,
				},
				builtin.TextView{ meta = { class = param.textClass }, text = param.text },
			},
		}
	else
		content = builtin.TextView{ meta = { class = param.textClass }, text = param.text }
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		child = builtin.ToggleButton(react.ref(buttonRef), {
			content = content,
			value = param.expanded and 1 or 0,
			onValueChange = function(_)
				param.onToggle()
			end,
			meta = { class = "cell-button" .. (param.isFirst and ", left-edge" or "") .. (param.isLast and ", right-edge" or "") },
		}),
	}
end)

local function makeSectionRow(rowKey, texts, classes, index, expanded, onToggle)
	local cells = {}
	for i, text in ipairs(texts) do
		local textClass = "font-scale-body"
		if classes[i] then textClass = textClass .. ", " .. classes[i] end
		local edge = (i == #texts) and ", right-edge" or (i == 1 and ", left-edge" or "")
		cells[i] = SectionCell{
			meta = { class = "cell, " .. ((index % 2 == 0) and "even" or "odd") .. edge },
			text = text,
			textClass = textClass,
			isFirst = i == 1,
			isLast = i == #texts,
			expanded = expanded,
			onToggle = onToggle,
		}
	end
	return builtin.Row{ meta = { localKey = rowKey }, cells = cells }
end

-- rows: list of { label, values = {..}|nil, kind = "header"|"line"|"total"|"memo", key = sectionKey (header),
--                 parent = sectionKey (line) }.  expanded: { sectionKey = 0|1 };  toggle(sectionKey)
local function buildTable(prefix, headers, rows, expanded, toggle)
	local columns = #headers

	local headerTexts, headerClasses = { "" }, { "category" }
	for i, h in ipairs(headers) do
		headerTexts[i + 1] = tostring(h)
		headerClasses[i + 1] = nil
	end
	local headerRows = { makeRow(prefix .. "-header", headerTexts, headerClasses, 0, "First") }

	local detailRows = {}
	local index = 0
	for rowNumber, row in ipairs(rows) do
		local visible = row.parent == nil or expanded == nil or expanded[row.parent] == 1
		if visible then
			index = index + 1
			local label = row.label
			if row.kind == "total" or row.kind == "header" then
				label = string.upper(label)
			elseif row.kind == "line" or row.kind == "memo" then
				label = "    " .. label
			end
			local texts, classes = { label }, { "category" }
			for i = 1, columns do
				if row.values ~= nil then
					local v = row.values[i]
					texts[i + 1] = money(v)
					classes[i + 1] = (v ~= nil and v < 0) and "negative" or "positive"
				else
					texts[i + 1] = ""
				end
			end
			local rowKey = prefix .. "-" .. tostring(rowNumber)
			if row.kind == "header" and expanded ~= nil then
				detailRows[#detailRows + 1] = makeSectionRow(rowKey, texts, classes, index,
					expanded[row.key] == 1, function() toggle(row.key) end)
			else
				-- a rule above every total row shows where the sum is taken
				detailRows[#detailRows + 1] = makeRow(rowKey, texts, classes, index, nil, row.kind == "total")
			end
		end
	end

	local weights = { 24 }
	for _ = 1, columns do weights[#weights + 1] = 10 end

	return builtin.Component{
		meta = { class = "table" },
		layout = builtin.BoxLayout{
			meta = { class = "table-box-layout" },
			orientation = builtin.type.Orientation.Vertical,
			children = {
				builtin.TableLayout{ columnWeights = weights, rows = headerRows },
				builtin.ScrollArea{
					content = builtin.Component{
						layout = builtin.BoxLayout{
							orientation = builtin.type.Orientation.Vertical,
							children = {
								builtin.Component{
									layout = builtin.TableLayout{ columnWeights = weights, rows = detailRows },
								},
								builtin.Component{},
							},
						},
					},
					horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
					verticalPolicy = builtin.type.ScrollBarPolicy.AsNeededButAlwaysReserveSpace,
					disableGamepadNavigation = true,
				},
			},
		},
	}
end

local function buildChecks(checks)
	local children = {}
	for _, check in ipairs(checks) do
		children[#children + 1] = builtin.TextView{
			meta = { class = "font-scale-body, " .. (check.ok and "positive" or "negative") },
			text = (check.ok and tr("OK:  ") or tr("CHECK:  ")) .. check.text,
		}
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end

local function statementPage(title, table, checks)
	return builtin.Component{
		layout = builtin.BoxLayout{
			meta = { class = "content-layout" },
			orientation = builtin.type.Orientation.Vertical,
			children = {
				content_card.ContentCard{ title = title },
				table,
				content_card.ContentCard{ title = tr("Reconciliation checks") },
				buildChecks(checks),
			},
		},
	}
end

local function placeholderPage(text)
	return builtin.Component{
		layout = builtin.BoxLayout{
			meta = { class = "content-layout" },
			orientation = builtin.type.Orientation.Vertical,
			children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = text } },
		},
	}
end

-- ---------------------------------------------------------------------------
-- statement row builders
-- ---------------------------------------------------------------------------

local function addLines(rows, lines, skipZero, parent)
	for _, l in ipairs(lines) do
		if not skipZero or accounting.anyNonZero(l.values) then
			rows[#rows + 1] = { label = accounting.label(l.id), values = l.values, kind = "line", parent = parent }
		end
	end
end

-- Section headers ("header" rows) carry the section total and can be collapsed; their detail lines
-- carry parent = header key.

local function incomeStatementRows(c)
	local rows = {}
	rows[#rows + 1] = { label = tr("Revenue"), values = c.totalRevenue, kind = "header", key = "is_rev" }
	addLines(rows, c.revenue, false, "is_rev")
	rows[#rows + 1] = { label = tr("Operating expenses"), values = c.totalOpex, kind = "header", key = "is_opex" }
	addLines(rows, c.opex, true, "is_opex")
	if accounting.anyNonZero(c.other) then
		rows[#rows + 1] = { label = accounting.label("other_operating"), values = c.other, kind = "line", parent = "is_opex" }
	end
	if accounting.anyNonZero(c.unclassified) then
		rows[#rows + 1] = { label = accounting.label("unclassified"), values = c.unclassified, kind = "line", parent = "is_opex" }
	end
	rows[#rows + 1] = { label = tr("Operating profit before depreciation (EBITDA)"), values = c.ebitda, kind = "total" }
	rows[#rows + 1] = { label = c.hasLedger and tr("Depreciation (vehicles, from year-end values)") or tr("Depreciation (ledger not running)"),
		values = c.depreciation, kind = "line" }
	rows[#rows + 1] = { label = tr("EBIT / operating profit"), values = c.ebit, kind = "total" }
	rows[#rows + 1] = { label = tr("Interest expense"), values = c.interest, kind = "line" }
	rows[#rows + 1] = { label = tr("Net income"), values = c.netIncome, kind = "total" }
	rows[#rows + 1] = { label = tr("Memo: capital expenditure (excluded above)"), values = c.totalCapex, kind = "memo" }
	rows[#rows + 1] = { label = tr("Memo: game 'Earnings' (= net income + depreciation + capex)"), values = c.gameTotal, kind = "memo" }
	return rows
end

local function cashFlowRows(c)
	local rows = {}
	rows[#rows + 1] = { label = tr("Net cash from operating activities"), values = c.operatingCash, kind = "header", key = "cf_op" }
	rows[#rows + 1] = { label = tr("Revenue collected (incl. subsidies)"), values = c.totalRevenue, kind = "line", parent = "cf_op" }
	rows[#rows + 1] = { label = tr("Operating expenses & maintenance paid"), values = c.totalOpex, kind = "line", parent = "cf_op" }
	local otherOp = {}
	for i = 1, c.n do otherOp[i] = c.other[i] + c.unclassified[i] end
	if accounting.anyNonZero(otherOp) then
		rows[#rows + 1] = { label = tr("Other operating items"), values = otherOp, kind = "line", parent = "cf_op" }
	end
	rows[#rows + 1] = { label = tr("Interest paid"), values = c.interest, kind = "line", parent = "cf_op" }
	if accounting.anyNonZero(c.unmapped) then
		rows[#rows + 1] = { label = tr("Unmapped vs game Earnings"), values = c.unmapped, kind = "line", parent = "cf_op" }
	end

	rows[#rows + 1] = { label = tr("Net cash from investing activities"), values = c.totalCapex, kind = "header", key = "cf_inv" }
	addLines(rows, c.capex, true, "cf_inv")

	rows[#rows + 1] = { label = tr("Net cash from financing activities"), values = c.financing, kind = "header", key = "cf_fin" }
	rows[#rows + 1] = { label = tr("Loans taken"), values = c.borrow, kind = "line", parent = "cf_fin" }
	rows[#rows + 1] = { label = tr("Loan principal repaid"), values = c.repay, kind = "line", parent = "cf_fin" }

	rows[#rows + 1] = { label = tr("Net change in cash"), values = c.netChange, kind = "total" }
	rows[#rows + 1] = { label = tr("Opening cash"), values = c.opening, kind = "line" }
	rows[#rows + 1] = { label = tr("Closing cash (bank account)"), values = c.closing, kind = "total" }
	return rows
end

local function balanceSheetRows(b)
	local one = function(v) return { v } end
	local rows = {}
	rows[#rows + 1] = { label = tr("Total assets"), values = one(b.totalAssets), kind = "header", key = "bs_assets" }
	rows[#rows + 1] = { label = tr("Cash (bank account)"), values = one(b.cash), kind = "line", parent = "bs_assets" }
	rows[#rows + 1] = { label = tr("Vehicles at cost (net purchases)"), values = one(b.vehicleCost), kind = "line", parent = "bs_assets" }
	rows[#rows + 1] = { label = tr("Less: accumulated depreciation"), values = one(-b.accumulatedDepreciation), kind = "line", parent = "bs_assets" }
	rows[#rows + 1] = { label = tr("Vehicles, net book value (game value)"), values = one(b.vehicleBookValue), kind = "line", parent = "bs_assets" }
	rows[#rows + 1] = { label = tr("Infrastructure at cost (cumulative construction)"), values = one(b.infrastructureCost), kind = "line", parent = "bs_assets" }
	rows[#rows + 1] = { label = tr("Total liabilities"), values = one(b.totalLiabilities), kind = "header", key = "bs_liab" }
	rows[#rows + 1] = { label = tr("Loans outstanding"), values = one(b.loans), kind = "line", parent = "bs_liab" }
	rows[#rows + 1] = { label = tr("Total equity"), values = one(b.totalEquity), kind = "header", key = "bs_equity" }
	rows[#rows + 1] = { label = tr("Contributed capital (derived)"), values = one(b.contributedCapital), kind = "line", parent = "bs_equity" }
	rows[#rows + 1] = { label = tr("Retained earnings (after depreciation)"), values = one(b.retainedEarnings), kind = "line", parent = "bs_equity" }
	if math.abs(b.unreconciled) >= 1 then
		rows[#rows + 1] = { label = tr("Unreconciled (loan flows vs live debt)"), values = one(b.unreconciled), kind = "line", parent = "bs_equity" }
	end
	rows[#rows + 1] = { label = tr("Total liabilities + equity"), values = one(b.totalLiabilities + b.totalEquity), kind = "total" }
	return rows
end

-- ---------------------------------------------------------------------------
-- recipe
-- ---------------------------------------------------------------------------

local StatementsRecipe = react.RegisterRecipe("FinancesTable", function()
	react.useInputAction("IA_NAV_LEFT", react.iaFocusTraversal(true, false))
	react.useInputAction("IA_NAV_RIGHT", react.iaFocusTraversal(true, true))
	react.useInputAction("IA_NAV_UP", react.iaFocusTraversal(false, false))
	react.useInputAction("IA_NAV_DOWN", react.iaFocusTraversal(false, true))

	local tabState = react.useState("Income")

	-- one expanded/collapsed flag per collapsible section (fixed list: hook count must stay stable)
	local SECTION_KEYS = { "is_rev", "is_opex", "cf_op", "cf_inv", "cf_fin", "bs_assets", "bs_liab", "bs_equity" }
	local sectionStates = {}
	for _, key in ipairs(SECTION_KEYS) do
		sectionStates[key] = react.useState(1)
	end
	local expanded = {}
	for _, key in ipairs(SECTION_KEYS) do
		expanded[key] = sectionStates[key]:old()
	end
	local function toggleSection(key)
		sectionStates[key]:set(expanded[key] == 1 and 0 or 1)
	end

	local periodState = engine_react_util.useStepStateTimer(makePeriodState, nil, periodStateEqual)

	-- the balance sheet walks every vehicle, so only refresh it while its tab is open
	local balanceState = engine_react_util.useStepStateTimer(function(old)
		if tabState:old() ~= "Balance" then return old end
		return makeBalanceState()
	end, nil, balanceStateEqual)

	-- depreciation inputs: recorded year-end values + live vehicle value (skipped on tabs that don't need it)
	local ledgerState = engine_react_util.useStepStateTimer(readLedgerYears, nil, ledgerEqual)
	local liveValueState = engine_react_util.useStepStateTimer(function(old)
		local tab = tabState:old()
		if tab == "Vanilla" or tab == "Balance" then return old end
		return totalVehicleBookValue()
	end, nil)

	local normalizedPeriods = normalize(periodState:old())
	local ledgerYears = ledgerState:old()
	if ledgerYears ~= nil then
		normalizedPeriods.ledger = {
			nbvEnd = ledgerYears,
			currentYear = api.engine.util.getYear(),
			liveNbv = liveValueState:old(),
		}
	end
	local computed = accounting.compute(normalizedPeriods)

	local liveCash = api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer())

	local incomePage = statementPage(
		tr("Income Statement"),
		buildTable("is", computed.headers, incomeStatementRows(computed), expanded, toggleSection),
		(function()
			local checks = {
				{ ok = true, text = tr("Capital expenditure is excluded from net income (shown as a memo line)") },
				accounting.cashFlowChecks(computed, liveCash)[1],
			}
			if not computed.hasLedger then
				checks[#checks + 1] = { ok = false, text = tr("Depreciation ledger (game script) not found: depreciation shown as 0") }
			elseif not computed.depreciationComplete then
				checks[#checks + 1] = { ok = true, text = tr("Depreciation not available for periods before the ledger started (shown as 0)") }
			end
			return checks
		end)()
	)

	local cashPage = statementPage(
		tr("Cash Flow Statement"),
		buildTable("cf", computed.headers, cashFlowRows(computed), expanded, toggleSection),
		accounting.cashFlowChecks(computed, liveCash)
	)

	local balancePage
	local bs = balanceState:old()
	if bs == nil then
		balancePage = placeholderPage(tr("Loading balance sheet..."))
	else
		local sheet = accounting.balanceSheet(normalize(bs.fd), {
			cash = bs.cash,
			loan = bs.loan,
			vehicleBookValue = bs.vehicleBookValue,
		})
		local checks = {
			{ ok = sheet.balances, text = tr("Assets = Liabilities + Equity") },
			{ ok = math.abs(sheet.unreconciled) < 1, text = tr("Loan flows in the data window match the live loan balance") },
			{ ok = true, text = tr("Data window (periods)") .. ": " .. tostring(sheet.windowPeriods) .. ", " ..
				tostring(sheet.windowFirst) .. " ... " .. tostring(sheet.windowLast) },
		}
		if sheet.infiniteMoney then
			checks[#checks + 1] = { ok = false, text = tr("Infinite-money mode: cash shown as 0") }
		end
		balancePage = statementPage(
			tr("Balance Sheet (as of now)"),
			buildTable("bs", { tr("Now") }, balanceSheetRows(sheet), expanded, toggleSection),
			checks
		)
	end

	local function tab(key, label, page)
		return builtin.TabWidgetChild{
			localKey = "statement_" .. key,
			value = key,
			indicator = builtin.TextView{
				meta = { class = "font-scale-tab-widget-indicator" },
				text = label,
			},
			item = page,
		}
	end

	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = {
			builtin.TabWidget{
				orientation = builtin.type.TabOrientation.North,
				deselectAllowed = false,
				initialValue = "Income",
				onValueChange = function(value)
					tabState:set(value)
				end,
				tabs = {
					tab("Income", tr("Income Statement"), incomePage),
					tab("Cash", tr("Cash Flow"), cashPage),
					tab("Balance", tr("Balance Sheet"), balancePage),
					tab("Vanilla", tr("Default"), react.CallOriginalRecipe(original_finances_table)),
				},
			},
		},
	}
end)

local function doReplaceFn(replacementApi)
	replacementApi.ReplaceRecipe(original_finances_table, StatementsRecipe)
end

-- plain-Lua script files are loaded through data() (unlike Teal .tl files, which return a table)
function data()
	return {
		doReplaceFn = doReplaceFn,
	}
end
