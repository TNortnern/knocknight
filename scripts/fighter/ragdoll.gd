extends RefCounted
## Physical ragdoll of one fighter: a PhysicalBoneSimulator3D with 17 PhysicalBone3D bodies built procedurally on the
## fighter's Skeleton3D (sizes measured from the rest pose, so both models get a fitting body).
##
## Layout (rest pose is a T-pose with identity bone bases, skeleton space = bone space):
##   hip(box) > abdomenLower(box) > chestLower(box) > neckLower(capsule) > head(sphere)
##   chestLower > l/rShldrBend(capsule, cone) > l/rForearmBend(capsule, hinge) > l/rHand(capsule, cone)
##   hip > l/rThighBend(capsule, cone) > l/rShin(capsule, hinge) > l/rFoot(box, hinge)
## Total mass 81.2 kg. Bodies live on their own layers and collide with the world only (floor + ring walls) plus each
## other across the torso / limb groups; they never touch the fighters' capsules, the standing foe is kept clear by
## Fighter._separate_from_downed.
##
## Lifecycle: build() once, track() every frame while animated (per-body velocities), begin() at a KO / knockdown
## (starts the simulation from the animated pose with that velocity, then the punch impulse), settled() when at rest,
## capture_pose() + stop() for the get-up blend (ragdoll_blend.gd), reset() for a new round.

const RagdollBlend := preload("res://scripts/fighter/ragdoll_blend.gd")
const KnockdownMotion := preload("res://scripts/fighter/knockdown_motion.gd")

const LAYER_TORSO := 1 << 8     # physics layer 9
const LAYER_LIMB := 1 << 9      # physics layer 10
const WORLD := 1 << 0
# pose polish: selective self-collision. chest / abdomen sit on LAYER_CORE, each arm (forearm + hand) on its own FORE
# layer, each leg (thigh + shin) on its own LEG layer. Group masks start out WORLD-only; _enable_groups() adds the bits
# that make arm <-> core and leg <-> leg collide only once the two groups are clear of each other, so the guard pose
# never pops. (Collision exceptions between PhysicalBone3D bodies are not honoured by Jolt, masks are.)
const LAYER_CORE := 1 << 10
const LAYER_FORE_L := 1 << 11
const LAYER_FORE_R := 1 << 12
const LAYER_LEG_L := 1 << 13
const LAYER_LEG_R := 1 << 14
const GROUPS := [
	{"a": ["lForearm", "lHand"], "b": ["abdomen", "chest"], "a_layer": LAYER_FORE_L, "b_layer": LAYER_CORE},
	{"a": ["rForearm", "rHand"], "b": ["abdomen", "chest"], "a_layer": LAYER_FORE_R, "b_layer": LAYER_CORE},
	{"a": ["lThigh", "lShin"], "b": ["rThigh", "rShin"], "a_layer": LAYER_LEG_L, "b_layer": LAYER_LEG_R},
]
const PAIR_MARGIN := 0.012      ## m of clearance before a pair's exception is lifted

