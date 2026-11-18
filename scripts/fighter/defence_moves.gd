extends RefCounted
## The defence family (Undisputed reference), owned by Fighter as `dm`:
##   shell      Block + Shell modifier. Lead shoulder up to the chin, chin tucked, torso turned. Head shots land on the shoulder /
##              forearms for less guard damage than the high block, but the body is more open (body shots hurt more).
##   tilt       Slip + Block held. Short procedural head tilt behind the high guard (quick, 1.5 stamina, guard stays up).
##   slip       Slip without Block (existing authored DEF_slip_*): the full head slip.
##   sway       Slip + stepping back (or the CPU): authored DEF_sway_* lean-back, beats straights.
##   roll       Duck + Slip direction: deep roll, authored DEF_duck_left/right plus extra waist hinge / knee load and a lateral lean
##              that lags the dip (U-shaped path) - beats hooks.
##   backstep   existing B Dodge.
## Evasion is geometry only: the head hurtbox rides the head bone, which these poses move. Nothing here grants immunity.
## A successful evasion (foe whiffs a head strike while we are slipping / rolling) opens the counter window (Fighter._report_whiff)
## and records it in `last_evade`; the next RHook then plays the authored DEF_counter_* clip for that side / distance.

const DefencePoseScript := preload("res://scripts/fighter/defence_pose.gd")

const TILT_STAMINA := 1.5
const TILT_MIN_HOLD := 0.08
const TILT_IN := 0.07
const TILT_OUT := 0.11
const SHELL_GUARD_MULT := 0.55      ## guard meter lost per blocked head hit vs the high block
const SHELL_BODY_MULT := 1.25       ## body shots hurt more while the elbows are up
const ROLL_STAMINA := 5.0
const COUNTER_MEASURE := "res://data/counter_measure.json"
const COUNTER_TAG := "RHook"        ## the authored counters are rear hooks

var f: Fighter
var pose
var kind := ""                      ## "" | "slip" | "tilt" | "sway" while in State.SLIP; "roll" | "duck" in State.CROUCH
var crouch_dir := 0                 ## roll direction (+1 = fighter's left) or 0 for a plain duck
var shell_on := false
var shell_w := 0.0
var tilt_w := 0.0
var roll_w := 0.0
var roll_lat_w := 0.0
var last_evade := {}                ## {kind, dir, gap, t}
var counts := {}                    ## defence type -> times started (tests / CPU stats)
var _shoulders: Array = []
var _tilt_dir := 0

static var _counter_ready := false


func setup(fighter: Fighter) -> void:
	f = fighter
	pose = DefencePoseScript.new()
	pose.name = "DefencePose"
	pose.fighter = fighter
	f.rig.skeleton.add_child(pose)
	_build_shoulder_guards()
	_ensure_counter_data()


## Shoulder guard volumes (only active while the shell is up): the shoulders / upper arms.
func _build_shoulder_guards() -> void:
	var sk := f.rig.skeleton
	for bone in ["lShldrBend", "rShldrBend"]:
		var ba := BoneAttachment3D.new()
		ba.name = "BA_shell_" + bone
		ba.bone_name = bone
		sk.add_child(ba)
		var hu := HitAreas.Hurtbox.new()
		hu.name = "Guard_shell_" + bone
		hu.fighter = f
		hu.zone = "guard"
		hu.is_guard = true
		hu.collision_layer = 0   # switched on by tick() while the shell is up
		hu.collision_mask = 0
		hu.monitoring = false
		hu.monitorable = true
		ba.add_child(hu)
		var cs := CollisionShape3D.new()
		var sh := SphereShape3D.new()
		sh.radius = 0.12
		cs.shape = sh
		hu.add_child(cs)
		hu.shape_node = cs
		f.rig.guards.append(hu)
		_shoulders.append(hu)


