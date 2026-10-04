-- Styles for the statement tables.
-- "sum-line": a thin rule above total rows. It reuses the border artwork of the vanilla finance table
-- (finances.css.lua: !header / !upper-left-corner / !upper-right-corner) but without the rounded
-- background, so it can sit in the middle of a table.
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = {}

	local a = ssu.makeAdder(result)

	local colorDefault = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
	local contour = "::/gui/entity_window/design/card_contour.tga"

	-- rule across the middle columns
	a("R::FinancesTable !sum-line", {
		borderColor = colorDefault.BaseVeryLight,
		borderImage = {
			fileName = contour,
			horizontal = { 7, 7, 25, 25 },
			vertical = { 0, 6, 7, 7 },
		},
	})

	-- first column: rule + left table edge
	a("R::FinancesTable !sum-line!left-edge", {
		borderColor = colorDefault.BaseVeryLight,
		borderImage = {
			fileName = contour,
			horizontal = { 0, 6, 7, 7 },
			vertical = { 0, 6, 7, 7 },
		},
	})

	-- last column: rule + right table edge
	a("R::FinancesTable !sum-line!right-edge", {
		borderColor = colorDefault.BaseVeryLight,
		borderImage = {
			fileName = contour,
			horizontal = { 25, 25, 26, 32 },
			vertical = { 0, 6, 7, 7 },
		},
	})

	return result
end
