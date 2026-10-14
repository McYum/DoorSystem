-- Studio Edit or Play Client. Use real item instances and observe native
-- attribute reads in the production helpers without initializing door remotes.
local original = game.ReplicatedStorage.DoorSystemShared.DoorAccess
local source = original.Source
local first = assert(source:find("local function nonEmptyString(", 1, true))
local last = assert(source:find("local function playerHasItem(", first, true))
local helpers = source:sub(first, last - 1)
helpers = helpers:gsub("instance:GetAttribute%((.-)%)", "readAttribute(instance, %1)")
local module = Instance.new("ModuleScript")
module.Source = [[
local reads = 0
local function readAttribute(instance, name)
 reads += 1
 return instance:GetAttribute(name)
end
]] .. helpers .. [[
return {ValueMatches = valueMatches, ItemMatches = itemMatches,
 ResetReads = function() reads = 0 end, Reads = function() return reads end}
]]
local helpersApi = require(module)
local fixture = Instance.new("Folder")
local key = Instance.new("Folder")
key.Name, key.Parent = "KeyItem", fixture
key:SetAttribute("Category", "DoorKey")
key:SetAttribute("KeyId", "A")
key:SetAttribute("DisplayName", "DisplayKey")
local unrelated = Instance.new("Part")
unrelated.Parent = fixture
local link = Instance.new("ObjectValue")
link.Value, link.Parent = key, fixture
local ok, result = pcall(function()
	assert(helpersApi.ValueMatches(key, "KeyItem", "DoorKey", "A"), "Exact key no longer matches")
	assert(helpersApi.ValueMatches(key, "DisplayKey", "DoorKey", "A"), "Display name no longer matches")
	assert(helpersApi.ValueMatches(key, "KeyItem", nil, nil), "Name-only matching changed")
	assert(helpersApi.ValueMatches(key, nil, nil, "A"), "Key-only matching changed")
	assert(not helpersApi.ValueMatches(key, nil, "DoorKey", "B"), "Wrong key accepted")
	assert(not helpersApi.ValueMatches(key, nil, "Medicine", nil), "Wrong category accepted")
	assert(helpersApi.ItemMatches(link, "KeyItem", "DoorKey", "A"), "Linked item no longer matches")
	key:SetAttribute("DoorKeyId", "B")
	assert(helpersApi.ValueMatches(key, nil, "DoorKey", "B"), "DoorKeyId precedence changed")
	key:SetAttribute("MasterKey", true)
	assert(helpersApi.ValueMatches(key, "OtherName", "Medicine", "OtherKey"), "Master key bypass changed")
	key:SetAttribute("MasterKey", nil)
	key:SetAttribute("DoorKeyId", "*")
	assert(helpersApi.ValueMatches(key, "OtherName", "Medicine", "OtherKey"), "Wildcard key bypass changed")
	unrelated:SetAttribute("Category", "Medicine")
	assert(helpersApi.ValueMatches(unrelated, nil, "Medicine", nil), "Non-key category matching changed")
	assert(not helpersApi.ValueMatches(unrelated, nil, nil, nil), "Empty criteria unexpectedly match")
	unrelated:SetAttribute("Category", nil)
	helpersApi.ResetReads()
	assert(not helpersApi.ValueMatches(unrelated, nil, "DoorKey", "A"), "Unrelated geometry accepted as a key")
	assert(helpersApi.Reads() == 1, string.format(
		"Wrong-category candidate reads unrelated key/name attributes (%d reads)", helpersApi.Reads()))
	return "DoorRequirementLookup: PASS (irrelevant candidates read category only; key IDs, names, links, master keys and other categories preserved)"
end)
fixture:Destroy()
module:Destroy()
assert(ok, result)
return result
