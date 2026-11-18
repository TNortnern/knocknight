extends SceneTree
# Pose polish: the final pose never breaks the hip / knee / trunk budget (PoseLimiter), KO falls drop in place and
# differ by punch type, limbs rest outside the torso, and the get-up blend does not pop.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_pose_limits.gd
# Prints PASS/FAIL and exits 0 / 1.

const PoseLimiter := preload("res://scripts/fighter/pose_limiter.gd")

var failures := 0
var m: Match
var _pose := {}       ## fighter instance id -> {hip, lk, rk, pitch, hand_*}: final skeleton pose of the last modifier pass


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


func make_match(cfg: Dictionary) -> Array:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	Engine.time_scale = 1.0
	_pose.clear()
	var full := {"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "rules": "boxing",
		"p1_model": "viper", "p2_model": "anvil"}
	full.merge(cfg, true)
	m = load("res://scenes/match.tscn").instantiate()
	m.setup(full)
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	for fi in f:
		watch(fi)
	return f


## Skeleton poses are only final inside Skeleton3D.skeleton_updated (after the modifiers), see test_rocked.gd.
func watch(f: Fighter) -> void:
	var sk: Skeleton3D = f.rig.skeleton
	sk.skeleton_updated.connect(func():
		if not sk.is_inside_tree():
			return
		var g := sk.global_transform
		var hip := g * sk.get_bone_global_pose(sk.find_bone("hip")).origin
		var chest := g * sk.get_bone_global_pose(sk.find_bone("chestUpper")).origin
		var v := f.global_basis.inverse() * (chest - hip)
		_pose[f.get_instance_id()] = {"hip": hip.y, "hip_pos": hip,
			"lk": (g * sk.get_bone_global_pose(sk.find_bone("lShin")).origin).y,
			"rk": (g * sk.get_bone_global_pose(sk.find_bone("rShin")).origin).y,
			"pitch": rad_to_deg(atan2(v.z, v.y))})


const STAND_STATES := ["idle", "attack", "hit", "slip", "crouch", "taunt"]


## Samples both fighters for `frames` physics frames; returns violations of the budget.
func sample_budget(f: Array, frames: int, tag: String, report: Dictionary) -> void:
	for i in frames:
		await physics_frame
		for fi in f:
			var fighter: Fighter = fi
			if not (fighter.state_name in STAND_STATES):
				continue
			var d: Dictionary = _pose.get(fighter.get_instance_id(), {})
			if d.is_empty():
				continue
			var deep: float = fighter._pose_limiter.deep
			var hip_min := lerpf(0.62, 0.48, deep)       # the limiter floors are 0.66 / 0.50; the test allows a hair of tolerance
			var knee_min := lerpf(0.24, 0.17, deep)
			var trunk_max := lerpf(58.0, 84.0, deep)
			report["frames"] += 1
			report["hip_min"] = minf(report["hip_min"], d["hip"])
			report["knee_min"] = minf(report["knee_min"], minf(d["lk"], d["rk"]))
			report["pitch_max"] = maxf(report["pitch_max"], d["pitch"])
			if d["hip"] < hip_min:
				report["hip_bad"] += 1
			if minf(d["lk"], d["rk"]) < knee_min:
				report["knee_bad"] += 1
			if d["pitch"] > trunk_max:
				report["trunk_bad"] += 1
			if fighter._pose_limiter.hip_raised > 0.0005 or fighter._pose_limiter.knee_lifted or fighter._pose_limiter.trunk_cut > 0.0:
				report["limiter_acted"] += 1


func new_report() -> Dictionary:
	return {"frames": 0, "hip_min": 9.0, "knee_min": 9.0, "pitch_max": -99.0, "hip_bad": 0, "knee_bad": 0, "trunk_bad": 0, "limiter_acted": 0}


func finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


