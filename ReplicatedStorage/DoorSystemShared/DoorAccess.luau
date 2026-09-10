--!strict
-- Shared inventory/side requirement evaluator for DoorSystem prompts and server actions.

local RunService = game:GetService("RunService")

local DoorAccess = {}

local function setting(assembly: Model, leafRig: Model?, names: {string}, fallback: any): any
	for _, name in names do
		if leafRig then
			local leafValue = leafRig:GetAttribute(name)
			if leafValue ~= nil then
				return leafValue
			end
		end
		local assemblyValue = assembly:GetAttribute(name)
		if assemblyValue ~= nil then
			return assemblyValue
		end
	end
	return fallback
end

local function nonEmptyString(value: any): string?
	if typeof(value) ~= "string" then
		return nil
	end
	local trimmed = string.match(value, "^%s*(.-)%s*$")
	return if trimmed ~= "" then trimmed else nil
end

local function valueMatches(instance: Instance, itemName: string?, category: string?, keyId: string?): boolean
	local instanceCategory = nonEmptyString(instance:GetAttribute("Category"))
	local instanceKeyId = nonEmptyString(instance:GetAttribute("DoorKeyId"))
		or nonEmptyString(instance:GetAttribute("KeyId"))
	local displayName = nonEmptyString(instance:GetAttribute("DisplayName"))

	if instanceCategory == "DoorKey"
		and (instance:GetAttribute("MasterKey") == true or instanceKeyId == "*")
	then
		return true
	end
	if category and instanceCategory ~= category then
		return false
	end
	if keyId and instanceKeyId ~= keyId then
		return false
	end
	if itemName and instance.Name ~= itemName and displayName ~= itemName then
		return false
	end
	return itemName ~= nil or category ~= nil or keyId ~= nil
end

local function itemMatches(instance: Instance, itemName: string?, category: string?, keyId: string?): boolean
	if valueMatches(instance, itemName, category, keyId) then
		return true
	end
	if instance:IsA("ObjectValue") then
		local linked = instance.Value
		if linked and valueMatches(linked, itemName, category, keyId) then
			return true
		end
	end
	return false
end

local function playerHasItem(player: Player, itemName: string?, category: string?, keyId: string?): boolean
	for _, rootName in {"Inventory", "Backpack"} do
		local root = player:FindFirstChild(rootName)
		if root then
			if itemMatches(root, itemName, category, keyId) then
				return true
			end
			for _, descendant in root:GetDescendants() do
				if itemMatches(descendant, itemName, category, keyId) then
					return true
				end
			end
		end
	end

	local character = player.Character
	if character then
		for _, descendant in character:GetDescendants() do
			if itemMatches(descendant, itemName, category, keyId) then
				return true
			end
		end
	end
	return false
end

local function findChecker(assembly: Model, leafRig: Model?): ModuleScript?
	local function under(root: Instance?): ModuleScript?
		if not root then
			return nil
		end
		local direct = root:FindFirstChild("DoorRequirementChecker") or root:FindFirstChild("Checker")
		if direct and direct:IsA("ModuleScript") then
			return direct
		end
		local requirements = root:FindFirstChild("Requirements")
		local nested = requirements and requirements:FindFirstChild("Checker")
		return if nested and nested:IsA("ModuleScript") then nested else nil
	end
	return under(leafRig) or under(assembly)
end

local function runChecker(checkerModule: ModuleScript, player: Player, assembly: Model, action: string): (boolean, string?)
	local okRequire, checker = pcall(require, checkerModule)
	if not okRequire or typeof(checker) ~= "table" then
		return false, "RequirementCheckerFailed"
	end
	local functionName = if RunService:IsServer() then "checkserver" else "check"
	local callback = checker[functionName] or checker.Check
	if typeof(callback) ~= "function" then
		return false, "RequirementCheckerMissing"
	end

	local ok, result = pcall(callback, player, assembly, action)
	-- The old server Checker is a dot function whose second parameter is the actual
	-- player. Retry that signature when its first, conventional invocation errors.
	if not ok and callback == checker.checkserver then
		ok, result = pcall(callback, player, player, assembly, action)
	end
	-- Also accept colon-style requirement tables.
	if not ok then
		ok, result = pcall(callback, checker, player, assembly, action)
	end
	if not ok then
		return false, "RequirementCheckerFailed"
	end
	return result == true, if result == true then nil else "CustomRequirement"
