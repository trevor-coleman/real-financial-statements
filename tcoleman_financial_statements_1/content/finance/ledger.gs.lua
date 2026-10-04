-- Game script: keeps the year-end vehicle book values used for the depreciation line.
-- (Registered by its .gs.lua file ending, like the base game's reforestation.gs.lua.)
function data()
	return {
		updateScript = {
			fileName = "ledger.script@update",
		},
		handleEventScript = {
			fileName = "ledger.script@handleEvent",
		},
	}
end