## One entry per body. `from`/`to` are bones (rest positions) giving the segment; `shape` box / capsule / sphere;
## `joint` cone / hinge / none; `axis` hinge axis in skeleton rest space (flexion = positive about it).
const BODIES := [
	{"id": "pelvis", "bone": "hip", "parent": "", "shape": "box", "size": Vector3(0.34, 0.19, 0.21), "centre_off": Vector3(0, -0.012, -0.005), "mass": 11.5, "group": "torso"},
	{"id": "abdomen", "bone": "abdomenLower", "parent": "pelvis", "from": "abdomenLower", "to": "chestLower", "shape": "box", "size": Vector3(0.31, 0.0, 0.20), "len_add": 0.02, "mass": 6.5, "group": "torso",
		"joint": "cone", "swing": 14.0, "twist": 10.0},
	{"id": "chest", "bone": "chestLower", "parent": "abdomen", "from": "chestLower", "to": "neckLower", "shape": "box", "size": Vector3(0.34, 0.0, 0.23), "len_add": -0.03, "mass": 21.0, "group": "torso",
		"joint": "cone", "swing": 16.0, "twist": 12.0},
	{"id": "neck", "bone": "neckLower", "parent": "chest", "from": "neckLower", "to": "head", "shape": "capsule", "radius": 0.05, "len_add": 0.02, "mass": 2.0, "group": "torso",
		"joint": "cone", "swing": 22.0, "twist": 16.0},
	{"id": "head", "bone": "head", "parent": "neck", "shape": "sphere", "radius": 0.102, "centre_off": Vector3(0, 0.085, 0.02), "mass": 5.0, "group": "torso",
		"joint": "cone", "swing": 30.0, "twist": 22.0},
	{"id": "lUpperArm", "bone": "lShldrBend", "parent": "chest", "from": "lShldrBend", "to": "lForearmBend", "shape": "capsule", "radius": 0.052, "mass": 2.3, "group": "limb",
		"joint": "cone", "swing": 95.0, "twist": 50.0},
	{"id": "lForearm", "bone": "lForearmBend", "parent": "lUpperArm", "from": "lForearmBend", "to": "lHand", "shape": "capsule", "radius": 0.042, "mass": 1.4, "group": "limb",
		"joint": "hinge", "axis": Vector3(0, -1, 0), "range": Vector2(-4.0, 150.0)},
	{"id": "lHand", "bone": "lHand", "parent": "lForearm", "from": "lHand", "len": 0.11, "dir": Vector3(1, 0, 0), "shape": "capsule", "radius": 0.046, "mass": 0.5, "group": "limb",
		"joint": "cone", "swing": 55.0, "twist": 20.0},
	{"id": "rUpperArm", "bone": "rShldrBend", "parent": "chest", "from": "rShldrBend", "to": "rForearmBend", "shape": "capsule", "radius": 0.052, "mass": 2.3, "group": "limb",
		"joint": "cone", "swing": 95.0, "twist": 50.0},
	{"id": "rForearm", "bone": "rForearmBend", "parent": "rUpperArm", "from": "rForearmBend", "to": "rHand", "shape": "capsule", "radius": 0.042, "mass": 1.4, "group": "limb",
		"joint": "hinge", "axis": Vector3(0, 1, 0), "range": Vector2(-4.0, 150.0)},
	{"id": "rHand", "bone": "rHand", "parent": "rForearm", "from": "rHand", "len": 0.11, "dir": Vector3(-1, 0, 0), "shape": "capsule", "radius": 0.046, "mass": 0.5, "group": "limb",
		"joint": "cone", "swing": 55.0, "twist": 20.0},
	{"id": "lThigh", "bone": "lThighBend", "parent": "pelvis", "from": "lThighBend", "to": "lShin", "shape": "capsule", "radius": 0.082, "mass": 8.5, "group": "limb",
		"joint": "cone", "swing": 88.0, "twist": 28.0},
	{"id": "lShin", "bone": "lShin", "parent": "lThigh", "from": "lShin", "to": "lFoot", "shape": "capsule", "radius": 0.058, "mass": 3.8, "group": "limb",
		"joint": "hinge", "axis": Vector3(1, 0, 0), "range": Vector2(-3.0, 145.0)},
	{"id": "lFoot", "bone": "lFoot", "parent": "lShin", "shape": "box", "size": Vector3(0.095, 0.075, 0.26), "centre_off": Vector3(0, -0.026, 0.065), "mass": 1.1, "group": "limb",
		"joint": "hinge", "axis": Vector3(1, 0, 0), "range": Vector2(-45.0, 40.0)},
	{"id": "rThigh", "bone": "rThighBend", "parent": "pelvis", "from": "rThighBend", "to": "rShin", "shape": "capsule", "radius": 0.082, "mass": 8.5, "group": "limb",
		"joint": "cone", "swing": 88.0, "twist": 28.0},
	{"id": "rShin", "bone": "rShin", "parent": "rThigh", "from": "rShin", "to": "rFoot", "shape": "capsule", "radius": 0.058, "mass": 3.8, "group": "limb",
		"joint": "hinge", "axis": Vector3(1, 0, 0), "range": Vector2(-3.0, 145.0)},
	{"id": "rFoot", "bone": "rFoot", "parent": "rShin", "shape": "box", "size": Vector3(0.095, 0.075, 0.26), "centre_off": Vector3(0, -0.026, 0.065), "mass": 1.1, "group": "limb",
		"joint": "hinge", "axis": Vector3(1, 0, 0), "range": Vector2(-45.0, 40.0)},
]
const LEG_IDS := ["lThigh", "lShin", "lFoot", "rThigh", "rShin", "rFoot"]
const LINEAR_DAMP := 0.12
const ANGULAR_DAMP := 1.6
const LIMB_DAMP_MULT := {"neck": 1.8, "head": 1.5, "lUpperArm": 2.2, "rUpperArm": 2.2, "lForearm": 2.0, "rForearm": 2.0, "lHand": 2.0, "rHand": 2.0}
const MAX_TRACK_SPEED := 5.0
const SHIFT_LIMITS := 0.0
const GROUND_DRAG := 2.2       ## 1/s: horizontal speed lost per second by any body lying on the floor (friction the engine lacks)
const GROUND_SPIN_DRAG := 1.2  ## 1/s: same for spin of a body on the floor
## struck body -> the bodies that share its impact momentum
const IMPACT_GROUPS := {
	"head": ["head", "neck", "chest"], "neck": ["head", "neck", "chest"],
	"chest": ["chest", "abdomen", "neck", "head"], "abdomen": ["abdomen", "pelvis", "chest"], "pelvis": ["pelvis", "abdomen", "chest"],
}
const MAX_IMPACT_DV := 3.2     ## m/s cap of the impact velocity change
const ANCHOR_DAMP := 2.5       ## 1/s: pelvis horizontal speed bled off during the first ANCHOR_T s of a fall
const ANCHOR_T := 2.5
const ANCHOR_STEP := 0.12     ## m the hips may travel before the leash pulls
const ANCHOR_PULL := 60.0     ## 1/s leash stiffness
const LAT_DAMP := 4.0          ## 1/s: sideways speed bled off in a blow without a side
const TRACKED_KEEP := 0.5      ## share of the pre-KO pose velocity the bodies keep at the start of a fall
const FOOT_DRAG := 9.0         ## 1/s: extra horizontal drag on shins / feet touching the canvas (planted feet grip)
const GROUND_Y := 0.2          ## a body whose centre is lower than this counts as lying on the floor
const BODY_FRICTION := 1.0      ## the engine caps friction at 1.0 (floor is 1.0 too); GROUND_DRAG adds the rest
const CONTACT_MASS := 5.0      ## kg: effective striking mass behind the fist (impulse = this * fist speed * power)
const PITCH_WALK := 0.45       ## fall pitch per m/s the victim was walking in (towards the attacker) when the blow landed
const LEAN_NEUTRAL := 0.04    ## m: chest ahead of the hips in an upright guard
const PITCH_LEAN := 4.0        ## fall pitch per m of torso lean towards the attacker (chest ahead of the hips)
const PITCH_RATE := 2.2        ## rad/s of forward trunk pitch per unit of fall pitch
const PITCH_PUSH := 0.5        ## m/s of upper-body speed towards the attacker per unit of positive fall pitch
const STEER_PITCH_T := 1.1     ## s the fall's pitch / roll keeps steering the trunk
const PITCH_ACC := 2.5         ## m/s^2 along the facing direction per unit of fall pitch
const PITCH_SPIN := 12.0        ## rad/s^2 of trunk pitch per unit of fall pitch
const ROLL_ACC := 1.5          ## m/s^2 sideways per unit of fall roll
const ROLL_SPIN := 4.0         ## rad/s^2 of trunk roll per unit of fall roll
const LIE_UPRIGHT := 0.35      ## chest up-axis height below which the trunk counts as down
const LIE_DAMP := 6.0          ## 1/s spin damping of a trunk that is down
const ROLL_SIDE := 0.95        ## |fall roll| above which the body ends on a side
const PITCH_DOWN := 0.5        ## fall pitch above which the body ends face down
const PITCH_HOLD := 9.0         ## 1/s: how fast backward trunk spin is bled off in a fall that is not meant to end on the back
const PITCH_HOLD_RATE := 0.9   ## rad/s of forward trunk pitch a face-down fall keeps
const PITCH_HOLD_T := 1.0
const FADE_START := 0.8        ## s: the fall servos / steering start to fade
const FADE_END := 1.2          ## s: ... and are off
const FADE_ANGLE := 25.0       ## deg: chest within this of its resting side = done
const FLOOR_DAMP := 5.0        ## 1/s linear damping of a body whose hips are on the floor (ramped in over FLOOR_RAMP s)
const FLOOR_SPIN_DAMP := 7.0
const FLOOR_RAMP := 0.4
const LIE_SERVO_T := 2.0
const LIE_SERVO_MAX := 7.0
const LIE_SERVO_GAIN := 250.0
const SERVO_NUDGE := 0.6       ## base lean of the carry target (the trunk is nudged over even when upright)
const SERVO_MAX := 6.0         ## rad/s cap of the carry spin (a body lying flat needs a real swing to roll over)
const SERVO_GAIN := 70.0       ## rad/s^2 per unit of orientation error: how hard the trunk is carried to its resting side
const SERVO_T := 2.2           ## s the trunk is carried to its resting side
const ROLL_RATE := 1.6         ## rad/s of trunk roll about the attacker line per unit of fall roll
const ROLL_PUSH := 0.7         ## m/s sideways speed of the upper body per unit of fall roll
const UP_CAP := 0.10           ## m: pelvis / feet never rise more than this above where they stood when the blow landed
const SHOVE := 0.19            ## whole-body velocity gain per m/s of fist speed (the rest of the blow is carried by the struck body)

