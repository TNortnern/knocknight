extends SceneTree
## Windowed, deterministic Fight Night pose / counter captures through the real game scene.
##
## Run from the project root:
##   <godot-console.exe> --path . --fixed-fps 120 --script res://tools/capture_fn_match.gd -- \
##       scenario=slip_l model=viper solo=true out=C:/absolute/capture/dir fps=30 view=reference side=-1
##
## `scenario=all` writes one sequence under a scenario-named child directory. Inputs are applied on
## 120 Hz physics ticks. Images are read only after RenderingServer.frame_post_draw; no SceneTree
## timer advances simulation or controls sampling. The capture camera replaces the live FightCamera
## for the whole shoot, and is made current again immediately before every sampled draw.

const MAIN_SCENE := "res://scenes/main.tscn"
const CaptureMainScript := preload("res://tools/capture_fn_main.gd")
const FighterInputScript := preload("res://scripts/fighter/fighter_input.gd")
const RosterScript := preload("res://scripts/fighter/roster.gd")
const HitFitScript := preload("res://scripts/fighter/hit_fit.gd")

const TICK_RATE := 120
var INPUT_START := 0.20
var INPUT_RELEASE := 0.85
var COUNTER_INPUT := 0.50
var counter_tag := "RHook"
var opponent_tag := ""   # Empty retains the original direction-specific coverage action.
var OPPONENT_STRIKE := 0.35
var CLIP_SECONDS := 1.60
const DEFAULT_GAP := 1.00
var capture_gap := DEFAULT_GAP
const POSE_SCENARIOS := ["slip_l", "slip_r", "back", "forward", "duck", "circle"]
const COUNTER_SCENARIOS := ["counter_l", "counter_r", "counter_back"]
const ALL_SCENARIOS := ["slip_l", "slip_r", "back", "forward", "duck", "circle", "counter_l", "counter_r", "counter_back"]


class PhysicsInputDriver extends Node:
	## SceneTree.physics_frame is emitted before Node._physics_process(). A coroutine that
	## waits on it resumes first and can overwrite the next one-tick input before Fighter sees
	## the previous one. This node owns replay ordering: priority -100 runs before Fighter's 0.
	var runner: SceneTree
	var sequence := ""
	var submitted_tick := -1
	var target_tick := 0
	var running := false
	var defender_attacks: Array = []
	var opponent_attacks: Array = []
	var _last_defender_serial := -1
	var _last_opponent_serial := -1
	const DRIVER_TICK_RATE := 120

	func _init(p_runner: SceneTree) -> void:
		runner = p_runner
		name = "FnMatchPhysicsInput"
		process_physics_priority = -100
		process_priority = 1000

	func begin(seq_name: String) -> void:
		sequence = seq_name
		submitted_tick = -1
		target_tick = 0
		running = true
		defender_attacks.clear()
		opponent_attacks.clear()
		_last_defender_serial = -1
		_last_opponent_serial = -1

	func set_target(tick: int) -> void:
		target_tick = tick
		running = submitted_tick < target_tick

	func stop() -> void:
		running = false

	func _physics_process(_dt: float) -> void:
		if not running:
			return
		submitted_tick += 1
		runner.call("_apply_input_tick", sequence, submitted_tick)

	func _process(_dt: float) -> void:
		if not running and submitted_tick < 0:
			return
		_track(runner.get("defender"), true)
		_track(runner.get("opponent"), false)
		runner.call("_update_capture_orbit", submitted_tick)

	func _track(fighter, is_defender: bool) -> void:
		if fighter == null or not is_instance_valid(fighter):
			return
		var tag := String(fighter.atk.get("tag", ""))
		var serial := int(fighter.atk.get("serial", -1))
		var previous: int = _last_defender_serial if is_defender else _last_opponent_serial
		if serial == previous:
			return
		if is_defender:
			_last_defender_serial = serial
		else:
			_last_opponent_serial = serial
		if tag == "":
			return
		var row := {
			"tick": submitted_tick,
			"time": float(submitted_tick) / float(DRIVER_TICK_RATE),
			"tag": tag,
			"serial": serial,
			"counter": bool(fighter.atk.get("counter", false)),
			"clip": String(fighter.atk.get("s", {}).get("counter_clip", fighter.anim.action_clip)),
		}
		if is_defender:
			defender_attacks.append(row)
		else:
			row["input_state"] = String(fighter.state_name)
			opponent_attacks.append(row)

	func audit() -> Dictionary:
		return {
			"driver_priority": process_physics_priority,
			"last_submitted_tick": submitted_tick,
			"dispatched_inputs": runner.get("input_events"),
			"defender_attacks": defender_attacks,
			"opponent_attacks": opponent_attacks,
		}


var main: Node
var match_node: Node
var fighters: Array = []
var defender: Node3D
var opponent: Node3D
var capture_cam: Camera3D
var bone_snap: Dictionary = {}
var fitted_snap: Dictionary = {}
var input_driver: PhysicsInputDriver
var input_events: Array = []

