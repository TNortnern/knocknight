extends SceneTree
## Plays the defence moves the way the owner does: a real match (p1 human vs a dummy), the live FightCamera, and the real InputMap
## actions (Input.action_press) so HumanController / Fighter run their normal path. Captures 30 fps crops of the player and measures
## the visible (Meshy) body every physics tick.
##
##   godot --path . --fixed-fps 120 --script res://tools/capture_defence_play.gd -- model=meshy_viper clip=hold_q out=C:/abs/dir [fps=30] [frames=1]
##
## clips: idle hold_q hold_e switch_qe switch_qeq switch_overlap tap_q tap_e tap_qe duck duck_q duck_e duck_switch slip_duck back
## Writes <out>/<model>/<clip>/f_###.png (cropped, 30 fps) and <out>/<model>/<clip>/trace.json (every physics tick).

const BodyVolumes := preload("res://scripts/fighter/body_volumes.gd")
const MAIN_SCENE := "res://scenes/main.tscn"
const CaptureMainScript := preload("res://tools/capture_fn_main.gd")
const TICK := 120.0
const SETTLE_TICKS := 330

## clip -> {len, ev: [[t, action, pressed]]}
const CLIPS := {
	"idle": {"len": 1.5, "ev": []},
	"hold_q": {"len": 2.4, "ev": [[0.4, "p1_slip_left", true], [1.4, "p1_slip_left", false]]},
	"hold_e": {"len": 2.4, "ev": [[0.4, "p1_slip_right", true], [1.4, "p1_slip_right", false]]},
	"switch_qe": {"len": 2.6, "ev": [[0.4, "p1_slip_left", true], [1.2, "p1_slip_left", false], [1.2, "p1_slip_right", true], [2.0, "p1_slip_right", false]]},
	"switch_qeq": {"len": 3.4, "ev": [[0.4, "p1_slip_left", true], [1.1, "p1_slip_left", false], [1.1, "p1_slip_right", true],
			[1.8, "p1_slip_right", false], [1.8, "p1_slip_left", true], [2.5, "p1_slip_left", false]]},
	"switch_overlap": {"len": 2.6, "ev": [[0.4, "p1_slip_left", true], [1.2, "p1_slip_right", true], [1.25, "p1_slip_left", false], [2.0, "p1_slip_right", false]]},
	"tap_q": {"len": 1.6, "ev": [[0.4, "p1_slip_left", true], [0.52, "p1_slip_left", false]]},
	"tap_e": {"len": 1.6, "ev": [[0.4, "p1_slip_right", true], [0.52, "p1_slip_right", false]]},
	"tap_qe": {"len": 2.0, "ev": [[0.4, "p1_slip_left", true], [0.52, "p1_slip_left", false], [0.7, "p1_slip_right", true], [0.82, "p1_slip_right", false]]},
	"duck": {"len": 2.4, "ev": [[0.4, "p1_duck", true], [1.4, "p1_duck", false]]},
	"duck_q": {"len": 3.0, "ev": [[0.3, "p1_duck", true], [0.9, "p1_slip_left", true], [1.5, "p1_slip_left", false], [1.9, "p1_duck", false]]},
	"duck_e": {"len": 3.0, "ev": [[0.3, "p1_duck", true], [0.9, "p1_slip_right", true], [1.5, "p1_slip_right", false], [1.9, "p1_duck", false]]},
	"duck_switch": {"len": 3.4, "ev": [[0.3, "p1_duck", true], [0.9, "p1_slip_left", true], [1.4, "p1_slip_left", false], [1.4, "p1_slip_right", true],
			[1.9, "p1_slip_right", false], [2.3, "p1_duck", false]]},
	"slip_duck": {"len": 3.0, "ev": [[0.3, "p1_slip_left", true], [0.9, "p1_duck", true], [1.5, "p1_duck", false], [1.5, "p1_slip_left", false]]},
	"back": {"len": 2.4, "ev": [[0.4, "p1_lean_back", true], [1.4, "p1_lean_back", false]]},
}

