extends SceneTree
# Liveliness: additive hit flinch (spring-damper), idle motion, committed punches unaffected, pose budgets hold.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_alive.gd
# Prints PASS/FAIL and exits 0 / 1.

var failures := 0
var m: Match
var _rec := {}      ## fighter instance id -> latest final pose {head_yaw, head_pitch, head_pos, hip, hand_l, hand_r, trunk_pitch}
var _k := {}        ## fighter instance id -> head forward in head-rest space


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


func make_match() -> Array:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	Engine.time_scale = 1.0
	_rec.clear()
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "rules": "boxing",
		"p1_model": "viper", "p2_model": "anvil", "p1_controller": "dummy", "p2_controller": "dummy"})
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-0.6, 0, 0)
	f[1].global_position = Vector3(0.6, 0, 0)
	for fi in f:
		fi.external_input = FighterInput.new()
		watch(fi)
	await steps(90)
	return f


func watch(f: Fighter) -> void:
	var sk: Skeleton3D = f.rig.skeleton
	var hi := sk.find_bone("head")
	var rest := sk.get_bone_global_rest(hi).basis.orthonormalized()
	sk.skeleton_updated.connect(func():
		if not sk.is_inside_tree():
			return
		var g := sk.global_transform
		var S := g.basis.orthonormalized().inverse()
		var id := f.get_instance_id()
		if not _k.has(id):
			_k[id] = rest.inverse() * (S * f.global_basis.z).normalized()
		var hb: Basis = sk.get_bone_global_pose(hi).basis.orthonormalized()
		var hf: Vector3 = f.global_basis.inverse() * (g.basis.orthonormalized() * (hb * (_k[id] as Vector3)))
		var hip := g * sk.get_bone_global_pose(sk.find_bone("hip")).origin
		var chest := g * sk.get_bone_global_pose(sk.find_bone("chestUpper")).origin
		var v := f.global_basis.inverse() * (chest - hip)
		_rec[id] = {"yaw": rad_to_deg(atan2(hf.x, hf.z)), "pitch": rad_to_deg(atan2(hf.y, Vector2(hf.x, hf.z).length())),
			"head_pos": g * sk.get_bone_global_pose(hi).origin, "hip": hip,
			"hand_l": g * sk.get_bone_global_pose(sk.find_bone("lHand")).origin,
			"hand_r": g * sk.get_bone_global_pose(sk.find_bone("rHand")).origin,
			"trunk": rad_to_deg(atan2(v.z, v.y))})


func r(f: Fighter) -> Dictionary:
	return _rec.get(f.get_instance_id(), {})


## Runs a fresh, deterministic match: warm up, optionally kick the attacker-side fighter `a` at frame 0 (fatigued if asked),
## then records its pose for `frames` frames. Two runs (kick / no kick) differ only by the flinch.
func run_case(dir: String, zone: String, s: float, kick: bool, frames: int, tired := false) -> Array:
	var f: Array = await make_match()
	var a: Fighter = f[0]
	var b: Fighter = f[1]
	if tired:
		a.stats.stamina = a.stats.stamina_max * 0.08
		await steps(60)
	if kick:
		a.flinch(b, {"dir": dir}, s, zone)
	var out := []
	for i in frames:
		await physics_frame
		var c := r(a)
		out.append({"t": float(i + 1) / 120.0, "yaw": c["yaw"], "pitch": c["pitch"], "trunk": c["trunk"],
			"fh": a._hit_flinch.head, "ft": a._hit_flinch.torso})
	return out


## flinch-only response: kick run minus control run
func trace(dir: String, zone: String, s: float, frames: int, tired := false) -> Array:
	var ctl: Array = await run_case(dir, zone, s, false, frames, tired)
	var hit: Array = await run_case(dir, zone, s, true, frames, tired)
	var out := []
	for i in frames:
		out.append({"t": hit[i]["t"], "yaw": hit[i]["yaw"] - ctl[i]["yaw"], "pitch": hit[i]["pitch"] - ctl[i]["pitch"],
			"trunk": hit[i]["trunk"] - ctl[i]["trunk"], "fh": hit[i]["fh"], "ft": hit[i]["ft"]})
	return out


