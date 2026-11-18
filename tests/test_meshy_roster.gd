extends SceneTree
# Meshy roster: every fighter plays on its M3DMale template and shows a retargeted Meshy skin.
# Per fighter: skeleton + visibility, feet on the canvas, head joint vs head bone / head hurt box, hand joints vs hand bones /
# hand hit boxes in guard and at jab extension, and the Meshy head following the physical head during a ragdoll KO.
# godot --headless --fixed-fps 120 --path . --script res://tests/test_meshy_roster.gd
const RosterScript := preload("res://scripts/fighter/roster.gd")

var failures := 0
var m: Match


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


func make_match(p1: String, p2: String, ctrl := "cpu") -> Array:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "p1_controller": ctrl, "p2_controller": ctrl,
		"p1_model": p1, "p2_model": p2, "rules": "boxing"})
	get_root().add_child(m)
	await process_frame
	return m.get_fighters()


func hand_box_centre(f: Fighter, limb: String) -> Vector3:
	var hb: Array = f.rig.hitbox_for(limb)
	return (hb[0] as Node).get_child(0).global_position


func head_box_centre(f: Fighter) -> Vector3:
	for hu in f.rig.hurtboxes:
		if hu.zone == "head":
			return hu.shape_node.global_position
	return Vector3.ZERO


## {l, r}: distance Meshy hand joint -> M3DMale hand bone (world)
func hand_err(f: Fighter) -> Dictionary:
	var out := {}
	for side in ["l", "r"]:
		var drv: Vector3 = f.meshy_skin.driver_world(side + "Hand").origin
		var jn := "LeftHand" if side == "l" else "RightHand"
		out[side] = f.meshy_skin.joint_world(jn).distance_to(drv)
	return out


