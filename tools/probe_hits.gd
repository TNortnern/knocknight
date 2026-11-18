extends SceneTree
## Hit-registration and hit-reaction probe (before / after tool for the fn3/hits work). Runs the real match scene with Meshy fighters.
##   <godot> --headless --fixed-fps 120 --path . --script res://tools/probe_hits.gd -- pair=meshy_viper:meshy_oak mode=scripted out=base
##   args: pair=A:B (attacker:foe, repeatable via comma: pair=a:b,c:d)  mode=scripted|cpu|both  out=<tag>  quick=1 (fewer gaps / punches)
##         cpu_seconds=90  cpu_pair=a:b  states=idle,block,slip  punches=LJab,RJab,...  gaps=1.5,1.2,...
## Every punch of the attacking (human side, fighter 0) is logged to _build/hits/probe_<out>.jsonl with
##   ground truth   : minimum distance between the VISIBLE skinned glove and the visible foe head / neck / torso / gloves + forearms
##                    (tools/skin_sampler.gd, decimated skin vertices) and how deep the glove sits inside the visible head;
##   gameplay       : the minimum (sphere - volume) distance the gameplay sweep (hit_areas.gd) saw, and its deepest swept penetration;
##   outcome        : hit / glance / block / parry / clash / whiff, the damage, and the rule that decided it (Fighter.atk["why"]);
##   reaction       : peak displacement of the foe's visible head / chest / gloves in the 0.25 s after contact, minus the same joints in a
##                    control run without the punch (scripted) or minus the pre-contact trend (CPU fight).
## tools/probe_hits_report.py turns the .jsonl into the tables.
##
## Timing: the tracker is a node added after the match, so it runs after both fighters' physics and skeleton updates: the poses it
## reads are the ones the NEXT physics tick's hit resolution works on (Hitbox.track reads bone attachments, which follow the
## skeleton_updated of the previous tick).

const SkinSampler := preload("res://tools/skin_sampler.gd")
const RosterScript := preload("res://scripts/fighter/roster.gd")

const HEAD_PUNCHES := ["LJab", "RJab", "LHook", "RHook", "LUppercut", "RUppercut"]
const BODY_PUNCHES := ["RBodyJab", "LBodyHook"]
const VIS_TOUCH := 0.012      ## m between decimated skin samples that counts as visible contact
const REACT_WINDOW := 30      ## frames at 120 Hz = 0.25 s
const JOINTS := ["Head", "Chest", "LGlove", "RGlove"]   ## centroids of the VISIBLE skin groups (a head that rotates about its joint moves the skull, not the joint)
const MIN_VISIBLE := 0.02     ## m: a reaction above this is "visible"

var args := {}
var out_file: FileAccess
var m: Node
var F: Array = []
var tracker: Node
var samplers: Array = [null, null]
var frame := 0
var recs: Array = [null, null]
var finished: Array = []
var traj: Array = []          ## per frame since the press: {j: [Vector3 x4]} of the foe (fighter-local, visible Meshy joints)
var rec_frames := false
var gp_prev: Array = [{}, {}]   ## fighter index -> {hitbox: [Vector3 centres]}
var both_attack := false
var last_info: Array = [null, null]
var last_clash := [-99, -99]
var press_frame := 0
var ctrl_cache := {}
var scen := {}
var cur_gap := 0.0


