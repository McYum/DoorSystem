--!strict
-- Door System server-authoritative virtual rigid-body hinge + solid collision proxy.
-- Visible leaves are reconstructed client-side from timestamped motion snapshots.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Config = require(script.Parent.Config)
local sharedFolder = ReplicatedStorage:WaitForChild("DoorSystemShared", 10)
assert(sharedFolder, "[DoorSystem] ReplicatedStorage.DoorSystemShared is missing")
local DoorAccess = require(sharedFolder:WaitForChild("DoorAccess"))

local DoorService = {}
DoorService.VERSION = Config.Version or "7.8.0"
DoorService.VERSION_NAME = Config.VersionName or "DoorSystem v7.8"

function DoorService.GetVersion(): (string, string)
	return DoorService.VERSION, DoorService.VERSION_NAME
end

local remotesFolder = ReplicatedStorage:FindFirstChild(Config.RemotesFolderName) :: Folder?
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = Config.RemotesFolderName
	remotesFolder.Parent = ReplicatedStorage
end

local stateEvent = remotesFolder:FindFirstChild("State") :: RemoteEvent?
if not stateEvent then
	stateEvent = Instance.new("RemoteEvent")
	stateEvent.Name = "State"
	stateEvent.Parent = remotesFolder
end

local actionEvent = remotesFolder:FindFirstChild("Action") :: RemoteEvent?
if not actionEvent then
	actionEvent = Instance.new("RemoteEvent")
	actionEvent.Name = "Action"
	actionEvent.Parent = remotesFolder
end

-- Client-assisted push intent. The client only identifies the leaf it is approaching;
-- all movement/contact/lock validation and the actual impulse remain server-authoritative.
local pushEvent = remotesFolder:FindFirstChild("Push") :: RemoteEvent?
if not pushEvent then
	pushEvent = Instance.new("RemoteEvent")
	pushEvent.Name = "Push"
	pushEvent.Parent = remotesFolder
end

-- Client-side prompt proxies use this remote so their billboard can follow the
-- reconstructed smooth leaf pose without relying on a replicated prompt anchor.
-- Every request is still validated server-side.
local interactEvent = remotesFolder:FindFirstChild("Interact") :: RemoteEvent?
if not interactEvent then
	interactEvent = Instance.new("RemoteEvent")
	interactEvent.Name = "Interact"
	interactEvent.Parent = remotesFolder
end

local snapshotFunction = remotesFolder:FindFirstChild("Snapshot") :: RemoteFunction?
if not snapshotFunction then
	snapshotFunction = Instance.new("RemoteFunction")
	snapshotFunction.Name = "Snapshot"
	snapshotFunction.Parent = remotesFolder
end

local function attr(inst: Instance, name: string, fallback: any): any
	if inst:IsA("Model") then
		return DoorAccess.GetSetting(inst, nil, name, fallback)
	end
	local value = inst:GetAttribute(name)
	if value ~= nil then
		return value
	end
	return fallback
end

local function setting(leafRig: Model, assembly: Model, name: string, fallback: any): any
	return DoorAccess.GetSetting(assembly, leafRig, name, fallback)
end

local function clampAbs(value: number, maxAbs: number): number
	return math.clamp(value, -maxAbs, maxAbs)
end

local function signNonZero(v: number): number
	if v < 0 then
		return -1
	end
	return 1
end

local function axisCFrame(axis: string, radians: number): CFrame
	if axis == "Y" then
		return CFrame.Angles(0, radians, 0)
	elseif axis == "Z" then
		return CFrame.Angles(0, 0, radians)
	end
	return CFrame.Angles(radians, 0, 0)
end

export type PlayerSample = {
	player: Player,
	root: BasePart,
	humanoid: Humanoid,
	position: Vector3,
	previousPosition: Vector3,
	velocity: Vector3,
	moveDirection: Vector3,
}

export type PushDriver = {
	expiresAt: number,
	startedAt: number,
	lastRefreshAt: number,
	peakNormalSpeed: number,
}

export type LeafState = {
	assembly: Model,
	rig: Model,
	hinge: BasePart,
	leafModel: Model,
	root: BasePart?,
	collision: BasePart,
	closedLeafPivot: CFrame,
	hingeToLeaf: CFrame,
	closedCollisionCF: CFrame,
	hingeToCollision: CFrame,
	angle: number,
	velocity: number,
	targetAngle: number?,
	mode: string,
	commandSerial: number,
	lastPushTime: number,
	lastMotionTime: number,
	holdUntil: number,
	blockedUntil: number,
	occupied: boolean,
	health: number,
	lastAcceleration: number,
	contacts: {[Player]: number},
	drivers: {[Player]: PushDriver},
	broken: boolean,
	breached: boolean,
	kickBoostUntil: number,
	collisionEnabled: boolean,
	collisionYieldUntil: number,
	safetyIgnorePlayer: Player?,
	safetyIgnoreUntil: number,
	lastReplicatedAngle: number,
	lastReplicatedMode: string,
	openSoundArmed: boolean,
	closeStartSoundArmed: boolean,
	closeSoundArmed: boolean,
	closeSeatSoundPlayed: boolean,
	audioPhase: string,
	lastMotionSoundAt: number,
	lastSoundChoice: {[string]: Sound},
	walkPushHandleArmed: boolean,
	lastWalkPushHandleAt: number,
	prompt: ProximityPrompt?,
	lockPrompt: ProximityPrompt?,
	kickPrompt: ProximityPrompt?,
}

export type AssemblyState = {
	model: Model,
	leaves: {LeafState},
	locked: boolean,
	pendingLock: boolean,
	registered: boolean,
	attributeConnections: {RBXScriptConnection},
	lastPublishedAttributes: {[string]: any},
	stableClosed: boolean,
	stableOpen: boolean,
	targetState: string,
	lastPublicState: string,
	stateRevision: number,
	lastMotionAudioAt: {[string]: number},
}

local assemblies: {[Model]: AssemblyState} = {}
local leafByRig: {[Model]: LeafState} = {}
local activeLeaves: {[LeafState]: boolean} = {}
-- Only assemblies actually waiting to latch are checked each heartbeat. This avoids
-- scanning every registered door every frame in large maps.
local pendingLockAssemblies: {[AssemblyState]: boolean} = {}
local playerSamples: {PlayerSample} = {}
local playerPositionHistory: {[Player]: Vector3} = {}
local spatialBuckets: {[string]: {[LeafState]: boolean}} = {}
local leafSpatialKey: {[LeafState]: string} = {}

local function spatialKeyFromPosition(position: Vector3): string
	local cell = Config.SpatialCellSize
	return (`{math.floor(position.X / cell)}:{math.floor(position.Z / cell)}`)
end

local function addLeafToSpatialHash(leaf: LeafState)
	local key = spatialKeyFromPosition(leaf.hinge.Position)
	local bucket = spatialBuckets[key]
	if not bucket then
		bucket = {}
		spatialBuckets[key] = bucket
	end
	bucket[leaf] = true
	leafSpatialKey[leaf] = key
end

local function removeLeafFromSpatialHash(leaf: LeafState)
	local key = leafSpatialKey[leaf]
	if not key then return end
	local bucket = spatialBuckets[key]
	if bucket then
		bucket[leaf] = nil
		if next(bucket) == nil then spatialBuckets[key] = nil end
	end
	leafSpatialKey[leaf] = nil
end

local simAccumulator = 0
local scanAccumulator = 0
local replicationAccumulator = 0
local occupancyAccumulator = 0
local started = false

local function getLeafPose(leaf: LeafState, angle: number): CFrame
	return leaf.hinge.CFrame * CFrame.Angles(0, angle, 0) * leaf.hingeToLeaf
end

local function getCollisionPose(leaf: LeafState, angle: number): CFrame
	return leaf.hinge.CFrame * CFrame.Angles(0, angle, 0) * leaf.hingeToCollision
end

local function setCollisionPose(leaf: LeafState)
	if leaf.collision.Parent then
		leaf.collision.CFrame = getCollisionPose(leaf, leaf.angle)
	end
end

local function setActive(leaf: LeafState)
	activeLeaves[leaf] = true
	leaf.lastMotionTime = os.clock()
end

type DefaultSoundDefinition = {
	ids: {string},
	volume: number,
}

local DEFAULT_SOUND_BANK: {[string]: DefaultSoundDefinition} = table.freeze({
	Open = table.freeze({ids = table.freeze({"rbxassetid://123340492201290"}), volume = 0.72}),
	-- Distinct closing-motion cue. `Close` remains the physical jamb/seat impact.
	CloseStart = table.freeze({ids = table.freeze({"rbxasset://sounds/switch.wav"}), volume = 0.18}),
	Close = table.freeze({ids = table.freeze({"rbxassetid://136038446613189"}), volume = 0.76}),
	Lock = table.freeze({ids = table.freeze({"rbxassetid://7163763387"}), volume = 0.72}),
	Unlock = table.freeze({ids = table.freeze({"rbxassetid://9069595493"}), volume = 0.72}),
	Locked = table.freeze({ids = table.freeze({
		"rbxassetid://6814495006",
		"rbxassetid://78692018703946",
		"rbxassetid://17614504723",
	}), volume = 0.72}),
	KickAttempt = table.freeze({ids = table.freeze({
		"rbxassetid://86813211589705",
		"rbxassetid://87406101322923",
		"rbxassetid://74949702069382",
	}), volume = 0.88}),
	Breach = table.freeze({ids = table.freeze({
		"rbxassetid://123640556588300",
		"rbxassetid://87406101322923",
		"rbxassetid://139136622293168",
	}), volume = 0.94}),
})

local function configureGeneratedSound(sound: Sound, soundId: string, volume: number, assembly: Model)
	sound.SoundId = soundId
	sound.Volume = volume
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = math.max(0, tonumber(attr(assembly, "DefaultSoundRollOffMinDistance", Config.DefaultSoundRollOffMinDistance)) or Config.DefaultSoundRollOffMinDistance)
	sound.RollOffMaxDistance = math.max(sound.RollOffMinDistance + 1, tonumber(attr(assembly, "DefaultSoundRollOffMaxDistance", Config.DefaultSoundRollOffMaxDistance)) or Config.DefaultSoundRollOffMaxDistance)
	sound:SetAttribute("PitchVariance", tonumber(attr(assembly, "SoundDefaultPitchVariance", Config.SoundDefaultPitchVariance)) or Config.SoundDefaultPitchVariance)
	sound:SetAttribute("DoorSystemGenerated", true)
end

local function provisionDefaultSounds(assembly: Model)
	if attr(assembly, "ProvisionDefaultSounds", Config.ProvisionDefaultSounds) == false then
		return
	end
	local sounds = assembly:FindFirstChild("Sounds")
	if sounds and not sounds:IsA("Folder") then
		-- Respect an unusual custom object named Sounds rather than replacing it.
		return
	end
	if not sounds then
		sounds = Instance.new("Folder")
		sounds.Name = "Sounds"
		sounds:SetAttribute("DoorSystemGenerated", true)
		sounds.Parent = assembly
	end
	local soundsFolder = sounds :: Folder

	for categoryName, definition in DEFAULT_SOUND_BANK do
		-- Existing custom Sound OR Folder wins completely. For the new KickAttempt
		-- category, an authored legacy Sounds/Kick category also wins so v7.7 does not
		-- silently replace a creator's custom impact bank. Old DoorSystem-generated Kick
		-- categories are migrated by adding the new KickAttempt category beside them.
		if soundsFolder:FindFirstChild(categoryName) then
			continue
		end
		if categoryName == "KickAttempt" then
			local legacyKick = soundsFolder:FindFirstChild("Kick")
			if legacyKick and legacyKick:GetAttribute("DoorSystemGenerated") ~= true then
				continue
			end
		end
		local ids = definition.ids
		if #ids == 1 then
			local sound = Instance.new("Sound")
			sound.Name = categoryName
			configureGeneratedSound(sound, ids[1], definition.volume, assembly)
			sound.Parent = soundsFolder
		else
			local pool = Instance.new("Folder")
			pool.Name = categoryName
			pool:SetAttribute("DoorSystemGenerated", true)
			pool.Parent = soundsFolder
			for index, soundId in ids do
				local sound = Instance.new("Sound")
				sound.Name = string.format("%02d", index)
				configureGeneratedSound(sound, soundId, definition.volume, assembly)
				sound.Parent = pool
			end
		end
	end
end

