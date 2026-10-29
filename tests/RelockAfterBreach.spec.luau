-- Studio Edit: bind the real server lock functions and client prompt updater.
return function(serverSource, clientSource)
	local serverFirst = assert(serverSource:find("function DoorService.SetLocked(", 1, true))
	local serverLast = assert(serverSource:find("function DoorService.SetState(", serverFirst, true))
	local toggleFirst = assert(serverSource:find("function DoorService.ToggleLock(", serverLast, true))
	local toggleLast = assert(serverSource:find("local function launchClosedAssemblyCompanions", toggleFirst, true))
	local clientFirst = assert(clientSource:find("local function updateLocalPromptState(", 1, true))
	local clientLast = assert(clientSource:find("local function discoverAssembly(", clientFirst, true))
	local function subject()
		local model = Instance.new("Model")
		model:SetAttribute("Breached", true)
		model:SetAttribute("LockBroken", true)
		model:SetAttribute("LockPromptEnabled", true)
		model:SetAttribute("AllowPlayerLocking", true)
		local rig = Instance.new("Model", model)
		rig:SetAttribute("Breached", true)
		rig:SetAttribute("LockBroken", true)
		rig:SetAttribute("Health", 0)
		rig:SetAttribute("HealthPercent", 0)
		local prompt = Instance.new("ProximityPrompt", rig)
		local leaf = {rig = rig, assembly = model, breached = true, broken = false, health = 0,
			angle = 0, velocity = 0, mode = "Idle", drivers = {}, contacts = {}, lockPrompt = prompt,
			collision = Instance.new("Part", rig)}
		local state = {model = model, leaves = {leaf}, locked = false, pendingLock = false}
		local api = {state = state, leaf = leaf, closed = true, allowed = true, closes = 0, player = {}}
		local function attr(object, key, fallback)
			local value = object:GetAttribute(key)
			return if value == nil then fallback else value
		end
		local env = setmetatable({
			DoorService = {}, assemblies = {[model] = state}, leafByRig = {[rig] = leaf}, pendingLockAssemblies = {},
			Config = {ExternalLockRepairsBrokenLock = true, RelockAfterBreach = true, MaxHealth = 100,
				PromptStackSpacing = 58, SoundNames = {Lock = "Lock", Unlock = "Unlock"}},
			attr = attr, setting = function(r, a, key, fallback) return attr(r, key, attr(a, key, fallback)) end,
			allLeavesClosed = function() return api.closed end, assemblyActuallyOpen = function() return not api.closed end,
			refreshAssemblyPublicState = function() end, updatePromptText = function() end,
			writeAssemblyAttribute = function(s, key, value) s.model:SetAttribute(key, value) end,
			beginLeafCommand = function() end, playSound = function() end, broadcastAction = function() end,
			requestExternalCloseLeaf = function() api.closes += 1 end,
			canPlayerAccess = function() return api.allowed end,
			findAssembly = function() return model end, disableServerPromptsLocally = function() end,
			promptBaseOffsets = {},
		}, {__index = getfenv()})
		local chunk = assert(loadstring(serverSource:sub(serverFirst, serverLast - 1) .. "\n"
			.. serverSource:sub(toggleFirst, toggleLast - 1) .. "\n"
			.. clientSource:sub(clientFirst, clientLast - 1) .. "\nreturn updateLocalPromptState"))
		setfenv(chunk, env)
		api.refresh = chunk()
		api.toggle = function() return env.DoorService.ToggleLock(model, api.player, rig) end
		api.set = function(value, external) return env.DoorService.SetLocked(model, value, if external then nil else api.player) end
		return api
	end
	local fixtures = {}
	local function fresh() local api = subject(); table.insert(fixtures, api); return api end
	local ok, result = pcall(function()
		local a = fresh()
		a.refresh(a.leaf)
		assert(a.leaf.lockPrompt.Enabled, "Breaching permanently hid the lock prompt")
		assert(a.toggle() and a.state.locked, "Authorized player could not relock a breached door")
		assert(not a.state.model:GetAttribute("Breached") and not a.state.model:GetAttribute("LockBroken"))
		assert(not a.leaf.breached and a.leaf.health == 100 and a.leaf.rig:GetAttribute("HealthPercent") == 1,
			"Relocking did not rearm lock integrity for the next breach")
		assert(a.toggle() and not a.state.locked, "Repaired lock could not unlock normally")
		local ajar = fresh(); ajar.closed = false
		ajar.toggle()
		assert(ajar.state.pendingLock and ajar.closes == 1 and not ajar.state.locked, "Ajar door skipped close-and-latch")
		ajar.closed = true; ajar.set(true)
		assert(ajar.state.locked and not ajar.state.pendingLock)
		local denied = fresh(); denied.allowed = false
		assert(not denied.toggle() and denied.leaf.breached and denied.leaf.health == 0, "Relock bypassed access checks")
		local disabled = fresh(); disabled.state.model:SetAttribute("RelockAfterBreach", false)
		disabled.refresh(disabled.leaf); disabled.set(true)
		assert(not disabled.leaf.lockPrompt.Enabled and not disabled.state.locked and disabled.leaf.breached)
		local broken = fresh(); broken.leaf.broken = true
		broken.refresh(broken.leaf); broken.set(true)
		assert(not broken.leaf.lockPrompt.Enabled and not broken.state.locked and broken.leaf.health == 0,
			"Relocking repaired a physically broken door")
		local external = fresh(); external.state.model:SetAttribute("RelockAfterBreach", false)
		external.set(true, true)
		assert(external.state.locked, "Player relock option disabled existing external repair")
		return "RelockAfterBreach: PASS (visible prompt, permission, rearmed integrity, close/latch, opt-out, broken leaf and external control)"
	end)
	for _, api in fixtures do api.state.model:Destroy() end
	assert(ok, result)
	return result
end
