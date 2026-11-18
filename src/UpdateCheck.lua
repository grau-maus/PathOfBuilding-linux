#@
-- Path of Building
--
-- Module: Update Check
-- Checks for updates
--
local connectionProtocol, proxyURL, noSSL = ...

local xml = require("xml")
local sha1 = require("sha1")
local curl = require("lcurl.safe")
local lzip = require("lzip")

-- Non-Windows hosts (e.g. the native Linux build) run their own engine binaries, so the
-- Windows runtime files (DLLs/EXEs) listed in the manifest must never be downloaded or deleted.
local windowsHost = package.config:sub(1, 1) == "\\"
local function isWindowsBinary(name, attrib)
	local lowerName = name:lower()
	return attrib.runtime == "win32" or lowerName:match("%.dll$") ~= nil or lowerName:match("%.exe$") ~= nil
end
local function skipFileOnHost(name, attrib)
	return not windowsHost and attrib.part == "runtime" and isWindowsBinary(name, attrib)
end

local globalRetryLimit = 10
local function downloadFileText(source, file)
	for i = 1, 5 do
		if i > 1 then
			ConPrintf("Retrying... (%d of 5)", i)
		end
		local text = ""
		local easy = curl.easy()
		local escapedUrl = source..easy:escape(file)
		easy:setopt_url(escapedUrl)
		easy:setopt(curl.OPT_ACCEPT_ENCODING, "")
		-- GitHub's API rejects requests without a User-Agent; release downloads redirect to a file host
		easy:setopt(curl.OPT_USERAGENT, "Path of Building")
		easy:setopt(curl.OPT_FOLLOWLOCATION, 1)
		if connectionProtocol then
			easy:setopt(curl.OPT_IPRESOLVE, connectionProtocol)
		end
		if proxyURL then
			easy:setopt(curl.OPT_PROXY, proxyURL)
		end
		if noSSL then
			easy:setopt(curl.OPT_SSL_VERIFYPEER, 0)
			easy:setopt(curl.OPT_SSL_VERIFYHOST, 0)
			ConPrintf("SSL verification disabled")
		end
		easy:setopt_writefunction(function(data)
			text = text..data 
			return true
		end)
		local _, error = easy:perform()
		easy:close()
		if not error then
			return text
		end
		ConPrintf("Download failed (%s)", error:msg())
		if globalRetryLimit == 0 or i == 5 then
			return nil, error:msg()
		end
		globalRetryLimit = globalRetryLimit - 1
	end
end
local function downloadFile(source, file, outName, progressLabel)
	for i = 1, 5 do
		if i > 1 then
			ConPrintf("Retrying... (%d of 5)", i)
		end
		local easy = curl.easy()
		local escapedUrl = source..easy:escape(file)
		easy:setopt_url(escapedUrl)
		easy:setopt(curl.OPT_ACCEPT_ENCODING, "")
		easy:setopt(curl.OPT_USERAGENT, "Path of Building")
		easy:setopt(curl.OPT_FOLLOWLOCATION, 1)
		if connectionProtocol then
			easy:setopt(curl.OPT_IPRESOLVE, connectionProtocol)
		end
		if proxyURL then
			easy:setopt(curl.OPT_PROXY, proxyURL)
		end
		if noSSL then
			easy:setopt(curl.OPT_SSL_VERIFYPEER, 0)
			easy:setopt(curl.OPT_SSL_VERIFYHOST, 0)
			ConPrintf("SSL verification disabled")
		end
		if progressLabel and UpdateProgress then
			-- Report download progress (used for the single large AppImage download)
			easy:setopt(curl.OPT_NOPROGRESS, false)
			local lastPercent
			easy:setopt_progressfunction(function(total, now)
				local percent = total > 0 and math.floor(now * 100 / total) or 0
				if percent ~= lastPercent then
					lastPercent = percent
					UpdateProgress("%s %d%%", progressLabel, percent)
				end
				return true
			end)
		end
		local file = io.open(outName, "wb+")
		if not file then
			return nil, "can't write "..outName
		end
		easy:setopt_writefunction(file)
		local _, error = easy:perform()
		easy:close()
		file:close()
		if not error then
			return true
		end
		ConPrintf("Download failed (%s)", error:msg())
		if globalRetryLimit == 0 or i == 5 then
			return nil, error:msg()
		end
		globalRetryLimit = globalRetryLimit - 1
	end
	return true