local function rootCharacter(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
		return root, humanoid
	end
	return nil, nil
end

local function collectSoundCandidates(container: Instance?, name: string): {Sound}
	local result: {Sound} = {}
	if not container then
		return result
	end

	local category = container:FindFirstChild(name)
	if not category then
		return result
	end
	if category:IsA("Sound") then
		if category.SoundId ~= "" then
			table.insert(result, category)
		end
		return result
	end
	if category:IsA("Folder") then
		for _, descendant in category:GetDescendants() do
			if descendant:IsA("Sound") and descendant.SoundId ~= "" then
				table.insert(result, descendant)
			end
		end
	end
	return result
end

local function getSoundCandidates(leaf: LeafState, name: string): {Sound}
	-- A category authored on the leaf overrides the assembly category completely.
	local leafCandidates = collectSoundCandidates(leaf.rig:FindFirstChild("Sounds"), name)
	if #leafCandidates > 0 then
		return leafCandidates
	end
	return collectSoundCandidates(leaf.assembly:FindFirstChild("Sounds"), name)
end

local function chooseSoundTemplate(leaf: LeafState, name: string): Sound?
	local candidates = getSoundCandidates(leaf, name)
	if #candidates == 0 then
		return nil
	end
	if #candidates == 1 then
		leaf.lastSoundChoice[name] = candidates[1]
		return candidates[1]
	end

	local noRepeat = setting(leaf.rig, leaf.assembly, "SoundRandomNoImmediateRepeat", Config.SoundRandomNoImmediateRepeat) ~= false
	local previous = leaf.lastSoundChoice[name]
	local picked = candidates[math.random(1, #candidates)]
	if noRepeat and previous and picked == previous then
		-- One bounded reroll without allocating a filtered table.
		local previousIndex = table.find(candidates, previous)
		if previousIndex then
			local offset = math.random(1, #candidates - 1)
			picked = candidates[((previousIndex - 1 + offset) % #candidates) + 1]
		end
	end
	leaf.lastSoundChoice[name] = picked
	return picked
end

local function playSound(leaf: LeafState, name: string, speedScale: number?, channel: string?): boolean
	if setting(leaf.rig, leaf.assembly, "SoundEnabled", Config.SoundEnabled) == false then
		return false
	end
	local template = chooseSoundTemplate(leaf, name)
	if not template then
		return false
	end

	-- The server chooses both the category variant and random variance exactly once.
	-- Every hearing client therefore receives the same event instead of independently
	-- rolling a random clip.
	local defaultPitchVariance = tonumber(setting(leaf.rig, leaf.assembly, "SoundDefaultPitchVariance", Config.SoundDefaultPitchVariance)) or Config.SoundDefaultPitchVariance
	local defaultVolumeVariance = tonumber(setting(leaf.rig, leaf.assembly, "SoundDefaultVolumeVariance", Config.SoundDefaultVolumeVariance)) or Config.SoundDefaultVolumeVariance
	local pitchVariance = tonumber(template:GetAttribute("PitchVariance")) or defaultPitchVariance
	local volumeVariance = tonumber(template:GetAttribute("VolumeVariance")) or defaultVolumeVariance
	local pitchScale = tonumber(setting(leaf.rig, leaf.assembly, "SoundPitchScale", Config.SoundPitchScale)) or Config.SoundPitchScale
	local volumeScale = tonumber(setting(leaf.rig, leaf.assembly, "SoundVolumeScale", Config.SoundVolumeScale)) or Config.SoundVolumeScale
	local speed = speedScale or 1
	local playbackSpeed = math.max(0.1, template.PlaybackSpeed * speed * pitchScale * (1 + (math.random() * 2 - 1) * pitchVariance))
	local volume = math.max(0, template.Volume * volumeScale * (1 + (math.random() * 2 - 1) * volumeVariance))

	local authoredDistance = tonumber(setting(leaf.rig, leaf.assembly, "SoundReplicationDistance", Config.SoundReplicationDistance)) or Config.SoundReplicationDistance
	local maxDistance = math.max(authoredDistance, template.RollOffMaxDistance + 8)
	local maxDistanceSq = maxDistance * maxDistance
	local payload = {
		kind = "Sound",
		rig = leaf.rig,
		data = {
			name = name,
			template = template,
			playbackSpeed = playbackSpeed,
			volume = volume,
			channel = channel,
		},
	}

	-- 3D sounds cannot be heard beyond their rolloff anyway. Avoid sending every door
	-- sound to every player on large servers while preserving the audible range.
	for _, player in Players:GetPlayers() do
		local root = select(1, rootCharacter(player))
		if root then
			local delta = root.Position - leaf.hinge.Position
			if delta:Dot(delta) <= maxDistanceSq then
				actionEvent:FireClient(player, payload)
			end
		end
	end
	return true
end

local function playSoundFallback(leaf: LeafState, primary: string?, fallback: string?, speedScale: number?, channel: string?): boolean
	if primary and primary ~= "" and playSound(leaf, primary, speedScale, channel) then
		return true
	end
	if fallback and fallback ~= "" and fallback ~= primary then
		return playSound(leaf, fallback, speedScale, channel)
	end
	return false
end

local function playMotionSoundFallback(
	leaf: LeafState,
	eventKey: string,
	primary: string?,
	fallback: string?,
	tertiary: string?,
	speedScale: number?
): boolean
	local state = assemblies[leaf.assembly]
	local now = os.clock()
	if state then
		local window = math.max(0, tonumber(setting(
			leaf.rig,
			leaf.assembly,
			"AssemblyMotionSoundDedupWindow",
			Config.AssemblyMotionSoundDedupWindow
		)) or Config.AssemblyMotionSoundDedupWindow)
		local lastAt = state.lastMotionAudioAt[eventKey] or -math.huge
		if now - lastAt < window then
			-- Treat a duplicate as handled so callers never fall through to another sound.
			return true
		end
	end

	local played = playSoundFallback(leaf, primary, fallback, speedScale, "Motion")
	if not played and tertiary and tertiary ~= "" and tertiary ~= primary and tertiary ~= fallback then
		played = playSound(leaf, tertiary, speedScale, "Motion")
	end
	if played and state then
		state.lastMotionAudioAt[eventKey] = now
	end
	return played
end

local function markAudioPhase(leaf: LeafState, phase: string, soundName: string?, fallbackName: string?, speedScale: number?, force: boolean?)
	-- Motion cues are one-shot per real open/close cycle. `force` may bypass the
	-- short time debounce, but it never bypasses these cycle gates. This prevents
	-- hinge bounce, duplicate state transitions, or overlapping command paths from
	-- replaying Open/CloseStart multiple times.
	if phase == "Opening" and not leaf.openSoundArmed then
		leaf.audioPhase = phase
		return
	elseif phase == "Closing" and not leaf.closeStartSoundArmed then
		leaf.audioPhase = phase
		return
	end

	if not force and leaf.audioPhase == phase then
		return
	end
	local now = os.clock()
	local debounce = tonumber(setting(leaf.rig, leaf.assembly, "MotionSoundDebounce", Config.MotionSoundDebounce)) or Config.MotionSoundDebounce
	if soundName and (force or now - leaf.lastMotionSoundAt >= debounce) then
		if playMotionSoundFallback(leaf, phase, soundName, fallbackName, nil, speedScale) then
			leaf.lastMotionSoundAt = now
		end
	end

	if phase == "Opening" then
		leaf.openSoundArmed = false
		leaf.closeStartSoundArmed = true
		leaf.closeSeatSoundPlayed = false
	elseif phase == "Closing" then
		leaf.closeStartSoundArmed = false
	end
	leaf.audioPhase = phase
end

local function broadcastAction(leaf: LeafState, kind: string, data: {[string]: any}?)
	actionEvent:FireAllClients({
		kind = kind,
		rig = leaf.rig,
		data = data or {},
	})
end

local function refreshPlayerSamples()
	table.clear(playerSamples)
	local alive: {[Player]: boolean} = {}
	for _, player in Players:GetPlayers() do
		alive[player] = true
		local root, humanoid = rootCharacter(player)
		if root and humanoid then
			local position = root.Position
			local previous = playerPositionHistory[player] or position
			playerPositionHistory[player] = position
			table.insert(playerSamples, {
				player = player,
				root = root,
				humanoid = humanoid,
				position = position,
				previousPosition = previous,
				velocity = root.AssemblyLinearVelocity,
				moveDirection = humanoid.MoveDirection,
			})
		end
	end
	for player in playerPositionHistory do
		if not alive[player] then
			playerPositionHistory[player] = nil
		end
	end
end

local function resolveLeafRigs(assembly: Model): {Model}
	local result = {}
	local leavesFolder = assembly:FindFirstChild("Leaves")
	if leavesFolder then
		for _, child in leavesFolder:GetChildren() do
			if child:IsA("Model") then
				table.insert(result, child)
			end
		end
	else
		-- Backward-compatible simple format: assembly itself contains Hinge + Leaf.
		if assembly:FindFirstChild("Hinge") and assembly:FindFirstChild("Leaf") then
			table.insert(result, assembly)
		end
	end
	return result
end

local function getOrCreateCollision(leafRig: Model, leafModel: Model): BasePart
	local existing = leafRig:FindFirstChild("DoorCollision")
	if existing and existing:IsA("BasePart") then
		existing.Anchored = true
		existing.Transparency = 1
		existing.CanTouch = false
		existing.CanQuery = true
		existing.CanCollide = true
		return existing
	end

	local template = leafRig:FindFirstChild("CollisionTemplate")
	if template and template:IsA("BasePart") then
		local collision = template:Clone()
		collision.Name = "DoorCollision"
		collision.Transparency = 1
		collision.Anchored = true
		collision.CanTouch = false
		collision.CanQuery = true
		collision.CanCollide = true
		collision.Parent = leafRig
		template.CanCollide = false
		template.CanTouch = false
		template.CanQuery = false
		template.Transparency = 1
		return collision
	end

	local boxCF, boxSize = leafModel:GetBoundingBox()
	local collision = Instance.new("Part")
	collision.Name = "DoorCollision"
	collision.Size = Vector3.new(
		math.max(0.2, boxSize.X - 0.12),
		math.max(0.2, boxSize.Y - 0.12),
		math.max(0.14, math.min(boxSize.Z, 0.55))
	)
	collision.CFrame = boxCF
	collision.Anchored = true
	collision.Transparency = 1
	collision.CanTouch = false
	collision.CanQuery = true
	collision.CanCollide = true
	collision.Parent = leafRig
	return collision
end

local function makePrompt(leaf: LeafState): ProximityPrompt?
	if not setting(leaf.rig, leaf.assembly, "PromptEnabled", Config.PromptEnabled) then
		return nil
	end

	local attachment = leaf.collision:FindFirstChild("PromptAttachment")
	if not attachment or not attachment:IsA("Attachment") then
		attachment = Instance.new("Attachment")
		attachment.Name = "PromptAttachment"
		-- Put the prompt near the free edge, roughly handle height.
		local hingeLocalX = leaf.collision.CFrame:PointToObjectSpace(leaf.hinge.Position).X
		local freeEdgeSign = if hingeLocalX >= 0 then -1 else 1
		attachment.Position = Vector3.new(
			freeEdgeSign * leaf.collision.Size.X * 0.35,
			math.min(0.2, leaf.collision.Size.Y * 0.1),
			0
		)
		attachment.Parent = leaf.collision
	end
	local existing = attachment:FindFirstChild("DoorPrompt")
	if existing and existing:IsA("ProximityPrompt") then
		if setting(leaf.rig, leaf.assembly, "CustomPromptStyle", Config.CustomPromptStyle) == true then
			existing.Style = Enum.ProximityPromptStyle.Custom
		end
		return existing
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "DoorPrompt"
	prompt.ActionText = setting(leaf.rig, leaf.assembly, "PromptActionText", Config.PromptActionText)
	prompt.ObjectText = setting(leaf.rig, leaf.assembly, "PromptObjectText", Config.PromptObjectText)
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.MaxActivationDistance = setting(leaf.rig, leaf.assembly, "PromptDistance", Config.PromptDistance)
	prompt.HoldDuration = setting(leaf.rig, leaf.assembly, "PromptHoldDuration", Config.PromptHoldDuration)
	prompt.RequiresLineOfSight = false
	if setting(leaf.rig, leaf.assembly, "CustomPromptStyle", Config.CustomPromptStyle) == true then
		prompt.Style = Enum.ProximityPromptStyle.Custom
	end
	prompt.Parent = attachment
	return prompt
end

local function makeLockPrompt(leaf: LeafState): ProximityPrompt?
	local enabled = setting(leaf.rig, leaf.assembly, "LockPromptEnabled", Config.LockPromptEnabled)
	local allow = setting(leaf.rig, leaf.assembly, "AllowPlayerLocking", Config.AllowPlayerLocking)
	if not enabled or not allow then
		return nil
	end

	local attachment = leaf.collision:FindFirstChild("PromptAttachment")
	if not attachment or not attachment:IsA("Attachment") then
		return nil
	end
	local existing = attachment:FindFirstChild("LockPrompt")
	if existing and existing:IsA("ProximityPrompt") then
		if setting(leaf.rig, leaf.assembly, "CustomPromptStyle", Config.CustomPromptStyle) == true then
			existing.Style = Enum.ProximityPromptStyle.Custom
		end
		return existing
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LockPrompt"
	prompt.ActionText = "Lock / Unlock"
	prompt.ObjectText = setting(leaf.rig, leaf.assembly, "PromptObjectText", Config.PromptObjectText)
	prompt.KeyboardKeyCode = setting(leaf.rig, leaf.assembly, "LockPromptKey", Config.LockPromptKey)
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.MaxActivationDistance = setting(leaf.rig, leaf.assembly, "LockPromptDistance", Config.LockPromptDistance)
	prompt.HoldDuration = setting(leaf.rig, leaf.assembly, "LockPromptHoldDuration", Config.LockPromptHoldDuration)
	prompt.RequiresLineOfSight = false
	if setting(leaf.rig, leaf.assembly, "CustomPromptStyle", Config.CustomPromptStyle) == true then
		prompt.Style = Enum.ProximityPromptStyle.Custom
	end
	prompt.Parent = attachment
	return prompt
end

local function makeKickPrompt(leaf: LeafState): ProximityPrompt?
	if not setting(leaf.rig, leaf.assembly, "KickPromptEnabled", Config.KickPromptEnabled) then
		return nil
	end
	local attachment = leaf.collision:FindFirstChild("PromptAttachment")
	if not attachment or not attachment:IsA("Attachment") then
		return nil
	end
	local existing = attachment:FindFirstChild("KickPrompt")
	if existing and existing:IsA("ProximityPrompt") then
		if setting(leaf.rig, leaf.assembly, "CustomPromptStyle", Config.CustomPromptStyle) == true then
			existing.Style = Enum.ProximityPromptStyle.Custom
		end
		return existing
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "KickPrompt"
	prompt.ActionText = "Kick"
	prompt.ObjectText = setting(leaf.rig, leaf.assembly, "PromptObjectText", Config.PromptObjectText)
	prompt.KeyboardKeyCode = setting(leaf.rig, leaf.assembly, "KickPromptKey", Config.KickPromptKey)
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonB
	prompt.MaxActivationDistance = setting(leaf.rig, leaf.assembly, "KickPromptDistance", Config.KickPromptDistance)
	prompt.HoldDuration = setting(leaf.rig, leaf.assembly, "KickPromptHoldDuration", Config.KickPromptHoldDuration)
	prompt.RequiresLineOfSight = false
	if setting(leaf.rig, leaf.assembly, "CustomPromptStyle", Config.CustomPromptStyle) == true then
		prompt.Style = Enum.ProximityPromptStyle.Custom
	end
	prompt.Parent = attachment
	return prompt
end

local function playerSideForLeaf(leaf: LeafState, player: Player): string
	local root = select(1, rootCharacter(player))
	if not root then
		return "Front"
	end
	-- Use the CURRENT leaf plane. This stays correct when the door is already ajar.
	local currentCF = getCollisionPose(leaf, leaf.angle)
	local localPos = currentCF:PointToObjectSpace(root.Position)
	return if localPos.Z >= 0 then "Front" else "Back"
end

local function canPlayerAccess(leaf: LeafState, player: Player, action: string): (boolean, string?)
	return DoorAccess.Check(player, leaf.assembly, action, playerSideForLeaf(leaf, player), leaf.rig)
end

local function torqueSignFromForce(leaf: LeafState, contactWorld: Vector3, forceWorld: Vector3): number
	local forcePlanar = forceWorld * Vector3.new(1, 0, 1)
	if forcePlanar.Magnitude < 1e-4 then
		return signNonZero(leaf.angle == 0 and 1 or leaf.angle)
	end
	local vertical = leaf.hinge.CFrame.UpVector
	local radius = contactWorld - leaf.hinge.Position
	local planarRadius = radius - vertical * radius:Dot(vertical)
	local torque = vertical:Dot(planarRadius:Cross(forcePlanar.Unit))
	if math.abs(torque) < 1e-4 then
		return signNonZero(leaf.angle == 0 and 1 or leaf.angle)
	end
	return if torque >= 0 then 1 else -1
end

local function chooseOpenSign(leaf: LeafState, player: Player?): number
	local forced = tonumber(setting(leaf.rig, leaf.assembly, "OpenSign", 0)) or 0
	if forced > 0 then
		return 1
	elseif forced < 0 then
		return -1
	end

	if not player then
		return signNonZero(leaf.angle == 0 and 1 or leaf.angle)
	end
	local root = select(1, rootCharacter(player))
	if not root then
		return 1
	end

	local cf = getCollisionPose(leaf, leaf.angle)
	local localPlayer = cf:PointToObjectSpace(root.Position)
	local half = leaf.collision.Size * 0.5
	local contactLocal = Vector3.new(math.clamp(localPlayer.X, -half.X, half.X), math.clamp(localPlayer.Y, -half.Y, half.Y), 0)
	local contactWorld = cf:PointToWorldSpace(contactLocal)
	-- Opening from a prompt/kick should rotate AWAY from the player at the current pose.
	local awayForce = contactWorld - root.Position
	return torqueSignFromForce(leaf, contactWorld, awayForce)
end

local function leafLooksOpen(leaf: LeafState): boolean
	local threshold = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "PromptCloseThresholdDeg", Config.PromptCloseThresholdDeg)) or Config.PromptCloseThresholdDeg)
	-- The prompt represents the action that makes sense NOW, not merely the current
	-- angle. If a half-open door is actively closing, show Open so the prompt can
	-- decisively reverse it. Likewise an explicit open target counts as open intent.
	if leaf.targetAngle ~= nil then
		return math.abs(leaf.targetAngle) >= threshold
	end
	if leaf.mode == "Closing" or leaf.mode == "GuidedClose" or leaf.mode == "PromptClosing" or leaf.mode == "HandleEngagedClose" or leaf.mode == "HeldForPlayer" then
		return false
	end
	return math.abs(leaf.angle) >= threshold
end

local function updateLeafPromptText(state: AssemblyState, leaf: LeafState)
	if not leaf.prompt then
		return
	end
	if state.locked then
		leaf.prompt.ActionText = setting(leaf.rig, state.model, "PromptLockedText", Config.PromptLockedText)
	elseif leafLooksOpen(leaf) then
		leaf.prompt.ActionText = setting(leaf.rig, state.model, "PromptCloseText", Config.PromptCloseText)
	else
		leaf.prompt.ActionText = setting(leaf.rig, state.model, "PromptActionText", Config.PromptActionText)
	end
end

local function updatePromptText(state: AssemblyState)
	for _, leaf in state.leaves do
		updateLeafPromptText(state, leaf)
	end
end

local function allLeavesClosed(state: AssemblyState): boolean
	local enterAngle = tonumber(attr(state.model, "ClosedEnterAngleDeg", Config.ClosedEnterAngleDeg)) or Config.ClosedEnterAngleDeg
	local exitAngle = tonumber(attr(state.model, "ClosedExitAngleDeg", Config.ClosedExitAngleDeg)) or Config.ClosedExitAngleDeg
	local enterVelocity = tonumber(attr(state.model, "ClosedEnterVelocityDeg", Config.ClosedEnterVelocityDeg)) or Config.ClosedEnterVelocityDeg
	if state.stableClosed then
		for _, leaf in state.leaves do
			if leaf.broken or math.abs(leaf.angle) > math.rad(exitAngle) then
				state.stableClosed = false
				break
			end
		end
	else
		state.stableClosed = #state.leaves > 0
		for _, leaf in state.leaves do
			if leaf.broken or math.abs(leaf.angle) > math.rad(enterAngle) or math.abs(leaf.velocity) > math.rad(enterVelocity) then
				state.stableClosed = false
				break
			end
		end
	end
	return state.stableClosed
end

local function primeVelocityTowardTarget(leaf: LeafState, target: number, minSpeedDeg: number)
	local delta = target - leaf.angle
	if math.abs(delta) < math.rad(0.15) then
		return
	end
	local direction = signNonZero(delta)
	local along = leaf.velocity * direction
	local minSpeed = math.rad(math.max(0, minSpeedDeg))
	if along < minSpeed then
		leaf.velocity = direction * minSpeed
	end
end

local function beginLeafCommand(leaf: LeafState): number
	leaf.commandSerial += 1
	return leaf.commandSerial
end

local function isHighPriorityGuidedMode(mode: string): boolean
	return mode == "PromptOpening"
		or mode == "PromptClosing"
		or mode == "GuidedClose"
		or mode == "ExternalOpening"
		or mode == "ExternalClosing"
		or mode == "ExternalLockClosing"
end

local function assemblyHasActiveExternalCommand(state: AssemblyState): boolean
	for _, leaf in state.leaves do
		if leaf.mode == "ExternalOpening"
			or leaf.mode == "ExternalClosing"
			or leaf.mode == "ExternalLockClosing"
		then
			return true
		end
	end
	return false
end

local function playCloseStartIfMoving(leaf: LeafState, force: boolean?)
	local minAngle = math.rad(tonumber(setting(
		leaf.rig,
		leaf.assembly,
		"CloseStartSoundMinAngleDeg",
		Config.CloseStartSoundMinAngleDeg
	)) or Config.CloseStartSoundMinAngleDeg)
	if math.abs(leaf.angle) >= minAngle then
		markAudioPhase(leaf, "Closing", Config.SoundNames.CloseStart, Config.SoundNames.Creak, 1, force)
	else
		leaf.audioPhase = "Closed"
	end
end

local function requestCloseLeaf(leaf: LeafState)
	if leaf.broken then
		return
	end
	beginLeafCommand(leaf)
	table.clear(leaf.drivers)
	table.clear(leaf.contacts)
	leaf.targetAngle = 0
	leaf.mode = "GuidedClose"
	leaf.closeSoundArmed = true
	local closeState = assemblies[leaf.assembly]
	if closeState then closeState.targetState = "Closed" end
	leaf.holdUntil = 0
	leaf.safetyIgnorePlayer = nil
	leaf.safetyIgnoreUntil = 0
	playCloseStartIfMoving(leaf, true)
	local minSpeed = tonumber(setting(leaf.rig, leaf.assembly, "PromptCloseCommandMinSpeedDeg", Config.PromptCloseCommandMinSpeedDeg)) or Config.PromptCloseCommandMinSpeedDeg
	primeVelocityTowardTarget(leaf, 0, minSpeed)
	setActive(leaf)
end

local function requestExternalCloseLeaf(leaf: LeafState, lockAfterClose: boolean?)
	if leaf.broken then
		return
	end
	beginLeafCommand(leaf)
	table.clear(leaf.drivers)
	table.clear(leaf.contacts)
	leaf.targetAngle = 0
	leaf.mode = if lockAfterClose then "ExternalLockClosing" else "ExternalClosing"
	local externalCloseState = assemblies[leaf.assembly]
	if externalCloseState then externalCloseState.targetState = if lockAfterClose then "Locked" else "Closed" end
	leaf.holdUntil = 0
	leaf.kickBoostUntil = 0
	leaf.blockedUntil = 0
	leaf.safetyIgnorePlayer = nil
	leaf.safetyIgnoreUntil = 0
	leaf.closeSoundArmed = true
	playCloseStartIfMoving(leaf, true)
	local minSpeed = tonumber(setting(leaf.rig, leaf.assembly, "ExternalCloseCommandMinSpeedDeg", Config.ExternalCloseCommandMinSpeedDeg)) or Config.ExternalCloseCommandMinSpeedDeg
	primeVelocityTowardTarget(leaf, 0, minSpeed)
	setActive(leaf)
end

local function requestExternalOpenLeaf(leaf: LeafState)
	if leaf.broken then
		return
	end
	beginLeafCommand(leaf)
	table.clear(leaf.drivers)
	table.clear(leaf.contacts)
	leaf.kickBoostUntil = 0
	leaf.blockedUntil = 0
	leaf.safetyIgnorePlayer = nil
	leaf.safetyIgnoreUntil = 0

	local preserveDirectionThreshold = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "PromptPreserveOpenDirectionDeg", Config.PromptPreserveOpenDirectionDeg)) or Config.PromptPreserveOpenDirectionDeg)
	local authoredSign = tonumber(setting(leaf.rig, leaf.assembly, "ExternalOpenSign", setting(leaf.rig, leaf.assembly, "OpenSign", 0))) or 0
	local openSign: number
	if math.abs(leaf.angle) >= preserveDirectionThreshold then
		openSign = signNonZero(leaf.angle)
	elseif authoredSign ~= 0 then
		openSign = signNonZero(authoredSign)
	else
		openSign = 1
	end

	local targetDeg = tonumber(setting(leaf.rig, leaf.assembly, "ExternalOpenAngleDeg", setting(leaf.rig, leaf.assembly, "PromptOpenAngleDeg", Config.PromptOpenAngleDeg))) or Config.PromptOpenAngleDeg
	local maxAngleDeg = tonumber(setting(leaf.rig, leaf.assembly, "MaxAngleDeg", Config.MaxAngleDeg)) or Config.MaxAngleDeg
	local desiredAngle = math.rad(math.clamp(targetDeg, 5, maxAngleDeg) * openSign)
	leaf.targetAngle = desiredAngle
	leaf.mode = "ExternalOpening"
	local externalOpenState = assemblies[leaf.assembly]
	if externalOpenState then externalOpenState.targetState = "Open" end
	leaf.holdUntil = math.huge
	leaf.lastPushTime = os.clock()
	leaf.closeSoundArmed = true
	markAudioPhase(leaf, "Opening", Config.SoundNames.Open, Config.SoundNames.Creak, 1, true)
	local minSpeed = tonumber(setting(leaf.rig, leaf.assembly, "ExternalOpenCommandMinSpeedDeg", Config.ExternalOpenCommandMinSpeedDeg)) or Config.ExternalOpenCommandMinSpeedDeg
	primeVelocityTowardTarget(leaf, desiredAngle, minSpeed)
	setActive(leaf)
end

