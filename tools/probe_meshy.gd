extends SceneTree
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var m: Match = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "p1_controller": "dummy", "p2_controller": "dummy", "p1_model": "meshy_viper", "p2_model": "meshy_anvil", "rules": "boxing"})
	get_root().add_child(m)
	var f: Array = m.get_fighters()
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	for i in 120: await physics_frame
	f[0].global_position = Vector3(-0.45, 0, 0)
	f[1].global_position = Vector3(0.45, 0, 0)
	for i in 60: await physics_frame
	var p1: Fighter = f[0]
	var p2: Fighter = f[1]
	p2.stats.head = 0.4
	p2.stats.knockdowns = 3
	p1.external_input.strikes.append("RHook")
	await physics_frame
	p1.external_input.strikes.clear()
	var n := 0
	while p2.state != Fighter.State.DOWN and n < 600:
		await physics_frame
		n += 1
	var ms = p2.meshy_skin
	var w1 := 0.0
	var w2 := 0.0
	var w3 := 0.0
	for i in 480:
		await physics_frame
		if p2._ragdoll.active:
			var drv: Vector3 = ms.driver_world("head").origin
			w1 = maxf(w1, drv.distance_to(p2._ragdoll.bone_origin("head")))
			w2 = maxf(w2, ms.joint_world("Head").distance_to(drv))
			w3 = maxf(w3, ms.joint_world("Head").distance_to(p2._ragdoll.bone_origin("head")))
			if ms.joint_world("Head").distance_to(drv) > 0.08:
				print(i, " drv ", drv.snapped(Vector3.ONE*0.01), " phys ", p2._ragdoll.bone_origin("head").snapped(Vector3.ONE*0.01), " meshy ", ms.joint_world("Head").snapped(Vector3.ONE*0.01))
	print("max drv-phys ", w1, " meshy-drv ", w2, " meshy-phys ", w3)
	quit()
