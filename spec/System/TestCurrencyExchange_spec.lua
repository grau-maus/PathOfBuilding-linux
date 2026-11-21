describe("CurrencyExchange", function()
	local dkjson = require("dkjson")
	local currencyExchange = require("Classes.CurrencyExchange")

	local DIVINE = "Metadata/Items/Currency/CurrencyModValues"
	local CHAOS = "Metadata/Items/Currency/CurrencyRerollRare"
	local GEMCRAFT = "Metadata/Items/Currency/RunegraftSupportLevels"
	local FORTRESS = "Metadata/Items/Currency/RunegraftAttributeGlobalDefences"
	local TREACHERY = "Metadata/Items/Currency/RunegraftTreacherousAuras"

	-- static trade data: runegrafts live in their own category, not the first one
	local static = {
		result = {
			{ id = "Currency", label = "Currency", entries = {
				{ id = "chaos", text = "Chaos Orb" },
				{ id = "sep", text = "" },
				{ id = "divine", text = "Divine Orb" },
			} },
			{ id = "Runegrafts", label = "Runegrafts", entries = {
				{ id = "runegraft-of-gemcraft", text = "Runegraft of Gemcraft" },
				{ id = "runegraft-of-the-fortress", text = "Runegraft of the Fortress" },
				{ id = "runegraft-of-treachery", text = "Runegraft of Treachery" },
			} },
			-- a category with no exported currency items is left out
			{ id = "Cards", label = "Cards", entries = { { id = "the-doctor", text = "Not A Currency Item" } } },
		}
	}

	local function market(league, a, b, ratioA, ratioB, stockA, stockB, volumeA, volumeB)
		return {
			league = league,
			market_pair = { a, b },
			lowest_ratio = { [a] = ratioA, [b] = ratioB },
			highest_stock = { [a] = stockA or 100, [b] = stockB or 100 },
			volume_traded = { [a] = volumeA or 0, [b] = volumeB or 0 },
		}
	end

	local cx = { markets = {
		market("Covens", CHAOS, DIVINE, 150, 1, 5000, 50),
		market("Covens", CHAOS, GEMCRAFT, 110, 1, 1800, 44, 6700, 52),
		market("Covens", FORTRESS, DIVINE, 1, 10, 95, 500, 112),
		-- less stock than the divine pair, so ignored
		market("Covens", FORTRESS, CHAOS, 1, 900, 8, 20000),
		market("Covens", TREACHERY, CHAOS, 1, 0, 100, 0),
		market("Standard", CHAOS, DIVINE, 100, 1),
	} }

	before_each(function()
		currencyExchange.Reset()
	end)

	describe("Process", function()
		it("prices items from every static category in divine orbs", function()
			local data = currencyExchange.Process(static, cx)
			assert.are.same({ "Currency", "Runegrafts" }, data.categories)
			assert.are.equal("Runegrafts", data.items[GEMCRAFT].category)
			assert.are.equal("runegraft-of-gemcraft", data.items[GEMCRAFT].short)
			local covens = data.leagues.Covens
			assert.are.equal(150, covens.chaosPerDiv)
			assert.are.equal(1, covens.prices[DIVINE].divs)
			assert.is_true(math.abs(covens.prices[GEMCRAFT].divs - 110 / 150) < 1e-9)
			assert.are.equal(44, covens.prices[GEMCRAFT].stock)
			assert.are.equal(52, covens.prices[GEMCRAFT].volume)
			assert.are.equal(10, covens.prices[FORTRESS].divs)
			-- a zero ratio is skipped
			assert.is_nil(covens.prices[TREACHERY])
			assert.are.equal(5, covens.markets)
		end)

		it("prefers the market pair that traded the most", function()
			local data = currencyExchange.Process(static, { markets = {
				market("Covens", CHAOS, DIVINE, 200, 1, 5000, 50),
				-- more stock, but a thin market asking 1 divine
				market("Covens", DIVINE, TREACHERY, 1, 1, 0, 168, 10, 10),
				market("Covens", CHAOS, TREACHERY, 116, 1, 12000, 100, 45000, 293),
			} })
			assert.are.equal(116 / 200, data.leagues.Covens.prices[TREACHERY].divs)
			assert.are.equal(293, data.leagues.Covens.prices[TREACHERY].volume)
		end)

		it("keeps divine-priced items in a league without a chaos rate", function()
			local data = currencyExchange.Process(static, { markets = { market("Solo", FORTRESS, DIVINE, 1, 12) } })
			assert.are.equal(12, data.leagues.Solo.prices[FORTRESS].divs)
			assert.is_nil(data.leagues.Solo.chaosPerDiv)
		end)
	end)

	describe("lookups", function()
		local data
		before_each(function()
			data = currencyExchange.Process(static, cx)
		end)

		it("finds a price by display name", function()
			local price = currencyExchange.PriceByName(data, "Covens", "Runegraft of Gemcraft")
			assert.is_true(math.abs(price.chaos - 110) < 1e-9)
			assert.is_nil(currencyExchange.PriceByName(data, "Covens", "Runegraft of Treachery"))
			assert.is_nil(currencyExchange.PriceByName(data, "Nowhere", "Runegraft of Gemcraft"))
		end)

		it("prefers the given league, else the busiest one", function()
			assert.are.same({ "Covens", "Standard" }, currencyExchange.LeagueList(data))
			assert.are.equal("Standard", currencyExchange.PickLeague(data, "Standard"))
			assert.are.equal("Covens", currencyExchange.PickLeague(data, "Unknown League"))
			assert.are.equal("Covens", currencyExchange.PickLeague(data, nil))
			-- the first preference the data has wins; missing ones are skipped
			assert.are.equal("Standard", currencyExchange.PickLeague(data, nil, "Unknown League", "Standard"))
			assert.are.equal("Covens", currencyExchange.PickLeague(data, "Covens", "Standard"))
		end)

		it("formats prices", function()
			assert.are.equal("110c", currencyExchange.FormatPrice({ divs = 0.73, chaos = 110 }))
			assert.are.equal("2.5c", currencyExchange.FormatPrice({ divs = 0.02, chaos = 2.5 }))
			assert.are.equal("1.5 div", currencyExchange.FormatPrice({ divs = 1.5, chaos = 225 }))
			assert.are.equal("10 div", currencyExchange.FormatPrice({ divs = 10, chaos = 1500 }))
			assert.are.equal("110c (0.73 div)", currencyExchange.FormatPriceLong({ divs = 0.7333, chaos = 110 }))
			assert.are.equal("10 div (1500c)", currencyExchange.FormatPriceLong({ divs = 10, chaos = 1500 }))
		end)
	end)

	describe("Fetch", function()
		local origDownloadPage, requests, pendingCX

		before_each(function()
			origDownloadPage = launch.DownloadPage
			requests, pendingCX = { }, nil
			launch.DownloadPage = function(_, url, callback)
				table.insert(requests, url)
				if url == "https://www.pathofexile.com/api/trade/data/static" then
					callback({ body = dkjson.encode(static) })
				else
					pendingCX = callback
				end
			end
		end)

		after_each(function()
			launch.DownloadPage = origDownloadPage
		end)

		it("shares one download between callers and caches it", function()
			local results = { }
			currencyExchange.Fetch("pc", function(data) table.insert(results, data) end)
			currencyExchange.Fetch("pc", function(data) table.insert(results, data) end)
			assert.are.equal(2, #requests)
			pendingCX({ body = dkjson.encode(cx) })
			assert.are.equal(2, #results)
			assert.are.equal(results[1], results[2])
			assert.is_truthy(requests[2]:match("^https://web%.poecdn%.com/api/currency%-exchange/%d+$"))

			currencyExchange.Fetch("pc", function(data) table.insert(results, data) end)
			assert.are.equal(2, #requests)
			assert.are.equal(results[1], results[3])
			assert.are.equal(results[1], currencyExchange.Get("pc"))
		end)

		it("reports errors and waits before retrying", function()
			local gotErr
			currencyExchange.Fetch("pc", function(data, errMsg) gotErr = errMsg end)
			pendingCX({ body = dkjson.encode({ error = { message = "kaput" } }) })
			assert.are.equal("CX error: kaput", gotErr)
			currencyExchange.Fetch("pc", function(data, errMsg) gotErr = errMsg end)
			assert.are.equal(2, #requests)
			assert.is_truthy(gotErr)
		end)
	end)
end)
