--!strict
-- Door System client presentation.
-- Server-owned Leaf models are used as authoring/source templates only. Each client
-- renders a private clone so server replication/physics can never overwrite the
-- visible hinge pose. Door motion is reconstructed from authoritative snapshots;
-- UISpr drives the cloned handle motors.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local DOOR_SYSTEM_VERSION = "7.7.0"
-- Client configuration is inlined so DoorClient is self-contained.
local Config = {
	Version = DOOR_SYSTEM_VERSION,
	Tag = "DoorSystemDoor",
	RemotesFolderName = "DoorSystemRemotes",
	ClientNearDistance = 120,
	ClientFarDistance = 300,
	SnapshotProtocolVersion = 2,
	ClientRelevanceRefreshHz = 8,
	ClientPushCandidateDistance = 18,
	ClientInteractionProxyDistance = 48,
	ClientDormantAngleEpsilonDeg = 0.025,
	ClientDormantVelocityEpsilonDeg = 0.20,
	ClientTrackingFrequency = 15.5,
	ClientTrackingDamping = 1.02,
	ClientFarTrackingFrequency = 8.0,
	ClientFarTrackingDamping = 1.05,
	ClientMaxExtrapolation = 0.18,
	ClientHardCorrectionDeg = 14,
	PredictionEnabled = true,
	PredictionMaxDeg = 15.0,
	PredictionGain = 0.075,
	PredictionDecay = 22,
	HandleEnabled = true,
	HandleAxis = "Z",
	HandlePressDeg = -26,
	HandleDamping = 0.78,
	HandleFrequency = 13.5,
	HandleReleaseDelay = 0.20,
	LockedHandleJiggleDeg = 11,
	LockedHandleJiggleDelay = 0.07,
	LockedAttemptShakeDeg = 5.5,
	LockedAttemptShakeFrequency = 29.0,
	LockedAttemptShakeDamping = 0.08,

	-- Interaction presentation
	LocalPromptProxy = true,
	LocalCollisionMirror = true,
	LocalPushScanHz = 60,
	PushSendInterval = 0.045,
	PushPredictionTime = 0.095,
	PushNearDepth = 1.72,
	PushSidePadding = 1.00,
	PushContactSurfaceGap = 1.48,
	PushMaxLeadTime = 0.095,
	PushLeadExtraGap = 0.52,
	PushPreserveOpenDirectionDeg = 8,
	LocalPushCollisionYield = false,
	LocalPushCollisionYieldTime = 0.10,
	LocalPushYieldMinPredictionDeg = 2.5,
	LocalPushYieldMinAngularSpeedDeg = 28,
	LocalPushYieldClearance = 0.58,
	ClosedCollisionSolidAngleDeg = 6.0,

	-- Push intent is scanned locally and validated on the server.
	LocalPushAssist = true,

	-- Additive client-only torsional recoil for kicks/breach impacts.
	KickShakeDeg = 10.0,
	KickShakeFrequency = 21.0,
	KickShakeDamping = 0.38,
	LockedKickShakeDeg = 9.0,
	LockedKickShakeFrequency = 27.0,
	LockedKickShakeDamping = 0.08,
	BreachShakeDeg = 7.0,
	KickParticleEmitterName = "KickDust",
	KickParticleCount = 12,
	BreachParticleCount = 28,
}
local UISpr = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Hud"):WaitForChild("UISpr"))
local remotesInstance = ReplicatedStorage:WaitForChild(Config.RemotesFolderName, 10)
if not remotesInstance or not remotesInstance:IsA("Folder") then
	error(("[DoorSystem] Client could not find ReplicatedStorage.%s after 10 seconds. "
		.. "Make sure Bootstrapper is a SERVER Script under ServerScriptService and look for "
		.. "'[DoorSystem] Networking ready' in the Server Output."):format(Config.RemotesFolderName))
end
local remotes = remotesInstance :: Folder

local function requireRemote(className: string, name: string): Instance
	local inst = remotes:WaitForChild(name, 10)
	if not inst then
		error(("[DoorSystem] Missing %s.%s after 10 seconds"):format(Config.RemotesFolderName, name))
	end
	if inst.ClassName ~= className then
		error(("[DoorSystem] %s.%s is %s, expected %s")
			:format(Config.RemotesFolderName, name, inst.ClassName, className))
	end
	return inst
end

local stateEvent = requireRemote("RemoteEvent", "State") :: RemoteEvent
local actionEvent = requireRemote("RemoteEvent", "Action") :: RemoteEvent
local pushEvent = requireRemote("RemoteEvent", "Push") :: RemoteEvent
local interactEvent = requireRemote("RemoteEvent", "Interact") :: RemoteEvent
local snapshotFunction = requireRemote("RemoteFunction", "Snapshot") :: RemoteFunction

export type ClientLeaf = {
	rig: Model,
	hinge: BasePart,
	leafModel: Model,
	renderModel: Model?,
	sourceLocalTransparency: {[BasePart]: number},
	sourceHidden: boolean,
	collision: BasePart?,
	localCollision: BasePart?,
	sourceCollisionCanCollide: boolean?,
	hingeToLeaf: CFrame,
	hingeToCollision: CFrame?,
	snapshotAngle: number,
	snapshotVelocity: number,
	snapshotAcceleration: number,
	snapshotTime: number,
	visualAngle: number,
	visualVelocity: number,
	prediction: number,
	mode: string,
	broken: boolean,
	collisionEnabled: boolean,
	localCollisionYieldUntil: number,
	initialized: boolean,
	renderAccumulator: number,
	lastAppliedAngle: number,
	frontMotor: Motor6D?,
	backMotor: Motor6D?,
	promptAnchor: BasePart?,
	promptOffset: CFrame?,
	doorPrompt: ProximityPrompt?,
	lockPrompt: ProximityPrompt?,
	kickPrompt: ProximityPrompt?,
	shakeAngle: number,
	shakeVelocity: number,
	shakeFrequency: number,
	shakeDamping: number,
	shakeLimitAngle: number,
	activeMotionSound: Sound?,
}

local leaves: {[Model]: ClientLeaf} = {}
local renderLeaves: {ClientLeaf} = {}
-- Push scanning only needs very-near leaves; keeping a separate relevance list avoids
-- testing every rendered door at 60 Hz in dense interiors.
local pushLeaves: {ClientLeaf} = {}
local localRoot: BasePart? = nil
local localHumanoid: Humanoid? = nil
local nearAccumulator = 0
local pushScanAccumulator = 0
local pushSentAt: {[Model]: number} = {}

export type LocalPushState = {
	expiresAt: number,
	sign: number,
	normalSpeed: number,
	surfaceGap: number,
}
local localPushStates: {[Model]: LocalPushState} = {}

-- Client-only render container. Nothing in here replicates back to the server,
-- which is intentional: the server owns simulation/collision, clients own smooth visuals.
local oldRenderFolder = workspace:FindFirstChild("_DoorSystemClientRender")
if oldRenderFolder then
	oldRenderFolder:Destroy()
end
local renderFolder = Instance.new("Folder")
renderFolder.Name = "_DoorSystemClientRender"
renderFolder.Archivable = false
renderFolder.Parent = workspace

local function setting(rig: Model, assembly: Instance?, name: string, fallback: any): any
	local value = rig:GetAttribute(name)
	if value ~= nil then return value end
	if assembly then
		value = assembly:GetAttribute(name)
		if value ~= nil then return value end
	end
	return fallback
end

local function findAssembly(rig: Model): Model?
	local p: Instance? = rig
	while p and p ~= workspace do
		if p:IsA("Model") and CollectionService:HasTag(p, Config.Tag) then
			return p
		end
		p = p.Parent
	end
	return nil
end

local function findHandleMotor(leafModel: Model, name: string): Motor6D?
	for _, descendant in leafModel:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Name == name then
			return descendant
		end
	end
	return nil
end

local function setSourceHidden(leaf: ClientLeaf, hidden: boolean)
	if hidden == leaf.sourceHidden then
		return
	end

	for _, descendant in leaf.leafModel:GetDescendants() do
		if descendant:IsA("BasePart") then
			if hidden then
				if leaf.sourceLocalTransparency[descendant] == nil then
					leaf.sourceLocalTransparency[descendant] = descendant.LocalTransparencyModifier
				end
				descendant.LocalTransparencyModifier = 1
			else
				local original = leaf.sourceLocalTransparency[descendant]
				descendant.LocalTransparencyModifier = if original ~= nil then original else 0
			end
		end
	end
	leaf.sourceHidden = hidden
end

