-- Path of Building
--
-- Class: Currency Price List Control
-- Sortable list of Currency Exchange prices, used by the Trader's currency price lookup.
--
local t_sort = table.sort
local s_format = string.format

local currencyExchange = require("Classes.CurrencyExchange")

---@class CurrencyPriceListControl: ListControl
local CurrencyPriceListClass = newClass("CurrencyPriceListControl", "ListControl")

function CurrencyPriceListClass:CurrencyPriceListControl(anchor, rect, list)
	self:ListControl(anchor, rect, 16, "VERTICAL", false, list, true)
	local width = rect[3]
	self.colList = {
		{ width = width * 0.37, label = "Item", sortable = true },
		{ width = width * 0.30, label = "Category", sortable = true },
		{ width = width * 0.11, label = "Chaos", sortable = true },
		{ width = width * 0.11, label = "Divine", sortable = true },
		{ width = width * 0.11, label = "Stock", sortable = true },
	}
	self.colLabels = true
	self.sortCol = 1
	return self
end

local function formatNumber(value)
	if not value then
		return "-"
	end
	if value >= 100 then
		return s_format("%.0f", value)
	elseif value >= 10 then
		return s_format("%.1f", value)
	end
	-- keep small prices readable: two decimals while they show a value (0.01), then three (0.004), then <0.001
	local text = s_format("%.2f", value)
	if text ~= "0.00" or value == 0 then
		return text
	end
	text = s_format("%.3f", value)
	return text ~= "0.000" and text or "<0.001"
end

function CurrencyPriceListClass:GetRowValue(column, index, data)
	if column == 1 then
		return "^7" .. data.name
	elseif column == 2 then
		return "^8" .. data.category
	elseif column == 3 then
		return colorCodes.CURRENCY .. formatNumber(data.chaos)
	elseif column == 4 then
		return colorCodes.CURRENCY .. formatNumber(data.divs)
	elseif column == 5 then
		return "^7" .. tostring(data.stock)
	end
end

function CurrencyPriceListClass:ReSort(colIndex)
	self.sortCol = colIndex or self.sortCol
	local col = self.sortCol
	t_sort(self.list, function(a, b)
		if col == 2 and a.category ~= b.category then
			return a.category < b.category
		elseif (col == 3 or col == 4) and a.divs ~= b.divs then
			return a.divs > b.divs
		elseif col == 5 and a.stock ~= b.stock then
			return a.stock > b.stock
		end
		return a.name < b.name
	end)
end

function CurrencyPriceListClass:AddValueTooltip(tooltip, index, data)
	tooltip:Clear()
	tooltip:AddLine(16, "^7" .. data.name)
	tooltip:AddLine(16, colorCodes.CURRENCY .. currencyExchange.FormatPriceLong(data))
	tooltip:AddLine(16, s_format("^7%d in stock, %d traded in the last hour", data.stock, data.volume))
	tooltip:AddLine(16, "^8Price from its busiest market with chaos or divine orbs")
end
