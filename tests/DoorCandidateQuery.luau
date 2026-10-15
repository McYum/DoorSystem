-- Studio Edit or Play Client: real Instance queries, with candidate visits counted
-- in a private copy of the production module. No game inventory is changed.
local source = game.ReplicatedStorage.DoorSystemShared.DoorAccess.Source
local signature = "local function itemMatches(instance: Instance, itemName: string?, category: string?, keyId: string?): boolean"
local at = assert(source:find(signature, 1, true)) + #signature
source = "local candidateVisits = 0\n" .. source:sub(1, at) .. "\n candidateVisits += 1" .. source:sub(at + 1)
local tail = assert(source:find("\nreturn DoorAccess", 1, true))
source = source:sub(1, tail) .. [[
DoorAccess.ResetCandidateVisits = function() candidateVisits = 0 end
DoorAccess.CandidateVisits = function() return candidateVisits end
return DoorAccess
]]
local module = Instance.new("ModuleScript") module.Source = source
local access = require(module)
local fixture = Instance.new("Folder")
local inventory = Instance.new("Folder") inventory.Name = "Inventory" inventory.Parent = fixture
local backpack = Instance.new("Folder") backpack.Name = "Backpack" backpack.Parent = fixture
local character = Instance.new("Model") character.Parent = fixture
local external = Instance.new("Folder") external.Parent = fixture
local assembly = Instance.new("Model") assembly.Parent = fixture
local player = {Parent = fixture, Character = character}
function player:FindFirstChild(name) return fixture:FindFirstChild(name) end
function player:FindFirstChildOfClass() return nil end
function player:GetAttribute(name) return fixture:GetAttribute(name) end
local cases = 0
local function expect(wanted, label)
	cases += 1
	assert(access.HasMatchingItem(player, assembly, nil) == wanted, label)
end
local ok, result = pcall(function()
	for _, root in {inventory, backpack, character} do
		for i = 1, 500 do local part = Instance.new("Part") part.Name = "Geometry" .. i part.Parent = root end
		task.wait()
	end
	assembly:SetAttribute("RequiredKeyId", "A")
	expect(false, "Missing key accepted")
	local nested = Instance.new("Folder") nested.Parent = inventory
	local key = Instance.new("Folder") key.Name = "KeyItem" key.Parent = nested
	key:SetAttribute("Category", " DoorKey ") key:SetAttribute("KeyId", "A")
	expect(true, "Nested key / trimmed category lost")
	key:SetAttribute("KeyId", "B") expect(false, "Wrong key accepted")
	key:SetAttribute("DoorKeyId", "A") expect(true, "DoorKeyId precedence lost")
	key:SetAttribute("DoorKeyId", nil) key:SetAttribute("MasterKey", true)
	assembly:SetAttribute("RequiredItemCategory", "Medicine")
	expect(true, "Master key bypass lost for another category")
	key:SetAttribute("MasterKey", nil) key:SetAttribute("KeyId", "*")
	expect(true, "Wildcard bypass lost")
	key:SetAttribute("KeyId", "A") key.Parent = external
	assembly:SetAttribute("RequiredItemCategory", nil)
	local link = Instance.new("ObjectValue") link.Parent = backpack link.Value = key
	link:SetAttribute("Category", "Medicine")
	expect(true, "ObjectValue with unrelated own category lost its linked key")
	link.Value = nil expect(false, "Cleared link remained eligible")
	link.Value = key key:SetAttribute("Category", nil)
	expect(false, "Key without required category accepted")
	key:SetAttribute("Category", "DoorKey") expect(true, "Late category update not observed")
	link:Destroy() expect(false, "Removed link remained eligible")
	key.Parent = character expect(true, "Equipped character key lost")
	key.Parent = backpack expect(true, "Backpack key lost")
	key.Parent = inventory expect(true, "Inventory key lost")
	key.Parent = external
	inventory:SetAttribute("Category", "DoorKey") inventory:SetAttribute("KeyId", "A")
	expect(true, "Inventory root attributes lost")
	inventory:SetAttribute("Category", nil) inventory:SetAttribute("KeyId", nil)
	character:SetAttribute("Category", "DoorKey") character:SetAttribute("KeyId", "A")
	expect(false, "Character root became eligible unlike the original traversal")
	character:SetAttribute("Category", nil) character:SetAttribute("KeyId", nil)
	assembly:SetAttribute("RequiredKeyId", nil) assembly:SetAttribute("RequiredItemName", "Geometry500")
	expect(true, "Name-only uncategorized fallback lost")
	assembly:SetAttribute("RequiredItemName", "DisplayKey") key.Parent = nested
	key:SetAttribute("Category", nil) key:SetAttribute("DisplayName", "DisplayKey")
	expect(true, "Uncategorized display-name fallback lost")
	assembly:SetAttribute("RequiredItemName", nil) assembly:SetAttribute("RequiredItemCategory", "Medicine")
	key:SetAttribute("Category", "Medicine") expect(true, "Non-key category lost")
	key:SetAttribute("Category", false) expect(false, "Non-string category accepted")
	key:SetAttribute("Category", "Medicine")
	assembly:SetAttribute("RequiredItemCategory", nil) expect(false, "Empty criteria unexpectedly matched")
	assembly:SetAttribute("RequiredKeyId", "A") assembly:SetAttribute("LockType", "Key") assembly:SetAttribute("Locked", true)
	local allowed, reason = access.Check(player, assembly, "Open", "Front")
	assert(not allowed and reason == "MissingItem", "Denied door changed its reason")
	key:SetAttribute("Category", "DoorKey") key:SetAttribute("KeyId", "A")
	assert(access.Check(player, assembly, "Open", "Front"), "Valid key no longer opens a locked door")
	key.Parent = external
	allowed, reason = access.Check(player, assembly, "Unlock", "Front")
	assert(not allowed and reason == "MissingItem", "Dropping key did not immediately revoke unlocking")
	assert(access.Check(player, assembly, "Close", "Front"), "Closing now requires a key")
	fixture:SetAttribute("LockpickInteracting", true)
	allowed, reason = access.Check(player, assembly, "Close", "Front")
	assert(not allowed and reason == "Lockpicking", "Lockpick interaction guard changed")
	fixture:SetAttribute("LockpickInteracting", nil)
	access.ResetCandidateVisits()
	expect(false, "Missing category key unexpectedly matched")
	local visits = access.CandidateVisits()
	assert(visits <= 4, string.format("Category check still visits irrelevant geometry in Lua (%d candidates)", visits))
	return {Passed = cases + 5, MissingKeyCandidateVisits = visits}
end)
fixture:Destroy() module:Destroy()
assert(ok, result)
return result