local function destroyRenderModel(leaf: ClientLeaf, showSource: boolean)
	if leaf.frontMotor then
		UISpr.stop(leaf.frontMotor)
	end
	if leaf.backMotor then
		UISpr.stop(leaf.backMotor)
	end
	leaf.frontMotor = nil
	leaf.backMotor = nil

	if leaf.renderModel then
		leaf.renderModel:Destroy()
		leaf.renderModel = nil
	end

	if leaf.localCollision then
		leaf.localCollision:Destroy()
		leaf.localCollision = nil
	end
	-- Restore the replicated collision slab locally when the private presentation
	-- proxy is no longer being used. Do not force it on for a legacy broken leaf.
	if leaf.collision and leaf.collision.Parent and not leaf.broken and leaf.sourceCollisionCanCollide ~= nil then
		leaf.collision.CanCollide = leaf.sourceCollisionCanCollide
	end

	if showSource then
		setSourceHidden(leaf, false)
	end
end

local function ensureRenderModel(leaf: ClientLeaf): Model?
	if leaf.broken then
		return nil
	end
	if leaf.renderModel and leaf.renderModel.Parent then
		return leaf.renderModel
	end
	if not leaf.leafModel.Parent then
		return nil
	end

	local source = leaf.leafModel
	local oldArchivable = source.Archivable
	source.Archivable = true
	local clone = source:Clone()
	source.Archivable = oldArchivable
	clone.Name = "_Render_" .. leaf.rig.Name

	-- A render clone must never participate in gameplay physics or run cloned scripts.
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
			descendant:Destroy()
		elseif descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
		end
	end

	-- Preserve the authored Root/Weld/Motor hierarchy. Only Root is anchored; the
	-- remainder is local-only, so there are no server corrections fighting the welds.
	local cloneRootInst = clone:FindFirstChild("Root", true)
	local cloneRoot = if cloneRootInst and cloneRootInst:IsA("BasePart") then cloneRootInst else nil
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = if cloneRoot then descendant == cloneRoot else true
		end
	end

	clone.Parent = renderFolder
	local hingeRotation = leaf.hinge.CFrame * CFrame.Angles(0, leaf.visualAngle, 0)
	clone:PivotTo(hingeRotation * leaf.hingeToLeaf)

	leaf.renderModel = clone
	leaf.frontMotor = findHandleMotor(clone, "HandleFrontMotor")
	leaf.backMotor = findHandleMotor(clone, "HandleBackMotor")
	setSourceHidden(leaf, true)
	return clone
end

local function ensureLocalCollisionMirror(leaf: ClientLeaf): BasePart?
	if Config.LocalCollisionMirror ~= true or leaf.broken then
		return nil
	end
	if leaf.localCollision and leaf.localCollision.Parent then
		if leaf.collision and leaf.collision.Parent then
			leaf.collision.CanCollide = false
		end
		return leaf.localCollision
	end
	local source = leaf.collision
	if not source or not source.Parent or not leaf.hingeToCollision then
		return nil
	end

	local proxy = Instance.new("Part")
	proxy.Name = "_DoorSystemLocalCollision_" .. leaf.rig.Name
	proxy.Size = source.Size
	proxy.CFrame = leaf.hinge.CFrame * CFrame.Angles(0, leaf.visualAngle, 0) * leaf.hingeToCollision
	proxy.Anchored = true
	proxy.Transparency = 1
	proxy.CanCollide = leaf.collisionEnabled
	proxy.CanTouch = false
	proxy.CanQuery = false
	proxy.CastShadow = false
	proxy.Massless = true
	proxy.CollisionGroup = source.CollisionGroup
	proxy.Archivable = false
	proxy.Parent = renderFolder

	leaf.sourceCollisionCanCollide = source.CanCollide
	-- The authoritative slab remains solid on the server. Locally we disable only
	-- that replicated copy so the player collides with the exact render-frame proxy
	-- instead of a stale server CFrame. This is client presentation/character physics
	-- alignment; it never changes server authority.
	source.CanCollide = false
	leaf.localCollision = proxy
	return proxy
end

local function ensureLeaf(rig: Model): ClientLeaf?
	local cached = leaves[rig]
	if cached then return cached end
	if not rig.Parent then return nil end
	local hinge = rig:FindFirstChild("Hinge")
	local leafModel = rig:FindFirstChild("Leaf")
	if not hinge or not hinge:IsA("BasePart") or not leafModel or not leafModel:IsA("Model") then
		return nil
	end
	local angle = math.rad(tonumber(rig:GetAttribute("AngleDeg")) or 0)
	local collisionInst = rig:FindFirstChild("DoorCollision")
	local collision = if collisionInst and collisionInst:IsA("BasePart") then collisionInst else nil
	local authoredLeafOffset = rig:GetAttribute("ClosedHingeToLeaf")
	local authoredCollisionOffset = rig:GetAttribute("ClosedHingeToCollision")
	local hingeToLeaf = if typeof(authoredLeafOffset) == "CFrame" then authoredLeafOffset else hinge.CFrame:ToObjectSpace(leafModel:GetPivot())
	local hingeToCollision = if typeof(authoredCollisionOffset) == "CFrame" then authoredCollisionOffset else (if collision then hinge.CFrame:ToObjectSpace(collision.CFrame) else nil)
	local now = workspace:GetServerTimeNow()
	local state: ClientLeaf = {
		rig = rig,
		hinge = hinge,
		leafModel = leafModel,
		renderModel = nil,
		sourceLocalTransparency = {},
		sourceHidden = false,
		collision = collision,
		localCollision = nil,
		sourceCollisionCanCollide = nil,
		hingeToLeaf = hingeToLeaf,
		hingeToCollision = hingeToCollision,
		snapshotAngle = angle,
		snapshotVelocity = 0,
		snapshotAcceleration = 0,
		snapshotTime = now,
		visualAngle = angle,
		visualVelocity = 0,
		prediction = 0,
		mode = tostring(rig:GetAttribute("DoorState") or "Idle"),
		broken = false,
		collisionEnabled = rig:GetAttribute("CollisionEnabled") ~= false,
		localCollisionYieldUntil = 0,
		initialized = false,
		renderAccumulator = 0,
		lastAppliedAngle = math.huge,
		frontMotor = nil,
		backMotor = nil,
		promptAnchor = nil,
		promptOffset = nil,
		doorPrompt = nil,
		lockPrompt = nil,
		kickPrompt = nil,
		shakeAngle = 0,
		shakeVelocity = 0,
		shakeFrequency = Config.KickShakeFrequency,
		shakeDamping = Config.KickShakeDamping,
		shakeLimitAngle = math.rad(42),
		activeMotionSound = nil,
	}
	leaves[rig] = state
	-- Keep the visual clone authoritative for fidelity at distance, but defer the
	-- heavier local collision/prompt proxies until the local player is relevant.
	ensureRenderModel(state)
	return state
end


local function disableServerPromptsLocally(rig: Model)
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("ProximityPrompt")
			and (descendant.Name == "DoorPrompt" or descendant.Name == "LockPrompt" or descendant.Name == "KickPrompt")
		then
			descendant.Enabled = false
		end
	end
end

local function createLocalPrompt(name: string, actionText: string, objectText: string, key: Enum.KeyCode, gamepad: Enum.KeyCode, distance: number, hold: number, attachment: Attachment): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.KeyboardKeyCode = key
	prompt.GamepadKeyCode = gamepad
	prompt.MaxActivationDistance = distance
	prompt.HoldDuration = hold
	prompt.RequiresLineOfSight = false
	prompt.Parent = attachment
	return prompt
end

local function leafOrAssemblyLooksOpen(leaf: ClientLeaf, assembly: Model): boolean
	local threshold = math.rad(tonumber(setting(leaf.rig, assembly, "PromptCloseThresholdDeg", 12)) or 12)

	local function oneLooksOpen(other: ClientLeaf): boolean
		if other.mode == "Closing"
			or other.mode == "GuidedClose"
			or other.mode == "PromptClosing"
			or other.mode == "HandleEngagedClose"
			or other.mode == "HeldForPlayer"
		then
			return false
		end
		if other.mode == "PromptOpening" or other.mode == "OpenHold" or other.mode == "KickedOpen" then
			return true
		end
		return math.abs(other.visualAngle) >= threshold
	end

	if tostring(setting(leaf.rig, assembly, "PromptOpenMode", "Single")) == "All" then
		for _, other in leaves do
			if findAssembly(other.rig) == assembly and oneLooksOpen(other) then
				return true
			end
		end
		return false
	end
	return oneLooksOpen(leaf)
end