local function requestPromptOpen(leaf: LeafState, player: Player?, animateHandle: boolean?)
	if leaf.broken then
		return
	end
	local assemblyState = assemblies[leaf.assembly]
	if not assemblyState then
		return
	end

	local side = player and playerSideForLeaf(leaf, player) or "Front"
	if assemblyState.locked and player then
		local allowed = DoorAccess.Check(player, leaf.assembly, "Open", side, leaf.rig)
		if allowed then
			DoorService.SetLocked(leaf.assembly, false, player)
		end
	end
	local commandSerial = beginLeafCommand(leaf)
	if assemblyState.locked then
		local attemptSign = chooseOpenSign(leaf, player)
		if animateHandle ~= false then
			broadcastAction(leaf, "HandleLocked", {side = side})
			playSound(leaf, Config.SoundNames.Locked)
		end
		broadcastAction(leaf, "LockedAttempt", {side = side, sign = attemptSign})

		-- Locked open attempts are cosmetic-only by default. Keeping the real hinge at
		-- exactly zero makes the collision invariant explicit: handle/rattle feedback can
		-- be very visible without creating a traversable crack.
		local allowPhysicalRattle = setting(
			leaf.rig,
			leaf.assembly,
			"LockedAttemptAuthoritativeMotion",
			Config.LockedAttemptAuthoritativeMotion
		) == true
		if allowPhysicalRattle then
			local rattleDeg = tonumber(setting(leaf.rig, leaf.assembly, "LockedAttemptAngularImpulseDeg", Config.LockedAttemptAngularImpulseDeg)) or Config.LockedAttemptAngularImpulseDeg
			leaf.velocity += math.rad(attemptSign * rattleDeg)
			leaf.targetAngle = 0
			leaf.mode = "LockedRattle"
			setActive(leaf)
		else
			leaf.angle = 0
			leaf.velocity = 0
			leaf.lastAcceleration = 0
			leaf.targetAngle = nil
			leaf.mode = "Locked"
			leaf.collisionEnabled = true
			leaf.holdUntil = 0
			leaf.closeSoundArmed = false
			setCollisionPose(leaf)
			leaf.rig:SetAttribute("AngleDeg", 0)
			leaf.rig:SetAttribute("Open", false)
			leaf.rig:SetAttribute("Closed", true)
			leaf.rig:SetAttribute("Moving", false)
			leaf.rig:SetAttribute("CollisionEnabled", true)
			leaf.rig:SetAttribute("DoorState", "Locked")
			updateLeafPromptText(assemblyState, leaf)
			stateEvent:FireAllClients({
				t = workspace:GetServerTimeNow(),
				states = {{
					rig = leaf.rig,
					angle = 0,
					velocity = 0,
					acceleration = 0,
					mode = "Locked",
					broken = false,
					collisionEnabled = true,
				}},
			})
			activeLeaves[leaf] = nil
		end
		return
	end

	if animateHandle ~= false then
		broadcastAction(leaf, "Handle", {side = side})
		playSound(leaf, Config.SoundNames.Handle)
	end

	-- If the leaf is already meaningfully ajar, Open means continue away from closed
	-- in its current direction. Only choose a side from the operator when near closed.
	local preserveDirectionThreshold = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "PromptPreserveOpenDirectionDeg", Config.PromptPreserveOpenDirectionDeg)) or Config.PromptPreserveOpenDirectionDeg)
	local openSign = if math.abs(leaf.angle) >= preserveDirectionThreshold then signNonZero(leaf.angle) else chooseOpenSign(leaf, player)
	local targetDeg = tonumber(setting(leaf.rig, leaf.assembly, "PromptOpenAngleDeg", Config.PromptOpenAngleDeg)) or Config.PromptOpenAngleDeg
	local maxAngleDeg = tonumber(setting(leaf.rig, leaf.assembly, "MaxAngleDeg", Config.MaxAngleDeg)) or Config.MaxAngleDeg
	local desiredAngle = math.rad(math.clamp(targetDeg, 5, maxAngleDeg) * openSign)
	leaf.mode = "HandleEngaged"
	leaf.safetyIgnorePlayer = nil
	leaf.safetyIgnoreUntil = 0
	leaf.lastPushTime = os.clock()
	leaf.holdUntil = 0
	leaf.closeSoundArmed = true
	setActive(leaf)

	local delayTime = tonumber(setting(leaf.rig, leaf.assembly, "HandleDoorDelay", Config.HandleDoorDelay)) or Config.HandleDoorDelay
	task.delay(delayTime, function()
		if not leaf.rig.Parent or leaf.broken or leaf.commandSerial ~= commandSerial then
			return
		end
		if animateHandle ~= false then
			playSound(leaf, Config.SoundNames.Latch)
		end
		table.clear(leaf.drivers)
		table.clear(leaf.contacts)
		leaf.targetAngle = desiredAngle
		leaf.mode = "PromptOpening"
		assemblyState.targetState = "Open"
		markAudioPhase(leaf, "Opening", Config.SoundNames.Open, Config.SoundNames.Creak, 1, true)
		local minSpeed = tonumber(setting(leaf.rig, leaf.assembly, "PromptOpenCommandMinSpeedDeg", Config.PromptOpenCommandMinSpeedDeg)) or Config.PromptOpenCommandMinSpeedDeg
		primeVelocityTowardTarget(leaf, desiredAngle, minSpeed)
		setActive(leaf)
	end)
end

local function requestPromptClose(leaf: LeafState, player: Player?, animateHandle: boolean?)
	if leaf.broken then
		return
	end
	local state = assemblies[leaf.assembly]
	if not state then
		return
	end
	local commandSerial = beginLeafCommand(leaf)
	local side = player and playerSideForLeaf(leaf, player) or "Front"
	if animateHandle ~= false then
		broadcastAction(leaf, "Handle", {side = side})
		playSound(leaf, Config.SoundNames.Handle)
	end
	leaf.mode = "HandleEngagedClose"
	leaf.holdUntil = 0
	leaf.safetyIgnorePlayer = player
	leaf.safetyIgnoreUntil = os.clock() + (tonumber(setting(leaf.rig, leaf.assembly, "PromptCloseOperatorGrace", Config.PromptCloseOperatorGrace)) or Config.PromptCloseOperatorGrace)
	setActive(leaf)
	local delayTime = tonumber(setting(leaf.rig, leaf.assembly, "HandleDoorDelay", Config.HandleDoorDelay)) or Config.HandleDoorDelay
	task.delay(delayTime, function()
		if not leaf.rig.Parent or leaf.broken or leaf.commandSerial ~= commandSerial then
			return
		end
		if animateHandle ~= false then
			playSound(leaf, Config.SoundNames.Latch)
		end
		table.clear(leaf.drivers)
		table.clear(leaf.contacts)
		leaf.targetAngle = 0
		leaf.closeSoundArmed = true
		leaf.mode = "PromptClosing"
		state.targetState = "Closed"
		playCloseStartIfMoving(leaf, true)
		local minSpeed = tonumber(setting(leaf.rig, leaf.assembly, "PromptCloseCommandMinSpeedDeg", Config.PromptCloseCommandMinSpeedDeg)) or Config.PromptCloseCommandMinSpeedDeg
		primeVelocityTowardTarget(leaf, 0, minSpeed)
		setActive(leaf)
		updateLeafPromptText(state, leaf)
	end)
end

local function promptSetAssembly(state: AssemblyState, sourceLeaf: LeafState, player: Player, shouldClose: boolean)
	local mode = tostring(attr(state.model, "PromptOpenMode", "Single"))
	if mode == "All" then
		for _, leaf in state.leaves do
			if shouldClose then
				requestPromptClose(leaf, player, leaf == sourceLeaf)
			else
				requestPromptOpen(leaf, player, leaf == sourceLeaf)
			end
		end
	else
		if shouldClose then
			requestPromptClose(sourceLeaf, player, true)
		else
			requestPromptOpen(sourceLeaf, player, true)
		end
	end
	updatePromptText(state)
end

local function promptToggleAssembly(state: AssemblyState, sourceLeaf: LeafState, player: Player)
	local shouldClose = false
	if tostring(attr(state.model, "PromptOpenMode", "Single")) == "All" then
		for _, leaf in state.leaves do
			if leafLooksOpen(leaf) then
				shouldClose = true
				break
			end
		end
	else
		shouldClose = leafLooksOpen(sourceLeaf)
	end
	promptSetAssembly(state, sourceLeaf, player, shouldClose)
end

local function connectLeafPrompts(state: AssemblyState, leaf: LeafState)
	if leaf.prompt then
		leaf.prompt.Triggered:Connect(function(player)
			promptToggleAssembly(state, leaf, player)
		end)
	end
	if leaf.lockPrompt then
		leaf.lockPrompt.Triggered:Connect(function(player)
			if setting(leaf.rig, state.model, "AllowPlayerLocking", Config.AllowPlayerLocking) then
				DoorService.ToggleLock(state.model, player, leaf.rig)
			end
		end)
	end
	if leaf.kickPrompt then
		leaf.kickPrompt.Triggered:Connect(function(player)
			DoorService.Kick(state.model, player, leaf.rig)
		end)
	end
end

local function playerWithinInteractionRange(player: Player, leaf: LeafState, baseDistance: number): boolean
	local root = select(1, rootCharacter(player))
	if not root then
		return false
	end

	local padding = tonumber(setting(leaf.rig, leaf.assembly, "PromptValidationPadding", Config.PromptValidationPadding)) or Config.PromptValidationPadding
	local cf = getCollisionPose(leaf, leaf.angle)
	local p = cf:PointToObjectSpace(root.Position)
	local half = leaf.collision.Size * 0.5
	local reach = baseDistance + padding

	-- Validate against the actual current leaf rather than only the hinge. This
	-- remains correct when the door is already open and the handle/free edge has moved.
	return math.abs(p.X) <= half.X + reach
		and math.abs(p.Y) <= half.Y + math.min(reach, 3.0)
		and math.abs(p.Z) <= half.Z + reach
end

local clientInteractRate: {[Player]: number} = {}

local function handleClientInteraction(player: Player, rig: Instance, action: any)
	if not rig:IsA("Model") then
		return
	end
	local leaf = leafByRig[rig]
	if not leaf or leaf.broken or not leaf.rig.Parent then
		return
	end
	local state = assemblies[leaf.assembly]
	if not state then
		return
	end

	-- Script/API Open/Close/Lock owns the assembly until the commanded motion
	-- reaches its target. Player prompts, kicks and lock toggles cannot replace a
	-- force-state command halfway through.
	if assemblyHasActiveExternalCommand(state) then
		return
	end

	local now = os.clock()
	local last = clientInteractRate[player] or -math.huge
	if now - last < 0.075 then
		return
	end
	clientInteractRate[player] = now

	local actionName = tostring(action)
	if actionName == "Toggle" or actionName == "Open" or actionName == "Close" then
		if not setting(leaf.rig, state.model, "PromptEnabled", Config.PromptEnabled) then
			return
		end
		local distance = tonumber(setting(leaf.rig, state.model, "PromptDistance", Config.PromptDistance)) or Config.PromptDistance
		if not playerWithinInteractionRange(player, leaf, distance) then
			return
		end
		if actionName == "Open" then
			promptSetAssembly(state, leaf, player, false)
		elseif actionName == "Close" then
			promptSetAssembly(state, leaf, player, true)
		else
			promptToggleAssembly(state, leaf, player)
		end
	elseif actionName == "Lock" then
		if not setting(leaf.rig, state.model, "AllowPlayerLocking", Config.AllowPlayerLocking)
			or not setting(leaf.rig, state.model, "LockPromptEnabled", Config.LockPromptEnabled)
		then
			return
		end
		local distance = tonumber(setting(leaf.rig, state.model, "LockPromptDistance", Config.LockPromptDistance)) or Config.LockPromptDistance
		if not playerWithinInteractionRange(player, leaf, distance) then
			return
		end
		DoorService.ToggleLock(state.model, player, leaf.rig)
	elseif actionName == "Kick" then
		if not setting(leaf.rig, state.model, "KickPromptEnabled", Config.KickPromptEnabled) then
			return
		end
		local distance = tonumber(setting(leaf.rig, state.model, "KickPromptDistance", Config.KickPromptDistance)) or Config.KickPromptDistance
		if not playerWithinInteractionRange(player, leaf, distance) then
			return
		end
		DoorService.Kick(state.model, player, leaf.rig)
	end
end

interactEvent.OnServerEvent:Connect(handleClientInteraction)
Players.PlayerRemoving:Connect(function(player)
	clientInteractRate[player] = nil
end)

local function anchorLeafForHybrid(leafModel: Model, root: BasePart?)
	-- Root-based authoring: Root is the only anchored visual part. Everything welded
	-- to Root (including Motor6D handle roots) remains unanchored so custom pieces
	-- added later can actually follow their weld/motor hierarchy.
	for _, descendant in leafModel:GetDescendants() do
		if descendant:IsA("BasePart") then
			if root then
				descendant.Anchored = descendant == root
			else
				descendant.Anchored = true
			end
			descendant.CanCollide = false
			descendant.CanTouch = false
		end
	end
end

local function registerLeaf(state: AssemblyState, leafRig: Model): LeafState?
	local hinge = leafRig:FindFirstChild("Hinge")
	local leafModel = leafRig:FindFirstChild("Leaf")
	if not hinge or not hinge:IsA("BasePart") or not leafModel or not leafModel:IsA("Model") then
		warn(("[DoorService] %s needs Hinge (BasePart) + Leaf (Model)"):format(leafRig:GetFullName()))
		return nil
	end

	local root = leafModel:FindFirstChild("Root", true)
	local rootPart = if root and root:IsA("BasePart") then root else nil
	anchorLeafForHybrid(leafModel, rootPart)
	leafModel.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanTouch = false
			if rootPart then
				descendant.Anchored = descendant == rootPart
			end
		end
	end)

	local collision = getOrCreateCollision(leafRig, leafModel)
	local closedLeafPivot = leafModel:GetPivot()
	local closedCollisionCF = collision.CFrame
	local hingeToLeaf = hinge.CFrame:ToObjectSpace(closedLeafPivot)
	local hingeToCollision = hinge.CFrame:ToObjectSpace(closedCollisionCF)
	leafRig:SetAttribute("ClosedHingeToLeaf", hingeToLeaf)
	leafRig:SetAttribute("ClosedHingeToCollision", hingeToCollision)

	local maxHealth = math.max(0, tonumber(setting(leafRig, state.model, "MaxHealth", Config.MaxHealth)) or Config.MaxHealth)
	local explicitHealth = leafRig:GetAttribute("Health")
	if explicitHealth == nil then explicitHealth = state.model:GetAttribute("Health") end
	local numericExplicitHealth = tonumber(explicitHealth)
	local authoredStartingHealth = tonumber(setting(leafRig, state.model, "StartingHealth", Config.StartingHealth)) or Config.StartingHealth
	local startingHealth: number
	if numericExplicitHealth ~= nil then
		startingHealth = math.clamp(numericExplicitHealth, 0, maxHealth)
	elseif authoredStartingHealth >= 0 then
		startingHealth = math.clamp(authoredStartingHealth, 0, maxHealth)
	else
		startingHealth = maxHealth
	end

	local leaf: LeafState = {
		assembly = state.model,
		rig = leafRig,
		hinge = hinge,
		leafModel = leafModel,
		root = rootPart,
		collision = collision,
		closedLeafPivot = closedLeafPivot,
		hingeToLeaf = hingeToLeaf,
		closedCollisionCF = closedCollisionCF,
		hingeToCollision = hingeToCollision,
		angle = 0,
		velocity = 0,
		targetAngle = nil,
		mode = "Idle",
		commandSerial = 0,
		lastPushTime = 0,
		lastMotionTime = os.clock(),
		holdUntil = 0,
		blockedUntil = 0,
		occupied = false,
		health = startingHealth,
		broken = false,
		breached = false,
		kickBoostUntil = 0,
		collisionEnabled = true,
		collisionYieldUntil = 0,
		safetyIgnorePlayer = nil,
		safetyIgnoreUntil = 0,
		lastAcceleration = 0,
		contacts = {},
		drivers = {},
		lastReplicatedAngle = math.huge,
		lastReplicatedMode = "",
		openSoundArmed = true,
		closeStartSoundArmed = false,
		closeSoundArmed = false,
		closeSeatSoundPlayed = true,
		audioPhase = "Closed",
		lastMotionSoundAt = 0,
		lastSoundChoice = {},
		walkPushHandleArmed = true,
		lastWalkPushHandleAt = -math.huge,
		prompt = nil,
		lockPrompt = nil,
		kickPrompt = nil,
	}

	leaf.prompt = makePrompt(leaf)
	leaf.lockPrompt = makeLockPrompt(leaf)
	leaf.kickPrompt = makeKickPrompt(leaf)
	leafRig:SetAttribute("Health", leaf.health)
	leafRig:SetAttribute("HealthPercent", if maxHealth > 0 then math.clamp(leaf.health / maxHealth, 0, 1) else 0)
	leafRig:SetAttribute("Breached", false)
	leafRig:SetAttribute("LockBroken", false)
	leaf.mode = if state.locked then "Locked" else "Idle"
	leafRig:SetAttribute("DoorState", leaf.mode)
	leafRig:SetAttribute("AngleDeg", 0)
	leafRig:SetAttribute("Open", false)
	leafRig:SetAttribute("Closed", true)
	leafRig:SetAttribute("Moving", false)
	leafRig:SetAttribute("CollisionEnabled", true)
	leafByRig[leafRig] = leaf
	addLeafToSpatialHash(leaf)
	connectLeafPrompts(state, leaf)
	return leaf
end

local function setAttributeIfDifferent(inst: Instance, name: string, value: any)
	if inst:GetAttribute(name) ~= value then
		inst:SetAttribute(name, value)
	end
end

local function writeAssemblyAttribute(state: AssemblyState, name: string, value: any)
	-- Keep the guard aligned with the latest public state even when the Instance
	-- already has that value. Roblox may deliver an older SetAttribute signal on a
	-- later deferred cycle; leaving the previous published value here would make
	-- that system-authored signal look external and recursively issue a command.
	state.lastPublishedAttributes[name] = value
	if state.model:GetAttribute(name) == value then
		return
	end
	state.model:SetAttribute(name, value)
end

local function assemblyActuallyOpen(state: AssemblyState): boolean
	local enterDeg = tonumber(attr(state.model, "OpenStateAngleDeg", Config.OpenStateAngleDeg)) or Config.OpenStateAngleDeg
	local hysteresis = tonumber(attr(state.model, "OpenStateExitHysteresisDeg", Config.OpenStateExitHysteresisDeg)) or Config.OpenStateExitHysteresisDeg
	local threshold = math.rad(if state.stableOpen then math.max(1, enterDeg - hysteresis) else enterDeg)
	state.stableOpen = #state.leaves > 0
	for _, leaf in state.leaves do
		if leaf.broken or math.abs(leaf.angle) < threshold then
			state.stableOpen = false
			break
		end
	end
	return state.stableOpen
end

local function assemblyMoving(state: AssemblyState): boolean
	local threshold = math.rad(tonumber(attr(state.model, "MovingStateVelocityDeg", Config.MovingStateVelocityDeg)) or Config.MovingStateVelocityDeg)
	for _, leaf in state.leaves do
		if leaf.targetAngle ~= nil or math.abs(leaf.velocity) >= threshold then
			return true
		end
	end
	return false
end

local function refreshAssemblyPublicState(state: AssemblyState)
	local closed = allLeavesClosed(state)
	local open = assemblyActuallyOpen(state)
	local moving = assemblyMoving(state)
	local publicState: string
	if state.locked and closed then
		publicState = "Locked"
	elseif closed then
		publicState = "Closed"
	elseif moving then
		local closing = false
		for _, leaf in state.leaves do
			if leaf.targetAngle ~= nil and math.abs(leaf.targetAngle) < math.abs(leaf.angle) - math.rad(0.2) then
				closing = true
				break
			elseif leaf.mode == "Closing" or leaf.mode == "GuidedClose" or leaf.mode == "PromptClosing" or leaf.mode == "HeldForPlayer" then
				closing = true
				break
			end
		end
		publicState = if closing then "Closing" else "Opening"
	elseif open then
		publicState = "Open"
	else
		publicState = "Ajar"
	end

	if publicState ~= state.lastPublicState then
		state.lastPublicState = publicState
		state.stateRevision += 1
		writeAssemblyAttribute(state, "StateRevision", state.stateRevision)
		writeAssemblyAttribute(state, "LastStateChangeTime", workspace:GetServerTimeNow())
	end

	writeAssemblyAttribute(state, "Locked", state.locked or state.pendingLock)
	writeAssemblyAttribute(state, "Open", open)
	writeAssemblyAttribute(state, "Opened", open)
	writeAssemblyAttribute(state, "Closed", closed)
	writeAssemblyAttribute(state, "Moving", moving)
	writeAssemblyAttribute(state, "Opening", publicState == "Opening")
	writeAssemblyAttribute(state, "Closing", publicState == "Closing")
	writeAssemblyAttribute(state, "DoorState", publicState)
	writeAssemblyAttribute(state, "TargetState", state.targetState)

	-- Assembly Health is the lowest-integrity leaf, which makes it useful as a simple
	-- door-level readout while each LeafRig still exposes its exact Health value.
	local assemblyHealth = math.huge
	local assemblyHealthPercent = 1
	for _, leaf in state.leaves do
		local maxHealth = math.max(0, tonumber(setting(leaf.rig, state.model, "MaxHealth", Config.MaxHealth)) or Config.MaxHealth)
		assemblyHealth = math.min(assemblyHealth, math.max(0, leaf.health))
		local percent = if maxHealth > 0 then math.clamp(leaf.health / maxHealth, 0, 1) else 0
		assemblyHealthPercent = math.min(assemblyHealthPercent, percent)
	end
	if assemblyHealth == math.huge then assemblyHealth = 0 end
	writeAssemblyAttribute(state, "Health", assemblyHealth)
	writeAssemblyAttribute(state, "HealthPercent", assemblyHealthPercent)
end

