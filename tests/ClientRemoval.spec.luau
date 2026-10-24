-- Inject the actual client lifecycle functions; no running character is needed.
return function(api)
	local assembly=Instance.new("Model") assembly.Name="DoorRemovalRegression"
	local folder=Instance.new("Folder") folder.Name="Leaves" folder.Parent=assembly
	local rig=Instance.new("Model") rig.Parent=folder
	local hinge=Instance.new("Part") hinge.Name="Hinge" hinge.Anchored=true hinge.Parent=rig
	local model=Instance.new("Model") model.Name="Leaf" model.Parent=rig
	local root=Instance.new("Part") root.Name="Root" root.Anchored=true root.Parent=model
	model.PrimaryPart=root
	game:GetService("CollectionService"):AddTag(assembly,"DoorSystemDoor")
	assembly.Parent=workspace
	local state=assert(api.ensureLeaf(rig))
	api.pushSentAt[rig]=10
	local clone=state.renderModel
	assembly.Parent=nil -- streaming/removal leaves the nested rig parented to Leaves
	api.refreshRenderLeaves()
	local removed=api.leaves[rig]==nil
	local disconnected=next(state.sourceConnections)==nil and #state.sourceHierarchyConnections==0
	local released=clone.Parent==nil and api.pushSentAt[rig]==nil
	-- Always clean the fixture, even when exercising the old broken implementation.
	api.disconnectSourceTracking(state) api.destroyRenderModel(state,true)
	assembly:Destroy()
	assert(removed,"Removing a whole assembly must evict its nested leaf from the client cache")
	assert(disconnected,"Removing a whole assembly must disconnect its source listeners")
	assert(released,"Removing a whole assembly must destroy its render clone and release push timestamps")
	return "PASS: removed assembly releases nested leaf, clone, listeners and push history"
end
