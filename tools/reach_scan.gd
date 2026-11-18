extends SceneTree
# Which strikes connect at which centre-to-centre gap (idle target). Diagnostic only.
#   godot --headless --fixed-fps 120 --path . --script res://tools/reach_scan.gd [-- tag1 tag2 ...]

const CORE := ["LJab", "RJab", "LHook", "RHook", "LUppercut", "RUppercut", "LBodyJab", "RBodyHook", "LBodyUppercut",
	"LRoundKick", "RRoundKick", "LFrontKick", "RFrontKick", "LBodyRoundKick", "RBodyRoundKick", "LLowKick", "RLowKick", "RPHook", "LPJab"]
const GAPS := [0.70, 0.90, 1.10, 1.30]


func _initialize() -> void:
	var tags: Array = CORE
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		tags = args
	var line := "%-16s" % "strike"
	for g in GAPS:
		line += "%5.2f" % g
	print(line)
	for tag in tags:
		line = "%-16s" % tag
		for g in GAPS:
			var m: Match = load("res://scenes/match.tscn").instantiate()
			m.setup({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 120.0})
			var hit := {"n": 0, "zone": ""}
			m.hit_landed.connect(func(_i, info): hit["n"] += 1; hit["zone"] = info["zone"])
			get_root().add_child(m)
			await process_frame
			var f: Array = m.get_fighters()
			f[0].global_position = Vector3(-g * 0.5, 0, 0)
			f[1].global_position = Vector3(g * 0.5, 0, 0)
			f[0].external_input = FighterInput.new()
			f[1].external_input = FighterInput.new()
			for i in 60:
				await physics_frame
			f[0].external_input.strikes.append(tag)
			await physics_frame
			f[0].external_input.strikes.clear()
			for i in int(120.0 * 2.0):
				await physics_frame
			line += "%5s" % ("hit" if hit["n"] > 0 else " -- ")
			get_root().remove_child(m)
			m.queue_free()
		print(line)
	quit()
