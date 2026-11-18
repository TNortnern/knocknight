extends SceneTree
# Hit registration and hit reactions on what the player SEES (Meshy fighters; tools/probe_hits.gd is the full version of this):
#  A. every punch whose visible glove touches the visible foe registers an outcome (no silent whiff), for an idle foe, a blocking foe and a slipping foe
#  B. every registered outcome is felt: clean hits snap the head / chest, blocks drive the struck glove back, glances move something
#  C. a landed head blow never shows the glove through the skull (share of glove samples inside the visible head stays small)
#  D. the volumes ride the visible skeleton: the fist sphere / head hull stay on the visible glove / head while the pose changes
#  E. the impact layer's clamp is invisible to the hit sweeps (Hitbox.clamp_delta), a hold never changes who hit whom
# godot --headless --fixed-fps 120 --path . --script res://tests/test_hit_registration.gd
# Prints PASS/FAIL and exits 0 / 1.

const SkinSampler := preload("res://tools/skin_sampler.gd")

var failures := 0
var m: Match
var holder: Node
var F: Array = []
var samplers: Array = []
var rec := {}
var tracking := false
var infos: Array = [null, null]
var traj: Array = []


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func steps(n: int) -> void:
	for i in n:
		await physics_frame


func make_match(p1: String, p2: String) -> void:
	if holder != null and is_instance_valid(holder):
		holder.queue_free()
		await process_frame
	m = load("res://scenes/match.tscn").instantiate()
	holder = m
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "rounds": 1,
		"round_seconds": 900.0, "p1_model": p1, "p2_model": p2, "rules": "boxing"})
	get_root().add_child(m)
	await process_frame
	F = m.get_fighters()
	for fi in F:
		fi.external_input = FighterInput.new()
		fi.stats.infinite_stamina = true
	samplers = [SkinSampler.make(F[0]), SkinSampler.make(F[1])]
	F[0].hit_landed.connect(func(_a, info): infos[0] = info)


## one punch: returns {outcome, damage, vis_min, inside, react_head, react_chest, react_glove}
func punch(tag: String, gap: float, state: String) -> Dictionary:
	await make_match(_p1, _p2)
	F[0].global_position = Vector3(-gap * 0.5, 0, 0)
	F[1].global_position = Vector3(gap * 0.5, 0, 0)
	var foe_in := FighterInput.new()
	if state == "block":
		foe_in.block = true
		foe_in.body = tag.contains("Body")
	F[1].external_input = foe_in
	await steps(88)
	if state == "slip":
		foe_in = FighterInput.new()
		foe_in.lean = Vector2(1, 0)
		F[1].external_input = foe_in
	await steps(12)
	infos = [null, null]
	traj = []
	rec = {"vis_min": 9.0, "inside": 0.0, "hit_i": -1}
	var inp := FighterInput.new()
	inp.strikes.append(tag)
	F[0].external_input = inp
	tracking = true
	var ended := -1
	for k in 260:
		if k == 1:
			F[0].external_input = FighterInput.new()
		await physics_frame
		_track(k)
		if ended < 0 and k > 6 and F[0].state != F[0].State.ATTACK:
			ended = k
		if ended >= 0 and k > ended + 40:
			break
	tracking = false
	var atk: Dictionary = F[0].atk
	var out := {"vis_min": rec["vis_min"], "inside": rec["inside"], "outcome": "whiff", "damage": 0.0}
	var why: String = String(rec.get("why", ""))
	if rec.get("hit_i", -1) >= 0:
		var info = infos[0]
		out["damage"] = float(info["damage"]) if info != null else 0.0
		if why == "evaded":
			out["outcome"] = "evaded"
		elif why == "glance":
			out["outcome"] = "glance"
		elif why.begins_with("block_"):
			out["outcome"] = "block" if why != "block_parry" else "parry"
		else:
			out["outcome"] = "hit"
		# reaction: the foe's visible head / chest / gloves after the blow vs where they were at the blow
		var k0: int = rec["hit_i"]
		var best := [0.0, 0.0, 0.0]
		for j in range(0, 31):
			if k0 + j >= traj.size():
				break
			for q in 3:
				best[q] = maxf(best[q], ((traj[k0 + j][q] as Vector3) - (traj[k0][q] as Vector3)).length())
		out["react_head"] = best[0]
		out["react_chest"] = best[1]
		out["react_glove"] = best[2]
	return out