local function connectAssemblyAttributeControls(state: AssemblyState)
	local assembly = state.model
	local function connect(name: string, callback: (any) -> ())
		table.insert(state.attributeConnections, assembly:GetAttributeChangedSignal(name):Connect(function()
			callback(assembly:GetAttribute(name))
		end))
	end
	local function clearStringRequest(name: string, handledValue: any)
		task.defer(function()
			if assembly.Parent and assembly:GetAttribute(name) == handledValue then
				assembly:SetAttribute(name, "")
			end
		end)
	end

	-- DoorState/Open/Closed/Locked/Health are public readbacks. Listening to those
	-- same attributes as commands is unsafe with Roblox's deferred signal behavior:
	-- a queued readback event can arrive after a newer value and recursively reverse
	-- the current command. Dedicated request attributes preserve attribute-driven
	-- integrations without making our own replication feed back into the service.
	connect("RequestedLocked", function(requested)
		if type(requested) == "boolean" then
			DoorService.SetLocked(assembly, requested, nil, true)
		end
	end)
	connect("RequestedState", function(requested)
		requested = tostring(requested or "")
		if requested ~= "" then
			DoorService.SetState(assembly, requested)
			clearStringRequest("RequestedState", requested)
		end
	end)
	connect("DoorCommand", function(requested)
		requested = tostring(requested or "")
		if requested ~= "" then
			DoorService.Command(assembly, requested)
			clearStringRequest("DoorCommand", requested)
		end
	end)
	connect("RequestedHealth", function(requested)
		requested = tonumber(requested)
		if requested ~= nil then
			DoorService.SetHealth(assembly, requested)
		end
	end)

	connect("MaxHealth", function(_requested)
		-- Live MaxHealth changes never silently heal; they only clamp current integrity.
		for _, leaf in state.leaves do
			local maxHealth = math.max(0, tonumber(setting(leaf.rig, assembly, "MaxHealth", Config.MaxHealth)) or Config.MaxHealth)
			if leaf.health > maxHealth then
				leaf.health = maxHealth
				setAttributeIfDifferent(leaf.rig, "Health", leaf.health)
			end
			setAttributeIfDifferent(leaf.rig, "HealthPercent", if maxHealth > 0 then math.clamp(leaf.health / maxHealth, 0, 1) else 0)
		end
		refreshAssemblyPublicState(state)
	end)
end

-- Curated, safe-to-author per-door settings. Publishing these defaults makes the
-- system self-documenting in Studio while preserving the exact Config behavior.
-- State/readout attributes (Open, Closed, Health, etc.) are intentionally excluded.
local DEFAULT_CONFIGURATION_ATTRIBUTES = table.freeze({
	"AutoClose",
	"AutoCloseDelay",
	"AutoCloseExtraHoldTime",
	"AutoCloseMinimumAngleDeg",
	"PromptEnabled",
	"PromptDistance",
	"PromptHoldDuration",
	"PromptHoldOpenTime",
	"PromptOpenAngleDeg",
	"PromptOpenMode",
	"PromptStackSpacing",
	"MaxAngleDeg",
	"OpenSign",
	"PushEnabled",
	"VirtualMass",
	"EffectivePlayerMass",
	"PushFollowVelocityScale",
	"SprintPushEnabled",
	"SprintPushMinSpeed",
	"SprintPushClosedAngleDeg",
	"SprintPushMinAngularSpeedDeg",
	"SprintPushMaxAngularSpeedDeg",
	"SprintPushBoostDuration",
	"SprintPushPlaysImpactSound",
	"SprintPushAddsKickShake",
	"SprintPushPredictionTime",
	"SprintPushSidePadding",
	"SprintPushLeadExtraGap",
	"SprintPushMaxLeadTime",
	"SprintPushMinNormalIntent",
	"MaxAngularSpeedDeg",
	"ReturnStiffness",
	"ReturnDamping",
	"SafetyEnabled",
	"HandleEnabled",
	"HandleAnimateBothSides",
	"WalkPushHandleEnabled",
	"WalkPushHandlePlaysSound",
	"HandlePressDeg",
	"HandleDoorDelay",
	"LockedHandleJiggleDeg",
	"LockedHandleJiggleDelay",
	"LockIndicatorEnabled",
	"LockIndicatorAxis",
	"LockIndicatorUnlockedDeg",
	"LockIndicatorLockedDeg",
	"LockIndicatorDamping",
	"LockIndicatorFrequency",
	"LockPromptEnabled",
	"AllowPlayerLocking",
	"LockType",
	"LockSide",
	"RequiredKeyId",
	"RequiredItemName",
	"RequiredItemCategory",
	"OpenRequiresItem",
	"LockPromptDistance",
	"KickPromptEnabled",
	"KickOnlyWhenLocked",
	"KickPromptDistance",
	"Breakable",
	"MaxHealth",
	"StartingHealth",
	"KickDamageMin",
	"KickDamageMax",
	"LockedAttemptAuthoritativeMotion",
	"LockedAttemptShakeDeg",
	"LockedAttemptShakeFrequency",
	"LockedAttemptShakeDamping",
	"LockedKickAuthoritativeMotion",
	"LockedKickShakeDeg",
	"LockedKickShakeFrequency",
	"LockedKickShakeDamping",
	"KickShakeDeg",
	"KickShakeFrequency",
	"KickShakeDamping",
	"AutoCloseAfterBreach",
	"ResetAfterBreak",
	"ResetDelay",
	"SoundEnabled",
	"ProvisionDefaultSounds",
	"DefaultSoundRollOffMinDistance",
	"DefaultSoundRollOffMaxDistance",
	"SoundPitchScale",
	"SoundVolumeScale",
	"CloseStartSoundMinAngleDeg",
	"SoundRandomNoImmediateRepeat",
	"SoundReplicationDistance",
	"AssemblyMotionSoundDedupWindow",
	"OpenSoundTriggerAngleDeg",
	"OpenSoundRearmAngleDeg",
	"ExternalOpenAngleDeg",
	"ExternalOpenSign",
})

local function publishDefaultConfigurationAttributes(assembly: Model)
	if Config.PublishDefaultConfigurationAttributes == false then
		return
	end
	for _, name in DEFAULT_CONFIGURATION_ATTRIBUTES do
		if assembly:GetAttribute(name) == nil and DoorAccess.GetSetting(assembly, nil, name, nil) == nil then
			local value = (Config :: any)[name]
			if value ~= nil then
				assembly:SetAttribute(name, value)
			end
		end
	end
end

local function migrateLegacyShakeDefaults(assembly: Model)
	-- Auto-published v7.5 values would otherwise survive an upgrade and hide the new
	-- tighter v7.7 defaults. Only migrate the exact old default triplets; any custom
	-- tuning, even one changed field, is preserved verbatim.
	local attemptDeg = tonumber(assembly:GetAttribute("LockedAttemptShakeDeg"))
	local attemptFreq = tonumber(assembly:GetAttribute("LockedAttemptShakeFrequency"))
	local attemptDamp = tonumber(assembly:GetAttribute("LockedAttemptShakeDamping"))
	if attemptDeg == 9.5 and attemptFreq == 24 and attemptDamp == 0.12 then
		assembly:SetAttribute("LockedAttemptShakeDeg", Config.LockedAttemptShakeDeg)
		assembly:SetAttribute("LockedAttemptShakeFrequency", Config.LockedAttemptShakeFrequency)
		assembly:SetAttribute("LockedAttemptShakeDamping", Config.LockedAttemptShakeDamping)
	end

	local kickDeg = tonumber(assembly:GetAttribute("LockedKickShakeDeg"))
	local kickFreq = tonumber(assembly:GetAttribute("LockedKickShakeFrequency"))
	local kickDamp = tonumber(assembly:GetAttribute("LockedKickShakeDamping"))
	if kickDeg == 16 and kickFreq == 23 and kickDamp == 0.12 then
		assembly:SetAttribute("LockedKickShakeDeg", Config.LockedKickShakeDeg)
		assembly:SetAttribute("LockedKickShakeFrequency", Config.LockedKickShakeFrequency)
		assembly:SetAttribute("LockedKickShakeDamping", Config.LockedKickShakeDamping)
	end
end

function DoorService.Register(assembly: Model): AssemblyState?
	if assemblies[assembly] then
		return assemblies[assembly]
	end

	-- v7.7 no longer exposes implementation versioning on door Attributes. Clean the
	-- legacy runtime attribute as doors register so upgraded doors do not keep showing it.
	if assembly:GetAttribute("DoorSystemVersion") ~= nil then
		assembly:SetAttribute("DoorSystemVersion", nil)
	end

	publishDefaultConfigurationAttributes(assembly)
	migrateLegacyShakeDefaults(assembly)
	provisionDefaultSounds(assembly)

	local initialOpenAttr = assembly:GetAttribute("Open")
	local initialOpenedAttr = assembly:GetAttribute("Opened")
	local initialClosedAttr = assembly:GetAttribute("Closed")
	local initialOpen = initialOpenAttr == true
		or initialOpenedAttr == true
		or assembly:GetAttribute("Opening") == true
		or initialClosedAttr == false
	local initialClosed = initialClosedAttr == true
		or assembly:GetAttribute("Closing") == true
		or initialOpenAttr == false
		or initialOpenedAttr == false
	local initialDoorState = string.lower(tostring(assembly:GetAttribute("DoorState") or ""))

	local state: AssemblyState = {
		model = assembly,
		leaves = {},
		locked = attr(assembly, "Locked", false) == true,
		pendingLock = false,
		registered = true,
		attributeConnections = {},
		lastPublishedAttributes = {},
		stableClosed = true,
		stableOpen = false,
		targetState = if attr(assembly, "Locked", false) == true then "Locked" else "Closed",
		lastPublicState = "",
		stateRevision = 0,
		lastMotionAudioAt = {},
	}
	assemblies[assembly] = state

	for _, leafRig in resolveLeafRigs(assembly) do
		local leaf = registerLeaf(state, leafRig)
		if leaf then
			table.insert(state.leaves, leaf)
		end
	end

	if #state.leaves == 0 then
		assemblies[assembly] = nil
		warn(("[DoorService] No valid leaf rigs under %s"):format(assembly:GetFullName()))
		return nil
	end

	if assembly:GetAttribute("Breached") == nil then
		assembly:SetAttribute("Breached", false)
	end
	if assembly:GetAttribute("LockBroken") == nil then
		assembly:SetAttribute("LockBroken", false)
	end
	-- Visible, reusable live-control fields for designers. String commands reset to
	-- blank after handling, so entering the same command twice still fires twice.
	if assembly:GetAttribute("DoorCommand") == nil then assembly:SetAttribute("DoorCommand", "") end
	if assembly:GetAttribute("RequestedState") == nil then assembly:SetAttribute("RequestedState", "") end
	connectAssemblyAttributeControls(state)
	refreshAssemblyPublicState(state)
	updatePromptText(state)

	-- Honor authored initial state attributes after registration. Locked has precedence.
	if not state.locked then
		if initialOpen or initialDoorState == "open" or initialDoorState == "opened" or initialDoorState == "opening" then
			task.defer(function() if assembly.Parent then DoorService.Open(assembly) end end)
		elseif initialClosed or initialDoorState == "closed" or initialDoorState == "close" or initialDoorState == "closing" then
			task.defer(function() if assembly.Parent then DoorService.Close(assembly) end end)
		end
	end
	return state
end

function DoorService.Unregister(assembly: Model)
	local state = assemblies[assembly]
	if not state then
		return
	end
	for _, connection in state.attributeConnections do
		connection:Disconnect()
	end
	table.clear(state.attributeConnections)
	pendingLockAssemblies[state] = nil
	for _, leaf in state.leaves do
		activeLeaves[leaf] = nil
		removeLeafFromSpatialHash(leaf)
		leafByRig[leaf.rig] = nil
	end
	assemblies[assembly] = nil
end

local function virtualInertia(leaf: LeafState): number
	local mass = tonumber(setting(leaf.rig, leaf.assembly, "VirtualMass", Config.VirtualMass)) or Config.VirtualMass
	local width = math.max(0.5, leaf.collision.Size.X)
	-- Thin rectangular door rotating about a vertical edge: I = 1/3 m w^2.
	return math.max(0.05, (mass * width * width) / 3)
end

local function playerIsSprinting(player: Player): boolean
	local characterValues = player.Character and player.Character:FindFirstChild("Values")
	local sprintFolder = characterValues and characterValues:FindFirstChild("SprintHandler")
	local sprintValue = sprintFolder and sprintFolder:FindFirstChild("Sprinting")
	return sprintValue ~= nil and sprintValue:IsA("BoolValue") and sprintValue.Value == true
end

local function computePushContact(
	leaf: LeafState,
	position: Vector3,
	movement: Vector3,
	moveDirection: Vector3,
	strictContact: boolean,
	sprintApproach: boolean?
): (boolean, number, number, number, number)
	local movePlanar = movement * Vector3.new(1, 0, 1)
	local intentPlanar = moveDirection * Vector3.new(1, 0, 1)
	local pushMinimumSpeed = tonumber(setting(leaf.rig, leaf.assembly, "PushMinimumSpeed", Config.PushMinimumSpeed)) or Config.PushMinimumSpeed
	local pushFallbackWalkSpeed = tonumber(setting(leaf.rig, leaf.assembly, "PushFallbackWalkSpeed", Config.PushFallbackWalkSpeed)) or Config.PushFallbackWalkSpeed
	local pushLeadExtraGap = tonumber(setting(leaf.rig, leaf.assembly, "PushLeadExtraGap", Config.PushLeadExtraGap)) or Config.PushLeadExtraGap
	if intentPlanar.Magnitude <= 0.05 then
		intentPlanar = movePlanar
	end
	if movePlanar.Magnitude < pushMinimumSpeed and intentPlanar.Magnitude > 0.05 then
		movePlanar = intentPlanar.Unit * math.max(pushFallbackWalkSpeed, pushMinimumSpeed)
	end
	if movePlanar.Magnitude < pushMinimumSpeed or intentPlanar.Magnitude <= 0.05 then
		return false, 0, 0, 0, 0
	end

	local cf = getCollisionPose(leaf, leaf.angle)
	local half = leaf.collision.Size * 0.5
	local predictionTime = tonumber(setting(leaf.rig, leaf.assembly, "ContactPredictionTime", Config.ContactPredictionTime)) or Config.ContactPredictionTime
	local sidePadding = tonumber(setting(leaf.rig, leaf.assembly, "ContactSidePadding", Config.ContactSidePadding)) or Config.ContactSidePadding
	local heightPadding = tonumber(setting(leaf.rig, leaf.assembly, "ContactHeightPadding", Config.ContactHeightPadding)) or Config.ContactHeightPadding
	local contactGap = tonumber(setting(leaf.rig, leaf.assembly, "PushContactSurfaceGap", Config.PushContactSurfaceGap)) or Config.PushContactSurfaceGap
	local maxLeadTime = tonumber(setting(leaf.rig, leaf.assembly, "PushMaxLeadTime", Config.PushMaxLeadTime)) or Config.PushMaxLeadTime
	if sprintApproach then
		predictionTime = math.max(predictionTime, tonumber(setting(leaf.rig, leaf.assembly, "SprintPushPredictionTime", Config.SprintPushPredictionTime)) or Config.SprintPushPredictionTime)
		sidePadding = math.max(sidePadding, tonumber(setting(leaf.rig, leaf.assembly, "SprintPushSidePadding", Config.SprintPushSidePadding)) or Config.SprintPushSidePadding)
		pushLeadExtraGap = math.max(pushLeadExtraGap, tonumber(setting(leaf.rig, leaf.assembly, "SprintPushLeadExtraGap", Config.SprintPushLeadExtraGap)) or Config.SprintPushLeadExtraGap)
		maxLeadTime = math.max(maxLeadTime, tonumber(setting(leaf.rig, leaf.assembly, "SprintPushMaxLeadTime", Config.SprintPushMaxLeadTime)) or Config.SprintPushMaxLeadTime)
	end

	local currentLocal = cf:PointToObjectSpace(position)
	local futureLocal = cf:PointToObjectSpace(position + movePlanar * predictionTime)
	local localVelocity = cf:VectorToObjectSpace(movePlanar)
	local localIntent = cf:VectorToObjectSpace(intentPlanar.Unit)

	local lateralOk = math.abs(currentLocal.X) <= half.X + sidePadding
		or math.abs(futureLocal.X) <= half.X + sidePadding
	local heightOk = math.abs(currentLocal.Y) <= half.Y + heightPadding
		or math.abs(futureLocal.Y) <= half.Y + heightPadding
	if not lateralOk or not heightOk then
		return false, 0, 0, 0, 0
	end

	local surfaceGap = math.max(0, math.abs(currentLocal.Z) - half.Z)
	local futureGap = math.max(0, math.abs(futureLocal.Z) - half.Z)
	local normalIntent = math.abs(localIntent.Z)
	local normalSpeed = math.max(math.abs(localVelocity.Z), movePlanar.Magnitude * normalIntent * 0.72)
	local minNormalIntent = tonumber(setting(leaf.rig, leaf.assembly, "SprintPushMinNormalIntent", Config.SprintPushMinNormalIntent)) or Config.SprintPushMinNormalIntent
	local movingToward = currentLocal.Z * localIntent.Z < (if sprintApproach then -0.006 else -0.018)
		and (not sprintApproach or normalIntent >= minNormalIntent)
	local timeToSurface = if normalSpeed > 0.05 then surfaceGap / normalSpeed else math.huge
	local touchingRange = surfaceGap <= contactGap
	local imminent = timeToSurface <= maxLeadTime
		and futureGap < surfaceGap
		and surfaceGap <= contactGap + pushLeadExtraGap

	-- `strictContact` still permits a very short predictive window. This is not a
	-- proximity trigger: the player must be moving into the CURRENT slab and be on a
	-- trajectory that reaches it within PushMaxLeadTime. The predictive portion is
	-- intentionally weak; full torque only arrives at body-contact range.
	local accepted = touchingRange or imminent
	if not movingToward or not accepted then
		return false, 0, 0, 0, 0
	end

	local contactFactor = 1.0
	if not touchingRange then
		local leadAlpha = math.clamp(1 - (timeToSurface / math.max(maxLeadTime, 1e-3)), 0, 1)
		contactFactor = (tonumber(setting(leaf.rig, leaf.assembly, "PreContactDriveScale", Config.PreContactDriveScale)) or Config.PreContactDriveScale)
			* (0.55 + 0.45 * leadAlpha)
	else
		-- Ramp from a soft body-contact edge to full pressure as the root gets closer.
		local depth = math.clamp((contactGap - surfaceGap) / math.max(contactGap * 0.55, 0.15), 0, 1)
		contactFactor = 0.62 + 0.38 * depth
	end

	-- Direction is derived from the player's CURRENT side of the CURRENT rotated slab,
	-- not from a cached prompt direction and not from tangential movement noise. The
	-- player therefore always drives the leaf AWAY from the side they are standing on.
	-- This remains correct after prompt opens, partial opens, reversals, and opposite-side
	-- multiplayer pushes. Movement speed still controls strength; side controls sign.
	local contactLocal = Vector3.new(
		math.clamp(currentLocal.X, -half.X, half.X),
		math.clamp(currentLocal.Y, -half.Y, half.Y),
		0
	)
	local contactWorld = cf:PointToWorldSpace(contactLocal)
	local hingeAxis = leaf.hinge.CFrame.UpVector
	local radius = contactWorld - leaf.hinge.Position
	local planarRadius = radius - hingeAxis * radius:Dot(hingeAxis)
	local sideSign = if currentLocal.Z >= 0 then 1 else -1
	local normalForce = -cf.ZVector * sideSign -- from player side through the slab
	local torquePerUnitForce = hingeAxis:Dot(planarRadius:Cross(normalForce))
	local width = math.max(0.5, leaf.collision.Size.X)
	local minimumLever = width * (tonumber(setting(leaf.rig, leaf.assembly, "MinimumPushLeverFraction", Config.MinimumPushLeverFraction)) or Config.MinimumPushLeverFraction)
	local torqueSign = if torquePerUnitForce < 0 then -1 else 1
	if math.abs(torquePerUnitForce) < 1e-4 then
		-- Extremely close to the hinge: use an explicit normal-force sign fallback.
		torqueSign = torqueSignFromForce(leaf, contactWorld, normalForce)
	end
	local signedLever = torqueSign * math.max(math.abs(torquePerUnitForce), minimumLever)

	return true, signedLever, normalSpeed, surfaceGap, contactFactor
end

