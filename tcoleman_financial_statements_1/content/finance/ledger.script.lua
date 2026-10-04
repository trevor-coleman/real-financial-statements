-- Depreciation ledger (reporting only; it never books money or changes the simulation).
--
-- State (saved with the game):
--   nbvEnd   = { ["<year>"] = total vehicle book value (api...vehicle.getDepreciatedValue) at the end of <year> }
--   lastYear = the calendar year seen on the previous tick
--   fresh    = true when the game script was created for a brand-new game (no vehicles yet)
--
-- A new game has no vehicles, so the book value at the end of the year before the start is exactly 0.
-- For a save that already existed before this mod, the opening value is unknown and is NOT invented:
-- depreciation is then only available from the second year-end onwards.

local function totalVehicleBookValue()
	local total = 0
	for _, vehicle in ipairs(api.engine.util.vehicle.getVehicles()) do
		local ok, value = pcall(api.engine.util.vehicle.getDepreciatedValue, vehicle)
		if ok and value then total = total + value end
	end
	return total
end

function data()
	return {
		update = function(_userParams, state, dt)
			if dt == 0 then return end

			local s = state:get()
			local year = api.engine.util.getYear()

			if s.lastYear == nil then
				s.nbvEnd = s.nbvEnd or {}
				if s.fresh then
					s.nbvEnd[tostring(year - 1)] = 0
					s.fresh = nil
				end
				s.lastYear = year
				state:set(s)
				return
			end

			if year ~= s.lastYear then
				-- first tick of a new year: the current value is the closing value of the year that just ended
				s.nbvEnd = s.nbvEnd or {}
				s.nbvEnd[tostring(s.lastYear)] = totalVehicleBookValue()
				s.lastYear = year
				state:set(s)
			end
		end,

		handleEvent = function(_userParams, state, _src, id, name)
			if id == "" and name == "initNewGame" then
				local s = state:get()
				s.nbvEnd = s.nbvEnd or {}
				s.fresh = true
				state:set(s)
			end
		end,
	}
end
