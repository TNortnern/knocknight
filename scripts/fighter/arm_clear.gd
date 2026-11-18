extends "res://scripts/fighter/pose_layer_base.gd"
## Self-clearance for the guard arms. The LAST word on the fighter's own body: after every pose layer (slip, duck, lean back, rocked,
## fatigue, clinch ...) the glove, forearm and elbow of each arm are measured against the fighter's own torso and head hulls
## (body_volumes.gd, the HitFit volumes fitted to the visible mesh) and pushed out along the hull's outward normal, with the same
## two-bone IK the other layers use. The glove keeps its orientation. A striking hand is the punch's, not the guard's: left alone.
## Order on the Skeleton3D: after every pose layer and the post-inertialization, just before GloveClear (which keeps the last word on the foe's head) and the ragdoll blend.

const BodyVolumes := preload("res://scripts/fighter/body_volumes.gd")
const MARGIN := 0.006          ## m left between a limb and the torso hull
const HEAD_TOLERANCE := 0.045  ## m a guard glove may sink into the head hull (a high guard rests against the face)
const ITERATIONS := 6
const MAX_PUSH := 0.30         ## m, largest wrist / elbow correction

const MAX_STEP := 0.05         ## m: largest wrist correction added in one physics frame (6 m/s)
const RELEASE_TAU := 0.07      ## s: a correction grows at once (the glove never sinks in) but fades out smoothly (no pop when the contact ends)

var _wo := {"l": Vector3.ZERO, "r": Vector3.ZERO}   ## smoothed wrist / elbow-pole offsets (skeleton space)
var _eo := {"l": Vector3.ZERO, "r": Vector3.ZERO}
var _dt := 0.008
var pushed := 0.0              ## diagnostic: largest wrist correction this pass (m)
var residual := 0.0            ## diagnostic: deepest overlap left after the pass (m)


func _process_modification_with_delta(dt: float) -> void:
	_dt = clampf(dt, 0.001, 0.05)
	var sk := get_skeleton()
	pushed = 0.0
	residual = 0.0
	if sk == null or not _fighter_ok():
		return
	_ready_bones(sk)
	_restore(sk)
	if not _standing():
		_reset()
		return
	_frame(sk)
	for side in ["l", "r"]:
		var f = fighter
		if f.state == f.State.ATTACK and not f.atk.is_empty() and String(f.atk.get("limb", "")) == side + "Hand":
			_wo[side] = Vector3.ZERO
			_eo[side] = Vector3.ZERO
			continue
		_clear_arm(sk, side)


func _reset() -> void:
	for s in ["l", "r"]:
		_wo[s] = Vector3.ZERO
		_eo[s] = Vector3.ZERO


func _clear_arm(sk: Skeleton3D, side: String) -> void:
	var hand: String = side + "Hand"
	var el: String = side + "ForearmBend"
	var sh: String = side + "ShldrBend"
	var hand_idx: int = _bone[hand]
	var glove_q := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
	var model: String = fighter.model
	var wrist0 := _o(sk, hand)
	var elbow0 := _o(sk, el)
	var wo: Vector3 = _wo[side]
	var eo: Vector3 = _eo[side]
	var moved := false
	# Warm start: last frame's offsets are applied first, then only the penetration that is LEFT is added (bounded per frame). The solution
	# therefore moves continuously with the pose instead of being re-solved from scratch every frame (a from-scratch solve flips the elbow
	# when a hull normal flips: a 30-60 deg pop of the arm bones).
	if wo.length() > 0.0004:
		_ik2(sk, sh, el, hand, wrist0 + wo, elbow0 + eo)
		moved = true
	var budget := MAX_STEP
	var touched := false
	for it in ITERATIONS:
		var vols := BodyVolumes.build(sk, model)
		if vols.is_empty():
			return
		var w := _o(sk, hand)
		var e := _o(sk, el)
		var dw := Vector3.ZERO
		var de := Vector3.ZERO
		for part in [hand, side + "Fist"]:
			if not vols.has(part):
				continue
			for smp in BodyVolumes.limb_samples(vols[part]):
				dw = _deepest(vols, smp[0], smp[1], dw)
		# forearm samples: the push moves the elbow, and the wrist by its share along the forearm
		if vols.has(el):
			var fv: Dictionary = vols[el]
			var samples := BodyVolumes.limb_samples(fv, 5)
			for k in samples.size():
				var push := _deepest(vols, samples[k][0], samples[k][1], Vector3.ZERO)
				if push == Vector3.ZERO:
					continue
				var wf := float(k) / float(samples.size() - 1)   # share towards the wrist end of this sample
				if (fv["ax"] as Vector3).dot(w - e) < 0.0:
					wf = 1.0 - wf
				if push.length() > de.length():
					de = push
				if (push * wf).length() > dw.length():
					dw = push * wf
		# the elbow itself (the upper arm starts inside the shoulder hull by design, so only the elbow is tested)
		de = _deepest(vols, e, 0.04, de)
		if dw == Vector3.ZERO and de == Vector3.ZERO:
			break
		touched = true
		# the elbow only swivels about the shoulder-wrist line, so the part of its push that swivelling cannot give moves the wrist too
		var dwo := (dw + de * 0.8).limit_length(minf(budget, MAX_STEP * 0.5))
		var deo := (de * 1.5).limit_length(minf(budget * 1.5, MAX_STEP))
		budget -= dwo.length()
		wo += dwo
		eo += deo
		wo = wo.limit_length(MAX_PUSH)
		eo = eo.limit_length(MAX_PUSH * 1.5)
		_ik2(sk, sh, el, hand, wrist0 + wo, elbow0 + eo)
		moved = true
		if budget <= 0.0:
			break
	if not touched:
		var k := exp(-_dt / RELEASE_TAU)   # nothing overlaps any more: the offsets fade out
		wo *= k
		eo *= k
	_wo[side] = wo
	_eo[side] = eo
	if moved:
		var q_now := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
		_rot_sk(sk, hand_idx, glove_q * q_now.inverse())
		pushed = maxf(pushed, _o(sk, hand).distance_to(wrist0))
	var left := BodyVolumes.arm_penetration(BodyVolumes.build(sk, model), side)
	residual = maxf(residual, float(left["torso"]))


## The push (vector, m) that takes a sphere (centre p, radius r) out of the torso hulls and the head hull; `acc` when it is not larger.
func _deepest(vols: Dictionary, p: Vector3, r: float, acc: Vector3) -> Vector3:
	var best := acc
	for n in ["chest", "abdomen", "head"]:
		if not vols.has(n):
			continue
		var tol := HEAD_TOLERANCE if n == "head" else 0.0
		var depth: float = r - BodyVolumes.sdf(vols[n], p) + MARGIN - tol
		if depth > 0.0:
			var push: Vector3 = BodyVolumes.normal(vols[n], p) * depth
			if push.length() > best.length():
				best = push
	return best