local function applyPlayerPush(leaf: LeafState, sample: PlayerSample, dt: number, clientAssisted: boolean?): boolean
	local state = assemblies[leaf.assembly]
	if not state or state.locked or leaf.broken then
		return false
	end
	if not setting(leaf.rig, leaf.assembly, "PushEnabled", Config.PushEnabled) then
		return false
	end
	if leaf.targetAngle ~= nil and isHighPriorityGuidedMode(leaf.mode) then
		return false
	end

	local movement = sample.velocity * Vector3.new(1, 0, 1)
	local moveDirection = sample.moveDirection * Vector3.new(1, 0, 1)
	if moveDirection.Magnitude > 0.05 then
		-- The server still derives this entirely from authoritative character state.
		-- Preserve movement intent when contact with the solid slab has already reduced
		-- measured velocity, otherwise a fast approach can be rejected until a later scan.
		local intentFraction = tonumber(setting(leaf.rig, leaf.assembly, "PushIntentSpeedFraction", Config.PushIntentSpeedFraction)) or Config.PushIntentSpeedFraction
		local maxEffectiveSpeed = tonumber(setting(leaf.rig, leaf.assembly, "PushMaxEffectiveSpeed", Config.PushMaxEffectiveSpeed)) or Config.PushMaxEffectiveSpeed
		local intendedSpeed = math.min(maxEffectiveSpeed, math.max(0, sample.humanoid.WalkSpeed * intentFraction))
		if movement.Magnitude < intendedSpeed then
			movement = moveDirection.Unit * intendedSpeed
		end
	end
	local isSprinting = playerIsSprinting(sample.player)
	local sprintMinSpeed = tonumber(setting(leaf.rig, leaf.assembly, "SprintPushMinSpeed", Config.SprintPushMinSpeed)) or Config.SprintPushMinSpeed
	local sprintApproach = isSprinting or movement.Magnitude >= sprintMinSpeed
	local accepted, signedLever, normalSpeed, surfaceGap, contactFactor = computePushContact(leaf, sample.position, movement, moveDirection, clientAssisted == true, sprintApproach)
	if not accepted then
		return false
	end
	local interruptingClose = leaf.mode == "Closing" or leaf.mode == "HeldForPlayer"

	local inertia = virtualInertia(leaf)
	local effectivePlayerMass = tonumber(setting(leaf.rig, leaf.assembly, "EffectivePlayerMass", Config.EffectivePlayerMass)) or Config.EffectivePlayerMass
	local impulseScale = tonumber(setting(leaf.rig, leaf.assembly, "PushImpulseScale", Config.PushImpulseScale)) or Config.PushImpulseScale
	local continuousScale = tonumber(setting(leaf.rig, leaf.assembly, "ContinuousPushScale", Config.ContinuousPushScale)) or Config.ContinuousPushScale
	local now = os.clock()
	local retrigger = tonumber(setting(leaf.rig, leaf.assembly, "ContactRetriggerTime", Config.ContactRetriggerTime)) or Config.ContactRetriggerTime
	local lastContact = leaf.contacts[sample.player] or -math.huge
	local firstContact = now - lastContact >= retrigger
	leaf.contacts[sample.player] = now

	-- Walking into a CLOSED unlocked door now visually depresses the handle once before
	-- the leaf swings. It is deliberately tied to validated push contact, so proximity
	-- alone can never animate the handle.
	local walkHandleEnabled = setting(leaf.rig, leaf.assembly, "WalkPushHandleEnabled", Config.WalkPushHandleEnabled) ~= false
	local handleEnabled = setting(leaf.rig, leaf.assembly, "HandleEnabled", Config.HandleEnabled) ~= false
	local walkClosedAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "WalkPushHandleClosedAngleDeg", Config.WalkPushHandleClosedAngleDeg)) or Config.WalkPushHandleClosedAngleDeg)
	local walkMinSpeed = tonumber(setting(leaf.rig, leaf.assembly, "WalkPushHandleMinSpeed", Config.WalkPushHandleMinSpeed)) or Config.WalkPushHandleMinSpeed
	local walkMaxDoorSpeed = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "WalkPushHandleMaxDoorSpeedDeg", Config.WalkPushHandleMaxDoorSpeedDeg)) or Config.WalkPushHandleMaxDoorSpeedDeg)
	local walkCooldown = tonumber(setting(leaf.rig, leaf.assembly, "WalkPushHandleCooldown", Config.WalkPushHandleCooldown)) or Config.WalkPushHandleCooldown
	if walkHandleEnabled and handleEnabled and leaf.walkPushHandleArmed
		and math.abs(leaf.angle) <= walkClosedAngle
		and math.abs(leaf.velocity) <= walkMaxDoorSpeed
		and normalSpeed >= walkMinSpeed
		and now - leaf.lastWalkPushHandleAt >= walkCooldown
	then
		leaf.walkPushHandleArmed = false
		leaf.lastWalkPushHandleAt = now
		broadcastAction(leaf, "Handle", {side = playerSideForLeaf(leaf, sample.player), source = "WalkPush"})
		if setting(leaf.rig, leaf.assembly, "WalkPushHandlePlaysSound", Config.WalkPushHandlePlaysSound) == true then
			playSound(leaf, Config.SoundNames.Handle)
		end
	end

	local sign = if signedLever >= 0 then 1 else -1
	local lever = math.abs(signedLever)
	if interruptingClose and leaf.velocity * sign < 0 then
		-- A validated push owns the leaf now. Remove the automatic return's opposing
		-- momentum so the door begins responding away from the player immediately.
		leaf.velocity = 0
	end
	local currentCF = getCollisionPose(leaf, leaf.angle)
	local moveIntent = sample.moveDirection * Vector3.new(1, 0, 1)
	local intendedNormalSpeed = if moveIntent.Magnitude > 0.05
		then sample.humanoid.WalkSpeed * math.abs(currentCF.LookVector:Dot(moveIntent.Unit))
		else 0
	local approachSpeed = math.max(normalSpeed, intendedNormalSpeed, if isSprinting then sample.humanoid.WalkSpeed else 0)
	local sprintClosedAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "SprintPushClosedAngleDeg", Config.SprintPushClosedAngleDeg)) or Config.SprintPushClosedAngleDeg)
	local sprintLaunch = firstContact
		and setting(leaf.rig, leaf.assembly, "SprintPushEnabled", Config.SprintPushEnabled) ~= false
		and (isSprinting or approachSpeed >= sprintMinSpeed)
		and math.abs(leaf.angle) <= sprintClosedAngle
	if sprintLaunch then
		local minLaunch = tonumber(setting(leaf.rig, leaf.assembly, "SprintPushMinAngularSpeedDeg", Config.SprintPushMinAngularSpeedDeg)) or Config.SprintPushMinAngularSpeedDeg
		local maxLaunch = tonumber(setting(leaf.rig, leaf.assembly, "SprintPushMaxAngularSpeedDeg", Config.SprintPushMaxAngularSpeedDeg)) or Config.SprintPushMaxAngularSpeedDeg
		local speedScale = math.clamp(approachSpeed / math.max(sprintMinSpeed, 0.01), 1, 1.35)
		local launchedSpeed = math.min(maxLaunch, math.max(math.deg(leaf.velocity) * sign, minLaunch * speedScale))
		leaf.velocity = sign * math.rad(launchedSpeed)
		leaf.kickBoostUntil = now + (tonumber(setting(leaf.rig, leaf.assembly, "SprintPushBoostDuration", Config.SprintPushBoostDuration)) or Config.SprintPushBoostDuration)
		if setting(leaf.rig, leaf.assembly, "SprintPushPlaysImpactSound", Config.SprintPushPlaysImpactSound) ~= false then
			playSoundFallback(leaf, Config.SoundNames.KickAttempt, Config.SoundNames.Kick)
		end
		if setting(leaf.rig, leaf.assembly, "SprintPushAddsKickShake", Config.SprintPushAddsKickShake) ~= false then
			broadcastAction(leaf, "Kick", {side = playerSideForLeaf(leaf, sample.player), sign = sign, locked = false, breaching = false})
		end
	elseif firstContact then
		-- Tiny acquisition nudge only. Sustained torque does the real work, which keeps
		-- the door from behaving like an automatic proximity door.
		local deltaOmega = (effectivePlayerMass * normalSpeed * lever / inertia) * impulseScale * contactFactor
		local strongGap = tonumber(setting(leaf.rig, leaf.assembly, "StrongContactSurfaceGap", Config.StrongContactSurfaceGap)) or Config.StrongContactSurfaceGap
		local maxInitialDeg = tonumber(setting(leaf.rig, leaf.assembly, "InitialPushMaxAngularSpeedDeg", Config.InitialPushMaxAngularSpeedDeg)) or Config.InitialPushMaxAngularSpeedDeg
		if surfaceGap > strongGap then
			maxInitialDeg = tonumber(setting(leaf.rig, leaf.assembly, "PreContactInitialPushMaxAngularSpeedDeg", Config.PreContactInitialPushMaxAngularSpeedDeg)) or Config.PreContactInitialPushMaxAngularSpeedDeg
		end
		local maxInitial = math.rad(maxInitialDeg)
		leaf.velocity += sign * math.min(math.abs(deltaOmega), maxInitial)
	else
		local angularAccel = (effectivePlayerMass * normalSpeed * lever / inertia) * continuousScale * contactFactor * sign
		leaf.velocity += angularAccel * dt
	end

	leaf.targetAngle = nil
	leaf.mode = "Pushed"
	leaf.lastPushTime = now
	leaf.holdUntil = 0
	-- Do NOT arm the jamb/Close cue merely because a new push was accepted.
	-- A weak first contact can still be inside the latch/snap zone for one frame; if
	-- Close were armed here, completeClose() could immediately replay Close beside
	-- the freshly-started Open sound. The integration loop arms Close only after the
	-- leaf has genuinely departed past CloseSeatSoundRearmAngleDeg.

	-- For walk-through opening, validated contact is the reliable start-of-cycle event.
	-- Waiting for a later angle threshold was race-prone when the player reversed the
	-- leaf immediately after its jamb sound. Closed/Seat re-arm Open; the first accepted
	-- push consumes it exactly once.
	local pushOpenAudioZone = math.rad((tonumber(setting(
		leaf.rig,
		leaf.assembly,
		"CloseSeatSoundAngleDeg",
		Config.CloseSeatSoundAngleDeg
	)) or Config.CloseSeatSoundAngleDeg) + 0.35)
	if leaf.openSoundArmed and math.abs(leaf.angle) <= pushOpenAudioZone then
		markAudioPhase(leaf, "Opening", Config.SoundNames.Open, Config.SoundNames.Creak, 1, true)
	end

	updateLeafPromptText(state, leaf)
	setActive(leaf)
	return true
end

local function applyActivePushDrivers(leaf: LeafState, dt: number, now: number): boolean
	if leaf.broken then
		table.clear(leaf.drivers)
		return false
	end
	local state = assemblies[leaf.assembly]
	if not state or state.locked or not setting(leaf.rig, leaf.assembly, "PushEnabled", Config.PushEnabled) then
		table.clear(leaf.drivers)
		return false
	end

	if leaf.targetAngle ~= nil and isHighPriorityGuidedMode(leaf.mode) then
		table.clear(leaf.drivers)
		return false
	end

	local totalAngularAccel = 0
	local hasDrive = false

	for player, driver in leaf.drivers do
		if now > driver.expiresAt then
			leaf.drivers[player] = nil
			continue
		end

		local root, humanoid = rootCharacter(player)
		if not root or not humanoid then
			leaf.drivers[player] = nil
			continue
		end

		local maxDistance = tonumber(setting(leaf.rig, leaf.assembly, "MaxPushDistanceFromHinge", Config.MaxPushDistanceFromHinge)) or Config.MaxPushDistanceFromHinge
		local maxDistanceWithPadding = maxDistance + 1.25
		local hingeDelta = root.Position - leaf.hinge.Position
		if hingeDelta:Dot(hingeDelta) > maxDistanceWithPadding * maxDistanceWithPadding then
			leaf.drivers[player] = nil
			continue
		end

		local movement = root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
		local moveDirection = humanoid.MoveDirection * Vector3.new(1, 0, 1)
		local sprintMinSpeed = tonumber(setting(leaf.rig, leaf.assembly, "SprintPushMinSpeed", Config.SprintPushMinSpeed)) or Config.SprintPushMinSpeed
		local sprintApproach = playerIsSprinting(player) or movement.Magnitude >= sprintMinSpeed
		local accepted, signedLever, normalSpeed, _, contactFactor = computePushContact(leaf, root.Position, movement, moveDirection, true, sprintApproach)
		if not accepted then
			continue
		end

		local inertia = virtualInertia(leaf)
		local effectivePlayerMass = tonumber(setting(leaf.rig, leaf.assembly, "EffectivePlayerMass", Config.EffectivePlayerMass)) or Config.EffectivePlayerMass
		local response = tonumber(setting(leaf.rig, leaf.assembly, "PushDriveResponse", Config.PushDriveResponse)) or Config.PushDriveResponse
		local maxAccel = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "PushDriveMaxAccelerationDeg", Config.PushDriveMaxAccelerationDeg)) or Config.PushDriveMaxAccelerationDeg)

		-- Keep the approach energy for a short time after collision contact. Roblox can
		-- reduce AssemblyLinearVelocity sharply when the avatar hits an anchored slab;
		-- without this, sprinting could push less strongly than walking.
		local currentCF = getCollisionPose(leaf, leaf.angle)
		local intentPlanar = moveDirection * Vector3.new(1, 0, 1)
		local intentNormalSpeed = 0
		if intentPlanar.Magnitude > 0.05 then
			intentNormalSpeed = humanoid.WalkSpeed * math.abs(currentCF.LookVector:Dot(intentPlanar.Unit))
		end
		local memoryDecay = tonumber(setting(leaf.rig, leaf.assembly, "PushSpeedMemoryDecay", Config.PushSpeedMemoryDecay)) or Config.PushSpeedMemoryDecay
		local rememberedSpeed = driver.peakNormalSpeed * math.exp(-math.max(0, now - driver.lastRefreshAt) * memoryDecay)
		local intentFraction = tonumber(setting(leaf.rig, leaf.assembly, "PushIntentSpeedFraction", Config.PushIntentSpeedFraction)) or Config.PushIntentSpeedFraction
		local maxEffectiveSpeed = tonumber(setting(leaf.rig, leaf.assembly, "PushMaxEffectiveSpeed", Config.PushMaxEffectiveSpeed)) or Config.PushMaxEffectiveSpeed
		local effectiveNormalSpeed = math.min(maxEffectiveSpeed, math.max(normalSpeed, rememberedSpeed, intentNormalSpeed * intentFraction))

		local sign = if signedLever >= 0 then 1 else -1
		local lever = math.max(math.abs(signedLever), 0.35)
		local angularAccel = (effectivePlayerMass * effectiveNormalSpeed * lever / inertia) * response * contactFactor
		angularAccel = math.min(angularAccel, maxAccel)

		-- Velocity-follow assist: a swinging rigid door needs angular speed ~= linear
		-- contact speed / lever radius to actually get out of a sprinting player's way.
		-- This keeps fast movement feeling fast instead of hitting the same half-open wall.
		local followScale = tonumber(setting(leaf.rig, leaf.assembly, "PushFollowVelocityScale", Config.PushFollowVelocityScale)) or Config.PushFollowVelocityScale
		local followResponse = tonumber(setting(leaf.rig, leaf.assembly, "PushFollowVelocityResponse", Config.PushFollowVelocityResponse)) or Config.PushFollowVelocityResponse
		local followMin = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "PushFollowMinAngularSpeedDeg", Config.PushFollowMinAngularSpeedDeg)) or Config.PushFollowMinAngularSpeedDeg)
		local followMax = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "PushFollowMaxAngularSpeedDeg", Config.PushFollowMaxAngularSpeedDeg)) or Config.PushFollowMaxAngularSpeedDeg)
		local followMaxAccel = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "PushFollowMaxAccelerationDeg", Config.PushFollowMaxAccelerationDeg)) or Config.PushFollowMaxAccelerationDeg)
		local desiredOmegaMag = math.clamp((effectiveNormalSpeed / lever) * followScale, followMin, followMax)
		local desiredOmega = sign * desiredOmegaMag
		local followAccel = math.clamp((desiredOmega - leaf.velocity) * followResponse, -followMaxAccel, followMaxAccel)

		local rampTime = math.max(0.001, tonumber(setting(leaf.rig, leaf.assembly, "PushDriveRampTime", Config.PushDriveRampTime)) or Config.PushDriveRampTime)
		local ramp = math.clamp((now - driver.startedAt) / rampTime, 0, 1)
		totalAngularAccel += (angularAccel * sign + followAccel) * ramp
		hasDrive = true
	end

	-- Collision remains solid. `effectiveDrive` only means the player is currently
	-- contributing useful torque; it is no longer permission to disable collision.
	local effectiveDrive = hasDrive and math.abs(totalAngularAccel) > math.rad(0.25)
	if hasDrive then
		leaf.targetAngle = nil
		leaf.mode = "Pushed"
		leaf.lastPushTime = now
		leaf.holdUntil = 0
		leaf.closeSoundArmed = true
		leaf.velocity += totalAngularAccel * dt
		setActive(leaf)
	end
	return effectiveDrive
end

local function scanPlayerPushes(dt: number)
	refreshPlayerSamples()
	for leaf in activeLeaves do
		if not leaf.rig.Parent then
			activeLeaves[leaf] = nil
		end
	end

	local cell = Config.SpatialCellSize
	for _, sample in playerSamples do
		local cx = math.floor(sample.position.X / cell)
		local cz = math.floor(sample.position.Z / cell)
		for x = cx - 1, cx + 1 do
			for z = cz - 1, cz + 1 do
				local bucket = spatialBuckets[`{x}:{z}`]
				if bucket then
					for leaf in bucket do
						if not leaf.broken and leaf.rig.Parent then
							local maxDistance = tonumber(setting(leaf.rig, leaf.assembly, "MaxPushDistanceFromHinge", Config.MaxPushDistanceFromHinge)) or Config.MaxPushDistanceFromHinge
							local hingeDelta = sample.position - leaf.hinge.Position
							if hingeDelta:Dot(hingeDelta) <= maxDistance * maxDistance then
								applyPlayerPush(leaf, sample, dt)
							end
						end
					end
				end
			end
		end
	end
end

-- Fast local contact path. The client does NOT send force/angle values; it only
-- names the leaf. This handler rebuilds a fresh PlayerSample from authoritative
-- character state and runs the exact same rigid-body impulse calculation.
local clientPushRate: {[Player]: {[Model]: number}} = {}

local function handleClientPush(player: Player, rig: Instance)
	if not rig:IsA("Model") then
		return
	end
	local leaf = leafByRig[rig]
	if not leaf or leaf.broken or not leaf.rig.Parent then
		return
	end
	local state = assemblies[leaf.assembly]
	if not state or state.locked then
		return
	end

	local root, humanoid = rootCharacter(player)
	if not root or not humanoid then
		return
	end
	local maxDistance = tonumber(setting(leaf.rig, leaf.assembly, "MaxPushDistanceFromHinge", Config.MaxPushDistanceFromHinge)) or Config.MaxPushDistanceFromHinge
	local maxDistanceWithPadding = maxDistance + 1.0
	local hingeDelta = root.Position - leaf.hinge.Position
	if hingeDelta:Dot(hingeDelta) > maxDistanceWithPadding * maxDistanceWithPadding then
		return
	end

	local now = os.clock()
	local perPlayer = clientPushRate[player]
	if not perPlayer then
		perPlayer = {}
		clientPushRate[player] = perPlayer
	end
	local last = perPlayer[rig] or -math.huge
	if now - last < 0.045 then
		return
	end
	perPlayer[rig] = now

	local position = root.Position
	local previous = playerPositionHistory[player] or position
	local sample: PlayerSample = {
		player = player,
		root = root,
		humanoid = humanoid,
		position = position,
		previousPosition = previous,
		velocity = root.AssemblyLinearVelocity,
		moveDirection = humanoid.MoveDirection,
	}

	-- Crucially, do NOT create a sustained drive merely because the client named a
	-- nearby door. The same strict contact test must pass first. This is what fixes
	-- proximity alone must never create a sustained push drive.
	local accepted = applyPlayerPush(leaf, sample, 1 / math.max(1, Config.PlayerScanHz), true)
	if accepted then
		local grace = tonumber(setting(leaf.rig, leaf.assembly, "PushIntentGrace", Config.PushIntentGrace)) or Config.PushIntentGrace
		local previousDriver = leaf.drivers[player]
		local startedAt = now
		if previousDriver and now <= previousDriver.expiresAt + 0.06 then
			startedAt = previousDriver.startedAt
		end

		local currentCF = getCollisionPose(leaf, leaf.angle)
		local planarVelocity = root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
		local planarIntent = humanoid.MoveDirection * Vector3.new(1, 0, 1)
		local measuredNormal = math.abs(currentCF.LookVector:Dot(planarVelocity))
		local intendedNormal = 0
		if planarIntent.Magnitude > 0.05 then
			intendedNormal = humanoid.WalkSpeed * math.abs(currentCF.LookVector:Dot(planarIntent.Unit))
		end
		local approachSpeed = math.max(measuredNormal, intendedNormal)
		local previousPeak = if previousDriver then previousDriver.peakNormalSpeed else 0

		leaf.drivers[player] = {
			expiresAt = now + grace,
			startedAt = startedAt,
			lastRefreshAt = now,
			peakNormalSpeed = math.max(approachSpeed, previousPeak * 0.82),
		}
		setActive(leaf)
	end