var scenario := "slip_l"
var model := "viper"
var out_dir := ""
var fps := 30
var view := "reference"
var solo := false
var fullbody := true
var hide_ui := true
var width := 720
var height := 1280
var view_yaw_degrees := -1.0
var elevation_degrees := 25.0
var camera_side := "right"
var look_y := -1.0   ## capture-only: explicit look-at height (m); < 0 keeps the body framing
var cam_dist := -1.0 ## capture-only: explicit camera distance (m); < 0 keeps the body framing
var shift_x := 0.0   ## capture-only: slides camera and look-at along the camera right axis (m), framing the fighter off-centre
var frame_towards_foe := 0.20
var force_block := false
var amplitude := 1.0
var counter_analog_ramp := 0.0  ## capture-only: seconds from neutral to full analog lateral lean
var lean_ramp := 0.0  ## capture-only: slip_l/slip_r stick eases in over this many seconds from start and back out from release (a human thumb, not a step)
var release_ramp := -1.0  ## capture-only: seconds for the stick to return to centre on release (a let-go thumbstick springs back); <0 = lean_ramp
var lean_fwd := 0.0  ## capture-only: forward (+y) share of the slip_l/slip_r stick, for a diagonal slip-under input
var idle_clip := ""              ## capture-only idle comparison; empty keeps the gameplay default
var chain_punch := false
var debug_hulls := false
var trace_hitboxes := false
var recatch_start := -1.0
var recatch_end := -1.0
# Optional capture-only orbit. Defaults keep all existing captures static.
var orbit_enabled := false
var orbit_start_yaw := 40.0
var orbit_end_yaw := 120.0
var orbit_start_time := 0.40
var orbit_end_time := 0.77
var orbit_return_yaw := -1.0  ## optional return toward a side-on view
var orbit_return_time := -1.0
var orbit_pivot := Vector3.ZERO
var orbit_front := Vector3.FORWARD
var orbit_side_vec := Vector3.RIGHT
var orbit_distance := 0.0
var orbit_current_yaw := 0.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var ok := _parse_args()
	if not ok:
		quit(2)
		return
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path("res://_build/fn-match")
	out_dir = out_dir.simplify_path()
	if DirAccess.make_dir_recursive_absolute(out_dir) != OK:
		_fail("could not create output directory: " + out_dir)
		return
	if scenario != "all" and not ALL_SCENARIOS.has(scenario):
		_fail("unknown scenario '%s' (want %s or all)" % [scenario, ", ".join(ALL_SCENARIOS)])
		return
	if not RosterScript.DATA.has(model):
		_fail("unknown model '%s'" % model)
		return
	if solo and COUNTER_SCENARIOS.has(scenario):
		_fail("solo=true is only valid for pose scenarios; counter captures keep the opponent visible")
		return
	if scenario == "all" and solo:
		print("capture_fn_match: solo pose captures; counter sequences will keep the opponent visible")

	Engine.physics_ticks_per_second = TICK_RATE
	Engine.physics_jitter_fix = 0.0
	Engine.max_physics_steps_per_frame = 1
	_configure_window()
	input_driver = PhysicsInputDriver.new(self)
	root.add_child(input_driver)

	var names: Array = ALL_SCENARIOS if scenario == "all" else [scenario]
	var all_rows: Array = []
	for name: String in names:
		var this_solo := solo and POSE_SCENARIOS.has(name)
		var seq_dir := out_dir if names.size() == 1 else out_dir.path_join(name)
		if DirAccess.make_dir_recursive_absolute(seq_dir) != OK:
			_fail("could not create sequence directory: " + seq_dir)
			return
		print("capture_fn_match: %s model=%s solo=%s -> %s" % [name, model, str(this_solo), seq_dir])
		var doc := await _capture_sequence(name, seq_dir, this_solo)
		if doc.is_empty():
			quit(1)
			return
		var manifest_path := seq_dir.path_join("sequence_manifest.json")
		if not _write_json(manifest_path, doc):
			quit(1)
			return
		all_rows.append({"scenario": name, "directory": seq_dir, "manifest": manifest_path,
			"images": int(doc["frame_count"]), "model": model, "solo": this_solo})
		print("capture_fn_match: wrote %s (%d frames)" % [manifest_path, int(doc["frame_count"])])

	if names.size() > 1:
		var index := {
			"schema": "knocknight_fn_match_index/v1",
			"created_utc": Time.get_datetime_string_from_system(true),
			"fps": fps,
			"physics_ticks_per_second": TICK_RATE,
			"clip_seconds": CLIP_SECONDS,
			"sequences": all_rows,
		}
		_write_json(out_dir.path_join("all_manifest.json"), index)
	quit(0)