var _p1 := ""
var _p2 := ""


func _track(k: int) -> void:
	var a: Fighter = F[0]
	var d: Fighter = F[1]
	var atk: Dictionary = a.atk
	var inv := d.global_transform.affine_inverse()
	var g: Dictionary = (samplers[1] as RefCounted).call("sample", ["head", "chest", "hand_l", "hand_r"])
	traj.append([inv * SkinSampler.centroid(g["head"]), inv * SkinSampler.centroid(g["chest"]), inv * (SkinSampler.centroid(g["hand_l"]) + SkinSampler.centroid(g["hand_r"])) * 0.5])
	if atk.is_empty() or a.state != a.State.ATTACK:
		return
	if rec.get("why", "") != "evaded":
		rec["why"] = atk.get("why", rec.get("why", ""))
	if atk["hit_done"] and rec["hit_i"] < 0:
		rec["hit_i"] = k
	if atk.get("evaded_touch", false) and rec["hit_i"] < 0:   # the foe got his head away but the glove touched him: felt, no damage, the punch stays a miss
		rec["hit_i"] = k
		rec["why"] = "evaded"
	if a.punch_phase() == "startup":
		return
	var side := "l" if String(atk["limb"]).begins_with("l") else "r"
	var all: Dictionary = (samplers[1] as RefCounted).call("sample", ["head", "neck", "chest", "abdomen", "pelvis", "hand_l", "hand_r", "fore_l", "fore_r"])
	var gl: PackedVector3Array = (samplers[0] as RefCounted).call("sample", ["hand_" + side])["hand_" + side]
	var targets := PackedVector3Array()
	for n in all:
		targets.append_array(all[n])
	rec["vis_min"] = minf(rec["vis_min"], SkinSampler.min_dist(gl, targets))
	var hc := SkinSampler.centroid(all["head"])
	var hr := 0.0
	for p in (all["head"] as PackedVector3Array):
		hr += p.distance_to(hc)
	hr /= maxf((all["head"] as PackedVector3Array).size(), 1)
	var inside := 0
	for p in gl:
		if p.distance_to(hc) < hr * 0.8:
			inside += 1
	rec["inside"] = maxf(rec["inside"], float(inside) / maxf(gl.size(), 1))


