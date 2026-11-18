class_name FightCamera
extends Camera3D
## Side-on broadcast fight camera (spec section 10.1).
## - tracks the midpoint of both fighters with critically damped springs
## - sits on the fight axis normal, distance grows with separation, keeps its current side
## - always ends up outside the ring ropes
## - hit kick (roll + shove), knockdown pull-out/low angle, KO slow orbit
## Usage: cam.track(a, b); cam.bind_match(match_node); cam.arena = arena (optional).

## Fight Night Champion model: a broadcast side view at a fixed chest height; the distance only breathes gently with the
## separation; the view yaw is perpendicular to the fighters' line but only re-aims once the line has turned past a
## dead-zone, and then eases round very slowly (time constant ~1 s); the look-at point has its own small dead-zone.
const TARGET_HEIGHT := 1.0
const CAM_HEIGHT := 1.5        ## camera eye height (chest / shoulder)
const LOOK_HEIGHT := 1.15      ## look-at height
const DIST_BASE := 3.9
const DIST_PER_GAP := 0.35
const DIST_MIN := 3.9
const DIST_MAX := 5.6
const OMEGA_CENTRE := 1.5
const OMEGA_DIST := 1.2
const OMEGA_YAW := 9.0        ## critically damped (~0.11 s): the shot stays square to the fighters
const YAW_MAX_SPEED := 1.4     ## rad/s cap (~80 deg/s): the side view keeps up with the fighters, never whips (was 2.6 = 149 deg/s)
const LINE_RATE := 14.0         ## 1/s low-pass on the fighters' line angle at range
const LINE_RATE_CLOSE := 4.0   ## ... and in a clinch
const LINE_VEL_RATE := 1.5     ## 1/s low-pass on the pair's circling speed (fed forward so a steady circle is followed with no lag)
const LINE_VEL_MAX := 0.9      ## rad/s cap on that speed (~50 deg/s)
const CENTRE_DEADZONE := 0.50  ## m the pair can wander around the look-at point before it follows
const KICK_OMEGA := 11.0
const OUTSIDE_LIMIT := 3.75

const ImpactModel := preload("res://scripts/camera/impact_model.gd")
const ImpactPost := preload("res://scripts/fx/impact_post.gd")
const ImpactSpray := preload("res://scripts/fx/impact_spray.gd")
## How much of the rock push-in is re-centred on the victim's head (0 = zoom about screen centre like the web build).
const ROCK_PIVOT_WEIGHT := 0.5
const HEAD_HEIGHT := 1.55

enum Mode { LIVE, KNOCKDOWN, KO }

## Scales every shake/kick (reduced-motion setting uses 0.15).
@export var motion_scale := 1.0

var arena: Arena
var mode: int = Mode.LIVE

var _a: Node3D
var _b: Node3D
var _centre := Vector3(0, TARGET_HEIGHT, 0)
var _centre_v := Vector3.ZERO
var _dist := 7.1
var _dist_v := 0.0
var _yaw := 0.0
var _yaw_v := 0.0
var _goal_yaw := 0.0
var _line_yaw := 0.0
var _line_vel := 0.0   ## rad/s the fighters' line is turning (smoothed)
var _line_raw := 0.0
var _centre_goal := Vector3(0, TARGET_HEIGHT, 0)
var _extra := 0.0
var _extra_v := 0.0
var _side := -1.0  # -1 puts P1 (index 0, spawns at -x) on screen-left
var _axis := Vector3.RIGHT
var _first := true
# impulse springs
var _roll := 0.0
var _roll_v := 0.0
var _shove := Vector2.ZERO  # x = lateral (screen right), y = pull-back
var _shove_v := Vector2.ZERO
var _fov_kick := 0.0
var _fov_kick_v := 0.0
var _shake := 0.0
var _shake_gain := 0.03   ## metres of positional jitter at full shake; a knockdown punch is heavier
var _down_idx := -1       ## fighter index on the canvas (frames the count)
# mode state
var _mult := 1.0
var _mult_v := 0.0
var _low := 0.0
var _low_v := 0.0
var _orbit := 0.0
var _mode_timer := 0.0
var _bound: Node = null
## Impact / rocked presentation (web impact.js port): scale push-in, roll, shift, blur; post pass + sweat/spit.
var impact := ImpactModel.new()
var post: CanvasLayer