func _parse_args() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		var key := arg
		var value := ""
		var at := arg.find("=")
		if at >= 0:
			key = arg.substr(0, at).to_lower()
			value = arg.substr(at + 1)
		else:
			key = key.to_lower()
		match key:
			"scenario":
				scenario = value.to_lower()
			"model":
				model = value
			"out":
				out_dir = value
			"fps":
				fps = maxi(1, int(value))
			"start":
				INPUT_START = maxf(0.0, float(value))
			"release":
				INPUT_RELEASE = maxf(0.0, float(value))
			"seconds":
				CLIP_SECONDS = maxf(0.1, float(value))
			"counter_time":
				COUNTER_INPUT = maxf(0.0, float(value))
			"counter_tag":
				counter_tag = value
			"opponent_tag":
				opponent_tag = value
			"opponent_time":
				OPPONENT_STRIKE = maxf(0.0, float(value))
			"gap":
				capture_gap = clampf(float(value), 0.65, 1.8)
			"view":
				view = value.to_lower()
			"solo":
				solo = _truthy(value)
			"fullbody", "framing":
				fullbody = _truthy(value) or value.to_lower() == "fullbody"
			"yaw", "yaw_degrees":
				view_yaw_degrees = float(value)
			"orbit_start_yaw":
				orbit_enabled = true
				orbit_start_yaw = clampf(float(value), 0.0, 180.0)
			"orbit_end_yaw":
				orbit_enabled = true
				orbit_end_yaw = clampf(float(value), 0.0, 180.0)
			"orbit_start_time":
				orbit_start_time = maxf(0.0, float(value))
			"orbit_end_time":
				orbit_end_time = maxf(0.0, float(value))
			"orbit_return_yaw":
				orbit_enabled = true
				orbit_return_yaw = clampf(float(value), 0.0, 180.0)
			"orbit_return_time":
				orbit_return_time = maxf(0.0, float(value))
			"elevation", "elevation_degrees":
				elevation_degrees = clampf(float(value), -10.0, 75.0)
			"look_y":
				look_y = float(value)
			"shift_x":
				shift_x = float(value)
			"dist":
				cam_dist = float(value)
			"frame_offset":
				frame_towards_foe = float(value)
			"block":
				force_block = _truthy(value)
			"amplitude":
				amplitude = clampf(float(value), 0.0, 1.0)
			"lean_ramp":
				lean_ramp = maxf(float(value), 0.0)
			"release_ramp":
				release_ramp = maxf(float(value), 0.0)
			"lean_fwd":
				lean_fwd = clampf(float(value), -1.0, 1.0)
			"counter_analog_ramp":
				counter_analog_ramp = maxf(float(value), 0.0)
			"idle_clip":
				idle_clip = value
			"chain":
				chain_punch = _truthy(value)
			"debug_hulls":
				debug_hulls = _truthy(value)
			"trace_hitboxes":
				trace_hitboxes = _truthy(value)
			"recatch_start":
				recatch_start = float(value)
			"recatch_end":
				recatch_end = float(value)
			"camera_side", "orbit_side":
				camera_side = value.to_lower()
			"side":
				var side_sign := int(value)
				if side_sign != -1 and side_sign != 1:
					_fail("side must be -1 (mirrored) or +1 (default)")
					return false
				camera_side = "left" if side_sign < 0 else "right"
			"hide_ui", "ui":
				hide_ui = _truthy(value) if key == "hide_ui" else not _truthy(value)
			"width":
				width = maxi(160, int(value))
			"height":
				height = maxi(160, int(value))
			_:
				if arg.to_lower() == "fullbody":
					fullbody = true
				else:
					print("capture_fn_match: ignoring argument ", arg)
	if view not in ["reference", "rear", "front", "side"]:
		_fail("view must be reference, rear, front, or side")
		return false
	if camera_side not in ["left", "right"]:
		_fail("camera_side must be left or right")
		return false
	if orbit_enabled and orbit_end_time <= orbit_start_time:
		_fail("orbit_end_time must be later than orbit_start_time")
		return false
	if orbit_return_yaw >= 0.0 and orbit_return_time <= orbit_end_time:
		_fail("orbit_return_time must be later than orbit_end_time")
		return false
	if fps > TICK_RATE:
		_fail("fps cannot exceed the %d Hz physics tick rate" % TICK_RATE)
		return false
	if not StrikeDB.has_strike(counter_tag):
		_fail("unknown counter_tag '%s'" % counter_tag)
		return false
	if not opponent_tag.is_empty() and not StrikeDB.has_strike(opponent_tag):
		_fail("unknown opponent_tag '%s'" % opponent_tag)
		return false
	if not RosterScript.DATA.has(model):
		_fail("unknown model '%s' (choose from %s)" % [model, ", ".join(RosterScript.ORDER)])
		return false
	return true


static func _truthy(value: String) -> bool:
	return value.to_lower() in ["1", "true", "yes", "on", "hide", "hidden"]


func _capture_sequence(seq_name: String, seq_dir: String, pose_only: bool) -> Dictionary:
	var fresh_ok: bool = await _fresh(pose_only)
	if not fresh_ok:
		return {}

	var frame_count := maxi(1, int(round(CLIP_SECONDS * float(fps))))
	var frames: Array = []
	input_events.clear()
	input_driver.begin(seq_name)
	var tick := -1
	for frame_index in frame_count:
		var target_tick := int(round(float(frame_index) * float(TICK_RATE) / float(fps)))
		capture_cam.make_current()
		await RenderingServer.frame_post_draw
		while input_driver.submitted_tick < target_tick:
			await RenderingServer.frame_post_draw
		if input_driver.submitted_tick > target_tick + 1:
			_fail("physics tick overrun at frame %d: wanted %d, driver reached %d" %
				[frame_index, target_tick, input_driver.submitted_tick])
			return {}
		tick = input_driver.submitted_tick
		var image_path := seq_dir.path_join("%s_%s_%03d.png" % [model, seq_name, frame_index])
		var image := root.get_viewport().get_texture().get_image()
		if image == null or image.is_empty():
			_fail("viewport image was empty at frame %d" % frame_index)
			return {}
		var save_err := image.save_png(image_path)
		if save_err != OK:
			_fail("could not save %s (error %d)" % [image_path, save_err])
			return {}
		frames.append(_frame_record(frame_index, float(tick) / TICK_RATE, tick, image_path))
	input_driver.stop()

	var doc := {
		"schema": "knocknight_fn_match_sequence/v1",
		"created_utc": Time.get_datetime_string_from_system(true),
		"scenario": seq_name,
		"model": model,
		"defender_model_actual": String(defender.model),
		"defender_template": String(defender.template),
		"defender_player_index": defender.player_index,
		"opponent_model": String(opponent.model),
		"opponent_template": String(opponent.template),
		"opponent_player_index": opponent.player_index,
		"solo_visual": pose_only,
		"ui_hidden": hide_ui,
		"ui_scope": "main UI only; in-world rocked/gassed status tags remain visible",
		"fps": fps,
		"clip_seconds": CLIP_SECONDS,
		"frame_count": frames.size(),
		"physics_ticks_per_second": TICK_RATE,
		"ticks_per_frame": float(TICK_RATE) / float(fps),
		"sampling": "continuous priority -100 physics input driver -> frame_post_draw -> sample target tick; actual tick/time recorded, no paused-input ticks",
		"input_audit": input_driver.audit(),
		"input_timing": {
			"start": INPUT_START,
			"hold_until": INPUT_RELEASE,
			"counter": COUNTER_INPUT,
			"opponent_strike": OPPONENT_STRIKE if COUNTER_SCENARIOS.has(seq_name) else null,
		},
		"input_options": {"block": force_block, "amplitude": amplitude, "counter_analog_ramp": counter_analog_ramp, "idle_clip": idle_clip, "chain": chain_punch, "counter_tag": counter_tag, "opponent_tag": _opponent_strike_tag(seq_name), "gap": capture_gap, "debug_hulls": debug_hulls, "trace_hitboxes": trace_hitboxes, "recatch_start": recatch_start, "recatch_end": recatch_end},
		"schedule": _schedule(seq_name),
		"camera": _camera_record(),
		"bone_convention": "world-space skeleton origin: skeleton.global_transform * get_bone_global_pose(i).origin",
		"bone_source": "Skeleton3D.skeleton_updated after the final modifier pass (same pose drawn for that tick)",
		"frames": frames,
	}
	return doc