var skeleton: Skeleton3D
var simulator: PhysicalBoneSimulator3D
var blend: SkeletonModifier3D
var bones: Dictionary = {}      ## id -> PhysicalBone3D
var meta: Dictionary = {}       ## id -> {bone_idx, entry, axis (rest space), range}
var active := false             ## simulation running (any body)
var legs_free := true           ## false while the legs are still animation driven (the short buckle blend)
var sim_time := 0.0
var _legs_release_t := 0.0
var _still_t := 0.0
var _calm_t := 0.0
var _prev_pos: Dictionary = {}
var _prev_rot: Dictionary = {}
var _lin_vel: Dictionary = {}
var _ang_vel: Dictionary = {}
var _have_prev := false
var _paused_modifiers: Array = []
var _built := false
var _saved_pose: Dictionary = {}   ## bone index -> world Transform3D, captured for the get-up blend
var _last_start := {}
var _recipe := {}                  ## KnockdownMotion.RECIPES entry of the current fall
var _back := Vector3.RIGHT         ## horizontal unit: the way the body is driven (attacker -> victim)
var _lat := Vector3.BACK           ## horizontal unit, perpendicular to _back
var _side := 1.0                   ## +1 / -1: which way the blow carries the body sideways (along _lat)
var _toppled := false
var _anchor := Vector3.ZERO        ## pelvis position when the fall began
var _groups_on := {}               ## GROUPS index -> true once that group pair collides
var _rng := RandomNumberGenerator.new()
var _pitch := 0.0                  ## >0: the body tips forward (towards the attacker, face down), <0: back
var _outcome_dir := Vector2(-1.0, 0.0)  ## which way the trunk is carried over: x along the facing (+ face down), y sideways
var _fall_f := Vector3.RIGHT
var _on_target := false
var _hook_bias := 0.0              ## a hook carries the body to the side of the blow whatever way it ends up facing
var _floor_t := 0.0
var _roll := 0.0                   ## signed: the body rolls about the attacker line (onto a side)
var _rest_y: Dictionary = {}       ## id -> height of pelvis / feet when the fall began
var rng_seed := -1                 ## test hook: >= 0 seeds the fall randomness
var kind := ""                     ## fall kind of the current fall (diagnostics)


func build(sk: Skeleton3D) -> void:
	skeleton = sk
	simulator = PhysicalBoneSimulator3D.new()
	simulator.name = "RagdollSimulator"
	sk.add_child(simulator)
	for e in BODIES:
		var pb := _make_body(e)
		if pb != null:
			simulator.add_child(pb)
			bones[e["id"]] = pb
	blend = RagdollBlend.new()
	blend.name = "RagdollBlend"
	blend.ragdoll = self
	sk.add_child(blend)
	_built = true


func _rest(bone: String) -> Vector3:
	var i := skeleton.find_bone(bone)
	return skeleton.get_bone_global_rest(i).origin if i >= 0 else Vector3.ZERO


func _make_body(e: Dictionary) -> PhysicalBone3D:
	var bone_name: String = e["bone"]
	var bi := skeleton.find_bone(bone_name)
	if bi < 0:
		return null
	var bone_pos := _rest(bone_name)
	# segment: centre, direction (unit), length
	var dir := Vector3.UP
	var length := 0.0
	var centre := bone_pos
	if e.has("from"):
		var a := _rest(e["from"])
		var b: Vector3
		if e.has("to"):
			b = _rest(e["to"])
		else:
			b = a + (e["dir"] as Vector3).normalized() * float(e["len"])
		var d := b - a
		length = d.length()
		dir = d / maxf(length, 0.0001)
		length += float(e.get("len_add", 0.0))
		centre = (a + b) * 0.5
	if e.has("centre_off"):
		centre = bone_pos + (e["centre_off"] as Vector3)
		if e["shape"] == "box":
			dir = Vector3.UP
	# body frame: y along the segment (identity for upright bodies)
	var body_basis := Basis.IDENTITY
	if dir.dot(Vector3.UP) < 0.999:
		body_basis = Basis(Quaternion(Vector3.UP, dir))
	var pb := PhysicalBone3D.new()
	pb.name = "PB_" + String(e["id"])
	pb.bone_name = bone_name
	pb.body_offset = Transform3D(body_basis, centre - bone_pos)
	pb.mass = float(e["mass"])
	pb.friction = BODY_FRICTION
	pb.bounce = 0.0
	pb.linear_damp = LINEAR_DAMP
	pb.angular_damp = ANGULAR_DAMP * LIMB_DAMP_MULT.get(String(e["id"]), 1.0)   # muscle tone: arms / head do not whip
	pb.collision_layer = LAYER_TORSO if e["group"] == "torso" else LAYER_LIMB
	pb.collision_mask = WORLD   # limbs vs torso collisions overlap in the guard stance and pop the body at start
	var eid := String(e["id"])
	# selective self-collision: bodies carry a group layer; the masks that make groups collide are added at runtime by
	# _enable_groups() once the groups are clear of each other (see there)
	if eid == "abdomen" or eid == "chest":
		pb.collision_layer |= LAYER_CORE
	elif eid.ends_with("Forearm") or eid.ends_with("Hand"):
		pb.collision_layer |= LAYER_FORE_L if eid.begins_with("l") else LAYER_FORE_R
	elif eid.ends_with("Thigh") or eid.ends_with("Shin"):
		pb.collision_layer |= LAYER_LEG_L if eid.begins_with("l") else LAYER_LEG_R
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	match String(e["shape"]):
		"box":
			var sz: Vector3 = e["size"]
			if sz.y <= 0.0:
				sz.y = length
			var bx := BoxShape3D.new()
			bx.size = sz
			cs.shape = bx
		"capsule":
			var r: float = e["radius"]
			var cap := CapsuleShape3D.new()
			cap.radius = r
			cap.height = maxf(length + r, r * 2.0 + 0.001)
			cs.shape = cap
		"sphere":
			var sp := SphereShape3D.new()
			sp.radius = float(e["radius"])
			cs.shape = sp
	pb.add_child(cs)
	# joint
	var m := {"bone_idx": bi, "entry": e, "axis": Vector3.ZERO, "range": Vector2.ZERO}
	var jt := String(e.get("joint", "none"))
	if jt == "cone":
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
		# twist axis of a cone joint is the joint frame's x: lay it along the limb
		var jb := Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1))
		pb.joint_offset = Transform3D(jb, body_basis.inverse() * (bone_pos - centre))
		pb.set("joint_constraints/swing_span", float(e["swing"]))
		pb.set("joint_constraints/twist_span", float(e["twist"]))
		pb.set("joint_constraints/bias", 0.3)
		pb.set("joint_constraints/softness", 0.8)
		pb.set("joint_constraints/relaxation", 1.0)
	elif jt == "hinge":
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
		var axis: Vector3 = (e["axis"] as Vector3).normalized()
		var ab: Vector3 = body_basis.inverse() * axis
		var perp := ab.cross(Vector3.UP)
		if perp.length() < 0.1:
			perp = ab.cross(Vector3.RIGHT)
		perp = perp.normalized()
		# pose polish: the hinge turns about joint-frame Z, and positive = EXTENSION in this frame. With z = +axis the knee
		# could only hyperextend (-3 deg flexion limit): the legs were locked stilts that pivoted over the feet and kicked
		# out. z = -axis gives the intended flexion range 0..145 deg.
		var jb2 := Basis(perp, (-ab).cross(perp).normalized(), -ab)
		pb.joint_offset = Transform3D(jb2, body_basis.inverse() * (bone_pos - centre))
		pb.set("joint_constraints/angular_limit_enabled", true)
		var rg: Vector2 = e["range"]
		pb.set("joint_constraints/angular_limit_lower", rg.x)
		pb.set("joint_constraints/angular_limit_upper", rg.y)
		pb.set("joint_constraints/bias", 0.3)
		pb.set("joint_constraints/softness", 0.9)
		pb.set("joint_constraints/relaxation", 1.0)
		m["axis"] = axis
		m["range"] = rg
	meta[e["id"]] = m
	return pb