class Tracker extends Node:
	var owner_script: Object
	func _physics_process(_dt: float) -> void:
		owner_script.call("tick")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for a in OS.get_cmdline_user_args():
		var i: int = a.find("=")
		if i > 0:
			args[a.substr(0, i)] = a.substr(i + 1)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/hits"))
	var tag: String = args.get("out", "run")
	out_file = FileAccess.open("res://_build/hits/probe_%s.jsonl" % tag, FileAccess.WRITE)
	var mode: String = args.get("mode", "scripted")
	var quick: bool = args.get("quick", "0") == "1"
	if mode == "scripted" or mode == "both":
		var pairs: Array = String(args.get("pair", "meshy_viper:meshy_oak,meshy_oak:meshy_anvil,meshy_anvil:meshy_viper")).split(",")
		var states: Array = String(args.get("states", "idle,block,slip")).split(",")
		var punches: Array = String(args.get("punches", ",".join(HEAD_PUNCHES + BODY_PUNCHES))).split(",")
		var gaps_s: String = args.get("gaps", "1.5,1.35,1.2,1.1,1.0,0.9,0.8,0.7,0.6" if not quick else "1.3,1.1,0.95,0.8,0.65")
		var gaps := []
		for g in gaps_s.split(","):
			gaps.append(float(g))
		for pr in pairs:
			var ab: Array = String(pr).split(":")
			for st in states:
				await _scripted_block(ab[0], ab[1], st, punches, gaps)
	if mode == "cpu" or mode == "both":
		var cp: Array = String(args.get("cpu_pair", "meshy_viper:meshy_oak")).split(":")
		await _cpu_fight(cp[0], cp[1], float(args.get("cpu_seconds", "90")))
	out_file.close()
	print("probe done: ", finished.size(), " punches")
	quit(0)


# ----------------------------------------------------------------------------------------------------------- match plumbing
func _new_match(att_model: String, foe_model: String, cpu: bool) -> void:
	if tracker != null and is_instance_valid(tracker):
		tracker.queue_free()
	if m != null and is_instance_valid(m):
		m.queue_free()
	await process_frame
	m = load("res://scenes/match.tscn").instantiate()
	m.setup({"intro_delay": 0.0, "mode": "exhibition", "p1_controller": "cpu" if cpu else "dummy", "p2_controller": "cpu" if cpu else "dummy",
		"rounds": 1, "round_seconds": 900.0, "p1_model": att_model, "p2_model": foe_model, "rules": "boxing", "cpu_difficulty": "normal"})
	get_root().add_child(m)
	await process_frame
	F = m.get_fighters()
	for fi in F:
		fi.stats.infinite_stamina = true
	if not cpu:
		for fi in F:
			fi.external_input = FighterInput.new()
	samplers = [SkinSampler.make(F[0]), SkinSampler.make(F[1])]
	tracker = Tracker.new()
	tracker.owner_script = self
	get_root().add_child(tracker)
	for i in 2:
		F[i].hit_landed.connect(func(_att, info): last_info[i] = info)
		F[i].clashed.connect(func(_o, _p): last_clash[i] = frame)
	recs = [null, null]
	gp_prev = [{}, {}]
	frame = 0
	cpu_traj = [[], []]
	finished_scratch.clear()
	last_info = [null, null]


func steps(n: int) -> void:
	for i in n:
		await physics_frame


# ----------------------------------------------------------------------------------------------------------- scripted block
func _foe_input(state: String, active: bool, slip_sign: float, body_shot: bool) -> void:
	var d: FighterInput = FighterInput.new()
	match state:
		"block":
			d.block = true
			d.body = body_shot
		"slip":
			if active:
				d.lean = Vector2(slip_sign, 0.0)
	F[1].external_input = d


var cur_att := ""
var cur_foe := ""


func _scripted_block(att_model: String, foe_model: String, state: String, punches: Array, gaps: Array) -> void:
	cur_att = att_model
	cur_foe = foe_model
	both_attack = false
	var key := "%s>%s|%s" % [att_model, foe_model, state]
	print("== scripted %s" % key)
	# controls: the foe alone (twice, the second only to measure the repeatability of the control itself)
	for body_shot in [false, true]:
		if state != "block" and body_shot:
			continue
		var ck := key + ("|body" if body_shot else "")
		ctrl_cache[ck] = await _scenario(1.0, "", state, 1.0, body_shot)
		ctrl_cache[ck + "|2"] = await _scenario(1.0, "", state, 1.0, body_shot)
	var n := 0
	for tagp in punches:
		var body_shot: bool = String(tagp).contains("Body")
		var ctrl: Array = ctrl_cache[key + ("|body" if (body_shot and state == "block") else "")]
		var ctrl2: Array = ctrl_cache[key + ("|body" if (body_shot and state == "block") else "") + "|2"]
		for gi in gaps.size():
			var gap: float = gaps[gi]
			var sgn := 1.0 if (gi % 2 == 0) else -1.0
			var tr: Array = await _scenario(gap, tagp, state, sgn, body_shot and state == "block")
			var rows := _finish_run(tr, ctrl, ctrl2, key, tagp, gap, state)
			n += rows
	print("   %d punches" % n)


