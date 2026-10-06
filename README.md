# Real Financial Statements: Transport Fever 3 mod (`tcoleman_financial_statements_1`)

Replaces the **Finances** tab of the vanilla finance window with three statements: **Income Statement**, **Cash Flow**, **Balance Sheet**. A fourth tab, "Default", keeps the original table. Reporting only: the mod never books journal entries or sends commands, so it cannot change the economy. (It does keep a small saved ledger of year-end vehicle values for the depreciation line; see "Depreciation ledger".)

Website: https://trevor-coleman.github.io/real-financial-statements/ · mod.io: https://mod.io/g/transportfever3/m/real-financial-statements · [Report a bug](https://github.com/trevor-coleman/real-financial-statements/issues/new?template=bug_report.md)

> **Status: written from the game's own sources, NOT yet run in-game.** The accounting logic has unit tests (`tests/test_accounting.lua`), but no Lua interpreter was available here, so they haven't been executed either. See "Validation" for what to check first.

## Architecture

| Piece | File | Role |
|---|---|---|
| Replacement registration | `content/finance/statements.res.lua` | `type = "react-replacement-config"`: the game's documented-by-example hook for replacing a vanilla GUI recipe (same mechanism the campaign missions use in `hud_replacement.res.lua`). |
| UI + engine adapter | `content/finance/statements.script.lua` | `doReplaceFn` replaces the recipe returned by vanilla `game_mechanics/finance/finances_table.tl`. Reads engine data, converts `FinanceData` to plain tables, renders tables. |
| Accounting model | `content/finance/accounting.lua` | Pure Lua, no game API. Classifies journal categories, computes statements and reconciliation checks. |
| Tests | `tests/test_accounting.lua` | Synthetic scenarios for the model. |

The replacement recipe keeps the vanilla name `FinancesTable`, so the vanilla stylesheet (`finances.css.lua`) styles the new tables.

## Data sources (authoritative engine values, nothing is re-simulated)

- `api.engine.util.finance.computeFinanceTable(player, ChartConfig)` returns `FinanceData`: per-period columns of `transport[carrier][key]`, `investment[key]`, `other`, `interest`, `loanBorrowing`, `loanRepayment`, `total` ("Earnings"), `balance`, `loan`, `header`. This is exactly what the vanilla table uses. Keys unfold to `{JournalEntry.Type, Maintenance, Construction}`.
- `api.engine.util.finance.getPlayersBalance` is the live bank balance (`nil` = sandbox infinite money).
- `Engine.Component.Account.loan` is the live total debt.
- `api.engine.util.vehicle.getVehicles()` and `getDepreciatedValue(vehicle)` give the game's own vehicle book value.

## Accounting model

Sign convention is the game's (income +, costs -).

**Income Statement.** Revenue (transport revenue + subsidies) - operating expenses = **EBITDA**; depreciation (0, see compromises) = **EBIT**; interest expense; **Net income**. CAPEX never enters net income; it appears as a memo line.

**Cash Flow (direct method).** Operating: revenue collected, opex and maintenance paid, other, interest paid. Investing: vehicles, tracks, roads, stations, depots, signals, warehouses, other infrastructure. Financing: loans taken, loan principal repaid. Net change in cash; opening cash is derived as `closing - net change`, where closing is the game's `balance` column.

**Balance Sheet (as of now).** Assets: cash, vehicles at cost less accumulated depreciation (= game book value), infrastructure at cost. Liabilities: loans. Equity: contributed capital (derived), retained earnings (cumulative net income less accumulated depreciation), plus an explicit "unreconciled" line if the loan history does not match the live debt.

Identities: `Net change in cash = CFO + CFI + CFF`; `Assets = Liabilities + Equity`. Both are shown as OK/CHECK lines under each statement so failures are visible, not hidden.

## Journal category mapping

| Game journal category | Statement | Line |
|---|---|---|
| `INCOME` | Income / CFO | Transport revenue |
| `SUBSIDY` | Income / CFO | Subsidies |
| `MAINTENANCE / VEHICLE` | Income / CFO | Vehicle running costs |
| `MAINTENANCE / VEHICLE_MAINTENANCE` | Income / CFO | Vehicle maintenance |
| `MAINTENANCE / INFRASTRUCTURE` (any construction sub-type) | Income / CFO | Infrastructure upkeep |
| `MAINTENANCE / OTHER` | Income / CFO | Other upkeep |
| `ACQUISITION` | **CAPEX** / CFI | Vehicles (net of any sales the game books here) |
| `CONSTRUCTION / TRACK, STREET, STATION, DEPOT, SIGNAL, WAREHOUSE, OTHER` | **CAPEX** / CFI | Tracks, roads, stations, depots, signals, warehouses, other infrastructure |
| `CONSTRUCTION / BULLDOZER` | Income / CFO (expense) | Demolition (a cost of removing assets, not a new asset) |
| `INTEREST` (`interest` array) | Income (below EBIT) / CFO | Interest expense |
| `LOAN` (`loanBorrowing`, `loanRepayment`) | CFF only | Loans taken / principal repaid. Never in net income. |
| `OTHER` (`other` bucket) | Income / CFO | Other operating items |
| anything unknown | Income / CFO | "Unclassified", and flagged by the reconciliation check |