func _ready() -> void:
	fov = 42.0
	near = 0.1
	far = 120.0
	make_current()
	post = ImpactPost.new()
	post.name = "ImpactPost"
	add_child(post)


func track(a: Node3D, b: Node3D) -> void:
	_a = a
	_b = b
	_first = true
	if is_inside_tree():
		_process(1.0 / 60.0)   # place the camera now: the first rendered frame showed it at its default spot behind the ropes


func bind_match(m: Node) -> void:
	_bound = m
	if m.has_signal("hit_landed"):
		m.hit_landed.connect(_on_hit)
	if m.has_signal("knockdown"):
		m.knockdown.connect(_on_knockdown)
	if m.has_signal("clash"):
		m.clash.connect(_on_clash)
	if m.has_signal("count_tick"):
		m.count_tick.connect(_on_count_tick)
	if m.has_signal("round_started"):
		m.round_started.connect(_on_round_started)
	if m.has_signal("match_ended"):
		m.match_ended.connect(_on_match_ended)
	if m.has_signal("fighter_state_changed"):
		m.fighter_state_changed.connect(_on_fighter_state)   # fatigue pass: rocked camera kick


# --- events -----------------------------------------------------------------------------

func _on_round_started(_r: int) -> void:
	mode = Mode.LIVE
	_orbit = 0.0
	_mode_timer = 0.0
	impact.reset()
	if post:
		post.clear()


func _on_count_tick(_i: int, _n: int) -> void:
	if mode == Mode.KNOCKDOWN:
		_mode_timer = 2.0


func _on_fighter_state(i: int, state: String) -> void:
	if state == "rocked":
		# hit_landed carries the quality; this covers rocks that arrive without a hit (the model drops the duplicate)
		impact.consume({"attacker": 1 - i, "kind": "rock", "quality": 1.0, "dir_sign": _kick_sign(float(1 - i))})


func _on_knockdown(i: int) -> void:
	if mode == Mode.KO:
		return
	mode = Mode.KNOCKDOWN
	_mode_timer = 3.0
	_down_idx = i
	impact.release()   # the knockdown shot takes over (web: fall shot overrides rock)
	# the knockdown punch itself: a heavy kick (roll + shove + FOV punch) and a hard shake, then the rope bump
	var k := motion_scale
	var sgn := _kick_sign(float(1 - i))
	_roll_v += sgn * deg_to_rad(11.0) * KICK_OMEGA * 2.718 * k
	_shove_v += Vector2(sgn * 0.09 * KICK_OMEGA * 2.718 * 0.25 * k, 0.1 * KICK_OMEGA * 0.25 * k)
	_fov_kick_v += 1.6 * KICK_OMEGA * k
	_shake = 1.0 * k
	_shake_gain = 0.075


func _on_match_ended(result: Dictionary) -> void:
	var method := String(result.get("method", ""))
	if method == "KO" or method == "TKO":
		mode = Mode.KO
		_mode_timer = 0.0
		impact.release()
	else:
		mode = Mode.LIVE


## Glove clash (exchange): a small, short shake, no hit stop.
func _on_clash(_pos: Vector3) -> void:
	_shake = maxf(_shake, 0.10)


func _on_hit(attacker: int, info: Dictionary) -> void:
	var cue := ImpactModel.cue_for_hit(info)
	var sgn := _kick_sign(float(attacker))
	impact.consume({"attacker": attacker, "kind": cue["kind"], "quality": cue["quality"], "dir_sign": sgn})
	var pos: Variant = info.get("position", null)
	var uv := Vector2(0.5, 0.4)
	var have_pos := pos is Vector3
	if have_pos and is_inside_tree() and not is_position_behind(pos):
		var vs := get_viewport().get_visible_rect().size
		var sp := unproject_position(pos)
		uv = Vector2(clampf(sp.x / maxf(vs.x, 1.0), 0.0, 1.0), clampf(sp.y / maxf(vs.y, 1.0), 0.0, 1.0))
	if post and not bool(cue["block"]) and float(cue["fx"]) > 0.0:
		post.hit(float(cue["fx"]), bool(cue["head"]), sgn, uv, cue["kind"] == "rock")
	if (int(cue["sweat"]) > 0 or int(cue["spit"]) > 0) and have_pos:
		var parent: Node = _bound if _bound is Node3D else get_parent()
		var d := Vector3.ZERO
		var from := _a if attacker == 0 else _b
		var to := _b if attacker == 0 else _a
		if from != null and to != null:
			d = to.global_position - from.global_position
			d.y = 0.0
		ImpactSpray.emit(parent, pos, d + Vector3(0, 0.15, 0), int(cue["sweat"]), int(cue["spit"]))


