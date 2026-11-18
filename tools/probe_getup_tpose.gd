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
	f[1].getup_count = 4
	f[1]._do_knockdown("F")
	var a: Fighter = f[1]
	for k in 90:
		for i in 20: await physics_frame
		var pb = a.anim.tree.get("parameters/Base/playback")
		if k % 3 == 0 or a.state_name == "getup":
			print("t+%d state=%s tree=%s base=%s drv=%.1f legs=%.1f act=%.2f" % [k*20, a.state_name, a.anim.tree.active, pb.get_current_node(), pr.driver_deg, pr.legs_deg, a.anim._act])
	quit(0)