## One run: reset, settle, throw `tag` (empty = control), record `rec` frames. Returns the foe's joint trajectory per frame since the press.
func _scenario(gap: float, tag: String, state: String, slip_sign: float, body_block: bool) -> Array:
	cur_gap = gap
	await _new_match(cur_att, cur_foe, false)   # a fresh bout per run: the idle sway / head tracking are deterministic from tick 0, so the control matches
	F[0].global_position = Vector3(-gap * 0.5, 0, 0)
	F[1].global_position = Vector3(gap * 0.5, 0, 0)
	F[0].external_input = FighterInput.new()
	_foe_input(state, false, slip_sign, body_block)
	finished_scratch.clear()
	recs = [null, null]
	await steps(88)
	_foe_input(state, true, slip_sign, body_block)   # the slip starts 0.1 s before the punch is thrown
	await steps(12)
	traj = []
	scen = {"tag": tag, "state": state, "gap": gap}
	rec_frames = true
	press_frame = frame
	var inp := FighterInput.new()
	if tag != "":
		inp.strikes.append(tag)
	F[0].external_input = inp
	var total := 270
	var ended_at := -1
	for k in total:
		if k == 1:
			F[0].external_input = FighterInput.new()
		_foe_input(state, true, slip_sign, body_block)
		if tag != "" and ended_at < 0 and F[0].state != F[0].State.ATTACK and k > 6:
			ended_at = k
		if ended_at >= 0 and k > ended_at + 42:
			break
		await physics_frame
	rec_frames = false
	_close_rec(0)
	return traj


var finished_scratch: Array = []   ## the punches of the run in progress


func _finish_run(tr: Array, ctrl: Array, ctrl2: Array, key: String, tag: String, gap: float, state: String) -> int:
	var cnt := 0
	for r in finished_scratch:
		r["key"] = key
		r["state"] = state
		r["gap"] = gap
		r["mode"] = "scripted"
		_reaction(r, tr, ctrl)
		var noise := _reaction_noise(ctrl, ctrl2)
		r["ctrl_noise"] = noise
		_write(r)
		cnt += 1
	return cnt


# ----------------------------------------------------------------------------------------------------------- CPU vs CPU
func _cpu_fight(att_model: String, foe_model: String, secs: float) -> void:
	await _new_match(att_model, foe_model, true)
	both_attack = true
	rec_frames = true
	traj = []
	var key := "%s>%s|cpu" % [att_model, foe_model]
	var t := 0
	var total := int(secs * 120.0)
	var rebuilds := 0
	var all_traj := []   ## per frame {0: foe traj of fighter 1 .., 1: ..}
	var n_total := 0
	while t < total:
		await physics_frame
		t += 1
		if t % 30 == 0 and (F[0].is_out() or F[1].is_out()):   # bout ended (KO): a fresh match goes on
			_close_rec(0)
			_close_rec(1)
			n_total += _flush_cpu(key)
			await _new_match(att_model, foe_model, true)
			both_attack = true
			rec_frames = true
			rebuilds += 1
	_close_rec(0)
	_close_rec(1)
	n_total += _flush_cpu(key)
	print("cpu fight: %d punches, %d rebuilds" % [n_total, rebuilds])


## The CPU fight has no control run: reactions are measured against the pre-contact trend of each joint.
func _flush_cpu(key: String) -> int:
	var n := 0
	for r in finished_scratch:
		r["key"] = key
		r["mode"] = "cpu"
		r["state"] = "cpu"
		r["gap"] = r.get("root_gap", 0.0)
		_reaction_trend(r)
		_write(r)
		n += 1
	finished_scratch.clear()
	return n


