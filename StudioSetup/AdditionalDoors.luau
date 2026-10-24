-- Run once in Inventory_Dev Edit. Uses the installed DoorSystem without replacing its scripts.
-- Re-running preserves completed rigs, sound edits and designer configuration.
assert(not game:GetService("RunService"):IsRunning(), "Set up doors in Edit mode")
local doors = assert(workspace:FindFirstChild("Doors"), "Workspace.Doors missing")
local tags = game:GetService("CollectionService")
local history = game:GetService("ChangeHistoryService")
local definitions = {
	{ name="Generic_Door", body="Extruded.003", frame="Extruded.001", health=85, difficulty="Novice", wood=true, sounds="Lever_Door_A" },
	{ name="Office_Door1", body="Door2_low", health=110, difficulty="Apprentice", wood=true, sounds="Lever_Door_A" },
	{ name="Glass_Door", body="Door", frame="Frame", health=70, difficulty="Apprentice", sounds="Double_Glass_Door" },
	{ name="Cathedral_Door", frame="Extruded.009", health=200, difficulty="Adept", sounds="Lever_Door_A" },
}
-- Validate every input before changing any assembly.
for _, def in definitions do
	local assembly = assert(doors:FindFirstChild(def.name), "Missing " .. def.name)
	if not tags:HasTag(assembly, "DoorSystemDoor") then
		assert(not assembly:FindFirstChild("Leaves"), "Incomplete rig needs inspection: " .. def.name)
		assert(doors[def.sounds]:FindFirstChild("Sounds"), "Reference sound bank missing")
		if def.name == "Cathedral_Door" then
			assert(assembly.Left:FindFirstChild("Solid_481") and assembly.Right:FindFirstChild("Solid_483"))
		elseif def.name == "Office_Door1" then
			for _, name in {"Door2_low", "Glass_low", "Thing_low", "Handle2_low"} do assert(assembly:FindFirstChild(name), name .. " missing") end
		elseif def.name == "Glass_Door" then
			assert(assembly.Door:FindFirstChild("Door") and assembly.Door:FindFirstChild("Part"))
		else assert(assembly:FindFirstChild(def.body)) end
	end
end
local poses = {}
for _, def in definitions do
	for _, part in doors[def.name]:GetDescendants() do if part:IsA("BasePart") then poses[part] = part.CFrame end end
end
local function invisiblePart(name, cf, size, parent)
	local part = Instance.new("Part")
	part.Name, part.CFrame, part.Size = name, cf, size
	part.Transparency, part.Anchored = 1, true
	part.CanCollide, part.CanTouch, part.CanQuery = false, false, false
	part.Parent = parent
	return part
end
local function makeLeaf(assembly, name, body, moving, hingeSide, thickness, handle, plate)
	local rig = Instance.new("Model") rig.Name = name rig.Parent = assembly.Leaves
	local cf = CFrame.lookAt(body.Position, body.Position + body.CFrame.LookVector, Vector3.yAxis)
	local hinge = invisiblePart("Hinge", cf * CFrame.new(hingeSide * body.Size.X / 2, 0, 0), Vector3.new(.12,body.Size.Y,.12), rig)
	local leaf
	if typeof(moving) == "Instance" then leaf = moving leaf.Name = "Leaf" leaf.Parent = rig
	else
		leaf = Instance.new("Model") leaf.Name = "Leaf" leaf.Parent = rig
		for _, part in moving do part.Parent = leaf end
	end
	local root = invisiblePart("Root", cf, Vector3.new(.12,.12,.12), leaf)
	leaf.PrimaryPart = root
	local collision = invisiblePart("CollisionTemplate", cf, Vector3.new(body.Size.X-.08,body.Size.Y-.08,thickness), rig)
	collision.Material = body.Material
	local attachment = Instance.new("Attachment") attachment.Name = "PromptAttachment"
	attachment.Position = Vector3.new(-hingeSide * collision.Size.X*.35, handle and handle.Position.Y-cf.Position.Y or -.45, 0)
	attachment.Parent = collision
	local prompt = Instance.new("ProximityPrompt") prompt.Name="DoorPrompt" prompt.ActionText="Open"
	prompt.ObjectText=assembly:GetAttribute("PromptObjectText") prompt.KeyboardKeyCode=Enum.KeyCode.E prompt.GamepadKeyCode=Enum.KeyCode.ButtonX
	prompt.MaxActivationDistance=8 prompt.RequiresLineOfSight=false prompt.Style=Enum.ProximityPromptStyle.Custom prompt.Parent=attachment
	for _, part in leaf:GetDescendants() do
		if part:IsA("BasePart") and part ~= root then
			part.Anchored=false part.CanCollide=false part.CanTouch=false part.CanQuery=false part.Massless=true
			if part == handle then
				local position = Vector3.new(plate.Position.X, handle.Position.Y, plate.Position.Z)
				local pivot = CFrame.new(position) * cf.Rotation
				part.PivotOffset=part.CFrame:ToObjectSpace(pivot)
				local motor=Instance.new("Motor6D") motor.Name="HandleFrontMotor" motor.Part0=root motor.Part1=part
				motor.C0=root.CFrame:ToObjectSpace(pivot) motor.C1=part.CFrame:ToObjectSpace(pivot) motor.Parent=root
				local target=Instance.new("ObjectValue") target.Name="PivotTarget" target.Value=part target.Parent=motor
			else
				local weld=Instance.new("WeldConstraint") weld.Name="DoorVisualWeld" weld.Part0=root weld.Part1=part weld.Parent=root
			end
		end
	end
	rig:SetAttribute("HandleEnabled",handle ~= nil)
	if handle then rig:SetAttribute("HandleAxis","Z") rig:SetAttribute("HandlePressDeg",-26) end
	rig:SetAttribute("ExternalOpenSign",-hingeSide)
	assert(math.abs(cf:PointToObjectSpace(hinge.Position).X) > body.Size.X*.49, "Hinge is not at outer edge")
	return rig
