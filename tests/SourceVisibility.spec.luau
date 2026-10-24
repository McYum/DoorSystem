-- Disposable Edit-mode regression; inject the actual DoorClient functions, not a running client.
return function(api)
	local fixture=Instance.new("Folder") fixture.Parent=game.ServerStorage
	local rig=Instance.new("Model") rig.Parent=fixture
	local hinge=Instance.new("Part") hinge.Name="Hinge" hinge.Anchored=true hinge.Parent=rig
	local model=Instance.new("Model") model.Name="Leaf" model.Parent=rig
	local root=Instance.new("Part") root.Name="Root" root.Anchored=true root.CFrame=CFrame.new(2,0,0) root.Parent=model model.PrimaryPart=root
	local glass=Instance.new("Part") glass.Name="Glass" glass.Transparency=.5 glass.LocalTransparencyModifier=.2 glass.CFrame=root.CFrame glass.Parent=model
	local decal=Instance.new("Decal") decal.Transparency=.25 decal.Parent=glass
	local weld=Instance.new("WeldConstraint") weld.Part0=root weld.Part1=glass weld.Parent=root
	local state
	local refreshes=0
	local refreshConnection=api.renderFolder.ChildAdded:Connect(function() refreshes+=1 end)
	local ok,result=xpcall(function()
		state=assert(api.ensureLeaf(rig))
		task.wait()
		local initialRefreshes=refreshes
		assert(glass.LocalTransparencyModifier==1 and decal.Transparency==1,"Source glass/decal must be hidden")
		local late=Instance.new("Part") late.Name="LateGlass" late.Transparency=.5 late.CFrame=CFrame.new(2,1,0) late.Parent=model
		local lateDecal=Instance.new("Decal") lateDecal.Transparency=.4 lateDecal.Parent=late
		state.visualAngle=math.pi/2
		task.wait()
		assert(refreshes==initialRefreshes+1,"A replication batch must produce one coalesced visual refresh")
		assert(late.LocalTransparencyModifier==1 and lateDecal.Transparency==1,"Late replicated glass/decal must not remain visible at the closed pose")
		local visual=assert(state.renderModel:FindFirstChild("LateGlass"),"Render clone must receive late geometry")
		assert(visual.Anchored,"Glass arriving before its weld must not fall away from the door")
		assert(visual.LocalTransparencyModifier<1 and math.abs(visual:FindFirstChildOfClass("Decal").Transparency-.4)<.001,"Clone must preserve authored transparency")
		assert((visual.Position-(hinge.CFrame*CFrame.Angles(0,state.visualAngle,0)):PointToWorldSpace(Vector3.new(2,1,0))).Magnitude<.001,"Refresh must preserve current door angle")
		local lateWeld=Instance.new("WeldConstraint") lateWeld.Parent=root
		task.wait()
		assert(state.renderModel.LateGlass.Anchored,"Incomplete weld references must not release the visual")
		lateWeld.Part0=root lateWeld.Part1=late
		task.wait()
		assert(not state.renderModel.LateGlass.Anchored,"Completed weld must join the normal moving assembly")
		assert(refreshes==initialRefreshes+3,"Each staged batch must produce only one visual refresh")
		local movingVisual=state.renderModel
		for i=1,20 do state.renderModel:PivotTo(CFrame.Angles(0,i*.01,0)*state.renderModel:GetPivot()) end
		task.wait()
		assert(state.renderModel==movingVisual and refreshes==initialRefreshes+3,"Normal motion must not rebuild or rescan source geometry")
		glass.LocalTransparencyModifier=0 decal.Transparency=.6
		task.wait()
		assert(glass.LocalTransparencyModifier==1 and decal.Transparency==1,"External property changes must not reveal stationary source")
		state.renderModel:Destroy()
		local rebuilt=assert(api.ensureRenderModel(state))
		assert(rebuilt.Glass.LocalTransparencyModifier<1 and math.abs(rebuilt.Glass:FindFirstChildOfClass("Decal").Transparency-.6)<.001,"Rebuilding must not copy hidden overrides into the visible clone")
		late.Parent=fixture
		task.wait()
		assert(late.LocalTransparencyModifier==0 and math.abs(lateDecal.Transparency-.4)<.001,"Detached content must regain original visibility")
		assert(not state.renderModel:FindFirstChild("LateGlass"),"Removed content must leave the render clone")
		for _, joint in state.renderModel:GetDescendants() do
			if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
				assert(joint.Part0:IsDescendantOf(state.renderModel) and joint.Part1:IsDescendantOf(state.renderModel),"Render weld must not reference detached server geometry")
			end
		end
		api.destroyRenderModel(state,true)
		assert(glass.LocalTransparencyModifier==0 and math.abs(decal.Transparency-.6)<.001,"Broken/restored source must regain authored visibility")
		decal.Transparency=.35
		api.ensureRenderModel(state)
		api.destroyRenderModel(state,true)
		assert(math.abs(decal.Transparency-.35)<.001,"Reset must preserve edits made while the source was visible")
		return "PASS: late glass/decals/welds, current pose, property resets, clone rebuild and cleanup"
	end,debug.traceback)
	if state and api.disconnectSourceTracking then api.disconnectSourceTracking(state) end
	if state then api.destroyRenderModel(state,true) end
	fixture:Destroy()
	refreshConnection:Disconnect()
	assert(ok,result)
	return result
end