func test_registration() -> void:
	print("== A / B / C. visible contact always registers, every outcome is felt, no glove through the head")
	var pairs := [["meshy_viper", "meshy_oak"], ["meshy_oak", "meshy_anvil"], ["meshy_anvil", "meshy_viper"]]
	var punches := ["LJab", "RHook", "LUppercut", "RBodyJab"]
	var gaps := [1.15, 0.95, 0.75]
	var states := ["idle", "block", "slip"]
	var n := 0
	var fn := 0
	var visible := 0
	var no_react := 0
	var registered := 0
	var deepest := 0.0
	var head_hits := 0
	var head_peak_sum := 0.0
	var hits_total := 0
	var block_glove := 0
	var blocks := 0
	for pr in pairs:
		_p1 = pr[0]
		_p2 = pr[1]
		for st in states:
			for tag in punches:
				for gap in gaps:
					if st == "block" and tag == "LUppercut":
						continue
					var r: Dictionary = await punch(tag, gap, st)
					n += 1
					var touched: bool = r["vis_min"] <= 0.012
					if touched:
						visible += 1
						if r["outcome"] == "whiff":
							fn += 1
							print("   FN: %s %s>%s %s gap %.2f (visible distance %.1f mm)" % [tag, pr[0], pr[1], st, gap, r["vis_min"] * 1000])
					if r["outcome"] != "whiff":
						registered += 1
						var head_move: float = maxf(r["react_head"], r["react_chest"])
						var visible_react: bool = head_move > 0.02 or (r["outcome"] in ["block", "parry"] and r["react_glove"] > 0.02)
						if not visible_react:
							no_react += 1
							print("   no reaction: %s %s>%s %s gap %.2f %s (head %.1f chest %.1f glove %.1f cm)" % [tag, pr[0], pr[1], st, gap, r["outcome"], r["react_head"] * 100, r["react_chest"] * 100, r["react_glove"] * 100])
						if r["outcome"] == "hit" and not tag.contains("Body"):
							head_hits += 1
							head_peak_sum += r["react_head"]
							deepest = maxf(deepest, r["inside"])
						if r["outcome"] == "hit":
							hits_total += 1
							if r["damage"] <= 0.0:
								check(false, "a registered hit did damage (%s %s %s gap %.2f)" % [tag, st, pr[0], gap])
						if r["outcome"] == "block":
							blocks += 1
							if r["react_glove"] > 0.03:
								block_glove += 1
	print("   %d punches, %d visible contacts, %d registered, %d false negatives, %d without a visible reaction" % [n, visible, registered, fn, no_react])
	check(visible >= 60, "the sweep produced visible contacts (%d)" % visible)
	check(fn == 0, "no visible contact registered as a whiff (%d)" % fn)
	check(no_react == 0, "every registered outcome moved the foe's head / chest (or the struck glove) > 2 cm (%d did not)" % no_react)
	check(head_hits > 0 and head_peak_sum / head_hits > 0.06, "clean head hits snap the head > 6 cm on average (%.1f cm over %d)" % [head_peak_sum / maxf(head_hits, 1) * 100.0, head_hits])
	check(blocks == 0 or float(block_glove) / blocks > 0.8, "blocked shots drive the glove > 3 cm (%d of %d)" % [block_glove, blocks])
	check(deepest < 0.25, "no clean head hit shows more than 25 %% of the glove inside the visible head (worst %.0f %%)" % (deepest * 100.0))


func test_volumes_on_skin() -> void:
	print("== D. the fist sphere and the head hull ride the visible skin")
	_p1 = "meshy_viper"
	_p2 = "meshy_oak"
	await make_match(_p1, _p2)
	await steps(90)
	var a: Fighter = F[0]
	var worst_fist := 0.0
	var worst_head := 0.0
	var inp := FighterInput.new()
	inp.strikes.append("RHook")
	a.external_input = inp
	for k in 80:
		if k == 1:
			a.external_input = FighterInput.new()
		await physics_frame
		var g: Dictionary = (samplers[0] as RefCounted).call("sample", ["hand_r", "head"])
		var gl: PackedVector3Array = g["hand_r"]
		# the fist sphere sits on the far cap of the glove: it must be within the glove's own extent (its centre within 1 radius of some glove sample)
		var hb: HitAreas.Hitbox = a.rig.hitbox_for("rHand")[0]
		var c: Vector3 = (hb.shapes[0]["node"] as CollisionShape3D).global_position - hb.clamp_delta
		var best := 9.0
		for p in gl:
			best = minf(best, p.distance_to(c))
		worst_fist = maxf(worst_fist, best)
		var hcen: Vector3 = a.rig.target_centre("head")
		worst_head = maxf(worst_head, hcen.distance_to(SkinSampler.centroid(g["head"])))
	print("   worst distance of the fist sphere centre to the nearest visible glove sample %.1f cm; worst distance of the head hull centre to the visible head centroid %.1f cm" % [worst_fist * 100, worst_head * 100])
	check(worst_fist < 0.07, "the fist sphere stays on the visible glove through a hook (%.1f cm from the nearest skin sample)" % (worst_fist * 100))
	check(worst_head < 0.05, "the head hull stays on the visible head (centre within %.1f cm of the skin centroid)" % (worst_head * 100))
	check(a.rig.visible_mounted and a.rig.hitbox_for("rHand")[0].has_meta("vis_mount"), "the hit volumes are mounted on the visible skeleton")