end

ConPrintf("Checking for update...")

-- Use built-in helpers to obtain absolute paths without spawning a shell.
local scriptPath, scriptFallback = GetScriptPath()
scriptPath = scriptPath or scriptFallback or "."
local runtimePath, runtimeFallback = GetRuntimePath()
runtimePath = runtimePath or runtimeFallback or scriptPath

-- Load and process local manifest
local localVer
local localPlatform, localBranch, localRelease
local localFiles = { }
local localManXML = xml.LoadXMLFile(scriptPath.."/manifest.xml")
local localSource
local runtimeExecutable
if localManXML and localManXML[1].elem == "PoBVersion" then
	for _, node in ipairs(localManXML[1]) do
		if type(node) == "table" then
			if node.elem == "Version" then
				localVer = node.attrib.number
				localPlatform = node.attrib.platform
				localBranch = node.attrib.branch
				localRelease = node.attrib.release
			elseif node.elem == "Source" then
				if node.attrib.part == "default" then
					localSource = node.attrib.url
				end
			elseif node.elem == "File" and not skipFileOnHost(node.attrib.name, node.attrib) then
				local fullPath
				node.attrib.name = node.attrib.name:gsub("{space}", " ")
				if node.attrib.part == "runtime" then
					fullPath = runtimePath .. "/" .. node.attrib.name
				else
					fullPath = scriptPath .. "/" .. node.attrib.name
				end
				localFiles[node.attrib.name] = { sha1 = node.attrib.sha1, part = node.attrib.part, platform = node.attrib.platform, runtime = node.attrib.runtime, fullPath = fullPath }
				if node.attrib.part == "runtime" and node.attrib.name:match("Path of Building") then
					runtimeExecutable = fullPath
				end
			end
		end
	end
end
if not localVer or not localSource or not localBranch or not next(localFiles) then
	ConPrintf("Update check failed: invalid local manifest")
	return nil, "Invalid local manifest"
end
localSource = localSource:gsub("{branch}", localBranch)