func peak(tr: Array, key: String) -> Array:
	var best := 0.0
	var at := 0.0
	for e in tr:
		if absf(e[key]) > absf(best):
			best = e[key]
			at = e["t"]
	return [best, at]


func tail_ratio(tr: Array, key: String, t: float, pk: float) -> float:
	for e in tr:
		if e["t"] >= t:
			return absf(e[key]) / maxf(absf(pk), 1e-6)
	return 1.0


func _initialize() -> void:
	var f := await make_match()
	var a: Fighter = f[0]
	var b: Fighter = f[1]
	check(a._hit_flinch != null and a.has_method("flinch"), "fighter exposes flinch() and a HitFlinch layer")

	# ---- idle liveliness: never static (head / hips / hands move) over 2 s
	var lo := {}
	var hi := {}
	for i in 240:
		await physics_frame
		var c := r(a)
		for key in ["head_pos", "hip", "hand_l", "hand_r"]:
			var p: Vector3 = c[key]
			if not lo.has(key):
				lo[key] = p
				hi[key] = p
			lo[key] = Vector3(minf(lo[key].x, p.x), minf(lo[key].y, p.y), minf(lo[key].z, p.z))
			hi[key] = Vector3(maxf(hi[key].x, p.x), maxf(hi[key].y, p.y), maxf(hi[key].z, p.z))
	for key in ["head_pos", "hip", "hand_l", "hand_r"]:
		var span: float = (hi[key] - lo[key]).length() * 1000.0
		check(span > 6.0, "idle %s moves over 2 s (%.1f mm)" % [key, span])
	check(span_ok(hi["head_pos"] - lo["head_pos"]), "idle motion stays modest (head span < 30 cm)")
	check(absf(a._hit_flinch.head.y) < 0.001, "no flinch residue at idle")
	var gaze_err := absf(r(a)["yaw"])
	check(gaze_err < 25.0, "head roughly faces the foe at idle (yaw %.1f deg)" % gaze_err)

	# ---- flinch: hook from the attacker's left turns the head to the victim's left, jab snaps back, uppercut lifts the chin
	var tr: Array = await trace("L", "head", 1.0, 60)
	var pk: Array = peak(tr, "yaw")
	print("  hook L: yaw peak %.1f deg at %.3f s" % [pk[0], pk[1]])
	check(pk[0] > 22.0 and pk[0] < 52.0, "left hook turns the head to the victim's left, 22-52 deg (%.1f)" % pk[0])
	check(pk[1] <= 0.12, "hook peak within 0.12 s (%.3f)" % pk[1])
	# the reaction is held a beat (HitFlinch W_HEAD 12, like the reference fighters) instead of snapping home in 0.2 s; it is still gone by 0.5 s
	var tl := tail_ratio(tr, "yaw", 0.50, pk[0])
	check(tl < 0.10, "hook flinch back under 10 %% by 0.5 s (%.3f)" % tl)
	tr = await trace("R", "head", 1.0, 60)
	pk = peak(tr, "yaw")
	check(pk[0] < -22.0, "right hook turns the head the other way (%.1f)" % pk[0])
	tr = await trace("F", "head", 0.5, 60)
	pk = peak(tr, "pitch")
	print("  jab 0.5: pitch peak %.1f deg at %.3f s" % [pk[0], pk[1]])
	check(pk[0] > 0.8 and pk[0] < 9.0 and pk[1] <= 0.12, "jab: small snap back (%.1f deg at %.3f s)" % [pk[0], pk[1]])
	var jab_peak: float = pk[0]
	tr = await trace("U", "head", 1.0, 60)
	pk = peak(tr, "pitch")
	check(pk[0] > jab_peak and pk[0] > 12.0, "uppercut snaps the chin up more than a jab (%.1f deg)" % pk[0])
	tr = await trace("F", "body", 1.0, 90)   # 0.75 s: the fold is held longer now (W_TORSO 10) and the recovery is read at 0.65 s
	pk = peak(tr, "trunk")
	print("  body: trunk fold peak %.1f deg at %.3f s" % [pk[0], pk[1]])
	check(pk[0] > 4.0 and pk[1] <= 0.16, "body shot folds the trunk forward (%.1f deg at %.3f s)" % [pk[0], pk[1]])
	check(tail_ratio(tr, "trunk", 0.65, pk[0]) < 0.12, "body fold recovers")

	# ---- tired fighters swing more
	var fresh_tr: Array = await trace("L", "head", 0.7, 40)
	var fresh_pk: Array = peak(fresh_tr, "yaw")
	var tired_tr: Array = await trace("L", "head", 0.7, 40, true)
	var tired_pk: Array = peak(tired_tr, "yaw")
	check(absf(tired_pk[0]) > absf(fresh_pk[0]) * 1.1, "tired fighter flinches more (%.1f vs %.1f deg)" % [tired_pk[0], fresh_pk[0]])

	# ---- accumulation clamps: ten hooks in a row never exceed the head clamp
	f = await make_match()
	a = f[0]
	b = f[1]
	var worst := 0.0
	for i in 10:
		a.flinch(b, {"dir": "L"}, 1.0, "head")
		await steps(4)
		worst = maxf(worst, absf(a._hit_flinch.head.y))
	check(worst <= a._hit_flinch.HEAD_MAX.y + 1e-3, "stacked hits clamp (max head yaw %.2f rad)" % worst)

	# ---- committed punch unaffected: same jab with and without a flinch, the striking hand stays within 1 cm
	var base := await jab_hand_track(false)
	var flin := await jab_hand_track(true)
	var dev := 0.0
	var n := mini(base.size(), flin.size())
	for i in n:
		if base[i] == null or flin[i] == null:
			continue
		dev = maxf(dev, (base[i] as Vector3).distance_to(flin[i]))
	print("  punching hand deviation %.1f mm over %d frames" % [dev * 1000.0, n])
	check(n > 20 and dev < 0.01, "punching hand unaffected by a flinch (< 1 cm): %.2f cm" % (dev * 100.0))

	# ---- pose budgets hold under repeated flinches (the limiter stays last)
	f = await make_match()
	a = f[0]
	b = f[1]
	var worst_hip := 9.0
	var worst_pitch := 0.0
	for i in 8:
		a.flinch(b, {"dir": "F" if i % 2 == 0 else "L"}, 1.0, "body")
		for j in 40:
			await physics_frame
			var c := r(a)
			worst_hip = minf(worst_hip, (c["hip"] as Vector3).y)
			worst_pitch = maxf(worst_pitch, c["trunk"])
	check(worst_hip >= 0.62, "hips never below the budget under flinches (%.3f m)" % worst_hip)
	check(worst_pitch <= 58.0, "trunk flexion within the limiter budget (%.1f deg)" % worst_pitch)

	if m != null:
		get_root().remove_child(m)
		m.queue_free()
	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)


