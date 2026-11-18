extends SceneTree
# Body spacing: standing fighters keep a minimum chest-to-chest distance (and stay inside the rope line) in open ring,
# on the ropes, in corners, during lunges and pressure. Sampled every physics frame from the final skeleton pose.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_body_spacing.gd
# Prints PASS/FAIL and exits 0 / 1.

const ROPE_HALF := 3.45
const MIN_CHEST := 0.28        ## chest-bone to chest-bone, horizontal. Bodies are now stopped by their own volumes (HitAreas.contact_gap), not by a 0.72 m capsule: gloves / forearms rest on the foe's chest, torsos touch (was 0.50)
const CONTACT_TOL := 0.03      ## a landed punch may briefly squeeze this much closer
const ROPE_CLEAR := 0.16       ## chest bone stays this far inside the rope line (the back of the torso is ~0.13 behind the bone)
const MIN_CENTRES := 0.20      ## root-to-root (capsules: 2 x 0.12 = 0.24, minus solver slack; was 0.69 with the 0.36 capsule)
const MIN_TORSO := 0.25        ## abdomen / chest bones of the two fighters (the bodies touch skin to skin now; was 0.46)
const MIN_GUARD_HEAD := 0.04   ## a non-punching fighter's hands / forearms to the foe's head bone (head hull ~0.10 + glove: the volumes stop touching at ~0.13; was 0.10)

var failures := 0
var m: Match
var main: Node
var _chest := {}   ## fighter instance id -> chest world position (final pose of the last skeleton update)
var _rep := {}


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


## Starts a match through main.tscn so the real ring (arena.tscn: rope-line walls) is loaded, not the placeholder box.
func make_match(cfg: Dictionary) -> Array:
	if main != null:
		get_root().remove_child(main)
		main.queue_free()
		await process_frame
	Engine.time_scale = 1.0
	_chest.clear()
	_bones.clear()
	var full := {"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "rules": "boxing",
		"p1_model": "viper", "p2_model": "anvil", "arena": "ring"}
	full.merge(cfg, true)
	main = load("res://scenes/main.tscn").instantiate()
	get_root().add_child(main)
	await process_frame
	main.start_match(full)
	await process_frame
	m = main.current_match
	var f: Array = m.get_fighters()
	for fi in f:
		watch(fi)
	return f


const BODY_BONES := ["abdomenUpper", "chestLower", "chestUpper", "head", "lShldrBend", "rShldrBend", "lHand", "rHand", "lForearmBend", "rForearmBend"]
const HANDS := ["lHand", "rHand", "lForearmBend", "rForearmBend"]
const TORSO := ["abdomenUpper", "chestLower", "chestUpper"]
var _bones := {}   ## fighter instance id -> {bone: world position}


func watch(f: Fighter) -> void:
	var sk: Skeleton3D = f.rig.skeleton
	var id := f.get_instance_id()
	sk.skeleton_updated.connect(func():
		if not is_instance_valid(sk) or not sk.is_inside_tree():
			return
		var d := {}
		for b in BODY_BONES:
			d[b] = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b)).origin
		_bones[id] = d
		_chest[id] = d["chestUpper"])


func new_report() -> Dictionary:
	return {"frames": 0, "min_chest": 9.0, "min_pos": "", "below": 0, "rope_max": 0.0, "rope_bad": 0, "contact_frames": 0, "min_centre": 9.0, "min_torso": 9.0, "min_head": 9.0, "min_hc": 9.0, "min_any": 9.0, "min_guard_torso": 9.0, "min_guard_head": 9.0}