func total_mass() -> float:
	var t := 0.0
	for id in bones:
		t += (bones[id] as PhysicalBone3D).mass
	return t


## Torso / limb bone ids hit by a zone ("head" -> head, "body" -> chest or abdomen by height, "leg" -> thigh / shin).
func body_for_zone(zone: String, world_pos: Vector3, leg_side := "") -> String:
	if zone == "head":
		var dh: float = world_pos.distance_to(bones["head"].global_position)
		var dn: float = world_pos.distance_to(bones["neck"].global_position)
		return "head" if dh <= dn + 0.02 else "neck"
	if zone == "leg":
		var side := "l" if leg_side == "L" else "r"
		var ds: float = world_pos.distance_to(bones[side + "Shin"].global_position)
		var dt: float = world_pos.distance_to(bones[side + "Thigh"].global_position)
		return side + ("Shin" if ds < dt else "Thigh")
	var best := "chest"
	var bd := 1e9
	for id in ["abdomen", "chest", "pelvis"]:
		var d: float = world_pos.distance_to(bones[id].global_position)
		if d < bd:
			bd = d
			best = id
	return best


# ---------------------------------------------------------------- motion tracking (pre-KO velocities)
## Call every physics frame while the fighter is animated. Records per-body linear / angular velocity of the pose.
func track(dt: float) -> void:
	if not _built or active or dt <= 0.0:
		return
	var sg := skeleton.global_transform
	for id in bones:
		var bi: int = meta[id]["bone_idx"]
		var t: Transform3D = sg * skeleton.get_bone_global_pose(bi)
		var centre: Vector3 = t * (bones[id] as PhysicalBone3D).body_offset.origin
		var q := t.basis.orthonormalized().get_rotation_quaternion()
		if _have_prev:
			var v := (centre - (_prev_pos[id] as Vector3)) / dt
			_lin_vel[id] = (_lin_vel.get(id, Vector3.ZERO) as Vector3).lerp(v.limit_length(MAX_TRACK_SPEED), 0.6)
			var dq: Quaternion = q * (_prev_rot[id] as Quaternion).inverse()
			if dq.w < 0.0:
				dq = -dq
			var ang := dq.get_angle()
			var ax := dq.get_axis() if ang > 0.0001 else Vector3.ZERO
			_ang_vel[id] = (_ang_vel.get(id, Vector3.ZERO) as Vector3).lerp((ax * ang / dt).limit_length(12.0), 0.6)
		_prev_pos[id] = centre
		_prev_rot[id] = q
	_have_prev = true


# ---------------------------------------------------------------- start / stop
## Starts the simulation from the current animated pose. `hit`: {pos (world contact point), dir (unit travel of the
## fist), speed, zone, side, power (0..1.5), body_zone}. `buckle` seconds the legs stay animation driven.
func begin(hit: Dictionary, buckle := 0.12) -> void:
	if not _built or active:
		return
	active = true
	sim_time = 0.0
	_still_t = 0.0
	_calm_t = 0.0
	_on_target = false
	_floor_t = 0.0
	_last_start = hit
	_hold_modifiers(true)
	# joint limits are relative to the pose the joint is created in: re-centre them on the current angles
	for id in meta:
		var m: Dictionary = meta[id]
		if (m["entry"] as Dictionary).get("joint", "") == "hinge":
			var th := _hinge_angle(id) * SHIFT_LIMITS
			var rg: Vector2 = m["range"]
			(bones[id] as PhysicalBone3D).set("joint_constraints/angular_limit_lower", rg.x - th)
			(bones[id] as PhysicalBone3D).set("joint_constraints/angular_limit_upper", rg.y - th)
	var upper: Array[StringName] = []
	var legs: Array[StringName] = []
	for id in bones:
		if LEG_IDS.has(id):
			legs.append(StringName((bones[id] as PhysicalBone3D).bone_name))
		else:
			upper.append(StringName((bones[id] as PhysicalBone3D).bone_name))
	legs_free = buckle <= 0.0
	_legs_release_t = buckle
	simulator.physical_bones_start_simulation(upper if buckle > 0.0 else [])
	for id in bones:
		if buckle > 0.0 and LEG_IDS.has(id):
			continue
		var pb := bones[id] as PhysicalBone3D
		pb.linear_velocity = _lin_vel.get(id, Vector3.ZERO)
		pb.angular_velocity = _ang_vel.get(id, Vector3.ZERO)
	_reset_masks()
	_setup_fall(hit)
	_apply_hit(hit)
	_apply_recipe(hit)


func _hold_modifiers(hold: bool) -> void:
	if hold:
		_paused_modifiers.clear()
		for c in skeleton.get_children():
			var mod := c as SkeletonModifier3D
			if mod != null and mod != simulator and mod != blend and mod.active:
				mod.active = false
				_paused_modifiers.append(mod)
	else:
		for mod in _paused_modifiers:
			if is_instance_valid(mod):
				(mod as SkeletonModifier3D).active = true
		_paused_modifiers.clear()


## The punch: an impulse at the contact point of the struck body along the fist's travel direction, plus the share of
## the momentum that shoves the whole body (so the body is driven along the blow, not only the head).
func _apply_hit(hit: Dictionary) -> void:
	if hit.is_empty():
		return
	var dir: Vector3 = hit["dir"]
	var speed: float = hit["speed"]
	var power: float = hit.get("power", 1.0)
	var id: String = hit.get("body", "head")
	var pb: PhysicalBone3D = bones.get(id)
	if pb == null:
		return
	var contact: Vector3 = hit.get("pos", pb.global_position)
	# contact impulse (N s): effective striking mass 9 kg at the fist speed, scaled by power
	var p_contact := CONTACT_MASS * speed * power * float(_recipe.get("imp", 1.0))
	# an uppercut lifts the chin, but no blow launches a body: keep the vertical part of the impulse modest
	# (the lift of an uppercut is not a linear impulse, which launches the whole body: it is a torque about the neck / upper
	# chest below, so the head snaps back while the body stays on the canvas)
	var idir := Vector3(dir.x, clampf(dir.y, -0.45, 0.12), dir.z).normalized()
	# pose polish: the blow's momentum is spread over the struck body and its neighbours (their summed mass) instead of
	# one point impulse on a light body (a 25 N s hit on the 2 kg neck made 12 m/s and whipped the whole body off the floor)
	var group: Array = IMPACT_GROUPS.get(id, [id])
	var gmass := 0.0
	for gid in group:
		gmass += (bones[gid] as PhysicalBone3D).mass
	var gdv := minf(p_contact / maxf(gmass, 1.0), MAX_IMPACT_DV)
	for gid in group:
		var gb := bones[gid] as PhysicalBone3D
		if gb.is_simulating_physics():
			gb.linear_velocity += idir * gdv
		if gid == id:
			# off-centre contact: a little spin of the struck body from the lever arm
			var lever := (contact - gb.global_position)
			gb.angular_velocity += lever.cross(idir * gdv) * 6.0
	var lift := clampf(dir.y - 0.12, 0.0, 0.8)
	if lift > 0.0:
		var snap_ax := Vector3.UP.cross(_back)   # head thrown back, chin up
		var spin := lift * gdv * 4.0
		for gid in group:
			if gid == "head" or gid == "neck" or gid == "chest":
				var gb2 := bones[gid] as PhysicalBone3D
				if gb2.is_simulating_physics():
					gb2.angular_velocity += snap_ax * (spin * (1.0 if gid == "head" else (0.6 if gid == "neck" else 0.25)))
	# whole body shove: v = 0.28 * speed * power (m/s) on every simulated body, mass weighted by the contact distance
	var dv := Vector3(dir.x, dir.y * 0.25, dir.z) * (SHOVE * speed * power * float(_recipe.get("shove", 1.0)))   # shoved along the blow, hardly lifted
	for k in bones:
		var other := bones[k] as PhysicalBone3D
		if not other.is_simulating_physics():
			continue
		other.linear_velocity += dv
	# the shot also lifts / sinks the body a little along its vertical component (uppercut lifts, overhand drops)
	hit["applied"] = {"contact": p_contact, "dv": dv}


