-- Creates a clean no-floor demo with:
-- 1) Lightweight push + handle single door
-- 2) Linked double door
-- 3) Lockable / breakable heavier door

local CollectionService = game:GetService("CollectionService")

local TAG = "DoorSystemDoor"
local old = workspace:FindFirstChild("DoorSystemDemo")
if old then
	old:Destroy()
end

local demo = Instance.new("Folder")
demo.Name = "DoorSystemDemo"
demo.Parent = workspace

local spawnLocation = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
local origin = if spawnLocation then spawnLocation.Position + Vector3.new(0, 3.5, -14) else Vector3.new(0, 4, 0)

local function part(name, size, cf, color, parent, transparency)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.WoodPlanks
	p.Anchored = true
	p.CanCollide = true
	p.Transparency = transparency or 0
	p.Parent = parent
	return p
end

local function weld(part0: BasePart, part1: BasePart)
	local wc = Instance.new("WeldConstraint")
	wc.Part0 = part0
	wc.Part1 = part1
	wc.Parent = part1
	part1.Anchored = false
	return wc
end

local function soundTemplate(parent: Instance, name: string, soundId: string, volume: number)
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = soundId
	s.Volume = volume
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 4
	s.RollOffMaxDistance = 48
	s:SetAttribute("PitchVariance", 0.035)
	s.Parent = parent
	return s
end

local function soundPool(parent: Folder, name: string, soundIds: {string}, volume: number)
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	for index, soundId in soundIds do
		soundTemplate(folder, string.format("%02d", index), soundId, volume)
	end
	return folder
end

local function addSoundBank(assembly: Model)
	local sounds = Instance.new("Folder")
	sounds.Name = "Sounds"
	sounds.Parent = assembly

	-- v7.7 default sound bank. A category may be ONE Sound or a Folder of Sound variants.
	-- The server rolls folder variants once and replicates that exact choice to clients.
	soundTemplate(sounds, "Open", "rbxassetid://123340492201290", 0.72)
	soundTemplate(sounds, "CloseStart", "rbxasset://sounds/switch.wav", 0.18)
	soundTemplate(sounds, "Close", "rbxassetid://136038446613189", 0.76)
	soundTemplate(sounds, "Lock", "rbxassetid://7163763387", 0.72)
	soundTemplate(sounds, "Unlock", "rbxassetid://9069595493", 0.72)

	soundPool(sounds, "Locked", {
		"rbxassetid://6814495006",
		"rbxassetid://78692018703946",
		"rbxassetid://17614504723",
	}, 0.72)

	soundPool(sounds, "KickAttempt", {
		"rbxassetid://86813211589705",
		"rbxassetid://87406101322923",
		"rbxassetid://74949702069382",
	}, 0.88)

	soundPool(sounds, "Breach", {
		"rbxassetid://123640556588300",
		"rbxassetid://87406101322923",
		"rbxassetid://139136622293168",
	}, 0.94)

	-- Optional categories left as simple built-in placeholders so existing handle/latch
	-- feedback remains intact. Delete any category you don't want to hear.
	soundTemplate(sounds, "Handle", "rbxasset://sounds/button.wav", 0.28)
	soundTemplate(sounds, "Latch", "rbxasset://sounds/switch.wav", 0.30)
end