end
history:SetWaypoint("Before additional door setup")
local installed = {}
for _, def in definitions do
	local assembly = doors[def.name]
	if not tags:HasTag(assembly,"DoorSystemDoor") then
		local reference = doors[def.sounds]
		for name, value in reference:GetAttributes() do assembly:SetAttribute(name,value) end
		assembly:SetAttribute("PromptObjectText",def.name:gsub("_"," "))
		assembly:SetAttribute("MaxHealth",def.health) assembly:SetAttribute("StartingHealth",def.health)
		assembly:SetAttribute("Locked",false) assembly:SetAttribute("LockpickEnabled",true)
		assembly:SetAttribute("LockpickDifficulty",def.difficulty)
		assembly:SetAttribute("LockpickAutoClose",false) assembly:SetAttribute("LockpickRegenEnabled",false)
		assembly:SetAttribute("HandleEnabled",def.name=="Office_Door1")
		assembly:SetAttribute("DoorSetupVersion",1)
		if def.wood then assembly:SetAttribute("DoorMaterial","Wood") end
		if def.name=="Cathedral_Door" then assembly:SetAttribute("SoundPitchScale",.85) end
		local sounds=reference.Sounds:Clone() sounds.Parent=assembly
		local leaves=Instance.new("Folder") leaves.Name="Leaves" leaves.Parent=assembly
		if def.frame then local frame=assembly[def.frame] frame.Anchored=true frame.CanCollide=false frame.CanTouch=false end
		if def.name=="Cathedral_Door" then
			makeLeaf(assembly,"Left",assembly.Left.Solid_481,assembly.Left,1,.38)
			makeLeaf(assembly,"Right",assembly.Right.Solid_483,assembly.Right,-1,.38)
		elseif def.name=="Office_Door1" then
			local body=assembly.Door2_low body.Material=Enum.Material.Wood
			local handle,plate=assembly.Handle2_low,assembly.Thing_low
			makeLeaf(assembly,"MainLeaf",body,{body,assembly.Glass_low,plate,handle},1,.32,handle,plate)
		elseif def.name=="Glass_Door" then
			makeLeaf(assembly,"MainLeaf",assembly.Door.Door,assembly.Door,-1,.22)
		else
			local body=assembly[def.body] body.Material=Enum.Material.Wood
			makeLeaf(assembly,"MainLeaf",body,{body},-1,.32)
		end
		tags:AddTag(assembly,"DoorSystemDoor")
		table.insert(installed,def.name)
	end
end
for part, cf in poses do assert((part.Position-cf.Position).Magnitude<.001, "Authored mesh moved: "..part:GetFullName()) end
history:SetWaypoint("Additional doors configured")
return {Installed=installed, Note="Save the place to retain these editable door rigs and sounds"}