# ---------------------------------------------------------------- fall recipe (pose polish)
## Reads the blow: which way the body is driven, which side a hook carries it to, which recipe applies.
func _setup_fall(hit: Dictionary) -> void:
	kind = String(hit.get("kind", ""))
	_recipe = KnockdownMotion.RECIPES.get(kind, KnockdownMotion.RECIPES[KnockdownMotion.RECIPE_FALLBACK])
	_toppled = false
	_anchor = (bones["pelvis"] as PhysicalBone3D).global_position
	var back: Vector3 = hit.get("back", Vector3.ZERO)
	var d: Vector3 = hit.get("dir", Vector3.ZERO)
	if back.length() < 0.01:
		back = Vector3(d.x, 0.0, d.z)
	back.y = 0.0
	_back = back.normalized() if back.length() > 0.01 else Vector3.RIGHT
	_lat = Vector3(_back.z, 0.0, -_back.x)
	var lat_c := d.dot(_lat)
	if not bool(_recipe.get("lateral", false)) and d.length() > 0.01:
		# straight / upper / body blows drive the body along the line of the blow, not sideways
		hit["dir"] = (d - _lat * lat_c).normalized()
	if absf(lat_c) > 0.08:
		_side = signf(lat_c)
	else:
		# no lateral blow: the stance decides (lead foot side)
		var lf := bone_origin("lFoot")
		var rf := bone_origin("rFoot")
		_side = signf((lf - rf).dot(_back)) if absf((lf - rf).dot(_back)) > 0.02 else 1.0
	_roll_the_dice()


## What decides how the body ends up: the blow (recipe base pitch / roll), the victim's own momentum (walking into the
## blow tips him forward), his stance lean (chest ahead of the hips) and a little seeded randomness.
func _roll_the_dice() -> void:
	_rng.seed = rng_seed if rng_seed >= 0 else randi()
	var walk := 0.0
	for id in ["pelvis", "abdomen", "chest"]:
		walk -= (_lin_vel.get(id, Vector3.ZERO) as Vector3).dot(_back)
	walk = clampf(walk / 3.0, -1.5, 2.5)
	var chest_p := (bones["chest"] as PhysicalBone3D).global_position
	var pelvis_p := (bones["pelvis"] as PhysicalBone3D).global_position
	var lean := clampf((chest_p - pelvis_p).dot(-_back) - LEAN_NEUTRAL, -0.2, 0.3)
	var n1 := clampf(_rng.randfn(0.0, 1.0), -2.0, 2.0)
	var n2 := clampf(_rng.randfn(0.0, 1.0), -2.0, 2.0)
	_pitch = float(_recipe.get("pitch", 0.0)) + walk * PITCH_WALK * float(_recipe.get("walk_k", 1.0)) + lean * PITCH_LEAN + n1 * float(_recipe.get("pitch_noise", 0.5))
	_roll = _side * float(_recipe.get("roll", 0.0)) + n2 * float(_recipe.get("roll_noise", 0.4))
	# how it ends: the fall's pitch / roll pick the way the body settles (face down / on a side / face up); _steer_fall carries
	# the trunk there (momentum, floor contact and the legs still decide the details)
	_fall_f = -_back
	if absf(_roll) > ROLL_SIDE and _pitch < PITCH_DOWN + 0.4:
		_outcome_dir = Vector2(0.0, signf(_roll))   # (along the facing, sideways)
	elif _pitch > PITCH_DOWN:
		_outcome_dir = Vector2(1.0, 0.0)
	else:
		_outcome_dir = Vector2(-1.0, 0.0)
	_hook_bias = _side * float(_recipe.get("hook_side", 0.0))
	_rest_y.clear()
	for id in ["pelvis", "lFoot", "rFoot"]:
		_rest_y[id] = (bones[id] as PhysicalBone3D).global_position.y


## One-off velocity kicks of the recipe (spin, side carry, fold, head snap).
func _apply_recipe(hit: Dictionary) -> void:
	if _recipe.is_empty():
		return
	var power: float = hit.get("power", 1.0)
	var up := Vector3.UP
	# the footwork velocity the pose carried (stepping, leaning) is mostly lost: keep TRACKED_KEEP of it, and for blows
	# without a lateral component none of the sideways part
	var keep_lat: bool = bool(_recipe.get("lateral", false))
	for id in bones:
		var tb := bones[id] as PhysicalBone3D
		if not tb.is_simulating_physics():
			continue
		var tv := tb.linear_velocity
		var tl := _lat * tv.dot(_lat)
		tb.linear_velocity = (tv - tl) * TRACKED_KEEP + tl * (TRACKED_KEEP if keep_lat else 0.0) + Vector3(0, tv.y * (1.0 - TRACKED_KEEP), 0)
	var yaw: float = float(_recipe.get("yaw", 0.0))
	var side_v: float = float(_recipe.get("side_v", 0.0))
	var fold: float = float(_recipe.get("fold", 0.0))
	var snap: float = float(_recipe.get("snap", 0.0)) * (1.0 - clampf(_pitch, 0.0, 1.0) * 0.8)   # a body going forward is not thrown back
	var fold_axis := up.cross(-_back)   # rotating about this takes the head towards the attacker
	var snap_axis := up.cross(_back)    # ... and this takes it away (chin up, head thrown back)
	for id in ["pelvis", "abdomen", "chest", "neck", "head", "lUpperArm", "rUpperArm", "lForearm", "rForearm", "lHand", "rHand"]:
		var pb := bones[id] as PhysicalBone3D
		if not pb.is_simulating_physics():
			continue
		var upper: bool = id != "pelvis"
		if yaw != 0.0:
			var w := 0.45 if id == "pelvis" else (1.0 if id in ["chest", "abdomen"] else 1.25)
			pb.angular_velocity += up * (yaw * _side * w * power)
		if side_v != 0.0 and upper:
			pb.linear_velocity += _lat * (side_v * _side * power)
		if fold != 0.0 and id in ["abdomen", "chest", "neck", "head"]:
			pb.angular_velocity += fold_axis * (fold * (0.6 if id == "abdomen" else 1.0))
		if snap != 0.0 and id in ["neck", "head"]:
			pb.linear_velocity += (_back + up * 0.5) * (snap * (0.6 if id == "neck" else 1.0) * power)
			pb.angular_velocity += snap_axis * (snap * 2.2)
		if id in ["abdomen", "chest", "neck", "head"]:
			# fall pitch / roll (see _roll_the_dice): tip the trunk towards the attacker (face down) or about the attacker line (side)
			var wgt := 0.5 if id == "abdomen" else 1.0
			if _pitch > 0.0:
				pb.angular_velocity += fold_axis * (_pitch * PITCH_RATE * wgt)
				pb.linear_velocity += -_back * (_pitch * PITCH_PUSH * wgt)
			pb.angular_velocity += -_back * (_roll * ROLL_RATE * wgt)
			pb.linear_velocity += _lat * (_roll * ROLL_PUSH * wgt)