local function makeLeafRig(parent: Instance, name: string, hingeCF: CFrame, width: number, height: number, opensFromRight: boolean)
	local rig = Instance.new("Model")
	rig.Name = name
	rig.Parent = parent

	local leavesOffset = if opensFromRight then width / 2 else -width / 2
	local center = hingeCF.Position + hingeCF.RightVector * leavesOffset
	local leafCF = CFrame.fromMatrix(center, hingeCF.RightVector, hingeCF.UpVector, hingeCF.LookVector)

	local hinge = part("Hinge", Vector3.new(0.12, height, 0.12), hingeCF, Color3.new(1, 1, 1), rig, 1)
	hinge.CanCollide = false
	hinge.CanQuery = false

	local leaf = Instance.new("Model")
	leaf.Name = "Leaf"
	leaf.Parent = rig

	local root = part("Root", Vector3.new(0.18, 0.18, 0.18), leafCF, Color3.new(1, 1, 1), leaf, 1)
	root.CanCollide = false

	leaf.PrimaryPart = root

	local slab = part("DoorSlab", Vector3.new(width, height, 0.28), leafCF, Color3.fromRGB(109, 76, 52), leaf)
	slab.Material = Enum.Material.Wood
	slab:SetAttribute("BreakCollision", true)
	weld(root, slab)

	-- Simple inset panels so you can clearly read the swing.
	for y = -1, 1, 2 do
		local panel = part("Panel", Vector3.new(width * 0.64, height * 0.30, 0.05), leafCF * CFrame.new(0, y * height * 0.22, -0.165), Color3.fromRGB(84, 56, 38), leaf)
		panel.Material = Enum.Material.Wood
		panel.CanCollide = false
		weld(root, panel)
	end

	-- Front handle root + motor. Weld any future front-handle geometry to HandleFrontRoot.
	local frontRoot = part("HandleFrontRoot", Vector3.new(0.12, 0.12, 0.12), leafCF * CFrame.new((opensFromRight and 1 or -1) * width * 0.32, 0, -0.24), Color3.new(1,1,1), leaf, 1)
	frontRoot.CanCollide = false
	frontRoot.Anchored = false
	local frontMotor = Instance.new("Motor6D")
	frontMotor.Name = "HandleFrontMotor"
	frontMotor.Part0 = root
	frontMotor.Part1 = frontRoot
	frontMotor.C0 = root.CFrame:ToObjectSpace(frontRoot.CFrame)
	frontMotor.C1 = CFrame.identity
	frontMotor.Parent = root
	local frontGrip = part("HandleFront", Vector3.new(0.65, 0.10, 0.12), frontRoot.CFrame * CFrame.new((opensFromRight and -1 or 1) * 0.24, 0, 0), Color3.fromRGB(58, 51, 45), leaf)
	frontGrip.Material = Enum.Material.Metal
	frontGrip.CanCollide = false
	weld(frontRoot, frontGrip)

	-- Back handle root + motor.
	local backRoot = part("HandleBackRoot", Vector3.new(0.12, 0.12, 0.12), leafCF * CFrame.new((opensFromRight and 1 or -1) * width * 0.32, 0, 0.24), Color3.new(1,1,1), leaf, 1)
	backRoot.CanCollide = false
	backRoot.Anchored = false
	local backMotor = Instance.new("Motor6D")
	backMotor.Name = "HandleBackMotor"
	backMotor.Part0 = root
	backMotor.Part1 = backRoot
	backMotor.C0 = root.CFrame:ToObjectSpace(backRoot.CFrame)
	backMotor.C1 = CFrame.identity
	backMotor.Parent = root
	local backGrip = part("HandleBack", Vector3.new(0.65, 0.10, 0.12), backRoot.CFrame * CFrame.new((opensFromRight and -1 or 1) * 0.24, 0, 0), Color3.fromRGB(58, 51, 45), leaf)
	backGrip.Material = Enum.Material.Metal
	backGrip.CanCollide = false
	weld(backRoot, backGrip)

	-- Authoring attachment points. You can weld/attach future content to Root and handles.
	for _, nameAndPos in {
		{"AccessoryRoot", Vector3.new(0, 0, 0)},
		{"AudioRoot", Vector3.new((opensFromRight and 1 or -1) * width * 0.30, 0, 0)},
		{"KickRoot", Vector3.new(0, -height * 0.22, 0)},
	} do
		local a = Instance.new("Attachment")
		a.Name = nameAndPos[1]
		a.Position = nameAndPos[2]
		a.Parent = root
		if a.Name == "KickRoot" then
			local dust = Instance.new("ParticleEmitter")
			dust.Name = "KickDust"
			dust.Enabled = false
			dust.Rate = 0
			dust.Lifetime = NumberRange.new(0.22, 0.48)
			dust.Speed = NumberRange.new(5, 11)
			dust.SpreadAngle = Vector2.new(42, 42)
			dust.Rotation = NumberRange.new(0, 360)
			dust.RotSpeed = NumberRange.new(-120, 120)
			dust.Drag = 4
			dust.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.22),
				NumberSequenceKeypoint.new(0.35, 0.48),
				NumberSequenceKeypoint.new(1, 0),
			})
			dust.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.20),
				NumberSequenceKeypoint.new(1, 1),
			})
			dust.Parent = a
		end
	end

	local collision = part("CollisionTemplate", Vector3.new(width * 0.94, height * 0.96, 0.34), leafCF, Color3.new(1,1,1), rig, 1)
	collision.CanCollide = false
	collision.CanTouch = false
	collision.CanQuery = false

	leaf:PivotTo(leafCF)
	return rig
end

local function makeFrame(assembly: Model, center: Vector3, totalWidth: number, height: number)
	local color = Color3.fromRGB(55, 48, 42)
	part("FrameLeft", Vector3.new(0.34, height + 0.55, 0.55), CFrame.new(center + Vector3.new(-totalWidth/2 - 0.17, 0, 0)), color, assembly)
	part("FrameRight", Vector3.new(0.34, height + 0.55, 0.55), CFrame.new(center + Vector3.new(totalWidth/2 + 0.17, 0, 0)), color, assembly)
	part("FrameTop", Vector3.new(totalWidth + 0.68, 0.34, 0.55), CFrame.new(center + Vector3.new(0, height/2 + 0.17, 0)), color, assembly)
end