func _fresh(pose_only: bool) -> bool:
	if main != null and is_instance_valid(main):
		main.queue_free()
		await process_frame
	main = load(MAIN_SCENE).instantiate()
	main.set_script(CaptureMainScript)
	root.add_child(main)
	await process_frame
	# Main._ready() sets CANVAS_ITEMS / KEEP / 1600x900. Reset it after that ready pass so the
	# captured Window viewport is the requested portrait raster, not a letterboxed 16:9 surface.
	_configure_window()
	await process_frame
	var opponent_model := _opponent_for(model)
	main.start_match({
		"mode": "exhibition",
		"p1_controller": "dummy",
		"p2_controller": "dummy",
		"p1_model": opponent_model,
		"p2_model": model,
		"rules": "boxing",
		"rounds": 1,
		"round_seconds": 120.0,
		"arena": "ring",
		"intro_delay": 0.0,
	})
	for i in 330:
		await physics_frame
	var matches := main.find_children("*", "Match", true, false)
	if matches.is_empty():
		_fail("main scene did not create a Match")
		return false
	match_node = matches[0]
	fighters = match_node.get_fighters()
	if fighters.size() < 2:
		_fail("Match did not expose two fighters")
		return false
	opponent = fighters[0] as Node3D
	defender = fighters[1] as Node3D
	if not idle_clip.is_empty():
		if not defender.anim.player.has_animation(idle_clip):
			_fail("unknown idle_clip '%s'" % idle_clip)
			return false
		var blend_root: AnimationNodeBlendTree = defender.anim.tree.tree_root
		var machine := blend_root.get_node("Base") as AnimationNodeStateMachine
		for state_name in ["Move", "Rocked"]:
			var space := machine.get_node(state_name) as AnimationNodeBlendSpace2D
			var idle := space.get_blend_point_node(0) as AnimationNodeAnimation
			idle.animation = StringName(idle_clip)
	if debug_hulls:
		opponent.set_debug_boxes(true)
		defender.set_debug_boxes(true)
	opponent.external_input = FighterInputScript.new()
	defender.external_input = FighterInputScript.new()
	opponent.global_position = Vector3(-capture_gap * 0.5, 0.0, 0.0)
	defender.global_position = Vector3(capture_gap * 0.5, 0.0, 0.0)
	for i in 60:
		await physics_frame

	_freeze_live_camera()
	if main.get("ui") != null:
		main.get("ui").visible = not hide_ui
	if pose_only:
		var opp_slot := opponent.get_node_or_null("ModelSlot")
		if opp_slot != null:
			opp_slot.visible = false

	defender.guard_style.record = true
	_install_bone_recorder()
	for i in 2:
		await physics_frame
	_aim_static_camera()
	capture_cam.make_current()
	await process_frame
	await RenderingServer.frame_post_draw
	capture_cam.make_current()
	return true


func _freeze_live_camera() -> void:
	var live: Camera3D = main.get("current_camera") as Camera3D
	if live != null:
		live.set_process(false)
		live.process_mode = Node.PROCESS_MODE_DISABLED
		live.current = false
		var post := live.get_node_or_null("ImpactPost")
		if post is CanvasLayer:
			(post as CanvasLayer).visible = false
	if capture_cam == null or not is_instance_valid(capture_cam):
		capture_cam = Camera3D.new()
		capture_cam.name = "FnMatchCaptureCamera"
		capture_cam.fov = 36.0
		capture_cam.near = 0.05
		capture_cam.far = 80.0
		capture_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		capture_cam.keep_aspect = Camera3D.KEEP_HEIGHT
		root.add_child(capture_cam)
	# A second make_current after add_child covers the frame in which the scene camera became current.
	capture_cam.make_current()


func _install_bone_recorder() -> void:
	bone_snap = {}
	fitted_snap = {}
	var sk := _skeleton(defender)
	if sk == null:
		return
	if not sk.skeleton_updated.is_connected(_record_final_bones):
		sk.skeleton_updated.connect(_record_final_bones.bind(sk))


func _record_final_bones(sk: Skeleton3D) -> void:
	# skeleton_updated is the final-post-modifier callback used by the Meshy retargeter.
	# Reading here keeps the manifest aligned with the visible posed skeleton, not its pre-modifier pose.
	var out := {}
	for bone_name: String in ["head", "hip", "chestUpper", "abdomenLower", "neckLower",
			"lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend",
			"lHand", "rHand", "lFoot", "rFoot", "lShin", "rShin"]:
		var idx := sk.find_bone(bone_name)
		if idx >= 0:
			out[bone_name] = sk.global_transform * sk.get_bone_global_pose(idx).origin
	bone_snap = out
	var fitted := {}
	var fit: Dictionary = HitFitScript.FIT.get(defender.model, {})
	for key in ["head", "lHand", "rHand"]:
		if fit.has(key):
			var idx := sk.find_bone(String(fit[key]["bone"]))
			if idx >= 0:
				fitted[key] = sk.global_transform * (sk.get_bone_global_pose(idx) * (fit[key]["off"] as Vector3))
	fitted_snap = fitted


