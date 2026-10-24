-- Run with a factory binding the actual DoorService prompt/interaction functions
-- to isolated fixtures; no server startup or live door models are required.
return function(makeSubject)
	local checks = 0
	local function check(condition, message)
		assert(condition, message)
		checks += 1
	end
	-- Either handle operates a pair with the same intent, including mirrored angles.
	for _, sourceIndex in {1, 2} do
		for _, open in {false, true} do
			local s = makeSubject()
			local a, b = s.state.leaves[1], s.state.leaves[2]
			a.angle, b.angle = if open then math.rad(80) else 0, if open then math.rad(-80) else 0
			s.toggle(s.state, s.state.leaves[sourceIndex], s.player)
			s.flush()
			check(a.mode == (if open then "PromptClosing" else "PromptOpening"), "Source must toggle")
			check(b.mode == a.mode, "Equal-intent double doors must toggle both leaves")
			check(s.handles == 1, "Only the operated handle should animate")
		end
	end
	-- An individually opened leaf leaves the pair mixed; operate only the chosen leaf.
	for _, sourceIndex in {1, 2} do
		local s = makeSubject()
		local a, b = s.state.leaves[1], s.state.leaves[2]
		a.angle = math.rad(70)
		s.toggle(s.state, s.state.leaves[sourceIndex], s.player)
		s.flush()
		check(a.mode == (if sourceIndex == 1 then "PromptClosing" else "Idle"), "Mixed open leaf must remain independent")
		check(b.mode == (if sourceIndex == 2 then "PromptOpening" else "Idle"), "Mixed closed leaf must remain independent")
	end
	-- Pair intent must survive different physical angles and reverse during handle delay.
	for _, opening in {true, false} do
		local s = makeSubject()
		local a, b = s.state.leaves[1], s.state.leaves[2]
		a.angle, b.angle = math.rad(65), math.rad(-3)
		a.targetAngle, b.targetAngle = if opening then math.rad(90) else 0, if opening then math.rad(-90) else 0
		a.mode, b.mode = if opening then "PromptOpening" else "PromptClosing", if opening then "PromptOpening" else "PromptClosing"
		s.toggle(s.state, a, s.player)
		s.toggle(s.state, b, s.player)
		s.flush()
		check(a.mode == (if opening then "PromptOpening" else "PromptClosing"), "Repeated prompt must reverse pending intent")
		check(b.mode == a.mode, "Reversal must preserve the pair")
	end
	do
		local s = makeSubject()
		local a, b = s.state.leaves[1], s.state.leaves[2]
		s.toggle(s.state, a, s.player)
		s.toggle(s.state, b, s.player)
		s.flush()
		check(a.mode == "PromptClosing" and b.mode == "PromptClosing", "Opening handle delay must already count as open intent")
	end
	-- Explicit remote Open/Close uses the same pairing rule, while All keeps its contract.
	for _, action in {"Open", "Close"} do
		local s = makeSubject()
		local a, b = s.state.leaves[1], s.state.leaves[2]
		if action == "Close" then a.angle, b.angle = math.rad(80), math.rad(-80) end
		s.interact(s.player, b.rig, action)
		s.flush()
		check(a.mode == (if action == "Open" then "PromptOpening" else "PromptClosing") and a.mode == b.mode, "Validated explicit action must command both")
	end
	do
		local s = makeSubject()
		local a, b = s.state.leaves[1], s.state.leaves[2]
		s.state.model.PromptOpenMode = "All"
		a.angle = math.rad(80)
		s.toggle(s.state, b, s.player)
		s.flush()
		check(a.mode == "PromptClosing" and b.mode == "PromptClosing", "Explicit All must close mixed leaves together")
	end
	do
		local s = makeSubject()
		s.state.leaves[2] = nil
		s.toggle(s.state, s.state.leaves[1], s.player)
		s.flush()
		check(s.state.leaves[1].mode == "PromptOpening", "Single doors must still operate")
	end
	do
		local s = makeSubject()
		s.state.leaves[3] = table.clone(s.state.leaves[2])
		s.toggle(s.state, s.state.leaves[1], s.player)
		s.flush()
		check(s.state.leaves[1].mode == "PromptOpening" and s.state.leaves[2].mode == "Idle" and s.state.leaves[3].mode == "Idle", "Automatic pairing must be limited to double doors")
	end
	-- Auto-pairing must check access at the operated leaf, never unlock via its sibling.
	for _, sourceIndex in {1, 2} do
		local s = makeSubject()
		local source = s.state.leaves[sourceIndex]
		s.state.locked = true
		source.rig.allowed = false
		s.toggle(s.state, source, s.player)
		s.flush()
		check(s.state.locked, "Denied source access must not unlock through an allowed sibling")
		check(s.state.leaves[1].mode ~= "PromptOpening" and s.state.leaves[2].mode ~= "PromptOpening", "Denied locked pair must stay closed")
	end
	do
		local s = makeSubject()
		s.state.locked = true
		s.toggle(s.state, s.state.leaves[2], s.player)
		s.flush()
		check(not s.state.locked, "Authorized operated leaf may unlock")
		check(s.state.leaves[1].mode == "PromptOpening" and s.state.leaves[2].mode == "PromptOpening", "Authorized unlock must open both")
	end
	-- The original remote guards remain authoritative before any pair is dispatched.
	for _, blocked in {"range", "disabled", "external", "lockpick", "broken", "removed", "invalid", "rate"} do
		local s = makeSubject()
		local source = s.state.leaves[1]
		if blocked == "range" then s.inRange = false
		elseif blocked == "disabled" then source.rig.PromptEnabled = false
		elseif blocked == "external" then s.external = true
		elseif blocked == "lockpick" then s.player.LockpickInteracting = true
		elseif blocked == "broken" then source.broken = true
		elseif blocked == "removed" then source.rig.Parent = nil
		elseif blocked == "invalid" then source.rig.valid = false
		else s.rate[s.player] = os.clock() end
		s.interact(s.player, source.rig, "Toggle")
		s.flush()
		check(source.mode == "Idle" and s.state.leaves[2].mode == "Idle", "Rejected " .. blocked .. " request must not command either leaf")
	end
	return tostring(checks) .. " double-door prompt checks passed"
end