end

function DoorAccess.HasMatchingItem(player: Player, assembly: Model, leafRig: Model?): boolean
	local keyId = nonEmptyString(setting(assembly, leafRig, {"RequiredKeyId", "DoorKeyId", "KeyId"}, nil))
	local itemName = nonEmptyString(setting(assembly, leafRig, {"RequiredItemName", "RequiredItem"}, nil))
	local legacyCondition = setting(assembly, leafRig, {"Condition"}, nil)
	if not itemName and typeof(legacyCondition) == "string" then
		itemName = nonEmptyString(legacyCondition)
	end
	local category = nonEmptyString(setting(assembly, leafRig, {"RequiredItemCategory"}, nil))
	if not category and keyId then
		category = "DoorKey"
	end
	return playerHasItem(player, itemName, category, keyId)
end

function DoorAccess.Check(
	player: Player,
	assembly: Model,
	action: string,
	playerSide: string?,
	leafRig: Model?
): (boolean, string?)
	if not player or not player.Parent or not assembly or not assembly.Parent then
		return false, "PlayerUnavailable"
	end

	local normalizedAction = string.lower(action)
	if normalizedAction == "close" then
		return true, nil
	end
	local locked = assembly:GetAttribute("Locked") == true
	local isLockAction = normalizedAction == "lock"
		or normalizedAction == "unlock"
		or normalizedAction == "togglelock"
	local openRequiresItem = setting(assembly, leafRig, {"OpenRequiresItem"}, false) == true
	local requirementRelevant = isLockAction or locked or openRequiresItem
	if not requirementRelevant then
		return true, nil
	end

	local lockType = string.lower(tostring(setting(assembly, leafRig, {"LockType", "LockMode"}, "None")))
	local requiredSide = nonEmptyString(setting(assembly, leafRig, {"LockSide", "RequiredSide"}, nil))
	if lockType == "side" or lockType == "sided" or lockType == "inside" or lockType == "outside" or requiredSide then
		requiredSide = requiredSide or (if lockType == "outside" then "Front" else "Back")
		if string.lower(tostring(playerSide or "")) ~= string.lower(requiredSide) then
			return false, "WrongSide"
		end
	end

	local keyId = nonEmptyString(setting(assembly, leafRig, {"RequiredKeyId", "DoorKeyId", "KeyId"}, nil))
	local itemName = nonEmptyString(setting(assembly, leafRig, {"RequiredItemName", "RequiredItem"}, nil))
	local legacyCondition = setting(assembly, leafRig, {"Condition"}, nil)
	if not itemName and typeof(legacyCondition) == "string" then
		itemName = nonEmptyString(legacyCondition)
	end
	local requiresInventoryItem = openRequiresItem or lockType == "key" or keyId ~= nil or itemName ~= nil
	if requiresInventoryItem and not DoorAccess.HasMatchingItem(player, assembly, leafRig) then
		return false, "MissingItem"
	end

	local checkerModule = findChecker(assembly, leafRig)
	if checkerModule and (legacyCondition == true or setting(assembly, leafRig, {"UseRequirementChecker"}, true) == true) then
		return runChecker(checkerModule, player, assembly, action)
	end
	return true, nil
end

-- Names retained for old prompt Checker-compatible integrations.
function DoorAccess.check(player: Player, assembly: Model, action: string, playerSide: string?, leafRig: Model?)
	return DoorAccess.Check(player, assembly, action, playerSide, leafRig)
end

function DoorAccess.checkserver(player: Player, assembly: Model, action: string, playerSide: string?, leafRig: Model?)
	return DoorAccess.Check(player, assembly, action, playerSide, leafRig)
end

return DoorAccess