local function makeAssembly(name: string, center: Vector3, doubleDoor: boolean)
	local assembly = Instance.new("Model")
	assembly.Name = name
	assembly.Parent = demo
	assembly:SetAttribute("Locked", false)
	assembly:SetAttribute("PushEnabled", true)
	assembly:SetAttribute("HybridCollision", false)
	assembly:SetAttribute("PromptEnabled", true)
	assembly:SetAttribute("AutoClose", true)
	assembly:SetAttribute("AutoCloseDelay", 0.85)
	assembly:SetAttribute("MaxHealth", 100)
	assembly:SetAttribute("WalkPushHandleEnabled", true)
	assembly:SetAttribute("SoundVolumeScale", 1.0)
	assembly:SetAttribute("AllowPlayerLocking", false)
	assembly:SetAttribute("LockPromptEnabled", false)
	assembly:SetAttribute("Breakable", true)
	assembly:SetAttribute("PromptOpenMode", doubleDoor and "All" or "Single")

	local leaves = Instance.new("Folder")
	leaves.Name = "Leaves"
	leaves.Parent = assembly

	local height = 7
	if doubleDoor then
		local width = 3.15
		makeFrame(assembly, center, width * 2, height)
		makeLeafRig(leaves, "LeftLeaf", CFrame.new(center + Vector3.new(-width, 0, 0)), width, height, true)
		makeLeafRig(leaves, "RightLeaf", CFrame.new(center + Vector3.new(width, 0, 0)), width, height, false)
	else
		local width = 4
		makeFrame(assembly, center, width, height)
		makeLeafRig(leaves, "MainLeaf", CFrame.new(center + Vector3.new(-width/2, 0, 0)), width, height, true)
	end
	addSoundBank(assembly)
	CollectionService:AddTag(assembly, TAG)
	return assembly
end

-- Lightweight door: walking through should be easy and fluid.
local light = makeAssembly("01_Light_Push_And_Handle", origin + Vector3.new(-8, 0, 0), false)
light:SetAttribute("VirtualMass", 3.9)
light:SetAttribute("EffectivePlayerMass", 10.0)
light:SetAttribute("PushImpulseScale", 0.60)
light:SetAttribute("PushDriveResponse", 16.0)
light:SetAttribute("AutoCloseDelay", 1.0)
light:SetAttribute("ReturnStiffness", 12.5)
light:SetAttribute("ReturnDamping", 6.4)
light:SetAttribute("PromptOpenAngleDeg", 90)

-- Double door: both leaves open from a single prompt; physical push still affects the contacted leaf independently.
local double = makeAssembly("02_Double_Door", origin + Vector3.new(0, 0, 0), true)
double:SetAttribute("VirtualMass", 4.8)
double:SetAttribute("EffectivePlayerMass", 9.6)
double:SetAttribute("PushImpulseScale", 0.54)
double:SetAttribute("PushDriveResponse", 14.0)
double:SetAttribute("PromptOpenMode", "All")
double:SetAttribute("PromptOpenAngleDeg", 82)
double:SetAttribute("PromptHoldOpenTime", 1.5)

-- Heavier / lockable / breakable door.
local heavy = makeAssembly("03_Lockable_Breachable", origin + Vector3.new(9, 0, 0), false)
heavy:SetAttribute("VirtualMass", 7.0)
heavy:SetAttribute("EffectivePlayerMass", 8.0)
heavy:SetAttribute("PushImpulseScale", 0.46)
heavy:SetAttribute("PushDriveResponse", 12.0)
heavy:SetAttribute("ReturnStiffness", 16.5)
heavy:SetAttribute("ReturnDamping", 8.0)
heavy:SetAttribute("AllowPlayerLocking", true)
heavy:SetAttribute("LockPromptEnabled", true)
heavy:SetAttribute("Breakable", true)
heavy:SetAttribute("KickPromptEnabled", true)
heavy:SetAttribute("MaxHealth", 100)
heavy:SetAttribute("BreachOpenAngularSpeedDeg", 350)
heavy:SetAttribute("BreachMaxAngularSpeedDeg", 480)
heavy:SetAttribute("BreachLimitBounce", 0.30)
heavy:SetAttribute("BreachShakeDeg", 8)
heavy:SetAttribute("BreachHoldOpenTime", 1.8)
heavy:SetAttribute("AutoCloseAfterBreach", false)
heavy:SetAttribute("PromptObjectText", "Breachable Door")
heavy:SetAttribute("UnlockedKickAngularImpulseDeg", 300)
heavy:SetAttribute("KickMinAngularSpeedDeg", 420)
heavy:SetAttribute("KickMaxAngularSpeedDeg", 580)

print("[DoorSystem] Demo spawned at workspace.DoorSystemDemo")
print("DoorSystem v7.7 demo: walk/sprint push, E Open/Close, F lock, R kick. External attributes Open/Closed/Locked/DoorState/TargetState are hard commands.")
