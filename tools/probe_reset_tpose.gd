extends SceneTree
const Probe := preload("res://tools/tpose_probe.gd")
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var m: Match = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 3, "round_seconds": 600.0, "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": "anvil", "rules": "boxing"})
	root.add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	for x in f: x.external_input = FighterInput.new()
	var pr = Probe.make(f[1])
	for i in 100: await physics_frame
	f[1]._do_ko("KO", "F", "head")
	for i in 200: await physics_frame
	for x in f: x.reset_for_round(Vector3(-0.8 if x.player_index == 0 else 0.8, 0, 0), true)
	var a: Fighter = f[1]
	for k in 12:
		for i in 20: await physics_frame
		var pb = a.anim.tree.get("parameters/Base/playback")
		print("t+%d state=%s tree=%s base=%s playing=%s drv=%.1f mix=%.2f act=%.2f guard=%.2f mods=%s" % [k*20, a.state_name, a.anim.tree.active, pb.get_current_node(), pb.is_playing(), pr.driver_deg, a.anim._mix, a.anim._act, a.anim._guard, str(a.rig.skeleton.get_children().filter(func(c): return c is SkeletonModifier3D).map(func(c): return "%s:%s" % [c.name, c.active]))])
	quit(0)