# ---------------------------------------------------------------- per tick
func tick(dt: float) -> void:
	# shell: Block + Shell held in idle (the shell is a stance of the standing guard)
	var want_shell: bool = f.guard_on and f.inp.shell and not f.guard_body and f.state == Fighter.State.IDLE and not f.stats.rocked
	if want_shell != shell_on:
		shell_on = want_shell
		if shell_on:
			_count("shell")
		var layer := HitAreas.guard_layer(f.player_index) if shell_on else 0
		for hu in _shoulders:
			hu.collision_layer = layer
	shell_w = move_toward(shell_w, 1.0 if shell_on else 0.0, dt / (0.10 if shell_on else 0.12))
	if f.state != Fighter.State.SLIP and kind in ["slip", "tilt", "sway"]:
		kind = ""
	if f.state != Fighter.State.CROUCH:
		if kind in ["roll", "duck"]:
			kind = ""
		crouch_dir = 0
	# tilt envelope
	var tilt_target := 0.0
	# (the head tilt is now the analog lean: LeanPose, driven by Fighter._tick_lean; the old envelope stays at 0)
	tilt_w = move_toward(tilt_w, tilt_target, dt / (TILT_IN if tilt_target > 0.5 else TILT_OUT))
	if tilt_w < 0.001:
		_tilt_dir = 0
	# roll envelopes: the dip is quick, the lateral part trails it (down, then out and through, then up)
	var roll_target := 0.0
	if f.state == Fighter.State.CROUCH and kind == "roll" and f.duck_release_t < 0.0:
		roll_target = 1.0
	roll_w = move_toward(roll_w, roll_target, dt / (0.20 if roll_target > 0.5 else 0.22))
	roll_lat_w = move_toward(roll_lat_w, roll_target, dt / (0.30 if roll_target > 0.5 else 0.16))
	pose.shell = smoothstep(0.0, 1.0, shell_w)
	pose.lean = float(_tilt_dir) * smoothstep(0.0, 1.0, tilt_w)
	pose.hinge = smoothstep(0.0, 1.0, roll_w)
	pose.roll_lean = 0.0   # the lateral part of a roll is the analog lean now (LeanPose), one spring for slip and duck + slip


func _count(name: String) -> void:
	counts[name] = int(counts.get(name, 0)) + 1


# ---------------------------------------------------------------- slip family (State.SLIP)
## Decides which kind of slip an input produces. `back` = backstep (B Dodge), handled by Fighter itself.
func begin_slip(dir: int, back: bool) -> void:
	if back:
		kind = "slip"
		_count("backstep")
		return
	kind = ""
	update_lean_kind(f._lean_wanted())
	_count(kind)


## Names the lean in progress from the analog lean the input asks for: "tilt" (block held: small, behind the guard),
## "sway" (leaning back), "slip" (sideways / bob). Counted once per change (CPU stats, tests).
func update_lean_kind(want: Vector2) -> void:
	if want.length() < 0.08:
		return
	var k := "slip"
	if f.inp.block and f.stats.guard_lock <= 0.0 and f.stats.guard > 0.0:
		k = "tilt"
	elif want.y < -0.45 and want.y < -absf(want.x) * 0.6:
		k = "sway"
	if k != kind:
		if kind != "":
			_count(k)
		kind = k


func _wants_back() -> bool:
	var mv := Vector3(f.inp.move.x, 0, -f.inp.move.y)
	if mv.length() < 0.4:
		return false
	return f.local_dir(mv.normalized()).y < -0.45


## Stamina cost of the slip being entered.
func slip_stamina(back: bool) -> float:
	return TILT_STAMINA if (kind == "tilt" and not back) else 3.0


## Authored clip for the active slip kind ("" = purely procedural tilt).
func slip_clip(dir: int, guard_suffix: String) -> String:
	var side := "left" if dir > 0 else "right"
	match kind:
		"tilt":
			return ""
		"sway":
			return "DEF_sway_%s%s" % [side, guard_suffix]
	return "DEF_slip_%s%s" % [side, guard_suffix]


## Slipping / swaying / tilting / ducking / rolling for long enough to count as an evasion of a whiffed strike.
func evading() -> bool:
	if f.state == Fighter.State.SLIP:
		return f.slip_t > 0.02 and f.lean_pose.pos.length() > 0.3
	return f.state == Fighter.State.CROUCH and f.duck_t > 0.02


func keeps_guard_pose() -> bool:
	# Analog leans now start from the base guard instead of the authored *_block hold poses.
	# Keep the actual block pose under the procedural lean so raising Block does not silently lose its arm silhouette.
	return f.state == Fighter.State.SLIP


## Tilt flow (called from Fighter._update_slip after the shared checks). Returns true when it owned this tick.
func update_tilt(dt: float) -> bool:
	if kind != "tilt":
		return false
	if f.slip_release_t < 0.0:
		var want := f._slip_from_input()
		if f.slip_t >= TILT_MIN_HOLD:
			if want != 0 and want != f.slip_dir and (f.stats.stamina >= 3.0 or f.stats.infinite_stamina):
				f._enter_slip(want, false)
				return true
			if want != f.slip_dir or not f.inp.block:
				f.slip_release_t = 0.0
	else:
		f.slip_release_t += dt
		if f.slip_release_t >= TILT_OUT:
			f.slip_dir = 0
			kind = ""
			f._set_state(Fighter.State.IDLE)
	return true