## Meshy glove (hand joint pushed along the hand bone to the fist, as the hit box is) -> hand hit box centre
func glove_err(f: Fighter, side: String) -> float:
	var ms = f.meshy_skin
	var jn := "LeftHand" if side == "l" else "RightHand"
	var sk: Skeleton3D = ms.skeleton
	var gt: Transform3D = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(jn))
	var dir := gt.basis.y.normalized()
	var dh: Transform3D = ms.driver_world(side + "Hand")
	var off_len := (hand_box_centre(f, side + "Hand") - dh.origin).length()
	return (gt.origin + dir * off_len).distance_to(hand_box_centre(f, side + "Hand"))


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var ids: Array = RosterScript.ORDER.filter(func(i): return RosterScript.skin_path(i) != "")
	check(ids.size() == 5, "5 Meshy fighters in the roster")
	for fi_idx in ids.size():
		var fid: String = ids[fi_idx]
		print("== ", fid)
		var other: String = ids[(fi_idx + 1) % ids.size()]
		var f := await make_match(fid, other)
		await steps(120 * 4)   # 4 s of CPU fight
		var a: Fighter = f[0]
		check(a.meshy_skin != null and a.meshy_skin.skeleton != null, "%s: Meshy skeleton exists" % fid)
		check(a.meshy_skin.skeleton.get_bone_count() == 24, "%s: 24 joints" % fid)
		var vis := false
		for n in a.meshy_skin.root.find_children("*", "MeshInstance3D", true, false):
			vis = vis or (n as MeshInstance3D).is_visible_in_tree()
		check(vis, "%s: Meshy mesh visible" % fid)
		var hidden := true
		for n in a.model_root.find_children("*", "MeshInstance3D", true, false):
			hidden = hidden and not (n as MeshInstance3D).is_visible_in_tree()
		check(hidden, "%s: M3DMale mesh hidden" % fid)
		check(a.display_name == RosterScript.display_name(fid), "%s: HUD name %s" % [fid, a.display_name])
		# ---- guard: freeze both, stand still
		for fi in f:
			fi.external_input = FighterInput.new()
		await steps(240)
		var ms = a.meshy_skin
		var dy: float = ms.joint_world("Head").y - ms.driver_world("head").origin.y
		var toes: float = minf(ms.joint_world("LeftToeBase").y, ms.joint_world("RightToeBase").y)
		var feet_d: float = absf(ms.joint_world("LeftToeBase").y - ms.driver_world("lMetatarsals").origin.y)
		check(toes > -0.03 and toes < 0.09, "%s: toes on the canvas (min toe y %.3f)" % [fid, toes])
		check(feet_d < 0.04, "%s: toe height matches the driver's (%.3f)" % [fid, feet_d])
		var head_bone_err: float = ms.joint_world("Head").distance_to(ms.driver_world("head").origin)
		var head_box_err: float = ms.joint_world("Head").distance_to(head_box_centre(a))
		check(head_bone_err < 0.04, "%s: head joint %.3f m from head bone (guard)" % [fid, head_bone_err])
		check(head_box_err < 0.08, "%s: head joint %.3f m from head hurt box" % [fid, head_box_err])
		var he: Dictionary = hand_err(a)
		var ge: float = maxf(glove_err(a, "l"), glove_err(a, "r"))
		check(maxf(he["l"], he["r"]) < 0.06, "%s: hand joints %.3f / %.3f m from hand bones (guard)" % [fid, he["l"], he["r"]])
		check(ge < 0.06, "%s: glove %.3f m from hand hit box (guard)" % [fid, ge])
		print("     head dy %.3f  skin scale %.3f" % [dy, ms.skin_scale()])
		# ---- jab extension
		var pos0 := a.global_position
		for tag in ["LJab", "RCross"]:
			var worst_hand := 0.0
			var worst_glove := 0.0
			var worst_feet := 0.0
			a.external_input.strikes.append(tag)
			await steps(1)
			a.external_input.strikes.clear()
			for i in 90:
				await steps(1)
				var e: Dictionary = hand_err(a)
				worst_hand = maxf(worst_hand, maxf(e["l"], e["r"]))
				worst_glove = maxf(worst_glove, maxf(glove_err(a, "l"), glove_err(a, "r")))
				worst_feet = maxf(worst_feet, absf(minf(ms.joint_world("LeftToeBase").y, ms.joint_world("RightToeBase").y)))
			check(worst_hand < 0.06, "%s %s: hand joint within %.3f m of the hand bone over the throw" % [fid, tag, worst_hand])
			check(worst_glove < 0.06, "%s %s: glove within %.3f m of the hit box over the throw" % [fid, tag, worst_glove])
			check(worst_feet < 0.09, "%s %s: feet stay down (%.3f)" % [fid, tag, worst_feet])
		# ---- ragdoll KO: P1 knocks the other fighter out; its Meshy head must follow the physical head
		var p1: Fighter = f[0]
		var p2: Fighter = f[1]
		p1.global_position = Vector3(-0.30, 0, 0)   # 0.6 m: the scripted hook only touches a head from there (contact-only hits)
		p2.global_position = Vector3(0.30, 0, 0)
		await steps(60)
		p2.stats.head = 0.4
		p2.stats.knockdowns = 3
		p1.external_input.strikes.append("RHook@aim")   # aimed: unaimed, whether it lands depends on the foe's idle-sway / bounce phase
		await steps(1)
		p1.external_input.strikes.clear()
		var n := 0
		while p2.state != Fighter.State.DOWN and n < 600:
			await steps(1)
			n += 1
		check(p2.state == Fighter.State.DOWN and p2._ragdoll.active, "%s: KO ragdoll started" % fid)
		var worst := 0.0
		var worst_drv := 0.0
		var min_y := 9.0
		for i in 360:
			await steps(1)
			if p2._ragdoll.active:
				var ph: Vector3 = p2._ragdoll.bone_origin("head")
				worst = maxf(worst, p2.meshy_skin.joint_world("Head").distance_to(ph))
				worst_drv = maxf(worst_drv, p2.meshy_skin.joint_world("Head").distance_to(p2.meshy_skin.driver_world("head").origin))
				min_y = minf(min_y, p2.meshy_skin.joint_world("Head").y)
		check(worst < 0.2 and worst_drv < 0.10, "%s: Meshy head follows the physical head through the KO (max %.3f m, %.3f from the driver head)" % [fid, worst, worst_drv])
		check(min_y > -0.05, "%s: Meshy head stays above the canvas (min y %.3f)" % [fid, min_y])
	print("PASS: meshy roster" if failures == 0 else "FAIL: meshy roster (%d)" % failures)
	quit(1 if failures else 0)
