# TF3 three-statement finance mod: investigation notes (phase 1)

Source: only the Teal typedefs under `Transport Fever 3\api\tealdef` and `base\tealdef`, plus sample mods in `mods\release`. **The vanilla finance UI source is not on disk** (compiled into the exe or packed). The modding wiki returned "Permission Denied". Nothing below has been run in-game.

## What the API exposes
| Need | API | Notes |
|---|---|---|
| Cash | `api.engine.util.finance.getPlayersBalance(player)`; `Engine.Component.Account.balance` | authoritative |
| Debt | `Account.loan` (total); `LoanTable{availableLoans, obtainedLoans}` with `Loan{amount,duration,percentage,lastPayDay,timesPaid,birthDay,...}` | per-loan terms available (state location unverified) |
| Period aggregates | `UtilFinance.computeFinanceTable(player, ChartConfig{interval,count})` -> `FinanceData` | per-period arrays: `transport[carrier][key]`, `investment[key]`, `other`, `loan`, `interest`, `loanBorrowing`, `loanRepayment`, `total`, `balance`, `header`. This is what the vanilla UI uses. |
| Charts | `getAccountChart`, `getDebtChart`, `calculateBalance(entities,start,end,maintOnly,maintType)` | aggregates only |
| Vehicle value | `UtilVehicle.getDepreciatedValue(vehicle)`, `getPartPrice`, `getRunningCost` | engine models depreciation, so a book value is available |
| Maintenance | `UtilMaintenance.calc...ForStationGroup/Subconstruction`; `MAINTENANCE_COST` component | current run-rate, not history |
| Persistence | game-script `state` (saved with the game), `getGuiSaveData/setGuiSaveData(modId)` | a mod ledger is feasible |

## Transaction categories (`JournalEntry`)
- `Type`: LOAN, INTEREST, CONSTRUCTION, ACQUISITION, MAINTENANCE, INCOME, OTHER, SUBSIDY
- `Construction`: STREET, TRACK, SIGNAL, STATION, DEPOT, BULLDOZER, WAREHOUSE, OTHER
- `Maintenance`: VEHICLE, INFRASTRUCTURE, OTHER, VEHICLE_MAINTENANCE
- `Carrier`: ROAD, RAIL, TRAM, OTHER, AIR, WATER
- `Other`: OTHER
- Entry = `{time, amount, category}`.

## Provisional mapping
INCOME -> revenue (operating); SUBSIDY -> other operating income; MAINTENANCE -> opex; INTEREST -> interest expense; CONSTRUCTION/ACQUISITION -> CAPEX (investing); BULLDOZER -> disposal/refund (check sign); LOAN -> financing (`loanBorrowing`/`loanRepayment` split).

## Gaps and risks
1. **Individual historical journal entries cannot be read**, only written (`makeJournalBookAssetCmd`) or summed. Reports must be built from `computeFinanceTable` periods, or from a mod ledger that snapshots them going forward.
2. **Infrastructure valuation is not exposed**, so infra book value would have to be a ledger of cumulative CONSTRUCTION spend, with no purchase dates or asset IDs. Land and buildings are not exposed.
3. **Depreciation** exists only for vehicles (current value). Infra depreciation would be a reporting approximation.
4. Balance sheet equity is a plug unless startup capital is known; history before the mod was installed is only recoverable via the aggregate table.
5. **UI mechanism unknown**: the finance window is a React-style GUI (`FinanceToolParam` tabs Overview/Finances/Assets/Loans/CargoLifetime). The widget API for building a window and the user-mod install path/`mod.json` format for gui scripts aren't documented on disk. Also no TF3 user-data folder exists on this PC yet (game likely never launched), so mod folder and logs can't be confirmed.
6. I cannot launch or play the game, so validation scenarios 1-8 must be done by you in-game.