func _kick_sign(attacker: float) -> float:
	## +1 when the punch travels towards screen-right.
	if _a == null or _b == null:
		return 1.0
	var from := _a if int(attacker) == 0 else _b
	var to := _b if int(attacker) == 0 else _a
	var dirv := to.global_position - from.global_position
	dirv.y = 0.0
	var right := global_transform.basis.x
	return 1.0 if dirv.dot(right) >= 0.0 else -1.0


# --- spring maths ------------------------------------------------------------------------

static func _crit(x: float, v: float, target: float, omega: float, dt: float) -> Vector2:
	var f := 1.0 + 2.0 * dt * omega
	var oo := omega * omega
	var hoo := dt * oo
	var hhoo := dt * hoo
	var det := 1.0 / (f + hhoo)
	var nx := (f * x + dt * v + hhoo * target) * det
	var nv := (v + hoo * (target - x)) * det
	return Vector2(nx, nv)


func _crit3(x: Vector3, v: Vector3, target: Vector3, omega: float, dt: float) -> Array:
	var rx := _crit(x.x, v.x, target.x, omega, dt)
	var ry := _crit(x.y, v.y, target.y, omega, dt)
	var rz := _crit(x.z, v.z, target.z, omega, dt)
	return [Vector3(rx.x, ry.x, rz.x), Vector3(rx.y, ry.y, rz.y)]


