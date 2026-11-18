extends SceneTree
# Motion smoothness: over a 30 s CPU-vs-CPU fight the final skeleton pose (after PoseLimiter) is sampled every physics frame;
# per-bone angular velocity change (angular acceleration step) and pose jumps are measured with the inertialization layer
# off and on and both are reported. Also: punch arrival timing is unchanged by the layer (<= 20 ms), and the hit-flinch
# cascade (head -> shoulders -> hips) keeps its delays.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_motion_smooth.gd
# Prints PASS/FAIL and exits 0 / 1.

const BONES := ["hip", "abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "neckLower", "neckUpper", "head",
		"lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend", "lHand", "rHand", "lThighBend", "rThighBend", "lShin", "rShin"]
const FALL_STATES := ["fall", "count", "getup", "down", "win"]
const SECS := 30.0
const JUMP_STEP := 0.20        ## rad in one 120 Hz frame (~1400 deg/s), and a sudden one, = a pose jump
const ACC_STEP := 30.0         ## rad/s change of angular velocity in one frame

var failures := 0
var m: Match


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


static func rv(q: Quaternion) -> Vector3:
	q = q.normalized()
	if q.w < 0.0:
		q = Quaternion(-q.x, -q.y, -q.z, -q.w)
	var s := sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
	if s < 1e-7:
		return Vector3(q.x, q.y, q.z) * 2.0
	return Vector3(q.x, q.y, q.z) / s * (2.0 * atan2(s, q.w))


func make_match(cfg: Dictionary) -> Array:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	Engine.time_scale = 1.0
	var full := {"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "rules": "boxing",
		"p1_model": "viper", "p2_model": "anvil"}
	full.merge(cfg, true)
	m = load("res://scenes/match.tscn").instantiate()
	m.setup(full)
	get_root().add_child(m)
	await process_frame
	return m.get_fighters()


func watch(f: Fighter, st: Dictionary) -> void:
	var sk: Skeleton3D = f.rig.skeleton
	var idx := []
	for n in BONES:
		idx.append(sk.find_bone(n))
	var rec := {"frame": -1, "q": {}, "w": {}, "ok": 0}
	sk.skeleton_updated.connect(func():
		if not sk.is_inside_tree():
			return
		var fr := Engine.get_physics_frames()
		if fr == rec["frame"]:
			return
		var down: bool = f.state_name in FALL_STATES or f._ragdoll.active
		var good: bool = rec["frame"] >= 0 and fr == rec["frame"] + 1 and not down and rec["ok"] >= 2
		rec["frame"] = fr
		rec["ok"] = 0 if down else rec["ok"] + 1
		var dt := 1.0 / float(Engine.physics_ticks_per_second)
		for i in idx:
			var q := sk.get_bone_pose_rotation(i)
			if good and rec["q"].has(i):
				var w: Vector3 = rv(q * (rec["q"][i] as Quaternion).inverse()) / dt
				var step := w.length() * dt
				var acc := (w - (rec["w"][i] as Vector3)).length()
				st["n"] += 1
				if step > st["max_step"]:
					st["max_step"] = step
					st["max_who"] = "%s %s %s in %.2f off %.2f post %.2f" % [sk.get_bone_name(i), f.state_name, String(f.anim.action_clip), f.inertia.dbg_in.get(i, -1.0), f.inertia.max_off, f.inertia_post.max_off]
				st["max_acc"] = maxf(st["max_acc"], acc)
				st["acc_sum"] += acc
				# a jump = a big step that is not just fast authored motion (the previous frame was already moving that fast)
				if step > JUMP_STEP and step > 2.0 * (rec["w"][i] as Vector3).length() * dt + 0.1:
					st["jumps"] += 1
					if st["log"].size() < 40:
						st["log"].append("%s %s %s step %.2f in_step %.2f off %.2f hipUp %.3f kneeLift %s trunkcut %.2f post_off %.2f" % [sk.get_bone_name(i), f.state_name, String(f.anim.action_clip), step, f.inertia.dbg_in.get(i, -1.0), f.inertia.max_off, f._pose_limiter.hip_raised, str(f._pose_limiter.knee_lifted), f._pose_limiter.trunk_cut, f.inertia_post.max_off])
				if acc > ACC_STEP:
					st["acc_hi"] += 1
				rec["w"][i] = w
			else:
				rec["w"][i] = Vector3.ZERO
			rec["q"][i] = q)


func fight_sample(inertia_on: bool) -> Dictionary:
	var f: Array = await make_match({"p1_controller": "cpu", "p2_controller": "cpu", "cpu_difficulty": "hard"})
	var st := {"n": 0, "max_step": 0.0, "max_acc": 0.0, "acc_sum": 0.0, "jumps": 0, "acc_hi": 0, "punches": 0, "log": [], "max_who": ""}
	for fi in f:
		fi.inertia.enabled = inertia_on
		fi.inertia_post.enabled = inertia_on
		watch(fi, st)
	var last := [0, 0]
	for i in int(SECS * 120.0):
		await physics_frame
		for k in 2:
			var a: Fighter = f[k]
			if a.state_name == "attack" and a.atk.has("serial") and a.atk["serial"] != last[k]:
				last[k] = a.atk["serial"]
				st["punches"] += 1
	st["jumps_caught"] = f[0].inertia.jumps + f[1].inertia.jumps
	print("   (captured jumps: pre %d, post %d)" % [st["jumps_caught"], f[0].inertia_post.jumps + f[1].inertia_post.jumps])
	return st