var model := "meshy_viper"
var clip := "hold_q"
var out_dir := ""
var fps := 30
var save_frames := true
var view := "game"      ## game (live FightCamera) | front (fixed camera in front of the fighter, foe hidden) | side
var _view_cam: Camera3D
var main: Node
var fighter: Node3D
var foe: Node3D
var cam: Camera3D
var skin: Node
var driver: Skeleton3D
var rows: Dictionary = {}     ## tick -> record
var tick := -1
var running := false
var _events: Array = []
var _hold := {}
var _vol_model := ""
var _mesh_probe
var _rest := {}


class Probe extends RefCounted:
	## Skins a band of the Meshy mesh (head, neck, upper trunk) on the CPU to measure the VISIBLE neck.
	var sk: Skeleton3D
	var verts: Array = []     ## {v: Vector3 (mesh space), bones: PackedInt32Array(skeleton bone idx), w: PackedFloat32Array, bind: Array[Transform3D]}
	var landmarks := {}
	var rest_set := false

	func collect(skel: Skeleton3D, root: Node, cut_y: float, fighter: Node3D) -> void:
		sk = skel
		for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh == null:
				continue
			var skin_res: Skin = mi.skin
			if skin_res == null:
				continue
			var map := PackedInt32Array()
			for i in skin_res.get_bind_count():
				var nm := skin_res.get_bind_name(i)
				map.append(skel.find_bone(nm) if nm != "" else skin_res.get_bind_bone(i))
			for s in mi.mesh.get_surface_count():
				var arr := mi.mesh.surface_get_arrays(s)
				var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var bs = arr[Mesh.ARRAY_BONES]
				var ws = arr[Mesh.ARRAY_WEIGHTS]
				if bs == null or ws == null or vs.is_empty():
					continue
				var per := int(bs.size() / vs.size())
				for k in vs.size():
					# cheap prefilter by rest pose: skeleton-space rest position via the first influence
					var p := Vector3.ZERO
					var wsum := 0.0
					for j in per:
						var wj: float = ws[k * per + j]
						if wj <= 0.0:
							continue
						var bi := int(bs[k * per + j])
						var b: int = map[bi]
						p += wj * (skel.get_bone_global_rest(b) * skin_res.get_bind_pose(bi) * vs[k])
						wsum += wj
					if wsum <= 0.0:
						continue
					p /= wsum
					var pw := skel.global_transform * p
					var y := fighter.to_local(pw).y
					if y < cut_y:
						continue
					var rec := {"v": vs[k], "n": []}
					var bones := PackedInt32Array()
					var wts := PackedFloat32Array()
					var binds: Array = []
					for j in per:
						if float(ws[k * per + j]) > 0.0:
							var bi2 := int(bs[k * per + j])
							bones.append(map[bi2])
							wts.append(ws[k * per + j])
							binds.append(skin_res.get_bind_pose(bi2))
					rec["b"] = bones
					rec["w"] = wts
					rec["bind"] = binds
					verts.append(rec)

	func skinned(i: int) -> Vector3:
		var r: Dictionary = verts[i]
		var out := Vector3.ZERO
		var b: PackedInt32Array = r["b"]
		var w: PackedFloat32Array = r["w"]
		for j in b.size():
			out += w[j] * (sk.get_bone_global_pose(b[j]) * (r["bind"][j] as Transform3D) * (r["v"] as Vector3))
		return out

	func all_local(fighter: Node3D) -> PackedVector3Array:
		var out := PackedVector3Array()
		out.resize(verts.size())
		var xf := fighter.global_transform.affine_inverse() * sk.global_transform
		for i in verts.size():
			out[i] = xf * skinned(i)
		return out


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var at := arg.find("=")
		if at < 0:
			continue
		var k := arg.substr(0, at).to_lower()
		var v := arg.substr(at + 1)
		match k:
			"model": model = v
			"clip": clip = v
			"out": out_dir = v
			"fps": fps = maxi(1, int(v))
			"frames": save_frames = v != "0"
			"view": view = v
	if not CLIPS.has(clip):
		push_error("unknown clip " + clip)
		quit(2)
		return
	Engine.physics_ticks_per_second = int(TICK)
	Engine.physics_jitter_fix = 0.0
	Engine.max_physics_steps_per_frame = 1
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path("res://_build/def/scratch")
	var dir := out_dir.path_join(model).path_join(clip + ("" if view == "game" else "_" + view))
	DirAccess.make_dir_recursive_absolute(dir)
	main = load(MAIN_SCENE).instantiate()
	main.set_script(CaptureMainScript)
	root.add_child(main)
	await process_frame
	var foe_model := "meshy_anvil" if model != "meshy_anvil" else "meshy_viper"
	main.start_match({"mode": "exhibition", "p1_controller": "human", "p2_controller": "dummy", "p1_model": model, "p2_model": foe_model,
		"rules": "boxing", "rounds": 1, "round_seconds": 300.0, "arena": "ring", "intro_delay": 0.0})
	for i in SETTLE_TICKS:
		await physics_frame
	var m: Node = main.find_children("*", "Match", true, false)[0]
	var fs: Array = m.get_fighters()
	fighter = fs[0]
	foe = fs[1]
	skin = fighter.meshy_skin
	driver = skin.driver
	cam = main.get("current_camera") as Camera3D
	cam.make_current()
	if view != "game":
		_view_cam = Camera3D.new()
		root.add_child(_view_cam)
		var fwd: Vector3 = fighter.global_basis.z
		var left: Vector3 = fighter.global_basis.x
		var centre: Vector3 = fighter.global_position + Vector3(0, 1.05, 0)
		var eye: Vector3 = centre + (fwd * 2.7 if view == "front" else left * 2.7) + Vector3(0, 0.15, 0)
		_view_cam.fov = 38.0
		_view_cam.global_position = eye
		_view_cam.look_at(centre, Vector3.UP)
		_view_cam.make_current()
		cam = _view_cam
		foe.visible = false
	main.get("ui").visible = false
	_vol_model = String(fighter.model)
	for a in ["p1_slip_left", "p1_slip_right", "p1_duck", "p1_lean_back"]:
		Input.action_release(a)
	for i in 120:
		await physics_frame
	# rest probe (idle guard) for the neck landmarks
	var hip_y := fighter.to_local(fighter.global_position).y
	_mesh_probe = Probe.new()
	_mesh_probe.collect(skin.skeleton, skin.root, 1.05, fighter)
	driver.skeleton_updated.connect(_on_skeleton_updated)
	var spec: Dictionary = CLIPS[clip]
	_events = (spec["ev"] as Array).duplicate(true)
	var total_ticks := int(round(float(spec["len"]) * TICK))
	var step := int(round(TICK / float(fps)))
	var frame_i := 0
	var t0 := Engine.get_physics_frames()
	running = true
	var crop := Rect2i()
	while true:
		await physics_frame
		tick = Engine.get_physics_frames() - t0
		_apply_events(tick)
		if tick > total_ticks:
			break
		if view != "game":
			cam.make_current()
		await RenderingServer.frame_post_draw
		if tick % step == 0:
			if save_frames:
				var img := root.get_viewport().get_texture().get_image()
				if crop.size == Vector2i.ZERO:
					crop = _crop_rect(img.get_size())
				img.get_region(crop).save_png("%s/f_%03d.png" % [dir, frame_i])
			_sample_neck(tick)
			frame_i += 1
	running = false
	for a in ["p1_slip_left", "p1_slip_right", "p1_duck", "p1_lean_back"]:
		Input.action_release(a)
	var f := FileAccess.open(dir.path_join("trace.json"), FileAccess.WRITE)
	var arr: Array = []
	var keys: Array = rows.keys()
	keys.sort()
	for k in keys:
		arr.append(rows[k])
	f.store_string(JSON.stringify({"model": model, "clip": clip, "tick_rate": TICK, "events": spec["ev"], "rows": arr, "neck": _neck_rows}))
	f.close()
	print("capture_defence_play: %s %s -> %s (%d ticks, %d frames)" % [model, clip, dir, rows.size(), frame_i])
	quit(0)