# --- frame -------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _a == null or _b == null or not is_instance_valid(_a) or not is_instance_valid(_b):
		return
	var dt := minf(delta, 1.0 / 20.0)
	var pa := _focus(_a)
	var pb := _focus(_b)
	var mid := (pa + pb) * 0.5
	var flat := Vector3(pb.x - pa.x, 0.0, pb.z - pa.z)
	var gap := flat.length()
	var live := mode == Mode.LIVE
	if gap >= 0.22 and mode != Mode.KNOCKDOWN:   # during the count the shot stays put while the other fighter walks to his corner
		_axis = flat / gap
	# the fighters' line, low-passed so a clinch spinning round does not whip the shot
	var line := atan2(_axis.x, _axis.z)
	if _first:
		_line_yaw = line
		_line_raw = line
		_line_vel = 0.0
	else:
		# (in a clinch the line is ill-defined and swings with every step, so it is filtered much harder there)
		var rate := lerpf(LINE_RATE_CLOSE, LINE_RATE, smoothstep(0.9, 2.0, gap))
		# plus the pair's circling speed, heavily smoothed, fed forward: the low-pass alone trailed a steady circle on the
		# inside by ~10 deg and the shot went oblique
		var raw_v := clampf(angle_difference(_line_raw, line) / maxf(dt, 0.001), -3.0, 3.0) if live else 0.0
		_line_vel = clampf(lerpf(_line_vel, raw_v, 1.0 - exp(-LINE_VEL_RATE * dt)), -LINE_VEL_MAX, LINE_VEL_MAX)
		_line_raw = line
		_line_yaw += angle_difference(_line_yaw, line) * (1.0 - exp(-rate * dt)) + _line_vel * dt
	var axis_s := Vector3(sin(_line_yaw), 0.0, cos(_line_yaw))

	# Mode bookkeeping
	if mode == Mode.KNOCKDOWN:
		# stay on the count until both fighters are free again, then ease back out
		if _any_acute_down():
			_mode_timer = 0.9
		else:
			_mode_timer -= dt
		if _mode_timer <= 0.0:
			mode = Mode.LIVE
			_down_idx = -1
			live = true
	if mode == Mode.KO:
		_orbit += 0.42 * dt

	# Camera side: keep current unless the pair is clearly on the far side of the ring from the camera
	var normal := Vector3(axis_s.z, 0.0, -axis_s.x)
	# Fight Night: the camera never swaps sides mid-fight, so P1 always stays on screen-left (the ropes and posts
	# between camera and fighters fade out instead, arena.update_camera)
	var cam_dir := normal * _side
	var want_yaw := atan2(cam_dir.x, cam_dir.z) + _orbit
	# Fight Night model: a broadcast side view kept square to the fighters' (filtered) line
	_goal_yaw = want_yaw

	# Targets
	var tgt_mult := 1.0
	var tgt_low := 0.0
	var tgt_y := LOOK_HEIGHT
	match mode:
		Mode.KNOCKDOWN:
			tgt_mult = 0.95
			tgt_low = 1.0
			tgt_y = 0.5
		Mode.KO:
			tgt_mult = 0.78
			tgt_low = 1.0
			tgt_y = 0.95
	var tgt_centre := Vector3(mid.x, tgt_y, mid.z)
	var frame_gap := gap
	if mode == Mode.KNOCKDOWN and _down_idx >= 0:
		# low angle on the fighter on the canvas, the standing fighter (in his corner) kept in shot
		var dn := _a if _down_idx == 0 else _b
		var up := _b if _down_idx == 0 else _a
		var wgt := 0.62
		var c := _focus(dn).lerp(_focus(up), 1.0 - wgt)
		tgt_centre = Vector3(c.x, tgt_y, c.z)
		frame_gap = minf(gap, 4.2) * 0.8
	var tgt_dist := clampf(DIST_BASE + DIST_PER_GAP * frame_gap, DIST_MIN, DIST_MAX)

	if _first:
		_first = false
		_centre = tgt_centre
		_centre_goal = tgt_centre
		_centre_v = Vector3.ZERO
		_dist = tgt_dist
		_yaw = _goal_yaw
		_mult = tgt_mult
		_low = tgt_low
	else:
		# the look-at point only follows once the pair has left a small zone around it (a dead-zone like the yaw)
		if live:
			var off := Vector3(tgt_centre.x - _centre_goal.x, 0.0, tgt_centre.z - _centre_goal.z)
			if off.length() > CENTRE_DEADZONE:
				_centre_goal += off - off.normalized() * CENTRE_DEADZONE
			_centre_goal.y = tgt_y
		else:
			_centre_goal = tgt_centre
		var c3 := _crit3(_centre, _centre_v, _centre_goal, OMEGA_CENTRE if live else 3.4, dt)
		_centre = c3[0]
		_centre_v = (c3[1] as Vector3).limit_length(2.2 if live else 4.0)
		var d := _crit(_dist, _dist_v, tgt_dist, OMEGA_DIST, dt)
		_dist = d.x
		_dist_v = clampf(d.y, -0.9, 0.9)
		var err := angle_difference(_yaw, _goal_yaw)
		var yw := _crit(0.0, _yaw_v, err, OMEGA_YAW if live else 2.0, dt)
		_yaw += yw.x
		var vmax := YAW_MAX_SPEED if live else (2.0 if mode == Mode.KO else 1.0)
		_yaw_v = clampf(yw.y, -vmax, vmax)
		var m := _crit(_mult, _mult_v, tgt_mult, 2.0, dt)
		_mult = m.x
		_mult_v = m.y
		var l := _crit(_low, _low_v, tgt_low, 3.5, dt)
		_low = l.x
		_low_v = l.y

	var r := _crit(_roll, _roll_v, 0.0, KICK_OMEGA, dt)
	_roll = r.x
	_roll_v = r.y
	var sx := _crit(_shove.x, _shove_v.x, 0.0, KICK_OMEGA, dt)
	var sy := _crit(_shove.y, _shove_v.y, 0.0, KICK_OMEGA, dt)
	_shove = Vector2(sx.x, sy.x)
	_shove_v = Vector2(sx.y, sy.y)
	var fk := _crit(_fov_kick, _fov_kick_v, 0.0, KICK_OMEGA, dt)
	_fov_kick = fk.x
	_fov_kick_v = fk.y
	_shake = move_toward(_shake, 0.0, dt * 3.0)
	if _shake <= 0.001:
		_shake_gain = 0.03
	impact.step(delta)

	# Place the camera: fixed chest height, no roll of its own
	var dir_h := Vector3(sin(_yaw), 0.0, cos(_yaw))
	var dist := _dist * _mult
	var height := lerpf(CAM_HEIGHT - LOOK_HEIGHT, 0.25, _low * 0.8)
	var pos := _centre + dir_h * dist + Vector3(0, height, 0)
	# Stay outside the ropes: slide back along the view direction until clear of the ring (continuous, then eased)
	var need := _clear_distance(pos, dir_h)
	var ex := _crit(_extra, _extra_v, need, 4.0, dt)
	_extra = maxf(ex.x, 0.0)
	_extra_v = ex.y
	pos += dir_h * maxf(_extra, need if _extra < need else 0.0)   # never inside the ropes, even while the ease catches up
	pos.y = maxf(pos.y, 0.35)
	var look := _centre
	# shake (small positional jitter) + shove along camera axes
	var right := dir_h.cross(Vector3.UP).normalized() * -1.0
	pos += right * _shove.x + dir_h * _shove.y
	if _shake > 0.001:
		pos += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * _shake_gain * _shake
	global_position = pos
	look_at(look, Vector3.UP)
	_apply_presentation()

	if arena:
		arena.update_camera(pos, look)