## Physics tick at which the striking hand is furthest from the fighter along its forward axis.
func jab_peak_tick(inertia_on: bool) -> int:
	var f: Array = await make_match({"p1_controller": "dummy", "p2_controller": "dummy"})
	var a: Fighter = f[0]
	a.global_position = Vector3(-0.6, 0, 0)
	f[1].global_position = Vector3(0.6, 0, 0)
	for x in f:
		x.external_input = FighterInput.new()
		x.stats.infinite_stamina = true
		x.inertia.enabled = inertia_on
		x.inertia_post.enabled = inertia_on
	await steps(120)
	var sk: Skeleton3D = a.rig.skeleton
	var hi := sk.find_bone("lHand")
	var best := -1.0
	var best_t := -1
	a.external_input.strikes.append("LJab")
	await steps(1)
	a.external_input.strikes.clear()
	for t in 70:
		await physics_frame
		var hp: Vector3 = sk.global_transform * sk.get_bone_global_pose(hi).origin
		var d: float = (a.global_basis.inverse() * (hp - a.global_position)).z
		if d > best:
			best = d
			best_t = t
	return best_t


func flinch_cascade() -> Dictionary:
	var f: Array = await make_match({"p1_controller": "dummy", "p2_controller": "dummy"})
	var a: Fighter = f[0]
	a.global_position = Vector3(-0.6, 0, 0)
	f[1].global_position = Vector3(0.6, 0, 0)
	for x in f:
		x.external_input = FighterInput.new()
	await steps(90)
	a.flinch(f[1], {"dir": "L"}, 1.0, "head")
	var hp := [0.0, 0.0, 0.0]
	var ht := [0.0, 0.0, 0.0]
	var over := 0.0
	var fl: Node = a._hit_flinch
	var first_sign := 0.0
	var gd_max := 0.0
	for i in 90:
		await physics_frame
		var t := float(i + 1) / 120.0
		var mags := [absf(fl.head.y), absf(fl.torso.y), fl.hip.length() * 4.0]
		for k in 3:
			if mags[k] > hp[k]:
				hp[k] = mags[k]
				ht[k] = t
		if first_sign == 0.0 and absf(fl.head.y) > 0.01:
			first_sign = signf(fl.head.y)
		if first_sign != 0.0 and signf(fl.head.y) == -first_sign and t > ht[0]:
			over = maxf(over, absf(fl.head.y))
		gd_max = maxf(gd_max, fl.guard_drop.length())
	return {"head_t": ht[0], "torso_t": ht[1], "hip_t": ht[2], "head_peak": hp[0], "overshoot_deg": rad_to_deg(over), "drop": gd_max}