`Carrier` (road/rail/tram/air/water/other) sub-splits transport rows in the game; statements aggregate across carriers.

## Accounting compromises (missing game data)

1. **Depreciation is not in the journal.** The game has no depreciation cash/expense entries, so the Income Statement shows depreciation as 0 and EBIT = EBITDA. Depreciation appears only cumulatively on the Balance Sheet as `vehicle cost - game book value`. Per-period depreciation would need a saved ledger of period-end vehicle values (a game script). Left out to keep the mod stateless.
2. **Balance Sheet is "as of now" only.** Historical vehicle and infrastructure values are not exposed, so period-end balance sheets cannot be reconstructed without a ledger.
3. **Infrastructure is at cumulative construction cost.** The game exposes no infrastructure valuation, purchase dates or per-asset costs. Demolished infrastructure is not written down (its original cost is unknown). Land and buildings are not exposed at all.
4. **Contributed capital is derived**, not read: `cash - net cash change over the data window`. Equity is therefore constructed from the data, and the only true data check is loan flows in the window vs live debt (the "unreconciled" line).
5. **Vehicle sales** are assumed to be booked by the game under `ACQUISITION` (positive). Not verified.
6. **Periods:** same 4 yearly columns as the vanilla table. Month reporting is not offered because the unit of `ChartConfig.interval` is undocumented; guessing it risked engine errors.
7. **Data window:** the Balance Sheet requests up to 250 yearly periods starting from 1840; the engine's handling of an oversized `count` is unverified.
8. Vanilla source is not fully documented; API usage is inferred from vanilla `.tl` files and type definitions.

## Vanilla files / APIs used or overridden

- **Overridden (by replacement, not file edit):** recipe from `game_mechanics/finance/finances_table.tl` (Finances tab). The original stays available through `react.CallOriginalRecipe` in the "Default" tab. No base files are modified.
- **Read for reference:** `game_mechanics/finance/{account,finances_table,finances_util,finances_assets,loan.script}.tl`, `scripts/journal.d.tl`, `game_mechanics/finance/{loan,loan_util}.d.tl`.
- **Engine APIs:** `computeFinanceTable`, `getPlayersBalance`, `ComponentType.ACCOUNT`, `api.engine.util.vehicle.getVehicles/getDepreciatedValue`, `api.engine.util.getYear`, `api.util.formatMoney`.
- **GUI:** `react.RegisterRecipe`, `react.useState`, `react.CallOriginalRecipe`, `engine_react_util.useStepStateTimer`, `builtin.TabWidget/TableLayout/Row/ScrollArea/BoxLayout/TextView`, `content_card.ContentCard`.
- **Mod mechanism:** `react-replacement-config` resource (`doReplaceFn`).

## Languages

Text is translated through the mod's `strings.json` (root of the mod folder, next to `mod.json`). In code every UI string is wrapped in `_("English text")`; the English text is the key, so a missing translation or key shows English. Languages: `en`, `ru`, `fr`, `de`, `pt_BR` (Brazilian Portuguese), `es`, `it`, `nl`, `pl`, `ja`, `ko`, `zh_CN` (Simplified), `zh_TW` (Traditional). That is every language the game itself ships. The Mod Hub name and tagline are translated via `localization` in `_metadata/modinfo.json`. The translations are automated and have not had a native-speaker review; feedback and improvements are welcome on the mod.io page.

Want another language, or can you help improve one? [Open a translation request](https://github.com/trevor-coleman/real-financial-statements/issues/new?template=translation_request.md).

To add a language: copy an entry in `strings.json` under the game's locale code (the codes are the files in the base game's `locale.zip`) and translate the values; keep the keys.

## Install

`install.ps1` copies the mod to the staging area in the Steam user-data folder (per the official docs): `C:\Program Files (x86)\Steam\userdata\<SteamID>\3493540\local\staging_area\`. Then start the game, open **Mod Hub > My Mods**, and enable the mod for a save. Use `-Target` to override the folder.

## Validation to run in-game

1. Open Finance > Finances: expect 4 tabs; confirm the game loads without a GUI error in the log.
2. Profitable services, no construction: EBITDA = Earnings; capex memo line 0.
3. Build track/stations, buy vehicles: net income unchanged by the purchase; investing cash flow drops; "Net income + investing == game Earnings" stays OK.
4. Take a loan: financing +, net income unchanged; repay: principal in financing, interest in income.
5. Advance across years; reload a save; re-check the OK lines and that Balance Sheet "unreconciled" is 0.
6. Remove the mod and load the save: economy is unchanged (the mod is stateless).

## Tests

`lua tests/test_accounting.lua` (any Lua 5.1-5.4/LuaJIT).