## Distance to slide `pos` along `dir` (>= 0) until max(|x|, |z|) >= OUTSIDE_LIMIT. Continuous in pos and dir.
static func _clear_distance(pos: Vector3, dir: Vector3) -> float:
	var best := INF
	for ax in [[pos.x, dir.x], [pos.z, dir.z]]:
		var p: float = ax[0]
		var d: float = ax[1]
		if absf(p) >= OUTSIDE_LIMIT:
			return 0.0
		if absf(d) > 1e-4:
			best = minf(best, (OUTSIDE_LIMIT - signf(d) * p) / absf(d))
	return minf(best, 6.0)


## Impact presentation on top of the tracked shot (web composeFightPresentation + ImpactBlur): lens scale via fov,
## roll about the view axis, image shift as a small camera yaw/pitch in rolled screen axes, then the post pass.
func _apply_presentation() -> void:
	var base_fov := 42.0 + _fov_kick
	var motion := motion_scale
	var scale := 1.0 + (impact.image_scale - 1.0) * motion
	var roll_rad := deg_to_rad(impact.roll_deg) * motion - _roll   # web rotateZ sign; legacy knockdown spring kept
	var vs := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(1280, 720)
	var aspect := vs.x / maxf(vs.y, 1.0)
	# victim's head in NDC on the un-modified frame (rock push re-centres towards it)
	var piv := Vector2.ZERO
	var focus := impact.rock_focus * motion
	if focus > 0.0 and impact.pivot_victim >= 0 and is_inside_tree():
		var victim: Node3D = _a if impact.pivot_victim == 0 else _b
		if victim != null and is_instance_valid(victim):
			fov = base_fov
			var head := victim.global_position + Vector3(0, HEAD_HEIGHT, 0)
			if not is_position_behind(head):
				var sp := unproject_position(head)
				piv = Vector2(clampf((sp.x / vs.x - 0.5) * 2.0, -1.0, 1.0), clampf((0.5 - sp.y / vs.y) * 2.0, -1.0, 1.0))
	fov = ImpactModel.fov_for_scale(base_fov, scale)
	if absf(roll_rad) > 1e-6:
		rotate_object_local(Vector3.BACK, roll_rad)
	var push := 1.0 + (ImpactModel.ROCK_SCALE - 1.0) * focus
	var dx := 2.0 * impact.shift_x * motion + ROCK_PIVOT_WEIGHT * (1.0 - push) * piv.x
	var dy := -2.0 * impact.shift_y * motion + ROCK_PIVOT_WEIGHT * (1.0 - push) * piv.y
	var ht := tan(deg_to_rad(fov) * 0.5)
	if absf(dx) > 1e-6:
		rotate_object_local(Vector3.UP, atan(dx * ht * aspect))
	if absf(dy) > 1e-6:
		rotate_object_local(Vector3.RIGHT, atan(-dy * ht))
	if post:
		var rocked_now := false
		for f in [_a, _b]:
			if f != null and is_instance_valid(f) and f.get("rocked") == true:
				rocked_now = true
		post.set_state(get_process_delta_time(), impact.blur * motion, impact.blur_dir * Vector2(1, 1), roll_rad, 42.0 - fov, rocked_now)


## Ground position to frame for a fighter: a ragdolled body lies away from its capsule, so follow the body.
func _focus(f: Node3D) -> Vector3:
	if f.has_method("body_focus_position"):
		var p: Vector3 = f.body_focus_position()
		return Vector3(p.x, f.global_position.y, p.z)
	return f.global_position


func _any_acute_down() -> bool:
	for f in [_a, _b]:
		if f != null and f.has_method("is_acute_down") and f.is_acute_down():
			return true
	return false