func _aim_static_camera() -> void:
	var front := opponent.global_position - defender.global_position
	front.y = 0.0
	if front.length() < 0.001:
		front = -defender.global_basis.z
	front = front.normalized()
	var side := front.cross(Vector3.UP).normalized()
	var head := _snap_point("head", defender.global_position + Vector3.UP * 1.65)
	var hip := _snap_point("hip", defender.global_position + Vector3.UP * 1.0)
	var feet_l := _snap_point("lFoot", defender.global_position)
	var feet_r := _snap_point("rFoot", defender.global_position)
	var knee_l := _snap_point("lShin", feet_l.lerp(hip, 0.45))
	var knee_r := _snap_point("rShin", feet_r.lerp(hip, 0.45))
	var bottom := minf(knee_l.y, knee_r.y) - 0.075
	if fullbody:
		bottom = minf(feet_l.y, feet_r.y) - 0.035
	var top := head.y + 0.10
	var centre_y := (top + bottom) * 0.5
	var target := (head + hip + feet_l + feet_r) * 0.25
	target.y = 0.90 if fullbody and view in ["reference", "rear"] else centre_y
	# The source frames the defender on the right, leaving room for the extended glove and opponent on the left.
	target += front * frame_towards_foe
	var yaw_deg := _effective_yaw_degrees()
	var yaw_rad := deg_to_rad(yaw_deg)
	var from_target := (front * cos(yaw_rad) + side * sin(yaw_rad)).normalized()
	var vertical_span := maxf(top - bottom, 0.6)
	var occupancy := 0.88 if fullbody else 0.84
	var distance := (vertical_span * 0.5) / (tan(deg_to_rad(capture_cam.fov) * 0.5) * occupancy)
	distance = clampf(distance, 1.25, 6.5)
	if cam_dist > 0.0:
		distance = cam_dist
	if look_y > 0.0:
		target.y = look_y
	orbit_pivot = target
	orbit_front = front
	orbit_side_vec = side
	orbit_distance = distance
	var el_rad := deg_to_rad(elevation_degrees)
	capture_cam.global_position = target + from_target * (distance * cos(el_rad)) + Vector3.UP * (distance * sin(el_rad))
	capture_cam.look_at(target, Vector3.UP)
	if shift_x != 0.0:
		var cam_right := capture_cam.global_transform.basis.x
		capture_cam.global_position += cam_right * shift_x
	capture_cam.make_current()
	print("capture_fn_match: camera %s yaw=%.1f elevation=%.1f %s fov=%.1f pos=%s target=%s" % [view, yaw_deg, elevation_degrees, "fullbody" if fullbody else "knee-to-head", capture_cam.fov, str(capture_cam.global_position), str(target)])


## Update only the capture camera; the normal gameplay camera is untouched.
func _update_capture_orbit(tick: int) -> void:
	if not orbit_enabled or tick < 0 or capture_cam == null or orbit_distance <= 0.0:
		return
	var t := float(tick) / float(TICK_RATE)
	var u := smoothstep(orbit_start_time, orbit_end_time, t)
	var yaw := lerpf(orbit_start_yaw, orbit_end_yaw, u)
	if orbit_return_yaw >= 0.0:
		yaw = lerpf(yaw, orbit_return_yaw, smoothstep(orbit_end_time, orbit_return_time, t))
	var signed_yaw := yaw if camera_side == "right" else -yaw
	orbit_current_yaw = signed_yaw
	var rad := deg_to_rad(signed_yaw)
	var from_target := (orbit_front * cos(rad) + orbit_side_vec * sin(rad)).normalized()
	var el := deg_to_rad(elevation_degrees)
	capture_cam.global_position = orbit_pivot + from_target * (orbit_distance * cos(el)) + Vector3.UP * (orbit_distance * sin(el))
	capture_cam.look_at(orbit_pivot, Vector3.UP)
	capture_cam.make_current()


func _effective_yaw_degrees() -> float:
	var yaw_deg := view_yaw_degrees
	if yaw_deg < 0.0:
		yaw_deg = 120.0 if view in ["reference", "rear"] else (40.0 if view == "front" else 90.0)
	# `side` points to the defender's right. The default preserves the baseline +1 orbit;
	# explicit `side=-1` mirrors that orbit and puts the fighter's face towards screen-left.
	return yaw_deg if camera_side == "right" else -yaw_deg


func _apply_input_tick(seq_name: String, tick: int) -> void:
	var t := float(tick) / float(TICK_RATE)
	var dinp = FighterInputScript.new()
	var oinp = FighterInputScript.new()
	var out_ramp := release_ramp if release_ramp >= 0.0 else lean_ramp
	var active := t >= INPUT_START and t < INPUT_RELEASE + (out_ramp if seq_name in ["slip_l", "slip_r"] else 0.0)
	var stick := 1.0
	if seq_name in ["slip_l", "slip_r"]:
		if lean_ramp > 0.0:
			stick *= smoothstep(INPUT_START, INPUT_START + lean_ramp, t)
		if out_ramp > 0.0:
			stick *= 1.0 - smoothstep(INPUT_RELEASE, INPUT_RELEASE + out_ramp, t)
	if active:
		match seq_name:
			"slip_l":
				dinp.lean = Vector2(amplitude, lean_fwd) * stick
			"slip_r":
				dinp.lean = Vector2(-amplitude, lean_fwd) * stick
			"back":
				dinp.lean = Vector2(0.0, -amplitude)
			"forward":
				dinp.lean = Vector2(0.0, amplitude)
			"duck":
				dinp.duck = true
			"circle":
				# Sweep the analog head-movement disc through side / forward / opposite side / pull.
				var phase := (t - INPUT_START) / maxf(INPUT_RELEASE - INPUT_START, 0.01) * TAU
				dinp.lean = Vector2(cos(phase), sin(phase)) * 0.8
			"counter_l":
				if counter_analog_ramp > 0.0:
					dinp.lean = Vector2(amplitude * clampf((t - INPUT_START) / counter_analog_ramp, 0.0, 1.0), 0.0)
				else:
					dinp.slip = 1
			"counter_r":
				if counter_analog_ramp > 0.0:
					dinp.lean = Vector2(-amplitude * clampf((t - INPUT_START) / counter_analog_ramp, 0.0, 1.0), 0.0)
				else:
					dinp.slip = -1
			"counter_back":
				dinp.lean = Vector2(0.0, -amplitude)
		if force_block:
			dinp.block = true
	# Slip captures may throw an explicit opponent strike (opponent_tag=...), for the punch the defender slips under.
	if COUNTER_SCENARIOS.has(seq_name) or (not opponent_tag.is_empty() and seq_name in ["slip_l", "slip_r"]):
		if tick == int(round(OPPONENT_STRIKE * TICK_RATE)):
			oinp.strikes.append(_opponent_strike_tag(seq_name))
			input_events.append({"tick": tick, "time": t, "target": "opponent", "strike": String(oinp.strikes[-1])})
	if COUNTER_SCENARIOS.has(seq_name):
		if tick == int(round(COUNTER_INPUT * TICK_RATE)):
			dinp.strikes.append(counter_tag)
			input_events.append({"tick": tick, "time": t, "target": "defender", "strike": counter_tag})
		if chain_punch and tick == int(round((COUNTER_INPUT + 0.30) * TICK_RATE)):
			dinp.strikes.append("LJab")
			input_events.append({"tick": tick, "time": t, "target": "defender", "strike": "LJab"})
	if recatch_start >= 0.0 and t >= recatch_start and t < recatch_end:
		dinp.lean = Vector2.ZERO
		dinp.slip = 0
	defender.external_input = dinp
	opponent.external_input = oinp


