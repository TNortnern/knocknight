extends SceneTree
## Which centre-to-centre gaps each punch variant lands at on an idle foe (physics hit path). Writes `range`
## ([lo, hi] of the contiguous run of hitting gaps around the best one) into data/punch_variants.json when `write` is given.
##   godot --headless --fixed-fps 120 --path . --script res://tools/scan_variants.gd -- [write] [tag ...]

const GAPS := [0.60, 0.66, 0.72, 0.78, 0.84, 0.90, 0.96, 1.02, 1.08, 1.14, 1.20, 1.28, 1.36, 1.44, 1.52, 1.60, 1.68, 1.76]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var tags := []
	var write := false
	for a in OS.get_cmdline_user_args():
		if a == "write":
			write = true
		else:
			tags.append(a)
	var vtxt := FileAccess.get_file_as_string("res://data/punch_variants.json")
	var variants: Dictionary = JSON.parse_string(vtxt)
	if tags.is_empty():
		for k in variants:
			tags.append(k)
		for b in ["LJab", "RJab", "LHook", "RHook", "LUppercut", "RUppercut", "LBodyJab", "RBodyJab", "LBodyHook", "RBodyHook", "LBodyUppercut", "RBodyUppercut"]:
			tags.append(b)
	for tag in tags:
		var line := "%-22s" % tag
		var hits := []
		for g in GAPS:
			var m: Match = load("res://scenes/match.tscn").instantiate()
			m.setup({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 120.0, "intro_delay": 0.0})
			var hit := {"n": 0}
			m.hit_landed.connect(func(_i, _info): hit["n"] += 1)
			get_root().add_child(m)
			await process_frame
			var f: Array = m.get_fighters()
			f[0].global_position = Vector3(-g * 0.5, 0, 0)
			f[1].global_position = Vector3(g * 0.5, 0, 0)
			f[0].external_input = FighterInput.new()
			f[1].external_input = FighterInput.new()
			for i in 50:
				await physics_frame
			f[0].external_input.strikes.append(tag)
			await physics_frame
			f[0].external_input.strikes.clear()
			for i in 150:
				await physics_frame
			hits.append(hit["n"] > 0)
			line += "%5s" % ("hit" if hit["n"] > 0 else "--")
			get_root().remove_child(m)
			m.queue_free()
		print(line)
		if write and variants.has(tag):
			var lo := -1.0
			var hi := -1.0
			for i in GAPS.size():
				if hits[i]:
					if lo < 0.0:
						lo = GAPS[i]
					hi = GAPS[i]
			variants[tag]["range"] = [lo, hi]
	if write:
		var out := FileAccess.open("res://data/punch_variants.json", FileAccess.WRITE)
		out.store_string(JSON.stringify(variants, " "))
		out.close()
	var hdr := "%-22s" % "gap"
	for g in GAPS:
		hdr += "%5.2f" % g
	print(hdr)
	quit(0)
