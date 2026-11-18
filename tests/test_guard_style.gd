extends SceneTree
# Guard / stance variety + idle rhythm.
#   godot --headless --path . --script res://tests/test_guard_style.gd --fixed-fps 120
# (run `--headless --import` first on a fresh checkout)

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


func make_duel(gap: float) -> Array:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 300.0,
		"intro_delay": 0.0, "p1_model": "viper", "p2_model": "anvil"})
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	for fx in f:
		fx.external_input = FighterInput.new()
		fx.guard_style.record = true
	await steps(60)
	return f


## bone position relative to the head, in the fighter's own frame
func rel(f: Fighter, bone: String) -> Vector3:
	var gs: GuardStyle = f.guard_style
	var inv := f.global_transform.affine_inverse()
	return inv * gs.snap[bone] - inv * gs.snap["head"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== idle cadence (gap 1.5 m, 12 s)")
	var f: Array = await make_duel(1.5)
	var v: Fighter = f[0]   # viper = keyshawn
	var a: Fighter = f[1]   # anvil = tank
	check(v.guard_style.style_name == "keyshawn" and a.guard_style.style_name == "tank", "styles: viper=keyshawn, anvil=tank")
	var t_start: float = v.guard_style._time
	var hip_y: Array = [[], []]
	for i in 12 * 120:
		await physics_frame
		for k in 2:
			hip_y[k].append(f[k].guard_style.snap["hip"].y)
	var sv := _dwell_stats(v.guard_style.variant_log, t_start)
	var sa := _dwell_stats(a.guard_style.variant_log, t_start)
	print("  keyshawn dwell: ", sv, "   tank dwell: ", sa)
	check(sv["n"] >= 8 and sv["n"] <= 11 and sv["mean"] > 1.05 and sv["mean"] < 1.35, "keyshawn changes guard every ~1.2 s (n=%d mean=%.2f)" % [sv["n"], sv["mean"]])
	check(sa["n"] >= 5 and sa["n"] <= 7 and sa["mean"] > 1.7 and sa["mean"] < 2.3, "tank changes guard every ~2 s (n=%d mean=%.2f)" % [sa["n"], sa["mean"]])
	var seq_v: Array = v.guard_style.variant_log.map(func(e): return e[1])
	var seq_a: Array = a.guard_style.variant_log.map(func(e): return e[1])
	check(str(seq_v) != str(seq_a), "guard sequences differ: %s vs %s" % [str(seq_v), str(seq_a)])
	var times_v: Array = v.guard_style.variant_log.filter(func(e): return e[0] >= t_start).map(func(e): return snappedf(e[0], 0.01))
	var times_a: Array = a.guard_style.variant_log.filter(func(e): return e[0] >= t_start).map(func(e): return snappedf(e[0], 0.01))
	var sync := 0
	for t in times_v:
		if times_a.has(t):
			sync += 1
	check(sync <= 1, "switch times are not in sync (%d coincide)" % sync)
	var no_repeat := true
	for log in [v.guard_style.variant_log, a.guard_style.variant_log]:
		for i in range(1, log.size()):
			if log[i][1] == log[i - 1][1]:
				no_repeat = false
	check(no_repeat, "no immediate repeat of a variant")
	var distinct_v := {}
	var distinct_a := {}
	for s in seq_v:
		distinct_v[s] = true
	for s in seq_a:
		distinct_a[s] = true
	check(distinct_v.size() >= 3 and distinct_a.size() >= 3, "several variants in use (keyshawn %d, tank %d)" % [distinct_v.size(), distinct_a.size()])
	var tank_pp := _median_pp(hip_y[1], 120)
	var key_pp := _median_pp(hip_y[0], 120)
	var tank_hz := _bounce_hz(hip_y[1], 120)
	var dipped := _max_range(hip_y[0], int(0.45 * 120))
	print("  hip peak-to-peak (median per 1 s): tank %.1f cm @ %.2f Hz, keyshawn %.1f cm; keyshawn largest dip %.1f cm" % [tank_pp * 100.0, tank_hz, key_pp * 100.0, dipped * 100.0])
	check(tank_pp >= 0.02 and tank_pp <= 0.05, "tank hip bounce 2-5 cm peak-to-peak (%.1f cm)" % (tank_pp * 100.0))
	check(tank_hz > 1.6 and tank_hz < 2.4, "tank bounce ~2 Hz (%.2f Hz)" % tank_hz)
	check(dipped >= 0.07 and dipped <= 0.14, "keyshawn level-change dip 7-14 cm within 0.45 s (%.1f cm)" % (dipped * 100.0))
	# flat-footed between dips: pin the pose, suppress dips, compare against the tank bounce
	v.guard_style._enter("high", 100.0)
	v.guard_style._dip_next = 99.0
	v.guard_style._dip_t = -1.0
	a.guard_style._enter("high", 100.0)
	await steps(60)
	var flat: Array = []
	var bounce: Array = []
	for i in 4 * 120:
		await physics_frame
		flat.append(v.guard_style.snap["hip"].y)
		bounce.append(a.guard_style.snap["hip"].y)
	var flat_pp := _median_pp(flat, 120)
	var bounce_pp := _median_pp(bounce, 120)
	check(flat_pp < 0.025 and bounce_pp > flat_pp * 1.4, "keyshawn flat-footed (%.1f cm) vs tank bounce (%.1f cm) with the pose pinned" % [flat_pp * 100.0, bounce_pp * 100.0])

	print("== snap back to a protective guard when the foe strikes")
	var gs: GuardStyle = a.guard_style
	for variant in ["down", "feeler", "lead_low", "peek"]:
		v.global_position = Vector3(-0.75, 0, 0)
		a.global_position = Vector3(0.75, 0, 0)
		v.external_input = FighterInput.new()
		gs._enter(variant, 100.0)
		await steps(180)
		var open_d := maxf(rel(a, "lHand").length(), rel(a, "rHand").length())
		check(gs.weight > 0.95, "[%s] style fully on before the strike (w=%.2f, farthest glove %.2f m from head)" % [variant, gs.weight, open_d])
		v.begin_attack("LJab")
		var frames := 0
		var back_frame := -1
		var glove_at_back := 9.0
		var low_at_back := 9.0
		for i in 60:
			await physics_frame
			frames += 1
			if gs.weight <= 0.0 and back_frame < 0:
				back_frame = frames
				glove_at_back = maxf(rel(a, "lHand").length(), rel(a, "rHand").length())
				low_at_back = minf(rel(a, "lHand").y, rel(a, "rHand").y)
		var secs := back_frame / 120.0
		check(back_frame > 0 and secs <= 0.15, "[%s] layer fully released %.3f s after the foe's strike starts (<= 0.15)" % [variant, secs])
		check(glove_at_back < 0.50 and low_at_back > -0.30, "[%s] gloves back near the chin by then (farthest %.2f m, lowest %.2f m rel head)" % [variant, glove_at_back, low_at_back])
		await steps(100)

	print("== inside engage range the layer is off")
	v.external_input = FighterInput.new()
	v.global_position = Vector3(-0.5, 0, 0)
	a.global_position = Vector3(0.5, 0, 0)
	await steps(60)
	check(gs.weight == 0.0 and v.guard_style.weight == 0.0, "gap 1.0 m: both layers at weight 0")

	print("== layer weight during strikes")
	f = await make_duel(1.6)
	v = f[0]
	a = f[1]
	await steps(200)
	check(v.guard_style.weight > 0.9, "free fighter: layer on (w=%.2f)" % v.guard_style.weight)
	v.begin_attack("LJab")
	var zero_during := true
	var seen := 0
	for i in 50:
		await physics_frame
		if v.state == Fighter.State.ATTACK and i > 12:
			seen += 1
			if v.guard_style.weight != 0.0:
				zero_during = false
	check(seen > 3 and zero_during, "own strike: layer weight == 0 for the whole strike after the first 0.1 s (%d frames)" % seen)
	await steps(200)
	check(v.guard_style.weight > 0.9, "layer returns after the strike (w=%.2f)" % v.guard_style.weight)

	print("== hands-down reset after a get-up")
	v.guard_style._enter("high", 100.0)
	await steps(10)
	v._set_state(Fighter.State.GETUP)
	await steps(5)
	v._set_state(Fighter.State.IDLE)
	await steps(2)
	check(v.guard_style.variant == "down", "after a get-up the fighter starts in hands-down (variant=%s)" % v.guard_style.variant)
	await steps(240)
	check(v.guard_style.variant != "down", "hands-down reset expires (variant=%s)" % v.guard_style.variant)

	if failures == 0:
		print("PASS: all guard style checks")
		quit(0)
	else:
		print("FAIL: %d check(s) failed" % failures)
		quit(1)


func _dwell_stats(log: Array, t0: float) -> Dictionary:
	var ts: Array = []
	for e in log:
		if e[0] >= t0:
			ts.append(e[0])
	var mean := 0.0
	for i in range(1, ts.size()):
		mean += ts[i] - ts[i - 1]
	return {"n": ts.size(), "mean": mean / maxf(ts.size() - 1, 1)}


## median over 1 s windows of the peak-to-peak range
func _median_pp(a: Array, hz: int) -> float:
	var vals: Array = []
	var i := 0
	while i + hz <= a.size():
		vals.append(_range(a, i, i + hz))
		i += hz
	vals.sort()
	return vals[vals.size() / 2] if vals.size() > 0 else 0.0


func _range(a: Array, from: int, to: int) -> float:
	var lo := 99.0
	var hi := -99.0
	for j in range(from, to):
		lo = minf(lo, a[j])
		hi = maxf(hi, a[j])
	return hi - lo


func _max_range(a: Array, win: int) -> float:
	var best := 0.0
	for i in range(0, a.size() - win, 3):
		best = maxf(best, _range(a, i, i + win))
	return best


## upward zero crossings per second of the signal minus its 0.5 s moving average
func _bounce_hz(a: Array, hz: int) -> float:
	var cross := 0
	var prev := 0.0
	var win := hz / 4
	var counted := 0
	for i in range(win, a.size() - win):
		var s := 0.0
		for j in range(i - win, i + win):
			s += a[j]
		var d: float = a[i] - s / (2 * win)
		if prev < 0.0 and d >= 0.0:
			cross += 1
		prev = d
		counted += 1
	return cross / (counted / float(hz))


## signal minus its 0.5 s moving average (removes slow guard-variant height changes)
func _high_pass(a: Array, hz: int) -> Array:
	var out: Array = []
	var win := hz / 4
	for i in a.size():
		var lo := maxi(i - win, 0)
		var hi := mini(i + win, a.size() - 1)
		var s := 0.0
		for j in range(lo, hi + 1):
			s += a[j]
		out.append(a[i] - s / (hi - lo + 1))
	return out