func test_clamp_invisible() -> void:
	print("== E. the visual clamp never changes what the sweeps see")
	_p1 = "meshy_viper"
	_p2 = "meshy_oak"
	var res: Array = []
	for variant in 2:
		await make_match(_p1, _p2)
		F[0].global_position = Vector3(-0.5, 0, 0)
		F[1].global_position = Vector3(0.5, 0, 0)
		await steps(100)
		if variant == 1:   # the same punch with the impact layer switched off
			for c in F[0].rig.skeleton.get_children():
				if c.name == "ImpactHold":
					(c as SkeletonModifier3D).active = false
		infos = [null, null]
		var inp := FighterInput.new()
		inp.strikes.append("LJab")
		F[0].external_input = inp
		var hit_frame := -1
		var dmg := -1.0
		for k in 120:
			if k == 1:
				F[0].external_input = FighterInput.new()
			await physics_frame
			if hit_frame < 0 and infos[0] != null:
				hit_frame = k
				dmg = float(infos[0]["damage"])
		res.append([hit_frame, dmg])
	print("   with the layer: hit at tick %d dmg %.3f; without: tick %d dmg %.3f" % [res[0][0], res[0][1], res[1][0], res[1][1]])
	check(res[0][0] >= 0 and res[0][0] == res[1][0], "the blow lands on the same tick with and without the visual layer")
	check(absf(res[0][1] - res[1][1]) < 0.05, "and does the same damage (%.3f vs %.3f)" % [res[0][1], res[1][1]])


func test_slip_not_cancelled() -> void:
	print("== F. a blow that lands on a slipping foe moves him but does not cancel the slip")
	_p1 = "meshy_viper"
	_p2 = "meshy_oak"
	await make_match(_p1, _p2)
	# 0.9 m, foe settled in his lean before the throw: with the quicker hook (contact ~0.24 s) a lean still under way when it
	# is thrown takes the head off the line (the slip works), and from 1.2 m it never reaches
	F[0].global_position = Vector3(-0.45, 0, 0)
	F[1].global_position = Vector3(0.45, 0, 0)
	await steps(88)
	var d := FighterInput.new()
	d.lean = Vector2(1, 0)
	F[1].external_input = d
	await steps(40)
	infos = [null, null]
	var inp := FighterInput.new()
	inp.strikes.append("RHook@aim")   # aimed: unaimed, landing on the leaning head depends on the idle-sway phase at the throw
	F[0].external_input = inp
	var hit_k := -1
	var lean_at := 0.0
	var state_at := ""
	for k in 150:
		if k == 1:
			F[0].external_input = FighterInput.new()
		await physics_frame
		if hit_k < 0 and infos[0] != null:
			hit_k = k
		if hit_k >= 0 and k == hit_k + 12:
			lean_at = (F[1].lean_pose.pos as Vector2).length()
			state_at = F[1].state_name
	print("   hook on a leaning foe: landed %s (damage %.2f), 0.1 s later his state is %s and his lean is %.2f" % [str(hit_k >= 0), float(infos[0]["damage"]) if infos[0] != null else 0.0, state_at, lean_at])
	check(hit_k >= 0, "the hook lands on the leaning foe")
	check(state_at == "slip", "the foe is still slipping 0.1 s after the blow (state %s)" % state_at)
	check(lean_at > 0.5, "and still leaning (%.2f of 1)" % lean_at)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if "only_slip" in OS.get_cmdline_user_args():   # quick check of section F (also usable on the base commit)
		await test_slip_not_cancelled()
		quit(0)
		return
	await test_volumes_on_skin()
	await test_clamp_invisible()
	await test_slip_not_cancelled()
	await test_registration()
	print("PASS: hit registration" if failures == 0 else "FAIL: hit registration (%d)" % failures)
	quit(0 if failures == 0 else 1)
