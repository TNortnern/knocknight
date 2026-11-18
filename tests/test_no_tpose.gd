extends SceneTree
# No T-pose after a ragdoll fall. Deactivating the AnimationTree for a KO / knockdown resets its state machines; Base then sat in
# "Start" for good, so after the get-up (or a reset_for_round) the fighter stood with straight rest-pose legs and nothing playing.
# Checks the final pose (logic skeleton + Meshy skeleton) via tools/tpose_probe.gd on the paths that reproduced it, plus the KO paths.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_no_tpose.gd
const Probe := preload("res://tools/tpose_probe.gd")
const MODELS := ["meshy_anvil", "viper"]
const MIN_FRAMES := 12

var failures := 0
var m: Match
var probes: Array = []


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame
		for p in probes:
			p.step()


func make(model: String) -> Array:
	if m != null:
		root.remove_child(m)
		m.queue_free()
		await process_frame
	probes.clear()
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 3, "round_seconds": 600.0, "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": model, "rules": "boxing", "end_delay": 1.0, "intermission": 1.0})
	root.add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	for x: Fighter in f:
		x.external_input = FighterInput.new()
		x.stats.infinite_stamina = true
		probes.append(Probe.make(x))
	await steps(90)
	f[0].global_position = Vector3(-0.30, 0, 0)   # 0.6 m: scripted (unaimed) punches touch the fitted head volume from ~0.6 m
	f[1].global_position = Vector3(0.30, 0, 0)
	await steps(30)
	for p in probes:
		p.worst_run = 0
		p.run_frames = 0
	return f


func wait_state(x: Fighter, st: Array, max_f: int) -> void:
	var n := 0
	while not (x.state in st) and n < max_f:
		await steps(1)
		n += 1


func verdict(label: String, model: String, victim_only := true) -> void:
	for p in probes:
		if victim_only and p.fighter.player_index != 1:
			continue
		check(p.worst_run < MIN_FRAMES, "%s / %s: never rest-posed for %d frames (worst %d: %s)" % [label, model, MIN_FRAMES, p.worst_run, p.worst_info])


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for model: String in MODELS:
		print("== ", model)
		var f: Array = await make(model)
		# knockdown -> count -> get-up -> standing again: Base must be back on the locomotion blend space
		f[1].getup_count = 4
		f[1]._do_knockdown("F")
		await wait_state(f[1], [Fighter.State.GETUP], 3000)
		await wait_state(f[1], [Fighter.State.IDLE], 3000)
		await steps(360)
		var pb = f[1].anim.tree.get("parameters/Base/playback")
		check(String(pb.get_current_node()) == "Move", "after the get-up the Base state machine is on Move (%s)" % String(pb.get_current_node()))
		await verdict("knockdown + get-up", model)

		# the same for a standing fighter who is reset while down (new round / restart): fall, count, get-up blend, KO
		for phase in ["fall", "count", "ko"]:
			f = await make(model)
			f[1]._do_knockdown("F")
			match phase:
				"fall":
					await steps(30)
				"count":
					await wait_state(f[1], [Fighter.State.COUNT], 900)
				"ko":
					f[1]._do_ko("KO", "F", "head")
					await steps(200)
			for x: Fighter in f:
				x.reset_for_round(Vector3(-0.8 if x.player_index == 0 else 0.8, 0, 0), true)
			await steps(300)
			pb = f[1].anim.tree.get("parameters/Base/playback")
			check(String(pb.get_current_node()) == "Move", "reset from %s: Base is on Move" % phase)
			await verdict("reset while down (%s)" % phase, model)

		# KO paths: real punch KO, TKO, KO while already down (fall / count / get-up), body KO
		f = await make(model)
		f[1].stats.head = 0.4
		f[1].stats.knockdowns = 3
		f[0].external_input.strikes.append("RHook")
		await physics_frame
		f[0].external_input.strikes.clear()
		await wait_state(f[1], [Fighter.State.DOWN], 900)
		await steps(500)
		check(f[1].state == Fighter.State.DOWN, "punch KO ends DOWN")
		await verdict("punch KO", model)
		f = await make(model)
		f[1]._do_ko("TKO", "F", "head")
		await steps(500)
		await verdict("TKO", model)
		for phase in ["fall", "count", "getup"]:
			f = await make(model)
			f[1].getup_count = 4
			f[1]._do_knockdown("F")
			match phase:
				"fall":
					await steps(40)
				"count":
					await wait_state(f[1], [Fighter.State.COUNT], 900)
				"getup":
					await wait_state(f[1], [Fighter.State.GETUP], 3000)
					await steps(30)
			f[1]._do_ko("KO", "F", "head")
			await steps(500)
			check(f[1].state == Fighter.State.DOWN, "KO during %s ends DOWN" % phase)
			await verdict("KO during " + phase, model)
		f = await make(model)
		f[1].stats.body_max = 0.0
		f[0].external_input.strikes.append("RBodyHook")
		await physics_frame
		f[0].external_input.strikes.clear()
		await wait_state(f[1], [Fighter.State.DOWN], 900)
		await steps(400)
		await verdict("body KO", model)

	if m != null:
		m.queue_free()
	if failures == 0:
		print("PASS: no T-pose after ragdoll falls")
		quit(0)
	else:
		print("FAIL: %d check(s) failed" % failures)
		quit(1)
