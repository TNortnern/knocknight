extends RefCounted
## Knockdown / KO presentation data and helpers (clip choice per punch direction, fall timing, lying orientation,
## get-up choice, pose comparison). Pure data + static functions; fighter.gd calls into it.
## Measured with tools/analyze_fall_clips.gd, tools/clip_timing.gd and tools/render_clip_strips.gd.

## Bones compared when matching one clip's pose to another (no face / finger bones).
const CORE_BONES := ["hip", "pelvis", "abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "lCollar", "rCollar",
	"lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend", "lHand", "rHand", "neckLower", "neckUpper", "head",
	"lThighBend", "rThighBend", "lShin", "rShin", "lFoot", "rFoot"]

## Fall clip per strike direction (F straight, L / R hook, U uppercut, O overhand). Every one of them ends lying on
## the back (face up, head behind the hip), so the get-up is GetUpBack. `speed` retimes the clip (1.0 = authored).
## "L Fall" / "R Fall" are NOT used: they are a forward dive / a backward leap-and-tuck (see tools/render_clip_strips.gd).
const HEAD_FALLS := {
	"F": {"clip": "F head KO", "speed": 1.25},   # steps back, sits, drops flat on the back
	"L": {"clip": "L head KO", "speed": 1.1},    # twists away, sits, rolls onto the back
	"R": {"clip": "R head KO", "speed": 1.1},
	"U": {"clip": "U head KO", "speed": 1.1},    # head snaps back, legs go, back-pedals to the floor
	"O": {"clip": "O head KO", "speed": 1.1},    # overhand: legs buckle straight down, then onto the back
}
const BODY_FALL := {"clip": "KB_MidKO", "speed": 1.0}   # folds, kneels, slumps face down (-> GetUpFace)
const LEG_FALL := {"clip": "KB_TopKO", "speed": 1.0}    # legs give out, crumples, falls back
const GETUP_FACE_UP := "KB_GetUpBack"
const GETUP_FACE_DOWN := "KB_GetUpFace"
## The fall clips end at the hip's ground height (~0.1 m); the capsule stays at y = 0.
const MAX_POSE_JUMP_DEG := 25.0


static func fall_for(zone: String, dir: String) -> Dictionary:
	if zone == "body":
		return BODY_FALL
	if zone == "leg":
		return LEG_FALL
	return HEAD_FALLS.get(dir, HEAD_FALLS["F"])


## Seconds the fall plays for (real time).
static func fall_seconds(ap: AnimationPlayer, fall: Dictionary) -> float:
	var clip: String = fall["clip"]
	if ap == null or not ap.has_animation(clip):
		return 2.0
	return ap.get_animation(clip).length / float(fall["speed"])


## True when the body lies face up (chest toward the sky). `sk` must be posed; positions are skeleton space.
static func lying_face_up(sk: Skeleton3D) -> bool:
	var hip := sk.find_bone("hip")
	var head := sk.find_bone("head")
	var ls := sk.find_bone("lShldrBend")
	var rs := sk.find_bone("rShldrBend")
	if hip < 0 or head < 0 or ls < 0 or rs < 0:
		return true
	var up := sk.get_bone_global_pose(head).origin - sk.get_bone_global_pose(hip).origin
	var across := sk.get_bone_global_pose(ls).origin - sk.get_bone_global_pose(rs).origin
	return across.cross(up).y > 0.0   # chest normal; > 0 = up (calibrated on KB_Idle_1: normal +z when standing)


static func getup_clip(sk: Skeleton3D) -> String:
	return GETUP_FACE_UP if lying_face_up(sk) else GETUP_FACE_DOWN


## Largest rotation difference (degrees) over CORE_BONES between two poses of one skeleton.
static func pose_distance(a: Array, b: Array) -> float:
	var mx := 0.0
	for i in mini(a.size(), b.size()):
		mx = maxf(mx, rad_to_deg((a[i] as Quaternion).angle_to(b[i])))
	return mx