func _apply_events(t: int) -> void:
	for e in _events:
		var tt := int(round(float(e[0]) * TICK))
		if tt == t:
			if e[2]:
				Input.action_press(e[1])
			else:
				Input.action_release(e[1])


func _crop_rect(size: Vector2i) -> Rect2i:
	var c := cam.unproject_position(fighter.global_position + Vector3(0, 0.9, 0))
	var feet := cam.unproject_position(fighter.global_position)
	var head := cam.unproject_position(fighter.global_position + Vector3(0, 1.8, 0))
	var h := int(absf(feet.y - head.y) * 1.45)
	var w := int(h * 0.9)
	var cx := int(c.x)
	var cy := int(c.y)
	var r := Rect2i(cx - w / 2, cy - int(h * 0.52), w, h)
	r.position.x = clampi(r.position.x, 0, maxi(size.x - r.size.x, 0))
	r.position.y = clampi(r.position.y, 0, maxi(size.y - r.size.y, 0))
	r.size.x = mini(r.size.x, size.x)
	r.size.y = mini(r.size.y, size.y)
	return r


func _jw(joint: String) -> Vector3:
	return fighter.to_local(skin.joint_world(joint))


func _dw(bone: String) -> Vector3:
	return fighter.to_local(driver.global_transform * driver.get_bone_global_pose(driver.find_bone(bone)).origin)