end

pushEvent.OnServerEvent:Connect(handleClientPush)
Players.PlayerRemoving:Connect(function(player)
	clientPushRate[player] = nil
	playerPositionHistory[player] = nil
end)

local function pointInsideCollisionAtAngle(leaf: LeafState, angle: number, worldPoint: Vector3, padding: number): boolean
	local cf = getCollisionPose(leaf, angle)
	local p = cf:PointToObjectSpace(worldPoint)
	local half = leaf.collision.Size * 0.5
	return math.abs(p.X) <= half.X + padding
		and math.abs(p.Y) <= half.Y + padding * 0.65
		and math.abs(p.Z) <= half.Z + padding
end

local function isPlayerInDoorway(leaf: LeafState, sample: PlayerSample): boolean
	local padding = tonumber(setting(leaf.rig, leaf.assembly, "SafetyPadding", Config.SafetyPadding)) or Config.SafetyPadding
	local p = leaf.closedCollisionCF:PointToObjectSpace(sample.position)
	local half = leaf.collision.Size * 0.5
	local depth = half.Z + padding + 0.55
	return math.abs(p.X) <= half.X + padding
		and math.abs(p.Y) <= half.Y + padding * 0.7
		and math.abs(p.Z) <= depth
end

local function angleObstructed(leaf: LeafState, angle: number): boolean
	local padding = tonumber(setting(leaf.rig, leaf.assembly, "SafetyPadding", Config.SafetyPadding)) or Config.SafetyPadding
	local now = os.clock()
	for _, sample in playerSamples do
		if leaf.safetyIgnorePlayer == sample.player and now < leaf.safetyIgnoreUntil then
			continue
		end
		if pointInsideCollisionAtAngle(leaf, angle, sample.position, padding)
			or pointInsideCollisionAtAngle(leaf, angle, sample.previousPosition, padding * 0.9)
		then
			return true
		end
	end
	return false
end

local function closingSweepObstructed(leaf: LeafState, fromAngle: number, candidateAngle: number): boolean
	if not setting(leaf.rig, leaf.assembly, "SafetyEnabled", Config.SafetyEnabled) then
		return false
	end
	if math.abs(candidateAngle) >= math.abs(fromAngle) - math.rad(0.01) then
		return false
	end

	local lookAhead = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "SafetyLookAheadDeg", Config.SafetyLookAheadDeg)) or Config.SafetyLookAheadDeg)
	local samples = math.max(1, math.floor(tonumber(setting(leaf.rig, leaf.assembly, "SafetySamples", Config.SafetySamples)) or Config.SafetySamples))
	local sign = signNonZero(fromAngle)
	local lookAngle = sign * math.max(0, math.abs(candidateAngle) - lookAhead)

	for i = 1, samples do
		local alpha = i / samples
		local testAngle = candidateAngle + (lookAngle - candidateAngle) * alpha
		if angleObstructed(leaf, testAngle) then
			return true
		end
	end
	return angleObstructed(leaf, candidateAngle)
end

local function updateHybridCollision(leaf: LeafState, state: AssemblyState, _now: number, _drivenByPlayer: boolean)
	-- Normal hinged doors are ALWAYS physically solid. Previous builds disabled the
	-- slab during pushes/opening to hide latency, which let avatars phase through the
	-- leaf before it had actually swung away. Responsiveness is now provided by
	-- predictive torque + client/server hinge reconstruction instead.
	local enabled = not leaf.broken
	leaf.collisionEnabled = enabled
	if leaf.collision.Parent and leaf.collision.CanCollide ~= enabled then
		leaf.collision.CanCollide = enabled
	end
end

local function refreshOccupancy()
	local now = os.clock()
	for leaf in activeLeaves do
		if leaf.broken or not setting(leaf.rig, leaf.assembly, "SafetyEnabled", Config.SafetyEnabled) then
			leaf.occupied = false
			continue
		end
		local occupied = false
		for _, sample in playerSamples do
			if isPlayerInDoorway(leaf, sample) then
				occupied = true
				break
			end
		end
		if leaf.occupied and not occupied then
			local resumeDelay = tonumber(setting(leaf.rig, leaf.assembly, "SafetyResumeDelay", Config.SafetyResumeDelay)) or Config.SafetyResumeDelay
			leaf.blockedUntil = now + resumeDelay
		end
		leaf.occupied = occupied
	end
end

local function springAcceleration(angle: number, velocity: number, target: number, stiffness: number, damping: number): number
	return (target - angle) * stiffness - velocity * damping
end

local function publishLeafAttributes(leaf: LeafState, includeAngle: boolean?)
	if leaf.lastReplicatedMode ~= leaf.mode then
		leaf.lastReplicatedMode = leaf.mode
		leaf.rig:SetAttribute("DoorState", leaf.mode)
	end
	local closedEnter = tonumber(setting(leaf.rig, leaf.assembly, "ClosedEnterAngleDeg", Config.ClosedEnterAngleDeg)) or Config.ClosedEnterAngleDeg
	local closedVelocity = tonumber(setting(leaf.rig, leaf.assembly, "ClosedEnterVelocityDeg", Config.ClosedEnterVelocityDeg)) or Config.ClosedEnterVelocityDeg
	local closed = math.abs(leaf.angle) <= math.rad(closedEnter) and math.abs(leaf.velocity) <= math.rad(closedVelocity)
	local openThreshold = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "OpenStateAngleDeg", Config.OpenStateAngleDeg)) or Config.OpenStateAngleDeg)
	local open = math.abs(leaf.angle) >= openThreshold
	local movingThreshold = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "MovingStateVelocityDeg", Config.MovingStateVelocityDeg)) or Config.MovingStateVelocityDeg)
	local moving = leaf.targetAngle ~= nil or math.abs(leaf.velocity) >= movingThreshold
	setAttributeIfDifferent(leaf.rig, "Open", open)
	setAttributeIfDifferent(leaf.rig, "Closed", closed)
	setAttributeIfDifferent(leaf.rig, "Moving", moving)
	setAttributeIfDifferent(leaf.rig, "CollisionEnabled", leaf.collisionEnabled)
	local maxHealth = math.max(0, tonumber(setting(leaf.rig, leaf.assembly, "MaxHealth", Config.MaxHealth)) or Config.MaxHealth)
	setAttributeIfDifferent(leaf.rig, "Health", math.max(0, leaf.health))
	setAttributeIfDifferent(leaf.rig, "HealthPercent", if maxHealth > 0 then math.clamp(leaf.health / maxHealth, 0, 1) else 0)
	local assemblyState = assemblies[leaf.assembly]
	if assemblyState then setAttributeIfDifferent(leaf.rig, "TargetState", assemblyState.targetState) end
	if includeAngle then
		leaf.lastReplicatedAngle = leaf.angle
		leaf.rig:SetAttribute("AngleDeg", math.deg(leaf.angle))
	end
end

local function completeClose(leaf: LeafState, state: AssemblyState)
	leaf.angle = 0
	leaf.velocity = 0
	leaf.lastAcceleration = 0
	leaf.targetAngle = nil
	leaf.holdUntil = 0
	leaf.kickBoostUntil = 0
	leaf.mode = if state.locked then "Locked" else "Idle"
	leaf.collisionYieldUntil = 0
	leaf.safetyIgnorePlayer = nil
	leaf.safetyIgnoreUntil = 0
	leaf.collisionEnabled = true
	leaf.walkPushHandleArmed = true
	leaf.openSoundArmed = true
	leaf.closeStartSoundArmed = false
	if leaf.collision.Parent then leaf.collision.CanCollide = true end
	-- Seat audio normally fires slightly before mathematical zero when the closing
	-- leaf enters the jamb zone. If a hard scripted snap skipped that crossing,
	-- fire the same cue here as a deterministic fallback.
	if leaf.closeSoundArmed and not leaf.closeSeatSoundPlayed then
		playMotionSoundFallback(leaf, "Seat", Config.SoundNames.Close, Config.SoundNames.Rest, Config.SoundNames.Latch, 1)
		leaf.audioPhase = "Seat"
		leaf.lastMotionSoundAt = os.clock()
		leaf.closeSoundArmed = false
		leaf.closeSeatSoundPlayed = true
		-- The jamb impact definitively ends the previous opening cycle. Re-arm Open
		-- immediately so a player can walk back through before completeClose/sleep.
		leaf.openSoundArmed = true
	end
	leaf.audioPhase = "Closed"
	state.stableClosed = true
	state.stableOpen = false
	state.targetState = if state.locked or state.pendingLock then "Locked" else "Closed"
	updateLeafPromptText(state, leaf)
	refreshAssemblyPublicState(state)
end

local function integrateLeaf(leaf: LeafState, dt: number)
	if leaf.broken or not leaf.rig.Parent then
		activeLeaves[leaf] = nil
		return
	end
	local now = os.clock()
	local state = assemblies[leaf.assembly]
	if not state then
		activeLeaves[leaf] = nil
		return
	end
	local previousAngle = leaf.angle
	local walkHandleRearm = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "WalkPushHandleRearmAngleDeg", Config.WalkPushHandleRearmAngleDeg)) or Config.WalkPushHandleRearmAngleDeg)
	if math.abs(leaf.angle) >= walkHandleRearm then
		leaf.walkPushHandleArmed = true
	end

	-- Sustained, validated player contact. This is what makes "hold W into the
	-- door" reliable even if the anchored collision proxy has already reduced the
	-- character's replicated AssemblyLinearVelocity.
	local drivenByPlayer = applyActivePushDrivers(leaf, dt, now)
	-- Keep the server-authoritative slab physically solid. Client-side push-through yield,
	-- when enabled, is presentation-only and is handled by DoorClient per local pusher.
	updateHybridCollision(leaf, state, now, drivenByPlayer)

	local maxAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "MaxAngleDeg", Config.MaxAngleDeg)) or Config.MaxAngleDeg)
	local kickMotion = leaf.mode == "KickedOpen" and now < leaf.kickBoostUntil
	local breachMotion = kickMotion and leaf.breached
	local externalMotion = leaf.mode == "ExternalOpening" or leaf.mode == "ExternalClosing" or leaf.mode == "ExternalLockClosing"
	local maxAngularName = if breachMotion then "BreachMaxAngularSpeedDeg" elseif kickMotion then "KickMaxAngularSpeedDeg" elseif externalMotion then "ExternalCommandMaxAngularSpeedDeg" else "MaxAngularSpeedDeg"
	local maxAngularDefault = if breachMotion then (Config.BreachMaxAngularSpeedDeg or Config.MaxAngularSpeedDeg) elseif kickMotion then (Config.KickMaxAngularSpeedDeg or Config.MaxAngularSpeedDeg) elseif externalMotion then Config.ExternalCommandMaxAngularSpeedDeg else Config.MaxAngularSpeedDeg
	local maxAngular = math.rad(tonumber(setting(leaf.rig, leaf.assembly, maxAngularName, maxAngularDefault)) or maxAngularDefault)
	local freeDragName = if breachMotion then "BreachFreeDrag" elseif kickMotion then "KickFreeDrag" else "FreeDrag"
	local freeDragDefault = if breachMotion then (Config.BreachFreeDrag or Config.FreeDrag) elseif kickMotion then (Config.KickFreeDrag or Config.FreeDrag) else Config.FreeDrag
	local freeDrag = tonumber(setting(leaf.rig, leaf.assembly, freeDragName, freeDragDefault)) or freeDragDefault
	local acceleration = 0
	local guided = leaf.targetAngle ~= nil
	local target = leaf.targetAngle

	if guided and target ~= nil then
		target = math.clamp(target, -maxAngle, maxAngle)
		local closing = math.abs(target) < math.abs(leaf.angle) - math.rad(0.25) or math.abs(target) < math.rad(1)
		local externalGuided = leaf.mode == "ExternalOpening" or leaf.mode == "ExternalClosing" or leaf.mode == "ExternalLockClosing"
		local stiffnessName = if externalGuided then (if closing then "ExternalCloseStiffness" else "ExternalOpenStiffness") else (if closing then "PromptCloseStiffness" else "PromptOpenStiffness")
		local dampingName = if externalGuided then (if closing then "ExternalCloseDamping" else "ExternalOpenDamping") else (if closing then "PromptCloseDamping" else "PromptOpenDamping")
		local accelName = if externalGuided then (if closing then "ExternalCloseMaxAccelerationDeg" else "ExternalOpenMaxAccelerationDeg") else (if closing then "PromptCloseMaxAccelerationDeg" else "PromptOpenMaxAccelerationDeg")
		local stiffnessDefault = if externalGuided then (if closing then Config.ExternalCloseStiffness else Config.ExternalOpenStiffness) else (if closing then Config.PromptCloseStiffness else Config.PromptOpenStiffness)
		local dampingDefault = if externalGuided then (if closing then Config.ExternalCloseDamping else Config.ExternalOpenDamping) else (if closing then Config.PromptCloseDamping else Config.PromptOpenDamping)
		local accelDefault = if externalGuided then (if closing then Config.ExternalCloseMaxAccelerationDeg else Config.ExternalOpenMaxAccelerationDeg) else (if closing then Config.PromptCloseMaxAccelerationDeg else Config.PromptOpenMaxAccelerationDeg)
		local stiffness = tonumber(setting(leaf.rig, leaf.assembly, stiffnessName, stiffnessDefault)) or stiffnessDefault
		local damping = tonumber(setting(leaf.rig, leaf.assembly, dampingName, dampingDefault)) or dampingDefault
		local maxAccel = math.rad(tonumber(setting(leaf.rig, leaf.assembly, accelName, accelDefault)) or accelDefault)
		acceleration = clampAbs(springAcceleration(leaf.angle, leaf.velocity, target, stiffness, damping), maxAccel)
	else
		-- Free rigid-body coast.
		leaf.velocity *= math.exp(-freeDrag * dt)
		local shouldAutoClose = setting(leaf.rig, leaf.assembly, "AutoClose", Config.AutoClose)
		if leaf.breached and setting(leaf.rig, leaf.assembly, "AutoCloseAfterBreach", Config.AutoCloseAfterBreach) ~= true then
			shouldAutoClose = false
		end
		local delay = tonumber(setting(leaf.rig, leaf.assembly, "AutoCloseDelay", Config.AutoCloseDelay)) or Config.AutoCloseDelay
		local extraHold = tonumber(setting(leaf.rig, leaf.assembly, "AutoCloseExtraHoldTime", Config.AutoCloseExtraHoldTime)) or Config.AutoCloseExtraHoldTime
		local minAutoCloseAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "AutoCloseMinimumAngleDeg", Config.AutoCloseMinimumAngleDeg)) or Config.AutoCloseMinimumAngleDeg)
		local canCloseAfterHold = leaf.holdUntil <= 0 or now >= leaf.holdUntil
		local autoCloseDue = now - leaf.lastPushTime >= delay + math.max(0, extraHold)
		if shouldAutoClose and math.abs(leaf.angle) >= minAutoCloseAngle and canCloseAfterHold and autoCloseDue and not leaf.occupied and now >= leaf.blockedUntil then
			local stiffness = tonumber(setting(leaf.rig, leaf.assembly, "ReturnStiffness", Config.ReturnStiffness)) or Config.ReturnStiffness
			local damping = tonumber(setting(leaf.rig, leaf.assembly, "ReturnDamping", Config.ReturnDamping)) or Config.ReturnDamping
			local maxAccel = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "ReturnMaxAccelerationDeg", Config.ReturnMaxAccelerationDeg)) or Config.ReturnMaxAccelerationDeg)
			acceleration = clampAbs(springAcceleration(leaf.angle, leaf.velocity, 0, stiffness, damping), maxAccel)
			if math.abs(leaf.angle) > math.rad(0.5) then
				if leaf.mode ~= "Closing" then
					leaf.mode = "Closing"
					state.targetState = "Closed"
					leaf.closeSoundArmed = true
					-- Optional automatic-return start cue. The physical Close category is reserved
					-- for the jamb/seat impact so the user's closed sound happens when it looks closed.
					markAudioPhase(leaf, "Closing", Config.SoundNames.AutoClose, Config.SoundNames.CloseStart, 1, true)
				end
			end
		end
	end

	-- Soft latch zone adds rotational damping near the jamb without a hard tween.
	local latchCatch = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "LatchCatchAngleDeg", Config.LatchCatchAngleDeg)) or Config.LatchCatchAngleDeg)
	local isClosingMotion = math.abs(leaf.angle + leaf.velocity * dt) < math.abs(leaf.angle)
	if isClosingMotion and math.abs(leaf.angle) <= latchCatch then
		local catchDamping = tonumber(setting(leaf.rig, leaf.assembly, "LatchCatchDamping", Config.LatchCatchDamping)) or Config.LatchCatchDamping
		leaf.velocity *= math.exp(-catchDamping * dt)
	end

	local softLimit = not guided
		and not kickMotion
		and not externalMotion
		and setting(leaf.rig, leaf.assembly, "LimitSpringEnabled", Config.LimitSpringEnabled) ~= false
	local softLimitRange = 0
	if softLimit then
		local springRange = math.clamp(math.rad(tonumber(setting(leaf.rig, leaf.assembly, "LimitSpringRangeDeg", Config.LimitSpringRangeDeg)) or Config.LimitSpringRangeDeg), 0, maxAngle)
		softLimitRange = springRange
		local springStart = math.max(0, maxAngle - springRange)
		if math.abs(leaf.angle) > springStart then
			local springTarget = signNonZero(leaf.angle) * springStart
			local stiffness = tonumber(setting(leaf.rig, leaf.assembly, "LimitSpringStiffness", Config.LimitSpringStiffness)) or Config.LimitSpringStiffness
			local damping = tonumber(setting(leaf.rig, leaf.assembly, "LimitSpringDamping", Config.LimitSpringDamping)) or Config.LimitSpringDamping
			local maxAccel = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "LimitSpringMaxAccelerationDeg", Config.LimitSpringMaxAccelerationDeg)) or Config.LimitSpringMaxAccelerationDeg)
			acceleration += clampAbs(springAcceleration(leaf.angle, leaf.velocity, springTarget, stiffness, damping), maxAccel)
		end
	end

	local candidateVelocity = clampAbs(leaf.velocity + acceleration * dt, maxAngular)
	if softLimit and softLimitRange > 0 then
		-- Active push drivers may continue adding outward speed while the player leans
		-- on the stopped door. Reduce the permitted outward speed continuously to zero
		-- so the hard clamp never alternates between impact and another push impulse.
		local remaining = math.max(0, maxAngle - math.abs(leaf.angle))
		local alpha = math.clamp(remaining / softLimitRange, 0, 1)
		local eased = alpha * alpha * (3 - 2 * alpha)
		local outwardSign = signNonZero(if math.abs(leaf.angle) > 1e-5 then leaf.angle else candidateVelocity)
		if candidateVelocity * outwardSign > 0 then
			candidateVelocity = outwardSign * math.min(math.abs(candidateVelocity), maxAngular * eased)
		end
	end
	local candidateAngle = leaf.angle + candidateVelocity * dt

	local bounceDefault = if breachMotion then (Config.BreachLimitBounce or Config.LimitBounce) elseif kickMotion then (Config.KickLimitBounce or Config.LimitBounce) else Config.LimitBounce
	local bounceName = if breachMotion then "BreachLimitBounce" elseif kickMotion then "KickLimitBounce" else "LimitBounce"
	local limitBounce = tonumber(setting(leaf.rig, leaf.assembly, bounceName, bounceDefault)) or bounceDefault
	if candidateAngle > maxAngle then
		candidateAngle = maxAngle
		candidateVelocity = if softLimit then math.min(0, candidateVelocity) else -math.abs(candidateVelocity) * limitBounce
	elseif candidateAngle < -maxAngle then
		candidateAngle = -maxAngle
		candidateVelocity = if softLimit then math.max(0, candidateVelocity) else math.abs(candidateVelocity) * limitBounce
	end

	local externalClosing = leaf.mode == "ExternalClosing" or leaf.mode == "ExternalLockClosing"
	-- External/API state commands are authoritative. They must reach their requested
	-- state even if a character is occupying the sweep. Normal prompt/auto-return
	-- motion still uses anti-crush obstruction handling below.
	local ignoreSafety = externalClosing
	if not ignoreSafety and closingSweepObstructed(leaf, leaf.angle, candidateAngle) then
		-- Keep external close/lock commands in their high-priority mode while blocked.
		-- The target remains armed and resumes at full external force as soon as the
		-- sweep clears instead of degrading into normal prompt-close tuning.
		if not externalClosing then
			leaf.mode = "HeldForPlayer"
		end
		leaf.lastAcceleration = 0
		local damp = tonumber(setting(leaf.rig, leaf.assembly, "BlockedVelocityDamping", Config.BlockedVelocityDamping)) or Config.BlockedVelocityDamping
		leaf.velocity *= math.exp(-damp * dt)

		-- If a character entered the current slab sweep, retreat the virtual door a
		-- little instead of ever disabling its collider or pushing the character.
		if angleObstructed(leaf, leaf.angle) and math.abs(leaf.angle) > math.rad(1) then
			local backoffSpeed = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "SafetyBackoffSpeedDeg", Config.SafetyBackoffSpeedDeg)) or Config.SafetyBackoffSpeedDeg)
			local sign = signNonZero(leaf.angle)
			leaf.angle = sign * math.min(maxAngle, math.abs(leaf.angle) + backoffSpeed * dt)
		end
		leaf.velocity = 0
		local resumeDelay = tonumber(setting(leaf.rig, leaf.assembly, "SafetyResumeDelay", Config.SafetyResumeDelay)) or Config.SafetyResumeDelay
		leaf.blockedUntil = now + resumeDelay
	else
		leaf.velocity = candidateVelocity
		leaf.angle = candidateAngle
		leaf.lastAcceleration = acceleration
	end

	-- Fire the physical close/rest cue where the door visually reaches the frame.
	-- This applies to prompt Close, auto-close, natural return, Closed=true/Open=false,
	-- forced Locked=true closes, and direct DoorService.Close().
	local seatAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "CloseSeatSoundAngleDeg", Config.CloseSeatSoundAngleDeg)) or Config.CloseSeatSoundAngleDeg)
	local seatMinVelocity = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "CloseSeatMinVelocityDeg", Config.CloseSeatMinVelocityDeg)) or Config.CloseSeatMinVelocityDeg)
	local closingTowardSeat = math.abs(leaf.angle) < math.abs(previousAngle) - math.rad(0.002)
		or (math.abs(leaf.velocity) >= seatMinVelocity and leaf.angle * leaf.velocity < 0)
	if leaf.closeSoundArmed and not leaf.closeSeatSoundPlayed and closingTowardSeat and math.abs(leaf.angle) <= seatAngle then
		local impactScale = math.clamp(0.95 + math.abs(leaf.velocity) / math.rad(240) * 0.28, 0.92, 1.22)
		playMotionSoundFallback(leaf, "Seat", Config.SoundNames.Close, Config.SoundNames.Rest, Config.SoundNames.Latch, impactScale)
		leaf.audioPhase = "Seat"
		leaf.lastMotionSoundAt = os.clock()
		leaf.closeSoundArmed = false
		leaf.closeSeatSoundPlayed = true
		-- The jamb impact definitively ends the previous opening cycle. Re-arm Open
		-- immediately so a player can walk back through before completeClose/sleep.
		leaf.openSoundArmed = true
	end

	-- Guided target completion.
	if leaf.targetAngle ~= nil then
		local remaining = math.abs(leaf.targetAngle - leaf.angle)
		if remaining < math.rad(0.85) and math.abs(leaf.velocity) < math.rad(4.5) then
			if math.abs(leaf.targetAngle) <= math.rad(1) then
				completeClose(leaf, state)
			else
				local wasExternalOpen = leaf.mode == "ExternalOpening"
				leaf.angle = leaf.targetAngle
				leaf.velocity = 0
				leaf.lastAcceleration = 0
				leaf.targetAngle = nil
				leaf.mode = if wasExternalOpen then "ExternalOpenHold" else "OpenHold"
				leaf.holdUntil = if wasExternalOpen then math.huge else now + (tonumber(setting(leaf.rig, leaf.assembly, "PromptHoldOpenTime", Config.PromptHoldOpenTime)) or Config.PromptHoldOpenTime)
				state.stableClosed = false
				state.stableOpen = true
				state.targetState = "Open"
				-- Reaching the open hinge limit is intentionally silent. `Open` is the
				-- opening-motion cue; `Close` is reserved exclusively for seating at the jamb.
				leaf.audioPhase = "OpenRest"
				updateLeafPromptText(state, leaf)
			end
		end
	else
		local snapAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "LatchSnapAngleDeg", Config.LatchSnapAngleDeg)) or Config.LatchSnapAngleDeg)
		local snapVelocity = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "LatchSnapVelocityDeg", Config.LatchSnapVelocityDeg)) or Config.LatchSnapVelocityDeg)
		if math.abs(leaf.angle) <= snapAngle and math.abs(leaf.velocity) <= snapVelocity and not leaf.occupied then
			completeClose(leaf, state)
		end
	end

	local absAngle = math.abs(leaf.angle)
	local previousAbsAngle = math.abs(previousAngle)
	local motionDelta = absAngle - previousAbsAngle
	local audioMoveThreshold = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "MotionSoundVelocityDeg", Config.MotionSoundVelocityDeg)) or Config.MotionSoundVelocityDeg)
	local openTriggerAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "OpenSoundTriggerAngleDeg", Config.OpenSoundTriggerAngleDeg or 1.5)) or 1.5)
	local openRearmAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "OpenSoundRearmAngleDeg", Config.OpenSoundRearmAngleDeg or 0.75)) or 0.75)
	local closeStartAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "CloseStartSoundMinAngleDeg", Config.CloseStartSoundMinAngleDeg)) or Config.CloseStartSoundMinAngleDeg)
	local closeSeatRearmAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "CloseSeatSoundRearmAngleDeg", Config.CloseSeatSoundRearmAngleDeg)) or Config.CloseSeatSoundRearmAngleDeg)

	-- Audio cycles are tied to physical hinge zones rather than only completeClose().
	-- A player can walk back into a leaf while it is visually seated but before its
	-- final sleep transition; re-arming here makes that next real opening audible.
	local openingOutward = motionDelta > math.rad(0.002)
		or (absAngle > openRearmAngle and leaf.angle * leaf.velocity > 0 and math.abs(leaf.velocity) >= audioMoveThreshold)
	local closingInward = motionDelta < -math.rad(0.002)
		or (absAngle > openRearmAngle and leaf.angle * leaf.velocity < 0 and math.abs(leaf.velocity) >= audioMoveThreshold)

	local audioPhaseCanRearmOpen = leaf.audioPhase == "Closed"
		or leaf.audioPhase == "Closing"
		or leaf.audioPhase == "Seat"
	if (absAngle <= openRearmAngle or previousAbsAngle <= openRearmAngle) and audioPhaseCanRearmOpen then
		leaf.openSoundArmed = true
		-- Explicit Prompt/API opens already mark the phase as Opening before motion starts;
		-- never re-arm those here or the same command could play Open twice.
		if math.abs(leaf.velocity) < audioMoveThreshold and leaf.audioPhase ~= "Seat" then
			leaf.audioPhase = "Closed"
		end
	end

	-- Once the leaf has genuinely left the jamb, independently re-arm both closing
	-- cues. This does not depend on whether the Open sound asset itself managed to play.
	if openingOutward and absAngle >= openTriggerAngle then
		leaf.closeStartSoundArmed = true
	end
	if openingOutward and absAngle >= closeSeatRearmAngle then
		leaf.closeSoundArmed = true
		leaf.closeSeatSoundPlayed = false
	end

	-- Open is started explicitly by Prompt/API commands or the first server-validated
	-- walk-through push contact. Do not infer Open from outward velocity here: a closing
	-- leaf can bounce slightly off the jamb and would otherwise consume the next cycle.
	if closingInward and absAngle >= closeStartAngle and leaf.closeStartSoundArmed then
		-- Optional motion-start/creak category. Close itself is the physical seat sound.
		markAudioPhase(leaf, "Closing", Config.SoundNames.CloseStart, Config.SoundNames.Creak)
	end

	setCollisionPose(leaf)
	updateHybridCollision(leaf, state, now, drivenByPlayer)
	publishLeafAttributes(leaf, false)
	refreshAssemblyPublicState(state)
	updateLeafPromptText(state, leaf)

	-- Dormancy: closed doors sleep; permanently-open non-auto-close doors can sleep too.
	local sleepAngle = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "SleepAngleDeg", Config.SleepAngleDeg)) or Config.SleepAngleDeg)
	local sleepVelocity = math.rad(tonumber(setting(leaf.rig, leaf.assembly, "SleepVelocityDeg", Config.SleepVelocityDeg)) or Config.SleepVelocityDeg)
	local autoClose = setting(leaf.rig, leaf.assembly, "AutoClose", Config.AutoClose)
	local canSleepClosed = math.abs(leaf.angle) < sleepAngle and math.abs(leaf.velocity) < sleepVelocity and leaf.targetAngle == nil and not leaf.occupied
	local canSleepOpen = not autoClose and leaf.targetAngle == nil and math.abs(leaf.velocity) < sleepVelocity and now >= leaf.holdUntil
	if canSleepClosed then
		completeClose(leaf, state)
		setCollisionPose(leaf)
		publishLeafAttributes(leaf, true)
		stateEvent:FireAllClients({
			t = workspace:GetServerTimeNow(),
			states = {{rig = leaf.rig, angle = 0, velocity = 0, acceleration = 0, mode = leaf.mode, broken = false, collisionEnabled = leaf.collisionEnabled}},
		})
		activeLeaves[leaf] = nil
	elseif canSleepOpen then
		-- Dormant/full-open state is silent; never fall back to Rest/Close-style audio.
		leaf.audioPhase = "OpenRest"
		publishLeafAttributes(leaf, true)
		stateEvent:FireAllClients({
			t = workspace:GetServerTimeNow(),
			states = {{rig = leaf.rig, angle = leaf.angle, velocity = 0, acceleration = 0, mode = leaf.mode, broken = false, collisionEnabled = leaf.collisionEnabled}},
		})
		activeLeaves[leaf] = nil
	end
