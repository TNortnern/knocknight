extends SceneTree
## Headless: how a landed punch LOOKS, in numbers, for comparing against the tempo / feel reference (Tale of the Tape teaser).
## One scripted throw per case into an idle foe at a given root gap; per case it prints
##   gap    root gap when the blow registered (m)
##   ext    arm extension at contact: shoulder-glove distance / its max in the same punch thrown at the air
##   stick  s the glove stays within 5 cm of the foe's skin / gloves after contact
##   head / torso   peak HitFlinch head / trunk angle (deg) and when it peaks;  hip  peak flinch weight shift (cm)
##   back   foe root pushed back (cm);  clip  the foe played a reaction clip (HIT state)
##   <godot> --headless --fixed-fps 120 --path . --script res://tools/measure_punch_feel.gd -- gap=1.15 tags=LJab,RJab,LHook,RHook,LBodyJab,RUppercut
func _initialize() -> void:
	_run.call_deferred()


var _cur := {}
var main
var a: Fighter
var d: Fighter
var _block := false


func _run() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var i: int = arg.find("=")
		if i > 0:
			args[arg.substr(0, i)] = arg.substr(i + 1)
	var gap := float(args.get("gap", "1.15"))
	var tags: PackedStringArray = String(args.get("tags", "LJab,RJab,LHook,RHook,LBodyJab,RUppercut")).split(",")
	var hint: String = args.get("hint", "@aim")
	_block = args.get("block", "0") == "1"
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "intro_delay": 0.0,
		"p1_model": args.get("att", "meshy_viper"), "p2_model": args.get("foe", "meshy_oak"), "rules": "boxing", "rounds": 1,
		"round_seconds": 600.0, "arena": "ring"})
	await process_frame
	var f: Array = main.current_match.get_fighters()
	a = f[0]
	d = f[1]
	for fi in f:
		fi.stats.infinite_stamina = true
	var ska: Skeleton3D = a.rig.skeleton
	ska.skeleton_updated.connect(func():
		var g := ska.global_transform
		for b in ["lShldrBend", "rShldrBend", "lHand", "rHand"]:
			_cur[b] = g * ska.get_bone_global_pose(ska.find_bone(b)).origin)
	var bl := func(b: String) -> float:
		return (ska.get_bone_global_rest(ska.find_bone(b)).origin - ska.get_bone_global_rest(ska.get_bone_parent(ska.find_bone(b))).origin).length()
	print("arm bones: upper %.3f fore %.3f (+twist) -> straight shoulder-hand %.3f" % [bl.call("lForearmBend") + bl.call("lForearmTwist") * 0.0, bl.call("lHand"),
		(ska.get_bone_global_rest(ska.find_bone("lHand")).origin - ska.get_bone_global_rest(ska.find_bone("lShldrBend")).origin).length()])
	print("tag            gap   ext   stick  head_deg@t  torso_deg  hip_cm  back_cm  yaw_deg  clip  outcome")
	for tag in tags:
		var free: Dictionary = await _throw(tag + hint, 3.0)
		var m: Dictionary = await _throw(tag + hint, gap)
		print("  free throw: arm max %.3f m, glove reach in front of the root %.3f m" % [free["arm_max"], free["reach"]])
		print("%-13s %5.2f %5.2f %s %5.1f@%.2f %9.1f %7.1f %8.1f %8.0f  %-5s %s" % [tag, m["gap_hit"], m["arm_hit"] / maxf(free["arm_max"], 0.001),
			"%.3f/%.3f" % [m["stick_skin"], m["stick"]], m["head"], m["head_t"], m["torso"], m["hip"], m["back"], m["yaw"], "yes" if m["clip"] else "no", m["outcome"]])
	quit(0)


