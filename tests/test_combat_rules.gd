extends SceneTree
# Pure-rules unit test.  godot --headless --path . --script res://tests/test_combat_rules.gd

var failures := 0

func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func near(a: float, b: float, eps := 0.06) -> bool:
	return absf(a - b) <= eps

func _initialize() -> void:
	print("== strike database")
	check(StrikeDB.all_tags().size() == 74, "74 strikes loaded")
	var jab := StrikeDB.get_strike("LJab")
	check(jab["clip"] == "L J" and jab["zone"] == "head" and near(jab["action"], 0.58), "LJab clip/zone/action from spec table")
	check(jab["w1"] > jab["w0"] and jab["w1"] <= jab["action"], "LJab active window %.3f-%.3f inside action %.2f" % [jab["w0"], jab["w1"], jab["action"]])
	check(StrikeDB.resolve_tag("L", "Jab", true, false) == "LBodyJab", "body modifier + jab -> LBodyJab")
	check(StrikeDB.resolve_tag("R", "Kick", false, true) == "RFrontKick", "spec modifier + kick -> RFrontKick")
	check(StrikeDB.resolve_tag("R", "Kick", true, false) == "RBodyRoundKick", "body + kick -> RBodyRoundKick")
	check(StrikeDB.resolve_tag("L", "Low", true, false) == "LLowKick", "low kick wins over body")
	check(StrikeDB.get_strike("RHook")["heavy"] and not jab["heavy"] and StrikeDB.get_strike("LRoundKick")["heavy"], "heavy classification (hook, kick heavy; jab light)")

	print("== damage")
	var d := CombatRules.compute_damage(jab, {"quality": 1.0})
	# fatigue pass: DAMAGE_SCALE 0.7 -> 0.55 (fights ended in round 1), so every spec damage below is x(0.55/0.7)
	check(near(d["total"], 3.025), "clean LJab = %.2f (spec 3.9 x 0.55/0.7)" % d["total"])
	var d2 := CombatRules.compute_damage(StrikeDB.get_strike("RHook"), {"quality": 1.0})
	check(near(d2["total"], 7.7), "clean RHook = %.2f (capped 14 x 0.55)" % d2["total"])
	var dq := CombatRules.compute_damage(jab, {"quality": 0.0})
	check(near(dq["total"], 3.025 * 0.45 / 1.0, 0.1), "zero-quality graze scales damage by 0.45: %.2f" % dq["total"])
	var dc := CombatRules.compute_damage(jab, {"quality": 1.0, "counter": true})
	check(near(dc["total"], d["total"] * 1.25), "earned counter x1.25: %.2f" % dc["total"])
	var dt := CombatRules.compute_damage(jab, {"quality": 1.0, "def_taunting": true})
	check(dt["total"] > d["total"] * 1.5, "taunting defender takes much more: %.2f" % dt["total"])
	var dtired := CombatRules.compute_damage(jab, {"quality": 1.0, "def_stamina_ratio": 0.0})
	check(near(dtired["total"], d["total"] * 1.25), "exhausted defender +25%%: %.2f" % dtired["total"])
	var drocked := CombatRules.compute_damage(jab, {"quality": 1.0, "attacker_rocked": true})
	check(near(drocked["total"], 5.0 * 0.72 * 1.1 * 0.55), "rocked attacker x0.72: %.2f" % drocked["total"])
	check(CombatRules.damage_cap(StrikeDB.get_strike("LPHook")) == 20.0 and CombatRules.damage_cap(StrikeDB.get_strike("LRoundKick")) == 18.0, "damage caps")

	print("== guard / stamina / tails")
	check(near(CombatRules.guard_loss(jab), 14.5), "jab guard loss clamp(5*1.5+7) = %.1f" % CombatRules.guard_loss(jab))
	check(CombatRules.guard_loss(StrikeDB.get_strike("RRoundKick")) == 32.0 * 0.0 + clampf(35 * 1.5 + 7, 13, 32), "heavy kick guard loss clamps at 32")
	check(near(CombatRules.outcome_tail(StrikeDB.get_strike("RHook"), "missed"), 0.24), "heavy missed tail 0.24")
	check(near(CombatRules.outcome_tail(jab, "blocked"), 0.04), "light blocked tail 0.04")
	check(CombatRules.reaction_cap(jab) == 0.20 and CombatRules.reaction_cap(StrikeDB.get_strike("RHook")) == 0.28 and CombatRules.reaction_cap(StrikeDB.get_strike("RRoundKick")) == 0.34, "reaction caps 0.20/0.28/0.34")
	var st := FighterStats.new()
	check(st.can_spend(5.0), "full stamina can spend")
	st.stamina = 8.0
	check(not st.can_spend(5.0), "needs stamina >= 10 to start any strike")
	st.stamina = 100.0
	st.spend_stamina(10.0)
	st.tick(0.1, false, false)
	check(near(st.stamina, 90.0), "stamina regen locked 0.25 s after spend (%.1f)" % st.stamina)
	st.tick(1.0, false, false)
	check(st.stamina > 100.0, "stamina regen 26/s after the lock (%.1f)" % st.stamina)
	var st2 := FighterStats.new()
	st2.stamina = 50.0
	st2.tick(1.0, true, false)
	# fatigue pass: regen 22/s -> 26/s standing off, guarding 11 -> 10/s (moving 15, mid-strike 2)
	check(near(st2.stamina, 50.0 + CombatRules.STAMINA_REGEN_GUARD, 0.2), "stamina regen slows (%.0f/s) while guarding (%.1f)" % [CombatRules.STAMINA_REGEN_GUARD, st2.stamina])
	var g := FighterStats.new()
	g.guard = 40.0
	g.tick(1.0, true, false)
	check(near(g.guard, 40.0), "guard does not regen while block held")
	g.tick(1.0, false, false)
	check(near(g.guard, 58.0), "guard regens 18/s when released")
	g.guard = 40.0
	g.guard_regen_lock = 1.1
	g.tick(1.0, false, false)
	check(near(g.guard, 40.0 + 0.0, 0.01) or near(g.guard, 40.0 + 18.0 * 0.0, 0.01), "guard regen lock 1.1 s after a blocked hit (%.1f)" % g.guard)

	print("== rocked / knockdown / KO")
	check(CombatRules.should_rock(13.0, 0.0, 90.0, 100.0), "total >= 12.5 rocks")
	check(CombatRules.should_rock(5.0, 41.0, 90.0, 100.0), "rock meter >= %d rocks" % int(CombatRules.ROCK_METER))
	check(not CombatRules.should_rock(5.0, 5.0, 90.0, 100.0), "light hit does not rock")
	var sev := CombatRules.rock_severity(14.0, 20.0, 70.0, 100.0)
	check(sev >= 0.35 and sev <= 1.0 and CombatRules.rock_duration(sev) >= 3.5 and CombatRules.rock_duration(1.0) == 6.0, "rock duration 3.2+2.8*severity, max 6 s")
	# fatigue pass: an unrocked fighter goes down only below head 28 %% (was 50 %%); a rocked one below 65 %%
	var kd := {"power": true, "kick": false, "speed": 5.0, "quality": 0.9, "launch_stamina_ratio": 0.8, "head_ratio": 0.25, "exposed": true}
	check(CombatRules.assess_knockdown(kd), "power head hit on exposed, damaged defender knocks down")
	kd["head_ratio"] = 0.8
	check(not CombatRules.assess_knockdown(kd), "healthy head never knocks down")
	kd["head_ratio"] = 0.25
	kd["exposed"] = false
	check(not CombatRules.assess_knockdown(kd), "unexposed defender does not go down")
	kd["exposed"] = true
	kd["power"] = false
	check(not CombatRules.assess_knockdown(kd), "non-power strike does not knock down")
	kd["power"] = true
	kd["head_ratio"] = 0.55
	check(not CombatRules.assess_knockdown(kd), "unrocked fighter at head 55 % stays up")
	kd["rocked"] = true
	check(CombatRules.assess_knockdown(kd), "a rocked fighter at head 55 % goes down to a power shot")
	kd["grace"] = true
	check(not CombatRules.assess_knockdown(kd), "no second knockdown inside the get-up grace window")
	var a := FighterStats.new()
	a.head_max = 0.0
	check(a.is_ko(), "any max <= 0 = KO")
	var b := FighterStats.new()
	b.head = 50.0
	b.head_max = 60.0
	b.rehab()
	check(near(b.head_max, 80.0), "between rounds max = min(current+30, 100): %.0f" % b.head_max)

	print("== reaction clip names exist in the library")
	var viper: Node = (load("res://assets/fighters/viper.glb") as PackedScene).instantiate()
	get_root().add_child(viper)
	await process_frame
	var ap: AnimationPlayer = viper.find_child("AnimationPlayer", true, false)
	var names := []
	for dir in ["F", "L", "R", "U", "O"]:
		for kind in ["punch", "kick", "break", "stun", "ko", "body_kick", "body_break", "body_pko", "body_ko"]:
			names.append(CombatRules.hit_clip(dir, kind))
	var missing := []
	for n in names:
		if not ap.has_animation(n):
			missing.append(n)
	check(missing.is_empty(), "all %d reaction clip names resolve (missing: %s)" % [names.size(), str(missing)])
	var strike_missing := []
	for tag in StrikeDB.all_tags():
		if not ap.has_animation(StrikeDB.get_strike(tag)["clip"]):
			strike_missing.append(tag)
	check(strike_missing.is_empty(), "all 74 strike clips exist (missing: %s)" % str(strike_missing))
	var dec := MatchState.decide(FighterStats.new(), FighterStats.new())
	check(dec["method"] == "Draw", "equal pools -> Draw")
	var weak := FighterStats.new()
	weak.body_max = 50.0
	check(MatchState.decide(FighterStats.new(), weak)["winner"] == 0, "higher sum of max pools wins the decision")

	if failures == 0:
		print("PASS: combat rules")
		quit(0)
	else:
		print("FAIL: %d check(s) failed" % failures)
		quit(1)