end

local function makeMotionState(leaf: LeafState): {[string]: any}
	return {
		rig = leaf.rig,
		angle = leaf.angle,
		velocity = leaf.velocity,
		acceleration = leaf.lastAcceleration,
		mode = leaf.mode,
		broken = leaf.broken,
		collisionEnabled = leaf.collisionEnabled,
	}
end

local function replicateActive()
	if next(activeLeaves) == nil then
		return
	end
	local serverTime = workspace:GetServerTimeNow()
	local maxDistanceSq = Config.ReplicationDistance * Config.ReplicationDistance
	for _, player in Players:GetPlayers() do
		local root = select(1, rootCharacter(player))
		if not root then
			continue
		end
		local rootPosition = root.Position
		local states = {}
		for leaf in activeLeaves do
			if leaf.rig.Parent then
				local delta = rootPosition - leaf.hinge.Position
				if delta:Dot(delta) <= maxDistanceSq then
					table.insert(states, makeMotionState(leaf))
				end
			end
		end
		if #states > 0 then
			stateEvent:FireClient(player, {t = serverTime, states = states, protocol = Config.SnapshotProtocolVersion})
		end
	end
end

-- Full snapshots are used once when a client joins. This is intentionally NOT
-- distance culled: a dormant door can already be open/locked far away, and a late
-- joiner must know that state before they ever walk into replication range.
-- Normal moving-door packets remain distance culled in replicateActive().
local function snapshotForPlayer(player: Player, fullSnapshot: boolean?)
	local root = select(1, rootCharacter(player))
	local rootPosition = root and root.Position or nil
	local maxDistanceSq = Config.ReplicationDistance * Config.ReplicationDistance
	local sendAll = fullSnapshot == true or Config.LateJoinFullSnapshot == true
	local states = {}
	for _, state in assemblies do
		for _, leaf in state.leaves do
			local include = sendAll or rootPosition == nil
			if not include and rootPosition then
				local delta = rootPosition - leaf.hinge.Position
				include = delta:Dot(delta) <= maxDistanceSq
			end
			if include then
				table.insert(states, makeMotionState(leaf))
			end
		end
	end
	return {
		t = workspace:GetServerTimeNow(),
		states = states,
		full = sendAll,
		protocol = Config.SnapshotProtocolVersion,
		version = DoorService.VERSION,
	}
end

function DoorService.Open(assembly: Model, _player: Player?, leafRig: Model?)
	local state = assemblies[assembly] or DoorService.Register(assembly)
	if not state then
		return
	end

	-- External/server Open is a hard state command. By default it also unlocks so a
	-- script can reliably request Open without first coordinating a separate unlock.
	if (state.locked or state.pendingLock) and attr(assembly, "ExternalOpenUnlocks", Config.ExternalOpenUnlocks) == true then
		state.locked = false
		state.pendingLock = false
		writeAssemblyAttribute(state, "Locked", false)
		local sourceLeaf = state.leaves[1]
		if sourceLeaf then
			playSound(sourceLeaf, Config.SoundNames.Unlock)
			broadcastAction(sourceLeaf, "Unlock", {external = true})
		end
	end

	if leafRig then
		local leaf = leafByRig[leafRig]
		if leaf and leaf.assembly == assembly then
			requestExternalOpenLeaf(leaf)
			refreshAssemblyPublicState(state)
		end
		return
	end
	for _, leaf in state.leaves do
		requestExternalOpenLeaf(leaf)
	end
	refreshAssemblyPublicState(state)
	updatePromptText(state)
end

function DoorService.Close(assembly: Model)
	local state = assemblies[assembly] or DoorService.Register(assembly)
	if not state then
		return
	end
	for _, leaf in state.leaves do
		requestExternalCloseLeaf(leaf, state.pendingLock)
	end
	refreshAssemblyPublicState(state)
	updatePromptText(state)
end

function DoorService.SetLocked(assembly: Model, locked: boolean, player: Player?, externalForce: boolean?)
	local state = assemblies[assembly] or DoorService.Register(assembly)
	if not state then
		return
	end
	local external = externalForce == true or player == nil

	-- Treat Locked as a physical invariant, not only a boolean. If the state says
	-- locked but any leaf is no longer seated, re-run the force-close + latch path.
	if locked and state.locked and not state.pendingLock and allLeavesClosed(state) then
		return
	end

	if locked and (assembly:GetAttribute("Breached") == true or assembly:GetAttribute("LockBroken") == true) then
		if external and attr(assembly, "ExternalLockRepairsBrokenLock", Config.ExternalLockRepairsBrokenLock) == true then
			assembly:SetAttribute("Breached", false)
			assembly:SetAttribute("LockBroken", false)
			for _, leaf in state.leaves do
				leaf.breached = false
				local maxHealth = tonumber(setting(leaf.rig, assembly, "MaxHealth", Config.MaxHealth)) or Config.MaxHealth
				leaf.health = maxHealth
				leaf.rig:SetAttribute("Health", maxHealth)
				leaf.rig:SetAttribute("Breached", false)
				leaf.rig:SetAttribute("LockBroken", false)
			end
		else
			return
		end
	end

	if not locked then
		state.pendingLock = false
		state.targetState = if allLeavesClosed(state) then "Closed" elseif assemblyActuallyOpen(state) then "Open" else "Free"
		state.locked = false
		writeAssemblyAttribute(state, "Locked", false)
		for _, leaf in state.leaves do
			if leaf.mode == "Locked" or leaf.mode == "ExternalLockClosing" then
				leaf.mode = if math.abs(leaf.angle) <= math.rad(1) then "Idle" else "OpenHold"
			end
		end
		refreshAssemblyPublicState(state)
		updatePromptText(state)
		local sourceLeaf = state.leaves[1]
		if sourceLeaf then
			playSound(sourceLeaf, Config.SoundNames.Unlock)
			broadcastAction(sourceLeaf, "Unlock", {player = player})
		end
		return
	end

	-- Locked=true is a priority close-and-latch command. It does not care whether the
	-- leaf is opening, kicked, pushed, ajar, or moving in the wrong direction.
	if allLeavesClosed(state) then
		local wasLocked = state.locked
		state.pendingLock = false
		state.locked = true
		state.targetState = "Locked"
		writeAssemblyAttribute(state, "Locked", true)
		for _, leaf in state.leaves do
			beginLeafCommand(leaf)
			table.clear(leaf.drivers)
			table.clear(leaf.contacts)
			leaf.angle = 0
			leaf.velocity = 0
			leaf.targetAngle = nil
			leaf.mode = "Locked"
			leaf.collisionEnabled = true
			if leaf.collision.Parent then leaf.collision.CanCollide = true end
		end
		refreshAssemblyPublicState(state)
		updatePromptText(state)
		if not wasLocked then
			local sourceLeaf = state.leaves[1]
			if sourceLeaf then
				playSound(sourceLeaf, Config.SoundNames.Lock)
				broadcastAction(sourceLeaf, "Lock", {player = player})
			end
		end
		return
	end

	state.pendingLock = true
	pendingLockAssemblies[state] = true
	state.locked = false
	state.targetState = "Locked"
	for _, leaf in state.leaves do
		requestExternalCloseLeaf(leaf, true)
	end
	writeAssemblyAttribute(state, "Locked", true)
	refreshAssemblyPublicState(state)
	updatePromptText(state)
end

function DoorService.SetState(assembly: Model, stateName: string)
	local requested = string.lower(stateName)
	if requested == "open" or requested == "opened" or requested == "opening" then
		DoorService.Open(assembly)
	elseif requested == "close" or requested == "closed" or requested == "closing" then
		DoorService.Close(assembly)
	elseif requested == "locked" or requested == "lock" then
		DoorService.SetLocked(assembly, true, nil, true)
	elseif requested == "unlocked" or requested == "unlock" then
		DoorService.SetLocked(assembly, false, nil, true)
	else
		warn(("[DoorService] Unknown state %q for %s"):format(stateName, assembly:GetFullName()))
	end
end

-- Stable one-call control surface for other synced server systems. Example:
-- DoorService.Command(door, "Lock") or DoorService.Command(door, "SetHealth", 50).
function DoorService.Command(assembly: Model, command: string, value: any?, player: Player?, leafRig: Model?): (boolean, string?)
	if not assembly or not assembly:IsA("Model") then
		return false, "InvalidDoor"
	end
	local normalized = string.lower(tostring(command)):gsub("[%s_%-]", "")
	if normalized == "open" then
		DoorService.Open(assembly, player, leafRig)
	elseif normalized == "close" then
		DoorService.Close(assembly)
	elseif normalized == "lock" then
		DoorService.SetLocked(assembly, true, player, player == nil)
	elseif normalized == "unlock" then
		DoorService.SetLocked(assembly, false, player, player == nil)
	elseif normalized == "togglelock" then
		return DoorService.ToggleLock(assembly, player, leafRig), nil
	elseif normalized == "kick" or normalized == "breach" then
		DoorService.Kick(assembly, player, leafRig)
	elseif normalized == "sethealth" or normalized == "health" then
		local health = tonumber(value)
		if health == nil then return false, "InvalidHealth" end
		DoorService.SetHealth(assembly, health, leafRig)
	elseif normalized == "reset" then
		DoorService.Reset(assembly)
	else
		return false, "UnknownCommand"
	end
	return true, nil
end

DoorService.Control = DoorService.Command

function DoorService.ToggleLock(assembly: Model, player: Player?, leafRig: Model?): boolean
	local state = assemblies[assembly] or DoorService.Register(assembly)
	if not state then
		return false
	end
	local leaf = if leafRig then leafByRig[leafRig] else state.leaves[1]
	if not leaf or leaf.assembly ~= assembly then
		return false
	end
	if player then
		local action = if state.locked or state.pendingLock then "Unlock" else "Lock"
		local allowed = canPlayerAccess(leaf, player, action)
		if not allowed then
			return false
		end
	end
	DoorService.SetLocked(assembly, not (state.locked or state.pendingLock), player)
	return true
end