local function ensureLocalPromptProxy(leaf: ClientLeaf)
	if not Config.LocalPromptProxy or leaf.promptAnchor or not leaf.collision then
		return
	end

	local assembly = findAssembly(leaf.rig)
	if not assembly then
		return
	end

	disableServerPromptsLocally(leaf.rig)

	local anchor = Instance.new("Part")
	anchor.Name = "_DoorSystemLocalPromptAnchor"
	anchor.Size = Vector3.new(0.12, 0.12, 0.12)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Archivable = false
	anchor.Parent = leaf.rig

	local attachment = Instance.new("Attachment")
	attachment.Name = "_DoorSystemLocalPromptAttachment"
	attachment.Parent = anchor

	local authored = leaf.collision:FindFirstChild("PromptAttachment")
	if authored and authored:IsA("Attachment") then
		leaf.promptOffset = authored.CFrame
	else
		local hingeLocalX = leaf.collision.CFrame:PointToObjectSpace(leaf.hinge.Position).X
		local freeEdgeSign = if hingeLocalX >= 0 then -1 else 1
		leaf.promptOffset = CFrame.new(
			freeEdgeSign * leaf.collision.Size.X * 0.35,
			math.min(0.2, leaf.collision.Size.Y * 0.1),
			0
		)
	end
	leaf.promptAnchor = anchor

	local objectText = tostring(setting(leaf.rig, assembly, "PromptObjectText", "Door"))
	if setting(leaf.rig, assembly, "PromptEnabled", true) ~= false then
		local prompt = createLocalPrompt(
			"LocalDoorPrompt",
			tostring(setting(leaf.rig, assembly, "PromptActionText", "Open")),
			objectText,
			Enum.KeyCode.E,
			Enum.KeyCode.ButtonX,
			tonumber(setting(leaf.rig, assembly, "PromptDistance", 7)) or 7,
			tonumber(setting(leaf.rig, assembly, "PromptHoldDuration", 0)) or 0,
			attachment
		)
		prompt.Triggered:Connect(function()
			local currentAssembly = findAssembly(leaf.rig)
			if not currentAssembly then
				return
			end
			local desiredAction = if leafOrAssemblyLooksOpen(leaf, currentAssembly) then "Close" else "Open"
			interactEvent:FireServer(leaf.rig, desiredAction)
		end)
		leaf.doorPrompt = prompt
	end

	if setting(leaf.rig, assembly, "LockPromptEnabled", false) == true
		and setting(leaf.rig, assembly, "AllowPlayerLocking", false) == true
	then
		local key = setting(leaf.rig, assembly, "LockPromptKey", Enum.KeyCode.F)
		if typeof(key) ~= "EnumItem" then key = Enum.KeyCode.F end
		local prompt = createLocalPrompt(
			"LocalLockPrompt",
			"Lock",
			objectText,
			key,
			Enum.KeyCode.ButtonY,
			tonumber(setting(leaf.rig, assembly, "LockPromptDistance", 6)) or 6,
			tonumber(setting(leaf.rig, assembly, "LockPromptHoldDuration", 0.20)) or 0.20,
			attachment
		)
		prompt.Triggered:Connect(function()
			interactEvent:FireServer(leaf.rig, "Lock")
		end)
		leaf.lockPrompt = prompt
	end

	if setting(leaf.rig, assembly, "KickPromptEnabled", false) == true then
		local key = setting(leaf.rig, assembly, "KickPromptKey", Enum.KeyCode.R)
		if typeof(key) ~= "EnumItem" then key = Enum.KeyCode.R end
		local prompt = createLocalPrompt(
			"LocalKickPrompt",
			tostring(setting(leaf.rig, assembly, "KickPromptUnlockedText", "Kick")),
			objectText,
			key,
			Enum.KeyCode.ButtonB,
			tonumber(setting(leaf.rig, assembly, "KickPromptDistance", 5.5)) or 5.5,
			tonumber(setting(leaf.rig, assembly, "KickPromptHoldDuration", 0.24)) or 0.24,
			attachment
		)
		prompt.Triggered:Connect(function()
			interactEvent:FireServer(leaf.rig, "Kick")
		end)
		leaf.kickPrompt = prompt
	end

	local initialRotation = leaf.hinge.CFrame * CFrame.Angles(0, leaf.visualAngle, 0)
	if leaf.hingeToCollision and leaf.promptOffset then
		anchor.CFrame = initialRotation * leaf.hingeToCollision * leaf.promptOffset
	end
end


local function updateLocalPromptState(leaf: ClientLeaf)
	local assembly = findAssembly(leaf.rig)
	if not assembly then
		return
	end

	disableServerPromptsLocally(leaf.rig)

	if leaf.doorPrompt then
		if leaf.broken then
			leaf.doorPrompt.Enabled = false
		else
			leaf.doorPrompt.Enabled = setting(leaf.rig, assembly, "PromptEnabled", true) ~= false
			if assembly:GetAttribute("Locked") == true then
				leaf.doorPrompt.ActionText = tostring(setting(leaf.rig, assembly, "PromptLockedText", "Locked"))
			elseif leafOrAssemblyLooksOpen(leaf, assembly) then
				leaf.doorPrompt.ActionText = tostring(setting(leaf.rig, assembly, "PromptCloseText", "Close"))
			else
				leaf.doorPrompt.ActionText = tostring(setting(leaf.rig, assembly, "PromptActionText", "Open"))
			end
		end
	end

	if leaf.lockPrompt then
		leaf.lockPrompt.Enabled = not leaf.broken
			and assembly:GetAttribute("Breached") ~= true
			and setting(leaf.rig, assembly, "LockPromptEnabled", false) == true
			and setting(leaf.rig, assembly, "AllowPlayerLocking", false) == true
		leaf.lockPrompt.ActionText = if assembly:GetAttribute("Locked") == true then "Unlock" else "Lock"
	end

	if leaf.kickPrompt then
		local locked = assembly:GetAttribute("Locked") == true
		local onlyLocked = setting(leaf.rig, assembly, "KickOnlyWhenLocked", false) == true
		leaf.kickPrompt.Enabled = not leaf.broken
			and setting(leaf.rig, assembly, "KickPromptEnabled", false) == true
			and (locked or not onlyLocked)
		leaf.kickPrompt.ActionText = if locked
			then tostring(setting(leaf.rig, assembly, "KickPromptLockedText", "Kick In"))
			else tostring(setting(leaf.rig, assembly, "KickPromptUnlockedText", "Kick"))
	end
end

local function discoverAssembly(assembly: Model)
	local folder = assembly:FindFirstChild("Leaves")
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("Model") then
				ensureLeaf(child)
			end
		end
	elseif assembly:FindFirstChild("Hinge") and assembly:FindFirstChild("Leaf") then
		ensureLeaf(assembly)
	end
end

local function handleTransform(axis: string, degrees: number): CFrame
	local r = math.rad(degrees)
	if axis == "Y" then return CFrame.Angles(0, r, 0) end
	if axis == "Z" then return CFrame.Angles(0, 0, r) end
	return CFrame.Angles(r, 0, 0)
end

local function animateHandle(leaf: ClientLeaf, side: string, locked: boolean)
	local assembly = findAssembly(leaf.rig)
	if setting(leaf.rig, assembly, "HandleEnabled", Config.HandleEnabled) == false then return end
	ensureRenderModel(leaf)
	local motor = if side == "Back" then leaf.backMotor else leaf.frontMotor
	if not motor then motor = leaf.frontMotor or leaf.backMotor end
	if not motor then return end
	local axis = tostring(setting(leaf.rig, assembly, "HandleAxis", Config.HandleAxis))
	local pressDeg = tonumber(setting(leaf.rig, assembly, "HandlePressDeg", Config.HandlePressDeg)) or Config.HandlePressDeg
	local damping = tonumber(setting(leaf.rig, assembly, "HandleDamping", Config.HandleDamping)) or Config.HandleDamping
	local frequency = tonumber(setting(leaf.rig, assembly, "HandleFrequency", Config.HandleFrequency)) or Config.HandleFrequency
	local releaseDelay = tonumber(setting(leaf.rig, assembly, "HandleReleaseDelay", Config.HandleReleaseDelay)) or Config.HandleReleaseDelay

	UISpr.target(motor, damping, frequency, {Transform = handleTransform(axis, pressDeg)})
	if locked then
		local jiggle = tonumber(setting(leaf.rig, assembly, "LockedHandleJiggleDeg", Config.LockedHandleJiggleDeg)) or Config.LockedHandleJiggleDeg
		local jiggleDelay = tonumber(setting(leaf.rig, assembly, "LockedHandleJiggleDelay", Config.LockedHandleJiggleDelay)) or Config.LockedHandleJiggleDelay
		task.delay(jiggleDelay, function()
			if motor.Parent then
				UISpr.target(motor, 0.68, frequency * 1.2, {Transform = handleTransform(axis, pressDeg + jiggle)})
			end
		end)
	end
	task.delay(releaseDelay, function()
		if motor.Parent then
			UISpr.target(motor, damping, frequency, {Transform = CFrame.identity})
		end
	end)
