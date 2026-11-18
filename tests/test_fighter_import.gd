extends SceneTree
# Run: godot --headless --path <project> --script res://tests/test_fighter_import.gd   (run `--headless --import` first)

const FIGHTERS := ["viper", "anvil"]
const BONES := ["hip", "pelvis", "abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "neckLower", "neckUpper", "head",
	"lCollar", "rCollar", "lShldrBend", "rShldrBend", "lShldrTwist", "rShldrTwist", "lForearmBend", "rForearmBend",
	"lForearmTwist", "rForearmTwist", "lHand", "rHand", "lThighBend", "rThighBend", "lThighTwist", "rThighTwist",
	"lShin", "rShin", "lFoot", "rFoot", "lMetatarsals", "rMetatarsals"]
const REQUIRED_ANIMS := ["KB_Idle_1", "KB_m_Jab_L", "KB_WalkFwd2", "KB_KO_Head"]

var failures := 0

func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func collect(n: Node, type_name: String, out: Array) -> void:
	if n.is_class(type_name):
		out.append(n)
	for c in n.get_children():
		collect(c, type_name, out)

func bone_pos(sk: Skeleton3D, bone: String) -> Vector3:
	return (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone))).origin

func _initialize() -> void:
	for f in FIGHTERS:
		print("== ", f)
		await test_fighter(f)
	if failures == 0:
		print("PASS: all fighter import checks")
		quit(0)
	else:
		print("FAIL: %d check(s) failed" % failures)
		quit(1)

func test_fighter(f: String) -> void:
	var packed: PackedScene = load("res://assets/fighters/%s.glb" % f)
	check(packed != null, "%s.glb loads" % f)
	if packed == null:
		return
	var root := packed.instantiate()
	get_root().add_child(root)
	await process_frame

	var skeletons: Array = []
	collect(root, "Skeleton3D", skeletons)
	check(skeletons.size() == 1, "exactly one Skeleton3D (found %d)" % skeletons.size())
	if skeletons.size() != 1:
		return
	var sk: Skeleton3D = skeletons[0]
	var missing: Array = []
	for b in BONES:
		if sk.find_bone(b) < 0:
			missing.append(b)
	check(missing.is_empty(), "all 31 animated bones present (missing: %s), skeleton has %d bones" % [str(missing), sk.get_bone_count()])

	var meshes: Array = []
	collect(root, "MeshInstance3D", meshes)
	var bad: Array = []
	for m in meshes:
		var mi: MeshInstance3D = m
		if mi.skin == null or mi.get_node_or_null(mi.skeleton) != sk:
			bad.append(mi.name)
	check(meshes.size() == 7 and bad.is_empty(), "%d MeshInstance3D, all skinned to the skeleton (bad: %s)" % [meshes.size(), str(bad)])

	var players: Array = []
	collect(root, "AnimationPlayer", players)
	check(players.size() == 1, "one AnimationPlayer")
	if players.size() != 1:
		return
	var ap: AnimationPlayer = players[0]
	var names := ap.get_animation_list()
	check(names.size() >= 150, "AnimationPlayer has %d animations (>=150)" % names.size())
	for a in REQUIRED_ANIMS:
		check(ap.has_animation(a), "has animation %s" % a)
	if not ap.has_animation("KB_Idle_1") or not ap.has_animation("KB_m_Jab_L"):
		return

	# height: head bone in idle, plus top of mesh AABB
	ap.play("KB_Idle_1")
	ap.seek(0.0, true)
	var head_y := bone_pos(sk, "head").y
	check(head_y > 1.5 and head_y < 1.75, "idle head bone Y = %.3f m (1.5..1.75)" % head_y)
	var top := -INF
	var bottom := INF
	for m in meshes:
		var mi: MeshInstance3D = m
		var bb := mi.get_aabb()
		top = max(top, bb.end.y)
		bottom = min(bottom, bb.position.y)
	print("  info mesh AABB y range (rest-skin AABB): %.3f .. %.3f" % [bottom, top])
	var feet_y := minf(bone_pos(sk, "lFoot").y, bone_pos(sk, "rFoot").y)
	check(feet_y > 0.0 and feet_y < 0.15, "idle ankle bones near the floor: %.3f m" % feet_y)
	var pel := bone_pos(sk, "pelvis")
	check(absf(pel.x) < 0.1 and absf(pel.z) < 0.15, "pelvis XZ near origin: (%.3f, %.3f)" % [pel.x, pel.z])

	# jab: which hand extends away from the chest, and by how much (peak chest-hand distance minus idle chest-hand distance)
	var idle_ext := {}
	for h in ["lHand", "rHand"]:
		idle_ext[h] = (bone_pos(sk, h) - bone_pos(sk, "chestUpper")).length()
	ap.play("KB_m_Jab_L")
	var jab := ap.get_animation("KB_m_Jab_L")
	var best := {"lHand": -INF, "rHand": -INF}
	var t := 0.0
	while t <= jab.length:
		ap.seek(t, true)
		var chest := bone_pos(sk, "chestUpper")
		for h in ["lHand", "rHand"]:
			best[h] = max(best[h], (bone_pos(sk, h) - chest).length() - idle_ext[h])
		t += 1.0 / 30.0
	print("  info jab reach gain over idle  lHand=%.3f  rHand=%.3f" % [best["lHand"], best["rHand"]])
	var lead: String = "lHand" if best["lHand"] > best["rHand"] else "rHand"
	check(best[lead] > 0.25, "KB_m_Jab_L: %s moves forward %.3f m (>0.25) farther from the chest than in idle" % [lead, best[lead]])
	check(lead == "lHand", "KB_m_Jab_L is thrown by lHand")
	root.queue_free()