# ----------------------------------------------------------------------------------------------------------- per-frame tracker
var cpu_traj: Array = [[], []]   ## per fighter: foe-local joints per frame (CPU fight, fixed index = the attacker's foe)


func tick() -> void:
	if F.is_empty() or not is_instance_valid(F[0]):
		return
	frame += 1
	var attackers := [0, 1] if both_attack else [0]
	# foe joints, every frame
	var fj := {}
	for i in 2:
		fj[i] = _local_joints(F[i], i)
	if rec_frames and not both_attack:
		traj.append(fj[1])
	if both_attack:
		cpu_traj[0].append(fj[1])   # foe joints when 0 attacks
		cpu_traj[1].append(fj[0])
	for i in attackers:
		_track_attacker(i, fj)
	for i in 2:   # remember the hit sphere centres (the sweep of the next tick starts here)
		for hb in F[i].rig.hitboxes:
			var cs := []
			for sh in hb.shapes:
				cs.append((sh["node"] as CollisionShape3D).global_position - _cd(hb))
			gp_prev[i][hb] = cs


## The world shift the visual impact layer applied to this glove last tick (absent on commits before scripts/fighter/impact_hold.gd): the sweeps do not see it.
func _cd(hb) -> Vector3:
	var v = hb.get("clamp_delta")
	return v if v != null else Vector3.ZERO


func _local_joints(f: Fighter, idx: int) -> Array:
	var inv := f.global_transform.affine_inverse()
	var g: Dictionary = (samplers[idx] as RefCounted).call("sample", ["head", "chest", "hand_l", "hand_r"])
	return [inv * SkinSampler.centroid(g["head"]), inv * SkinSampler.centroid(g["chest"]), inv * SkinSampler.centroid(g["hand_l"]), inv * SkinSampler.centroid(g["hand_r"])]