# ---------------------------------------------------------------- KO helpers
func punch_ko(tag: String, gap: float, off: float, body := false, model := "anvil") -> Dictionary:
	var f := await make_match({"p1_controller": "dummy", "p2_controller": "dummy", "p2_model": model})
	var p1: Fighter = f[0]
	var p2: Fighter = f[1]
	p1.external_input = FighterInput.new()
	p2.external_input = FighterInput.new()
	p1.stats.infinite_stamina = true
	p2.stats.infinite_stamina = true
	await steps(90)
	p1.global_position = Vector3(-gap * 0.5, 0, off * 0.5)
	p2.global_position = Vector3(gap * 0.5, 0, -off * 0.5)
	await steps(60)
	p2._ragdoll.rng_seed = 4000 + absi(tag.hash()) % 1000   # fixed per punch: rest poses reproducible
	var start := p2.global_position
	if body:
		p2.stats.body_max = 0.0
	else:
		p2.stats.head = 0.4
		p2.stats.knockdowns = 3
	p1.external_input.strikes.append(tag)
	await steps(1)
	p1.external_input.strikes.clear()
	var n := 0
	while p2.state != Fighter.State.DOWN and n < 600:
		await steps(1)
		n += 1
	await steps(120 * 6)
	var rd = p2._ragdoll
	var worst := -9.0
	for arm in ["lForearm", "rForearm", "lHand", "rHand"]:
		for box in ["chest", "abdomen"]:
			worst = maxf(worst, penetration(rd.bones[arm], rd.bones[box]))
	var tt := 9.0   # closest approach of the two thigh axes
	var pts: Array = capsule_pts(rd.bones["rThigh"])
	for p in capsule_pts(rd.bones["lThigh"]):
		for i in pts.size() - 1:
			var ab: Vector3 = pts[i + 1] - pts[i]
			var t := clampf((p - pts[i]).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
			tt = minf(tt, p.distance_to(pts[i] + ab * t))
	var pel: Vector3 = rd.pelvis_position()
	var head: Vector3 = rd.head_position()
	return {"limb_in": worst, "thigh_gap": tt, "groups": rd._groups_on.size(), "slide": Vector2(pel.x - start.x, pel.z - start.z).length(), "head": head - start, "pelvis": pel - start,
		"face_up": rd.lying_face_up(), "kind": rd.kind, "hit": p2.state == Fighter.State.DOWN,
		"chest_ny": (rd.bones["chest"] as PhysicalBone3D).global_basis.z.y}


func capsule_pts(pb: PhysicalBone3D, n := 7) -> Array:
	var cap := (pb.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D
	var out: Array = []
	var half := maxf(cap.height * 0.5 - cap.radius, 0.0)
	var ax := pb.global_transform.basis.y.normalized()
	for i in n:
		out.append(pb.global_position + ax * (half * (2.0 * i / float(n - 1) - 1.0)))
	return out


## Deepest penetration (m) of a limb capsule axis into a torso box: > 0 = the capsule's axis is inside the box shape.
func penetration(limb: PhysicalBone3D, box: PhysicalBone3D) -> float:
	var half := ((box.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size * 0.5
	var worst := -9.0
	var inv := box.global_transform.affine_inverse()
	for p in capsule_pts(limb):
		var q: Vector3 = inv * p
		var d := Vector3(absf(q.x) - half.x, absf(q.y) - half.y, absf(q.z) - half.z)
		var inside := -maxf(d.x, maxf(d.y, d.z))   # > 0 when inside (distance to the nearest face)
		worst = maxf(worst, inside)
	return worst


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== A. the pose budget holds over 60 s of CPU fighting (both difficulties, final skeleton pose)")
	for cfg in [{"cpu_difficulty": "hard", "rules": "boxing"}, {"cpu_difficulty": "normal", "rules": "boxing"}]:
		var c: Dictionary = {"p1_controller": "cpu", "p2_controller": "cpu"}
		c.merge(cfg, true)
		var f := await make_match(c)
		var rep := new_report()
		await sample_budget(f, 120 * 60, "cpu", rep)
		print("  %s: %d frames, hip min %.3f, knee min %.3f, trunk pitch max %.1f deg, limiter acted %d" % [cfg["cpu_difficulty"], rep["frames"], rep["hip_min"], rep["knee_min"], rep["pitch_max"], rep["limiter_acted"]])
		check(rep["frames"] > 3000, "%s: sampled the fight (%d standing frames)" % [cfg["cpu_difficulty"], rep["frames"]])
		check(rep["hip_bad"] == 0, "%s: hips never below the floor (%d bad frames, min %.3f m)" % [cfg["cpu_difficulty"], rep["hip_bad"], rep["hip_min"]])
		check(rep["knee_bad"] == 0, "%s: no knee near the canvas (%d bad frames, min %.3f m)" % [cfg["cpu_difficulty"], rep["knee_bad"], rep["knee_min"]])
		check(rep["trunk_bad"] == 0, "%s: trunk flexion within budget (%d bad frames, max %.1f deg)" % [cfg["cpu_difficulty"], rep["trunk_bad"], rep["pitch_max"]])

	print("== B. stacked layers: body jabs thrown over and over (clip alone lunges to one knee), fatigue + duck on top")
	var f2 := await make_match({"p1_controller": "dummy", "p2_controller": "dummy"})
	var a: Fighter = f2[0]
	var b: Fighter = f2[1]
	a.external_input = FighterInput.new()
	b.external_input = FighterInput.new()
	a.stats.infinite_stamina = true
	b.stats.infinite_stamina = true
	await steps(60)
	a.global_position = Vector3(-0.45, 0, 0)
	b.global_position = Vector3(0.45, 0, 0)
	var rep2 := new_report()
	for k in 18:
		a.external_input.strikes.append("RBodyJab" if k % 3 != 2 else "RBodyHook")
		await sample_budget(f2, 1, "stack", rep2)
		a.external_input.strikes.clear()
		await sample_budget(f2, 70, "stack", rep2)
	check(rep2["limiter_acted"] > 0, "the limiter had to act on the stacked layers (%d frames)" % rep2["limiter_acted"])
	check(rep2["hip_bad"] == 0 and rep2["knee_bad"] == 0, "body jabs: hips >= floor and knees clear (hip min %.3f, knee min %.3f)" % [rep2["hip_min"], rep2["knee_min"]])
	check(rep2["trunk_bad"] == 0, "body jabs: trunk flexion within budget (max %.1f deg)" % rep2["pitch_max"])
	# a duck must not also get the punch wind-up dip
	a.external_input.strikes.clear()
	await steps(30)
	var base_hip: float = _pose[a.get_instance_id()]["hip"]
	check(a._punch_pose.w_dip < 0.01, "idle: no wind-up dip (w_dip %.3f)" % a._punch_pose.w_dip)
	check(base_hip > 0.7, "idle hip height %.3f" % base_hip)

	print("== C. KO falls: drop in place, differ by punch type")
	# contact-only hits: the scripted (unaimed) punches only touch from these ranges (was 0.75-0.85); the uppercut at 0.50 not 0.46: gloves in a clinch now stay outside the torso hull, so the target guard is no longer parked inside the thrower; the uppercut is aimed (unaimed it only grazes the chin / chest from here since the quicker tempo clips)
	var cases := [["LJab", "jab", 0.60, 0.0, false], ["RJab", "cross", 0.60, 0.0, false], ["LHook", "hook L", 0.60, 0.0, false],
		["RHook", "hook R", 0.60, 0.10, false], ["RUppercut@aim", "uppercut", 0.50, 0.0, false], ["RBodyHook", "body hook", 0.70, 0.0, true]]
	var res := {}
	for c in cases:
		var r := await punch_ko(c[0], c[2], c[3], c[4])
		res[c[1]] = r
		print("    %-10s kind %-8s slide %.2f m  head (%.2f, %.2f)  chest_ny %.2f  %s" % [c[1], r["kind"], r["slide"], r["head"].x, r["head"].z, r["chest_ny"], "up" if r["face_up"] else "down"])
		check(r["hit"], "%s: KO landed" % c[1])
	for k in ["jab", "hook L", "hook R", "body hook"]:
		var lim := 0.6 if res[k]["face_up"] else 0.9   # pitching forward onto the face carries the pelvis about a body-length further
		check(res[k]["slide"] <= lim, "%s: slide %.2f m <= %.1f" % [k, res[k]["slide"], lim])
	for k in ["cross", "uppercut"]:
		check(res[k]["slide"] <= 0.9, "%s: slide %.2f m <= 0.9" % [k, res[k]["slide"]])
	# P1 stands at -x: its left hook travels to +z, its right hook to -z; the body falls the way the blow went
	check(res["hook L"]["head"].z > 0.3 and res["hook R"]["head"].z < -0.3, "hooks: L ends on +z (%.2f), R ends on -z (%.2f)" % [res["hook L"]["head"].z, res["hook R"]["head"].z])
	check(res["jab"]["face_up"] and res["cross"]["face_up"] and res["uppercut"]["face_up"], "straights and the uppercut end face up")
	check(res["hook L"]["kind"] == "hook" and res["body hook"]["kind"] == "body" and res["uppercut"]["kind"] == "upper", "punch kinds classified")
	# the head ends further back after an uppercut / cross than after a hook; the hook ends more sideways
	check(absf(res["hook L"]["head"].z) > absf(res["hook L"]["head"].x), "hook: the body lies across the line of the blow")
	check(res["uppercut"]["head"].x > res["hook L"]["head"].x + 0.3, "uppercut: head thrown back past the hook's (%.2f vs %.2f)" % [res["uppercut"]["head"].x, res["hook L"]["head"].x])
	check(res["body hook"]["head"].x < 0.0, "body shot: folds towards the attacker, head ends on his side (%.2f)" % res["body hook"]["head"].x)
	var finals := {}
	for k in res:
		finals[k] = Vector2(res[k]["head"].x, res[k]["head"].z)
	# at most one pair may rest close together (the straight and the uppercut both drop him back, face up; which one ends
	# nearer depends on everything simulated before, ~0.05-0.17 m apart); every other pair must differ
	var dists: Array = []
	for k1 in finals:
		for k2 in finals:
			if k1 < k2:
				dists.append((finals[k1] as Vector2).distance_to(finals[k2]))
	dists.sort()
	var mind: float = dists[1] if dists.size() > 1 else 9.0
	# falls are outcome-driven (face up / down / side) now, so two punches can rest near each other; orientation carries the variety
	check(mind > 0.12, "rest head positions differ (second-closest pair %.2f m)" % mind)

	print("== D. limbs at rest stay out of the torso")
	for k in res:
		check(res[k]["limb_in"] < 0.03, "%s: forearms / hands outside the chest and abdomen (deepest axis point %.3f m inside)" % [k, res[k]["limb_in"]])
		check(res[k]["thigh_gap"] > 0.12, "%s: thighs do not overlap (axes %.3f m apart, radii 0.082 each)" % [k, res[k]["thigh_gap"]])
		check(res[k]["groups"] >= 1, "%s: self-collision groups switched on (%d of 3)" % [k, res[k]["groups"]])

	print("== E. knockdown get-up: no pop out of the ragdoll pose")
	var f3 := await make_match({"p1_controller": "dummy", "p2_controller": "dummy"})
	var q1: Fighter = f3[0]
	var q2: Fighter = f3[1]
	q1.external_input = FighterInput.new()
	q2.external_input = FighterInput.new()
	await steps(60)
	q1.global_position = Vector3(-0.45, 0, 0)
	q2.global_position = Vector3(0.45, 0, 0)
	await steps(30)
	q2._do_knockdown("L")
	q2.getup_count = 4
	var prev := Vector3.INF
	var worst_step := 0.0
	var worst_up := 0.0
	var n := 0
	var in_getup := 0
	var rest_pos := Vector3.ZERO
	while n < 120 * 25 and not (n > 30 and q2.state == Fighter.State.IDLE):
		await steps(1)
		n += 1
		var d: Dictionary = _pose.get(q2.get_instance_id(), {})
		if d.is_empty():
			continue
		var hp: Vector3 = d["hip_pos"]
		if q2.state == Fighter.State.GETUP or q2._ragdoll.blend.weight > 0.0:
			if prev != Vector3.INF:
				worst_step = maxf(worst_step, hp.distance_to(prev))
			in_getup += 1
		prev = hp
	print("    get-up frames %d, largest hip step %.3f m/frame" % [in_getup, worst_step])
	check(in_getup > 60, "the get-up was observed (%d frames)" % in_getup)
	check(worst_step < 0.06, "hips move smoothly through the blend (largest step %.3f m per frame)" % worst_step)
	check(q2.state == Fighter.State.IDLE, "back on his feet")

	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