-- AppImage builds are read-only, so they update as a whole: compare this image's release with the latest GitHub
-- release and download the new image next to the running one. Launch:ApplyUpdate("appimage") swaps it in.
local appImagePath = not windowsHost and os.getenv("APPIMAGE")
if appImagePath and appImagePath ~= "" then
	local dkjson = require("dkjson")
	local releaseApi = os.getenv("POB_RELEASE_API") or "https://api.github.com/repos/grau-maus/PathOfBuilding-linux/releases/latest"

	local function releaseNumbers(tag)
		-- "v2.68.1-linux.3" -> { 2, 68, 1, 3 }
		local numbers = { }
		for n in tostring(tag):gmatch("%d+") do
			table.insert(numbers, tonumber(n))
		end
		return numbers
	end
	local function isNewerRelease(remoteTag, currentTag)
		local remote, current = releaseNumbers(remoteTag), releaseNumbers(currentTag)
		for i = 1, math.max(#remote, #current) do
			if (remote[i] or 0) ~= (current[i] or 0) then
				return (remote[i] or 0) > (current[i] or 0)
			end
		end
		return false
	end
	local function shellQuote(s)
		return "'"..s:gsub("'", "'\\''").."'"
	end
	local function sha256File(path)
		local pipe = io.popen("sha256sum -- "..shellQuote(path).." 2>/dev/null")
		local out = pipe and pipe:read("*a") or ""
		if pipe then pipe:close() end
		return out:match("^(%x+)")
	end

	if not localRelease then
		ConPrintf("Update check failed: AppImage manifest has no release tag")
		return nil, "This AppImage doesn't record its release, so it can't update itself.\nDownload the latest AppImage from the releases page."
	end
	local releaseText, errMsg = downloadFileText(releaseApi, "")
	local release = releaseText and dkjson.decode(releaseText)
	if not release or not release.tag_name then
		ConPrintf("Update check failed: couldn't read the latest release")
		return nil, "Couldn't check for a new AppImage release.\nReason: "..(errMsg or (release and release.message) or "invalid response").."\nCheck your internet connectivity.\nIf you are using a proxy, specify it in Options."
	end
	if not isNewerRelease(release.tag_name, localRelease) then
		ConPrintf("No update available (running %s, latest release %s).", localRelease, release.tag_name)
		return "none"
	end

	local asset, checksumAsset
	for _, candidate in ipairs(release.assets or { }) do
		if candidate.name:match("x86_64%.AppImage$") then
			asset = candidate
		elseif candidate.name:match("x86_64%.AppImage%.sha256$") then
			checksumAsset = candidate
		end
	end
	if not asset then
		ConPrintf("Update check failed: release %s has no AppImage", release.tag_name)
		return nil, "Release "..release.tag_name.." has no AppImage to download."
	end
	local expectedHash = asset.digest and asset.digest:match("^sha256:(%x+)$")
	if not expectedHash and checksumAsset then
		local checksumText = downloadFileText(checksumAsset.browser_download_url, "")
		expectedHash = checksumText and checksumText:match("^(%x+)")
	end
	if not expectedHash then
		return nil, "Release "..release.tag_name.." has no checksum, so its AppImage can't be verified."
	end

	-- Download next to the running image, so the swap in Launch:ApplyUpdate is an atomic rename on one filesystem
	local updatePath = appImagePath..".update"
	if sha256File(updatePath) == expectedHash:lower() then
		ConPrintf("Using AppImage from previous update attempt '%s'", updatePath)
	else
		ConPrintf("Downloading %s...", asset.name)
		local ok, downloadErr = downloadFile(asset.browser_download_url, "", updatePath, "Downloading")
		if not ok then
			os.remove(updatePath)
			local dir = appImagePath:match("^(.*)/[^/]*$") or "."
			return nil, "Couldn't download the new AppImage.\nReason: "..tostring(downloadErr).."\nThe AppImage's folder ("..dir..") must be writable for updates."
		end
		if sha256File(updatePath) ~= expectedHash:lower() then
			os.remove(updatePath)
			ConPrintf("Hash mismatch on '%s'", updatePath)
			return nil, "The downloaded AppImage failed verification.\nCheck your internet connectivity, or try again later."
		end
	end
	os.execute("chmod 755 "..shellQuote(updatePath))
	ConPrintf("AppImage %s is ready.", release.tag_name)
	return "appimage"
end

-- Download and process remote manifest
local remoteVer
local remoteFiles = { }
local remoteSources = { }
local remoteManText, errMsg = downloadFileText(localSource, "manifest.xml")
if not remoteManText then
	ConPrintf("Update check failed: couldn't download version manifest")
	return nil, "Couldn't download version manifest.\nReason: "..errMsg.."\nCheck your internet connectivity.\nIf you are using a proxy, specify it in Options."
end
local remoteManXML = xml.ParseXML(remoteManText)
if remoteManXML and remoteManXML[1].elem == "PoBVersion" then
	for _, node in ipairs(remoteManXML[1]) do
		if type(node) == "table" then
			if node.elem == "Version" then
				remoteVer = node.attrib.number
			elseif node.elem == "Source" then
				if not remoteSources[node.attrib.part] then
					remoteSources[node.attrib.part] = { }
				end
				remoteSources[node.attrib.part][node.attrib.platform or "any"] = node.attrib.url
			elseif node.elem == "File" then
				if (not node.attrib.platform or node.attrib.platform == localPlatform) and not skipFileOnHost(node.attrib.name, node.attrib) then
					local fullPath
					if node.attrib.part == "runtime" then
						fullPath = runtimePath .. "/" .. node.attrib.name
					else
						fullPath = scriptPath .. "/" .. node.attrib.name
					end
					remoteFiles[node.attrib.name] = { sha1 = node.attrib.sha1, part = node.attrib.part, platform = node.attrib.platform, runtime = node.attrib.runtime, fullPath = fullPath }
				end
			end
		end
	end
end
if not remoteVer or not next(remoteSources) or not next(remoteFiles) then
	ConPrintf("Update check failed: invalid remote manifest")
	return nil, "Invalid remote manifest"
end

-- Build lists of files to be updated or deleted
local updateFiles = { }
for name, data in pairs(remoteFiles) do
	data.name = name
	local sanitizedName = name:gsub("{space}", " ")
	if (not localFiles[name] or localFiles[name].sha1 ~= data.sha1) and (not localFiles[sanitizedName] or localFiles[sanitizedName].sha1 ~= data.sha1) then
		table.insert(updateFiles, data)
	elseif localFiles[name] then
		local file = io.open(localFiles[name].fullPath, "rb")
		if not file then
			ConPrintf("Warning: '%s' doesn't exist, it will be re-downloaded", data.name)
			table.insert(updateFiles, data)
		else
			local content = file:read("*a")
			file:close()
			if data.sha1 ~= sha1(content) and data.sha1 ~= sha1(content:gsub("\n", "\r\n")) then
				ConPrintf("Warning: Integrity check on '%s' failed, it will be replaced", data.name)
				table.insert(updateFiles, data)
			end
		end
	end
end
local deleteFiles = { }
for name, data in pairs(localFiles) do
	data.name = name
	local unSanitizedName = name:gsub(" ", "{space}")
	if not remoteFiles[name] and not remoteFiles[unSanitizedName] then
		table.insert(deleteFiles, data)
	end
end
	
if #updateFiles == 0 and #deleteFiles == 0 then
	ConPrintf("No update available.")
	return "none"
end

MakeDir("Update")
ConPrintf("Downloading update...")

-- Download changelog
downloadFile(localSource, "changelog.txt", scriptPath.."/changelog.txt")

-- Download files that need updating
local failedFile = false
local zipFiles = { }
for index, data in ipairs(updateFiles) do
	if UpdateProgress then
		UpdateProgress("Downloading %d/%d", index, #updateFiles)
	end
	local partSources = remoteSources[data.part]
	-- The runtime source is only published for win32; its platform-neutral files (Lua modules, fonts)
	-- live at the same URL, so non-Windows hosts can fall back to it.
	local source = partSources[localPlatform] or partSources["any"] or (not windowsHost and partSources["win32"])
	source = source:gsub("{branch}", localBranch)
	local fileName = scriptPath.."/Update/"..data.name:gsub("[\\/]","{slash}")
	data.updateFileName = fileName
	local zipName = source:match("/([^/]+%.zip)$")
	if zipName then
		if not zipFiles[zipName] then
			ConPrintf("Downloading %s...", zipName)
			local zipFileName = scriptPath.."/Update/"..zipName
			downloadFile(source, "", zipFileName)
			zipFiles[zipName] = lzip.open(zipFileName)
		end
		local zip = zipFiles[zipName]
		if zip then
			local zippedFile = zip:OpenFile(data.name)
			if zippedFile then
				local file = io.open(fileName, "wb+")
				file:write(zippedFile:Read("*a"))
				file:close()
				zippedFile:Close()
			else
				ConPrintf("Couldn't extract '%s' from '%s' (extract failed)", data.name, zipName)
			end
		else
			ConPrintf("Couldn't extract '%s' from '%s' (zip open failed)", data.name, zipName)
		end
	else
		local skipDownload
		local file = io.open(fileName, "rb")
		if file then
			local content = file:read("*all")
			if data.sha1 == sha1(content) or data.sha1 == sha1(content:gsub("\n", "\r\n")) then
				ConPrintf("Using file from previous update attempt '%s'", fileName)
				skipDownload = true
			end
			file:close()
		end
		if not skipDownload then
			ConPrintf("Downloading %s... (%d of %d)", data.name, index, #updateFiles)
			downloadFile(source, data.name, fileName)
		end
	end
	local file = io.open(fileName, "rb")
	if not file then
		failedFile = true
	else
		local content = file:read("*all")
		if data.sha1 ~= sha1(content) and data.sha1 ~= sha1(content:gsub("\n", "\r\n")) then
			ConPrintf("Hash mismatch on '%s'", fileName)
			failedFile = true
		end
		file:close()
	end
end
for name, zip in pairs(zipFiles) do
	zip:Close()
	os.remove(scriptPath.."/Update/"..name)
end
if failedFile then
	ConPrintf("Update failed: one or more files couldn't be downloaded")
	return nil, "One or more files couldn't be downloaded.\nCheck your internet connectivity,\nor try again later."
end

-- Create new manifest
localManXML = { elem = "PoBVersion" }
table.insert(localManXML, { elem = "Version", attrib = { number = remoteVer, platform = localPlatform, branch = localBranch } })
for part, platforms in pairs(remoteSources) do
	for platform, url in pairs(platforms) do
		table.insert(localManXML, { elem = "Source", attrib = { part = part, platform = platform ~= "any" and platform, url = url } })
	end
end
for name, data in pairs(remoteFiles) do
	table.insert(localManXML, { elem = "File", attrib = { name = data.name, sha1 = data.sha1, part = data.part, platform = data.platform, runtime = data.runtime } })
end 
xml.SaveXMLFile(localManXML, scriptPath.."/Update/manifest.xml")

-- Build list of operations to apply the update
local updateMode = "normal"
local ops = { }
local opsRuntime = { }
for _, data in pairs(updateFiles) do
	-- Ensure that the destination path of this file exists
	local dirStr = data.fullPath:sub(1,1) == "/" and "/" or ""
	for dir in data.fullPath:gmatch("([^/]+/)") do
		dirStr = dirStr .. dir
		MakeDir(dirStr)
	end
	if data.part == "runtime" and not windowsHost then
		-- Only platform-neutral runtime files reach this point on non-Windows hosts (Windows binaries are
		-- filtered out above), and nothing holds them locked, so they can be replaced in the normal environment
		table.insert(ops, 'move "'..data.updateFileName..'" "'..data.fullPath..'"')
	elseif data.part == "runtime" then
		-- Core runtime file, will need to update from the basic environment
		-- These files will be updated on the second pass of the update script, with the first pass being run within the normal environment
		updateMode = "basic"
		table.insert(opsRuntime, 'move "'..data.updateFileName..'" "'..data.fullPath..'"')
	else
		table.insert(ops, 'move "'..data.updateFileName..'" "'..data.fullPath..'"')
	end
end
for _, data in pairs(deleteFiles) do
	table.insert(ops, 'delete "'..data.fullPath..'"')
end
table.insert(ops, 'move "'..scriptPath..'/Update/manifest.xml" "'..scriptPath..'/manifest.xml"')
if updateMode == "basic" then
	-- Update script will need to relaunch the normal environment after updating
	table.insert(opsRuntime, 'start "'..runtimeExecutable..'"')
	local opRuntimeFile = io.open(scriptPath.."/Update/opFileRuntime.txt", "w+")
	opRuntimeFile:write(table.concat(opsRuntime, "\n"))
	opRuntimeFile:close()
end

-- Write operations file
local opFile = io.open(scriptPath.."/Update/opFile.txt", "w+")
opFile:write(table.concat(ops, "\n"))
opFile:close()

ConPrintf("Update is ready.")
return updateMode