func span_ok(v: Vector3) -> bool:
	return v.length() < 0.30


## Runs one left jab from a fresh match; with `with_flinch` a body hook flinch hits the attacker mid-punch.
## Returns the striking hand (world) position per frame while the attack is active.
func jab_hand_track(with_flinch: bool) -> Array:
	var f: Array = await make_match()
	var a: Fighter = f[0]
	var b: Fighter = f[1]
	for c in a.rig.skeleton.get_children():   # this check is about the pin that keeps a flinch off a flying punch; the glove hold at contact (impact_hold.gd,
		if c.name == "ImpactHold":             # tests/test_hit_registration.gd) depends on the exact tick the blow lands, so it is switched off for the comparison
			(c as SkeletonModifier3D).active = false
	# the foe out of reach: with the straights' trunk lean (punch_pose.gd REACH_LEAN) the jab now lands from 1.2 m, and the contact tick (which
	# the flinch can shift by one) moves the animation on (fighter.gd _catch_up_after_contact): that is not what this check is about
	b.global_position = Vector3(1.2, 0, 0)
	await physics_frame
	a.external_input.strikes.append("LJab")
	await physics_frame
	a.external_input.strikes.clear()
	var out := []
	for i in 40:
		await physics_frame
		if i == 6 and with_flinch:
			a.flinch(b, {"dir": "L"}, 1.0, "head")
			a.flinch(b, {"dir": "F"}, 1.0, "body")
		if a.state_name == "attack":
			out.append(r(a)["hand_l"])
		else:
			out.append(null)
	return out