end

local function emitKickParticles(leaf: ClientLeaf, count: number)
	local renderModel = ensureRenderModel(leaf)
	if not renderModel then return end
	local emitterName = tostring(Config.KickParticleEmitterName or "KickDust")
	for _, descendant in renderModel:GetDescendants() do
		if descendant:IsA("ParticleEmitter") and descendant.Name == emitterName then
			local parent = descendant.Parent
			local worldCF: CFrame? = nil
			if parent and parent:IsA("Attachment") then
				worldCF = parent.WorldCFrame
			elseif parent and parent:IsA("BasePart") then
				worldCF = parent.CFrame
			end
			if worldCF then
				-- Detach the burst from the render leaf so it survives a same-frame breach
				-- that destroys the client render clone and hands the real leaf to physics.
				local holder = Instance.new("Part")
				holder.Name = "_DoorSystemKickFX"
				holder.Size = Vector3.new(0.05, 0.05, 0.05)
				holder.CFrame = worldCF
				holder.Transparency = 1
				holder.Anchored = true
				holder.CanCollide = false
				holder.CanTouch = false
				holder.CanQuery = false
				holder.Parent = workspace
				local attachment = Instance.new("Attachment")
				attachment.Parent = holder
				local emitter = descendant:Clone()
				emitter.Enabled = false
				emitter.Parent = attachment
				emitter:Emit(math.max(1, math.floor(count)))
				Debris:AddItem(holder, 2.5)
			end
		end
	end
end

local function collectLocalSoundCandidates(container: Instance?, name: string): {Sound}
	local result: {Sound} = {}
	if not container then return result end
	local category = container:FindFirstChild(name)
	if not category then return result end
	if category:IsA("Sound") then
		if category.SoundId ~= "" then table.insert(result, category) end
	elseif category:IsA("Folder") then
		for _, descendant in category:GetDescendants() do
			if descendant:IsA("Sound") and descendant.SoundId ~= "" then
				table.insert(result, descendant)
			end
		end
	end
	return result
end

