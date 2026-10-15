-- Studio Edit or Play Client. Paired lookup benchmark, not an overall FPS test.
-- Reverts only the native candidate selection in a private Before module.
local original = game.ReplicatedStorage.DoorSystemShared.DoorAccess.Source
local beforeSource = original
for _, root in {"root", "character"} do
	local expression = 'if category then ' .. root .. ':QueryDescendants("[$Category], ObjectValue") else ' .. root .. ':GetDescendants()'
	local first, last = beforeSource:find(expression, 1, true)
	assert(first and last, "Native candidate selection not found")
	beforeSource = beforeSource:sub(1, first - 1) .. root .. ':GetDescendants()' .. beforeSource:sub(last + 1)
end
local beforeModule = Instance.new("ModuleScript") beforeModule.Source = beforeSource
local afterModule = Instance.new("ModuleScript") afterModule.Source = original
local before, after = require(beforeModule), require(afterModule)
local fixture = Instance.new("Folder")
local inventory = Instance.new("Folder") inventory.Name = "Inventory" inventory.Parent = fixture
local backpack = Instance.new("Folder") backpack.Name = "Backpack" backpack.Parent = fixture
local character = Instance.new("Model") character.Parent = fixture
local external = Instance.new("Folder") external.Parent = fixture
local assembly = Instance.new("Model") assembly.Parent = fixture
local player = {Character = character}
function player:FindFirstChild(name) return fixture:FindFirstChild(name) end
local key = Instance.new("Folder") key.Name = "TestKey" key.Parent = external
key:SetAttribute("Category", "DoorKey") key:SetAttribute("KeyId", "A")
local link = Instance.new("ObjectValue") link.Parent = backpack
local results = {}
local repetitions = 5
local function sample(name, subject, door, leaf, expected)
	assert(before.HasMatchingItem(subject, door, leaf) == after.HasMatchingItem(subject, door, leaf), name .. " initial mismatch")
	local values = {Before = {}, After = {}}
	for pair = 1, 12 do
		local order = if pair % 2 == 0 then {"Before", "After"} else {"After", "Before"}
		for _, variant in order do
			local api = if variant == "Before" then before else after
			local started = os.clock()
			for _ = 1, repetitions do assert(api.HasMatchingItem(subject, door, leaf) == expected, name .. " decision changed") end
			local elapsed = (os.clock() - started) * 1000 / repetitions
			if pair > 2 then table.insert(values[variant], elapsed) end
		end
		task.wait()
	end
	local row = {Name = name, Expected = expected}
	for variant, times in values do
		table.sort(times)
		row[variant] = {MedianMs = times[5], P95Ms = times[10]}
	end
	table.insert(results, row)
end
local ok, err = pcall(function()
	for _, root in {inventory, backpack, character} do
		for i = 1, 1000 do
			local part = Instance.new("Part") part.Name = "Geometry" .. i part.Parent = root
			if i % 500 == 0 then task.wait() end
		end
	end
	assembly:SetAttribute("RequiredKeyId", "A")
	sample("Missing category key / 3000 geometry descendants", player, assembly, nil, false)
	link.Value = key
	sample("Linked key outside inventory", player, assembly, nil, true)
	link.Value = nil key.Parent = character
	sample("Equipped character key", player, assembly, nil, true)
	key.Parent = external
	assembly:SetAttribute("RequiredKeyId", nil) assembly:SetAttribute("RequiredItemName", "Geometry1000")
	sample("Uncategorized name-only fallback", player, assembly, nil, true)
	local realPlayer = game.Players.LocalPlayer
	if realPlayer then
		local doors = {}
		for _, door in game:GetService("CollectionService"):GetTagged("DoorSystemDoor") do
			local leaves = door:FindFirstChild("Leaves")
			if leaves then for _, leaf in leaves:GetChildren() do
				if leaf:IsA("Model") and before.GetSetting(door, leaf, {"RequiredKeyId", "DoorKeyId", "KeyId"}, nil) then
					table.insert(doors, {Door = door, Leaf = leaf})
				end
			end end
		end
		table.sort(doors, function(a, b) return a.Door:GetFullName() .. a.Leaf.Name < b.Door:GetFullName() .. b.Leaf.Name end)
		for i = 1, math.min(5, #doors) do
			local item = doors[i]
			sample("Authored " .. item.Door.Name .. "/" .. item.Leaf.Name, realPlayer, item.Door, item.Leaf,
				before.HasMatchingItem(realPlayer, item.Door, item.Leaf))
		end
	end
end)
fixture:Destroy() beforeModule:Destroy() afterModule:Destroy()
assert(ok, err)
return {MeasuredPairs = 10, CallsPerVariantPerCase = repetitions * 10, SyntheticGeometry = 3000, Cases = results}