## World axis of knee / hip flexion (skeleton rest +x, positive = the shin swinging back behind the thigh).
func _flex_axis() -> Vector3:
	return (skeleton.global_basis * Vector3(1, 0, 0)).normalized()


## Knee flexion in degrees from the bodies: angle between the thigh segment and the shin segment.
func knee_flex(side: String) -> float:
	var hip := bone_origin(side + "Thigh")
	var knee := bone_origin(side + "Shin")
	var ankle := bone_origin(side + "Foot")
	var u := (knee - hip).normalized()
	var v := (ankle - knee).normalized()
	return rad_to_deg(acos(clampf(u.dot(v), -1.0, 1.0)))


## Drives a joint: the child's spin follows its parent's plus `rel` about `axis` (a relative joint speed, so the whole
## leg is not dragged against the rest of the body).
func _drive_joint(child: PhysicalBone3D, parent: PhysicalBone3D, axis: Vector3, rel: float, dt: float) -> void:
	var target := parent.angular_velocity + axis * rel
	child.angular_velocity = child.angular_velocity.lerp(target, minf(1.0, 16.0 * dt))


## Per-tick drives of the recipe: the knees buckle (legs fold under the body), later the sideways topple.
func _drive(dt: float) -> void:
	if _recipe.is_empty() or not legs_free:
		return
	var t0: float = float(_recipe.get("knee_t0", 0.0))
	var dur: float = float(_recipe.get("knee_dur", 0.0))
	if dur > 0.0 and sim_time >= t0 and sim_time <= t0 + dur:
		var axis := _flex_axis()
		var kmax: float = float(_recipe.get("knee_max", 100.0))
		for side in ["l", "r"]:
			if knee_flex(side) < kmax:
				_drive_joint(bones[side + "Thigh"], bones["pelvis"], axis, -float(_recipe.get("hip", 0.0)), dt)
				_drive_joint(bones[side + "Shin"], bones[side + "Thigh"], axis, float(_recipe.get("knee", 0.0)), dt)
	# steering: the passive fall is at the mercy of the stance (which way the knees point), so the upper body is nudged
	# along the recipe's line: back_acc (m/s^2, + = away from the attacker, - = towards him: the body fold), side_acc along
	# the blow's side (hooks), and the sideways speed of blows without a side is bled off
	var steer_t: float = float(_recipe.get("steer_t", 0.9))
	if sim_time <= steer_t:
		var back_acc: float = float(_recipe.get("back_acc", 0.0))
		var side_acc: float = float(_recipe.get("side_acc", 0.0))
		for id in ["abdomen", "chest", "neck", "head"]:
			var sb := bones[id] as PhysicalBone3D
			var v := sb.linear_velocity
			if bool(_recipe.get("lateral", false)):
				v += _lat * (side_acc * _side * dt)
			else:
				v -= _lat * (v.dot(_lat) * (1.0 - exp(-LAT_DAMP * dt)))
			v += _back * (back_acc * (1.0 - clampf(_pitch, 0.0, 1.0)) * dt)
			sb.linear_velocity = v
		if not bool(_recipe.get("lateral", false)):
			var pv := (bones["pelvis"] as PhysicalBone3D)
			pv.linear_velocity -= _lat * (pv.linear_velocity.dot(_lat) * (1.0 - exp(-LAT_DAMP * dt)))
	_steer_fall(dt)
	# the hips stay put: a KO'd fighter drops where he stands (a step or two back at most), so the pelvis loses horizontal speed
	if sim_time <= ANCHOR_T:
		var ph := bones["pelvis"] as PhysicalBone3D
		var pvv := ph.linear_velocity
		var ka := 1.0 - exp(-ANCHOR_DAMP * dt)
		ph.linear_velocity = Vector3(pvv.x * (1.0 - ka), pvv.y, pvv.z * (1.0 - ka))
		# a soft leash on the hips: beyond the allowed step the pelvis is pulled back towards the spot
		var off := ph.global_position - _anchor
		off.y = 0.0
		var over := off.length() - float(_recipe.get("step", ANCHOR_STEP))
		if over > 0.0 and sim_time > 0.15:
			ph.linear_velocity -= off.normalized() * (over * ANCHOR_PULL * dt)
	var sink: float = float(_recipe.get("sink", 0.0))
	if sink > 0.0 and sim_time >= t0 and sim_time <= t0 + dur:
		for id in ["pelvis", "abdomen", "chest", "neck", "head", "lUpperArm", "rUpperArm"]:
			(bones[id] as PhysicalBone3D).linear_velocity.y -= sink * dt
	if not _toppled and _recipe.has("topple_t") and sim_time >= float(_recipe["topple_t"]):
		_toppled = true
		for id in ["pelvis", "abdomen", "chest", "neck", "head", "lUpperArm", "rUpperArm"]:
			(bones[id] as PhysicalBone3D).linear_velocity += _lat * ((_side if bool(_recipe.get("carry_side", false)) else clampf(_roll, -1.5, 1.5)) * float(_recipe.get("topple_v", 0.0)))


## No blow launches a body: the hips and feet never rise more than UP_CAP above where they stood when the fall began
## (their upward speed is eased to zero as they near the cap).
func _cap_lift() -> void:
	var feet_too: bool = bool(_recipe.get("cap_feet", false))
	for id in _rest_y:
		if id != "pelvis" and not feet_too:
			continue   # heels kicking up behind a body going face down are natural; only blows that must not launch (uppercut) cap them
		var pb := bones[id] as PhysicalBone3D
		if not pb.is_simulating_physics():
			continue
		var room := float(_rest_y[id]) + UP_CAP - pb.global_position.y
		if room < UP_CAP and pb.linear_velocity.y > 0.0:
			var v := pb.linear_velocity
			v.y = minf(v.y, maxf(room, 0.0) * 12.0)
			pb.linear_velocity = v