function DoorService.Kick(assembly: Model, player: Player?, leafRig: Model?)
	local state = assemblies[assembly]
	if not state then
		return
	end
	local leaf = if leafRig then leafByRig[leafRig] else state.leaves[1]
	if not leaf or leaf.broken then
		return
	end
	if setting(leaf.rig, leaf.assembly, "KickOnlyWhenLocked", Config.KickOnlyWhenLocked) == true and not state.locked then
		return
	end

	beginLeafCommand(leaf)
	table.clear(leaf.drivers)
	table.clear(leaf.contacts)

	local wasLocked = state.locked
	state.targetState = if wasLocked then "Locked" else "Free"

	local sign = chooseOpenSign(leaf, player)
	local side = player and playerSideForLeaf(leaf, player) or "Front"

	-- Every kick gets the impact cue. If this exact kick breaks the latch, the distinct
	-- Breach cue below also plays, so impact and latch failure are separately audible.
	playSoundFallback(leaf, Config.SoundNames.KickAttempt, Config.SoundNames.Kick)

	local breakable = setting(leaf.rig, leaf.assembly, "Breakable", Config.Breakable) ~= false

	if not leaf.breached and breakable then
		local minDamage = tonumber(setting(leaf.rig, leaf.assembly, "KickDamageMin", Config.KickDamageMin)) or Config.KickDamageMin
		local maxDamage = tonumber(setting(leaf.rig, leaf.assembly, "KickDamageMax", Config.KickDamageMax)) or Config.KickDamageMax
		leaf.health -= math.random(math.floor(minDamage), math.floor(maxDamage))
		leaf.rig:SetAttribute("Health", math.max(0, leaf.health))
		local kickMaxHealth = math.max(0, tonumber(setting(leaf.rig, leaf.assembly, "MaxHealth", Config.MaxHealth)) or Config.MaxHealth)
		leaf.rig:SetAttribute("HealthPercent", if kickMaxHealth > 0 then math.clamp(leaf.health / kickMaxHealth, 0, 1) else 0)
		refreshAssemblyPublicState(state)
	end

	local breachingNow = wasLocked and not leaf.breached and breakable and leaf.health <= 0
	broadcastAction(leaf, "Kick", {
		side = side,
		sign = sign,
		locked = wasLocked,
		breaching = breachingNow,
	})

	-- Failed locked kicks NEVER accumulate real hinge motion. The visible recoil is
	-- client-only, while authoritative pose/collision remain exactly seated at 0°.
	if wasLocked and (leaf.breached or not breakable or leaf.health > 0) then
		local allowPhysicalRattle = setting(
			leaf.rig,
			leaf.assembly,
			"LockedKickAuthoritativeMotion",
			Config.LockedKickAuthoritativeMotion
		) == true

		if allowPhysicalRattle then
			local rattle = tonumber(setting(leaf.rig, leaf.assembly, "LockedKickAngularImpulseDeg", Config.LockedKickAngularImpulseDeg)) or Config.LockedKickAngularImpulseDeg
			leaf.velocity += math.rad(sign * rattle)
			leaf.targetAngle = 0
			leaf.mode = "LockedRattle"
			setActive(leaf)
		else
			leaf.angle = 0
			leaf.velocity = 0
			leaf.lastAcceleration = 0
			leaf.targetAngle = nil
			leaf.kickBoostUntil = 0
			leaf.mode = "Locked"
			leaf.collisionEnabled = true
			leaf.holdUntil = 0
			leaf.closeSoundArmed = false
			setCollisionPose(leaf)
			publishLeafAttributes(leaf, true)
			refreshAssemblyPublicState(state)
			updatePromptText(state)

			stateEvent:FireAllClients({
				t = workspace:GetServerTimeNow(),
				states = {{
					rig = leaf.rig,
					angle = 0,
					velocity = 0,
					acceleration = 0,
					mode = "Locked",
					broken = false,
					collisionEnabled = true,
				}},
			})
			activeLeaves[leaf] = nil
		end
		return
	end

	-- Unlocked kicks retain physical shove behavior. A locked leaf reaches the breach
	-- path only on the exact kick that reduced integrity to zero.
	if not wasLocked then
		local kickImpulse = tonumber(setting(leaf.rig, leaf.assembly, "UnlockedKickAngularImpulseDeg", Config.UnlockedKickAngularImpulseDeg)) or Config.UnlockedKickAngularImpulseDeg
		local kickMinSpeed = tonumber(setting(leaf.rig, leaf.assembly, "KickMinAngularSpeedDeg", Config.KickMinAngularSpeedDeg)) or Config.KickMinAngularSpeedDeg
		local along = math.deg(leaf.velocity) * sign
		local launchedSpeed = math.max(kickMinSpeed, math.max(0, along) + kickImpulse)
		leaf.targetAngle = nil
		leaf.velocity = sign * math.rad(launchedSpeed)
		leaf.mode = "KickedOpen"
		leaf.kickBoostUntil = os.clock() + (tonumber(setting(leaf.rig, leaf.assembly, "KickBoostDuration", Config.KickBoostDuration)) or Config.KickBoostDuration)
		leaf.lastPushTime = os.clock()
		leaf.closeSoundArmed = true
		setActive(leaf)
	end

	if leaf.breached or not breakable or leaf.health > 0 then
		return
	end

	leaf.health = 0
	leaf.breached = true
	leaf.rig:SetAttribute("Health", 0)
	leaf.rig:SetAttribute("HealthPercent", 0)
	leaf.rig:SetAttribute("Breached", true)
	leaf.rig:SetAttribute("LockBroken", true)
	assembly:SetAttribute("Breached", true)
	assembly:SetAttribute("LockBroken", true)

	playSoundFallback(leaf, Config.SoundNames.Breach, Config.SoundNames.Kick)
	broadcastAction(leaf, "Breach", {
		side = side,
		sign = sign,
	})

	-- Only after the latch is actually broken can a locked door release and swing.
	if state.locked and setting(leaf.rig, leaf.assembly, "UnlockOnBreach", Config.UnlockOnBreach) ~= false then
		state.pendingLock = false
		state.locked = false
		writeAssemblyAttribute(state, "Locked", false)
	end
	state.targetState = if state.locked then "Free" else "Open"

	local breachSpeed = tonumber(setting(leaf.rig, leaf.assembly, "BreachOpenAngularSpeedDeg", Config.BreachOpenAngularSpeedDeg)) or Config.BreachOpenAngularSpeedDeg
	local breachImpulse = tonumber(setting(leaf.rig, leaf.assembly, "BreachAdditiveAngularImpulseDeg", Config.BreachAdditiveAngularImpulseDeg)) or Config.BreachAdditiveAngularImpulseDeg
	local breachAngle = tonumber(setting(leaf.rig, leaf.assembly, "BreachOpenAngleDeg", Config.BreachOpenAngleDeg)) or Config.BreachOpenAngleDeg
	local maxAngleDeg = tonumber(setting(leaf.rig, leaf.assembly, "MaxAngleDeg", Config.MaxAngleDeg)) or Config.MaxAngleDeg
	-- A lock breach starts from the seated pose. Failed attempts never contribute
	-- authoritative angular momentum, so the final break is strong but bounded.
	local launchedSpeed = math.min(
		tonumber(setting(leaf.rig, leaf.assembly, "BreachMaxAngularSpeedDeg", Config.BreachMaxAngularSpeedDeg)) or Config.BreachMaxAngularSpeedDeg,
		Config.BreachAbsoluteMaxAngularSpeedDeg or 520,
		math.max(0, breachSpeed + breachImpulse)
	)
	leaf.targetAngle = nil
	leaf.angle = 0
	leaf.velocity = sign * math.rad(launchedSpeed)
	leaf.mode = "KickedOpen"
	leaf.kickBoostUntil = os.clock() + math.max(0.75, tonumber(setting(leaf.rig, leaf.assembly, "KickBoostDuration", Config.KickBoostDuration)) or Config.KickBoostDuration)
	leaf.rig:SetAttribute("BreachOpenAngleDeg", math.min(breachAngle, maxAngleDeg))
	leaf.lastPushTime = os.clock()
	leaf.holdUntil = os.clock() + (tonumber(setting(leaf.rig, leaf.assembly, "BreachHoldOpenTime", Config.BreachHoldOpenTime)) or Config.BreachHoldOpenTime)
	leaf.closeSoundArmed = true
	leaf.rig:SetAttribute("DoorState", "Breached")
	refreshAssemblyPublicState(state)
	updatePromptText(state)
	setActive(leaf)
end

function DoorService.BreakLeaf(leafRig: Model, player: Player?)
	local leaf = leafByRig[leafRig]
	if not leaf or leaf.broken then
		return
	end
	beginLeafCommand(leaf)
	leaf.broken = true
	leaf.breached = true
	leaf.mode = "Broken"
	leaf.targetAngle = nil
	leaf.collision.CanCollide = false
	leaf.collision.CanQuery = false
	leaf.rig:SetAttribute("DoorState", "Broken")
	leaf.rig:SetAttribute("Breached", true)
	leaf.assembly:SetAttribute("Breached", true)
	leaf.health = 0
	leaf.rig:SetAttribute("Health", 0)
	leaf.rig:SetAttribute("HealthPercent", 0)
	activeLeaves[leaf] = nil

	-- Put the server copy at the authoritative angle before handing it to physics.
	leaf.leafModel:PivotTo(getLeafPose(leaf, leaf.angle))
	if leaf.root then
		local markedCollision = false
		local largestPart: BasePart? = nil
		local largestVolume = 0
		for _, descendant in leaf.leafModel:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = false
				local shouldCollide = descendant:GetAttribute("BreakCollision") == true
				descendant.CanCollide = shouldCollide
				markedCollision = markedCollision or shouldCollide
				local volume = descendant.Size.X * descendant.Size.Y * descendant.Size.Z
				if descendant ~= leaf.root and descendant.Transparency < 1 and volume > largestVolume then
					largestVolume = volume
					largestPart = descendant
				end
			end
		end
		if not markedCollision and largestPart then
			largestPart.CanCollide = true
		end
		leaf.root.Anchored = false
		pcall(function()
			leaf.root:SetNetworkOwner(nil)
		end)
		local sign = chooseOpenSign(leaf, player)
		local breakKickImpulse = tonumber(setting(leaf.rig, leaf.assembly, "KickImpulse", Config.KickImpulse)) or Config.KickImpulse
		leaf.root.AssemblyLinearVelocity += leaf.hinge.CFrame.LookVector * breakKickImpulse * -sign + Vector3.new(0, 7, 0)
		local breakAngularImpulse = tonumber(setting(leaf.rig, leaf.assembly, "BreakAngularImpulseDeg", Config.BreakAngularImpulseDeg)) or Config.BreakAngularImpulseDeg
		leaf.root.AssemblyAngularVelocity += leaf.hinge.CFrame.UpVector * math.rad(breakAngularImpulse * sign)
	end
	playSound(leaf, Config.SoundNames.Break)
	broadcastAction(leaf, "Break", {sign = chooseOpenSign(leaf, player)})
	local state = assemblies[leaf.assembly]
	if state then
		refreshAssemblyPublicState(state)
		updatePromptText(state)
	end

	if setting(leaf.rig, leaf.assembly, "ResetAfterBreak", Config.ResetAfterBreak) then
		local delayTime = tonumber(setting(leaf.rig, leaf.assembly, "ResetDelay", Config.ResetDelay)) or Config.ResetDelay
		task.delay(delayTime, function()
			if leaf.rig.Parent then
				DoorService.ResetLeaf(leaf.rig)
			end
		end)
	end
end

function DoorService.ResetLeaf(leafRig: Model)
	local leaf = leafByRig[leafRig]
	if not leaf then
		return
	end
	leaf.broken = false
	leaf.breached = false
	leaf.rig:SetAttribute("Breached", false)
	leaf.rig:SetAttribute("LockBroken", false)
	leaf.assembly:SetAttribute("LockBroken", false)
	leaf.health = tonumber(setting(leaf.rig, leaf.assembly, "MaxHealth", Config.MaxHealth)) or Config.MaxHealth
	leaf.angle = 0
	leaf.velocity = 0
	leaf.targetAngle = nil
	leaf.mode = "Idle"
	leaf.occupied = false
	leaf.blockedUntil = 0
	leaf.holdUntil = 0
	leaf.kickBoostUntil = 0
	leaf.collisionEnabled = true
	leaf.collisionYieldUntil = 0
	leaf.safetyIgnorePlayer = nil
	leaf.safetyIgnoreUntil = 0
	leaf.lastAcceleration = 0
	leaf.walkPushHandleArmed = true
	leaf.lastWalkPushHandleAt = -math.huge
	leaf.openSoundArmed = true
	leaf.closeStartSoundArmed = false
	leaf.closeSoundArmed = false
	leaf.closeSeatSoundPlayed = true
	leaf.audioPhase = "Closed"
	leaf.lastMotionSoundAt = 0
	table.clear(leaf.lastSoundChoice)
	table.clear(leaf.contacts)
	table.clear(leaf.drivers)

	if leaf.root then
		leaf.root.AssemblyLinearVelocity = Vector3.zero
		leaf.root.AssemblyAngularVelocity = Vector3.zero
	end
	anchorLeafForHybrid(leaf.leafModel, leaf.root)
	leaf.leafModel:PivotTo(leaf.closedLeafPivot)
	leaf.collision.CFrame = leaf.closedCollisionCF
	leaf.collision.CanCollide = true
	leaf.collision.CanQuery = true
	leaf.rig:SetAttribute("Health", leaf.health)
	local resetMaxHealth = math.max(0, tonumber(setting(leaf.rig, leaf.assembly, "MaxHealth", Config.MaxHealth)) or Config.MaxHealth)
	leaf.rig:SetAttribute("HealthPercent", if resetMaxHealth > 0 then math.clamp(leaf.health / resetMaxHealth, 0, 1) else 0)
	leaf.lastReplicatedAngle = 0
	leaf.lastReplicatedMode = "Idle"
	leaf.rig:SetAttribute("AngleDeg", 0)
	leaf.rig:SetAttribute("DoorState", "Idle")
	broadcastAction(leaf, "Reset", {})
	local state = assemblies[leaf.assembly]
	if state then
		local anyBreached = false
		local anyLockBroken = false
		for _, otherLeaf in state.leaves do
			anyBreached = anyBreached or otherLeaf.breached or otherLeaf.broken
			anyLockBroken = anyLockBroken or otherLeaf.rig:GetAttribute("LockBroken") == true
		end
		state.model:SetAttribute("Breached", anyBreached)
		state.model:SetAttribute("LockBroken", anyLockBroken)
		refreshAssemblyPublicState(state)
		updatePromptText(state)
	end
end

function DoorService.Reset(assembly: Model)
	local state = assemblies[assembly]
	if not state then
		return
	end
	assembly:SetAttribute("Breached", false)
	for _, leaf in state.leaves do
		DoorService.ResetLeaf(leaf.rig)
	end
	refreshAssemblyPublicState(state)
end

function DoorService.SetHealth(assembly: Model, health: number, leafRig: Model?)
	local state = assemblies[assembly] or DoorService.Register(assembly)
	if not state then return end
	for _, leaf in state.leaves do
		if leafRig and leaf.rig ~= leafRig then continue end
		local maxHealth = math.max(0, tonumber(setting(leaf.rig, assembly, "MaxHealth", Config.MaxHealth)) or Config.MaxHealth)
		leaf.health = math.clamp(health, 0, maxHealth)
		setAttributeIfDifferent(leaf.rig, "Health", leaf.health)
		setAttributeIfDifferent(leaf.rig, "HealthPercent", if maxHealth > 0 then leaf.health / maxHealth else 0)
	end
	refreshAssemblyPublicState(state)
end

function DoorService.GetHealth(assembly: Model, leafRig: Model?): (number?, number?)
	local state = assemblies[assembly]
	if not state then return nil, nil end
	local leaf = if leafRig then leafByRig[leafRig] else state.leaves[1]
	if not leaf or leaf.assembly ~= assembly then return nil, nil end
	local maxHealth = math.max(0, tonumber(setting(leaf.rig, assembly, "MaxHealth", Config.MaxHealth)) or Config.MaxHealth)
	return leaf.health, maxHealth
end

-- Bulk attribute configuration helper. Values are written to the tagged assembly so
-- existing `setting(...)` lookups pick them up immediately; a LeafRig attribute can
-- still override any of these for one leaf.
function DoorService.Configure(assembly: Model, values: {[string]: any})
	for name, value in values do
		assembly:SetAttribute(name, value)
	end
end

function DoorService.GetResolvedSetting(assembly: Model, name: string, leafRig: Model?): any
	if leafRig then
		local leaf = leafByRig[leafRig]
		if leaf and leaf.assembly == assembly then
			local leafValue = leafRig:GetAttribute(name)
			if leafValue ~= nil then return leafValue end
		end
	end
	local assemblyValue = assembly:GetAttribute(name)
	if assemblyValue ~= nil then return assemblyValue end
	return (Config :: any)[name]
end

-- Plays a named category using the same single-Sound / random-Folder behavior as
-- built-in door events. Useful for custom scripted interactions without duplicating
-- audio selection/replication code.
function DoorService.PlaySound(assembly: Model, soundName: string, leafRig: Model?): boolean
	local state = assemblies[assembly] or DoorService.Register(assembly)
	if not state then return false end
	local leaf = if leafRig then leafByRig[leafRig] else state.leaves[1]
	if not leaf or leaf.assembly ~= assembly then return false end
	return playSound(leaf, soundName)
end

function DoorService.RefreshSoundBank(assembly: Model)
	-- Adds only missing default categories; custom categories are never replaced.
	provisionDefaultSounds(assembly)
end

function DoorService.GetAngle(leafRig: Model): number?
	local leaf = leafByRig[leafRig]
	return leaf and math.deg(leaf.angle) or nil
end

function DoorService.GetState(assembly: Model): AssemblyState?
	return assemblies[assembly]
end

function DoorService.CanPlayerAccess(assembly: Model, player: Player, action: string, leafRig: Model?): (boolean, string?)
	local state = assemblies[assembly] or DoorService.Register(assembly)
	if not state then
		return false, "InvalidDoor"
	end
	local leaf = if leafRig then leafByRig[leafRig] else state.leaves[1]
	if not leaf or leaf.assembly ~= assembly then
		return false, "InvalidLeaf"
	end
	return canPlayerAccess(leaf, player, action)
end

function DoorService.Start()
	if started then
		return
	end
	started = true
	-- Versioning stays internal; do not surface implementation versions as Attributes.
	script.Parent:SetAttribute("Version", nil)
	script.Parent:SetAttribute("VersionName", nil)

	local function registerTaggedDoors()
		for _, tagged in CollectionService:GetTagged(Config.Tag) do
			if tagged:IsA("Model") and tagged.Parent then
				DoorService.Register(tagged)
			end
		end
	end
	registerTaggedDoors()
	-- Authored tags and their leaf hierarchy can arrive in separate Studio-sync
	-- passes. A cheap idempotent rescan also recovers from live module replacement.
	task.spawn(function()
		while started do
			task.wait(2)
			registerTaggedDoors()
		end
	end)
	CollectionService:GetInstanceAddedSignal(Config.Tag):Connect(function(inst)
		if inst:IsA("Model") then
			DoorService.Register(inst)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(Config.Tag):Connect(function(inst)
		if inst:IsA("Model") then
			DoorService.Unregister(inst)
		end
	end)

	snapshotFunction.OnServerInvoke = function(player, request)
		local full = type(request) == "table" and request.full == true
		return snapshotForPlayer(player, full)
	end

	RunService.Heartbeat:Connect(function(dt)
		simAccumulator += dt
		scanAccumulator += dt
		replicationAccumulator += dt
		occupancyAccumulator += dt

		local scanStep = 1 / Config.PlayerScanHz
		if scanAccumulator >= scanStep then
			local elapsed = scanAccumulator
			scanAccumulator = 0
			scanPlayerPushes(elapsed)
		end

		local occupancyStep = 1 / Config.OccupancyHz
		if occupancyAccumulator >= occupancyStep then
			occupancyAccumulator = 0
			refreshOccupancy()
		end

		local simStep = 1 / Config.SimulationHz
		local iterations = 0
		while simAccumulator >= simStep and iterations < 3 do
			simAccumulator -= simStep
			iterations += 1
			for leaf in activeLeaves do
				integrateLeaf(leaf, simStep)
			end
		end
		if iterations == 3 then
			simAccumulator = 0
		end

		for state in pendingLockAssemblies do
			if assemblies[state.model] ~= state or not state.pendingLock then
				pendingLockAssemblies[state] = nil
			elseif allLeavesClosed(state) then
				pendingLockAssemblies[state] = nil
				DoorService.SetLocked(state.model, true)
			end
		end

		local replicationStep = 1 / Config.ReplicationHz
		if replicationAccumulator >= replicationStep then
			replicationAccumulator = 0
			replicateActive()
		end
	end)
end

return DoorService
