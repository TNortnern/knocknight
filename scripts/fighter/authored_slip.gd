extends "res://scripts/fighter/pose_layer_base.gd"
## Blender-authored left and right slips, blended by one modifier on the combat skeleton.
## Each side falls back to the existing procedural lean if its asset is incompatible.
const LEFT_GLB_PATH = "res://assets/animations/fightnight-slip-left.glb"
const RIGHT_GLB_PATH = "res://assets/animations/fightnight-slip-right.glb"
## The lateral slip shape is now procedural (lean_pose.gd: spine side-bend, loose neck, hip shift). The Blender-authored left/right
## poses hunch forward, so they are no longer written to the skeleton; the weights are still tracked for the counter-turn latch.
const APPLY_AUTHORED_POSE = false
const FADE_IN_SECONDS = 0.20
const FADE_OUT_SECONDS = 0.12
const COUNTER_TORSO_OUT_SECONDS = 0.12
const TORSO_BONES = ["abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "neckLower", "neckUpper", "head"]
const REQUIRED_ROTATIONS = ["hip", "abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "neckLower", "head", "lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend", "lHand", "rHand", "lThighBend", "rThighBend", "lShin", "rShin", "lFoot", "rFoot"]

# Left-facing compatibility fields used by existing capture tooling.
var action: Animation
var mappings: Array = []
var ignored_scale_tracks: Array = []
var weight := 0.0
var sample_time := 0.0
var target_weight := 0.0
var torso_weight := 0.0
var mode := "inactive"
var snapshot := {}
var record := false

var _left_side := {}
var _right_side := {}
var _last_selected := 0
var _track_keys: Array = []

# Retain the slip loading once per marked counter, independent of its fade.
var _turn_serial := -1
var _turn_entry := 0.0
const COUNTER_HIP_DEG := -10.0
const COUNTER_SPINE_DEG := -26.0
# The inherited IK helpers assume these indices are all valid.
const TURN_REQUIRED_BONES := ["hip", "abdomenLower", "abdomenUpper", "chestLower", "chestUpper",
	"lThighBend", "lShin", "lFoot", "rThighBend", "rShin", "rFoot"]

static func attach(f):
	if f == null or f.rig == null or f.rig.skeleton == null or f.lean_pose == null:
		push_warning("Bilateral authored slip: fighter must be ready")
		return null
	var sk: Skeleton3D = f.rig.skeleton
	if sk.get_node_or_null("AuthoredSlip") != null:
		push_warning("Bilateral authored slip: AuthoredSlip already attached")
		return null
	# This is the main fighter's replacement entrypoint, not a second opt-in layer.
	var layer = load("res://scripts/fighter/authored_slip.gd").new()
	layer.name = "AuthoredSlip"
	layer.fighter = f
	sk.add_child(layer)
	sk.move_child(layer, f.lean_pose.get_index())
	if not layer._setup():
		sk.remove_child(layer)
		layer.free()
		return null
	return layer

func _new_side(sign_x: float, asset: Dictionary) -> Dictionary:
	return {"sign": sign_x, "asset": asset, "weight": 0.0, "torso": 0.0,
		"target": 0.0, "sample": 0.0, "mode": "inactive", "was_active": false,
		"last_x": 0.0, "last_frame": -1, "lead": 0.0, "reentry": false,
		"torso_fade": FADE_OUT_SECONDS}

func _setup() -> bool:
	var sk: Skeleton3D = get_skeleton()
	if sk == null:
		return false
	var left_asset := _load_asset(sk, LEFT_GLB_PATH)
	var right_asset := _load_asset(sk, RIGHT_GLB_PATH)
	_left_side = _new_side(1.0, left_asset)
	_right_side = _new_side(-1.0, right_asset)
	if left_asset.is_empty() and right_asset.is_empty():
		push_warning("Bilateral authored slip: neither asset usable; retaining procedural lean")
		return false
	if not left_asset.is_empty():
		action = left_asset.action
		mappings = left_asset.mappings
		ignored_scale_tracks = left_asset.ignored_scale_tracks
	var union := {}
	for side in [_left_side, _right_side]:
		var asset: Dictionary = side.asset
		if not asset.is_empty():
			for key in asset.tracks:
				union[key] = true
	_track_keys = union.keys()
	sk.skeleton_updated.connect(_on_final_pose)
	return true

# Fail closed per direction, before any pose or procedural share is modified.
func _load_asset(sk: Skeleton3D, path: String) -> Dictionary:
	if not ResourceLoader.exists(path):
		push_warning("Bilateral authored slip: missing " + path + "; procedural fallback for this direction")
		return {}
	var packed := load(path) as PackedScene
	if packed == null:
		push_warning("Bilateral authored slip: not a scene: " + path)
		return {}
	var instance = packed.instantiate()
	if instance == null:
		push_warning("Bilateral authored slip: cannot instantiate " + path)
		return {}
	var src: Skeleton3D = instance.find_child("Skeleton3D", true, false)
	var sap: AnimationPlayer = instance.find_child("AnimationPlayer", true, false)
	if src == null or sap == null or not sap.has_animation("Animation") or src.get_bone_count() != sk.get_bone_count():
		instance.free()
		push_warning("Bilateral authored slip: incompatible skeleton or missing Animation in " + path)
		return {}
	for i in src.get_bone_count():
		var bone_name := src.get_bone_name(i)
		var j := sk.find_bone(bone_name)
		if j < 0:
			instance.free()
			push_warning("Bilateral authored slip: missing bone " + bone_name + " in " + path)
			return {}
		var sp := src.get_bone_parent(i)
		var tp := sk.get_bone_parent(j)
		var sn := "" if sp < 0 else src.get_bone_name(sp)
		var tn := "" if tp < 0 else sk.get_bone_name(tp)
		var x := src.get_bone_rest(i)
		var y := sk.get_bone_rest(j)
		if sn != tn or x.origin.distance_to(y.origin) > 0.001 or (x.basis.x-y.basis.x).length() > 0.001 or (x.basis.y-y.basis.y).length() > 0.001 or (x.basis.z-y.basis.z).length() > 0.001:
			instance.free()
			push_warning("Bilateral authored slip: rest/parent mismatch " + bone_name + " in " + path)
			return {}
	var clip: Animation = sap.get_animation("Animation").duplicate(true)
	instance.free()
	if clip.length < 0.4:
		push_warning("Bilateral authored slip: clip shorter than sampled entry in " + path)
		return {}
	var tracks := {}
	var out_mappings := []
	var ignored := []
	for i in clip.get_track_count():
		var old := clip.track_get_path(i)
		var bone := String(old.get_subname(0)) if old.get_subname_count() == 1 else ""
		var j := sk.find_bone(bone)
		var kind := clip.track_get_type(i)
		if bone == "" or j < 0 or clip.track_get_key_count(i) == 0:
			push_warning("Bilateral authored slip: invalid or empty track " + String(old) + " in " + path)
			return {}
		if kind == Animation.TYPE_SCALE_3D:
			for k in clip.track_get_key_count(i):
				var v: Vector3 = clip.track_get_key_value(i, k)
				if not v.is_finite() or v.distance_to(Vector3.ONE) > 0.0001:
					push_warning("Bilateral authored slip: non-unit scale " + bone + " in " + path)
					return {}
			ignored.append(bone)
		elif kind == Animation.TYPE_POSITION_3D or kind == Animation.TYPE_ROTATION_3D:
			for k in clip.track_get_key_count(i):
				if kind == Animation.TYPE_POSITION_3D:
					var value: Vector3 = clip.track_get_key_value(i, k)
					if not value.is_finite():
						push_warning("Bilateral authored slip: non-finite position in " + path)
						return {}
				else:
					var rotation: Quaternion = clip.track_get_key_value(i, k)
					if not rotation.is_finite() or rotation.length_squared() < 0.000001:
						push_warning("Bilateral authored slip: invalid rotation in " + path)
						return {}
			var key := bone + ":" + str(kind)
			if tracks.has(key):
				push_warning("Bilateral authored slip: duplicate track " + key + " in " + path)
				return {}
			tracks[key] = {"index": i, "bone": bone, "bone_index": j, "type": kind}
		else:
			push_warning("Bilateral authored slip: unsupported track in " + path)
			return {}
		out_mappings.append({"index": i, "source": String(old), "bone": bone, "type": kind})
	for bone in REQUIRED_ROTATIONS:
		if not tracks.has(bone + ":" + str(Animation.TYPE_ROTATION_3D)):
			push_warning("Bilateral authored slip: missing required rotation " + bone + " in " + path)
			return {}
	if not tracks.has("hip:" + str(Animation.TYPE_POSITION_3D)):
		push_warning("Bilateral authored slip: missing hip position in " + path)
		return {}
	return {"action": clip, "tracks": tracks, "mappings": out_mappings, "ignored_scale_tracks": ignored, "path": path}

func _reset_side(side: Dictionary, pos_x: float) -> void:
	side.weight = 0.0
	side.torso = 0.0
	side.target = 0.0
	side.sample = 0.0
	side.mode = "bypass"
	side.was_active = false
	side.last_x = pos_x
	side.lead = 0.0
	side.reentry = false
	side.last_frame = -1

func _advance_side(side: Dictionary, wanted: Vector2, pos: Vector2, handoff: bool, selected: int, dt: float) -> void:
	var f = fighter
	var sign_x: float = side.sign
	var available: bool = not (side.asset as Dictionary).is_empty()
	var input_held: bool = wanted.x * sign_x > 0.02
	var opposite: bool = wanted.x * sign_x < -0.02
	var neutral_release: bool = side.was_active and wanted.length() < 0.08 and selected == int(sign_x)
	if handoff or opposite or not available:
		side.target = 0.0
		side.mode = "defensive_fade" if not opposite else "reversal_fade"
		side.lead = 0.0
		side.last_x = pos.x
		side.reentry = false
	elif f.state == f.State.SLIP and (input_held or neutral_release):
		if Engine.get_physics_frames() != int(side.last_frame):
			side.lead = minf(maxf((pos.x - float(side.last_x)) * sign_x, 0.0) * 4.0, 0.20) if input_held else 0.0
			side.last_x = pos.x
			side.last_frame = Engine.get_physics_frames()
		var depth := clampf(pos.x * sign_x + float(side.lead), 0.0, 1.0)
		side.target = depth * depth * (3.0 - 2.0 * depth)
		var next_sample: float = 0.4 * float(side.target)
		if side.mode in ["defensive_fade", "attack_fade", "neutral_fade", "reversal_fade"] and float(side.weight) > 0.001:
			side.reentry = true
		if side.reentry:
			side.sample = move_toward(float(side.sample), next_sample, maxf(dt, 0.0) * 2.0)
			if is_equal_approx(float(side.sample), next_sample):
				side.reentry = false
		else:
			side.sample = next_sample
		side.mode = "lean" if input_held else "release"
		side.was_active = side.was_active or float(side.target) > 0.001
	elif f.state == f.State.ATTACK and side.was_active:
		side.target = 0.0
		side.mode = "attack_fade"
		if float(side.weight) > 0.00001:
			side.torso_fade = COUNTER_TORSO_OUT_SECONDS if bool(f.atk.get("counter", false)) else FADE_OUT_SECONDS
	else:
		side.target = 0.0
		side.mode = "neutral_fade"
	var duration: float = FADE_IN_SECONDS if float(side.target) > float(side.weight) else FADE_OUT_SECONDS
	side.weight = move_toward(float(side.weight), float(side.target), maxf(dt, 0.0) / duration)
	var torso_duration: float = FADE_IN_SECONDS if float(side.target) > float(side.torso) else (float(side.torso_fade) if f.state == f.State.ATTACK else FADE_OUT_SECONDS)
	side.torso = move_toward(float(side.torso), float(side.target), maxf(dt, 0.0) / torso_duration)
	if float(side.weight) < 0.00001 and float(side.torso) < 0.00001:
		side.weight = 0.0
		side.torso = 0.0
		if float(side.target) < 0.00001:
			side.was_active = false

func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or fighter == null:
		return
	_restore(sk)
	var f = fighter
	var wanted: Vector2 = f._lean_wanted()
	var pos: Vector2 = f.lean_pose.pos
	var bypass: bool = f.hurt.active() or f.stats.rocked or not (f.state in [f.State.SLIP, f.State.ATTACK, f.State.IDLE, f.State.CROUCH])
	if bypass:
		# Preserve the serial so the same interrupted attack cannot re-arm.
		_turn_entry = 0.0
		_reset_side(_left_side, pos.x)
		_reset_side(_right_side, pos.x)
		_last_selected = 0
		f.lean_pose.auth_k = f.anim.action_lean_share()
		_sync_legacy()
		return
	var handoff: bool = f.inp.block or f.inp.shell or f.inp.duck or f.inp.backstep or f._backstepping or f.state == f.State.CROUCH or absf(wanted.y) > 0.02
	if not handoff and f.state == f.State.SLIP:
		if wanted.x > 0.02:
			_last_selected = 1
		elif wanted.x < -0.02:
			_last_selected = -1
	_latch_counter_turn()
	_advance_side(_left_side, wanted, pos, handoff, _last_selected, dt)
	_advance_side(_right_side, wanted, pos, handoff, _last_selected, dt)
	var total_torso := clampf(float(_left_side.torso) + float(_right_side.torso), 0.0, 1.0)
	# One write, including zero and bypass paths; a fading side cannot reset the other.
	f.lean_pose.auth_k = f.anim.action_lean_share() * (1.0 - 0.70 * total_torso if APPLY_AUTHORED_POSE else 1.0)
	if APPLY_AUTHORED_POSE:
		_apply_combined(sk)
	_apply_counter_turn(sk)
	_sync_legacy()

# Carry the slip loading into a phased shoulder turn for the lead-straight counter.
func _latch_counter_turn() -> void:
	var f = fighter
	if f.state != f.State.ATTACK or f.atk.is_empty():
		_turn_serial = -1
		_turn_entry = 0.0
		return
	var serial := int(f.atk.get("serial", -1))
	# A defensive input cannot cancel an attack already in progress. Keep its
	# turn continuous until the attack state itself changes.
	if serial == _turn_serial:
		return
	_turn_serial = serial
	_turn_entry = 0.0
	var tag := String(f.atk.get("tag", ""))
	if bool(f.atk.get("counter", false)) and (tag == "LJab" or tag.begins_with("LJab~")) and bool(_left_side.was_active) and _last_selected == 1:
		_turn_entry = clampf(float(_left_side.weight), 0.0, 1.0)

func _turn_ease(x: float) -> float:
	var u := clampf(x, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)

func _apply_counter_turn(sk: Skeleton3D) -> void:
	if _turn_entry <= 0.001 or fighter.state != fighter.State.ATTACK or fighter.atk.is_empty():
		return
	var a: Dictionary = fighter.atk
	if int(a.get("serial", -1)) != _turn_serial:
		return
	var spec: Dictionary = a.get("s", {})
	var duration := float(a.get("A", 0.0))
	var contact_start := float(spec.get("w0", 0.0)) * float(a.get("k", 1.0))
	if duration <= 0.0 or contact_start <= 0.0:
		return
	var t := float(a.get("t", 0.0))
	# Rise into contact, then unwind by 90% of the action (before any tail).
	var peak := minf(contact_start, duration * 0.55)
	var end := duration * 0.90
	var envelope := _turn_ease(t / peak) * (1.0 - _turn_ease((t - peak) / maxf(end - peak, 0.001)))
	var strength := _turn_entry * envelope
	if strength <= 0.00001:
		return
	# This modifier owns the restore bookkeeping for the turn and IK corrections.
	self._ready_bones(sk)
	for bone_name in TURN_REQUIRED_BONES:
		if int(_bone.get(bone_name, -1)) < 0:
			return
	self._frame(sk)
	var feet := self._feet_begin(sk)
	var foot_rotation := {}
	for side in ["l", "r"]:
		var foot_index: int = _bone[side + "Foot"]
		foot_rotation[side] = sk.get_bone_global_pose(foot_index).basis.orthonormalized().get_rotation_quaternion()
	var strike_pin := self._pin_begin(sk)
	var strike_index := int(_bone.get(String(strike_pin.get("limb", "")), -1))
	var strike_rotation := sk.get_bone_global_pose(strike_index).basis.orthonormalized().get_rotation_quaternion() if strike_index >= 0 else Quaternion.IDENTITY
	# Negative fighter-frame yaw carries the left shoulder toward the foe.
	self._rot_axis(sk, "hip", _up, deg_to_rad(COUNTER_HIP_DEG) * strength)
	self._rot_chain(sk, SPINE, 0.0, deg_to_rad(COUNTER_SPINE_DEG) * strength, 0.0)
	self._plant_feet(sk, feet)
	# Preserve the animated sole direction after the leg IK changes its parents.
	for side in ["l", "r"]:
		var foot_index: int = _bone[side + "Foot"]
		var adjusted_foot := sk.get_bone_global_pose(foot_index).basis.orthonormalized().get_rotation_quaternion()
		self._rot_sk(sk, foot_index, (foot_rotation[side] as Quaternion) * adjusted_foot.inverse())
	self._pin_end(sk, strike_pin)
	# The fitted strike volume has a hand-local offset; preserve the striking
	# hand orientation as well as its origin through the additive body turn.
	if strike_index >= 0:
		var adjusted_rotation := sk.get_bone_global_pose(strike_index).basis.orthonormalized().get_rotation_quaternion()
		self._rot_sk(sk, strike_index, strike_rotation * adjusted_rotation.inverse())

func _apply_combined(sk: Skeleton3D) -> void:
	for key in _track_keys:
		var la: Dictionary = _left_side.asset
		var ra: Dictionary = _right_side.asset
		var lt: Dictionary = la.tracks.get(key, {}) if not la.is_empty() else {}
		var rt: Dictionary = ra.tracks.get(key, {}) if not ra.is_empty() else {}
		var tr: Dictionary = lt if not lt.is_empty() else rt
		var is_torso: bool = TORSO_BONES.has(tr.bone)
		var lw: float = (float(_left_side.torso) if is_torso else float(_left_side.weight)) if not lt.is_empty() else 0.0
		var rw: float = (float(_right_side.torso) if is_torso else float(_right_side.weight)) if not rt.is_empty() else 0.0
		var sum := lw + rw
		if sum < 0.00001:
			continue
		var strength := minf(sum, 1.0)
		var mix := rw / sum
		var j: int = tr.bone_index
		if int(tr.type) == Animation.TYPE_POSITION_3D:
			var base: Vector3 = sk.get_bone_pose_position(j)
			var left_value: Vector3 = la.action.position_track_interpolate(lt.index, float(_left_side.sample)) if lw > 0.0 else base
			var right_value: Vector3 = ra.action.position_track_interpolate(rt.index, float(_right_side.sample)) if rw > 0.0 else base
			var authored: Vector3 = left_value.lerp(right_value, mix)
			if not _base_pos.has(j):
				_base_pos[j] = base
			sk.set_bone_pose_position(j, base.lerp(authored, strength))
			_written_pos[j] = sk.get_bone_pose_position(j)
		elif int(tr.type) == Animation.TYPE_ROTATION_3D:
			var base: Quaternion = sk.get_bone_pose_rotation(j)
			var left_value: Quaternion = la.action.rotation_track_interpolate(lt.index, float(_left_side.sample)) if lw > 0.0 else base
			var right_value: Quaternion = ra.action.rotation_track_interpolate(rt.index, float(_right_side.sample)) if rw > 0.0 else base
			var authored: Quaternion = left_value.slerp(right_value, mix)
			_set_rot(sk, j, base.slerp(authored, strength))

func _sync_legacy() -> void:
	weight = float(_left_side.weight)
	torso_weight = float(_left_side.torso)
	target_weight = float(_left_side.target)
	sample_time = float(_left_side.sample)
	mode = String(_left_side.mode)

func _exit_tree() -> void:
	var sk := get_skeleton()
	if sk != null and sk.skeleton_updated.is_connected(_on_final_pose):
		sk.skeleton_updated.disconnect(_on_final_pose)
	if fighter != null and is_instance_valid(fighter) and fighter.lean_pose != null and fighter.anim != null:
		fighter.lean_pose.auth_k = fighter.anim.action_lean_share()

func _on_final_pose() -> void:
	if not record:
		return
	var sk := get_skeleton()
	if sk == null or fighter == null:
		return
	var h: Vector3 = sk.global_transform * sk.get_bone_global_pose(sk.find_bone("head")).origin
	snapshot = {"physics_frame": Engine.get_physics_frames(), "weight": weight, "torso_weight": torso_weight,
		"target_weight": target_weight, "source_time_s": sample_time, "mode": mode, "entry_lead": _left_side.lead,
		"left": _diagnostic(_left_side), "right": _diagnostic(_right_side), "selected": _last_selected,
		"lean_input": [fighter._lean_wanted().x, fighter._lean_wanted().y],
		"lean_pos": [fighter.lean_pose.pos.x, fighter.lean_pose.pos.y],
		"procedural_lean_share": fighter.lean_pose.auth_k, "driver_head": [h.x, h.y, h.z]}

func _diagnostic(side: Dictionary) -> Dictionary:
	return {"available": not (side.asset as Dictionary).is_empty(), "weight": side.weight,
		"torso_weight": side.torso, "target_weight": side.target, "source_time_s": side.sample,
		"mode": side.mode, "entry_lead": side.lead, "sample_reentry": side.reentry}