func _track_attacker(i: int, fj: Dictionary) -> void:
	var a: Fighter = F[i]
	var d: Fighter = F[1 - i]
	var atk: Dictionary = a.atk
	var rec = recs[i]
	if rec != null and (atk.is_empty() or not is_same(rec["ref"], atk)):
		_close_rec(i)
		rec = null
	if atk.is_empty() or a.state != a.State.ATTACK:
		return
	if rec == null:
		var s: Dictionary = atk["s"]
		rec = {"ref": atk, "i": i, "tag": atk["tag"], "limb": atk["limb"], "zone": s["zone"], "dir": s["dir"], "power": bool(s.get("power", false)),
			"start_frame": frame, "rel_start": frame - press_frame, "gp_head": 9.0, "gp_body": 9.0, "gp_guard": 9.0, "gp_head_depth": 0.0, "gp_body_depth": 0.0,
			"gp_guard_depth": 0.0, "vis_head": 9.0, "vis_neck": 9.0, "vis_torso": 9.0, "vis_glove": 9.0, "vis_head_inside": 0.0, "vis_head_through": -9.0,
			"first_vis": {}, "whys": [], "hit_frame": -1, "root_gap": a.gap_to_foe(), "foe_state0": d.state_name, "foe_guard0": d.guard_on,
			"min_gap": 9.0, "foe_lean0": 0.0}
		if d.lean_pose != null:
			rec["foe_lean0"] = (d.lean_pose.pos as Vector2).length()
		recs[i] = rec
		last_info[i] = null
	var s2: Dictionary = atk["s"]
	var k: float = atk["k"]
	var t: float = atk["t"]
	var in_window := t >= float(s2["w0"]) * k * a.EARLY_CONTACT and t <= float(s2["w1"]) * k
	var why: String = atk.get("why", "")
	var seq: Array = rec["whys"]
	if seq.is_empty() or seq[seq.size() - 1] != why:
		seq.append(why)
	if atk["hit_done"] and rec["hit_frame"] < 0:
		rec["hit_frame"] = frame
		rec["hit_rel"] = frame - press_frame
	rec["min_gap"] = minf(rec["min_gap"], a.gap_to_foe())
	# ---- gameplay contact: sphere centre against the foe's volumes (poses of this tick = the next resolution's input)
	var limb: String = atk["limb"]
	for hb in a.rig.hitbox_for(limb):
		var prev: Array = gp_prev[i].get(hb, [])
		for si in hb.shapes.size():
			var r: float = hb.shapes[si]["r"]
			var cn: Vector3 = (hb.shapes[si]["node"] as CollisionShape3D).global_position - _cd(hb)   # the path the gameplay sweeps see (no visual clamp)
			var cp: Vector3 = prev[si] if si < prev.size() else cn
			for hu: HitAreas.Hurtbox in d.rig.hurtboxes:
				hu._inv_frame = -1
				var key := "gp_head" if hu.zone == "head" else ("gp_body" if hu.zone == "body" else "")
				if key == "":
					continue
				var dist := hu.sdf(cn) - r
				rec[key] = minf(rec[key], dist)
				var c := HitAreas.sweep(cp, cn, r, hu)
				if not c.is_empty():
					rec[key + "_depth"] = maxf(rec[key + "_depth"], float(c["depth"]))
			for hu: HitAreas.Hurtbox in d.rig.guards:
				if hu.collision_layer == 0:
					continue
				hu._inv_frame = -1
				var dist2 := hu.sdf(cn) - r
				rec["gp_guard"] = minf(rec["gp_guard"], dist2)
				var c2 := HitAreas.sweep(cp, cn, r, hu)
				if not c2.is_empty():
					rec["gp_guard_depth"] = maxf(rec["gp_guard_depth"], float(c2["depth"]))
	# ---- visible contact: skinned glove against skinned foe
	var side := "l" if limb.begins_with("l") else "r"
	var hand_w: Vector3 = a.meshy_skin.joint_world("LeftHand" if side == "l" else "RightHand")
	var chest_w: Vector3 = d.meshy_skin.joint_world("Spine")
	var cls := {}
	# the hand has not left the guard in "startup": at close range the resting gloves overlap the foe's without that being a blow
	if hand_w.distance_to(chest_w) < 0.75 and a.punch_phase() != "startup":
		var gl: PackedVector3Array = (samplers[i] as RefCounted).call("sample", ["hand_" + side])["hand_" + side]
		var fo: Dictionary = (samplers[1 - i] as RefCounted).call("sample", ["head", "neck", "chest", "abdomen", "pelvis", "hand_l", "hand_r", "fore_l", "fore_r"])
		var torso := PackedVector3Array()
		for gname in ["chest", "abdomen", "pelvis"]:
			torso.append_array(fo[gname])
		var glv := PackedVector3Array()
		for gname in ["hand_l", "hand_r", "fore_l", "fore_r"]:
			glv.append_array(fo[gname])
		cls["vis_head"] = SkinSampler.min_dist(gl, fo["head"])
		cls["vis_neck"] = SkinSampler.min_dist(gl, fo["neck"])
		cls["vis_torso"] = SkinSampler.min_dist(gl, torso)
		cls["vis_glove"] = SkinSampler.min_dist(gl, glv)
		# how deep inside the visible head: share of glove samples within 0.8 of the head's mean radius from its centroid
		var hc := SkinSampler.centroid(fo["head"])
		var hr := 0.0
		for p in (fo["head"] as PackedVector3Array):
			hr += p.distance_to(hc)
		hr /= maxf((fo["head"] as PackedVector3Array).size(), 1)
		var inside := 0
		for p in gl:
			if p.distance_to(hc) < hr * 0.8:
				inside += 1
		rec["vis_head_inside"] = maxf(rec["vis_head_inside"], float(inside) / maxf(gl.size(), 1))
		rec["vis_head_through"] = maxf(rec["vis_head_through"], hr - SkinSampler.centroid(gl).distance_to(hc))
		# where the gameplay volumes sit against the visible skin, at the closest approach to the visible head / torso (diagnostic)
		var tgt_key := "vis_head" if String(rec["zone"]) == "head" else "vis_torso"
		if cls[tgt_key] < rec[tgt_key] and cls[tgt_key] < 0.06:
			var fb: Basis = a.global_basis   # fighter frame: x left, y up, z forward (towards the foe)
			var fist_c: Vector3 = (a.rig.hitbox_for(limb)[0].shapes[0]["node"] as CollisionShape3D).global_position
			var gl_c := SkinSampler.centroid(gl)
			var hu_t: HitAreas.Hurtbox = null
			for hu: HitAreas.Hurtbox in d.rig.hurtboxes:
				if hu.zone == String(rec["zone"]) and (hu.limb == "head" or hu.limb == "chestUpper"):
					hu_t = hu
			var tgt_c := SkinSampler.centroid(fo["head"] if String(rec["zone"]) == "head" else torso)
			var offs := {}
			var go := fb.inverse() * (gl_c - fist_c)
			offs["glove_vs_fist"] = [go.x, go.y, go.z]
			if hu_t != null:
				var to := fb.inverse() * (tgt_c - hu_t.shape_node.global_position)
				offs["target_vs_volume"] = [to.x, to.y, to.z]
			# tip of the visible glove along the line to the target, against the gameplay sphere's tip
			var u := (tgt_c - fist_c).normalized()
			var tip := -9.0
			for v in gl:
				tip = maxf(tip, (v - fist_c).dot(u))
			offs["glove_tip_beyond_sphere"] = tip - float(a.rig.hitbox_for(limb)[0].shapes[0]["r"])
			offs["gp_head"] = rec["gp_head"]
			offs["gp_body"] = rec["gp_body"]
			rec["off"] = offs
		for key in cls:
			rec[key] = minf(rec[key], cls[key])
			if cls[key] <= VIS_TOUCH and not (rec["first_vis"] as Dictionary).has(key):
				rec["first_vis"][key] = {"rel": frame - press_frame, "atk_t": t, "in_window": in_window, "hit_done": atk["hit_done"], "why": why,
					"phase": a.punch_phase(), "foe_state": d.state_name, "foe_guard": d.guard_on,
					"gp_head": rec["gp_head"], "gp_body": rec["gp_body"], "gp_guard": rec["gp_guard"], "frame": frame}