func _opponent_strike_tag(seq_name: String) -> String:
	return opponent_tag if not opponent_tag.is_empty() else ("RJab" if seq_name == "counter_l" else "LJab")


func _frame_record(index: int, time_s: float, tick: int, image_path: String) -> Dictionary:
	var bones := {}
	var projections := {}
	for bone_name: String in ["head", "hip", "chestUpper", "abdomenLower", "neckLower",
			"lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend",
			"lHand", "rHand", "lFoot", "rFoot", "lShin", "rShin"]:
		var p := _snap_point(bone_name, defender.global_position)
		bones[bone_name] = _vec3(p)
		projections[bone_name] = _projection(p)
	var basis_x := defender.global_basis.x.normalized()
	var basis_z := defender.global_basis.z.normalized()
	var fitted_projections := {}
	for key in fitted_snap:
		fitted_projections[key] = _projection(fitted_snap[key])
	return {
		"index": index,
		"time": time_s,
		"tick": tick,
		"image": image_path,
		"input": _input_record(defender.inp),
		"opponent_input": _input_record(opponent.inp),
		"bones": bones,
		"projections": projections,
		"fitted_center_projections": fitted_projections,
		"world_directions": {
			"basis_x": _vec3(basis_x),
			"basis_z": _vec3(basis_z),
			"facing": _vec3(basis_z),
		},
		"fighter": {
			"root_position": _vec3(defender.global_position),
			"state": String(defender.state_name),
			"defence_kind": String(defender.dm.kind),
			"slip_dir": int(defender.slip_dir),
			"slip_t": float(defender.slip_t),
			"duck_t": float(defender.duck_t),
			"lean_pos": [float(defender.lean_pose.pos.x), float(defender.lean_pose.pos.y)],
			"side_hold_time": float(defender.lean_pose.get("_side_hold_time")),
			"counter_entry_weight": defender.lean_pose.counter_entry_weight,
			"counter_entry_drop": defender.lean_pose.counter_entry_drop,
			"counter_reach_trim": defender.lean_pose.counter_reach_trim,
			"straight_chamber_weight": defender.lean_pose.straight_chamber_weight,
			"guard_wrist_turn_deg": defender.lean_pose.guard_wrist_turn_deg,
			"guard_wrist_angles": defender.lean_pose.guard_wrist_angles.duplicate(true),
			"counter_window": float(defender.counter_window),
			"attack_tag": String(defender.atk.get("tag", "")),
			"attack_serial": int(defender.atk.get("serial", -1)),
			"attack_time": float(defender.atk.get("t", 0.0)),
			"attack_phase": defender.punch_phase(),
			"hit_done": bool(defender.atk.get("hit_done", false)),
			"outcome": String(defender.atk.get("outcome", "")),
			"attack_clash": bool(defender.atk.get("clash", false)),
			"attack_blocked": bool(defender.atk.get("blocked", false)),
			"guard_on": bool(defender.guard_on),
			"attack_land_fighter_clock_s": float(defender.atk.get("land_t", -1.0)),
			"attack_counter": bool(defender.atk.get("counter", false)),
			"attack_clip": String(defender.atk.get("s", {}).get("counter_clip", defender.anim.action_clip)),
		},
		"opponent": {
			"root_position": _vec3(opponent.global_position),
			"visual_visible": opponent.get_node("ModelSlot").visible,
			"state": String(opponent.state_name),
			"attack_tag": String(opponent.atk.get("tag", "")),
			"attack_serial": int(opponent.atk.get("serial", -1)),
			"attack_time": float(opponent.atk.get("t", 0.0)),
			"attack_phase": opponent.punch_phase(),
			"hit_done": bool(opponent.atk.get("hit_done", false)),
			"outcome": String(opponent.atk.get("outcome", "")),
			"attack_clash": bool(opponent.atk.get("clash", false)),
			"attack_blocked": bool(opponent.atk.get("blocked", false)),
			"guard_on": bool(opponent.guard_on),
			"attack_land_fighter_clock_s": float(opponent.atk.get("land_t", -1.0)),
		},
		"arm_clearance": {"defender": _arm_clear_record(defender), "opponent": _arm_clear_record(opponent)},
		"contact_trace": _contact_trace(opponent, defender) if trace_hitboxes else {},
		"counter_contact_trace": _contact_trace(defender, opponent) if trace_hitboxes else {},
		"camera_frame": _camera_record() if orbit_enabled else {},
	}


