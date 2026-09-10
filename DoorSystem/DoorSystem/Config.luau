--!strict
-- Door System
-- Server-authoritative virtual rigid-body hinge with client-side dead reckoning.
-- All values can be overridden with Attributes on the top-level assembly or LeafRig.

return table.freeze({
	Version = "7.8.0",
	VersionName = "DoorSystem v7.8",
	Tag = "DoorSystemDoor",
	RemotesFolderName = "DoorSystemRemotes",

	-- Active-door simulation / networking
	SimulationHz = 60,
	PlayerScanHz = 30,
	OccupancyHz = 30,
	ReplicationHz = 20,
	ReplicationDistance = 240,
	-- Joining clients receive one full authoritative snapshot, regardless of distance.
	-- Normal moving-door replication remains distance culled after bootstrap.
	LateJoinFullSnapshot = true,
	SnapshotProtocolVersion = 2,
	SpatialCellSize = 32,
	SleepAngleDeg = 0.08,
	SleepVelocityDeg = 0.20,

	-- PER-DOOR ATTRIBUTE OVERRIDES
	-- Any value read through `setting(...)` can be overridden on the tagged assembly,
	-- and the same attribute on a LeafRig overrides the assembly for that leaf. Common:
	-- AutoClose, AutoCloseDelay, PromptHoldOpenTime, PromptOpenAngleDeg, MaxAngleDeg,
	-- PushEnabled, VirtualMass, EffectivePlayerMass, ReturnStiffness/ReturnDamping,
	-- MaxHealth, StartingHealth, Breakable, KickDamageMin/Max, SafetyEnabled,
	-- WalkPushHandleEnabled, HandlePressDeg, SoundEnabled, SoundVolumeScale,
	-- SoundPitchScale, SoundReplicationDistance, PromptDistance, KickPromptEnabled.
	-- Common defaults are also published onto newly registered assemblies so these
	-- settings are visible/editable directly in Studio's Attributes panel. Existing
	-- authored values are never overwritten.
	PublishDefaultConfigurationAttributes = true,

	-- Core behavior
	PushEnabled = true,
	PromptEnabled = true,
	CustomPromptStyle = true,
	LockPromptEnabled = false,
	AllowPlayerLocking = false,
	-- LockType="Key" requires an inventory item whose DoorKeyId matches
	-- RequiredKeyId. LockType="Side" requires LockSide ("Front"/"Back") and
	-- no item. Existing doors default to None and retain their old behavior.
	LockType = "None",
	LockSide = "Front",
	RequiredKeyId = "",
	RequiredItemName = "",
	RequiredItemCategory = "DoorKey",
	OpenRequiresItem = false,
	UseRequirementChecker = true,
	HideUnavailablePrompts = false,
	AutoClose = true,
	AutoCloseDelay = 0.85,
	-- Ignore tiny hinge vibrations when deciding whether an automatic return is needed.
	AutoCloseMinimumAngleDeg = 1.25,
	-- Optional extra delay after a door was prompt-opened before AutoCloseDelay begins to matter.
	-- PromptHoldOpenTime already controls prompt-open hold; this value is mainly useful for
	-- physically pushed doors and defaults to zero for backwards-compatible timing.
	AutoCloseExtraHoldTime = 0,
	PromptHoldOpenTime = 1.8,
	PromptOpenAngleDeg = 88,
	-- "Single" only operates the interacted leaf; "All" operates every leaf in an assembly.
	PromptOpenMode = "Single",
	-- 0 = choose side dynamically. -1 / +1 can force an authored opening direction.
	OpenSign = 0,
	ExternalOpenSign = 0,
	PromptCloseThresholdDeg = 12,
	PromptPreserveOpenDirectionDeg = 5,
	MaxAngleDeg = 108,

	-- Virtual rigid-body hinge.
	-- VirtualMass is an authored feel value, not Roblox AssemblyMass.
	VirtualMass = 5.6,
	EffectivePlayerMass = 11.5,
	PushImpulseScale = 0.52,
	ContinuousPushScale = 0.50,
	PushIntentGrace = 0.24,
	PushDriveResponse = 14.5,
	PushDriveRampTime = 0.010,
	PushDriveMaxAccelerationDeg = 5200,
	-- While a player is actively pushing, the hinge also tries to match the linear
	-- speed at the contact radius. This is what makes sprinting open the leaf faster
	-- instead of merely applying the same weak torque as walking.
	PushFollowVelocityScale = 0.72,
	PushFollowVelocityResponse = 15.0,
	PushFollowMinAngularSpeedDeg = 105,
	PushFollowMaxAngularSpeedDeg = 470,
	PushFollowMaxAccelerationDeg = 4400,
	-- Preserve the approach speed for a fraction of a second after the avatar hits the
	-- solid slab. Otherwise Roblox collision can zero AssemblyLinearVelocity and make
	-- sprinting paradoxically push LESS than walking.
	PushSpeedMemoryDecay = 2.6,
	PushIntentSpeedFraction = 0.92,
	PushMaxEffectiveSpeed = 34,
	PreContactDriveScale = 0.26,
	-- Push acquisition is intentionally contact-biased. The character root may still
	-- be ~1-1.5 studs from a solid slab when the avatar body makes contact, so this
	-- is not zero; it accounts for the avatar capsule while staying contact-biased.
	PushDriveNearDepth = 1.72,
	PushMinimumSpeed = 0.75,
	PushFallbackWalkSpeed = 12.5,
	PushLeadExtraGap = 0.52,
	MinimumPushLeverFraction = 0.28,
	PushCollisionYieldTime = 0,
	PushCollisionYieldMinAccelDeg = 99999,
	HybridCollision = false,
	OpeningCollisionYieldSpeedDeg = 99999,
	ContactPredictionTime = 0.10,
	ContactDepth = 1.20,
	ContactSidePadding = 1.00,
	ContactHeightPadding = 0.65,
	PushMaxLeadTime = 0.095,
	PushContactSurfaceGap = 1.48,
	ContactRetriggerTime = 0.24,
	MaxPushDistanceFromHinge = 10.5,
	MinimumInitialAngularSpeedDeg = 0,
	-- A weak cap is used in the predictive zone; once the avatar capsule is actually
	-- at the slab, allow a much stronger initial yield so the solid collision does
	-- not feel like an anchored wall.
	StrongContactSurfaceGap = 1.48,
	PreContactInitialPushMaxAngularSpeedDeg = 6,
	InitialPushMaxAngularSpeedDeg = 36,
	MaxAngularSpeedDeg = 320,
	FreeDrag = 0.95,
	LimitBounce = 0.16,
	-- Ordinary pushed/free-swinging doors compress a damped spring before the hard
	-- hinge stop. The hard clamp remains only as an overshoot safety fallback.
	LimitSpringEnabled = true,
	LimitSpringRangeDeg = 16,
	LimitSpringStiffness = 60,
	LimitSpringDamping = 14,
	LimitSpringMaxAccelerationDeg = 6000,

	-- Return spring after free-swing/coast.
	ReturnStiffness = 13.5,
	ReturnDamping = 6.7,
	ReturnMaxAccelerationDeg = 620,

	-- Prompt / handle guided motion.
	PromptOpenStiffness = 31,
	PromptOpenDamping = 10.2,
	PromptOpenMaxAccelerationDeg = 1500,
	PromptCloseStiffness = 29,
	PromptCloseDamping = 9.8,
	PromptCloseMaxAccelerationDeg = 1400,
	PromptOpenCommandMinSpeedDeg = 105,
	PromptCloseCommandMinSpeedDeg = 100,
	PromptCloseOperatorGrace = 0.52,

	-- External/server state commands. These are intentionally much stronger than
	-- player prompt springs: they cancel push/kick momentum and decisively reach the
	-- requested state from any intermediate angle or velocity.
	ExternalOpenStiffness = 52,
	ExternalOpenDamping = 13.5,
	ExternalOpenMaxAccelerationDeg = 9000,
	ExternalCloseStiffness = 68,
	ExternalCloseDamping = 15.5,
	ExternalCloseMaxAccelerationDeg = 12500,
	ExternalOpenCommandMinSpeedDeg = 280,
	ExternalCloseCommandMinSpeedDeg = 360,
	ExternalCommandMaxAngularSpeedDeg = 760,
	ExternalOpenAngleDeg = 92,
	ExternalOpenUnlocks = true,
	ExternalLockRepairsBrokenLock = true,
	-- Compatibility/readability attribute retained from earlier versions. External/API
	-- Open/Close/Lock are authoritative in v7.7 and always bypass obstruction safety.
	ExternalCommandIgnoreSafety = true,

	-- Public state attributes are also external server controls.
	-- Open=true / Closed=false force Open; Open=false / Closed=true force Close.
	-- Locked=true/false and DoorState = "Open"/"Closed"/"Locked"/"Unlocked"
	-- are also authoritative commands. System-authored readback writes are guarded.
	-- Stable public-state hysteresis shared by state attributes, prompt text,
	-- collision settling and transition audio.
	ClosedEnterAngleDeg = 2.0,
	ClosedExitAngleDeg = 5.5,
	ClosedEnterVelocityDeg = 6.0,
	OpenStateAngleDeg = 62,
	OpenStateExitHysteresisDeg = 6.0,
	MovingStateVelocityDeg = 3.5,

	-- Closing seat/rest audio fires as the moving leaf enters the jamb zone,
	-- rather than waiting for mathematical zero.
	CloseSeatSoundAngleDeg = 5.5,
	CloseSeatSoundRearmAngleDeg = 9.0,
	CloseSeatMinVelocityDeg = 0.35,

	-- Latch / rest behavior.
	LatchCatchAngleDeg = 5.5,
	LatchCatchDamping = 12.0,
	LatchSnapAngleDeg = 0.28,
	LatchSnapVelocityDeg = 1.8,

	-- Safety / anti-crush for normal/player-driven motion. External/API Open/Close/Lock commands bypass obstruction safety by design.
	SafetyEnabled = true,
	SafetyPadding = 0.95,
	SafetyLookAheadDeg = 14,
	SafetySamples = 3,
	SafetyResumeDelay = 0.30,
	SafetyBackoffSpeedDeg = 32,
	BlockedVelocityDamping = 18,

	-- Client presentation.
	-- DoorClient dead-reckons from timestamped angle/velocity/acceleration packets,
	-- then uses a high-frequency tracking spring before PivotTo(). UISpr remains
	-- responsible for handle/latch animation.
	ClientNearDistance = 120,
	ClientFarDistance = 300,
	-- Discovery/relevance refresh can run slowly because moving leaves still render every
	-- frame once relevant and CollectionService wakes newly-added doors immediately.
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
	-- Local pre-opening prediction is off by default. It made doors appear to react
	-- before physical contact. Network dead-reckoning still keeps actual motion smooth.
	PredictionEnabled = true,
	PredictionMaxDeg = 15.0,
	PredictionGain = 0.075,
	PredictionDecay = 22,

	-- Local collision presentation. Each client disables collision on the replicated
	-- authoritative slab locally and collides against a private proxy driven from the
	-- exact same visual hinge angle. The server slab stays authoritative on the server.
	LocalCollisionMirror = true,
	-- Only the LOCAL pusher gets temporary collision yield, and only while their
	-- current movement is driving the door away from their current side. Other players
	-- keep their own solid local proxy, while the server collider remains authoritative.
	LocalPushCollisionYield = true,
	LocalPushCollisionYieldTime = 0.16,
	LocalPushYieldMinPredictionDeg = 2.5,
	LocalPushYieldMinAngularSpeedDeg = 28,
	LocalPushYieldClearance = 0.72,

	-- Handle animation
	HandleEnabled = true,
	-- A closed door pushed by walking into it depresses the handle once as contact opens
	-- the leaf. This is presentation-only and does not alter push physics.
	WalkPushHandleEnabled = true,
	WalkPushHandleClosedAngleDeg = 4.5,
	WalkPushHandleRearmAngleDeg = 9.0,
	WalkPushHandleMinSpeed = 1.25,
	WalkPushHandleMaxDoorSpeedDeg = 24,
	WalkPushHandleCooldown = 0.45,
	WalkPushHandlePlaysSound = false,
	HandleAxis = "Z",
	HandlePressDeg = -26,
	HandleDamping = 0.78,
	HandleFrequency = 13.5,
	HandleReleaseDelay = 0.20,
	HandleDoorDelay = 0.085,
	LockedHandleJiggleDeg = 11,
	LockedHandleJiggleDelay = 0.07,
	-- Locked open attempts are presentation-only by default. The authoritative hinge
	-- remains seated/solid while the client renders a visible torsional rattle.
	LockedAttemptAuthoritativeMotion = false,
	LockedAttemptAngularImpulseDeg = 10, -- legacy physical rattle strength when enabled
	-- Smaller angular span but a faster, lower-damped ring: visibly aggressive without
	-- making the door look like it is actually opening.
	LockedAttemptShakeDeg = 5.5,
	LockedAttemptShakeFrequency = 29.0,
	LockedAttemptShakeDamping = 0.08,

	-- Prompts
	-- Local prompt proxies follow the client-reconstructed pose so the UI follows the
	-- reconstructed smooth door pose instead of the lower-rate server collider.
	LocalPromptProxy = true,
	PromptValidationPadding = 2.25,
	PromptActionText = "Open",
	PromptCloseText = "Close",
	PromptLockedText = "Locked",
	PromptUnlockText = "Unlock & Open",
	PromptObjectText = "Door",
	PromptDistance = 7,
	PromptHoldDuration = 0,
	LockPromptKey = Enum.KeyCode.F,
	LockPromptDistance = 6,
	LockPromptHoldDuration = 0.20,
	KickPromptEnabled = false,
	KickPromptKey = Enum.KeyCode.R,
	KickPromptDistance = 5.5,
	KickPromptHoldDuration = 0.24,
	KickPromptLockedText = "Kick In",
	KickPromptUnlockedText = "Kick",
	KickOnlyWhenLocked = false,

	-- Durability / forced entry. `Health` represents latch/door integrity.
	-- MaxHealth can be set on the assembly or an individual LeafRig. An authored
	-- StartingHealth attribute can begin below MaxHealth without fighting the runtime
	-- Health readout attribute. Assembly Health is a replicated readout AND a writable
	-- server control; HealthPercent is a read-only normalized aggregate readout.
	Breakable = true,
	MaxHealth = 100,
	StartingHealth = -1, -- -1 means start at MaxHealth

	KickDamageMin = 32,
	KickDamageMax = 42,
	-- Locked kick attempts are cosmetic-only by default: the authoritative hinge stays
	-- exactly seated and collidable until the latch health reaches zero.
	LockedKickAuthoritativeMotion = false,
	LockedKickAngularImpulseDeg = 74,
	UnlockedKickAngularImpulseDeg = 260,
	KickMinAngularSpeedDeg = 360,
	KickMaxAngularSpeedDeg = 520,
	KickBoostDuration = 0.60,
	KickFreeDrag = 1.10,
	KickLimitBounce = 0.30,
	BreachOpenAngularSpeedDeg = 330,
	BreachAdditiveAngularImpulseDeg = 85,
	BreachOpenAngleDeg = 106,
	BreachMaxAngularSpeedDeg = 460,
	-- Internal sanity ceiling also protects doors carrying overly aggressive older values.
	BreachAbsoluteMaxAngularSpeedDeg = 520,
	BreachLimitBounce = 0.30,
	BreachFreeDrag = 1.35,
	-- Forced-entry breach NEVER detaches the leaf. The latch fails and the
	-- door remains hinged, receiving a violent opening impulse.
	UnlockOnBreach = true,
	AutoCloseAfterBreach = false,
	BreachHoldOpenTime = 1.55,
	KickImpulse = 48,
	BreakAngularImpulseDeg = 190,
	ResetAfterBreak = true,
	ResetDelay = 9,

	-- Cosmetic recoil spring layered over authoritative hinge motion on clients.
	-- Locked attempts/kicks use their own spring tuning so they can look much stronger
	-- without moving the authoritative hinge or opening a collision gap.
	KickShakeDeg = 10.0,
	KickShakeFrequency = 21.0,
	KickShakeDamping = 0.38,
	LockedKickShakeDeg = 9.0,
	LockedKickShakeFrequency = 27.0,
	LockedKickShakeDamping = 0.08,
	-- Successful breach already has real hinge motion; keep its cosmetic layer subtle.
	BreachShakeDeg = 7.0,

	-- Optional authored impact particles. Put a ParticleEmitter named `KickDust`
	-- under KickRoot or LatchRoot in Leaf. The client clone emits it on each kick.
	KickParticleEmitterName = "KickDust",
	KickParticleCount = 12,
	BreachParticleCount = 28,

	-- State-driven motion audio. The server chooses the exact random variant once and
	-- clients play that same template at the smoothly rendered leaf. A sound category can
	-- be either:
	--   Sounds/Open (Sound)
	-- or
	--   Sounds/Open (Folder) -> any descendant Sound is a random variant.
	-- LeafRig/Sounds overrides Assembly/Sounds for that category.
	SoundEnabled = true,
	-- When true, DoorService fills missing Open/CloseStart/Close/Lock/Unlock/Locked/KickAttempt/Breach categories
	-- with the v7.7 defaults below. Existing authored categories are never overwritten.
	ProvisionDefaultSounds = true,
	DefaultSoundRollOffMinDistance = 4,
	DefaultSoundRollOffMaxDistance = 48,
	SoundRandomNoImmediateRepeat = true,
	SoundPitchScale = 1.0,
	SoundVolumeScale = 1.0,
	SoundDefaultPitchVariance = 0.035,
	SoundDefaultVolumeVariance = 0.0,
	-- Audio events are culled only beyond BOTH this distance and the selected Sound's
	-- RollOffMaxDistance, so this removes pointless remotes without audible quality loss.
	SoundReplicationDistance = 64,
	MotionSoundDebounce = 0.12,
	-- Prevent linked/double-door leaves from producing the same motion cue twice
	-- within one visual event. This is assembly-wide, while kick/lock sounds remain per leaf.
	AssemblyMotionSoundDedupWindow = 0.14,
	MotionSoundVelocityDeg = 4.0,
	-- A new open cycle is armed as soon as the real hinge returns to the closed zone,
	-- even if a player reverses it before the final sleep/completeClose path runs.
	OpenSoundTriggerAngleDeg = 1.5,
	OpenSoundRearmAngleDeg = 0.75,
	CloseStartSoundMinAngleDeg = 3.0,

	-- Close is ONLY the physical jamb/seat sound and is intentionally fired near the
	-- closed rest angle. Reaching the fully-open hinge limit is silent. CloseStart is
	-- optional if you also want a sound when closing begins. KickAttempt is the ordinary
	-- impact/rattle; Breach is the successful latch failure / kick-in event.
	SoundNames = table.freeze({
		Handle = "Handle",
		Latch = "Latch",
		Open = "Open",
		Close = "Close",
		CloseStart = "CloseStart",
		Lock = "Lock",
		Unlock = "Unlock",
		Locked = "Locked",
		KickAttempt = "KickAttempt",
		Kick = "Kick", -- legacy authored-category fallback
		Breach = "Breach",
		Break = "Break",
		Creak = "Creak",
		Rest = "Rest", -- legacy/fallback category
		OpenRest = "OpenRest",
		AutoClose = "AutoClose",
	}),
})