## One sample of both fighters. Only counts when both are upright and in the fight.
func sample(f: Array, rep: Dictionary, t: float) -> void:
	var a: Fighter = f[0]
	var b: Fighter = f[1]
	for fi in f:
		var x: Fighter = fi
		if x.is_acute_down() or x.is_out() or x.state == Fighter.State.DOWN or x._ragdoll.active:
			return
	if not (_chest.has(a.get_instance_id()) and _chest.has(b.get_instance_id())):
		return
	var ca: Vector3 = _chest[a.get_instance_id()]
	var cb: Vector3 = _chest[b.get_instance_id()]
	var d := Vector2(ca.x - cb.x, ca.z - cb.z).length()
	rep["frames"] += 1
	var ba: Dictionary = _bones[a.get_instance_id()]
	var bb: Dictionary = _bones[b.get_instance_id()]
	# hands / forearms of the fighter who is NOT punching (a guard must not sit inside the foe's torso or head)
	for pair in [[a, b, ba, bb], [b, a, bb, ba]]:
		var me: Fighter = pair[0]
		if me.state == Fighter.State.ATTACK or pair[1].state == Fighter.State.ATTACK and false:
			continue
		for h in HANDS:
			for y in ["abdomenUpper", "chestLower", "chestUpper"]:
				rep["min_guard_torso"] = minf(rep["min_guard_torso"], pair[2][h].distance_to(pair[3][y]))
			rep["min_guard_head"] = minf(rep["min_guard_head"], pair[2][h].distance_to(pair[3]["head"]))
	for x in BODY_BONES:
		if x in HANDS:
			continue
		for y in BODY_BONES:
			if y in HANDS:
				continue
			var dd: float = ba[x].distance_to(bb[y])
			rep["min_any"] = minf(rep["min_any"], dd)
			if x in TORSO and y in TORSO:
				rep["min_torso"] = minf(rep["min_torso"], dd)
			elif x == "head" and y == "head":
				rep["min_head"] = minf(rep["min_head"], dd)
			elif (x == "head" and y in TORSO) or (y == "head" and x in TORSO):
				rep["min_hc"] = minf(rep["min_hc"], dd)
	rep["min_centre"] = minf(rep["min_centre"], a.gap_to_foe())
	if d < rep["min_chest"]:
		rep["min_chest"] = d
		rep["min_pos"] = "t=%.2f %s/%s centres %.2f states %s/%s" % [t, a.state_name, b.state_name, a.gap_to_foe(), a.state_name, b.state_name]
	if d < MIN_CHEST - CONTACT_TOL:
		rep["below"] += 1
	elif d < MIN_CHEST:
		rep["contact_frames"] += 1
	for c in [ca, cb]:
		var e := maxf(absf(c.x), absf(c.z))
		rep["rope_max"] = maxf(rep["rope_max"], e)
		if e > ROPE_HALF - ROPE_CLEAR:
			rep["rope_bad"] += 1


func report_line(tag: String, r: Dictionary) -> void:
	print("    3D mins: torso-torso %.3f  head-head %.3f  head-torso %.3f  any %.3f  guard-hand to foe torso %.3f / head %.3f" % [r["min_torso"], r["min_head"], r["min_hc"], r["min_any"], r["min_guard_torso"], r["min_guard_head"]])
	print("  %s: frames %d  min chest %.3f (%s)  min centres %.3f  frames<%.2f: %d  chest rope-line max %.3f  beyond rope: %d" % [
		tag, r["frames"], r["min_chest"], r["min_pos"], r["min_centre"], MIN_CHEST - CONTACT_TOL, r["below"], r["rope_max"], r["rope_bad"]])


func cpu_fight(seed_n: int, secs: float) -> Dictionary:
	var f := await make_match({"p1_controller": "cpu", "p2_controller": "cpu", "cpu_difficulty": "hard"})
	for i in 2:
		f[i].rng.seed = 1000 + i + seed_n * 31
		if f[i]._brain != null:
			f[i]._brain.rng.seed = 4242 + i * 77 + seed_n * 7919
	var rep := new_report()
	var t := 0.0
	while t < secs:
		await physics_frame
		t += 1.0 / 120.0
		if m.ms.phase == MatchState.Phase.FIGHT:
			sample(f, rep, t)
	return rep