func _on_skeleton_updated() -> void:
	if not running or tick < 0:
		return
	var r := {"t": tick, "st": String(fighter.state_name)}
	var head := _jw("Head")
	var neck := _jw("neck")
	var sh_l := _jw("LeftArm")
	var sh_r := _jw("RightArm")
	var hips := _jw("Hips")
	r["head"] = [head.x, head.y, head.z]
	r["neck"] = [neck.x, neck.y, neck.z]
	r["hips"] = [hips.x, hips.y, hips.z]
	r["shm"] = [(sh_l.x + sh_r.x) * 0.5, (sh_l.y + sh_r.y) * 0.5, (sh_l.z + sh_r.z) * 0.5]
	r["neck_len"] = head.distance_to((sh_l + sh_r) * 0.5)
	r["pin"] = [skin.pin_shift.get("neck", 0.0), skin.pin_shift.get("LeftArm", 0.0), skin.pin_shift.get("RightArm", 0.0)]
	r["pos"] = [fighter.lean_pose.pos.x, fighter.lean_pose.pos.y]
	r["tgt"] = [fighter.lean_target.x, fighter.lean_target.y]
	r["duck_w"] = fighter.lean_pose.duck_w
	var sm := Vector3((sh_l.x + sh_r.x) * 0.5, (sh_l.y + sh_r.y) * 0.5, (sh_l.z + sh_r.z) * 0.5)
	r["trunk_roll"] = rad_to_deg(atan2(sm.x - hips.x, sm.y - hips.y))      # + = leaning to the fighter's left
	r["trunk_pitch"] = rad_to_deg(atan2(sm.z - hips.z, sm.y - hips.y))     # + = leaning towards the foe
	r["neck_flex"] = rad_to_deg(atan2(head.z - neck.z, head.y - neck.y) - atan2(sm.z - hips.z, sm.y - hips.y))   # neck pitch minus trunk pitch (+ = head tipped towards the foe relative to the trunk)
	r["head_roll"] = rad_to_deg(atan2(head.x - neck.x, head.y - neck.y))
	r["shoulder_tilt"] = rad_to_deg(atan2(sh_l.y - sh_r.y, sh_l.x - sh_r.x))
	# legs: the knee's offset from the hip-ankle line on the ground plane, against the foot's forward direction
	for s in ["Left", "Right"]:
		var up := _jw(s + "UpLeg")
		var kn := _jw(s + "Leg")
		var an := _jw(s + "Foot")
		var toe := _jw(s + "ToeBase")
		var thigh := kn - up
		var shin := an - kn
		var ang := rad_to_deg((-thigh).angle_to(shin)) if thigh.length() > 1e-4 and shin.length() > 1e-4 else 0.0
		var line := an - up
		var tl := line.length()
		var off := Vector3.ZERO
		if tl > 1e-4:
			var t := clampf((kn - up).dot(line) / (tl * tl), 0.0, 1.0)
			off = kn - (up + line * t)
		var ft := Vector3(toe.x - an.x, 0.0, toe.z - an.z)
		var kd := Vector3(off.x, 0.0, off.z)
		var yaw := 0.0
		var fwd_cm := 0.0
		if ft.length() > 1e-4:
			fwd_cm = 100.0 * kd.dot(ft.normalized())
			if kd.length() > 0.02:
				yaw = rad_to_deg(absf(ft.signed_angle_to(kd, Vector3.UP)))
		r["knee_" + s] = ang
		r["kneeyaw_" + s] = yaw          # deg between the knee-bend direction and the toe direction (0 = over the toes), 0 when the leg is nearly straight
		r["kneefwd_" + s] = fwd_cm       # cm the knee sits in front of the hip-ankle line along the toe direction (negative = bends backwards)
		r["kneeoff_" + s] = 100.0 * kd.length()
		var fw: Vector3 = skin.joint_world(s + "Foot")
		r["foot_" + s] = [fw.x, fw.y, fw.z]   # WORLD
		r["shin_len_" + s] = shin.length()
		r["thigh_len_" + s] = thigh.length()
		r["kneex_" + s] = kn.x
	# arms vs own body volumes (driver hulls, skeleton space)
	var vols: Dictionary = BodyVolumes.build(driver, _vol_model)
	for side in ["l", "r"]:
		var p: Dictionary = BodyVolumes.arm_penetration(vols, side)
		r["pen_" + side] = p
	# visible pin shift of the neck joint from its rest offset (skeleton units)
	var dfl: Vector3 = driver.global_transform * driver.get_bone_global_pose(driver.find_bone("lFoot")).origin
	var dfr: Vector3 = driver.global_transform * driver.get_bone_global_pose(driver.find_bone("rFoot")).origin
	var dhip: Vector3 = driver.global_transform * driver.get_bone_global_pose(driver.find_bone("hip")).origin
	r["dfoot"] = [dfl.x, dfl.y, dfl.z, dfr.x, dfr.y, dfr.z]
	r["dhip"] = [dhip.x, dhip.y, dhip.z]
	var pl = fighter._pose_limiter
	r["pl"] = [pl.hip_raised, 1.0 if pl.knee_lifted else 0.0, pl.trunk_cut, fighter.lean_pose._hs, fighter.lean_pose._hl.x]
	var ii = fighter.inertia_post
	var top := ""
	var best := 0.0
	for bn in ii.dbg_in:
		if ii.dbg_in[bn] > best:
			best = ii.dbg_in[bn]
			top = str(driver.get_bone_name(bn)) if bn is int else str(bn)
	r["inert"] = [ii.max_off, ii.jumps, best, top, ii.trig_window]
	var ac = driver.get_node_or_null("ArmClear")
	if ac != null:
		r["ac"] = [ac.pushed, ac.residual]
	rows[tick] = r


