extends SceneTree
# Guard coverage model, parry, glove knock.
#   godot --headless --path . --script res://tests/test_guard.gd --fixed-fps 120

const GM := preload("res://scripts/combat/guard_model.gd")
const ExchangeScript := preload("res://scripts/combat/exchange.gd")
var failures := 0
var m: Match
var infos: Array = []


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


## Fresh duel: fighter 0 = attacker (viper), fighter 1 = defender (`def_model`).
func duel(def_model: String, gap := 0.80) -> Array:
	if m != null:
		get_root().remove_child(m)
		m.queue_free()
		await process_frame
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1, "round_seconds": 600.0,
		"intro_delay": 0.0, "p1_model": "viper", "p2_model": def_model})
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	f[0].global_position = Vector3(-gap * 0.5, 0, 0)
	f[1].global_position = Vector3(gap * 0.5, 0, 0)
	for fx in f:
		fx.external_input = FighterInput.new()
		fx.stats.infinite_stamina = true
		fx.guard_style.record = true
		fx.guard_knock.record = true
	infos.clear()
	m.hit_landed.connect(func(_i, info): infos.append(info))
	await steps(90)
	return f


## Throws `tag` and holds / presses the defender's block. mode: "held" (guard up 0.5 s before), "press" (press `lead` s before
## contact), "mash" (an earlier press 0.45 s before the second). Returns the first hit info (or {}).
func throw(f: Array, tag: String, mode: String, lead := 0.05, body_guard := false) -> Dictionary:
	var att: Fighter = f[0]
	var def: Fighter = f[1]
	infos.clear()
	var s := StrikeDB.get_strike(tag)
	if mode == "held":
		def.external_input.block = true
		def.external_input.body = body_guard
		await steps(100 if body_guard else 60)
	elif mode == "mash":
		def.external_input.block = true
		await steps(12)
		def.external_input.block = false
		await steps(24)
	att.begin_attack(tag)
	var pressed := mode == "held"
	var i := 0
	while i < 240 and infos.is_empty():
		await physics_frame
		i += 1
		if not pressed and att.state == Fighter.State.ATTACK and not att.atk.is_empty():
			if ExchangeScript.time_to_contact(att.atk) <= lead + 0.004:
				def.external_input.block = true
				pressed = true
	return infos[0] if not infos.is_empty() else {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== guard model (pure)")
	var jab := StrikeDB.get_strike("LJab")
	var hook_w := StrikeDB.get_strike("RHook~wide")
	var hook_t := StrikeDB.get_strike("RHook~tight")
	var upper := StrikeDB.get_strike("RUppercut")
	var set_guard := {"style": "high", "age": 0.5, "guard_ratio": 1.0, "fatigue": 0.0, "graze": 0.0, "open": 0.0, "body_guard": false}
	check(GM.assess(jab, set_guard)["kind"] == "full", "jab into a set high guard: full block")
	check(GM.assess(hook_t, set_guard)["kind"] == "full", "tight hook into a set high guard: full block")
	check(GM.assess(hook_w, set_guard)["kind"] == "pierce", "wide hook around a high guard: pierce")
	check(GM.assess(upper, set_guard)["kind"] != "full", "uppercut into a high guard: not a full block (%s)" % GM.assess(upper, set_guard)["kind"])
	var peek := set_guard.duplicate()
	peek["style"] = "peek"
	check(GM.assess(hook_w, peek)["kind"] != "full", "wide hook vs peek-a-boo: partial / pierce")
	check(GM.assess(jab, peek)["kind"] == "full", "jab vs peek-a-boo: full block")
	var late := set_guard.duplicate()
	late["age"] = 0.05
	check(GM.assess(jab, late)["kind"] == "partial", "jab into a guard raised 0.05 s ago: leaks (partial)")
	var weak := set_guard.duplicate()
	weak["guard_ratio"] = 0.1
	check(GM.assess(jab, weak)["leak"] > GM.assess(jab, set_guard)["leak"] + 0.2, "a drained guard meter leaks more")
	check(GM.is_parry(jab, 0.08, 0.0, true, 50.0) and not GM.is_parry(jab, 0.08, 0.0, false, 50.0) and not GM.is_parry(jab, 0.30, 0.0, true, 50.0)
		and not GM.is_parry(jab, 0.01, 0.0, true, 50.0), "parry window: 0.03-0.15 s after a fresh, un-mashed press")
	check(not GM.is_parry(upper, 0.08, 0.0, true, 50.0) and not GM.is_parry(hook_w, 0.08, 0.0, true, 50.0), "uppercuts and loaded hooks cannot be parried")
	check(GM.parry_window(jab, 0.9).y < GM.parry_window(jab, 0.0).y - 0.03, "tired fighters get a narrower parry window")

	print("== in the ring: block outcomes")
	var f: Array = await duel("anvil")
	var info := await throw(f, "LJab", "held")
	check(info.get("blocked", false) and not info.get("partial", false) and not info.get("pierce", false) and not info.get("parry", false),
		"straight into a held high guard: full block (chip only, damage %.2f)" % float(info.get("damage", -1)))
	var plain_len := await _recovery_len(f[0])
	print("  (plain block: attacker back to idle %.2f s after the hit)" % plain_len)

	f = await duel("viper")
	info = await throw(f, "RHook~wide", "held")
	# contact-only hits: a wide hook that wraps round the gloves without touching them is simply a clean hit (no guard contact, no
	# assessment); one that grazes a glove / forearm is pierced. Either way it lands and is not blocked.
	var pierced: bool = info.get("pierce", false)
	check(not info.get("blocked", true) and float(info.get("damage", 0)) > 1.0 and (pierced or f[1].last_assess.is_empty()),
		"wide hook vs peek-a-boo guard: gets round / through the gloves (damage %.1f, %s)" % [float(info.get("damage", 0)), str(f[1].last_assess.get("kind", "no glove contact"))])
	check(not pierced or float(info.get("quality", 1.0)) <= 0.65, "a pierce is never a flooring shot (quality capped)")

	f = await duel("anvil")
	info = await throw(f, "RUppercut", "held")
	check(info.get("partial", false) or info.get("pierce", false), "uppercut into a high guard: partial / pierce (%s)" % str(f[1].last_assess.get("kind")))

	f = await duel("anvil")
	info = await throw(f, "RBodyHook", "held")
	check(info.get("zone", "") == "body" and not info.get("blocked", true) and float(info.get("damage", 0)) > 2.0,
		"body shot vs a high guard lands clean (damage %.1f)" % float(info.get("damage", 0)))
	f = await duel("anvil", 0.62)   # literal hooks end at chin / throat height: contact needs the closer range
	info = await throw(f, "RHook", "held", 0.05, true)
	check(info.get("zone", "") == "head" and not info.get("blocked", true) and float(info.get("damage", 0)) > 2.0,
		"head shot vs a body guard lands clean (damage %.1f)" % float(info.get("damage", 0)))
	f = await duel("anvil")
	info = await throw(f, "RBodyHook", "held", 0.05, true)
	check(info.get("blocked", false) or info.get("partial", false), "body shot vs a body guard is blocked")

	print("== guard raised just before contact")
	f = await duel("anvil")
	f[1]._press_ok = false
	info = await throw(f, "LJab", "mash", 0.03)   # the glove meets the guard ~0.025 s after the window opens (time_to_contact): ~0.05 s before contact
	var la: Dictionary = f[1].last_assess
	check(la.get("kind", "") in ["partial", "pierce"] and float(la.get("age", 9)) < 0.12,
		"mashed press 0.05 s before contact: no parry, the guard leaks (%s, age %.3f s, damage %.2f)" % [la.get("kind"), float(la.get("age", 9)), float(info.get("damage", 0))])

	print("== parry")
	f = await duel("anvil")
	var stam0: float = f[1].stats.stamina
	f[1].stats.infinite_stamina = false
	stam0 = f[1].stats.stamina
	info = await throw(f, "LJab", "press", 0.07)
	la = f[1].last_assess
	check(info.get("parry", false) and la.get("kind", "") == "parry", "block pressed ~0.07 s before a jab: PARRY (age %.3f s)" % float(la.get("age", 9)))
	check(float(info.get("damage", 1)) == 0.0 and f[1].stats.guard >= f[1].stats.guard_max - 0.01, "a parry costs no damage and no guard meter")
	check(f[1].stats.stamina < stam0 or f[1].stats.stamina_ratio() >= 0.999, "a parry costs stamina")
	check(f[0].atk.get("outcome", "") == "parried" and f[0].atk.get("parried", false), "attacker's punch is marked parried")
	var parried_t0: float = f[0].atk["t"]
	var p_left: float = f[0].atk["A"] - parried_t0 + f[0].atk["tail"]
	check(f[1].counter_window > 0.3, "parrier gets a counter window (%.2f s)" % f[1].counter_window)
	# attacker is locked in recovery; the parrier's jab is a counter
	f[1].begin_attack("RJab")
	infos.clear()
	var j := 0
	while j < 200 and infos.is_empty():
		await physics_frame
		j += 1
	var ci: Dictionary = infos[0] if not infos.is_empty() else {}
	check(not ci.is_empty() and ci.get("counter", false) and not ci.get("blocked", true),
		"the punish lands as a COUNTER (damage %.1f) while the parried attacker is still recovering (state %s)" % [float(ci.get("damage", 0)), f[0].state_name])
	var parry_len := p_left
	check(parry_len - plain_len >= 0.22, "parried recovery is %.2f s vs %.2f s for a plain block (+%.2f)" % [parry_len, plain_len, parry_len - plain_len])

	f = await duel("anvil")
	f[1].stats.infinite_stamina = false
	f[1].external_input.block = true
	await steps(60)   # long-held guard: a plain block, no parry
	info = await throw(f, "LJab", "held")
	check(not info.get("parry", false), "a held guard never parries")

	print("== glove knock")
	f = await duel("anvil")
	var d: Fighter = f[1]
	d.external_input.block = true
	await steps(90)
	var base_l: Vector3 = d.guard_knock.snap["lHand"]
	var base_r: Vector3 = d.guard_knock.snap["rHand"]
	infos.clear()
	f[0].begin_attack("LJab")
	var peak := 0.0
	var peak_off := 0.0
	var hit_at := -1
	var n := 0
	var back_l := 9.0
	var back_r := 9.0
	for k in 360:
		await physics_frame
		n += 1
		if hit_at < 0 and not infos.is_empty():
			hit_at = n
		var dl: float = (d.guard_knock.snap["lHand"] as Vector3).distance_to(d.guard_knock.snap_pre["lHand"])
		var dr: float = (d.guard_knock.snap["rHand"] as Vector3).distance_to(d.guard_knock.snap_pre["rHand"])
		if hit_at >= 0:
			peak = maxf(peak, maxf(dl, dr))
			peak_off = maxf(peak_off, maxf((d.guard_knock.off["l"] as Vector3).length(), (d.guard_knock.off["r"] as Vector3).length()))
			if n - hit_at == 48:   # 0.4 s after contact
				back_l = dl
				back_r = dr
	check(hit_at > 0 and peak > 0.03, "blocked jab moves the defender's glove %.1f cm (> 3 cm; knock offset %.1f cm)" % [peak * 100.0, peak_off * 100.0])
	check(maxf(back_l, back_r) < 0.012, "gloves are back within 1 cm 0.4 s later (%.1f / %.1f cm)" % [back_l * 100.0, back_r * 100.0])

	if failures == 0:
		print("PASS: all guard checks")
		quit(0)
	else:
		print("FAIL: %d guard checks" % failures)
		quit(1)


## Seconds the attacker's punch (already landed) stays in its ATTACK state from now.
func _recovery_len(att: Fighter) -> float:
	var t0: float = att.atk.get("t", 0.0) if not att.atk.is_empty() else 0.0
	if att.atk.is_empty():
		return 0.0
	var left: float = att.atk["A"] - t0 + att.atk["tail"]
	return left