## P1 is walked into a corner (or onto a rope) and holds guard; P2 presses forward and spams power punches.
func pinned_case(tag: String, pos1: Vector3, face_dir: Vector3, secs: float, vary: int) -> Dictionary:
	var f := await make_match({"p1_controller": "dummy", "p2_controller": "dummy"})
	var p1: Fighter = f[0]
	var p2: Fighter = f[1]
	p1.external_input = FighterInput.new()
	p2.external_input = FighterInput.new()
	p1.stats.infinite_stamina = true
	p2.stats.infinite_stamina = true
	await steps(60)
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 7 + vary
	p1.global_position = pos1
	p2.global_position = pos1 + face_dir * 1.2
	p1.velocity = Vector3.ZERO
	var rep := new_report()
	var strikes := ["RJab", "LHook", "RHook", "RUppercut", "LJab", "LUppercut"]
	var n := int(secs * 120.0)
	for i in n:
		var inp := FighterInput.new()
		# P1 keeps pushing back into the ropes (worst case: it is wedged); P2 walks in and throws power shots
		var into := -face_dir   # P2 stands at pos1 + face_dir, so the wall is behind P1 on the -face_dir side
		inp.move = Vector2(into.x, -into.z) if vary % 2 == 0 else Vector2.ZERO
		p1.stats.head = 100.0
		p1.stats.body = 100.0
		p1.stats.rock_meter = 0.0
		p1.stats.rocked = false
		p1.external_input = inp
		var inp2 := FighterInput.new()
		inp2.move = Vector2(-face_dir.x, face_dir.z)   # P2 walks towards P1 (world -face_dir)
		if i % 22 == 0:
			inp2.strikes.append(strikes[rnd.randi() % strikes.size()])
		p2.external_input = inp2
		await physics_frame
		sample(f, rep, i / 120.0)
	return rep


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== CPU vs CPU (hard)")
	var worst := 9.0
	for s in [0, 1, 2]:
		var r := await cpu_fight(s, 90.0)
		report_line("seed %d" % s, r)
		check(r["frames"] > 2000, "seed %d: enough upright frames sampled (%d)" % [s, r["frames"]])
		check(r["below"] == 0, "seed %d: chest distance never below %.2f m (min %.3f)" % [s, MIN_CHEST - CONTACT_TOL, r["min_chest"]])
		check(r["rope_bad"] == 0, "seed %d: no chest beyond the rope line (max %.3f)" % [s, r["rope_max"]])
		check(r["min_centre"] >= MIN_CENTRES, "seed %d: root distance >= %.2f (min %.3f)" % [s, MIN_CENTRES, r["min_centre"]])
		check(r["min_torso"] >= MIN_TORSO, "seed %d: torso-to-torso >= %.2f (min %.3f)" % [s, MIN_TORSO, r["min_torso"]])
		check(r["min_guard_head"] >= MIN_GUARD_HEAD, "seed %d: guard hands stay out of the foe's head >= %.2f (min %.3f)" % [s, MIN_GUARD_HEAD, r["min_guard_head"]])
	print("== pinned on the ropes / in a corner, foe spams power punches")
	var cases := [
		["corner", Vector3(-2.85, 0, -2.85), Vector3(1, 0, 1).normalized()],
		["rope +x", Vector3(2.85, 0, 0.3), Vector3(-1, 0, 0)],
		["rope -z", Vector3(0.4, 0, -2.85), Vector3(0, 0, 1)],
	]
	var vary := 0
	for c in cases:
		for v in 2:
			var r := await pinned_case(c[0], c[1], c[2], 14.0, vary)
			vary += 1
			report_line("%s v%d" % [c[0], v], r)
			check(r["frames"] > 800, "%s v%d: frames sampled" % [c[0], v])
			check(r["below"] == 0, "%s v%d: chest distance never below %.2f m (min %.3f)" % [c[0], v, MIN_CHEST - CONTACT_TOL, r["min_chest"]])
			check(r["rope_bad"] == 0, "%s v%d: no chest beyond the rope line (max %.3f)" % [c[0], v, r["rope_max"]])
			check(r["min_centre"] >= MIN_CENTRES, "%s v%d: root distance >= %.2f (min %.3f)" % [c[0], v, MIN_CENTRES, r["min_centre"]])
			check(r["min_torso"] >= MIN_TORSO, "%s v%d: torso-to-torso >= %.2f (min %.3f)" % [c[0], v, MIN_TORSO, r["min_torso"]])
			check(r["min_guard_head"] >= MIN_GUARD_HEAD, "%s v%d: guard hands stay out of the foe's head >= %.2f (min %.3f)" % [c[0], v, MIN_GUARD_HEAD, r["min_guard_head"]])
	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
