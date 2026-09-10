--!strict
-- Door System bootstrapper
-- Networking is created FIRST with zero dependencies so the client can never
-- infinite-yield on DoorSystemRemotes merely because another module is missing/broken.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

---------------------------------------------------------------------
-- 1) NETWORKING FIRST. Do not move this below any WaitForChild/require.
---------------------------------------------------------------------

local REMOTES_NAME = "DoorSystemRemotes"

local folderInstance = ReplicatedStorage:FindFirstChild(REMOTES_NAME)
if folderInstance and not folderInstance:IsA("Folder") then
	warn(("[DoorSystem] Replacing invalid ReplicatedStorage.%s (%s) with Folder")
		:format(REMOTES_NAME, folderInstance.ClassName))
	folderInstance:Destroy()
	folderInstance = nil
end

local remotesFolder: Folder
if folderInstance and folderInstance:IsA("Folder") then
	remotesFolder = folderInstance
else
	local created = Instance.new("Folder")
	created.Name = REMOTES_NAME
	created.Parent = ReplicatedStorage
	remotesFolder = created
end

local function ensureRemote(className: string, name: string): Instance
	local existing = remotesFolder:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	if existing then
		warn(("[DoorSystem] Replacing %s.%s because it is %s, expected %s")
			:format(REMOTES_NAME, name, existing.ClassName, className))
		existing:Destroy()
	end
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = remotesFolder
	return remote
end

ensureRemote("RemoteEvent", "State")
ensureRemote("RemoteEvent", "Action")
ensureRemote("RemoteEvent", "Push")
ensureRemote("RemoteEvent", "Interact")
ensureRemote("RemoteFunction", "Snapshot")

print("[DoorSystem] Networking ready")

---------------------------------------------------------------------
-- 2) Validate modules only AFTER networking exists.
---------------------------------------------------------------------

local systemFolder = script.Parent

local configModule = systemFolder:WaitForChild("Config", 10)
if not configModule then
	warn(("[DoorSystem] STARTUP FAILED: %s.Config was not found after 10 seconds. Networking is still available.")
		:format(systemFolder:GetFullName()))
	return
end
if not configModule:IsA("ModuleScript") then
	warn(("[DoorSystem] STARTUP FAILED: %s must be a ModuleScript, but it is %s")
		:format(configModule:GetFullName(), configModule.ClassName))
	return
end

local serviceModule = systemFolder:WaitForChild("DoorService", 10)
if not serviceModule then
	warn(("[DoorSystem] STARTUP FAILED: %s.DoorService was not found after 10 seconds. Networking is still available.")
		:format(systemFolder:GetFullName()))
	return
end
if not serviceModule:IsA("ModuleScript") then
	warn(("[DoorSystem] STARTUP FAILED: %s must be a ModuleScript, but it is %s")
		:format(serviceModule:GetFullName(), serviceModule.ClassName))
	return
end

local okRequire, DoorServiceOrError = xpcall(function()
	return require(serviceModule)
end, function(err)
	return debug.traceback(tostring(err), 2)
end)

if not okRequire then
	warn("[DoorSystem] DoorService FAILED TO LOAD. Actual error:\n" .. tostring(DoorServiceOrError))
	return
end

local DoorService = DoorServiceOrError
if type(DoorService) ~= "table" or type(DoorService.Start) ~= "function" then
	warn("[DoorSystem] DoorService loaded, but did not return a table with Start().")
	return
end

local okStart, startError = xpcall(function()
	DoorService.Start()
end, function(err)
	return debug.traceback(tostring(err), 2)
end)

if not okStart then
	warn("[DoorSystem] DoorService.Start() FAILED. Actual error:\n" .. tostring(startError))
	return
end

local version = tostring(DoorService.VERSION or "7.7.0")
local versionName = tostring(DoorService.VERSION_NAME or ("DoorSystem v" .. version))
-- Clean version Attributes left by older packages; versioning is internal only.
systemFolder:SetAttribute("Version", nil)
systemFolder:SetAttribute("VersionName", nil)
remotesFolder:SetAttribute("Version", nil)
print(("[DoorSystem] %s started successfully"):format(versionName))