func _close_rec(i: int) -> void:
	var rec = recs[i]
	recs[i] = null
	if rec == null:
		return
	var atk: Dictionary = rec["ref"]
	rec.erase("ref")
	var why: String = atk.get("why", "")
	var cls := "whiff"
	if atk.get("clash", false):
		cls = "clash"
	elif atk.get("evaded_touch", false) and not atk["hit_done"]:
		cls = "evaded"   # the foe got his head away; the glove still touched a shoulder / glove: felt (a flinch), no damage, the punch stays a miss
	elif atk["hit_done"]:
		if why == "glance":
			cls = "glance"
		elif why == "block_parry":
			cls = "parry"
		elif why.begins_with("block_"):
			cls = "block"
		else:
			cls = "hit"
	rec["outcome"] = cls
	rec["why"] = why
	rec["atk_outcome"] = String(atk.get("outcome", ""))
	rec["clash_flag"] = bool(atk.get("clash", false))
	rec["trade"] = atk.get("trade", {}).get("won", null) if atk.has("trade") else null
	var info = last_info[i]
	rec["damage"] = 0.0
	rec["strength"] = ""
	rec["info_flags"] = []
	if cls in ["hit", "glance", "block", "parry"] and info != null and rec["hit_frame"] >= 0:
		rec["damage"] = float(info.get("damage", 0.0))
		rec["strength"] = String(info.get("strength", ""))
		for fl in ["rocked", "knockdown", "ko", "counter", "open", "punish", "pierce", "partial", "guard_break", "trade", "parry"]:
			if info.get(fl, false):
				(rec["info_flags"] as Array).append(fl)
		rec["quality"] = float(info.get("quality", 0.0))
		rec["speed"] = float(info.get("speed", 0.0))
	elif cls in ["hit", "glance", "block", "parry"]:
		rec["damage"] = -1.0   # registered but no hit_landed (foe already down)
	rec["attacker_fatigue"] = 0.0
	rec["t_end_frame"] = frame
	# keep the dictionary values json-safe
	finished_scratch.append(rec)
	finished.append(rec)


