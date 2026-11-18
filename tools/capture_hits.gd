extends SceneTree
## Windowed capture for the hit contact sheets: one scripted punch in main.tscn (the normal gameplay camera), frames every 4th physics
## tick at --fixed-fps 120 = 30 fps, from the press until 0.5 s after the attack ended. Writes _build/hits/frames/<case>_NNN.png and
## <case>.json (contact frame index, outcome, damage). tools/make_hits_sheet2.py builds the contact sheets from them.
##   <godot> --fixed-fps 120 --path . --script res://tools/capture_hits.gd -- case=jab_head att=meshy_viper foe=meshy_oak tag=LJab gap=1.0 state=idle
##   state: idle | block | slip   (block adds body=1 for body punches via body=1)

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var i: int = a.find("=")
		if i > 0:
			args[a.substr(0, i)] = a.substr(i + 1)
	var cname: String = args.get("case", "case")
	var state: String = args.get("state", "idle")
	var tag: String = args.get("tag", "LJab")
	var gap := float(args.get("gap", "1.0"))
	var every := int(args.get("every", "4"))
	var dir_path := ProjectSettings.globalize_path("res://_build/hits/frames")
	DirAccess.make_dir_recursive_absolute(dir_path)
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "intro_delay": 0.0,
		"p1_model": args.get("att", "meshy_viper"), "p2_model": args.get("foe", "meshy_oak"), "rules": "boxing", "rounds": 1,
		"round_seconds": 600.0, "arena": "ring"})
	await process_frame
	for cl in main.find_children("*", "CanvasLayer", true, false):   # no HUD / round banner over the fighters (the world camera is the normal gameplay one)
		(cl as CanvasLayer).visible = false
	var f: Array = main.current_match.get_fighters()
	var a: Fighter = f[0]
	var d: Fighter = f[1]
	for fi in f:
		fi.stats.infinite_stamina = true
	a.global_position = Vector3(-gap * 0.5, 0, 0)
	d.global_position = Vector3(gap * 0.5, 0, 0)
	a.external_input = FighterInput.new()
	d.external_input = FighterInput.new()
	a.hit_landed.connect(func(_att, inf):
		if hit_tick < 0:
			hit_tick = ticks
			hit_info = inf)
	var settle := 100
	var slip_sign := float(args.get("slip", "1"))
	for k in settle:
		if state == "slip" and k >= settle - 12:
			var di := FighterInput.new()
			di.lean = Vector2(slip_sign, 0.0)
			d.external_input = di
		elif state == "block":
			var di2 := FighterInput.new()
			di2.block = true
			di2.body = args.get("body", "0") == "1"
			d.external_input = di2
		await physics_frame
	var inp := FighterInput.new()
	inp.strikes.append(tag)
	a.external_input = inp
	ticks = 0
	var n := 0
	var ended := -1
	var press_img := 0
	var total := 260
	for k in total:
		if k == 1:
			a.external_input = FighterInput.new()
		if state == "slip":
			var di3 := FighterInput.new()
			di3.lean = Vector2(slip_sign, 0.0)
			d.external_input = di3
		elif state == "block":
			var di4 := FighterInput.new()
			di4.block = true
			di4.body = args.get("body", "0") == "1"
			d.external_input = di4
		await physics_frame
		ticks += 1
		if k % every == 0:
			root.get_viewport().get_texture().get_image().save_png("%s/%s_%03d.png" % [dir_path, cname, n])
			n += 1
		if ended < 0 and a.state != a.State.ATTACK and k > 6:
			ended = k
		if ended >= 0 and k > ended + 60:
			break
	var out := {"case": cname, "frames": n, "every": every, "hit_tick": hit_tick, "hit_frame": (hit_tick / every) if hit_tick >= 0 else -1,
		"tag": tag, "state": state, "gap": gap, "att": args.get("att", "meshy_viper"), "foe": args.get("foe", "meshy_oak"),
		"outcome": a.atk.get("outcome", "") if not a.atk.is_empty() else "",
		"damage": hit_info.get("damage", 0.0), "blocked": hit_info.get("blocked", false), "glance": hit_info.get("glance", false), "strength": hit_info.get("strength", "")}
	var fa := FileAccess.open("%s/%s.json" % [dir_path, cname], FileAccess.WRITE)
	fa.store_string(JSON.stringify(out))
	fa.close()
	print("captured ", cname, " ", out)
	quit(0)


var ticks := 0
var hit_tick := -1
var hit_info := {}
