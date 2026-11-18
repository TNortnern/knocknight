extends SceneTree
# godot --headless --path . --script res://tools/measure_strikes.gd  -> writes data/strike_measure.json
func _initialize():
	var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/strike_table.json"))
	# punch variants (data/punch_variants.json) are measured per variant tag: base row + the variant's clip
	var vtxt := FileAccess.get_file_as_string("res://data/punch_variants.json")
	if vtxt != "":
		var variants: Dictionary = JSON.parse_string(vtxt)
		for vk in variants:
			var row: Dictionary = (table[variants[vk]["base"]] as Dictionary).duplicate()
			row["clip"] = variants[vk]["clip"]
			row["action"] = variants[vk].get("action", row["action"])
			table[vk] = row
	var p: PackedScene = load("res://assets/fighters/viper.glb")
	var r = p.instantiate()
	get_root().add_child(r)
	await process_frame
	var sk: Skeleton3D = r.find_child("Skeleton3D", true, false)
	var ap: AnimationPlayer = r.find_child("AnimationPlayer", true, false)
	var out := {}
	for tag in table:
		var s: Dictionary = table[tag]
		var clip: String = s["clip"]
		if not ap.has_animation(clip):
			print("missing ", clip); continue
		var a := ap.get_animation(clip)
		var limb: String = String(s["limb"]).to_lower()
		var tipb := sk.find_bone(limb + ("Mid1" if s["source"] == "hand" else "Metatarsals"))
		var pelb := sk.find_bone("pelvis")
		var n := int(a.length * 120.0)
		var ext := PackedFloat32Array(); var hgt := PackedFloat32Array()
		ap.play(clip)
		for i in n + 1:
			ap.seek(float(i) / 120.0, true)
			var t := sk.get_bone_global_pose(tipb).origin - sk.get_bone_global_pose(pelb).origin
			ext.append(Vector2(t.x, t.z).length()); hgt.append(t.y)
		var mx := -INF; var mn := INF; var pk := 0
		for i in ext.size():
			if ext[i] > mx: mx = ext[i]; pk = i
			mn = min(mn, ext[i])
		var thr := mn + 0.65 * (mx - mn)
		var i0 := pk; var i1 := pk
		while i0 > 0 and ext[i0 - 1] >= thr: i0 -= 1
		while i1 < ext.size() - 1 and ext[i1 + 1] >= thr: i1 += 1
		out[tag] = {"len": a.length, "peak": pk / 120.0, "w0": i0 / 120.0, "w1": i1 / 120.0, "ext_max": snappedf(mx, 0.001), "h_at_peak": snappedf(hgt[pk], 0.001)}
		var A: float = s["action"]
		var k := A / a.length
		print("%-18s A=%.2f len=%.2f  spec %.2f-%.2f  meas %.2f-%.2f (peak %.2f) ext=%.2f h=%.2f" % [tag, A, a.length, s["c0"], s["c1"], i0/120.0*k, i1/120.0*k, pk/120.0*k, mx, hgt[pk]])
	var f := FileAccess.open("res://data/strike_measure.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out, " "))
	f.close()
	quit()
