-- Run in Studio with the actual findHandleMotor function from DoorClient.
return function(findHandleMotor)
	local checks = 0
	local function near(actual, expected, message)
		local delta = expected:ToObjectSpace(actual)
		local _, angle = delta:ToAxisAngle()
		assert(delta.Position.Magnitude < 0.0001 and math.abs(angle) < 0.0001, message)
		checks += 1
	end
	local function makeLeaf(pose)
		local leaf = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "Root"
		root.Anchored = true
		root.CFrame = pose
		root.Parent = leaf
		local handle = Instance.new("Part")
		handle.CFrame = pose * CFrame.new(1, -0.7, -0.24)
		handle.PivotOffset = CFrame.new(-0.25, 0, 0) * CFrame.Angles(0.2, 0.3, 0.4)
		handle.Parent = leaf
		local motor = Instance.new("Motor6D")
		motor.Name = "HandleFrontMotor"
		motor.Part0 = root
		motor.Part1 = handle
		motor.C0 = root.CFrame:ToObjectSpace(handle.CFrame)
		motor.Parent = root
		local reference = Instance.new("ObjectValue")
		reference.Name = "PivotTarget"
		reference.Value = handle
		reference.Parent = motor
		return leaf, motor, handle, reference
	end
	local function verifyPivot(leaf, motor, handle)
		local rest = handle.CFrame
		assert(findHandleMotor(leaf, "HandleFrontMotor") == motor)
		near(motor.Part0.CFrame * motor.C0, handle:GetPivot(), "Joint must use the authored pivot")
		near(motor.Part0.CFrame * motor.C0 * motor.C1:Inverse(), rest, "Rebasing must preserve the resting pose")
		for _, angle in {-26, -15, 0, 11} do
			local rotated = motor.Part0.CFrame * motor.C0 * CFrame.Angles(0, 0, math.rad(angle)) * motor.C1:Inverse()
			assert((rotated * handle.PivotOffset).Position:FuzzyEq(handle:GetPivot().Position, 0.0001), "Handle pivot must stay fixed throughout rotation")
			checks += 1
		end
	end
	-- Each leaf of a double door owns its own target, including mirrored poses.
	for _, yaw in {0, math.pi} do
		local leaf, motor, handle = makeLeaf(CFrame.new(4, 3, -8) * CFrame.Angles(0, yaw, 0))
		local clone = leaf:Clone()
		local clonedMotor = clone.Root.HandleFrontMotor
		assert(clonedMotor.PivotTarget.Value:IsDescendantOf(clone), "Clone must remap the pivot reference")
		verifyPivot(clone, clonedMotor, clonedMotor.Part1)
		near(motor.C1, CFrame.identity, "Configuring render clone must not change source motor")
		verifyPivot(leaf, motor, handle)
		clone:Destroy()
		leaf:Destroy()
	end
	-- Model pivots are supported as well as individual handle parts.
	do
		local leaf, motor, handle, reference = makeLeaf(CFrame.new(2, 3, 4))
		local model = Instance.new("Model")
		model.Parent = leaf
		handle.Parent = model
		model.PrimaryPart = handle
		reference.Value = model
		verifyPivot(leaf, motor, handle)
		leaf:Destroy()
	end
	-- Parenting the fixture exercises Roblox's immediate joint updates. This
	-- catches reading Part1.CFrame after assigning C0, unlike detached fixtures.
	do
		local leaf, motor, handle = makeLeaf(CFrame.new(1000, 1000, 1000))
		leaf.Name = "_HandlePivotTest"
		leaf.Parent = workspace
		task.wait()
		local ok, err = pcall(verifyPivot, leaf, motor, handle)
		leaf:Destroy()
		assert(ok, err)
	end
	-- Missing, invalid and cross-leaf targets must retain authored motor offsets.
	for _, kind in {"missing", "empty", "invalid", "external"} do
		local leaf, motor, _, reference = makeLeaf(CFrame.identity)
		local other = Instance.new("Part")
		if kind == "missing" then reference:Destroy()
		elseif kind == "empty" then reference.Value = nil
		elseif kind == "invalid" then reference.Value = motor
		else reference.Value = other end
		local c0, c1 = motor.C0, motor.C1
		findHandleMotor(leaf, "HandleFrontMotor")
		near(motor.C0, c0, "Fallback must preserve C0")
		near(motor.C1, c1, "Fallback must preserve C1")
		other:Destroy()
		leaf:Destroy()
	end
	return tostring(checks) .. " handle pivot checks passed"
end