## The fall's pitch / roll, applied in the victim's own frame (a spinning hook victim keeps tipping the way he faces, the
## world frame of the blow would send him over backwards): while the trunk is still up, the upper body is accelerated
## along the facing direction (pitch > 0 forward, face down) and sideways (roll), with a matching angular acceleration.
func _steer_fall(dt: float) -> void:
	var chest := bones["chest"] as PhysicalBone3D
	# the servos and the steering fade out between FADE_START and FADE_END s, and stop for good once the chest faces its
	# resting side to within FADE_ANGLE deg: a body that has found its side is left to the engine, not squirmed into place
	var rest_dir := Vector3.UP
	if _outcome_dir.x > 0.5:
		rest_dir = Vector3.DOWN
	elif _outcome_dir.y != 0.0:
		rest_dir = _fall_f.cross(Vector3.UP) * _outcome_dir.y
	if sim_time > 0.3 and chest.global_basis.z.dot(rest_dir) > cos(deg_to_rad(FADE_ANGLE)):
		_on_target = true
	var gain := 0.0 if _on_target else clampf((FADE_END - sim_time) / (FADE_END - FADE_START), 0.0, 1.0)
	if sim_time > 0.4 and chest.global_basis.y.y < LIE_UPRIGHT:
		# the trunk is down: whatever it lies on is where it stays (muscle tone is gone, the body does not flop over again),
		# so spin of the trunk and legs is bled off and the pose is not rolled onto the back by the folded legs
		var kd := exp(-LIE_DAMP * dt)
		for id in ["pelvis", "abdomen", "chest", "neck", "lThigh", "rThigh", "lShin", "rShin"]:
			(bones[id] as PhysicalBone3D).angular_velocity *= kd
	var tilt_up := chest.global_basis.y
	var cz := Vector3(chest.global_basis.z.x, 0.0, chest.global_basis.z.z)
	if tilt_up.y > 0.85 and cz.length() > 0.2:
		_fall_f = cz.normalized()   # the way he faces while he is still upright
	if gain > 0.0 and _outcome_dir.x > -0.5 and sim_time > 0.03 and sim_time < PITCH_HOLD_T and tilt_up.y > 0.1:
		# a trunk that is not meant to fall on its back does not pitch back: the buckling legs sit the hips down and tip the
		# rigid trunk over backwards, so spin towards the back is bled off (a face-down fall is held at a forward pitch rate)
		var af := Vector3.UP.cross(_fall_f)
		var khold := (1.0 - exp(-PITCH_HOLD * dt)) * gain
		var want := PITCH_HOLD_RATE if _outcome_dir.x > 0.5 else 0.0
		for id in ["pelvis", "abdomen", "chest", "neck"]:
			var pbh := bones[id] as PhysicalBone3D
			var wh := pbh.angular_velocity
			var ch := wh.dot(af)
			if ch < want:
				pbh.angular_velocity = wh + af * ((want - ch) * khold)
	if gain > 0.0 and sim_time > 0.03 and sim_time < SERVO_T and tilt_up.y > 0.1:
		# carry the trunk over the way the fall decided: forward (face down), back (face up) or sideways (a side)
		var d := (_fall_f * _outcome_dir.x + _fall_f.cross(Vector3.UP) * (_outcome_dir.y + _hook_bias)).normalized()
		var err := tilt_up.cross(d) * SERVO_NUDGE
		var ehat := err.normalized() if err.length() > 0.001 else Vector3.ZERO
		for id in ["chest", "abdomen", "pelvis"]:
			var pb2 := bones[id] as PhysicalBone3D
			var w2 := pb2.angular_velocity + err * (SERVO_GAIN * dt * gain) * (1.0 if id == "chest" else 0.7)
			var c := w2.dot(ehat)
			if c > SERVO_MAX:
				w2 -= ehat * (c - SERVO_MAX)
			pb2.angular_velocity = w2
	if gain > 0.0 and sim_time > 0.3 and sim_time < LIE_SERVO_T and chest.global_basis.y.y < 0.75:
		# the trunk is going down: carry the chest over to the side the fall decided (face down / up / on a side)
		var target := Vector3.UP
		if _outcome_dir.x > 0.5:
			target = Vector3.DOWN
		elif _outcome_dir.y != 0.0:
			target = _fall_f.cross(Vector3.UP) * _outcome_dir.y
		var err2 := chest.global_basis.z.cross(target)
		var eh := err2.normalized() if err2.length() > 0.001 else Vector3.ZERO
		var cap := LIE_SERVO_MAX * minf(1.0, err2.length() * 1.5)
		for id in ["chest", "abdomen", "pelvis"]:
			var pb3 := bones[id] as PhysicalBone3D
			var w3 := pb3.angular_velocity + err2 * (LIE_SERVO_GAIN * dt * gain) * (1.0 if id == "chest" else 0.8)
			var c3 := w3.dot(eh)
			if c3 > cap:
				w3 -= eh * (c3 - cap)
			pb3.angular_velocity = w3
	if gain <= 0.0 or sim_time > STEER_PITCH_T or sim_time < 0.04:
		return
	if chest.global_basis.y.y < 0.05:
		return   # the trunk is down already
	var f := Vector3(chest.global_basis.z.x, 0.0, chest.global_basis.z.z)
	if f.length() < 0.1:
		return
	f = f.normalized()
	var lb := f.cross(Vector3.UP)
	var up := Vector3.UP
	var accel := (f * (_pitch * PITCH_ACC) + lb * ((_roll + _hook_bias) * ROLL_ACC)) * gain
	var spin := (up.cross(f) * (_pitch * PITCH_SPIN) + up.cross(lb) * (_roll * ROLL_SPIN)) * gain
	for id in ["abdomen", "chest", "neck", "head"]:
		var pb := bones[id] as PhysicalBone3D
		var w := 0.5 if id == "abdomen" else 1.0
		pb.linear_velocity += accel * (w * dt)
		pb.angular_velocity += spin * (w * dt)


## Once the hips are on the floor the whole body loses energy faster (ramped in, so the landing itself is not cushioned):
## nothing keeps squirming, limbs come to rest.
func _settle_damp(dt: float) -> void:
	if sim_time < 0.5 or (bones["pelvis"] as PhysicalBone3D).global_position.y > 0.3:
		_floor_t = 0.0
		return
	_floor_t += dt
	var r := minf(1.0, _floor_t / FLOOR_RAMP)
	var kl := exp(-FLOOR_DAMP * r * dt)
	var ka := exp(-FLOOR_SPIN_DAMP * r * dt)
	for id in bones:
		var pb := bones[id] as PhysicalBone3D
		if pb.is_simulating_physics():
			pb.linear_velocity = Vector3(pb.linear_velocity.x * kl, pb.linear_velocity.y, pb.linear_velocity.z * kl)
			pb.angular_velocity *= ka


## Friction the engine does not give: anything lying on the floor loses horizontal speed and spin (the body drops
## where it is instead of skating).
func _ground_drag(dt: float) -> void:
	var k := exp(-GROUND_DRAG * dt)
	var ks := exp(-GROUND_SPIN_DRAG * dt)
	for id in bones:
		var pb := bones[id] as PhysicalBone3D
		if not pb.is_simulating_physics() or pb.global_position.y > GROUND_Y:
			continue
		var v := pb.linear_velocity
		var kk := k
		if id.ends_with("Foot") or id.ends_with("Shin"):
			kk = exp(-(GROUND_DRAG + FOOT_DRAG) * dt) if pb.global_position.y < 0.1 else k
		pb.linear_velocity = Vector3(v.x * kk, v.y, v.z * kk)
		pb.angular_velocity *= ks


# ---------------------------------------------------------------- selective self-collision
func _reset_masks() -> void:
	for id in bones:
		(bones[id] as PhysicalBone3D).collision_mask = WORLD
	_groups_on.clear()