# ---------------------------------------------------------------- crouch family (State.CROUCH)
## Called from Fighter._enter_crouch: duck + a slip direction = deep roll.
func begin_crouch() -> void:
	var d := f._slip_from_input()
	if d != 0 and (f.stats.stamina >= ROLL_STAMINA or f.stats.infinite_stamina) and f.inp.duck:
		f.stats.spend_stamina(ROLL_STAMINA - 3.0, 0.25)   # a roll costs a little more than a slip
		kind = "roll"
		crouch_dir = d
		_count("roll")
	else:
		kind = "duck"
		crouch_dir = 0
		_count("duck")


func duck_clip(guard_suffix: String) -> String:
	return "DEF_duck" + guard_suffix   # the roll side is the analog lean (LeanPose) on top of the plain duck


## The slip side changed (or started) while ducked: only the labels / cost move, the pose follows the lean spring.
func retarget_roll() -> void:
	var d := f._slip_from_input()
	if d == 0:
		return
	if kind != "roll":
		f.stats.spend_stamina(ROLL_STAMINA - 3.0, 0.25)
		_count("roll")
	kind = "roll"
	crouch_dir = d


## True when the held slip direction changed while ducking (plain duck -> roll, or roll left <-> right).
func roll_changed() -> bool:
	var d := f._slip_from_input()
	if d == 0:
		return false
	return d != crouch_dir and (f.stats.stamina >= ROLL_STAMINA or f.stats.infinite_stamina)


# ---------------------------------------------------------------- guard modifiers (shell)
func guard_loss_mult(s: Dictionary) -> float:
	if shell_on and s["zone"] == "head":
		return SHELL_GUARD_MULT
	return 1.0


## Adjusts the damage dictionary of an incoming hit in place.
func adjust_damage(s: Dictionary, dmg: Dictionary) -> void:
	if shell_w > 0.5 and s["zone"] == "body":
		dmg["total"] = float(dmg["total"]) * SHELL_BODY_MULT


# ---------------------------------------------------------------- evasion -> counter
## The foe whiffed a head strike while we were slipping / rolling (Fighter._report_whiff).
func note_evasion() -> void:
	var k := kind
	if f.state == Fighter.State.CROUCH:
		k = "roll" if crouch_dir != 0 else "duck"
	var dir := crouch_dir
	if f.state == Fighter.State.SLIP:
		dir = f.slip_dir if f.slip_dir != 0 else (1 if f.lean_pose.pos.x > 0.0 else -1)
	last_evade = {"kind": k, "dir": dir, "gap": f.gap_to_foe(), "t": f._time}
	_count("evade_" + k)


func _ensure_counter_data() -> void:
	if _counter_ready:
		return
	_counter_ready = true
	var txt := FileAccess.get_file_as_string(COUNTER_MEASURE)
	if txt == "":
		return
	var data = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	StrikeDB.has_strike(COUNTER_TAG)   # loads the tables
	var base: Dictionary = StrikeDB._table.get(COUNTER_TAG, {})
	for clip in data:
		var row: Dictionary = base.duplicate()
		row["clip"] = clip
		var key := "%s~%s" % [COUNTER_TAG, clip]
		StrikeDB._table[key] = row
		StrikeDB._measure[key] = data[clip]


## `tag` is about to be thrown inside an open counter window: returns the authored-counter variant of the strike
## (clip, measured timing) when one fits this evasion, else {}.
func counter_variant(tag: String) -> Dictionary:
	if tag != COUNTER_TAG or f.state not in [Fighter.State.SLIP, Fighter.State.ATTACK, Fighter.State.IDLE]:
		return {}
	# the lean the punch is thrown out of (the held lean, or one that a moment ago evaded a strike)
	var lp: Vector2 = f.lean_pose.pos
	var k := ""
	var dir := 0
	if lp.length() > 0.5:
		k = "sway" if (lp.y < -0.45 and lp.y < -absf(lp.x) * 0.6) else ("slip" if absf(lp.x) > 0.4 else "")
		dir = 1 if lp.x >= 0.0 else -1
		if absf(lp.x) < 0.15:
			dir = int(last_evade.get("dir", 1)) if not last_evade.is_empty() else 1
	if k == "" and not last_evade.is_empty() and f._time - float(last_evade["t"]) <= 0.5 and lp.length() > 0.25:
		k = String(last_evade["kind"])
		dir = int(last_evade["dir"])
	if (k != "slip" and k != "sway") or dir == 0 or f.guard_body:
		return {}
	var gap := f.gap_to_foe()
	var dist := "near" if gap < 1.0 else ("mid" if gap < 1.15 else "far")   # the authored lunge grows with the distance: pick the shortest that still reaches
	var clip := "DEF_counter_%s_%s_%s" % [k, "left" if dir > 0 else "right", dist]
	var key := "%s~%s" % [COUNTER_TAG, clip]
	if not StrikeDB._table.has(key):
		return {}
	var s := StrikeDB.get_strike(key)
	s["tag"] = tag
	s["counter_clip"] = clip
	_count("counter_clip")
	return s