func _throw(tag: String, gap: float) -> Dictionary:
	a.global_position = Vector3(-gap * 0.5, 0, 0)
	d.global_position = Vector3(gap * 0.5, 0, 0)
	a.external_input = FighterInput.new()
	d.external_input = FighterInput.new()
	d.external_input.block = _block
	for k in 200:
		await physics_frame
	var hit := {"tick": -1, "zone": "", "blocked": false}
	var ticks := [0]
	var cb := func(_att, inf):
		if hit["tick"] < 0:
			hit["tick"] = ticks[0]
			hit["zone"] = inf.get("zone", "")
			hit["blocked"] = inf.get("blocked", false)
	a.hit_landed.connect(cb)
	d.hit_landed.connect(cb)
	var limb := "lHand" if tag.begins_with("L") else "rHand"
	var sh := limb.substr(0, 1) + "ShldrBend"
	var root0 := d.global_position
	var push_dir := (d.global_position - a.global_position).normalized()
	var inp := FighterInput.new()
	inp.strikes.append(tag)
	a.external_input = inp
	await physics_frame
	await physics_frame
	inp.strikes.clear()
	var m := {"arm_max": 0.0, "arm_hit": 0.0, "gap_hit": 0.0, "stick": -1.0, "head": 0.0, "head_t": 0.0, "torso": 0.0, "hip": 0.0,
		"back": 0.0, "yaw": 0.0, "clip": false, "stick_skin": -1.0, "reach": 0.0}
	var yaw_min := 999.0
	var yaw_max := -999.0
	var hf = d._hit_flinch
	for k in 160:
		await physics_frame
		await process_frame
		ticks[0] += 1
		if not _cur.has(limb):
			continue
		var arm: float = (_cur[limb] - _cur[sh]).length()
		if a.state == a.State.ATTACK:
			m["arm_max"] = maxf(m["arm_max"], arm)
			m["reach"] = maxf(m["reach"], (_cur[limb] - a.global_position).dot(a.global_basis.z))
			var shl: Vector3 = _cur["lShldrBend"] - _cur["rShldrBend"]
			var yaw := rad_to_deg(atan2(shl.dot(a.global_basis.z), shl.dot(a.global_basis.x)))
			yaw_min = minf(yaw_min, yaw)
			yaw_max = maxf(yaw_max, yaw)
		if d.state == d.State.HIT:
			m["clip"] = true
		if hit["tick"] < 0:
			continue
		var since: float = (ticks[0] - int(hit["tick"])) / 120.0
		if m["arm_hit"] == 0.0:
			m["arm_hit"] = arm
			m["gap_hit"] = a.gap_to_foe()
		if hf != null:
			var hd := rad_to_deg((hf.head as Vector3).length())
			if hd > m["head"]:
				m["head"] = hd
				m["head_t"] = since
			m["torso"] = maxf(m["torso"], rad_to_deg((hf.torso as Vector3).length()))
			m["hip"] = maxf(m["hip"], (hf.hip as Vector3).length() * 100.0)
		m["back"] = maxf(m["back"], (d.global_position - root0).dot(push_dir) * 100.0)
		if m["stick"] < 0.0:
			var gl: Vector3 = (a.rig.hitbox_for(limb)[0] as HitAreas.Hitbox).shapes[0]["node"].global_position
			var near := 9.0
			for hu: HitAreas.Hurtbox in d.rig.hurtboxes:
				if hu.zone == "head" or hu.zone == "body":
					near = minf(near, hu.sdf(gl))
			if near > 0.12 and m["stick_skin"] < 0.0:
				m["stick_skin"] = since
			for hu: HitAreas.Hurtbox in d.rig.guards:
				near = minf(near, hu.sdf(gl))
			if near > 0.12:   # sphere radius ~0.07 + 5 cm clear of the skin / gloves
				m["stick"] = since
		if since > 0.6 and a.state != a.State.ATTACK and m["stick"] >= 0.0:
			break
	a.hit_landed.disconnect(cb)
	d.hit_landed.disconnect(cb)
	m["yaw"] = yaw_max - yaw_min
	m["outcome"] = "miss" if hit["tick"] < 0 else ("%s%s" % [hit["zone"], " blocked" if hit["blocked"] else ""])
	return m