local function getLocalSoundTemplate(leaf: ClientLeaf, name: string): Sound?
	local leafCandidates = collectLocalSoundCandidates(leaf.rig:FindFirstChild("Sounds"), name)
	if #leafCandidates > 0 then
		return leafCandidates[math.random(1, #leafCandidates)]
	end
	local assembly = findAssembly(leaf.rig)
	local assemblySounds = if assembly then assembly:FindFirstChild("Sounds") else nil
	local assemblyCandidates = collectLocalSoundCandidates(assemblySounds, name)
	if #assemblyCandidates > 0 then
		return assemblyCandidates[math.random(1, #assemblyCandidates)]
	end
	return nil
end

local function playLocalDoorSound(leaf: ClientLeaf, name: string, playbackSpeed: number?, selectedTemplate: Instance?, selectedVolume: number?, channel: string?)
	-- v7.7 server sends the exact selected variant so every player hears the same clip.
	-- Name-only lookup remains as a compatibility fallback for old/custom events.
	local template: Sound? = nil
	if selectedTemplate and selectedTemplate:IsA("Sound") and selectedTemplate.SoundId ~= "" then
		template = selectedTemplate
	else
		template = getLocalSoundTemplate(leaf, name)
	end
	if not template then return end

	-- Motion audio is a single per-leaf channel. A newly-started Open must cut any
	-- lingering Close/CloseStart tail from the previous cycle (and vice versa), so
	-- two mutually-exclusive movement cues can never be heard at the same time.
	if channel == "Motion" then
		local previous = leaf.activeMotionSound
		if previous then
			leaf.activeMotionSound = nil
			if previous.Parent then
				previous:Stop()
				previous:Destroy()
			end
		end
	end

	local renderModel = ensureRenderModel(leaf)
	local parent: Instance? = nil
	if renderModel then
		local audioRoot = renderModel:FindFirstChild("AudioRoot", true)
		if audioRoot and (audioRoot:IsA("Attachment") or audioRoot:IsA("BasePart")) then
			parent = audioRoot
		else
			local root = renderModel:FindFirstChild("Root", true)
			if root and root:IsA("BasePart") then parent = root end
		end
	end
	parent = parent or leaf.promptAnchor or leaf.localCollision or leaf.collision
	if not parent then return end

	local sound = template:Clone()
	sound.PlaybackSpeed = math.max(0.1, playbackSpeed or template.PlaybackSpeed)
	if selectedVolume ~= nil then
		sound.Volume = math.max(0, selectedVolume)
	end
	sound.Parent = parent
	if channel == "Motion" then
		leaf.activeMotionSound = sound
		sound.Ended:Connect(function()
			if leaf.activeMotionSound == sound then
				leaf.activeMotionSound = nil
			end
		end)
	end
	sound:Play()
	Debris:AddItem(sound, math.max(8, sound.TimeLength + 1.5))
end

local function addDoorShake(leaf: ClientLeaf, sign: number, degrees: number, frequency: number, damping: number, velocityScale: number, limitDegrees: number?)
	local direction = if sign < 0 then -1 else 1
	leaf.shakeFrequency = math.max(0.01, frequency)
	leaf.shakeDamping = math.max(0, damping)
	leaf.shakeLimitAngle = math.rad(math.max(0.25, limitDegrees or 42))
	-- Give the visible clone a short torsional hit around the REAL hinge, then let it
	-- ring rapidly inside a strict visual span. Locked rattles therefore feel sharp
	-- without ever resembling a real opening swing. Collision/authority are untouched.
	local displacement = math.rad(degrees) * 0.20
	leaf.shakeAngle = math.clamp(leaf.shakeAngle + direction * displacement, -leaf.shakeLimitAngle, leaf.shakeLimitAngle)
	leaf.shakeVelocity += direction * math.rad(degrees) * velocityScale
end

local function addLockedAttemptShake(leaf: ClientLeaf, sign: number)
	local assembly = findAssembly(leaf.rig)
	local degrees = tonumber(setting(leaf.rig, assembly, "LockedAttemptShakeDeg", Config.LockedAttemptShakeDeg or 5.5)) or 5.5
	local frequency = tonumber(setting(leaf.rig, assembly, "LockedAttemptShakeFrequency", Config.LockedAttemptShakeFrequency or 29.0)) or 29.0
	local damping = tonumber(setting(leaf.rig, assembly, "LockedAttemptShakeDamping", Config.LockedAttemptShakeDamping or 0.08)) or 0.08
	addDoorShake(leaf, sign, degrees, frequency, damping, 15, degrees)
end

local function addKickShake(leaf: ClientLeaf, sign: number, breached: boolean, locked: boolean?)
	local assembly = findAssembly(leaf.rig)
	local degrees: number
	local frequency: number
	local damping: number
	local velocityScale: number
	if breached then
		degrees = tonumber(setting(leaf.rig, assembly, "BreachShakeDeg", Config.BreachShakeDeg or 7.0)) or 7.0
		frequency = tonumber(setting(leaf.rig, assembly, "KickShakeFrequency", Config.KickShakeFrequency or 21.0)) or 21.0
		damping = tonumber(setting(leaf.rig, assembly, "KickShakeDamping", Config.KickShakeDamping or 0.38)) or 0.38
		velocityScale = 7
	elseif locked == true then
		degrees = tonumber(setting(leaf.rig, assembly, "LockedKickShakeDeg", Config.LockedKickShakeDeg or 9.0)) or 9.0
		frequency = tonumber(setting(leaf.rig, assembly, "LockedKickShakeFrequency", Config.LockedKickShakeFrequency or 27.0)) or 27.0
		damping = tonumber(setting(leaf.rig, assembly, "LockedKickShakeDamping", Config.LockedKickShakeDamping or 0.08)) or 0.08
		velocityScale = 17
	else
		degrees = tonumber(setting(leaf.rig, assembly, "KickShakeDeg", Config.KickShakeDeg or 10.0)) or 10.0
		frequency = tonumber(setting(leaf.rig, assembly, "KickShakeFrequency", Config.KickShakeFrequency or 21.0)) or 21.0
		damping = tonumber(setting(leaf.rig, assembly, "KickShakeDamping", Config.KickShakeDamping or 0.38)) or 0.38
		velocityScale = 15
	end
	local limitDegrees = if locked == true and not breached then degrees else 42
	addDoorShake(leaf, sign, degrees, frequency, damping, velocityScale, limitDegrees)
end

local function isStableCollisionMode(mode: string): boolean
	return mode == "Idle"
		or mode == "Locked"
		or mode == "OpenHold"
		or mode == "ExternalOpenHold"
end

local function receivePacket(packet: any)
	if type(packet) ~= "table" then return end
	local packetTime = tonumber(packet.t) or workspace:GetServerTimeNow()
	local states = packet.states
	if type(states) ~= "table" then
		-- Backward-tolerant fallback for old packet shape.
		states = packet
	end
	for _, item in states do
		if type(item) == "table" and typeof(item.rig) == "Instance" and item.rig:IsA("Model") then
			local leaf = ensureLeaf(item.rig)
			if leaf then
				-- A full join snapshot can race a newer live motion packet. Never allow the
				-- older response to rewind a door that the client has already advanced.
				if leaf.initialized and packetTime + 0.002 < leaf.snapshotTime then
					continue
				end
				leaf.snapshotAngle = tonumber(item.angle) or leaf.snapshotAngle
				leaf.snapshotVelocity = tonumber(item.velocity) or 0
				leaf.snapshotAcceleration = tonumber(item.acceleration) or 0
				leaf.snapshotTime = packetTime
				leaf.mode = tostring(item.mode or leaf.mode)
				if item.collisionEnabled ~= nil then
					leaf.collisionEnabled = item.collisionEnabled == true
				end

				-- A settled authoritative state must become physically solid immediately.
				-- Never let an old local push/clearance grace survive after the server says
				-- the leaf is seated closed/locked or resting open.
				if isStableCollisionMode(leaf.mode) then
					localPushStates[leaf.rig] = nil
					leaf.prediction = 0
					leaf.localCollisionYieldUntil = 0
					-- Stable intact doors are always solid. Do not let a stale moving
					-- packet leave the local mirror non-collidable after the leaf settles.
					if not leaf.broken then leaf.collisionEnabled = true end
					-- Preserve v6.9+ relevance optimization: a full late-join snapshot must not
					-- instantiate private collision parts for every door in the map. Repair an
					-- existing mirror immediately, or create one only if this door is close enough
					-- to the local character to need interaction physics now.
					local stableCollision = leaf.localCollision
					if (not stableCollision or not stableCollision.Parent) and localRoot then
						local delta = localRoot.Position - leaf.hinge.Position
						local relevance = Config.ClientInteractionProxyDistance or 48
						if delta:Dot(delta) <= relevance * relevance then
							stableCollision = ensureLocalCollisionMirror(leaf)
						end
					end
					if stableCollision and stableCollision.Parent and leaf.hingeToCollision then
						stableCollision.CFrame = leaf.hinge.CFrame * CFrame.Angles(0, leaf.snapshotAngle, 0) * leaf.hingeToCollision
						stableCollision.CanCollide = not leaf.broken
					end
				end

				local wasBroken = leaf.broken
				leaf.broken = item.broken == true
				if leaf.broken and not wasBroken then
					destroyRenderModel(leaf, true)
				elseif not leaf.broken and wasBroken then
					ensureRenderModel(leaf)
				end

				if not leaf.initialized then
					leaf.visualAngle = leaf.snapshotAngle
					leaf.visualVelocity = leaf.snapshotVelocity
					leaf.initialized = true
				end
			end
		end
	end
end

stateEvent.OnClientEvent:Connect(receivePacket)

local function cosmeticActionRelevant(leaf: ClientLeaf): boolean
	local camera = workspace.CurrentCamera
	if not camera then return false end
	local maxDistance = (Config.ClientFarDistance or 300) + 12
	local delta = camera.CFrame.Position - leaf.hinge.Position
	return delta:Dot(delta) <= maxDistance * maxDistance
end

actionEvent.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" or typeof(payload.rig) ~= "Instance" or not payload.rig:IsA("Model") then return end
	local leaf = ensureLeaf(payload.rig)
	if not leaf then return end
	local kind = tostring(payload.kind)
	local data = if type(payload.data) == "table" then payload.data else {}
	if kind == "Sound" then
		local selectedTemplate = if typeof(data.template) == "Instance" then data.template else nil
		playLocalDoorSound(
			leaf,
			tostring(data.name or ""),
			tonumber(data.playbackSpeed),
			selectedTemplate,
			tonumber(data.volume),
			if data.channel ~= nil then tostring(data.channel) else nil
		)
	elseif kind == "Handle" then
		if cosmeticActionRelevant(leaf) then animateHandle(leaf, tostring(data.side or "Front"), false) end
	elseif kind == "HandleLocked" then
		if cosmeticActionRelevant(leaf) then animateHandle(leaf, tostring(data.side or "Front"), true) end
	elseif kind == "LockedAttempt" then
		if cosmeticActionRelevant(leaf) then
			addLockedAttemptShake(leaf, tonumber(data.sign) or 1)
		end
	elseif kind == "Kick" then
		if cosmeticActionRelevant(leaf) then
			local sign = tonumber(data.sign) or 1
			-- The exact kick that breaks the latch gets the separate, subtle Breach spring
			-- below instead of stacking a full locked-kick shake on top of it.
			if data.breaching ~= true then
				addKickShake(leaf, sign, false, data.locked == true)
			end
			emitKickParticles(leaf, tonumber(data.particles) or Config.KickParticleCount or 12)
		end
	elseif kind == "Breach" then
		if cosmeticActionRelevant(leaf) then
			local sign = tonumber(data.sign) or 1
			addKickShake(leaf, sign, true, false)
			emitKickParticles(leaf, tonumber(data.particles) or Config.BreachParticleCount or 28)
		end
	elseif kind == "Break" then
		leaf.broken = true
		leaf.prediction = 0
		destroyRenderModel(leaf, true)
	elseif kind == "Reset" then
		leaf.broken = false
		leaf.snapshotAngle = 0
		leaf.snapshotVelocity = 0
		leaf.snapshotAcceleration = 0
		leaf.snapshotTime = workspace:GetServerTimeNow()
		leaf.visualAngle = 0
		leaf.visualVelocity = 0
		leaf.prediction = 0
		leaf.shakeAngle = 0
		leaf.shakeVelocity = 0
		leaf.shakeFrequency = Config.KickShakeFrequency
		leaf.shakeDamping = Config.KickShakeDamping
		leaf.shakeLimitAngle = math.rad(42)
		leaf.collisionEnabled = true
		leaf.localCollisionYieldUntil = 0
		leaf.initialized = true
		ensureRenderModel(leaf)
	end
end)

local function refreshCharacter()
	local character = player.Character
	if not character then
		localRoot = nil
		localHumanoid = nil
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	localRoot = if root and root:IsA("BasePart") then root else nil
	localHumanoid = if humanoid and humanoid.Health > 0 then humanoid else nil
end

local function destroyLocalInteractionProxies(leaf: ClientLeaf)
	if leaf.promptAnchor then
		leaf.promptAnchor:Destroy()
		leaf.promptAnchor = nil
		leaf.promptOffset = nil
		leaf.doorPrompt = nil
		leaf.lockPrompt = nil
		leaf.kickPrompt = nil
	end
	if leaf.localCollision then
		leaf.localCollision:Destroy()
		leaf.localCollision = nil
	end
	if leaf.collision and leaf.collision.Parent and not leaf.broken and leaf.sourceCollisionCanCollide ~= nil then
		leaf.collision.CanCollide = leaf.sourceCollisionCanCollide
	end
	leaf.sourceCollisionCanCollide = nil
	leaf.localCollisionYieldUntil = 0
	localPushStates[leaf.rig] = nil
end

local function refreshRenderLeaves()
	table.clear(renderLeaves)
	table.clear(pushLeaves)
	local camera = workspace.CurrentCamera
	if not camera then return end
	local cameraPosition = camera.CFrame.Position
	local farSq = Config.ClientFarDistance * Config.ClientFarDistance
	local pushDistance = Config.ClientPushCandidateDistance or 18
	local pushSq = pushDistance * pushDistance
	local interactionDistance = Config.ClientInteractionProxyDistance or 48
	local interactionSq = interactionDistance * interactionDistance
	local rootPosition = localRoot and localRoot.Position or nil
	for rig, leaf in leaves do
		if not rig.Parent then
			if leaf.renderModel then leaf.renderModel:Destroy() end
			destroyLocalInteractionProxies(leaf)
			leaves[rig] = nil
		else
			if not leaf.collision or not leaf.collision.Parent then
				local candidate = rig:FindFirstChild("DoorCollision")
				if candidate and candidate:IsA("BasePart") then
					leaf.collision = candidate
					leaf.hingeToCollision = leaf.hinge.CFrame:ToObjectSpace(candidate.CFrame)
				end
			end

			local rootDistanceSq = math.huge
			if rootPosition then
				local rootDelta = rootPosition - leaf.hinge.Position
				rootDistanceSq = rootDelta:Dot(rootDelta)
			end

			-- Interaction-only objects are local-player relevant, not camera relevant.
			-- This avoids accumulating hundreds of invisible collision/prompt instances
			-- while preserving the full-fidelity render clone for visible doors.
			if not leaf.broken and rootDistanceSq <= interactionSq then
				ensureLocalCollisionMirror(leaf)
				ensureLocalPromptProxy(leaf)
				updateLocalPromptState(leaf)
			elseif leaf.localCollision or leaf.promptAnchor then
				destroyLocalInteractionProxies(leaf)
			end

			if not leaf.broken then
				local camDelta = cameraPosition - leaf.hinge.Position
				if camDelta:Dot(camDelta) <= farSq then
					table.insert(renderLeaves, leaf)
				end
				if rootDistanceSq <= pushSq then
					table.insert(pushLeaves, leaf)
				end
			end
		end
	end
end

local function updateLocalPrediction(leaf: ClientLeaf, dt: number): number
	if not Config.PredictionEnabled or not localRoot or not localHumanoid then
		leaf.prediction *= math.exp(-Config.PredictionDecay * dt)
		return leaf.prediction
	end
	local assembly = findAssembly(leaf.rig)
	if assembly and assembly:GetAttribute("Locked") == true then
		leaf.prediction *= math.exp(-Config.PredictionDecay * dt)
		return leaf.prediction
	end

	local collision = leaf.localCollision or leaf.collision
	local desired = 0
	if collision and collision.Parent then
		local velocity = localRoot.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
		local intent = localHumanoid.MoveDirection * Vector3.new(1, 0, 1)
		if velocity.Magnitude < 0.8 and intent.Magnitude > 0.05 then
			velocity = intent.Unit * math.max(localHumanoid.WalkSpeed, 0.8)
		end
		if velocity.Magnitude > 0.8 and intent.Magnitude > 0.05 then
			local cf = collision.CFrame
			local half = collision.Size * 0.5
			local localPos = cf:PointToObjectSpace(localRoot.Position)
			local localVel = cf:VectorToObjectSpace(velocity)
			local inputWorld = intent.Unit
			local inputLocal = cf:VectorToObjectSpace(inputWorld)
			local movingToward = localPos.Z * inputLocal.Z < -0.045
			local lateralOk = math.abs(localPos.X) <= half.X + (Config.PushSidePadding or 1.0)
			local heightOk = math.abs(localPos.Y) <= half.Y + 0.7
			local surfaceGap = math.max(0, math.abs(localPos.Z) - half.Z)
			local normalSpeed = math.abs(localVel.Z)
			local maxLead = Config.PushMaxLeadTime or 0.095
			local contactGap = Config.PushContactSurfaceGap or 1.48
			local timeToSurface = if normalSpeed > 0.05 then surfaceGap / normalSpeed else math.huge
			local inLeadWindow = surfaceGap <= contactGap
				or (timeToSurface <= maxLead and surfaceGap <= contactGap + (Config.PushLeadExtraGap or 0.52))

			if movingToward and lateralOk and heightOk and inLeadWindow then
				local contactLocal = Vector3.new(
					math.clamp(localPos.X, -half.X, half.X),
					math.clamp(localPos.Y, -half.Y, half.Y),
					0
				)
				local contactWorld = cf:PointToWorldSpace(contactLocal)
				local hingeAxis = leaf.hinge.CFrame.UpVector
				local radius = contactWorld - leaf.hinge.Position
				-- Side determines direction. Speed only determines magnitude. This prevents a
				-- previously prompt-opened/rotated leaf from predicting back toward the pusher.
				local sideSign = if localPos.Z >= 0 then 1 else -1
				local normalForce = -cf.ZVector * sideSign
				local torque = hingeAxis:Dot(radius:Cross(normalForce))
				local sign = if torque < 0 then -1 else 1
				local preserveDirectionAngle = math.rad(tonumber(setting(leaf.rig, assembly, "PushPreserveOpenDirectionDeg", Config.PushPreserveOpenDirectionDeg)) or Config.PushPreserveOpenDirectionDeg)
				if math.abs(leaf.snapshotAngle) >= preserveDirectionAngle and leaf.snapshotAngle * sign < 0 then
					sign = if leaf.snapshotAngle < 0 then -1 else 1
				end
				local closeness = if surfaceGap <= contactGap then 1 else math.clamp(1 - timeToSurface / math.max(maxLead, 1e-3), 0, 1) * 0.45
				local maxPred = math.rad(tonumber(setting(leaf.rig, assembly, "PredictionMaxDeg", Config.PredictionMaxDeg)) or Config.PredictionMaxDeg)
				local speedFactor = math.clamp(normalSpeed / 14, 0.35, 1.55)
				desired = sign * maxPred * closeness * speedFactor
			end
		end
	end

	local decay = tonumber(setting(leaf.rig, assembly, "PredictionDecay", Config.PredictionDecay)) or Config.PredictionDecay
	local alpha = 1 - math.exp(-decay * dt)
	leaf.prediction += (desired - leaf.prediction) * alpha
	return leaf.prediction
end

-- Client-assisted contact intent. This does not move the authoritative door; it
-- merely tells the server which nearby leaf we are genuinely approaching. The
-- server re-validates position, movement, lock state and computes the impulse.
local function scanLocalPushIntent(now: number)
	if not localRoot or not localHumanoid then
		return
	end

	local movement = localRoot.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
	if movement.Magnitude < 0.65 then
		local md = localHumanoid.MoveDirection * Vector3.new(1, 0, 1)
		if md.Magnitude > 0.05 then
			movement = md.Unit * math.max(localHumanoid.WalkSpeed * 0.82, 0.8)
		end
	end
	if movement.Magnitude < 0.65 then
		return
	end

	for _, leaf in pushLeaves do
		if leaf.broken then
			continue
		end
		local assembly = findAssembly(leaf.rig)
		if not assembly or assembly:GetAttribute("Locked") == true then
			continue
		end
		if setting(leaf.rig, assembly, "PushEnabled", true) == false then
			continue
		end

		local collision = leaf.localCollision or leaf.collision
		if not collision or not collision.Parent then
			local candidate = leaf.rig:FindFirstChild("DoorCollision")
			if candidate and candidate:IsA("BasePart") then
				collision = candidate
				leaf.collision = candidate
			end
		end
		if not collision then
			continue
		end


		local cf = collision.CFrame
		local half = collision.Size * 0.5
		local predictionTime = Config.PushPredictionTime or 0.07
		local currentLocal = cf:PointToObjectSpace(localRoot.Position)
		local futureLocal = cf:PointToObjectSpace(localRoot.Position + movement * predictionTime)
		local localVelocity = cf:VectorToObjectSpace(movement)
		local sidePadding = Config.PushSidePadding or 0.72
		local lateralOk = math.abs(currentLocal.X) <= half.X + sidePadding
			or math.abs(futureLocal.X) <= half.X + sidePadding
		local heightOk = math.abs(currentLocal.Y) <= half.Y + 0.70
			or math.abs(futureLocal.Y) <= half.Y + 0.70
		local inputWorld = if localHumanoid.MoveDirection.Magnitude > 0.05
			then localHumanoid.MoveDirection.Unit
			else movement.Unit
		local inputLocal = cf:VectorToObjectSpace(inputWorld)
		local movingToward = currentLocal.Z * inputLocal.Z < -0.045

		-- Use distance to the actual slab surface, not a broad proximity volume.
		-- For an R15 character the root can remain about one stud away when the body
		-- is physically touching the door, hence the small configurable surface gap.
		local surfaceGap = math.max(0, math.abs(currentLocal.Z) - half.Z)
		local futureGap = math.max(0, math.abs(futureLocal.Z) - half.Z)
		local contactGap = Config.PushContactSurfaceGap or 1.15
		local normalSpeed = math.abs(localVelocity.Z)
		local timeToSurface = if normalSpeed > 0.05 then surfaceGap / normalSpeed else math.huge
		local imminent = timeToSurface <= (Config.PushMaxLeadTime or 0.11)
			and futureGap < surfaceGap
			and surfaceGap <= contactGap + (Config.PushLeadExtraGap or 0.42)
		local touchingRange = surfaceGap <= contactGap

		if lateralOk and heightOk and movingToward and (touchingRange or imminent) then
			-- Compute a fresh AWAY-FROM-PLAYER hinge sign from the CURRENT leaf pose.
			-- Never reuse the previous prompt/open direction.
			local contactLocal = Vector3.new(
				math.clamp(currentLocal.X, -half.X, half.X),
				math.clamp(currentLocal.Y, -half.Y, half.Y),
				0
			)
			local contactWorld = cf:PointToWorldSpace(contactLocal)
			local hingeAxis = leaf.hinge.CFrame.UpVector
			local radius = contactWorld - leaf.hinge.Position
			local sideSign = if currentLocal.Z >= 0 then 1 else -1
			local normalForce = -cf.ZVector * sideSign
			local torque = hingeAxis:Dot(radius:Cross(normalForce))
			local openSign = if torque < 0 then -1 else 1
			local preserveDirectionAngle = math.rad(tonumber(setting(leaf.rig, assembly, "PushPreserveOpenDirectionDeg", Config.PushPreserveOpenDirectionDeg)) or Config.PushPreserveOpenDirectionDeg)
			if math.abs(leaf.snapshotAngle) >= preserveDirectionAngle and leaf.snapshotAngle * openSign < 0 then
				openSign = if leaf.snapshotAngle < 0 then -1 else 1
			end

			-- A seated/closing door must remain physically solid until the authoritative
			-- snapshot proves it has actually started opening AWAY from this player. We still
			-- send Push immediately, so walk-open responsiveness is preserved without the
			-- one-frame ghost-door window that existed while a door was finishing its close.
			local closedSolidAngle = math.rad(Config.ClosedCollisionSolidAngleDeg or 6.0)
			local inClosedSolidZone = math.abs(leaf.snapshotAngle) <= closedSolidAngle
			local authoritativeOpeningAway = leaf.snapshotVelocity * openSign >= math.rad(Config.LocalPushYieldMinAngularSpeedDeg or 28)
			if not inClosedSolidZone or authoritativeOpeningAway then
				localPushStates[leaf.rig] = {
					expiresAt = now + (Config.LocalPushCollisionYieldTime or 0.16),
					sign = openSign,
					normalSpeed = normalSpeed,
					surfaceGap = surfaceGap,
				}
			else
				localPushStates[leaf.rig] = nil
				leaf.localCollisionYieldUntil = 0
			end

			local last = pushSentAt[leaf.rig] or -math.huge
			if now - last >= (Config.PushSendInterval or 0.045) then
				pushSentAt[leaf.rig] = now
				pushEvent:FireServer(leaf.rig)
			end
		end
	end
end

local function renderLeaf(leaf: ClientLeaf, dt: number, serverNow: number, cameraPosition: Vector3)
	if leaf.broken or not leaf.leafModel.Parent then return end
	local renderModel = ensureRenderModel(leaf)
	if not renderModel then return end
	local assembly = findAssembly(leaf.rig)
	local dormantAngleEps = math.rad(Config.ClientDormantAngleEpsilonDeg or 0.025)
	local dormantVelocityEps = math.rad(Config.ClientDormantVelocityEpsilonDeg or 0.20)
	local dormantStable = isStableCollisionMode(leaf.mode)
	local dormantClosedSolidAngle = math.rad(Config.ClosedCollisionSolidAngleDeg or 6.0)
	if dormantStable and math.abs(leaf.snapshotAngle) <= dormantClosedSolidAngle and not leaf.broken then
		-- Repair collision BEFORE the dormant fast-path. A previous push-yield must never
		-- survive into a visually/authoritatively closed door, even for a single frame.
		leaf.localCollisionYieldUntil = 0
		localPushStates[leaf.rig] = nil
		leaf.collisionEnabled = true
		local closedMirror = leaf.localCollision
		if closedMirror and closedMirror.Parent and leaf.hingeToCollision then
			closedMirror.CFrame = leaf.hinge.CFrame * CFrame.Angles(0, leaf.snapshotAngle, 0) * leaf.hingeToCollision
			closedMirror.CanCollide = true
		end
	end
	if leaf.initialized
		and dormantStable
		and math.abs(leaf.snapshotVelocity) <= dormantVelocityEps
		and math.abs(leaf.snapshotAcceleration) <= dormantVelocityEps
		and math.abs(leaf.prediction) <= dormantAngleEps
		and math.abs(leaf.lastAppliedAngle - leaf.snapshotAngle) <= dormantAngleEps
		and math.abs(leaf.shakeAngle) <= math.rad(0.01)
		and math.abs(leaf.shakeVelocity) <= math.rad(0.05)
		and localPushStates[leaf.rig] == nil
	then
		return
	end
	local age = math.clamp(serverNow - leaf.snapshotTime, 0, Config.ClientMaxExtrapolation)
	local desiredAngle = leaf.snapshotAngle + leaf.snapshotVelocity * age + 0.5 * leaf.snapshotAcceleration * age * age
	local desiredVelocity = leaf.snapshotVelocity + leaf.snapshotAcceleration * age
	local maxAngle = math.rad(tonumber(setting(leaf.rig, assembly, "MaxAngleDeg", 108)) or 108)
	desiredAngle = math.clamp(desiredAngle, -maxAngle, maxAngle)

	local stableCollisionState = isStableCollisionMode(leaf.mode)
	local closedSolidAngle = math.rad(Config.ClosedCollisionSolidAngleDeg or 6.0)
	local openingAwayFromSeat = math.abs(leaf.snapshotVelocity) >= math.rad(Config.LocalPushYieldMinAngularSpeedDeg or 28)
		and (math.abs(leaf.snapshotAngle) <= math.rad(0.05) or leaf.snapshotAngle * leaf.snapshotVelocity > 0)
	local closedSeatSolid = math.abs(leaf.snapshotAngle) <= closedSolidAngle
		and not openingAwayFromSeat
		and leaf.mode ~= "PromptOpening"
		and leaf.mode ~= "ExternalOpening"
	if closedSeatSolid then
		stableCollisionState = true
		leaf.localCollisionYieldUntil = 0
		localPushStates[leaf.rig] = nil
		if not leaf.broken then
			leaf.collisionEnabled = true
		end
	end
	if stableCollisionState and math.abs(leaf.snapshotVelocity) <= math.rad(2.5) then
		-- Stable state packets are authoritative snap points. This prevents the
		-- collision mirror from spending another few rendered frames at a stale
		-- interpolated pose after the visible door has effectively finished.
		leaf.prediction = 0
		desiredAngle = leaf.snapshotAngle
		desiredVelocity = 0
	end

	local cameraDelta = cameraPosition - leaf.hinge.Position
	local distanceSq = cameraDelta:Dot(cameraDelta)
	local nearDistanceSq = Config.ClientNearDistance * Config.ClientNearDistance
	if not stableCollisionState and localRoot then
		local rootDelta = localRoot.Position - leaf.hinge.Position
		if rootDelta:Dot(rootDelta) <= 169 then
			desiredAngle += updateLocalPrediction(leaf, dt)
		else
			leaf.prediction *= math.exp(-Config.PredictionDecay * dt)
		end
	else
		leaf.prediction *= math.exp(-Config.PredictionDecay * dt)
	end

	leaf.renderAccumulator += dt
	local updateDt = dt
	local movingEstimate = math.abs(desiredVelocity) > math.rad(0.25)
		or math.abs(leaf.snapshotAcceleration) > math.rad(0.5)
		or math.abs(desiredAngle - leaf.visualAngle) > math.rad(0.03)
		or math.abs(leaf.prediction) > math.rad(0.02)
		or math.abs(leaf.shakeAngle) > math.rad(0.01)
		or math.abs(leaf.shakeVelocity) > math.rad(0.05)
	if not movingEstimate and math.abs(leaf.lastAppliedAngle - desiredAngle) < math.rad(0.02) then
		return
	end
	if distanceSq > nearDistanceSq then
		if leaf.renderAccumulator < (1 / 30) then
			return
		end
		updateDt = leaf.renderAccumulator
	end
	leaf.renderAccumulator = 0

	local frequency = if distanceSq <= nearDistanceSq then Config.ClientTrackingFrequency else Config.ClientFarTrackingFrequency
	local damping = if distanceSq <= nearDistanceSq then Config.ClientTrackingDamping else Config.ClientFarTrackingDamping
	frequency = tonumber(setting(leaf.rig, assembly, "ClientTrackingFrequency", frequency)) or frequency
	damping = tonumber(setting(leaf.rig, assembly, "ClientTrackingDamping", damping)) or damping

	local error = desiredAngle - leaf.visualAngle
	local hardCorrection = math.rad(Config.ClientHardCorrectionDeg)
	if stableCollisionState then
		leaf.visualAngle = desiredAngle
		leaf.visualVelocity = 0
	elseif math.abs(error) >= hardCorrection then
		leaf.visualAngle = desiredAngle
		leaf.visualVelocity = desiredVelocity
	else
		-- Stable feed-forward tracking spring. 'frequency' here is response rate;
		-- desiredVelocity prevents the common spring-behind-moving-target lag.
		local omega = math.max(0.01, frequency)
		local h = math.min(updateDt, 1 / 30)
		local substeps = math.max(1, math.ceil(h / (1 / 120)))
		local step = h / substeps
		for _ = 1, substeps do
			local accel = (desiredAngle - leaf.visualAngle) * (omega * omega)
				+ (desiredVelocity - leaf.visualVelocity) * (2 * damping * omega)
			leaf.visualVelocity += accel * step
			leaf.visualAngle += leaf.visualVelocity * step
		end
	end

	-- Client-only torsional recoil for kicks. It is additive and never feeds back
	-- into authoritative angle/collision, so it can look punchy without destabilizing
	-- the actual hinge simulation.
	local shakeFrequency = leaf.shakeFrequency
	local shakeDamping = leaf.shakeDamping
	if math.abs(leaf.shakeAngle) > 1e-5 or math.abs(leaf.shakeVelocity) > 1e-5 then
		local shakeAccel = -leaf.shakeAngle * (shakeFrequency * shakeFrequency)
			- leaf.shakeVelocity * (2 * shakeDamping * shakeFrequency)
		leaf.shakeVelocity += shakeAccel * updateDt
		leaf.shakeAngle += leaf.shakeVelocity * updateDt
		local limit = math.max(math.rad(0.25), leaf.shakeLimitAngle)
		if math.abs(leaf.shakeAngle) > limit then
			leaf.shakeAngle = math.sign(leaf.shakeAngle) * limit
			if leaf.shakeAngle * leaf.shakeVelocity > 0 then
				leaf.shakeVelocity *= -0.32
			end
		end
		if math.abs(leaf.shakeAngle) < math.rad(0.015) and math.abs(leaf.shakeVelocity) < math.rad(0.08) then
			leaf.shakeAngle = 0
			leaf.shakeVelocity = 0
		end
	end

	local baseHingeRotation = leaf.hinge.CFrame * CFrame.Angles(0, leaf.visualAngle, 0)
	local visualHingeRotation = leaf.hinge.CFrame * CFrame.Angles(0, leaf.visualAngle + leaf.shakeAngle, 0)
	renderModel:PivotTo(visualHingeRotation * leaf.hingeToLeaf)
	leaf.lastAppliedAngle = leaf.visualAngle

	-- Prompt proxy deliberately follows the stable authoritative visual angle, not
	-- the cosmetic kick shake, so interaction UI never jitters during impacts.
	-- eliminating the stair-step/jitter of a prompt attached to the replicated
	-- server collision proxy.
	if leaf.promptAnchor and leaf.hingeToCollision and leaf.promptOffset then
		leaf.promptAnchor.CFrame = baseHingeRotation * leaf.hingeToCollision * leaf.promptOffset
	end
	updateLocalPromptState(leaf)

	-- Local collision mirror: the local player collides with a private slab that is
	-- driven from the exact same render-frame hinge angle as the visible clone. The
	-- replicated authoritative slab is kept non-collidable on this client only, so a
	-- delayed server CFrame cannot block the player halfway through a visually open door.
	if not leaf.collision or not leaf.collision.Parent then
		local candidate = leaf.rig:FindFirstChild("DoorCollision")
		if candidate and candidate:IsA("BasePart") then
			leaf.collision = candidate
			leaf.hingeToCollision = leaf.hinge.CFrame:ToObjectSpace(candidate.CFrame)
			leaf.sourceCollisionCanCollide = nil
		end
	end
	local localCollision = ensureLocalCollisionMirror(leaf)
	if localCollision and leaf.hingeToCollision then
		localCollision.CFrame = baseHingeRotation * leaf.hingeToCollision

		-- Per-player hybrid collision: only THIS client can yield its private proxy while
		-- they are actively driving the leaf AWAY from their current side. The server
		-- collider and every other player's private proxy remain solid.
		local shouldYield = false
		local pushState = localPushStates[leaf.rig]
		local locked = assembly and assembly:GetAttribute("Locked") == true
		local externalForcedMotion = leaf.mode == "ExternalOpening"
			or leaf.mode == "ExternalClosing"
			or leaf.mode == "ExternalLockClosing"
		if externalForcedMotion then
			-- Script/API state commands own the door until their target is reached.
			-- Do not preserve a stale local push-through window that can make a forced
			-- Open/Close/Lock look non-solid or interfere with deterministic motion.
			leaf.localCollisionYieldUntil = 0
			localPushStates[leaf.rig] = nil
			pushState = nil
		elseif stableCollisionState then
			leaf.localCollisionYieldUntil = 0
			localPushStates[leaf.rig] = nil
			pushState = nil
		elseif Config.LocalPushCollisionYield == true and not locked and pushState and serverNow <= pushState.expiresAt then
			local minPred = math.rad(Config.LocalPushYieldMinPredictionDeg or 2.5)
			local minSpeed = math.rad(Config.LocalPushYieldMinAngularSpeedDeg or 28)
			local movingAway = leaf.visualVelocity * pushState.sign >= minSpeed
			local predictedAway = leaf.prediction * pushState.sign >= minPred
			if movingAway or predictedAway then
				shouldYield = true
				leaf.localCollisionYieldUntil = math.max(leaf.localCollisionYieldUntil, serverNow + (Config.LocalPushCollisionYieldTime or 0.16))
			end
		end

		-- Never re-enable the proxy inside the local avatar. Keep yielding for a tiny
		-- clearance window until the root has crossed/cleared the moving slab.
		if not shouldYield and not stableCollisionState and serverNow < leaf.localCollisionYieldUntil and localRoot then
			local lp = localCollision.CFrame:PointToObjectSpace(localRoot.Position)
			local half = localCollision.Size * 0.5
			local clearance = Config.LocalPushYieldClearance or 0.72
			local stillInside = math.abs(lp.X) <= half.X + 0.9
				and math.abs(lp.Y) <= half.Y + 0.8
				and math.abs(lp.Z) <= half.Z + clearance
			if stillInside then
				-- Preserve only the original short grace. Do NOT extend it forever
				-- while the avatar remains inside the slab; that created ghost doors
				-- after newly-open/newly-closed state transitions.
				shouldYield = true
			end
		end

		localCollision.CanCollide = leaf.collisionEnabled and not shouldYield
	end
end

for _, tagged in CollectionService:GetTagged(Config.Tag) do
	if tagged:IsA("Model") then discoverAssembly(tagged) end
end
CollectionService:GetInstanceAddedSignal(Config.Tag):Connect(function(inst)
	if inst:IsA("Model") then task.defer(discoverAssembly, inst) end
end)

player.CharacterAdded:Connect(function() task.defer(refreshCharacter) end)
refreshCharacter()
refreshRenderLeaves()

RunService.RenderStepped:Connect(function(dt)
	nearAccumulator += dt
	local relevanceStep = 1 / (Config.ClientRelevanceRefreshHz or 8)
	if nearAccumulator >= relevanceStep then
		nearAccumulator = 0
		refreshCharacter()
		refreshRenderLeaves()
	end
	local camera = workspace.CurrentCamera
	if not camera then return end
	local now = workspace:GetServerTimeNow()
	pushScanAccumulator += dt
	if pushScanAccumulator >= (1 / (Config.LocalPushScanHz or 60)) then
		pushScanAccumulator = 0
		scanLocalPushIntent(now)
	end
	local cameraPosition = camera.CFrame.Position
	for _, leaf in renderLeaves do
		renderLeaf(leaf, dt, now, cameraPosition)
	end
end)

-- Initial authoritative state for doors already open/moving when the client joins.
task.spawn(function()
	local ok, packet = pcall(function()
		return snapshotFunction:InvokeServer({full = true, protocol = Config.SnapshotProtocolVersion or 2})
	end)
	if ok then receivePacket(packet) end
end)
