-- Path of Building
--
-- Module: Currency Exchange
-- Downloads the game's hourly Currency Exchange snapshot and prices every currency item
-- (orbs, runegrafts, tattoos, omens, essences...) in chaos and divine orbs, per league.
-- Shared by the Trader (currency conversion and price lookup) and the tattoo/runegraft picker.
--
local dkjson = require "dkjson"

local t_insert = table.insert
local m_floor = math.floor
local s_format = string.format

local CHAOS = "Metadata/Items/Currency/CurrencyRerollRare"
local DIVINE = "Metadata/Items/Currency/CurrencyModValues"
local generalCurrencies = {
	[CHAOS] = true,
	[DIVINE] = true,
}
-- The snapshot changes once an hour; failed downloads are retried after a minute
local refreshSeconds = 61 * 60
local retrySeconds = 60

local M = {
	CHAOS = CHAOS,
	DIVINE = DIVINE,
	-- per realm: processed data from the last successful download
	cache = { },
	-- per realm: callbacks waiting on a download in progress
	pending = { },
	-- per realm: time of the last failed download
	failedAt = { },
	-- league the user picked for prices this session (tattoo/runegraft picker or Trader lookup)
	selectedLeague = nil,
}

--- Builds the price tables from the decoded trade static data and Currency Exchange snapshot.
--- For each item, the market pair with chaos or divine orbs that traded the most of it in the last hour
--- sets its price (ties go to the pair holding the most stock). A thin market can ask far more than
--- the busy one, e.g. 1 divine where hundreds trade for about 110 chaos.
---@param static table decoded https://www.pathofexile.com/api/trade/data/static
---@param cx table decoded Currency Exchange snapshot
---@return table data { items = { [id] = { name, short, category } }, categories = { label... }, leagues = { [league] = { prices = { [id] = { divs, stock, volume } }, chaosPerDiv, markets } } }
function M.Process(static, cx)
	local idByName = { }
	for id, name in pairs(require("Data.CurrencyNames")) do
		idByName[name] = id
	end
	local items, categories = { }, { }
	for _, category in ipairs(static.result or { }) do
		local label = category.label or category.id
		local listed = false
		for _, entry in ipairs(category.entries or { }) do
			local id = entry.id ~= "sep" and entry.text and idByName[entry.text]
			-- Not every bulk trade item is exported as currency
			if id and not items[id] then
				items[id] = { name = entry.text, short = entry.id, category = label }
				listed = true
			end
		end
		if listed then
			t_insert(categories, label)
		end
	end

	local leagues = { }
	for _, market in ipairs(cx.markets or { }) do
		local league = leagues[market.league]
		if not league then
			league = { quotes = { }, markets = 0 }
			leagues[market.league] = league
		end
		league.markets = league.markets + 1
		local fromID, toID = market.market_pair[1], market.market_pair[2]
		-- Price each item in chaos or divine orbs, and chaos orbs in divine orbs
		if generalCurrencies[fromID] and toID ~= DIVINE then
			fromID, toID = toID, fromID
		end
		local ratio, stock, volume = market.lowest_ratio or { }, market.highest_stock or { }, market.volume_traded or { }
		if items[fromID] and generalCurrencies[toID] and (ratio[fromID] or 0) > 0 and (ratio[toID] or 0) > 0 then
			local quote = {
				currency = toID,
				price = ratio[toID] / ratio[fromID],
				stock = stock[fromID] or 0,
				volume = volume[fromID] or 0,
			}
			-- Only keep the most popular option
			local old = league.quotes[fromID]
			if not old or old.volume < quote.volume or (old.volume == quote.volume and old.stock < quote.stock) then
				league.quotes[fromID] = quote
			end
		end
	end

	for name, league in pairs(leagues) do
		local chaosQuote = league.quotes[CHAOS]
		local divsPerChaos = chaosQuote and chaosQuote.currency == DIVINE and chaosQuote.price
		league.chaosPerDiv = divsPerChaos and 1 / divsPerChaos
		league.prices = { }
		for id, quote in pairs(league.quotes) do
			-- chaos-priced items need the league's chaos to divine rate
			if quote.currency == DIVINE or divsPerChaos then
				league.prices[id] = {
					divs = quote.currency == DIVINE and quote.price or quote.price * divsPerChaos,
					stock = quote.stock,
					volume = quote.volume,
				}
			end
		end
		league.quotes = nil
		if not next(league.prices) then
			leagues[name] = nil
		else
			league.prices[DIVINE] = { divs = 1, stock = 0, volume = 0 }
		end
	end
	return { items = items, categories = categories, leagues = leagues }
end

--- Forgets all downloaded data and pending or failed downloads
function M.Reset()
	M.cache = { }
	M.pending = { }
	M.failedAt = { }
	M.selectedLeague = nil
end

--- Returns the cached data for a realm, if any
---@param realm string? "pc" (default), "xbox" or "sony"
function M.Get(realm)
	return M.cache[realm or "pc"]