## Local rotations of CORE_BONES for clip `clip` at `t`; the AnimationPlayer and skeleton must be in the tree
## (the caller awaits a frame after this to let the pose apply, see `sample`).
static func core_pose(sk: Skeleton3D) -> Array:
	var out: Array = []
	for b in CORE_BONES:
		var i := sk.find_bone(b)
		out.append(sk.get_bone_pose_rotation(i) if i >= 0 else Quaternion.IDENTITY)
	return out


# ---------------------------------------------------------------- ragdoll fall recipes (pose polish)
## What kind of fall a blow produces. The ragdoll is passive, so each kind adds a short DRIVE on top of the punch
## impulse (see Ragdoll._apply_recipe / _drive): knee / hip buckle (the legs fold under the body so it drops in place
## instead of toppling like a tree), spin, forward fold, head snap, a late sideways topple.
## Fields: imp / shove scale the punch impulse and the whole-body shove; knee / hip = drive rates (rad/s) towards
## knee_max deg of knee flexion, starting at knee_t0 for knee_dur s; yaw = spin rate (rad/s, signed to the blow's
## lateral direction); side_v = lateral velocity (m/s) of the upper body along the blow's side; fold = forward pitch
## rate of trunk + head; snap = extra head / neck speed back and up; topple_t / topple_v = a delayed sideways nudge
## of the trunk (body shots: kneel first, then roll to the side).
const RECIPES := {
	"jab":      {"imp": 0.45, "shove": 0.15, "knee": 5.0, "hip": 0.0, "knee_t0": 0.04, "knee_dur": 0.45, "knee_max": 105.0, "snap": 0.3, "sink": 10.0, "back_acc": 0.8, "pitch": -0.15, "roll": 0.1, "walk_k": 0.4},
	"straight": {"imp": 0.8, "shove": 0.6, "knee": 4.0, "hip": 0.0, "knee_t0": 0.20, "knee_dur": 0.40, "knee_max": 95.0, "snap": 0.4, "sink": 8.0, "back_acc": 2.5, "pitch": -0.1, "roll": 0.2, "walk_k": 0.5},
	"hook":     {"imp": 0.5, "shove": 0.1, "knee": 4.0, "hip": 0.0, "knee_t0": 0.10, "knee_dur": 0.45, "knee_max": 100.0,
		"snap": 0.2, "sink": 8.0, "step": 0.04, "hook_side": 1.0, "topple_t": 0.3, "topple_v": 1.1, "carry_side": true, "pitch": 0.8, "roll": 0.5, "pitch_noise": 0.6},
	"upper":    {"imp": 1.0, "shove": 0.5, "step": 0.4, "knee": 4.5, "hip": 0.0, "knee_t0": 0.12, "knee_dur": 0.45, "knee_max": 100.0, "snap": 2.4, "sink": 6.0, "back_acc": 7.0, "pitch": -0.4, "roll": 0.2, "walk_k": 0.3, "cap_feet": true},
	"body":     {"imp": 0.5, "shove": 0.2, "knee": 3.5, "hip": 0.0, "knee_t0": 0.02, "knee_dur": 0.5, "knee_max": 100.0, "fold": 6.0,
		"topple_t": 0.55, "topple_v": 1.0, "sink": 10.0, "back_acc": -5.0, "steer_t": 0.7, "pitch": 1.3, "roll": 0.1},
	"over":     {"imp": 0.7, "shove": 0.4, "knee": 6.0, "hip": 0.0, "knee_t0": 0.02, "knee_dur": 0.45, "knee_max": 110.0, "snap": 0.2, "sink": 12.0, "back_acc": 0.5, "pitch": 0.9, "roll": 0.1},
}
const RECIPE_FALLBACK := "straight"


## Classifies the blow behind a fall: "jab" / "straight" / "hook" / "upper" / "body" / "over" (the key into RECIPES).
## `dir_prefix` is the strike's direction code (F straight, L / R hook, U uppercut, O overhand), `limb` "L" / "R" hand.
static func fall_kind(zone: String, dir_prefix: String, limb: String) -> String:
	if zone == "body":
		return "body"
	match dir_prefix:
		"L", "R":
			return "hook"
		"U":
			return "upper"
		"O":
			return "over"
	return "jab" if limb == "L" else "straight"