## Switches on a group pair's mutual collision once every body of `a` is clear of every body of `b`.
func _enable_groups() -> void:
	if sim_time < 0.12 or _groups_on.size() >= GROUPS.size():
		return
	for gi in GROUPS.size():
		if _groups_on.has(gi):
			continue
		var g: Dictionary = GROUPS[gi]
		var clear := true
		# the longer a group stays overlapped (a crouched stance), the deeper an overlap is tolerated: the engine resolves a
		# few cm of penetration gently, which beats two thighs that never collide
		var margin := PAIR_MARGIN - clampf((sim_time - 0.12) * 0.08, 0.0, 0.07)
		for ia in g["a"]:
			for ib in g["b"]:
				if not _shapes_clear(bones[ia], bones[ib], margin):
					clear = false
		if not clear:
			continue
		_groups_on[gi] = true
		for ia in g["a"]:
			(bones[ia] as PhysicalBone3D).collision_mask |= int(g["b_layer"])
		for ib in g["b"]:
			(bones[ib] as PhysicalBone3D).collision_mask |= int(g["a_layer"])


## Segment samples of a capsule body (world).
func _capsule_pts(pb: PhysicalBone3D, n := 6) -> Array:
	var cs := pb.get_node("Shape") as CollisionShape3D
	var cap := cs.shape as CapsuleShape3D
	var out: Array = []
	var half := maxf(cap.height * 0.5 - cap.radius, 0.0)
	var ax := pb.global_transform.basis.y.normalized()
	var c := pb.global_position
	for i in n:
		out.append(c + ax * (half * (2.0 * i / float(n - 1) - 1.0)))
	return out


func _shape_radius(pb: PhysicalBone3D) -> float:
	var cap := (pb.get_node("Shape") as CollisionShape3D).shape as CapsuleShape3D
	return cap.radius if cap != null else 0.0


func _box_dist(box: PhysicalBone3D, p: Vector3) -> float:
	var half := ((box.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size * 0.5
	var q := box.global_transform.affine_inverse() * p
	var d := Vector3(absf(q.x) - half.x, absf(q.y) - half.y, absf(q.z) - half.z)
	return Vector3(maxf(d.x, 0.0), maxf(d.y, 0.0), maxf(d.z, 0.0)).length() + minf(maxf(d.x, maxf(d.y, d.z)), 0.0)


## True when two paired bodies are separated by more than PAIR_MARGIN (capsule vs box, capsule vs capsule).
func _shapes_clear(a: PhysicalBone3D, b: PhysicalBone3D, margin := PAIR_MARGIN) -> bool:
	var ra := _shape_radius(a)
	var rb := _shape_radius(b)
	if rb == 0.0:   # a is a capsule (forearm / hand), b a box (abdomen / chest)
		for p in _capsule_pts(a):
			if _box_dist(b, p) < ra + margin:
				return false
		return true
	var pa := _capsule_pts(a)
	var sb := _capsule_pts(b)
	for p in pa:
		var best := 9.0
		for i in sb.size() - 1:
			best = minf(best, _seg_dist(p, sb[i], sb[i + 1]))
		if best < ra + rb + margin:
			return false
	return true


func _seg_dist(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _hinge_angle(id: String) -> float:
	var m: Dictionary = meta[id]
	var bi: int = m["bone_idx"]
	var par := skeleton.get_bone_parent(bi)
	var rel := skeleton.get_bone_global_pose(par).basis.orthonormalized().inverse() * skeleton.get_bone_global_pose(bi).basis.orthonormalized()
	# the rest relation is identity (T-pose), so the relative rotation is the joint angle
	var q := rel.get_rotation_quaternion()
	var ax: Vector3 = m["axis"]
	var th := 2.0 * atan2(Vector3(q.x, q.y, q.z).dot(ax), q.w)
	th = wrapf(th, -PI, PI)
	return rad_to_deg(th)


## Current angle (deg) of a hinge body from the posed skeleton (diagnostics / tests).
func joint_angle(id: String) -> float:
	return _hinge_angle(id)


## Call every physics frame while active.
func tick(dt: float) -> void:
	if not active:
		return
	sim_time += dt
	if not legs_free and sim_time >= _legs_release_t:
		legs_free = true
		var legs: Array[StringName] = []
		for id in LEG_IDS:
			legs.append(StringName((bones[id] as PhysicalBone3D).bone_name))
		simulator.physical_bones_start_simulation(legs)
		for id in LEG_IDS:
			var pb := bones[id] as PhysicalBone3D
			# pose polish: the planted legs are released at rest (they were animation driven, feet on the canvas); handing them
			# the pelvis velocity made the whole body skate away with the feet
			pb.linear_velocity = Vector3.ZERO
	_drive(dt)
	_cap_lift()
	_ground_drag(dt)
	_settle_damp(dt)
	_enable_groups()
	if _is_still():
		_still_t += dt
	else:
		_still_t = 0.0
	if _is_still(0.8, 4.0):
		_calm_t += dt
	else:
		_calm_t = 0.0


func _is_still(lin := 0.25, ang := 1.6) -> bool:
	for id in bones:
		var pb := bones[id] as PhysicalBone3D
		if pb.linear_velocity.length() > lin or pb.angular_velocity.length() > ang:
			return false
	return true


## At rest: every body has been (almost) still for `secs`.
func settled(secs := 0.35) -> bool:
	return active and legs_free and _still_t >= secs


## Nearly at rest (looser than settled): the fall is over, the count may start.
func calm() -> bool:
	return active and legs_free and _calm_t >= 0.3


func pelvis_position() -> Vector3:
	return (bones["pelvis"] as PhysicalBone3D).global_position if _built else Vector3.ZERO


func head_position() -> Vector3:
	return (bones["head"] as PhysicalBone3D).global_position if _built else Vector3.ZERO


func body_positions() -> Dictionary:
	var out := {}
	for id in bones:
		out[id] = (bones[id] as PhysicalBone3D).global_position
	return out


## World position of a bone's origin from its physical body (independent of when the skeleton last updated).
func bone_origin(id: String) -> Vector3:
	var pb := bones[id] as PhysicalBone3D
	return (pb.global_transform * pb.body_offset.affine_inverse()).origin


## Lying face up (chest toward the sky): the chest body's front axis (+z of the rest frame) points up.
func lying_face_up() -> bool:
	return (bones["chest"] as PhysicalBone3D).global_basis.z.y > 0.0


## World transforms of every bone (the ragdoll's pose), kept for the get-up blend: physical bones come from their
## bodies, the rest hang off their parent with their current local pose.
func capture_pose() -> void:
	_saved_pose.clear()
	var by_bone := {}
	for id in bones:
		var pb := bones[id] as PhysicalBone3D
		by_bone[skeleton.find_bone(pb.bone_name)] = pb.global_transform * pb.body_offset.affine_inverse()
	var sg := skeleton.global_transform
	for i in skeleton.get_bone_count():
		var t: Transform3D
		if by_bone.has(i):
			t = by_bone[i]
		else:
			var par := skeleton.get_bone_parent(i)
			var pw: Transform3D = _saved_pose[par] if par >= 0 else sg
			t = pw * skeleton.get_bone_pose(i)
		_saved_pose[i] = t


func saved_pose() -> Dictionary:
	return _saved_pose


func stop() -> void:
	if not active:
		return
	_reset_masks()
	_recipe = {}
	simulator.physical_bones_stop_simulation()
	active = false
	_have_prev = false
	_hold_modifiers(false)


## New round / get-up complete: simulation off, pose layers back, blend off.
func reset() -> void:
	if not _built:
		return
	stop()
	_saved_pose.clear()
	blend.weight = 0.0
	_have_prev = false
	_lin_vel.clear()
	_ang_vel.clear()