end

--- Downloads the snapshot for a realm unless a recent one is cached, then calls callback(data, errMsg)
---@param realm string? "pc" (default), "xbox" or "sony"
---@param callback fun(data: table?, errMsg: string?)?
function M.Fetch(realm, callback)
	realm = realm or "pc"
	local now = os.time()
	local cached = M.cache[realm]
	if cached and now - cached.timestamp < refreshSeconds then
		if callback then callback(cached) end
		return
	end
	if M.pending[realm] then
		if callback then t_insert(M.pending[realm], callback) end
		return
	end
	if M.failedAt[realm] and now - M.failedAt[realm] < retrySeconds then
		if callback then callback(cached, "Currency Exchange download failed, retrying shortly") end
		return
	end
	M.pending[realm] = { callback }
	local function finish(data, errMsg)
		local callbacks = M.pending[realm]
		M.pending[realm] = nil
		if data then
			data.timestamp = now
			data.snapshotTime = (m_floor(now / 3600) - 1) * 3600
			M.cache[realm] = data
			M.failedAt[realm] = nil
		else
			M.failedAt[realm] = now
			ConPrintf("Currency Exchange error: %s", tostring(errMsg))
		end
		for _, cb in ipairs(callbacks) do
			cb(data or cached, errMsg)
		end
	end

	-- download json containing the trade site's short names and categories for each item
	launch:DownloadPage("https://www.pathofexile.com/api/trade/data/static", function(response, errMsg)
		if errMsg then
			return finish(nil, "Error: " .. tostring(errMsg))
		end
		local static = dkjson.decode(response.body)
		if not static or not static.result then
			return finish(nil, "Could not decode static trade data")
		end
		local url = "https://web.poecdn.com/api/currency-exchange"
		if realm ~= "pc" then
			url = url .. "/" .. realm
		end
		-- the last complete hour
		local hourSeconds = 60 * 60
		url = url .. "/" .. ((m_floor(now / hourSeconds) - 1) * hourSeconds)
		launch:DownloadPage(url, function(response, errMsg)
			if errMsg then
				return finish(nil, "Error: " .. tostring(errMsg))
			end
			local json = dkjson.decode(response.body)
			if not json then
				return finish(nil, "Malformed CX API response")
			end
			if json.error then
				return finish(nil, "CX error: " .. tostring(json.error.message))
			end
			local success, result = pcall(M.Process, static, json)
			if not success then
				ConPrintf("CX error: %s", result)
				return finish(nil, "Failed to process CX response")
			end
			finish(result)
		end)
	end)
end

--- League names in the data, busiest (most markets) first
function M.LeagueList(data)
	local list = { }
	for name in pairs(data and data.leagues or { }) do
		t_insert(list, name)
	end
	table.sort(list, function(a, b)
		local ma, mb = data.leagues[a].markets, data.leagues[b].markets
		if ma ~= mb then
			return ma > mb
		end
		return a < b
	end)
	return list
end

--- The first preferred league the data has (nil preferences are skipped), otherwise the busiest league
function M.PickLeague(data, ...)
	for i = 1, select("#", ...) do
		local preferred = select(i, ...)
		if data and preferred and data.leagues[preferred] then
			return preferred
		end
	end
	return M.LeagueList(data)[1]
end

--- Price of an item by its display name, e.g. "Runegraft of Gemcraft"
---@return table? price { divs, chaos, stock, volume }
function M.PriceByName(data, league, name)
	if not (data and league and name and data.leagues[league]) then
		return
	end
	local leagueData = data.leagues[league]
	for id, item in pairs(data.items) do
		if item.name == name then
			local price = leagueData.prices[id]
			if price then
				return { divs = price.divs, chaos = leagueData.chaosPerDiv and price.divs * leagueData.chaosPerDiv, stock = price.stock, volume = price.volume }
			end
			return
		end
	end
end

local function trim(str)
	return (str:gsub("(%.%d-)0+$", "%1"):gsub("%.$", ""))
end

--- Short price text: divine orbs from 1 div up, chaos orbs below that
function M.FormatPrice(price)
	if not price then
		return
	end
	if price.divs >= 1 or not price.chaos then
		return trim(s_format(price.divs >= 10 and "%.0f" or "%.1f", price.divs)) .. " div"
	end
	return trim(s_format(price.chaos >= 10 and "%.0f" or "%.1f", price.chaos)) .. "c"
end

--- Price text with both currencies, e.g. "109c (0.73 div)"
function M.FormatPriceLong(price)
	if not price then
		return
	end
	local divText = trim(s_format(price.divs >= 10 and "%.1f" or "%.2f", price.divs)) .. " div"
	if not price.chaos then
		return divText
	end
	local chaosText = trim(s_format(price.chaos >= 10 and "%.0f" or "%.1f", price.chaos)) .. "c"
	if price.divs >= 1 then
		return divText .. " (" .. chaosText .. ")"
	end
	return chaosText .. " (" .. divText .. ")"
end

return M