func _initialize() -> void:
	var off: Dictionary = await fight_sample(false)
	var on: Dictionary = await fight_sample(true)
	for tag in ["off", "on"]:
		var d: Dictionary = off if tag == "off" else on
		print("  inertia %-3s: frames %d, punches %d, max step %.3f rad/frame, max d(omega) %.1f rad/s, mean d(omega) %.3f, jumps(>%.2f rad) %d, accel spikes(>%.0f) %d" % [
			tag, d["n"], d["punches"], d["max_step"], d["max_acc"], d["acc_sum"] / maxf(d["n"], 1), JUMP_STEP, d["jumps"], ACC_STEP, d["acc_hi"]])
	if OS.get_environment("KN_VERBOSE") != "":
		for l in on["log"]:
			print("     jump: ", l)
	check(on["n"] > 10000 and on["punches"] >= 3, "fight sample is a real fight (%d frames, %d punches)" % [on["n"], on["punches"]])
	# the two fights diverge (the layer changes poses, so hits and exchanges differ): compare per punch thrown
	var po: float = maxf(off["punches"], 1.0)
	var pn: float = maxf(on["punches"], 1.0)
	print("  (reported: biggest one-frame bone step %.2f rad on [%s], %.2f off)" % [on["max_step"], on["max_who"], off["max_step"]])
	check(float(on["jumps"]) / pn <= float(off["jumps"]) / po * 1.3 + 0.05, "pose jumps (>%.2f rad, sudden) per punch: %.2f with inertialization (off %.2f)" % [JUMP_STEP, float(on["jumps"]) / pn, float(off["jumps"]) / po])
	check(float(on["acc_hi"]) / pn <= float(off["acc_hi"]) / po * 1.3 + 0.05, "accel spikes per punch %.2f (off %.2f)" % [float(on["acc_hi"]) / pn, float(off["acc_hi"]) / po])

	var t_off := await jab_peak_tick(false)
	var t_on := await jab_peak_tick(true)
	print("  jab reach peak tick: off %d  on %d (%.0f ms apart)" % [t_off, t_on, absf(t_on - t_off) * 1000.0 / 120.0])
	check(t_off > 0 and absi(t_on - t_off) <= 2, "punch arrival unchanged within 20 ms")

	var c: Dictionary = await flinch_cascade()
	print("  flinch cascade: head %.3f s, torso %.3f s, hips %.3f s; head overshoot %.1f deg; guard drop %.2f" % [c["head_t"], c["torso_t"], c["hip_t"], c["overshoot_deg"], c["drop"]])
	var dt_t: float = c["torso_t"] - c["head_t"]
	var dt_h: float = c["hip_t"] - c["head_t"]
	check(c["head_t"] <= 0.11, "head peaks first (%.3f s)" % c["head_t"])
	check(dt_t >= 0.04 and dt_t <= 0.09, "shoulders / trunk follow the head by 0.04-0.09 s (%.3f)" % dt_t)
	check(dt_h >= 0.08 and dt_h <= 0.16, "hips follow the head by 0.08-0.16 s (%.3f)" % dt_h)
	check(c["overshoot_deg"] <= 1.5, "head comes home on a critically damped spring: no overshoot past rest (%.1f deg, was 2-9 with the old zeta 0.5: floaty)" % c["overshoot_deg"])

	await aim_check()
	await clinch_check()

	print("PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)


## Aimed punches really go at the head: at normal range the glove gets within the head capsule's reach (not under the chin).
func aim_check() -> void:
	for tag in ["LJab", "RJab", "RHook", "LHook"]:
		var f: Array = await make_match({"p1_controller": "dummy", "p2_controller": "dummy"})
		var a: Fighter = f[0]
		a.global_position = Vector3(-0.425, 0, 0)
		f[1].global_position = Vector3(0.425, 0, 0)
		for x in f:
			x.external_input = FighterInput.new()
			x.stats.infinite_stamina = true
		await steps(120)
		var sk: Skeleton3D = a.rig.skeleton
		var hand := sk.find_bone("lHand" if tag.begins_with("L") else "rHand")
		var fsk: Skeleton3D = f[1].rig.skeleton
		var head := fsk.find_bone("head")
		var best := 9.0
		var best_dy := 0.0
		a.external_input.strikes.append(tag)
		await steps(1)
		a.external_input.strikes.clear()
		for t in 80:
			await physics_frame
			var hp: Vector3 = sk.global_transform * sk.get_bone_global_pose(hand).origin
			var hd: Vector3 = fsk.global_transform * fsk.get_bone_global_pose(head).origin
			if hp.distance_to(hd) < best:
				best = hp.distance_to(hd)
				best_dy = hp.y - hd.y
		print("  aim %s: closest glove-to-head distance %.3f m (dy %.3f)" % [tag, best, best_dy])
		check(best < 0.2, "%s at 0.85 m reaches the head (%.2f m)" % [tag, best])


func _hull_gap(p: Vector3, foe: Fighter) -> float:
	var worst := 9.0
	for hu in foe.rig.hurtboxes:
		if hu.is_guard or hu.shape_node == null or not (hu.zone == "head" or hu.zone == "body"):
			continue
		worst = minf(worst, hu.sdf(p))
	return worst


## Clinch: pushing into each other, the gloves stay out of the foe's chest / head volumes (centre of the glove >= 3 cm outside).
func clinch_check() -> void:
	var f: Array = await make_match({"p1_controller": "dummy", "p2_controller": "dummy"})
	for x in f:
		x.external_input = FighterInput.new()
		x.stats.infinite_stamina = true
	f[0].global_position = Vector3(-0.21, 0, 0)
	f[1].global_position = Vector3(0.21, 0, 0)
	var worst := 9.0
	for i in 480:
		f[0].external_input.move = Vector2(1, 0)
		f[1].external_input.move = Vector2(-1, 0)
		f[0].external_input.block = true
		f[1].external_input.block = true
		await physics_frame
		if i < 60:
			continue
		for k in 2:
			var a: Fighter = f[k]
			var sk: Skeleton3D = a.rig.skeleton
			for hn in ["lHand", "rHand"]:
				var hp: Vector3 = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(hn)).origin
				var gg := _hull_gap(hp, f[1 - k])
				if gg < 0.03 and OS.get_environment("KN_VERBOSE") != "":
					var cp = a.rig.skeleton.get_node("ContactPose")
					print("     close: P", k, " ", hn, " gap ", gg, " st ", a.state_name, " gfix ", cp._gfix.keys(), " w ", cp._gfix_w, " frame ", cp._frame, " tight ", cp._tight)
				worst = minf(worst, gg)
	print("  clinch: closest glove centre to the foe's torso / head hulls %.3f m (gap %.2f m)" % [worst, f[0].gap_to_foe()])
	check(worst > 0.0, "gloves stay outside the foe's hulls in a clinch (%.3f m)" % worst)
