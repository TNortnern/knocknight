extends "res://scripts/fighter/pose_layer_base.gd"
## Loaded guard stance (Fight Night reference): the reference fighters stand crouched and loaded in every frame - knees about
## 110-130 deg, hips low, feet a little wider - while our animated guard stands tall (knee about 155 deg), which reads stiff
## before, between and after every move. This layer lowers the pelvis a few centimetres with both feet kept on their animated
## positions (two-bone leg IK, so the knees bend more) and widens the stance a little. Both fighters sit lower by the same
## amount, so punch lanes, reach and the guard-to-head geometry are unchanged. (A pinned striking hand was tried and rejected:
## its IK toggling at every punch start / end raised the per-punch pose jumps above the inertialization budget.)
##
## Active in boxing fight states (idle / slip / attack), blended in and out; off when the fighter is hurt, rocked, ducking,
## down or fatigued into a drop. Order on the Skeleton3D: after DefencePose, before LeanPose (the slip layers stack on top).

const DROP := 0.06          ## m the pelvis sits lower (knees about 22 deg more bent with the feet planted; 0.07 trips the clinch glove-hull test by 6 mm)
const WIDEN := 0.03         ## m each foot moves outwards
const BLEND_IN := 0.20      ## s
const BLEND_OUT := 0.12     ## s

var w := 0.0                ## 0..1 stance weight (diagnostic)


func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or not _fighter_ok():
		return
	_ready_bones(sk)
	_restore(sk)
	var f = fighter
	var on: bool = _standing() and f.rules == "boxing" and f.state in [f.State.IDLE, f.State.SLIP, f.State.ATTACK] \
			and not f.hurt.active() and not f.rocked and f.lean_pose.duck_w < 0.05
	var target := 1.0 if on else 0.0
	w = move_toward(w, target, dt / (BLEND_IN if target > w else BLEND_OUT))
	if w < 0.001:
		return
	_frame(sk)
	var feet := _feet_begin(sk)
	var foot_rot := {}
	for side in ["l", "r"]:
		foot_rot[side] = sk.get_bone_global_pose(_bone[side + "Foot"]).basis.orthonormalized().get_rotation_quaternion()

	_move_hip(sk, -_up * (DROP * w))
	feet["l"] = (feet["l"] as Vector3) + _left * (WIDEN * w)
	feet["r"] = (feet["r"] as Vector3) - _left * (WIDEN * w)
	_plant_feet(sk, feet)
	for side in ["l", "r"]:
		var idx: int = _bone[side + "Foot"]
		var cur := sk.get_bone_global_pose(idx).basis.orthonormalized().get_rotation_quaternion()
		_rot_sk(sk, idx, (foot_rot[side] as Quaternion) * cur.inverse())
	# (no pin: see header)