## Read-only capture diagnostics: last sampled hitbox centers and the attachment position after
## draw. This records timing/fit evidence; it neither moves the hand nor decides contact.
func _contact_trace(attacker, target) -> Dictionary:
	if attacker == null or target == null or attacker.atk.is_empty() or attacker.rig == null or target.rig == null:
		return {}
	var limb := String(attacker.atk.get("limb", ""))
	var matching: Array = attacker.rig.hitbox_for(limb)
	if matching.is_empty() or matching[0].shapes.is_empty():
		return {}
	var hb = matching[0]
	var sampled: Vector3 = hb.centre_now(0)
	var prior: Vector3 = hb.centre_before(0)
	var shape: CollisionShape3D = hb.shapes[0]["node"]
	var attached: Vector3 = shape.global_position
	var radi: float = float(hb.shapes[0]["r"])
	var sampled_shapes := []
	for box in matching:
		for i in box.shapes.size():
			sampled_shapes.append({"previous_world": _vec3(box.centre_before(i)),
				"current_world": _vec3(box.centre_now(i)), "radius_m": float(box.shapes[i]["r"])})
	var heads := []
	for hu in target.rig.hurtboxes:
		if hu.zone == "head" and hu.shape_node != null:
			heads.append({"limb": String(hu.limb), "sampled_sdf_m": float(hu.sdf(sampled)),
				"attachment_sdf_m": float(hu.sdf(attached)), "radius_m": radi})
	# Retargeted Meshy joints and the driver joints are distinct from the hitbox sphere centre.
	# Compare paired joint origins from the most recent sync, not from the pre-modifier pose.
	var retarget := {}
	var forearm_axis := {}
	if attacker.meshy_skin != null and target.meshy_skin != null and limb in ["lHand", "rHand"]:
		var hand_name := "LeftHand" if limb == "lHand" else "RightHand"
		var driver_hand: Vector3 = attacker.meshy_skin.driver_world(limb).origin
		var skin_hand: Vector3 = attacker.meshy_skin.joint_world(hand_name)
		var driver_head: Vector3 = target.meshy_skin.driver_world("head").origin
		var skin_head: Vector3 = target.meshy_skin.joint_world("Head")
		var elbow_name := "LeftForeArm" if limb == "lHand" else "RightForeArm"
		var elbow: Vector3 = attacker.meshy_skin.joint_world(elbow_name)
		var forearm := skin_hand - elbow
		var wrist_to_fist := attached - skin_hand
		if forearm.length() > 0.001 and wrist_to_fist.length() > 0.001:
			var axis := forearm.normalized()
			var axial := wrist_to_fist.dot(axis)
			forearm_axis = {"elbow_world": _vec3(elbow), "wrist_world": _vec3(skin_hand),
				"fist_world": _vec3(attached), "fist_offset_along_forearm_m": axial,
				"fist_offset_from_forearm_axis_m": (wrist_to_fist - axis * axial).length(),
				"angle_degrees": rad_to_deg(acos(clampf(axis.dot(wrist_to_fist.normalized()), -1.0, 1.0)))}
			# Diagnostic samples on the visible elbow/wrist joint line, against fresh head-hull transforms.
			# These are fitted proxies; they do not measure intersection of the actual skinned meshes.
			var nearest := {}
			for hu in target.rig.hurtboxes:
				if hu.zone != "head" or hu.shape_node == null:
					continue
				for j in 41:
					var u := float(j) / 40.0
					var sdf := _capture_shape_sdf(hu, elbow.lerp(skin_hand, u))
					if nearest.is_empty() or sdf < float(nearest["sdf_m"]):
						nearest = {"hull": String(hu.limb), "along_elbow_to_wrist": u, "sdf_m": sdf}
			forearm_axis["closest_head_proxy_sample"] = nearest
		# The uncached attachment transform is read after draw. Hurtbox.sdf caches its inverse
		# per physics frame, so it can still reflect the earlier hit-resolution pose.
		for info in heads:
			for hu in target.rig.hurtboxes:
				if hu.zone == "head" and String(hu.limb) == String(info["limb"]):
					info["driver_hand_current_sdf_m"] = _capture_shape_sdf(hu, driver_hand)
					info["skin_hand_current_sdf_m"] = _capture_shape_sdf(hu, skin_hand)
					info["attachment_current_sdf_m"] = _capture_shape_sdf(hu, attached)
		retarget = {"driver_hand_world": _vec3(driver_hand), "skin_hand_world": _vec3(skin_hand),
			"hand_joint_delta_m": driver_hand.distance_to(skin_hand),
			"driver_head_world": _vec3(driver_head), "skin_head_world": _vec3(skin_head),
			"head_joint_delta_m": driver_head.distance_to(skin_head),
			"driver_hand_projection": _projection(driver_hand), "skin_hand_projection": _projection(skin_hand),
			"driver_head_projection": _projection(driver_head), "skin_head_projection": _projection(skin_head)}
	var s: Dictionary = attacker.atk.get("s", {})
	var k: float = attacker.atk.get("k", 1.0)
	return {"limb": limb, "sampled_shapes": sampled_shapes, "retarget_joint_origins": retarget, "forearm_axis": forearm_axis, "attack_time_s": float(attacker.atk.get("t", 0.0)),
		"early_window_start_s": float(s.get("w0", 0.0)) * k * 0.6,
		"window_end_s": float(s.get("w1", 0.0)) * k,
		"sampled_prior_world": _vec3(prior), "sampled_current_world": _vec3(sampled),
		"attachment_after_draw_world": _vec3(attached), "sampled_projection": _projection(sampled),
		"attachment_projection": _projection(attached), "head_hulls": heads}