var _neck_rows: Array = []


func _sample_neck(t: int) -> void:
	if _mesh_probe == null or _mesh_probe.verts.is_empty():
		return
	var pts: PackedVector3Array = _mesh_probe.all_local(fighter)
	if _rest.is_empty() and clip != "idle" or _rest.is_empty():
		_rest = _landmarks(pts, null)
	var d := _landmarks(pts, _rest)
	d["t"] = t
	_neck_rows.append(d)


## Landmarks are picked once (first sample = idle guard) and then tracked by vertex id.
func _landmarks(pts: PackedVector3Array, rest) -> Dictionary:
	var out := {}
	if rest == null:
		# chin: lowest front vertex of the head (Head-dominant), notch: front-most x~0 vertex of the upper trunk below the chin,
		# nape: back-most x~0 vertex under the skull
		var head_idx: int = _mesh_probe.sk.find_bone("Head")
		var neck_idx: int = _mesh_probe.sk.find_bone("neck")
		var best_chin := -1
		var chin_y := 9.0
		# head vertices at the sagittal plane
		var hz := 0.0
		var n := 0
		for i in pts.size():
			if _dominant(_mesh_probe.verts[i]) == head_idx:
				hz += pts[i].z
				n += 1
		hz = hz / maxf(n, 1)
		for i in pts.size():
			var rec: Dictionary = _mesh_probe.verts[i]
			if _dominant(rec) == head_idx and absf(pts[i].x) < 0.035 and pts[i].z > hz + 0.03 and pts[i].y < chin_y:
				chin_y = pts[i].y
				best_chin = i
		var chin := pts[best_chin]
		# notch: x~0, below chin, spine/neck-dominant, front (z greater than the neck joint), highest y among those within 0.14 m under the chin
		var nj := _jw("neck")
		var best_notch := -1
		var best_ny := -9.0
		var best_nape := -1
		var best_nz := 9.0
		var nape_y := -9.0
		for i in pts.size():
			var dom := _dominant(_mesh_probe.verts[i])
			if dom == head_idx or absf(pts[i].x) > 0.03:
				continue
			if pts[i].y < chin.y - 0.02 and pts[i].y > nj.y - 0.16 and pts[i].z > nj.z + 0.02 and pts[i].y > best_ny:
				best_ny = pts[i].y
				best_notch = i
		# nape: back of the neck, x~0, highest spine-dominant vertex behind the neck joint, with the head's lowest back vertex above it
		for i in pts.size():
			var dom := _dominant(_mesh_probe.verts[i])
			if dom == head_idx or absf(pts[i].x) > 0.03:
				continue
			if pts[i].z < nj.z - 0.02 and pts[i].y > nj.y - 0.1 and pts[i].y < chin.y + 0.05 and pts[i].y > nape_y:
				nape_y = pts[i].y
				best_nape = i
		var occ := -1
		var occ_y := 9.0
		for i in pts.size():
			var rec2: Dictionary = _mesh_probe.verts[i]
			if _dominant(rec2) == head_idx and absf(pts[i].x) < 0.035 and pts[i].z < hz - 0.03 and pts[i].y < occ_y:
				occ_y = pts[i].y
				occ = i
		out = {"chin": best_chin, "notch": best_notch, "nape": best_nape, "occ": occ}
		# neck band: vertices with y between the neck joint and the chin that are neck / spine dominant near the axis (width)
		var band: Array = []
		for i in pts.size():
			var dom2 := _dominant(_mesh_probe.verts[i])
			if dom2 == neck_idx or (dom2 != head_idx and pts[i].y > nj.y - 0.02 and pts[i].y < chin.y + 0.03 and absf(pts[i].x) < 0.14):
				band.append(i)
		out["band"] = band
		out["front_len"] = pts[best_chin].distance_to(pts[best_notch]) if best_notch >= 0 else 0.0
		out["back_len"] = pts[occ].distance_to(pts[best_nape]) if (occ >= 0 and best_nape >= 0) else 0.0
		return out
	var res := {}
	var ci: int = rest["chin"]
	var ni: int = rest["notch"]
	var pi: int = rest["nape"]
	var oi: int = rest["occ"]
	res["front_len"] = pts[ci].distance_to(pts[ni]) if ni >= 0 else 0.0
	res["back_len"] = pts[oi].distance_to(pts[pi]) if (oi >= 0 and pi >= 0) else 0.0
	res["front_rest"] = rest["front_len"]
	res["back_rest"] = rest["back_len"]
	# neck band width (lateral x extent) and depth (z extent), measured perpendicular to the head-trunk axis
	var minx := 9.0
	var maxx := -9.0
	var minz := 9.0
	var maxz := -9.0
	var axis := (_jw("Head") - _jw("neck")).normalized()
	var lat := Vector3.RIGHT
	lat = (lat - axis * lat.dot(axis)).normalized()
	var dep := axis.cross(lat).normalized()
	for i in rest["band"]:
		var p: Vector3 = pts[i]
		var a := p.dot(lat)
		var b := p.dot(dep)
		minx = minf(minx, a)
		maxx = maxf(maxx, a)
		minz = minf(minz, b)
		maxz = maxf(maxz, b)
	res["band_w"] = maxx - minx
	res["band_d"] = maxz - minz
	res["chin"] = [pts[ci].x, pts[ci].y, pts[ci].z]
	if ni >= 0:
		res["notch"] = [pts[ni].x, pts[ni].y, pts[ni].z]
	return res


func _dominant(rec: Dictionary) -> int:
	var b: PackedInt32Array = rec["b"]
	var w: PackedFloat32Array = rec["w"]
	var best := -1
	var bw := 0.0
	for j in b.size():
		if w[j] > bw:
			bw = w[j]
			best = b[j]
	return best