# ----------------------------------------------------------------------------------------------------------- reactions
## T0 = the frame the blow registered; when nothing registered, the frame of the closest visible approach (so a whiff that visibly touched is
## judged on the same footing).
func _t0_frame(r: Dictionary) -> int:
	if r.get("hit_frame", -1) >= 0:
		return int(r["hit_frame"])
	var best := -1
	for key in (r["first_vis"] as Dictionary):
		var fv: Dictionary = r["first_vis"][key]
		if best < 0 or int(fv["frame"]) < best:
			best = int(fv["frame"])
	return best


func _reaction(r: Dictionary, tr: Array, ctrl: Array) -> void:
	var t0 := _t0_frame(r)
	r["react_t0"] = -1
	if t0 < 0:
		r["react"] = {}
		return
	var k0: int = t0 - press_frame_of(r) - 1   # traj[0] is the tick after the press
	r["react_t0"] = k0
	var peak := {}
	for ji in JOINTS.size():
		var best := 0.0
		for j in range(0, REACT_WINDOW + 1):
			var k := k0 + j
			if k >= tr.size() or k >= ctrl.size() or k0 >= tr.size() or k0 >= ctrl.size():
				break
			var dev: Vector3 = ((tr[k][ji] as Vector3) - (ctrl[k][ji] as Vector3)) - ((tr[k0][ji] as Vector3) - (ctrl[k0][ji] as Vector3))
			best = maxf(best, dev.length())
		peak[JOINTS[ji]] = best
	r["react"] = peak


func press_frame_of(r: Dictionary) -> int:
	return int(r["start_frame"]) - int(r["rel_start"])


## Largest deviation of the second control from the first over any window of the same length: the repeatability floor of the method.
func _reaction_noise(c1: Array, c2: Array) -> float:
	var worst := 0.0
	var n := mini(c1.size(), c2.size())
	for k in range(0, n):
		for ji in JOINTS.size():
			var dd := ((c1[k][ji] as Vector3) - (c2[k][ji] as Vector3)).length()
			if dd > worst:
				worst = dd
				if args.get("dbg", "0") == "1":
					print("   noise k=%d joint=%s d=%.3f" % [k, JOINTS[ji], dd])
	return worst


## CPU fight: displacement from the linear pre-contact trend of each foe joint (velocity over the 0.1 s before contact, capped).
func _reaction_trend(r: Dictionary) -> void:
	var t0 := _t0_frame(r)
	r["react"] = {}
	if t0 < 0:
		return
	var tra: Array = cpu_traj[int(r["i"])]
	var base: int = cpu_base[int(r["i"])]
	var k0: int = t0 - base
	if k0 < 12 or k0 + REACT_WINDOW >= tra.size():
		return
	var peak := {}
	for ji in JOINTS.size():
		var p0: Vector3 = tra[k0][ji]
		var v: Vector3 = ((p0 - (tra[k0 - 12][ji] as Vector3)) / 12.0).limit_length(0.012)
		var best := 0.0
		for j in range(1, REACT_WINDOW + 1):
			var pred := p0 + v * float(j)
			best = maxf(best, ((tra[k0 + j][ji] as Vector3) - pred).length())
		peak[JOINTS[ji]] = best
	r["react"] = peak
	r["react_t0"] = k0


var cpu_base := [1, 1]   ## absolute frame of cpu_traj[i][0]


func _write(r: Dictionary) -> void:
	var o := {}
	for k in r:
		var v = r[k]
		if v is Vector3:
			o[k] = [v.x, v.y, v.z]
		else:
			o[k] = v
	out_file.store_line(JSON.stringify(o))
	out_file.flush()
