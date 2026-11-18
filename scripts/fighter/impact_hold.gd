extends "res://scripts/fighter/pose_layer_base.gd"
## Impact clamp + hold on the ATTACKER: a punch never visibly goes through the foe, and a landed blow stops on the skin for a few frames.
##
## The foe's head / neck / torso hulls ride the visible skin (fighter_rig.gd rebind_visible), the striking sphere rides the visible glove. This layer
## runs last (after GloveClear, before the ragdoll blend) and keeps the glove sphere out of those hulls, to `TOL` of penetration (about 8 mm into the
## skin: a cheek compressing), by moving the striking hand with two-bone IK (the glove keeps its facing):
##   clamp : the animated glove would end the tick inside a hull -> it stops at the surface (pushed out along the hull normal, or at the entry
##           point of its path when it would tunnel past the hull's core). While the foe is in the way the glove cannot sail through the skull.
##   hold  : the tick a blow registers (hit / block) the glove is frozen on the surface for HOLD s (a hit-stop of ~40-90 ms scaled by the blow) while
##           the head snaps away (hit_flinch.gd), then eases back to the animated pose over RELEASE s - and the clamp keeps it out of the head, which by
##           then is moving off the punch line. Any correction lets go at most RELEASE_SPEED (clamped or held glove -> animated pose).
## Gameplay does not see this correction: `Hitbox.clamp_delta` is the world shift applied to the glove this tick, and the hit sweeps use the sphere
## path WITHOUT it, so which blows land, when and how hard is exactly what it was; only what the player sees changes.
##
## The sphere is rigid in the hand frame, so the animated sphere this tick = hand transform now * (hand transform last tick)^-1 * sphere last tick.

const TOL := 0.018          ## m the glove sphere may sink into a (skin + 1 cm) hull
const HOLD_MIN := 0.03
const RELEASE := 0.06       ## s to ease from the held pose back to the animated one
const MAX_SHIFT := 0.30
const RELEASE_SPEED := 2.5  ## m/s: a correction (hold / clamp) lets go of the glove at most this fast. A jab lands before full reach and the
                            ## clip carries on to it: let go at once, the glove popped 0.24 m out in two ticks

var _hand_last := {}        ## "lHand" / "rHand" -> world Transform3D of the hand bone at the end of the last tick (this layer is last: the final pose)
var _hold_serial := -1
var _hold_s := Vector3.ZERO   ## the world position the glove sphere is held at
var _hold_end := 0.0
var _hold_shift := Vector3.ZERO
var _shift := Vector3.ZERO   ## the world correction applied last tick (eased back to zero, never dropped)
var _shift_serial := -1
var last_shift := Vector3.ZERO   ## diagnostics: world shift applied to the striking hand this tick
var clamps := 0                  ## diagnostics: ticks the clamp moved a glove
var holds := 0                   ## diagnostics: holds started


