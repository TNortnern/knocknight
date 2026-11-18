extends SceneTree
## Windowed, for Godot's movie maker: films one scripted combo (or a CPU-vs-CPU stretch) with the normal gameplay camera so it can
## be cut next to the tempo reference. Strikes go in as "<tag>@auto", the same variant / hold roll a player's press gets.
## Writes _build/tempo/<tag>.json: process frame of every press, attack start, contact and return to guard, plus the variant.
##   <godot> --path . --resolution 1280x720 --write-movie _build/tempo/jab_hook.avi --script res://tools/film_tempo_demo.gd -- tag=jab_hook seq=LJab:0,RHook:0.15
##   seq: tag:press_delay_s (after the previous press) ... | mode=fight secs=20 films a hard CPU-vs-CPU fight instead
func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var i: int = a.find("=")
		if i > 0:
			args[a.substr(0, i)] = a.substr(i + 1)
	var tag: String = args.get("tag", "demo")
	var fight: bool = args.get("mode", "combo") == "fight"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/tempo"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "cpu" if fight else "dummy", "p2_controller": "cpu" if fight else "dummy",
		"intro_delay": 0.0, "p1_model": args.get("att", "meshy_viper"), "p2_model": args.get("foe", "meshy_oak"), "rules": "boxing",
		"rounds": 3, "round_seconds": 180.0, "cpu_difficulty": "hard", "arena": "ring"})
	await process_frame
	for cl in main.find_children("*", "CanvasLayer", true, false):   # no HUD / banners over the fighters
		(cl as CanvasLayer).visible = false
	var f: Array = main.current_match.get_fighters()
	var a: Fighter = f[0]
	var d: Fighter = f[1]
	var ev := {"tag": tag, "presses": [], "starts": [], "contacts": [], "guard": [], "variants": []}
	var pf := [0]
	for fi in f:
		fi.hit_landed.connect(func(_att, inf):
			ev["contacts"].append({"frame": pf[0], "zone": inf.get("zone", ""), "blocked": inf.get("blocked", false)}))
	if fight:
		var secs := float(args.get("secs", "20"))
		var serials := [-1, -1]
		ev["throws"] = []
		for k in int(secs * 60.0):
			await process_frame
			pf[0] += 1
			for j in 2:
				var fj: Fighter = f[j]
				if fj.state == fj.State.ATTACK and not fj.atk.is_empty() and int(fj.atk["serial"]) != serials[j]:
					serials[j] = int(fj.atk["serial"])
					ev["throws"].append([pf[0], j, String(fj.atk["tag"])])
			if paused:
				main.resume()
		_finish(ev, pf[0], tag)
		return
	var gap := float(args.get("gap", "1.0"))
	for fi in f:
		fi.stats.infinite_stamina = true
	a.global_position = Vector3(-gap * 0.5, 0, 0)
	d.global_position = Vector3(gap * 0.5, 0, 0)
	a.external_input = FighterInput.new()
	d.external_input = FighterInput.new()
	var seq: Array = []
	for item in String(args.get("seq", "LJab:0")).split(","):
		var p := item.split(":")
		seq.append([p[0], float(p[1]) if p.size() > 1 else 0.0])
	for k in int(float(args.get("settle", "1.0")) * 60.0):
		await process_frame
		pf[0] += 1
	var last_serial := -1
	var was_attacking := false
	var next := 0
	var wait := 0.0
	var idle_frames := 0
	while true:
		if next < seq.size():
			wait -= 1.0 / 60.0
			if wait <= 0.0:
				var inp := FighterInput.new()
				inp.strikes.append(String(seq[next][0]) + String(args.get("hint", "@auto")))
				a.external_input = inp
				ev["presses"].append({"frame": pf[0], "tag": seq[next][0]})
				next += 1
				if next < seq.size():
					wait = float(seq[next][1])
				await physics_frame   # physics_frame fires before the nodes tick: the fighter reads the press in this tick ...
				await physics_frame
				inp.strikes.clear()   # ... and it is gone before the next one (exactly one press)
		await process_frame
		pf[0] += 1
		var attacking: bool = a.state == a.State.ATTACK and not a.atk.is_empty()
		if args.get("debug", "0") == "1" and pf[0] % 5 == 0:
			print(pf[0], " ", a.state, " ", a.atk.get("tag", "-"), " buf=", a.buffer.size(), " paused=", paused, " locked=", a.input_locked, " phase=", main.current_match.ms.phase)
		if attacking and int(a.atk["serial"]) != last_serial:
			last_serial = int(a.atk["serial"])
			ev["starts"].append(pf[0])
			ev["variants"].append(String(a.atk["tag"]))
		if was_attacking and not attacking:
			ev["guard"].append(pf[0])
		was_attacking = attacking
		idle_frames = 0 if (attacking or next < seq.size()) else idle_frames + 1
		if idle_frames > int(float(args.get("tail", "0.8")) * 60.0) or pf[0] > 60 * 12:
			break
	_finish(ev, pf[0], tag)


func _finish(ev: Dictionary, end_frame: int, tag: String) -> void:
	ev["end_frame"] = end_frame
	var fa := FileAccess.open(ProjectSettings.globalize_path("res://_build/tempo/%s.json" % tag), FileAccess.WRITE)
	fa.store_string(JSON.stringify(ev, "  "))
	fa.close()
	print(JSON.stringify(ev))
	quit(0)