## Fresh, post-draw signed distance for the diagnostic head/neck capsule or sphere.
func _capture_shape_sdf(hu, world: Vector3) -> float:
	var xf: Transform3D = hu.shape_node.global_transform
	var q: Vector3 = Transform3D(xf.basis.orthonormalized(), xf.origin).affine_inverse() * world
	var shape: Shape3D = hu.shape_node.shape
	if shape is CapsuleShape3D:
		var cap := shape as CapsuleShape3D
		var half := maxf(cap.height * 0.5 - cap.radius, 0.0)
		q.y -= clampf(q.y, -half, half)
		return q.length() - cap.radius
	if shape is SphereShape3D:
		return q.length() - (shape as SphereShape3D).radius
	return 9.0


func _arm_clear_record(f) -> Dictionary:
	var node := f.rig.skeleton.get_node_or_null("GloveClear") as Node
	if node == null or node.get("last_forearm_pen_before") == null:
		return {}
	return {"before_m": node.get("last_forearm_pen_before"), "after_m": node.get("last_forearm_pen_after"),
		"corrections": node.get("correction_count"), "recovery_glove_moves": node.get("recovery_glove_count")}


func _projection(world_point: Vector3) -> Dictionary:
	var behind := capture_cam.is_position_behind(world_point)
	var pixel := capture_cam.unproject_position(world_point)
	var rect := root.get_viewport().get_visible_rect()
	return {
		"pixel": [pixel.x, pixel.y],
		"behind": behind,
		"in_viewport": (not behind) and rect.has_point(pixel),
	}


func _camera_record() -> Dictionary:
	var vs := root.get_viewport().get_visible_rect().size
	var r := capture_cam.rotation_degrees
	return {
		"position": _vec3(capture_cam.global_position),
		"rotation_degrees": [r.x, r.y, r.z],
		"forward": _vec3(-capture_cam.global_basis.z),
		"up": _vec3(capture_cam.global_basis.y),
		"fov_degrees": capture_cam.fov,
		"near": capture_cam.near,
		"far": capture_cam.far,
		"projection": capture_cam.projection,
		"keep_aspect": capture_cam.keep_aspect,
		"viewport_pixels": [vs.x, vs.y],
		"view": view,
		"yaw_degrees": orbit_current_yaw if orbit_enabled else _effective_yaw_degrees(),
		"elevation_degrees": elevation_degrees,
		"camera_side": camera_side,
		"side": -1 if camera_side == "left" else 1,
		"framing": "fullbody" if fullbody else "knee-to-head",
		"static": not orbit_enabled,
		"orbit_approximation": {"start_yaw_degrees": orbit_start_yaw, "end_yaw_degrees": orbit_end_yaw,
			"start_time_s": orbit_start_time, "end_time_s": orbit_end_time,
			"return_yaw_degrees": orbit_return_yaw, "return_time_s": orbit_return_time} if orbit_enabled else {},
	}


func _input_record(inp) -> Dictionary:
	var strikes: Array = []
	for s in inp.strikes:
		strikes.append(String(s))
	return {
		"move": [inp.move.x, inp.move.y],
		"block": inp.block,
		"body": inp.body,
		"duck": inp.duck,
		"shell": inp.shell,
		"slip": inp.slip,
		"lean": [inp.lean.x, inp.lean.y],
		"lean_mod": inp.lean_mod,
		"backstep": inp.backstep,
		"strikes": strikes,
		"taunt": inp.taunt,
		"shove": inp.shove,
	}


func _schedule(seq_name: String) -> Array:
	var rows: Array = []
	var field := ""
	match seq_name:
		"slip_l":
			field = "lean=(%s,0)" % str(amplitude)
		"slip_r":
			field = "lean=(-%s,0)" % str(amplitude)
		"counter_l":
			field = "analog left ramp to %s over %ss" % [str(amplitude), str(counter_analog_ramp)] if counter_analog_ramp > 0.0 else "slip=+1"
		"counter_r":
			field = "analog right ramp to %s over %ss" % [str(amplitude), str(counter_analog_ramp)] if counter_analog_ramp > 0.0 else "slip=-1"
		"back", "counter_back":
			field = "lean=(0,-1)"
		"forward":
			field = "lean=(0,%s)" % str(amplitude)
		"duck":
			field = "duck=true"
		"circle":
			field = "lean=(cos(phase),sin(phase))*0.8; phase traverses 0..TAU over hold"
	if force_block:
		field += "; block=true"
	rows.append({"time": INPUT_START, "target": "defender", "input": field})
	if COUNTER_SCENARIOS.has(seq_name):
		rows.append({"time": OPPONENT_STRIKE, "target": "opponent", "input": _opponent_strike_tag(seq_name)})
		rows.append({"time": COUNTER_INPUT, "target": "defender", "input": "%s (lean held)" % counter_tag})
		if chain_punch:
			rows.append({"time": COUNTER_INPUT + 0.30, "target": "defender", "input": "LJab (queued follow-up)"})
	rows.append({"time": INPUT_RELEASE, "target": "defender", "input": "release"})
	return rows


func _snap_point(bone_name: String, fallback: Vector3) -> Vector3:
	if bone_snap.has(bone_name):
		return bone_snap[bone_name]
	var sk := _skeleton(defender)
	if sk != null:
		var idx := sk.find_bone(bone_name)
		if idx >= 0:
			return sk.global_transform * sk.get_bone_global_pose(idx).origin
	return fallback


func _skeleton(f: Node3D) -> Skeleton3D:
	if f == null or f.get("rig") == null:
		return null
	return f.rig.skeleton as Skeleton3D


func _configure_window() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(width, height)


func _opponent_for(id: String) -> String:
	if id.begins_with("meshy_"):
		return "meshy_viper" if id == "meshy_anvil" else "meshy_anvil"
	return "viper" if id == "anvil" else "anvil"


func _write_json(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("could not open manifest for writing: " + path)
		return false
	file.store_string(JSON.stringify(data, "\t", true))
	file.close()
	return true


static func _vec3(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


func _fail(message: String) -> void:
	push_error("capture_fn_match: " + message)

