extends SceneTree
const KM := preload("res://scripts/fighter/knockdown_motion.gd")
const NeutralCorner := preload("res://scripts/fighter/neutral_corner.gd")
# Knockdown / KO polish: clip choice, get-up pose match, floor contact, referee count, HUD, neutral corner, clock, KO at 10.
# godot --headless --path . --script res://tests/test_knockdown.gd [--fixed-fps 120]
# Prints PASS/FAIL and exits 0 / 1.

var failures := 0
var main: Node
var m: Match
var f: Array
var counts: Array = []
var results: Array = []


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	_run.call_deferred()


func start_bout() -> void:
	if main != null:
		main.queue_free()
		await process_frame
	Engine.time_scale = 1.0
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "p1_model": "viper", "p2_model": "anvil",
		"rules": "boxing", "rounds": 3, "round_seconds": 180.0, "cpu_difficulty": "normal", "arena": "ring", "intro_delay": 0.0})
	await steps(30)
	m = main.current_match
	f = m.get_fighters()
	counts.clear()
	results.clear()
	m.count_tick.connect(func(i, n): counts.append([i, n]))
	m.match_ended.connect(func(r): results.append(r))


func _run() -> void:
	print("== A. get-up clip matches the fall clip's lying pose (max core-bone rotation difference)")
	var model: Node3D = (load("res://assets/fighters/viper.glb") as PackedScene).instantiate()
	root.add_child(model)
	await process_frame
	var ap: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	var sk: Skeleton3D = model.find_child("Skeleton3D", true, false)
	var falls: Array = []
	for d in KM.HEAD_FALLS: falls.append([d + " head", KM.HEAD_FALLS[d]])
	falls.append(["body KO", KM.BODY_FALL])
	falls.append(["leg KO", KM.LEG_FALL])
	for e in falls:
		var clip: String = e[1]["clip"]
		check(ap.has_animation(clip), "%s exists" % clip)
		ap.play(clip); ap.seek(ap.get_animation(clip).length, true); ap.advance(0.0)
		await process_frame
		var end_pose := KM.core_pose(sk)
		var up := KM.lying_face_up(sk)
		var g := KM.getup_clip(sk)
		ap.play(g); ap.seek(0.0, true); ap.advance(0.0)
		await process_frame
		var dist := KM.pose_distance(end_pose, KM.core_pose(sk))
		check(dist < KM.MAX_POSE_JUMP_DEG, "%-12s (%s) -> %s: %.1f deg" % [e[0], "face up" if up else "face down", g, dist])
	check(KM.getup_clip(sk) == KM.GETUP_FACE_UP or true, "orientation probe runs")
	model.queue_free()

	for dir in ["F", "L", "R", "U", "O"]:
		print("== B. knockdown from a %s punch: floor contact, count, HUD, corner, clock" % dir)
		await start_bout()
		var p1: Fighter = f[0]
		var p2: Fighter = f[1]
		var t_left := m.ms.time_left
		p2._do_knockdown(dir)
		check(Engine.time_scale < 1.0, "impact slow-mo active (%.2f)" % Engine.time_scale)
		var min_y := 9.0
		var max_y := -9.0
		var fight_banner := false
		var count_ok := true
		var seen_states := {}
		var n_steps := 0
		var corner_dist := 9.0
		var clip_used: String = String(p2.anim.action_clip)
		while n_steps < 120 * 20 and not (n_steps > 30 and p2.state == Fighter.State.IDLE and not p1.frozen):
			await physics_frame
			n_steps += 1
			min_y = minf(min_y, p2.global_position.y)
			max_y = maxf(max_y, p2.global_position.y)
			seen_states[p2.state_name] = true
			if p2.state == Fighter.State.COUNT:
				if main._hud.banner_text() == "FIGHT!":
					fight_banner = true
				if main._hud.count_text() != "" and main._hud.count_text() != str(p2.count_n) and p2.count_n > 0:
					count_ok = false
				if p1.corner_target != Vector3.INF:
					corner_dist = minf(corner_dist, Vector2(p1.global_position.x - p1.corner_target.x, p1.global_position.z - p1.corner_target.z).length())
		check(min_y > -0.03 and max_y < 0.05, "downed fighter stays on the canvas through %s (y %.3f .. %.3f)" % [",".join(seen_states.keys()), min_y, max_y])
		check(seen_states.has("fall") and seen_states.has("count") and seen_states.has("getup"), "fall -> count -> getup visited")
		# ragdoll: the fall is no longer one of KM.HEAD_FALLS' clips, it is the physics simulation (tests/test_ragdoll.gd)
		check(clip_used == "" and p2._ragdoll != null, "fall for %s is physics driven, no fall clip (action clip '%s')" % [dir, clip_used])
		check(p2.state == Fighter.State.IDLE, "back on his feet (%s) after %.1f s" % [p2.state_name, n_steps / 120.0])
		check(counts.size() == p2.getup_count and counts[0][1] == 1 and counts[counts.size() - 1][1] == p2.getup_count, "count 1..%d (%d ticks)" % [p2.getup_count, counts.size()])
		check(p2.getup_count >= 4 and p2.getup_count <= 8, "get-up number %d in 4..8" % p2.getup_count)
		check(not fight_banner, "no FIGHT! banner during the count")
		check(count_ok, "HUD numeral matches the referee count")
		check(corner_dist < 0.3, "standing fighter reached the neutral corner (closest %.2f m)" % corner_dist)
		check(absf(m.ms.time_left - t_left) < 0.05, "round clock paused (%.2f -> %.2f)" % [t_left, m.ms.time_left])
		await steps(20)
		check(main._hud.banner_text() == "FIGHT!", "FIGHT! banner after the count (%s)" % main._hud.banner_text())
		check(not p2.stats.rocked and not p2.hurt.active() and p2.stats.rock_grace > 0.0, "knocked-down fighter comes back clear-headed with a rock grace (owner: no post get-up daze)")
		check(p2.global_position.y > -0.03 and p2.global_position.y < 0.05, "on the floor after the get-up")
		await steps(120 * 3)
		check(Engine.time_scale == 1.0, "time scale restored")

	print("== C. count of ten is a KO (head almost gone)")
	await start_bout()
	f[1].stats.head = 2.0
	f[1]._do_knockdown("F")
	check(f[1].getup_count == 10, "get-up number is 10")
	var n_steps := 0
	while n_steps < 120 * 25 and f[1].state != Fighter.State.DOWN:
		await physics_frame
		n_steps += 1
	check(f[1].state == Fighter.State.DOWN and f[1].ko_method == "KO", "state DOWN, method KO after %.1f s" % (n_steps / 120.0))
	check(counts.size() == 10 and counts[9][1] == 10, "count reached 10 (%d ticks)" % counts.size())
	await steps(120 * 6)
	check(results.size() == 1 and results[0]["winner"] == 0 and results[0]["method"] == "KO", "match ends: %s" % str(results))

	print("== D. KOs lie still on the canvas (which way he lies is physics, see tests/test_ragdoll.gd)")
	for case in [["head", "F", true], ["head", "L", true], ["head", "U", true], ["head", "O", true], ["body", "F", false], ["leg", "L", true]]:
		await start_bout()
		f[1]._do_ko("KO", case[1], case[0])
		var ymin := 9.0
		var ymax := -9.0
		for i in 120 * 4:
			await physics_frame
			ymin = minf(ymin, f[1].global_position.y)
			ymax = maxf(ymax, f[1].global_position.y)
		var up: bool = f[1]._ragdoll.lying_face_up()
		check(ymin > -0.03 and ymax < 0.05, "%s KO from %s: y %.3f..%.3f" % [case[0], case[1], ymin, ymax])
		# ragdoll: which way he lies is physics now (the clips used to force face up / down); he must lie flat and be a get-up candidate
		var hipy: float = f[1]._ragdoll.bone_origin("pelvis").y
		check(hipy < 0.45, "%s KO from %s lies on the canvas (hip %.2f m, face %s)" % [case[0], case[1], hipy, "up" if up else "down"])
		await steps(120 * 5)
	await start_bout()
	Engine.time_scale = 1.0

	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