func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or not _fighter_ok():
		return
	_ready_bones(sk)
	_restore(sk)
	var f = fighter
	for hb in f.rig.hitboxes:
		hb.clamp_delta = Vector3.ZERO
	last_shift = Vector3.ZERO
	if f.atk.is_empty() or int(f.atk["serial"]) != _shift_serial:   # a new punch (maybe the other hand) starts uncorrected
		_shift = Vector3.ZERO
		_shift_serial = -1 if f.atk.is_empty() else int(f.atk["serial"])
	if f.foe == null or f.state != f.State.ATTACK or f.atk.is_empty() or f._ragdoll.active:
		_remember(sk)
		return
	var limb: String = String(f.atk["limb"])
	if not limb.ends_with("Hand") or not _hand_last.has(limb) or _bone.get(limb, -1) < 0 or f.punch_phase() == "startup":
		_remember(sk)
		return
	var hbs: Array = f.rig.hitbox_for(limb)
	if hbs.is_empty():
		_remember(sk)
		return
	var hb: HitAreas.Hitbox = hbs[0]
	var r: float = hb.shapes[0]["r"]
	var node := hb.shapes[0]["node"] as Node3D
	var hand_idx: int = _bone[limb]
	var sk_xf := sk.global_transform
	var h_now: Transform3D = sk_xf * sk.get_bone_global_pose(hand_idx)
	var h_last: Transform3D = _hand_last[limb]
	var s_last := node.global_position                      # the sphere as the last tick left it (clamp included)
	var s_now: Vector3 = h_now * (h_last.affine_inverse() * s_last)   # where the animation puts it now (rigid in the hand frame)
	var foe = f.foe
	# --- the hulls in the way
	var hulls: Array = []
	for hu: HitAreas.Hurtbox in foe.rig.hurtboxes:
		if hu.zone == "head" or hu.zone == "body":
			hulls.append(hu)
	if f.atk["hit_done"] and f.atk.get("blocked", false) or foe.guard_on:
		for hu: HitAreas.Hurtbox in foe.rig.guards:
			if hu.collision_layer != 0:
				hulls.append(hu)
	var target := s_now
	var pushed := false
	for _pass in 2:
		var worst: HitAreas.Hurtbox = null
		var worst_pen := TOL
		for hu: HitAreas.Hurtbox in hulls:
			var pen := -(hu.sdf(target) - r)
			if pen > worst_pen:
				worst_pen = pen
				worst = hu
		if worst == null:
			break
		pushed = true
		target = _stop_at(worst, s_last, target, r)
	# --- hold: frozen on the surface for a few frames after the blow registers
	var atk: Dictionary = f.atk
	if atk["hit_done"] and not atk.get("clash", false) and not atk.get("parried", false) and atk.has("hold_len") and atk.has("land_t"):
		var since: float = f._time - float(atk["land_t"])
		var hold_len: float = atk["hold_len"]
		if _hold_serial != int(atk["serial"]):
			_hold_serial = int(atk["serial"])
			_hold_s = target
			holds += 1
		if since <= hold_len:
			target = _hold_s
		elif since < hold_len + RELEASE:
			var w := smoothstep(0.0, 1.0, (since - hold_len) / RELEASE)
			target = _hold_s.lerp(target, w)
			# the eased pose must stay out of the hulls too (the head is leaving, but not necessarily fast enough)
			for hu: HitAreas.Hurtbox in hulls:
				if -(hu.sdf(target) - r) > TOL:
					target = _stop_at(hu, s_last, target, r)
	var shift := (target - s_now).limit_length(MAX_SHIFT)
	if shift.length() < _shift.length():   # letting go: ease out instead of snapping to the animated pose
		shift = _shift.move_toward(shift, RELEASE_SPEED * dt)
	_shift = shift
	if shift.length() > 0.0008:
		var shoulder := limb.substr(0, 1) + "ShldrBend"
		var elbow := limb.substr(0, 1) + "ForearmBend"
		var inv := sk_xf.affine_inverse()
		var glove_q := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
		var want_sk: Vector3 = inv * (h_now.origin + shift)
		# the elbow bends down and a little outward, whatever the punch: an almost straight arm has no stable bend direction of its own (the solve
		# would flip the elbow up when the hand is held back), so the pole is a point under / beside the shoulder instead of the current elbow
		_frame(sk)
		var out_dir := _left if limb.begins_with("l") else -_left
		var pole := _o(sk, shoulder) - _up * 0.35 + out_dir * 0.12
		_ik2(sk, shoulder, elbow, limb, want_sk, pole)
		var solved_q := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
		_rot_sk(sk, hand_idx, glove_q * solved_q.inverse())   # the elbow solve must not roll the glove: keep its facing
		# what the sphere really moved by: it is rigid in the hand frame, so follow the hand's final transform (origin AND facing)
		var h_after: Transform3D = sk_xf * sk.get_bone_global_pose(hand_idx)
		var s_after: Vector3 = h_after * (h_now.affine_inverse() * s_now)
		last_shift = h_after.origin - h_now.origin
		for hb2 in hbs:
			hb2.clamp_delta = s_after - s_now
		if pushed:
			clamps += 1
	_remember(sk)


func _remember(sk: Skeleton3D) -> void:
	var xf := sk.global_transform
	for limb in ["lHand", "rHand"]:
		if _bone.get(limb, -1) >= 0:
			_hand_last[limb] = xf * sk.get_bone_global_pose(_bone[limb])


## The sphere centre `p` (inside hull `hu`) moved back out to TOL of penetration. `s_last` = where the glove was last tick (outside, or on the surface).
func _stop_at(hu: HitAreas.Hurtbox, s_last: Vector3, p: Vector3, r: float) -> Vector3:
	var pen := -(hu.sdf(p) - r)
	var n := hu.normal_at(p)
	var n_last := hu.normal_at(s_last)
	if n.dot(n_last) > 0.0 and pen < r + 0.06:
		return p + n * (pen - TOL)   # slides along the surface: a hook arcs round the head instead of sticking to one spot
	# deep (the glove would tunnel past the core): the point where its path met the hull
	var lo := 0.0
	var hi := 1.0
	for _k in 14:
		var mid := (lo + hi) * 0.5
		if -(hu.sdf(s_last.lerp(p, mid)) - r) > TOL:
			hi = mid
		else:
			lo = mid
	return s_last.lerp(p, lo)
