class_name Fighter
extends CharacterBody3D
## One boxer / kickboxer. Presentation (AnimationTree, hit areas) is driven from plain combat logic
## (CombatRules / FighterStats / StrikeDB). Fighters always face the foe; movement is physics-based.

signal stats_changed
signal hit_landed(attacker: Fighter, info: Dictionary)
signal whiffed(attacker: Fighter, strike: String)
signal knocked_down(fighter: Fighter)
signal count_tick(fighter: Fighter, n: int)
signal state_changed(fighter: Fighter, state_name: String)
signal got_ko(fighter: Fighter, method: String)
signal clashed(other: Fighter, position: Vector3)   ## two straight punches met glove to glove (exchange.gd): no damage, both deflect

const HurtStateScript := preload("res://scripts/combat/hurt_state.gd")
const RockedPoseScript := preload("res://scripts/fighter/rocked_pose.gd")
const KnockdownMotion := preload("res://scripts/fighter/knockdown_motion.gd")
const FatigueScript := preload("res://scripts/combat/fatigue.gd")                 # fatigue pass
const FatiguePoseScript := preload("res://scripts/fighter/fatigue_pose.gd")      # fatigue pass: drooping guard + breathing
const StatusTagScript := preload("res://scripts/fighter/status_tag.gd")          # fatigue pass: ROCKED! / GASSED tag over the head
const RagdollScript := preload("res://scripts/fighter/ragdoll.gd")               # physics knockouts / knockdowns (PhysicalBone3D ragdoll)

enum State { IDLE, ATTACK, HIT, SLIP, CROUCH, FALL, COUNT, GETUP, DOWN, WIN, TAUNT }
const STATE_NAMES := ["idle", "attack", "hit", "slip", "crouch", "fall", "count", "getup", "down", "win", "taunt"]

const WALK_SPEED := 1.25
const GUARD_SPEED := 0.85
const CLIP_WALK_SPEED := 0.86
const DefenceMovesScript := preload("res://scripts/fighter/defence_moves.gd")
const PunchVariantsScript := preload("res://scripts/combat/punch_variants.gd")   # punch variety (variants, per-throw randomness)
const PunchPoseScript := preload("res://scripts/fighter/punch_pose.gd")          # procedural wind-up / aim / overextension
const BodyContactScript := preload("res://scripts/fighter/body_contact.gd")      # body contact: push / shove / break rules
const ContactPoseScript := preload("res://scripts/fighter/contact_pose.gd")      # body contact: lean / brace / shove pose layer
const ExchangeScript := preload("res://scripts/combat/exchange.gd")            # exchange: punch phases, trades, glove clash
const PoseLimiterScript := preload("res://scripts/fighter/pose_limiter.gd")      # pose polish: final hip / knee / trunk budget over all layers
const AlivePoseScript := preload("res://scripts/fighter/alive_pose.gd")          # liveliness: weight shift, head tracking, guard micro-motion, anticipation
const CommitmentScript := preload("res://scripts/combat/commitment.gd")   # punch commitment: lock time, whiff / block penalty, open window, punish
const InertializeScript := preload("res://scripts/fighter/inertialize.gd")      # inertialization: smooths every pose jump before the procedural layers
const ImpactHoldScript := preload("res://scripts/fighter/impact_hold.gd")        # visual impact: the glove stops on the skin and holds a few frames (gameplay sees the unclamped path)
const HitFlinchScript := preload("res://scripts/fighter/hit_flinch.gd")          # additive spring-damper hit flinch
const StancePoseScript := preload("res://scripts/fighter/stance_pose.gd")      # loaded guard stance (pelvis a few cm lower, feet planted)
const ArmClearScript := preload("res://scripts/fighter/arm_clear.gd")             # guard arms never pass through the fighter's own torso / head
const LeanPoseScript := preload("res://scripts/fighter/lean_pose.gd")            # analog lean (slips, pull-back, bob) pose layer
const AuthoredSlipScript := preload("res://scripts/fighter/authored_slip.gd")    # Blender-authored left-slip layer
const MODEL_PATH := "res://assets/fighters/%s.glb"
const VICTORY := ["Celebration_01", "Celebration_02", "Victory_Taunt", "Yes", "Bow", "Cheer", "Chest_Beat"]
const TAUNTS := ["Taunt", "Taunt (1)", "Finger_Taunt", "Up_Yours"]

@export var model := "viper"   ## roster id (scripts/fighter/roster.gd)
@export var player_index := 0
@export_enum("human", "cpu", "dummy") var controller := "human"

const RosterScript := preload("res://scripts/fighter/roster.gd")
const MeshySkinScript := preload("res://scripts/fighter/meshy_skin.gd")
const FighterLookScript := preload("res://scripts/fighter/fighter_look.gd")
## Derived from `model` so it is right even before the fighter enters the tree (the HUD binds first).
var display_name: String:
	get: return RosterScript.display_name(model)
## Gameplay template of the roster entry ("viper" / "anvil"): CPU style, guard style, hair, M3DMale body.
var template: String:
	get: return RosterScript.template(model)
var meshy_skin: Node   ## MeshySkin (Meshy roster entries only)
var stats := FighterStats.new()
var foe: Fighter
var rules := "kickboxing"
var difficulty := "normal"
var dummy_mode := "stationary"   ## stationary | guarding | moving (training dummy)
var practice := false
var frozen := false              ## another fighter is in a knockdown sequence
var input_locked := false
var state: State = State.IDLE
var inp := FighterInput.new()
var external_input: FighterInput    ## tests / replays can drive a fighter directly
var _blank_input := FighterInput.new()
var _own_input: FighterInput
var rng := RandomNumberGenerator.new()

# presentation
var model_root: Node3D
var anim := FighterAnimator.new()
var rig := FighterRig.new()
const GuardStyleScript := preload("res://scripts/fighter/guard_style.gd")
var guard_style   ## guard/stance variety + idle rhythm layer (scripts/fighter/guard_style.gd)
var debug_boxes := false

# combat runtime
var atk: Dictionary = {}          ## active attack: tag, s, t, A, hit_done, outcome, tail, serial, limb
var buffer: Array = []            ## queued strikes [{tag, t}]
var guard_on := false
var guard_body := false
const GuardModelScript := preload("res://scripts/combat/guard_model.gd")
const GuardKnockScript := preload("res://scripts/fighter/guard_knock.gd")
var guard_knock                   ## glove knock layer (scripts/fighter/guard_knock.gd)
var guard_age := 0.0              ## s since the guard went up (0 while it is down): coverage ramps in, parry window
var block_variant := ""           ## guard-style variant at the moment the guard went up ("lead_low" -> long guard, "peek")
var last_assess := {}             ## last guard verdict (tests / debugging)
var guard_open_t := 0.0           ## s left of a heavy shot knocking the gloves open (the guard leaks more)
var _press_ok := false            ## this block press may parry (no other press within PARRY_COOLDOWN)
var _press_t := -9.0
var _last_press := -9.0
var _prev_block_inp := false
var guard_log := {"full": 0, "partial": 0, "pierce": 0, "parry": 0}   ## outcome counts (tests, fight_stats)
var hit_t := 0.0
var hit_len := 0.0
var hit_clip := ""
var slip_dir := 0
var slip_t := 0.0
var slip_hold := false
var slip_release_t := -1.0
var stance_pose: SkeletonModifier3D   ## loaded guard stance layer (scripts/fighter/stance_pose.gd)
var lean_pose: SkeletonModifier3D   ## analog lean spring + pose (scripts/fighter/lean_pose.gd): lean_pose.pos = the lean now
var authored_slip: SkeletonModifier3D   ## optional authored pose; incompatible rigs retain the procedural lean
var lean_target := Vector2.ZERO     ## lean the fighter is asked for this tick (fighter frame: x left, y forward / -back)
var lean_hold := Vector2.ZERO       ## lean kept while a punch is thrown from it
var _backstepping := false
var _lean_side_paid := 0
var _move_cmd := Vector3.ZERO       ## smoothed movement command (footwork ease-in / ease-out)
var duck_t := 0.0
var duck_release_t := -1.0
var counter_window := 0.0         ## earned counter available (from a whiffed foe strike / good slip)
var counter_power := 0.0
var knock_t := 0.0
var count_n := 0
var knockdown_dir := "F"
var getup_count := 6              ## referee count at which this knockdown ends (10 = cannot beat the count -> KO)
var corner_target := Vector3.INF  ## set by Match on the STANDING fighter during a count: walk here (neutral corner)
var _fall_len := 2.0
var _getup_clip := KnockdownMotion.GETUP_FACE_UP
var ko_method := ""
var _ragdoll                      ## Ragdoll (scripts/fighter/ragdoll.gd): the KO / knockdown fall is physics, driven by the punch
var _last_hit := {}               ## the blow being resolved (fist velocity / position / speed / damage), read by the ragdoll impulse
var _rd_settled_t := 0.0
var ko_pending := ""
var taunt_t := 0.0
var rock_lock := 0.0
var hurt := HurtStateScript.new()       ## rocked / body-hurt episode (timing + look), see scripts/combat/hurt_state.gd
var _rocked_pose: SkeletonModifier3D      ## procedural hurt pose modifier (scripts/fighter/rocked_pose.gd)
var _lunge_left := 0.0
var _follow_atk: Dictionary = {}   ## the attack whose follow-through was already decided (same reference)
var _follow_v := 0.0             ## follow-through speed of a whiffed point-blank punch thrown while driving forward
var _lunge_dist := 0.0
var _lunge_t := 0.0
var _lunge_dur := 0.24             ## punch variants: duration of the entry step (default 0.24 s)
var inertia_post: SkeletonModifier3D
var inertia: SkeletonModifier3D   ## inertialization layer (first modifier after the AnimationTree)
var _punch_pose: SkeletonModifier3D
var _pose_limiter: SkeletonModifier3D   ## pose polish: last pose layer (scripts/fighter/pose_limiter.gd)
var _impulse := Vector3.ZERO
var _hit_flinch = null   ## set by the liveliness layer (scripts/fighter/hit_flinch.gd); null = no additive flinch available
var _stagger := 0.0      ## s after a flinch (a hit that did not interrupt): no new punch yet
var _push := Vector3.ZERO
var bc := BodyContactScript.new()   ## body contact (scripts/fighter/body_contact.gd): chest-to-chest pushing, shove-off, referee break
var _serial := 0
var _human: HumanController
var movement_mode := "fighter"   ## human move keys: "fighter" (W = toward the foe) or "camera" (W = away from the camera); see GameSettings
var _brain: CpuBrain
var _prev_foe_dir_angle := 0.0
var _side_dps := 0.0
var _closing_speed := 0.0
var _prev_gap := 0.0
var _time := 0.0
var _cur_guard_clip := ""
var dm := DefenceMovesScript.new()      ## defence family (shell / tilt / sway / roll / authored counters), scripts/fighter/defence_moves.gd

var health: float:
	get: return stats.head
var health_max: float:
	get: return stats.head_max
var stamina: float:
	get: return stats.stamina
var stamina_max: float:
	get: return stats.stamina_max
var fatigue: float:   ## 0 fresh .. 1 empty (fatigue pass): the pose layers / HUD / CPU read this
	get: return stats.fatigue()
var guard: float:
	get: return stats.guard
var guard_max: float:
	get: return stats.guard_max
var head_health: float:
	get: return stats.head
var body_health: float:
	get: return stats.body
var left_leg_health: float:
	get: return stats.lleg
var right_leg_health: float:
	get: return stats.rleg
var rocked: bool:
	get: return stats.rocked
var knockdown_count: int:
	get: return stats.knockdowns

var state_name: String:
	get: return STATE_NAMES[state]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	collision_layer = HitAreas.LAYER_BODY
	collision_mask = HitAreas.LAYER_WORLD | HitAreas.LAYER_BODY
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	rng.seed = 1000 + player_index
	bc.f = self
	stats.mass = RosterScript.mass(model)
	_own_input = inp
	var packed: PackedScene = load(RosterScript.template_path(model))
	model_root = packed.instantiate()
	model_root.name = "Model"
	$ModelSlot.add_child(model_root)
	_style_materials()
	var sk: Skeleton3D = model_root.find_child("Skeleton3D", true, false)
	rig.build(self, sk, player_index)
	inertia = InertializeScript.new()   # first modifier: smooths animation jumps before any procedural layer sees the pose
	inertia.name = "Inertialize"
	inertia.fighter = self
	sk.add_child(inertia)
	sk.move_child(inertia, 0)
	guard_style = GuardStyleScript.attach(self, sk)   # after rig.build so it runs after FistPose
	_attach_rocked_pose(sk)   # rocked rework
	_attach_fatigue_layers(sk)   # fatigue pass
	_punch_pose = PunchPoseScript.new()   # punch variety: runs after the other pose layers
	_punch_pose.name = "PunchPose"
	_punch_pose.fighter = self
	sk.add_child(_punch_pose)
	dm.setup(self)
	stance_pose = StancePoseScript.new()   # loaded guard stance (lower pelvis, wider feet): under the lean / slip layers
	stance_pose.name = "StancePose"
	stance_pose.fighter = self
	sk.add_child(stance_pose)
	lean_pose = LeanPoseScript.new()   # analog lean: after DefencePose, before the contact / alive / flinch layers
	lean_pose.name = "LeanPose"
	lean_pose.fighter = self
	lean_pose.speed = RosterScript.head_movement(model)
	sk.add_child(lean_pose)
	var contact_pose: SkeletonModifier3D = ContactPoseScript.new()   # body contact: lean / brace / shove, before the limiter
	contact_pose.name = "ContactPose"
	contact_pose.fighter = self
	sk.add_child(contact_pose)
	var alive: SkeletonModifier3D = AlivePoseScript.new()   # liveliness layers: after every other pose layer, before the limiter
	alive.name = "AlivePose"
	alive.fighter = self
	sk.add_child(alive)
	_hit_flinch = HitFlinchScript.new()
	_hit_flinch.name = "HitFlinch"
	_hit_flinch.fighter = self
	sk.add_child(_hit_flinch)
	guard_knock = GuardKnockScript.new()   # glove knock / parry swipe: after the flinch, before the limiter
	guard_knock.name = "GuardKnock"
	guard_knock.fighter = self
	sk.add_child(guard_knock)
	_pose_limiter = PoseLimiterScript.new()   # pose polish: after every pose layer (incl. DefencePose), before the ragdoll
	_pose_limiter.name = "PoseLimiter"
	_pose_limiter.fighter = self
	sk.add_child(_pose_limiter)
	inertia_post = InertializeScript.new()   # catches the pops the procedural layers (leg IK near full extension) introduce
	inertia_post.name = "InertializePost"
	inertia_post.fighter = self
	inertia_post.post = true
	inertia_post.pre = inertia
	inertia.post_peer = inertia_post
	sk.add_child(inertia_post)
	var arm_clear: SkeletonModifier3D = ArmClearScript.new()   # own-body clearance of the guard arms: after every pose layer, but BEFORE GloveClear (that one keeps the last word on the foe's head)
	arm_clear.name = "ArmClear"
	arm_clear.fighter = self
	sk.add_child(arm_clear)
	var glove_clear: SkeletonModifier3D = ContactPoseScript.new()   # last word on the gloves vs the foe's head (after every layer incl. the post inertialization, which would otherwise ease the correction and let the glove sink back through the head)
	glove_clear.name = "GloveClear"
	glove_clear.fighter = self
	glove_clear.post_clear = true
	sk.add_child(glove_clear)
	var impact_hold: SkeletonModifier3D = ImpactHoldScript.new()   # truly last: the striking glove never visibly passes through the foe, a landed blow holds it on the skin
	impact_hold.name = "ImpactHold"
	impact_hold.fighter = self
	sk.add_child(impact_hold)
	_ragdoll = RagdollScript.new()   # ragdoll: after every pose layer so its blend modifier runs last
	_ragdoll.build(sk)
	anim.setup(self, model_root)
	anim.inertia = inertia
	authored_slip = AuthoredSlipScript.attach(self)
	var skin_path: String = RosterScript.skin_path(model)
	if skin_path != "":
		_attach_meshy_skin(sk, skin_path)
	_configure_controller()
	if debug_boxes:
		set_debug_boxes(true)
	_set_state(State.IDLE)


const CORNER_COLORS := [Color("c9302c"), Color("2f62d6")]   ## P1 red corner, P2 blue corner
const HAIR_COLORS := {"viper": Color(0.045, 0.03, 0.026), "anvil": Color(0.02, 0.018, 0.018)}


## Per-fighter material copies (the glb's materials are shared by both fighters of a model): corner-coloured
## gloves / trunks / gi top, dark alpha-cut hair.
func _style_materials() -> void:
	var corner: Color = CORNER_COLORS[player_index % 2]
	var copies := {}
	for n in model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src := mi.get_active_material(i) as StandardMaterial3D
			if src == null:
				continue
			var mat: StandardMaterial3D = copies.get(src)
			if mat == null:
				mat = src.duplicate() as StandardMaterial3D
				copies[src] = mat
				var nm := String(src.resource_name)
				if nm.contains("Hair") or nm.contains("Shape"):
					_style_hair(mat)
				elif nm.begins_with("Left_LOD") or nm.begins_with("Right_LOD"):
					mat.albedo_color = corner
				elif nm.contains("KaratePants"):
					mat.albedo_color = corner.lerp(Color.WHITE, 0.15)
				elif nm.contains("KarateBelt"):
					mat.albedo_color = Color(0.12, 0.12, 0.13)
				elif nm.contains("KarateTop"):
					mat.albedo_color = Color.WHITE.lerp(corner, 0.28)
			mi.set_surface_override_material(i, mat)


## Meshy roster: hide the M3DMale meshes (the body stays as the logical skeleton) and show the retargeted Meshy skin.
func _attach_meshy_skin(sk: Skeleton3D, path: String) -> void:
	for n in model_root.find_children("*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).visible = false
	meshy_skin = MeshySkinScript.attach(self, $ModelSlot, sk, path)
	rig.rebind_visible(meshy_skin, model)   # hit / hurt / guard volumes ride the VISIBLE skeleton (hit_fit_vis.gd): what the player sees is what hits
	var tint := Color.WHITE.lerp(CORNER_COLORS[player_index % 2], 0.10)   # subtle corner tint so two of the same model differ
	var skin_id: String = String(RosterScript.def(model)["skin"])
	for n in meshy_skin.root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var src := mi.get_active_material(i) as StandardMaterial3D
			if src != null:
				var mat := src.duplicate() as StandardMaterial3D
				FighterLookScript.style_material(mat, skin_id, tint)   # rim, roughness, per-skin albedo (fighter_look.gd)
				mi.set_surface_override_material(i, mat)
	FighterLookScript.tag_meshes(meshy_skin.root)
	Callable(FighterLookScript, "ensure_lights").call_deferred(get_parent())


func _style_hair(mat: StandardMaterial3D) -> void:
	mat.albedo_color = HAIR_COLORS.get(template, Color(0.04, 0.03, 0.03))
	mat.roughness = 0.55
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if mat.albedo_texture != null:
		# hair cards: strand texture is grey + alpha. Cut it out (hashed edges avoid the grey speckle of a
		# plain opaque / low-threshold cut-out) and keep the colour dark via albedo_color.
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		mat.alpha_scissor_threshold = 0.5


func _configure_controller() -> void:
	match controller:
		"human":
			_human = HumanController.new("p%d" % (player_index + 1))
			_human.boxing = rules == "boxing"
		"cpu":
			_brain = CpuBrain.new()
			_brain.setup(self, difficulty, 4242 + player_index * 77)


func configure(p_rules: String, p_difficulty: String, p_practice: bool) -> void:
	rules = p_rules
	difficulty = p_difficulty
	practice = p_practice
	stats.practice = p_practice
	if _human:
		_human.boxing = rules == "boxing"
	if _brain:
		_brain.set_difficulty(difficulty)
		_brain.boxing = rules == "boxing"


func gap_to_foe() -> float:
	if foe == null:
		return 9.0
	var d := foe.global_position - global_position
	d.y = 0
	return d.length()


func dir_to_foe() -> Vector3:
	if foe == null:
		return global_basis.z
	var d := foe.global_position - global_position
	d.y = 0
	return d.normalized() if d.length() > 0.001 else global_basis.z


func local_dir(world: Vector3) -> Vector2:
	## (lateral = fighter's left positive, forward) of a world vector
	var b := global_basis
	return Vector2(world.dot(b.x), world.dot(b.z))


# ---------------------------------------------------------------- frame loop
func _physics_process(dt: float) -> void:
	_time += dt
	_ragdoll.track(dt)   # ragdoll: pose velocities while animated
	_ragdoll.tick(dt)
	_poll_input()
	_face_foe(dt)
	_measure_relative_motion(dt)
	_tick_timers(dt)
	_update_state(dt)
	_update_locomotion(dt)
	_apply_movement(dt)
	_update_guard()
	_update_hitboxes(dt)
	_resolve_attack_hits()
	_update_stats(dt)
	if not _debug_marks.is_empty():
		_tick_debug_marks()
	dm.tick(dt)   # defence family envelopes -> DefencePose (before the animation pass)
	_tick_lean(dt)
	_update_animation(dt)


func _poll_input() -> void:
	if input_locked:
		_blank_input.clear()
		inp = _blank_input
		return
	if external_input != null:
		inp = external_input
		return
	inp = _own_input
	match controller:
		"human":
			if _human:
				_human.poll(inp)
				_apply_movement_mode(inp)
		"cpu":
			if _brain and foe:
				_brain.think(get_physics_process_delta_time(), inp)
		_:
			_dummy_input()


## Human input arrives as "keys": move.y > 0 = W / up, move.x > 0 = D / right, slip +1 = Q. The movement mode turns that into
## the ring frame the rest of the fighter uses (FighterInput.move is world X / -Z).
##  "fighter": W = toward the foe, S = away, A / D = circle him (camera independent); Q / E and the lean stick stay fighter-relative.
##  "camera": W = along the camera's ground forward, A / D = camera right / left; Q / E and the stick's side lean are screen-left / right.
func _apply_movement_mode(i: FighterInput) -> void:
	if movement_mode == "camera":
		var fwd := _camera_ground_forward()
		var right := fwd.cross(Vector3.UP)
		var w := right * i.move.x + fwd * i.move.y
		i.move = Vector2(w.x, -w.z)
		if i.slip != 0:   # screen-left key -> the fighter's side that is on the camera's left
			var lat := (-right * float(i.slip)).dot(global_basis.x)
			i.slip = 0 if absf(lat) < 0.05 else (1 if lat > 0.0 else -1)
		if absf(i.lean.x) > 0.0:
			var lat := (right * -i.lean.x).dot(global_basis.x)   # lean.x is "fighter left" for a right-stick push left; treat the push as screen-left
			i.lean.x = clampf(lat, -1.0, 1.0)
		return
	var f := dir_to_foe()
	if f.length() < 0.01:
		f = global_basis.z
	f.y = 0.0
	f = f.normalized()
	var left := Vector3.UP.cross(f)
	var w2 := f * i.move.y - left * i.move.x
	i.move = Vector2(w2.x, -w2.z)


func _camera_ground_forward() -> Vector3:
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	var fwd := -cam.global_basis.z if cam != null else Vector3(0, 0, -1)
	fwd.y = 0.0
	return fwd.normalized() if fwd.length() > 0.01 else Vector3(0, 0, -1)


func _dummy_input() -> void:
	inp.clear()
	if foe == null:
		return
	match dummy_mode:
		"guarding":
			inp.block = true
			inp.body = foe.inp.body if foe.inp else false
		"moving":
			var t := _time
			inp.move = Vector2(0, sin(t * 0.9)) * 0.8
			var d := foe.global_position - global_position
			if absf(d.x) > 1.25 and gap_to_foe() > 1.25:
				inp.move.x = signf(d.x) * 0.8


func _face_foe(dt: float) -> void:
	if foe == null or state in [State.FALL, State.COUNT, State.DOWN]:
		return
	if state == State.GETUP and knock_t < 1.2:
		return   # no spinning on the canvas while sitting up
	var d := foe.global_position - global_position
	if corner_target != Vector3.INF and frozen:
		var to_c := corner_target - global_position   # walking to the neutral corner: face the way we walk
		if Vector2(to_c.x, to_c.z).length() > 0.15:
			d = to_c
	if Vector2(d.x, d.z).length() < 0.05:
		return
	var want := atan2(d.x, d.z)
	rotation.y = lerp_angle(rotation.y, want, 1.0 - exp(-(6.0 if state == State.GETUP else 16.0) * dt))


func _measure_relative_motion(dt: float) -> void:
	if foe == null or dt <= 0.0:
		return
	var gap := gap_to_foe()
	_closing_speed = lerpf(_closing_speed, (_prev_gap - gap) / dt, 1.0 - exp(-30.0 * dt))
	_prev_gap = gap
	var ang := atan2(foe.global_position.x - global_position.x, foe.global_position.z - global_position.z)
	_side_dps = lerpf(_side_dps, rad_to_deg(angle_difference(_prev_foe_dir_angle, ang)) / dt, 1.0 - exp(-20.0 * dt))
	_prev_foe_dir_angle = ang


func _tick_timers(dt: float) -> void:
	counter_window = maxf(counter_window - dt, 0.0)
	rock_lock = maxf(rock_lock - dt, 0.0)
	_stagger = maxf(_stagger - dt, 0.0)
	hurt.tick(dt)   # rocked rework
	for b in buffer:
		b["t"] -= dt
	buffer = buffer.filter(func(b): return b["t"] > 0.0)


# ---------------------------------------------------------------- state machine
func _set_state(s: State) -> void:
	if s == state and s != State.IDLE:
		return
	state = s
	# A downed body lies away from the standing capsule, so the two fighters stop colliding with each other while
	# one is down (_separate_from_downed keeps the foe off the body). The capsule itself stays on: disabling it
	# dropped the downed fighter through the floor.
	if foe != null:
		var down := s in [State.FALL, State.COUNT, State.GETUP, State.DOWN]
		if down:
			add_collision_exception_with(foe)
		elif not foe.state in [State.FALL, State.COUNT, State.GETUP, State.DOWN]:
			remove_collision_exception_with(foe)
	state_changed.emit(self, STATE_NAMES[s])


func is_acute_down() -> bool:
	return state in [State.FALL, State.COUNT, State.GETUP]


func is_out() -> bool:
	return state in [State.DOWN, State.WIN]


func can_act() -> bool:
	return state in [State.IDLE, State.SLIP, State.CROUCH] and not frozen


func _update_state(dt: float) -> void:
	if frozen and state != State.DOWN and state != State.WIN:
		_cancel_to_idle()
		buffer.clear()
		return
	match state:
		State.IDLE:
			_update_idle(dt)
		State.ATTACK:
			_update_attack(dt)
		State.HIT:
			hit_t += dt
			_queue_strikes()
			if hit_t >= hit_len:
				anim.end_action(0.28 if hurt.active() else 0.12)   # rocked rework: slow hand-over to the pose layer
				_set_state(State.IDLE)
		State.SLIP:
			_update_slip(dt)
		State.CROUCH:
			_update_crouch(dt)
		State.FALL:
			knock_t += dt
			_keep_lying_body_in_ring(dt)
			if _ragdoll.active:   # ragdoll: the fall lasts until the body is at rest (bounded)
				_fall_len = RAGDOLL_FALL_MIN if _ragdoll.calm() else RAGDOLL_FALL_MAX
			if knock_t >= _fall_len:
				_set_state(State.COUNT)
				knock_t = 0.0
				count_n = 0
		State.COUNT:
			knock_t += dt
			_keep_lying_body_in_ring(dt)
			# referee count: "1" half a second after the fall ends, then one number every COUNT_STEP seconds
			var want_n := 0 if knock_t < COUNT_FIRST else int((knock_t - COUNT_FIRST) / COUNT_STEP) + 1
			while count_n < mini(want_n, getup_count):
				count_n += 1
				count_tick.emit(self, count_n)
			if count_n >= getup_count and knock_t >= COUNT_FIRST + (getup_count - 1) * COUNT_STEP + COUNT_STEP * 0.6:
				if getup_count >= 10:
					_lose_by_count()
				else:
					_start_getup()
		State.GETUP:
			knock_t += dt
			if knock_t >= anim.clip_length(_getup_clip) - 0.05:
				anim.end_action(0.32)   # slow blend from the last get-up frame into the locomotion / guard layer
				stats.guard_lock = 0.3
				stats.rocked = false
				stats.stun_left = 0.0
				hurt.clear()
				_set_state(State.IDLE)
				_begin_post_getup_hurt()
		State.TAUNT:
			taunt_t -= dt
			if taunt_t <= 0.0:
				anim.end_action(0.15)
				_set_state(State.IDLE)
		State.DOWN:
			_keep_lying_body_in_ring(dt)
		State.WIN:
			pass


func _cancel_to_idle() -> void:
	if state in [State.ATTACK, State.SLIP, State.CROUCH, State.HIT, State.TAUNT]:
		atk = {}
		slip_dir = 0
		_backstepping = false
		anim.end_action(0.1)
		_set_state(State.IDLE)


func _update_idle(dt: float) -> void:
	if _try_queue_or_start(dt):
		return
	_try_defence_moves()


## Strikes pressed this tick: start one if possible, otherwise queue it (max 2).
func _queue_strikes() -> void:
	for t in inp.strikes:
		if StrikeDB.has_strike(t):
			var limb := String(t)[0]
			for i in range(buffer.size() - 1, -1, -1):
				if String(buffer[i]["tag"])[0] == limb:
					buffer.remove_at(i)
			buffer.append({"tag": t, "t": 0.55})
			while buffer.size() > 2:
				buffer.pop_front()


func _try_queue_or_start(_dt: float) -> bool:
	_queue_strikes()
	if rules == "boxing":
		buffer = buffer.filter(func(b): return not StrikeDB.get_strike(b["tag"]).get("is_leg", false))
	if buffer.is_empty():
		return false
	if rock_lock > 0.0 or stats.rocked and state == State.HIT:
		return false
	var next: Dictionary = buffer[0]
	if begin_attack(next["tag"]):
		buffer.pop_front()
		return true
	return false


func _try_defence_moves() -> void:
	if inp.taunt and not inp.block and state == State.IDLE:
		_start_taunt()
		return
	if inp.duck:
		_enter_crouch()
		return
	if _lean_wanted().length() >= LEAN_ENTER and (stats.stamina >= 3.0 or stats.infinite_stamina):
		_enter_slip(signi(int(roundf(_lean_wanted().x * 1.5))), false)
		return
	if inp.backstep and (stats.stamina >= 3.0 or stats.infinite_stamina):
		_enter_slip(0, true)


func _slip_from_input() -> int:
	## side of the lean asked for (fighter frame, +1 = fighter's left): the direction the roll / counters use
	var x := _lean_wanted().x
	return 0 if absf(x) < 0.3 else (1 if x > 0.0 else -1)


const LEAN_ENTER := 0.12
const DUCK_SLIP_SHARE := 0.6   ## a slip out of a duck is shallower than a standing one: the base is already folded
var defence_damp := 1.0        ## 0.25..1: rocked / fatigue neck-head layers are scaled by this while leaning / ducking
var _block_w := 0.0            ## smoothed "guard up" weight for the lean poses (_block variants)


## The lean the input asks for, fighter frame (x: +1 left, y: +1 forward / -1 back), |v| <= 1. Sources: the lean modifier + move stick,
## the right-stick analog lean, and the Q / E shortcuts (full side lean; with a step away from the foe a diagonal lean back).
func _lean_wanted() -> Vector2:
	var v := Vector2.ZERO
	if inp.lean_mod:
		if inp.move.length() > 0.12:
			var m := local_dir(Vector3(inp.move.x, 0, -inp.move.y))
			v = m.limit_length(1.0)
	elif inp.lean.length() > 0.02:
		v = inp.lean
	elif inp.slip != 0:
		v = Vector2(float(inp.slip), 0.0)
		if inp.move.length() > 0.4 and local_dir(Vector3(inp.move.x, 0, -inp.move.y).normalized()).y < -0.45:
			v = Vector2(float(inp.slip) * 0.5, -0.95)   # slip + stepping away = lean back and aside (sway)
	if inp.lean.y < -0.5 and v.y > -0.5 and not inp.lean_mod:
		v.y = inp.lean.y   # lean-back key on top of a side lean
	if inp.block and stats.guard_lock <= 0.0 and stats.guard > 0.0:
		v *= 0.55   # tilt behind the high guard: small and quick
	if (stats.stamina <= 0.0 and not stats.infinite_stamina) or stats.rocked and hurt.active():
		v *= 0.35
	return v.limit_length(1.0)


## Lean target / spring for this tick (called after the state update).
func _tick_lean(dt: float) -> void:
	var want := _lean_wanted()
	match state:
		State.SLIP:
			# Direct release is the analog contract: no minimum press time and no forced full-depth hold.
			lean_target = Vector2.ZERO if _backstepping else want
		State.ATTACK:
			if want.length() > 0.08:
				lean_hold = want
			elif not atk.is_empty() and float(atk["t"]) > 0.7 * float(atk["A"]):
				lean_hold = Vector2.ZERO   # released while the punch is on its way back
			lean_target = lean_hold
		State.IDLE:
			lean_target = Vector2.ZERO
			lean_hold = Vector2.ZERO
		State.CROUCH:
			# Duck + slip is one move: the authored duck lowers the base, the analog slip leans out of it (no separate roll clips).
			lean_target = Vector2(want.x * DUCK_SLIP_SHARE, 0.0)
			lean_hold = Vector2.ZERO
		_:
			lean_target = Vector2.ZERO
			lean_hold = Vector2.ZERO
	var lp = lean_pose
	_block_w = move_toward(_block_w, 1.0 if (inp.block and stats.guard_lock <= 0.0 and stats.guard > 0.0) else 0.0, dt / 0.12)
	lp.target = lean_target
	lp.duck_w = move_toward(lp.duck_w, 1.0 if (state == State.CROUCH and duck_release_t < 0.0) else 0.0, dt / 0.2)
	lp.tick(dt)
	# Free / blocked leans and ordinary punches use the calibrated procedural pose at full weight. Authored counter
	# clips carry their own lean, so hand that share over in lockstep with the action crossfade (1 = procedural,
	# 0 = counter clip) instead of dropping the procedural pose before the clip has become visible.
	lp.auth_k = anim.action_lean_share()
	anim.set_lean(lp.pos, _block_w)
	# rocked / fatigue layers add neck + head rotation: damp them while the head is moving or ducked (the neck never looks broken)
	defence_damp = 1.0 - 0.75 * clampf(maxf(lp.pos.length(), lp.duck_w), 0.0, 1.0)


## The head moved out of a head strike that is in the air (slip / pull) and the fighter is leaning: counts as an earned counter.
func _lean_counter() -> bool:
	if lean_pose.pos.length() < 0.4 or foe == null or foe.state != State.ATTACK or foe.atk.is_empty():
		return false
	return String(foe.atk["s"]["zone"]) == "head" and not foe.atk["hit_done"]


# -- attack
func begin_attack(tag: String) -> bool:
	var s := StrikeDB.get_strike(tag)
	var cv := {}
	if (counter_window > 0.0 or lean_pose.pos.length() > 0.5) and not s.is_empty():
		cv = dm.counter_variant(tag)   # slip / sway -> rear hook plays the authored DEF_counter_* clip
		if not cv.is_empty():
			s = cv
	if cv.is_empty() and not s.is_empty():
		tag = PunchVariantsScript.resolve(self, tag)   # punch variety: pick a concrete variant (tap / power / chain / step / pull)
		s = StrikeDB.get_strike(tag)
	if s.is_empty():
		return false
	if rules == "boxing" and s["is_leg"]:
		return false
	if not stats.can_spend(FatigueScript.strike_cost(s)) or FatigueScript.blocks_power(stats.stamina_ratio(), s) and not stats.infinite_stamina:
		return false   # fatigue pass: costs scaled up, and a gassed fighter (< 20 %) can only throw jabs
	if hurt.offence_locked() or _stagger > 0.0 or bc.blocks_offence():   # rocked rework: dazed / folded fighters throw nothing; a flinch delays the next punch a beat; body contact: shoved / shoving / referee break
		return false
	if state == State.CROUCH and s["is_leg"]:
		return false
	var pv_roll: Dictionary = PunchVariantsScript.roll(self, s)   # punch variety: per-throw randomness
	if not s["is_leg"]:
		s = s.duplicate()
		s["hang"] = float(s.get("hang", 0.0)) * float(pv_roll.get("hold", 1.0))   # the glove holds out a little longer / shorter each time
	var lvl := stats.fatigue()
	var a: float = s["action"] * (1.18 if stats.rocked else 1.0) * FatigueScript.action_scale(lvl) * pv_roll["speed"]   # tired arms are slow (k drives the time remap)
	stats.spend_stamina(FatigueScript.strike_cost(s), FatigueScript.strike_lock(s, 0.0))
	_serial += 1
	var limb: String = ("l" if s["limb"] == "L" else "r") + ("Foot" if s["is_leg"] else "Hand")
	var counter := counter_power > 0.0 or counter_window > 0.0 or _lean_counter()
	lean_hold = lean_target   # a punch thrown from a lean keeps the lean (LeanPose holds it through the throw)
	_backstepping = false
	counter_power = 0.0
	atk = {"tag": tag, "s": s, "t": 0.0, "A": a, "hit_done": false, "outcome": "pending", "tail": 0.0,
		"serial": _serial, "limb": limb, "counter": counter, "k": a / s["action"], "tail_t": 0.0, "var": pv_roll}
	PunchVariantsScript.note_start(self, tag)
	counter_window = 0.0
	slip_dir = 0
	guard_on = false
	# The counter clip owns the lean as it fades in; the animator hands the procedural share over by action weight.
	anim.play_action(s["clip"], 0.0, 0.08, 0.0, s.has("counter_clip"))   # speed is driven per tick through the strike time remap
	anim.set_action_rate(StrikeDB.clip_rate(s, 0.0, atk["k"], get_physics_process_delta_time()))
	if s.has("counter_clip"):
		_lunge_left = 0.0   # the authored counter carries its own step: no extra slide on top (the rear leg stretched)
	else:
		_start_lunge(s)
	PunchVariantsScript.after_start(self, s)   # variants own their entry step (flick none, lunge long, pull-back negative)
	_set_state(State.ATTACK)
	return true


## A blow that lands before full reach would keep pushing the glove into the skin (ImpactHold keeps it on the surface) through the rest of the
## extension and the hold: the glove looked glued to the face for ~0.15-0.2 s. The CLIP moves on instead: it gets through what is left of the reach
## and the hold in at most CONTACT_CATCHUP (a third of the time it had left) and then returns at its normal speed (so it is back in the guard that
## much earlier). Gameplay time (atk["t"]: lock, chain, recovery, the hit sweeps already done) is untouched; only the animation position runs ahead.
const CONTACT_CATCHUP := 0.05
func _catch_up_after_contact() -> void:
	var s: Dictionary = atk["s"]
	if s["is_leg"] or atk.has("vis"):
		return
	var t0: float = atk["t"]
	var p: float = (float(s["t_peak"]) + float(s.get("hang", 0.0))) * float(atk["k"])   # end of the hold, real seconds
	if p > t0 + 0.01:
		atk["vis"] = [t0, t0 + minf(CONTACT_CATCHUP, (p - t0) * 0.35), p]


## Animation time of the current punch for gameplay time t (see _catch_up_after_contact).
func _vis_t(t: float) -> float:
	var v: Array = atk.get("vis", [])
	if v.is_empty() or t <= v[0]:
		return t
	if t <= v[1]:
		return v[0] + (t - v[0]) * (v[2] - v[0]) / (v[1] - v[0])
	return t + v[2] - v[1]


func _start_lunge(s: Dictionary) -> void:
	_lunge_left = 0.0
	if foe == null:
		return
	var gap := gap_to_foe()
	var limit := 0.18
	var tag: String = s["tag"]
	if tag.contains("Jab"):
		limit = 0.45 if (tag.begins_with("L") and inp.move.length() > 0.2) else 0.28
	elif tag.contains("Hook"):
		limit = 0.42
	elif tag == "RUppercut":
		limit = 0.24
	if s["is_leg"]:
		limit = 0.0
	var hi := 1.75 if tag == "LJab" else 1.70
	# never step closer than the punch needs: straights (which reach further: punch_pose.gd REACH_LEAN) stop at a jab's length, not chest to
	# chest (stepping to 0.76 m made every jab land on a bent arm with the bodies crowding each other)
	var stop := 0.85 if String(s.get("dir", "F")) == "F" else 0.76
	if gap > stop + 0.02 and gap < hi and limit > 0.0:
		_lunge_dist = minf(gap - stop, limit)
		_lunge_left = 0.24
		_lunge_t = 0.0


func _update_attack(dt: float) -> void:
	if atk.is_empty():
		_set_state(State.IDLE)
		return
	var s: Dictionary = atk["s"]
	var a: float = atk["A"]
	atk["t"] += dt
	var t: float = atk["t"]
	var k: float = atk["k"]
	var prog := t / a
	anim.set_action_rate((StrikeDB.clip_time(s, _vis_t(t + dt) / k) - StrikeDB.clip_time(s, _vis_t(t) / k)) / maxf(dt, 0.0001))
	# outcome bookkeeping
	if atk["outcome"] == "pending" and t >= s["recoil"] * k and not atk["hit_done"] and t >= s["w1"] * k:
		atk["outcome"] = "missed"
		CommitmentScript.note_outcome(atk, "missed")
	_queue_strikes()
	var kick: bool = s["is_leg"]
	_ease_off_from_trade()
	# punch commitment: the guard / feet come back only once the retraction (and any whiff / block penalty) is done
	var lock := CommitmentScript.lock_end(atk)
	var parried: bool = atk.get("parried", false)   # parried: arm knocked aside, no guard / walking out of it until the recovery is over
	if inp.block and t >= lock and stats.guard > 0.0 and stats.guard_lock <= 0.0 and not parried:
		_end_attack(true)
		return
	if inp.move.length() > 0.3 and t >= lock and not parried:
		_end_attack(true)
		return
	# chain into queued strike (a whiffed loaded punch cannot be chained out of)
	if not buffer.is_empty() and t >= _chain_gate() and not CommitmentScript.blocks_chain(atk):
		var nxt: Dictionary = buffer[0]
		if rock_lock <= 0.0 and stats.can_spend(StrikeDB.get_strike(nxt["tag"]).get("stamina", 999.0)):
			_finish_attack_event(atk)
			buffer.pop_front()
			if begin_attack(nxt["tag"]):
				return
	if t >= a:
		if atk["outcome"] == "pending":
			atk["outcome"] = "missed"
			CommitmentScript.note_outcome(atk, "missed")
		if atk["tail"] == 0.0:
			atk["tail"] = CombatRules.outcome_tail(s, atk["outcome"]) + PunchVariantsScript.tail_extra(s, atk["outcome"])   # power whiffs overextend
			if atk["outcome"] == "missed":
				atk["tail"] = maxf(atk["tail"], CommitmentScript.lock_end(atk) - a)
			if atk["outcome"] == "missed":
				PunchVariantsScript.on_miss(self, s)
				_report_whiff()
		atk["tail_t"] += dt
		if atk["tail_t"] >= atk["tail"]:
			_end_attack(false)


## Both fighters are punching at once now (a hit no longer cancels the other punch): torsos lean through each other
## unless the roots drift apart a little, as they do in a real exchange (each steps / rides back off the other's glove).
const TRADE_SPACING := 0.92
func _ease_off_from_trade() -> void:
	if foe == null or foe.state != State.ATTACK or punch_phase() in ["startup", "committed"] or foe.punch_phase() == "startup":
		return
	var gap := gap_to_foe()
	if gap < TRADE_SPACING:
		_push += -dir_to_foe() * (TRADE_SPACING - gap) * 0.12
		_push = _push.limit_length(1.0)


func _chain_gate() -> float:
	var s: Dictionary = atk["s"]
	var a: float = atk["A"]
	var nxt := StrikeDB.get_strike(buffer[0]["tag"])
	var gate: float = s["chain"] * atk["k"]
	if nxt.is_empty():
		return a
	var paired: bool = nxt["limb"] != s["limb"] or nxt.get("base_tag", nxt["tag"]) == s.get("base_tag", s["tag"])   # a double jab: the rolled variant (LJab~std2) pairs with the next LJab press
	if s["is_leg"] != nxt["is_leg"]:
		gate = maxf(gate, (0.96 if not nxt["is_leg"] else 0.88) * a)
	elif not paired:
		gate = maxf(gate, 0.82 * a)
	return minf(gate, a)


func _finish_attack_event(prev: Dictionary) -> void:
	if prev["outcome"] == "pending" and not prev["hit_done"]:
		prev["outcome"] = "missed"
		CommitmentScript.note_outcome(prev, "missed")
		_report_whiff()


func _report_whiff() -> void:
	if atk.get("whiff_reported", false):
		return
	atk["whiff_reported"] = true
	stats.spend_stamina(FatigueScript.whiff_cost(atk["s"]), 0.5)   # fatigue pass: swinging at air costs extra
	whiffed.emit(self, atk["tag"])
	if foe and foe.state in [State.SLIP, State.CROUCH] and foe.dm.evading() and not atk.get("blocked", false):
		var zone: String = atk["s"]["zone"]
		if zone == "head":
			foe.counter_window = 0.40
			foe.dm.note_evasion()


func _end_attack(cancel: bool) -> void:
	if not atk.is_empty() and atk["outcome"] == "pending" and not atk["hit_done"]:
		atk["outcome"] = "missed"
		if not cancel:
			_report_whiff()
	atk = {}
	anim.end_action(0.12)
	_set_state(State.IDLE)


# -- slip / duck
## Enters the lean state (SLIP): the analog lean itself is the LeanPose spring, driven by `_tick_lean`. `back` = the B Dodge backstep.
func _enter_slip(dir: int, back: bool) -> void:
	slip_dir = dir
	slip_t = 0.0
	slip_hold = false
	slip_release_t = -1.0
	_backstepping = back
	var fresh: bool = lean_pose.pos.length() < 0.3   # re-entering from an attack while the lean is still held costs nothing
	dm.begin_slip(dir, back)   # tilt (block held) / sway (leaning back) / slip: names the lean for the CPU, counters and stats
	if back or fresh:
		stats.spend_stamina(dm.slip_stamina(back), 0.25)
	_lean_side_paid = dir
	if back:
		anim.play_action("B Dodge", 0.82 * 0.8, 0.06)
		_lunge_left = 0.16
		_lunge_dist = -0.12
		_lunge_t = 0.0
	_set_state(State.SLIP)


func _update_slip(dt: float) -> void:
	slip_t += dt
	if _try_queue_or_start(dt):
		return
	if inp.duck:
		_enter_crouch()
		return
	if _backstepping:
		# backstep: committed for entry + release
		if slip_t >= 0.5:
			_backstepping = false
			anim.end_action(0.12)
			_set_state(State.IDLE)
		return
	var want := _lean_wanted()
	dm.update_lean_kind(want)
	if want.length() >= 0.08:
		slip_release_t = -1.0
		var side := _slip_from_input()
		slip_dir = side
		if side != 0 and side != _lean_side_paid:   # flicking to the other side again costs a slip
			if _lean_side_paid != 0 and not stats.infinite_stamina and stats.stamina < 3.0:
				lean_target = Vector2.ZERO
			else:
				if _lean_side_paid != 0:
					stats.spend_stamina(3.0, 0.25)
				_lean_side_paid = side
	else:
		if slip_release_t < 0.0:
			slip_release_t = 0.0
		slip_release_t += dt
		slip_dir = 0
		_lean_side_paid = 0
		# back to the guard: the lean spring has to be (nearly) home before the state ends
		if lean_pose.pos.length() < 0.07 or slip_release_t > 0.9:
			dm.kind = ""
			_set_state(State.IDLE)


func _enter_crouch() -> void:
	duck_t = 0.0
	duck_release_t = -1.0
	slip_dir = 0
	var guard_suffix := "_block" if (inp.block and stats.guard_lock <= 0.0) else ""
	dm.begin_crouch()   # duck + slip direction = deep roll (DEF_duck_left / right + DefencePose hinge)
	anim.play_action(dm.duck_clip(guard_suffix), 0.55 * 0.24 / 0.21, 0.05)
	_set_state(State.CROUCH)


func _update_crouch(dt: float) -> void:
	duck_t += dt
	if _try_queue_or_start(dt):
		return
	var guard_suffix := "_block" if (inp.block and stats.guard_lock <= 0.0) else ""
	if duck_release_t < 0.0:
		if duck_t >= 0.24 and not slip_hold:
			slip_hold = true
			anim.play_action(dm.duck_clip(guard_suffix) + "_hold", 0.0, 0.03)
		if duck_t >= 0.24 and not inp.duck:
			duck_release_t = 0.0
			slip_hold = false
			anim.play_action(dm.duck_clip(guard_suffix), 0.23, 0.04, 0.21)
		elif duck_t >= 0.1 and inp.duck and dm.roll_changed():
			dm.retarget_roll()   # the slip side changed while ducked: the lean spring carries it, the duck clip keeps playing
	else:
		duck_release_t += dt
		if duck_release_t >= 0.23:
			anim.end_action(0.08)
			slip_hold = false
			_set_state(State.IDLE)


func _start_taunt() -> void:
	var c: String = TAUNTS[rng.randi() % TAUNTS.size()]
	taunt_t = minf(anim.clip_length(c), 2.5)
	anim.play_action(c, 0.0, 0.15)
	_set_state(State.TAUNT)


func is_taunting() -> bool:
	return state == State.TAUNT


# ---------------------------------------------------------------- guard
func _update_guard() -> void:
	var dt := get_physics_process_delta_time()
	if inp.block and not _prev_block_inp:   # a block press: only an un-mashed one can parry
		_press_ok = _time - _last_press >= GuardModelScript.PARRY_COOLDOWN
		_last_press = _time
		_press_t = _time
	_prev_block_inp = inp.block
	var can_guard := state in [State.IDLE, State.SLIP, State.CROUCH] and inp.block 		and stats.guard > 0.0 and stats.guard_lock <= 0.0 and not frozen
	if state == State.SLIP and _backstepping:
		can_guard = false
	if can_guard and not guard_on:   # the guard goes up now
		guard_age = 0.0
		block_variant = guard_style.variant if guard_style != null else ""
		if _time - _press_t > 0.25:
			_press_ok = false   # the press was a while ago (the guard was unavailable): nothing to parry with
	guard_on = can_guard
	guard_body = guard_on and inp.body
	guard_age = guard_age + dt if guard_on else 0.0
	guard_open_t = maxf(guard_open_t - dt, 0.0)
	var clip := ""
	if guard_on and (state == State.IDLE or dm.keeps_guard_pose()):
		clip = "Body Block" if guard_body else "KB_Block_Loop"
	if clip != _cur_guard_clip:
		var raising := clip != ""
		_cur_guard_clip = clip
		anim.set_guard(clip, 0.10 if raising else 0.06)   # the guard takes ~0.1 s to come up, drops quicker


# ---------------------------------------------------------------- movement
func _update_locomotion(dt: float) -> void:
	if _walk_to_corner(dt):
		return
	var want := Vector3(inp.move.x, 0, -inp.move.y)
	if want.length() > 1.0:
		want = want.normalized()
	if inp.lean_mod or (state == State.SLIP and not _backstepping and _lean_wanted().length() > 0.3):
		want = Vector3.ZERO   # the stick is leaning, not walking
	var max_speed := WALK_SPEED
	if guard_on:
		max_speed = GUARD_SPEED
	max_speed *= hurt.move_scale() if hurt.active() else (0.68 if stats.rocked else 1.0)   # rocked rework
	max_speed *= FatigueScript.move_scale(stats.fatigue())   # fatigue pass
	match state:
		State.ATTACK:
			var s: Dictionary = atk.get("s", {})
			if s.get("heavy", false) and not s.get("is_leg", false):
				max_speed = 0.0 if atk["t"] < 0.78 * atk["A"] else max_speed
			elif s.get("is_leg", false):
				max_speed = 0.0
			else:
				max_speed *= 0.46
		State.CROUCH:
			max_speed *= 0.65
		State.HIT, State.FALL, State.COUNT, State.GETUP, State.DOWN, State.WIN, State.TAUNT:
			max_speed = 0.0
	if frozen:
		max_speed = 0.0
	# leaning plants the feet: the deeper the lean the less he walks (weight is on the lead / rear foot)
	if lean_pose != null:
		max_speed *= 1.0 - smoothstep(0.10, 0.60, lean_pose.pos.length())
	var target := want * max_speed
	# footwork ease: the command is smoothed first (no instant start / direction snap), then the body follows it.
	# ~0.25 s to full speed from standstill, ~0.18 s to stop (FNC footwork: steps ease in / out over 0.25-0.3 s) (the stop is a little quicker than the start)
	var cmd_up := target.length() >= _move_cmd.length()
	_move_cmd = _move_cmd.lerp(target, 1.0 - exp(-(24.0 if cmd_up else 32.0) * dt))
	var vcur := Vector3(velocity.x, 0, velocity.z)
	var rate := 19.0 if _move_cmd.length() >= vcur.length() else 26.0
	var vh := vcur.lerp(_move_cmd, 1.0 - exp(-rate * dt))
	velocity.x = vh.x
	velocity.z = vh.z


func _apply_movement(dt: float) -> void:
	if _ragdoll.active:   # ragdoll: the capsule is off, it just follows the body (see _follow_ragdoll)
		_follow_ragdoll()
		return
	# entry step / lunge
	var extra := Vector3.ZERO
	if _lunge_left > 0.0:
		var prev_t := _lunge_t
		_lunge_t = minf(_lunge_t + dt, _lunge_dur)
		var f0 := smoothstep(0.0, _lunge_dur, prev_t)
		var f1 := smoothstep(0.0, _lunge_dur, _lunge_t)
		var d := _lunge_dist * (f1 - f0)
		extra += dir_to_foe() * (d / dt)
		_lunge_left -= dt
		if _lunge_dist > 0.0 and inp.move.length() > 0.2 and local_dir(Vector3(inp.move.x, 0, -inp.move.y).normalized()).y < -0.3 and state == State.ATTACK:
			_lunge_left = 0.0
	# follow-through: a punch that found nothing, thrown at point blank while driving forward, carries the thrower's weight on into the foe
	if state == State.ATTACK and not atk.is_empty() and atk["outcome"] == "missed" and not is_same(atk, _follow_atk):
		_follow_atk = atk
		var fgap := gap_to_foe()
		if _lunge_left <= 0.0 and fgap < 0.75 and fgap > 0.3 and inp.move.length() > 0.3 and local_dir(Vector3(inp.move.x, 0, -inp.move.y).normalized()).y > 0.3:
			_follow_v = clampf((fgap - 0.40) * 10.0, 0.5, 2.5)   # m/s, decays like a shove: travels v / 10 (about 0.2 m)
	if _follow_v > 0.01:
		extra += dir_to_foe() * _follow_v
		_follow_v *= exp(-10.0 * dt)
	_impulse = _impulse * exp(-18.0 * dt)
	_push = _push * exp(-10.0 * dt)
	bc.step(dt, extra)   # body contact: force balance with the foe (bc.correction), shove-off, referee break
	var v0 := velocity
	velocity.x += extra.x + _impulse.x + _push.x + bc.move_correction().x
	velocity.z += extra.z + _impulse.z + _push.z + bc.move_correction().z
	if is_on_floor():
		velocity.y = -0.5
	else:
		velocity.y -= 9.8 * dt
	move_and_slide()
	velocity.x = v0.x
	velocity.z = v0.z
	_separate_from_downed(dt)


## Floor for the root-to-root distance of two standing fighters = 2 x capsule radius in fighter.tscn (0.12). The capsule is only the
## walking collision, deliberately narrow: how close two fighters really get is decided by their visible bodies (torsos, heads, arms,
## gloves: HitAreas.contact_gap, eased apart in body_contact.gd when they overlap). It used to be 0.72 (capsule 0.36), which kept the
## torsos ~50 cm apart while the contact rules still fired, and hits registered from a mile away.
const BODY_SPACING := 0.24

const DOWNED_CLEARANCE := 0.5   ## metres from the lying body (hip-head-feet segments) a standing fighter keeps


## Ground-plane points of the lying body: hip, head, both feet (bone positions, world space).
func body_points() -> Array:
	var sk: Skeleton3D = rig.skeleton
	var pts: Array = []
	if sk == null:
		return pts
	if _ragdoll != null and _ragdoll.active:   # ragdoll: the bodies are the truth
		for id in ["pelvis", "head", "lFoot", "rFoot"]:
			var q: Vector3 = _ragdoll.bone_origin(id)
			pts.append(Vector3(q.x, 0.0, q.z))
		return pts
	for b in ["hip", "head", "lFoot", "rFoot"]:
		var i := sk.find_bone(b)
		if i >= 0:
			var p: Vector3 = sk.global_transform * sk.get_bone_global_pose(i).origin
			pts.append(Vector3(p.x, 0.0, p.z))
	return pts


## Keeps a standing fighter out of a foe who is lying on the canvas (the capsule alone cannot, it is switched off).
func _separate_from_downed(dt: float) -> void:
	if foe == null or not (foe.state in [State.FALL, State.COUNT, State.GETUP, State.DOWN]):
		return
	var pts: Array = foe.body_points()
	if pts.size() < 3:
		return
	var me := Vector3(global_position.x, 0.0, global_position.z)
	var best := Vector3.ZERO
	var best_d := 1e9
	for i in range(1, pts.size()):
		var a: Vector3 = pts[0]
		var b: Vector3 = pts[i]
		var ab := b - a
		var tt := clampf((me - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		var q := a + ab * tt
		var d := me.distance_to(q)
		if d < best_d:
			best_d = d
			best = q
	if best_d >= DOWNED_CLEARANCE:
		return
	var away := me - best
	if away.length() < 0.01:
		away = -dir_to_foe()
	var push := away.normalized() * minf(DOWNED_CLEARANCE - best_d, 3.0 * dt)
	move_and_collide(push)


func apply_impulse(dir: Vector3, dist: float) -> void:
	dir.y = 0
	_impulse += dir.normalized() * minf(dist * 18.0, 0.9)
	_impulse = _impulse.limit_length(0.9)


# ---------------------------------------------------------------- hit areas / detection
func _update_hitboxes(dt: float) -> void:
	for hb in rig.hitboxes:
		hb.track(dt)


func _window_open() -> bool:
	if atk.is_empty() or atk["hit_done"] or state != State.ATTACK:
		return false
	var s: Dictionary = atk["s"]
	var k: float = atk["k"]
	return atk["t"] >= s["w0"] * k and atk["t"] <= s["w1"] * k


const EARLY_CONTACT := 0.6   ## a glove that touches the foe's gloves / face this early (fraction of the strike window start) already counts: at close range
                             ## the fist is there before the nominal window opens, and the tight volumes no longer overlap constantly

## Contact-only hit resolution. The glove spheres of the striking limb are swept (last frame -> now) against the foe's hurt and guard
## hulls (HitAreas.sweep): no intersection, no hit. A touch shallower than HitAreas.GLANCE_DEPTH is held back while the glove is
## still advancing (it may go deeper) and lands as a glancing blow if it never does.
func _resolve_attack_hits() -> void:
	if foe == null or atk.is_empty() or atk["hit_done"] or state != State.ATTACK:
		return
	var s: Dictionary = atk["s"]
	var k: float = atk["k"]
	if atk["t"] < s["w0"] * k * EARLY_CONTACT or atk["t"] > s["w1"] * k:
		_land_pending_graze()
		atk["why"] = "window_closed"   # diagnostics (tools/probe_hits.gd): the rule that last decided this frame
		return
	var guard_hit: HitAreas.Hurtbox = null
	var guard_c := {}
	var target: HitAreas.Hurtbox = null
	var target_c := {}
	var hit_hb: HitAreas.Hitbox = null
	for hb in rig.hitbox_for(atk["limb"]):
		for i in hb.shapes.size():
			for hu: HitAreas.Hurtbox in foe.rig.guards:
				if hu.collision_layer == 0:
					continue   # shoulder shell volumes only exist while the shell is up
				var c: Dictionary = hb.contact(hu, i)
				if not c.is_empty() and (guard_hit == null or c["depth"] > guard_c["depth"]):
					guard_hit = hu
					guard_c = c
					hit_hb = hb
			for hu: HitAreas.Hurtbox in foe.rig.hurtboxes:
				if hu.zone != s["zone"]:
					if hu.zone == "leg" or s["is_leg"]:
						continue
					var oc: Dictionary = hb.contact(hu, i)   # head punch that only reaches the chest of a slipping foe (or the reverse): a touch is a touch
					if not oc.is_empty():
						var ob: Dictionary = atk.get("other", {})
						if ob.is_empty() or float(oc["depth"]) > float(ob["c"]["depth"]):
							atk["other"] = {"hb": hb, "ref": hu, "c": oc, "zone": hu.zone}
					continue
				var c: Dictionary = hb.contact(hu, i)
				if not c.is_empty() and (target == null or c["depth"] > target_c["depth"]):
					target = hu
					target_c = c
					hit_hb = hb
	if target == null and guard_hit == null:
		_land_pending_graze()   # the glove left the foe again: whatever grazed him before is all there was
		atk["why"] = "no_volume_touched"
		_land_soft_if_due()
		return
	var body_cover: bool = target != null and String(s["zone"]) == "body" and foe.guard_on and foe.guard_body   # elbows / forearms sit in front of the ribs
	var neck_cover: bool = target != null and target.limb == "neckLower" and foe.guard_on and not foe.guard_body   # chin tucked: gloves and forearms shield the throat
	var blocked: bool = (guard_hit != null or body_cover or neck_cover) and foe.blocks_zone(s["zone"])
	if not blocked and target == null:
		atk["why"] = "guard_touched_not_blocking"   # touched a glove / forearm of a foe who is not blocking this zone, and nothing in the strike's zone
		var gt: Dictionary = atk.get("gtouch", {})
		if gt.is_empty() or float(guard_c["depth"]) > float(gt["c"]["depth"]):
			atk["gtouch"] = {"hb": hit_hb, "ref": guard_hit, "c": guard_c}
		if not atk.get("gknock", false) and foe._guard_knock_ok():
			atk["gknock"] = true
			foe.guard_knock.knock(foe.dir_from(self), s, 0.35)   # the glove is shoved aside / back as the punch goes through it: a glove never ignores a glove
		_land_soft_if_due()
		return
	var ref: HitAreas.Hurtbox = guard_hit if (blocked and guard_hit != null) else target
	var cinfo: Dictionary = guard_c if (blocked and guard_hit != null) else target_c
	if not blocked and float(cinfo["depth"]) < HitAreas.GLANCE_DEPTH:
		var gp: Dictionary = atk.get("graze", {})
		if gp.is_empty() or float(cinfo["depth"]) >= float(gp["c"]["depth"]):
			atk["graze"] = {"hb": hit_hb, "target": target, "c": cinfo}   # still touching: wait to see whether it goes deeper
			atk["why"] = "graze_pending"
			if atk["t"] + 1.0 / Engine.physics_ticks_per_second >= s["w1"] * k:
				_land_pending_graze()   # last frame of the window: the glance is all there will be
			return
		_land_pending_graze()   # backing off the surface: it was a glance
		return
	atk.erase("graze")
	_land_hit(hit_hb, ref, blocked, cinfo, false)


## Contacts that never became a hit, landed on the last frame of the strike window so a punch that is still on its way to the head / body is
## not cut short: the glove touched the foe's glove / forearm while he was not blocking (a soft block: the glove stopped it), or only a part of
## the foe outside the strike's zone (a head punch that reached the chest of a slipping foe: a glance on that zone). Nothing visible is a whiff.
func _land_soft_if_due() -> void:
	if atk["hit_done"] or not (atk.has("gtouch") or atk.has("other")):
		return
	var s: Dictionary = atk["s"]
	if atk["t"] + 1.0 / Engine.physics_ticks_per_second < float(s["w1"]) * float(atk["k"]):
		return
	var g: Dictionary = atk.get("gtouch", {})
	var o: Dictionary = atk.get("other", {})
	atk.erase("gtouch")
	atk.erase("other")
	if foe == null or foe.is_acute_down() or foe.is_out():
		return
	if foe.state in [State.SLIP, State.CROUCH] and foe.dm.evading():
		# he got his head out of the way: the glove still touched him (a shoulder, a glove), so it is felt, but the punch stays a MISS: no damage, the
		# miss penalty and the defender's counter window (_report_whiff) are the defence rules and are not ours to change
		var c: Dictionary = (o if (not o.is_empty() and (g.is_empty() or float(o["c"]["depth"]) >= float(g["c"]["depth"]))) else g)
		atk["evaded_touch"] = true
		atk["why"] = "touch_evaded"
		foe._react(self, s, {"quality": 0.3, "damage": 0.0, "position": c["c"]["centre"]}, "glance")
		return
	if not o.is_empty() and (g.is_empty() or float(o["c"]["depth"]) >= float(g["c"]["depth"])):
		_land_hit(o["hb"], o["ref"], false, o["c"], true, String(o["zone"]))
	elif not g.is_empty():
		_land_hit(g["hb"], g["ref"], true, g["c"], false, "", true)


## A glancing touch that never got deeper: it lands as a glance now (window over, glove retracting or sliding off).
func _land_pending_graze() -> void:
	if not atk.has("graze") or atk["hit_done"]:
		return
	var g: Dictionary = atk["graze"]
	atk.erase("graze")
	if is_instance_valid(g["target"]) and g["target"].fighter == foe and not foe.is_acute_down():
		_land_hit(g["hb"], g["target"], false, g["c"], true)


## `ref` = the hull that was hit (target, or the glove / forearm that blocked), `cinfo` = HitAreas.sweep result.
func _land_hit(hb: HitAreas.Hitbox, ref: HitAreas.Hurtbox, blocked: bool, cinfo: Dictionary, glance: bool, zone_override := "", passive := false) -> void:
	var s: Dictionary = atk["s"]
	var hit_atk: Dictionary = atk
	if zone_override != "" and zone_override != String(s["zone"]):
		hit_atk = atk.duplicate()   # the blow lands on the zone it actually touched (take_hit reads the strike row's zone)
		s = s.duplicate()
		s["zone"] = zone_override
		hit_atk["s"] = s
	var pos: Vector3 = cinfo["centre"]
	var vel: Vector3 = hb.velocity
	var ratio := ref.contact_ratio(pos, float(hb.shapes[0]["r"]), vel)
	var gres := {}
	if blocked:   # guard coverage model: parry / full block / partial leak / pierce (scripts/combat/guard_model.gd)
		gres = foe.passive_assess(s, ratio) if passive else foe.guard_assess(s, ratio)
		if gres["kind"] == "pierce":
			blocked = false
	# quality = how centred the blow is (the hulls are ~30 % smaller than the old ones, so the same centring error is a bigger ratio: 0.7 instead
	# of 1.1 keeps the old damage / rock numbers) and how squarely it travelled into the surface (speed along the normal)
	var cosn := 1.0
	if vel.length() > 0.5:
		cosn = clampf(-vel.normalized().dot(cinfo["normal"]), 0.0, 1.0)
	var quality := clampf(1.15 - 0.7 * ratio, 0.0, 1.0) * lerpf(0.85, 1.0, cosn) * (1.0 - float(atk.get("q_pen", 0.0)))   # a punch that took a hit in flight lands less cleanly
	var ev := {
		"blocked": blocked,
		"quality": quality,
		"speed": vel.length(),
		"position": pos,
		"point": cinfo["point"],   # on the foe's skin (debug view, FX)
		"depth": cinfo["depth"],
		"normal_speed": maxf(-vel.dot(cinfo["normal"]), 0.0),
		"glance": glance and not blocked,
		"velocity": vel,   # ragdoll: the fist's travel direction
		"limb": atk["limb"],
		"hurt_side": ref.side,
		"guard": gres,
		"passive": passive,   # glove on a glove of a foe who was not holding block: a soft block
	}
	if ev["glance"]:
		ev["quality"] = minf(float(ev["quality"]), 0.12)
	if gres.get("kind", "") == "pierce":
		ev["quality"] = minf(float(ev["quality"]), 0.65)   # a pierced shot clips the head: it never floors anybody
	if not blocked and gres.is_empty() and not ev["glance"] and _try_clash(pos):
		return
	if debug_boxes:
		_debug_flash(cinfo["point"], Color(1, 0.9, 0.1) if ev["glance"] else (Color(0.2, 1, 0.3) if blocked else Color(1, 0.1, 0.1)))
	if not ev["glance"]:
		_assess_trade(blocked, ev["quality"])
	atk["hit_done"] = true
	atk["blocked"] = blocked
	atk["outcome"] = "blocked" if blocked else "hit"
	atk["why"] = "glance" if ev["glance"] else (("block_" + String(gres.get("kind", "guard"))) if blocked else ("pierce" if gres.get("kind", "") == "pierce" else "clean_hit"))
	atk["land_t"] = _time
	_lunge_left = 0.0   # the glove met the man: the entry step ends there (it used to carry the hitter on into him)
	if not ev["glance"]:
		_catch_up_after_contact()
	var res := foe.take_hit(self, hit_atk, ev)
	if not res.is_empty():   # visual hit-stop of the striking glove (impact_hold.gd): the harder the blow, the longer it stays on the skin
		var hit_dmg := float(res.get("damage", 0.0))
		atk["hold_len"] = clampf(0.035 + 0.04 * clampf(hit_dmg / 9.0, 0.0, 1.0), 0.035, 0.075) * (0.7 if blocked else (0.6 if glance else 1.0))
	if blocked:
		CommitmentScript.note_outcome(atk, "blocked")
		atk["tail"] = maxf(CombatRules.outcome_tail(s, "blocked"), float(atk.get("pen", 0.0)))   # a blocked punch recovers slower than a clean one
		if s["heavy"] and not s["is_leg"]:
			atk["tail"] += 0.12   # a loaded shot into the gloves leaves the hitter open a beat: a block can be punished
		if gres.get("kind", "") == "parry":
			atk["outcome"] = "parried"
			atk["parried"] = true
			atk["tail"] += GuardModelScript.PARRY_PUNISH
	if not res.is_empty():
		hit_landed.emit(self, res)


## "none" | "startup" | "committed" | "contact" | "recovery" (see scripts/combat/exchange.gd).
func punch_phase() -> String:
	if state != State.ATTACK:
		return "none"
	return ExchangeScript.phase(atk)


## Two straight head punches arriving together meet glove to glove: both deflect, nobody is hurt. Returns true when this
## fighter's punch clashed (both attacks are finished as "blocked", both recoil a little).
func _try_clash(pos: Vector3) -> bool:
	if foe == null or foe.state != State.ATTACK or foe.atk.is_empty():
		return false
	if gap_to_foe() > 1.9 or not ExchangeScript.clashes(atk, foe.atk):
		return false
	for f in [self, foe]:
		f.atk["hit_done"] = true
		f.atk["blocked"] = true
		f.atk["outcome"] = "blocked"
		f.atk["clash"] = true
		f.atk["why"] = "clash"
		f.atk["land_t"] = f._time
		f.apply_impulse(-f.dir_to_foe(), 0.03)
		f._stagger = maxf(f._stagger, 0.05)
		if f._hit_flinch != null:   # two gloves meet: both fighters feel it (the head nods, the weight shifts, the punching hand is batted off line)
			f._hit_flinch.impact(f.dir_to_foe(), "F", "head", "block", 0.35)
		if f.guard_knock != null:
			f.guard_knock.swat(String(f.atk["limb"]), (f.global_basis.x * (1.0 if String(f.atk["limb"]).begins_with("r") else -1.0) - f.dir_to_foe() * 0.3).normalized(), 0.07)
	clashed.emit(foe, pos)
	return true


## Both fists are about to land within TRADE_WINDOW: decide the exchange once, stash the verdict on both punches.
func _assess_trade(blocked: bool, quality: float) -> void:
	if atk.has("trade") and _time - float(atk["trade"]["t"]) > 0.35:
		atk.erase("trade")
	if blocked or atk.has("trade") or foe == null or foe.state != State.ATTACK or foe.atk.is_empty() or foe.atk["hit_done"]:
		return
	var ph := foe.punch_phase()
	if ph != "committed" and ph != "contact":
		return
	var ttc := ExchangeScript.time_to_contact(foe.atk)
	if ttc > ExchangeScript.TRADE_WINDOW:
		return
	var me := ExchangeScript.side_of(self, 0.0, quality)
	var them := ExchangeScript.side_of(foe, ttc, 0.75)
	var won := ExchangeScript.margin(me, them) >= 0.0
	atk["trade"] = {"won": won, "t": _time}
	foe.atk["trade"] = {"won": not won, "t": _time}


## Guard coverage verdict for a punch that touched the gloves (see GuardModelScript): {kind: parry|full|partial|pierce, ...}.
func guard_assess(s: Dictionary, graze: float) -> Dictionary:
	var fat := stats.fatigue()
	var stam := 999.0 if stats.infinite_stamina else stats.stamina
	if not guard_body and not dm.shell_on and not hurt.dazed() \
			and GuardModelScript.is_parry(s, guard_age, fat, _press_ok, stam):
		last_assess = {"kind": "parry", "leak": 0.0, "frac": 0.0, "lane": GuardModelScript.lane_of(s), "age": guard_age}
		return last_assess
	var res := GuardModelScript.assess(s, {"style": GuardModelScript.style_of(self), "age": guard_age,
		"guard_ratio": stats.guard / maxf(stats.guard_max, 1.0), "fatigue": fat, "graze": graze,
		"open": guard_open_t, "body_guard": guard_body})
	res["age"] = guard_age
	last_assess = res
	return res


## A punch that only found the gloves of a fighter who was not holding block: the gloves in his stance still stop it, but he is not set (no parry,
## no pierce through the gloves: a leak at most).
func passive_assess(s: Dictionary, graze: float) -> Dictionary:
	var res := GuardModelScript.assess(s, {"style": GuardModelScript.style_of(self), "age": 9.0, "guard_ratio": stats.guard / maxf(stats.guard_max, 1.0),
		"fatigue": stats.fatigue(), "graze": graze, "open": 0.0, "body_guard": false})
	if res["kind"] == "pierce":
		res["kind"] = "partial"
		res["frac"] = 0.6
	res["age"] = 0.0
	last_assess = res
	return res


func blocks_zone(zone: String) -> bool:
	if not guard_on:
		return false
	if zone == "head":
		return not guard_body
	return guard_body


## The head is low or leaning in: a body shot in flight, a duck, a lean (lean_vec from the lean pass, if present) or the
## overextension of a whiff. An uppercut that lands on it is a punish (CommitmentScript.PUNISH_MULT).
func head_low_or_forward() -> bool:
	if state == State.CROUCH:
		return true
	if state == State.ATTACK and not atk.is_empty():
		if String(atk["s"]["zone"]) == "body" or CommitmentScript.is_open(atk):
			return true
	return lean_pose != null and lean_pose.pos.y > 0.25   # leaning in (fighter frame: +y forward)


func _earned_counter() -> bool:
	if state == State.ATTACK and not atk.is_empty():
		if atk["outcome"] == "missed" or atk["outcome"] == "parried":   # whiffed / parried and recovering
			return true
		if atk["outcome"] == "blocked" and atk["s"]["heavy"] and ExchangeScript.phase(atk) == "recovery":   # loaded shot blocked: open for a beat
			return true
		if ExchangeScript.phase(atk) == "startup":   # beaten to the punch: the hand had not left the guard yet
			return true
	return false


## Called by the attacker's hit resolution. Returns the hit info dictionary (for the Match signal).
func take_hit(att: Fighter, a: Dictionary, ev: Dictionary) -> Dictionary:
	if is_acute_down() or is_out():
		return {}
	var s: Dictionary = a["s"]
	var blocked: bool = ev["blocked"]
	var zone: String = s["zone"]
	var gres: Dictionary = ev.get("guard", {})
	var gkind: String = gres.get("kind", "")
	if gkind == "parry":
		return _apply_parry(att, a, s, ev)
	var open := state == State.ATTACK and CommitmentScript.is_open(atk) and not blocked   # whiffed and still recovering: cannot defend
	var punish := not blocked and zone == "head" and String(s["dir"]) == "U" and head_low_or_forward()   # uppercut into a low / forward head
	var counter: bool = a["counter"] or _earned_counter() or punish
	var tr: Dictionary = a.get("trade", {}) if not blocked else {}
	var pmult: float = a.get("power_mult", 1.0)
	if gkind == "pierce":
		pmult *= float(gres["frac"])   # went around / through the guard: 70-90 % of the damage
	var glance: bool = ev.get("glance", false) and not blocked
	if glance:
		pmult *= GLANCE_POWER   # a glove that only brushed him
	ev["speed"] = float(ev["speed"]) * lerpf(1.0, pmult, 0.5)   # a punch hit in flight has less behind it
	var ctx := {
		"power_mult": pmult,
		"trade_mult": 1.0 if tr.is_empty() else (ExchangeScript.WIN_MULT if tr["won"] else ExchangeScript.LOSE_MULT),
		"blocked": blocked,
		"attacker_rocked": att.stats.rocked,
		"quality": ev["quality"],
		"counter": counter and not blocked,
		"open": open,
		"punish": punish,
		"def_stamina_ratio": stats.stamina_ratio(),
		"attacker_fatigue": att.stats.fatigue(),
		"closing": att._closing_speed,
		"def_walk_into": clampf(_closing_speed_of_defender(att), -3.0, 3.0),
		"def_side_speed_dps": _side_dps * (1.0 if s["dir"] == "L" else -1.0),
		"def_action": state in [State.ATTACK, State.SLIP, State.CROUCH, State.TAUNT],
		"def_taunting": state == State.TAUNT,
		"def_rocked": stats.rocked,
		"def_guarding": guard_on,
		"def_body_strike": state == State.ATTACK and not atk.is_empty() and String(atk["s"]["zone"]) == "body",
		"smother": bc.smother_for(s),   # body contact: long punches are smothered in close
	}
	_last_hit = {"ev": ev, "strike": s, "t": _time, "att": att}   # ragdoll: the blow behind a knockdown / KO
	var dmg := CombatRules.compute_damage(s, ctx)
	dm.adjust_damage(s, dmg)   # shell leaves the body more open
	var total: float = dmg["total"]
	var info := {
		"zone": zone, "blocked": blocked, "damage": total, "strength": CombatRules.strength_of(s, total),
		"position": ev["position"], "counter": counter and not blocked, "open": open, "punish": punish, "strike": s["tag"],
		"quality": ev["quality"], "speed": ev["speed"], "knockdown": false, "rocked": false, "ko": false, "guard_break": false,
		"trade": not tr.is_empty(), "trade_won": not tr.is_empty() and bool(tr["won"]),
	}
	if ev.get("passive", false):
		info["passive"] = true
	if gkind != "":
		guard_log[gkind] = int(guard_log[gkind]) + 1
	if gkind == "pierce":
		info["pierce"] = true
		info["rock_mult"] = GuardModelScript.PIERCE_ROCK
		stats.guard = maxf(stats.guard - CombatRules.guard_loss(s) * 0.5, 0.0)   # the glove still took some of it
		if _guard_knock_ok():
			guard_knock.knock(dir_from(att), s, 0.5)
	elif gkind == "partial":
		info["partial"] = true
		var open_ctx := ctx.duplicate()
		open_ctx["blocked"] = false
		var open_dmg := CombatRules.compute_damage(s, open_ctx)
		info["leak"] = float(open_dmg["total"]) * float(gres["frac"])
	_cut_committed_punch(total, blocked)
	if not blocked and state == State.ATTACK and (counter or not tr.is_empty() and not tr["won"]) and total >= 8.0 and punch_phase() in ["committed", "contact"] and not atk.is_empty():
		atk["q_pen"] = clampf(float(atk.get("q_pen", 0.0)) + 0.15, 0.0, 0.6)   # a heavy counter knocks the punch off line
	var dir_prefix := _reaction_dir(att, s)
	stats.regen_lock = 1.0
	if glance:
		_apply_glance(att, s, total, info)
	elif blocked:
		_apply_block(att, s, total, info)
	else:
		_apply_unblocked(att, s, a, ev, dmg, info, dir_prefix, counter)
	stats_changed.emit()
	att.stats_changed.emit()
	return info


## Hit while the hand is travelling: the punch continues, but with less behind it (and a worse line) the harder the hit.
## The winner of a trade is not cut (its flinch is cosmetic).
func _cut_committed_punch(total: float, blocked: bool) -> void:
	if blocked or state != State.ATTACK or atk.is_empty():
		return
	var ph := punch_phase()
	if ph != "committed" and ph != "contact":
		return
	var vt: Dictionary = atk.get("trade", {})
	if not vt.is_empty() and vt["won"]:
		return
	var cut := ExchangeScript.power_cut(total, atk["s"])
	atk["power_mult"] = float(atk.get("power_mult", 1.0)) * (1.0 - cut)
	atk["q_pen"] = clampf(float(atk.get("q_pen", 0.0)) + cut * ExchangeScript.CUT_QUALITY, 0.0, 0.5)


func _closing_speed_of_defender(att: Fighter) -> float:
	## defender walking INTO the attacker is positive
	var to_att := (att.global_position - global_position)
	to_att.y = 0
	if to_att.length() < 0.01:
		return 0.0
	return Vector3(velocity.x, 0, velocity.z).dot(to_att.normalized())


func _reaction_dir(att: Fighter, s: Dictionary) -> String:
	var d: String = s["dir"]
	return d


func _apply_block(att: Fighter, s: Dictionary, total: float, info: Dictionary) -> void:
	var passive: bool = info.get("passive", false)   # gloves in the stance stopped it: no guard meter / stamina cost, never a guard break
	if passive:
		stats.guard = maxf(stats.guard - CombatRules.guard_loss(s) * 0.25, 1.0)
	else:
		stats.guard -= CombatRules.guard_loss(s) * hurt.block_weakness() * dm.guard_loss_mult(s)   # dazed block is weak (rocked rework); shell soaks head shots cheaper (defence)
		stats.guard_regen_lock = 1.1
		stats.spend_stamina(FatigueScript.block_cost(s), 0.8)   # fatigue pass: soaking punches is tiring
	var chip := total * 0.12 * (HurtStateScript.DAZE_CHIP_MULT if hurt.dazed() else 1.0)
	var partial: bool = info.get("partial", false)
	if partial:
		chip = maxf(chip, float(info["leak"]))   # part of the punch got through the gloves
	if s["zone"] == "head":
		stats.head = maxf(stats.head - chip, 1.0)
	elif s["zone"] == "body":
		stats.body = maxf(stats.body - chip, 1.0)
	else:
		if info.get("hurt_side", "L") == "L":
			stats.lleg = maxf(stats.lleg - chip, 1.0)
		else:
			stats.rleg = maxf(stats.rleg - chip, 1.0)
	info["damage"] = chip
	var d := dir_from(att)
	apply_impulse(-d, 0.012 if not s["heavy"] else 0.025)
	_react(att, s, info, "block")   # the block still jolts the head and the weight (a straight: a nod, a hook: the head turns), partial leaks more
	if _guard_knock_ok():
		guard_knock.knock(dir_from(att), s, clampf(maxf(total / 10.0, 0.5), 0.0, 1.0))   # the struck glove and forearm are driven back toward the face and aside (at least 7 cm)
		if s.get("power", false):
			guard_open_t = GuardModelScript.STAGGER   # only a loaded power shot knocks the guard open
	if stats.guard <= 0.0:
		stats.guard = 0.0
		stats.guard_lock = 1.0
		info["guard_break"] = true
		var clip := "%s head punch Break" % (s["dir"] if s["dir"] in ["F", "L", "R"] else "F")
		if s["zone"] != "head":
			clip = CombatRules.hit_clip(s["dir"], "body_break")
		_start_reaction(clip, anim.clip_length(clip), s)
		att.atk["outcome"] = "hit"



const GLANCE_POWER := 0.12   ## damage multiplier of a glancing blow (a touch shallower than HitAreas.GLANCE_DEPTH)


## A glancing blow: a sliver of damage, no rock / knockdown / stun, just a small flinch.
func _apply_glance(att: Fighter, s: Dictionary, total: float, info: Dictionary) -> void:
	match String(s["zone"]):
		"head":
			stats.head = maxf(stats.head - total, 1.0)
		"body":
			stats.body = maxf(stats.body - total, 1.0)
		_:
			if info.get("hurt_side", "L") == "L":
				stats.lleg = maxf(stats.lleg - total, 1.0)
			else:
				stats.rleg = maxf(stats.rleg - total, 1.0)
	info["glance"] = true
	info["damage"] = total
	apply_impulse(-dir_from(att), 0.006)
	_react(att, s, info, "glance")


func _guard_knock_ok() -> bool:
	return guard_knock != null and state in [State.IDLE, State.SLIP, State.CROUCH]


## Time-pressed block just before a straight / hook arrives: the glove bats it off line. No guard-meter loss, no damage; the
## attacker's arm is knocked aside and his recovery is longer (_resolve_attack_hits adds PARRY_PUNISH), the parrier gets a
## counter window. Costs stamina; the press cooldown keeps mashing from working.
func _apply_parry(att: Fighter, a: Dictionary, s: Dictionary, ev: Dictionary) -> Dictionary:
	guard_log["parry"] = int(guard_log["parry"]) + 1
	stats.spend_stamina(GuardModelScript.PARRY_COST, 0.5)
	_press_ok = false
	counter_window = maxf(counter_window, 0.6)
	var toward := dir_from(att)
	var limb := String(s["limb"])
	if guard_knock != null:
		guard_knock.parry("r" if limb == "L" else "l", toward)
	if att.guard_knock != null:
		var side_w := global_basis.x * (1.0 if limb == "R" else -1.0)   # batted toward the defender's outside
		att.guard_knock.swat(String(a["limb"]), (side_w - toward * 0.2).normalized(), 0.16)
	att.buffer.clear()   # a parried punch breaks the combo
	att._stagger = maxf(att._stagger, 0.12)
	att.apply_impulse(-att.dir_to_foe(), 0.02)
	return {
		"zone": String(s["zone"]), "blocked": true, "parry": true, "damage": 0.0, "strength": "light",
		"position": ev["position"], "counter": false, "strike": s["tag"], "quality": ev["quality"], "speed": ev["speed"],
		"knockdown": false, "rocked": false, "ko": false, "guard_break": false, "trade": false, "trade_won": false,
	}


func dir_from(att: Fighter) -> Vector3:
	var d := att.global_position - global_position
	d.y = 0
	return d.normalized() if d.length() > 0.001 else global_basis.z


func _apply_unblocked(att: Fighter, s: Dictionary, a: Dictionary, ev: Dictionary, dmg: Dictionary, info: Dictionary, dir_prefix: String, counter: bool) -> void:
	var total: float = dmg["total"]
	var zone: String = s["zone"]
	var reaction := ""
	var kick: bool = s["is_leg"]
	var was_rocked := stats.rocked
	# stamina penalty for body/leg hits
	if zone != "head":
		stats.stamina_lock = maxf(stats.stamina_lock, 1.0)
	if zone != "head":   # body / leg shots take the wind out of you; head shots hurt, they do not drain the tank
		stats.spend_stamina(FatigueScript.hit_cost(total, zone), 0.8)
	match zone:
		"head":
			stats.apply_head(total, dmg["bonus"], dmg["num"])
			var won_trade: bool = info.get("trade_won", false)
			stats.rock_meter = minf(stats.rock_meter + CombatRules.rock_gain(total, s, counter) * (ExchangeScript.WIN_ROCK if won_trade else 1.0) * float(info.get("rock_mult", 1.0)) * (CommitmentScript.PUNISH_ROCK / 1.5 if info.get("punish", false) else (CommitmentScript.OPEN_ROCK / 1.5 if info.get("open", false) else 1.0)), 100.0)   # fatigue pass; the winner of a trade rocks more
			var power: bool = s["heavy"] or counter or s.get("power", false)
			var head_ratio := stats.head / 100.0
			var knock := false
			if not practice:
				var exposed := state == State.ATTACK or stats.stamina_ratio() <= 0.30 or _balance() <= 0.35 or was_rocked or counter   # a rocked fighter, or one caught by a counter, is exposed: with paced CPUs nearly every bout went the distance without a knockdown
				knock = CombatRules.assess_knockdown({
					"power": power, "kick": kick, "speed": ev["speed"], "quality": ev["quality"],
					"launch_stamina_ratio": att.stats.stamina_ratio(), "head_ratio": head_ratio, "exposed": exposed, "rocked": was_rocked, "grace": stats.kd_grace > 0.0})
				if stats.head <= 0.5:
					knock = true
				if not knock and power and stats.knockdowns > 0 and head_ratio < CombatRules.FLASH_KO_RATIO and ev["quality"] >= CombatRules.KD_MIN_QUALITY and ev["speed"] >= 2.2 \
						and att.stats.stamina_ratio() >= 0.55 and att.rng.randf() < CombatRules.flash_ko_chance(head_ratio, stats.stamina_ratio(), _balance()):
					_do_ko("KO", dir_prefix, "head")
					info["ko"] = true
					return
				if not knock and was_rocked and stats.knockdowns > 0 and head_ratio < CombatRules.FLASH_KO_RATIO + 0.08 and power and ev["quality"] >= CombatRules.KD_MIN_QUALITY:
					_do_ko("KO", dir_prefix, "head")
					info["ko"] = true
					return
			if knock:
				stats.head = maxf(stats.head, 1.0)
				if stats.should_tko():   # fatigue pass: 3 in a round or 4 in the bout (was 3 in the bout)
					stats.head = 0.0
					stats.head_max = 0.0
					_do_ko("TKO", dir_prefix, "head")
					info["ko"] = true
					return
				_do_knockdown(dir_prefix)
				info["knockdown"] = true
				return
			# rocked?
			if not practice and not was_rocked and stats.rock_grace <= 0.0 and CombatRules.should_rock(total, stats.rock_meter, stats.head, stats.head_max, counter):
				var sev := CombatRules.rock_severity(total, stats.rock_meter, stats.head, stats.head_max)
				_react(att, s, info, "head")   # the snap of the head rides on top of the rocked pose fading in
				_begin_head_hurt(att, s, sev, dir_prefix)   # rocked rework (daze, see HurtState)
				info["rocked"] = true
				return
			elif was_rocked and total >= 18.0:
				hurt.extend(0.4)
				stats.stun_left = minf(stats.stun_left + 0.4, 6.0 if not hurt.active() else hurt.remaining())
			if stats.head_max <= 0.0 and not practice:
				_do_ko("KO", dir_prefix, "head")
				info["ko"] = true
				return
			var kind := "kick" if kick else "punch"
			if s.get("power", false):
				kind = "break"
			var clip := CombatRules.hit_clip(dir_prefix, kind)
			_hit_reaction(att, clip, CombatRules.reaction_cap(s) if kind != "break" else anim.clip_length(clip), s, info, total)
		"body":
			stats.apply_body(total, dmg["bonus"])
			var body_ratio := stats.body_max / 100.0
			if not practice and stats.body_max <= 0.0:
				_do_ko("KO", dir_prefix, "body")
				info["ko"] = true
				return
			var clip := ""
			if kick or state == State.ATTACK:
				clip = CombatRules.hit_clip(dir_prefix, "body_kick")
				if body_ratio < 0.25:
					clip = CombatRules.hit_clip(dir_prefix, "body_pko")
				elif kick and stats.body_max < 50.0:
					clip = CombatRules.hit_clip(dir_prefix, "body_break")
			else:
				clip = "KB_Hit_m_MidFront_Weak" if dir_prefix == "F" else ("KB_Hit_p_MidLeft_Weak" if dir_prefix == "L" else "KB_Hit_p_MidRight_Weak")
				if dir_prefix == "U":
					clip = "KB_Hit_m_MidFront_Weak"
			_hit_reaction(att, clip, minf(CombatRules.reaction_cap(s) * (1.0 if not kick else 1.0), anim.clip_length(clip)), s, info, total)
			_try_begin_body_hurt(att, s, total, counter)   # rocked rework
		"leg":
			var left: bool = ev["hurt_side"] == "L"
			stats.apply_leg(left, total)
			if not practice and (stats.lleg_max <= 0.0 or stats.rleg_max <= 0.0):
				_do_ko("KO", dir_prefix, "leg")
				info["ko"] = true
				return
			var lm := stats.lleg_max if left else stats.rleg_max
			var clip := "%s leg kick" % ("L" if left else "R")
			if lm < 25.0:
				clip = "%s leg kick S" % ("L" if left else "R")
			elif lm < 50.0:
				clip = "%s leg kick C" % ("L" if left else "R")
			_hit_reaction(att, clip, CombatRules.reaction_cap(s), s, info, total)
	var imp := 0.045 if kick else (0.045 if s["heavy"] else 0.024)   # clean shots move the man a few cm off the glove (was 1.6 / 3.2 cm)
	apply_impulse(-dir_from(att), imp)


## Reaction to a clean, non-finishing hit (knockdown / KO / rock / guard break never get here). Either the full-body hit
## clip (interrupts whatever the fighter was doing) or an additive flinch that lets the action go on:
##  * hand still in the guard (startup): beaten to the punch, the punch is cut off (clip)
##  * hand released (committed / contact): the punch continues; flinch only (a heavy body shot that folds you still cuts it)
##  * otherwise (standing, recovering): light and medium shots flinch, heavy ones and body folds play the clip
func _hit_reaction(att: Fighter, clip: String, length: float, s: Dictionary, info: Dictionary, total: float) -> void:
	if _soft_reaction(s, info):
		var st := ExchangeScript.flinch_strength(total)
		if info.get("counter", false):
			st *= 1.25   # caught: the head snaps further
		if info.get("trade", false) and not info.get("trade_won", false):
			st *= 1.2   # lost the exchange
		_react(att, s, info, "head" if s["zone"] == "head" else "body")
		if info["strength"] != "light":   # medium+ hits: a small step back off the glove
			apply_impulse(-dir_from(att), CommitmentScript.STAGGER_STEP_HEAVY if info["strength"] == "heavy" else CommitmentScript.STAGGER_STEP_MEDIUM)
		_follow_v = 0.0
		_lunge_left = 0.0   # the entry step ends when you are hit (the cut-off clip used to do this): two lunging fighters must not walk through each other
		if state != State.ATTACK:
			_stagger = maxf(_stagger, ExchangeScript.STAGGER_MEDIUM if info["strength"] == "medium" else ExchangeScript.STAGGER_LIGHT)
		return
	_start_reaction(clip, length, s)
	_react(att, s, info, "head" if s["zone"] == "head" else "body")   # the clip is the stumble; the snap of the head / spine rides on top of it


func _soft_reaction(s: Dictionary, info: Dictionary) -> bool:
	var strength: String = info["strength"]
	var body: bool = s["zone"] != "head"
	if state == State.ATTACK and not atk.is_empty():
		match punch_phase():
			"startup":
				return false
			"committed", "contact":
				return not (strength == "heavy" and body)
			_:
				return _hit_flinch != null and strength != "heavy" and not (body and strength == "medium")
	if state in [State.SLIP, State.CROUCH] and not _backstepping and _hit_flinch != null and not hurt.active():
		# leaning / ducking: the reaction is layered on the held lean (never a snap back to the base pose, a hit never cancels a slip)
		return true
	if state != State.IDLE or hurt.active() or _hit_flinch == null:   # no flinch layer (or busy / hurt): the classic clip
		return false
	if strength == "light":
		return true
	return strength == "medium" and not body and not s["is_leg"]


## Every landed blow, whatever its outcome, is felt: an impulse into the HitFlinch springs (head / neck / spine / hips) at the contact point, scaled by
## the punch and the outcome (kind: "head" | "body" | "block" | "glance"), added on top of whatever the fighter is doing (a slip, a punch in flight).
func _react(att: Fighter, s: Dictionary, info: Dictionary, kind: String) -> void:
	if _hit_flinch == null:
		return
	var total := float(info.get("damage", 0.0))
	var power: float = HitFlinchScript.impact_power(s, kind, float(info.get("quality", 0.7)), total, bool(info.get("counter", false)),
			bool(info.get("trade", false)) and not bool(info.get("trade_won", false)), bool(info.get("partial", false)))
	power = clampf(power * _lean_flinch_gain(att, s), 0.0, 1.0)
	var off := Vector3.ZERO
	if info.has("position"):
		var c: Vector3 = rig.target_centre(String(s["zone"]))
		if c != Vector3.INF:
			off = global_basis.inverse() * ((info["position"] as Vector3) - c)
	_hit_flinch.impact(dir_from(att), String(s.get("dir", "F")), String(s["zone"]), kind, power, off)
	var lp = lean_pose
	if lp != null and lp.pos.length() > 0.2:
		lp.nudge(local_dir(-dir_from(att)) * (0.10 + 0.18 * power))   # the blow also knocks the held lean


## Additive hit flinch that does not interrupt the current action. strength 0..1. Filled in by the hit_flinch layer.
func flinch(att: Fighter, s: Dictionary, strength: float, zone: String) -> void:
	if _hit_flinch != null:
		strength = clampf(strength * _lean_flinch_gain(att, s), 0.0, 1.0)
		_hit_flinch.kick(dir_from(att), String(s.get("dir", "F")), zone, strength)
		var lp = lean_pose
		if lp != null and lp.pos.length() > 0.2:
			# the hit also knocks the held lean: pushed along the blow (into a lean back, off a slip)
			var push := local_dir(-dir_from(att)) * (0.10 + 0.18 * strength)
			lp.nudge(push)


## Hit while leaning: leaning INTO the blow (slipping into a hook, bobbing into a straight) or leaning back into the end of a straight
## (caught on the tip: the head snaps back further) hurts the head more than a clean hit on a still guard.
func _lean_flinch_gain(att: Fighter, s: Dictionary) -> float:
	var lp = lean_pose
	if lp == null or lp.pos.length() < 0.15 or String(s["zone"]) != "head":
		return 1.0
	var l: Vector2 = lp.pos
	var dir := String(s.get("dir", "F"))
	var into := 0.0
	if dir == "L" or dir == "R":
		var from_left := 1.0 if String(s["limb"]) == "R" else -1.0   # a right hook arrives from the victim's left
		into = maxf(l.x * from_left, 0.0)
	else:
		into = maxf(l.y, 0.0) + 0.55 * maxf(-l.y, 0.0)
	return 1.0 + 0.75 * clampf(into, 0.0, 1.0)


func _balance() -> float:
	if bc.off_balance():   # shoved off the foe (body contact)
		return 0.3
	match state:
		State.ATTACK:
			if not atk.is_empty() and atk["outcome"] in ["missed"]:
				return 0.2
			return 0.35
		State.SLIP:
			return 0.3 if (_backstepping and slip_t > 0.3) else 1.0
		_:
			return 0.5 if velocity.length() > 0.3 else 1.0


func _start_reaction(clip: String, length: float, s: Dictionary) -> void:
	if not anim.player.has_animation(clip):
		clip = "F head punch"
	atk = {}
	hit_clip = clip
	hit_len = maxf(length, 0.1)
	hit_t = 0.0
	slip_dir = 0
	_backstepping = false
	lean_hold = Vector2.ZERO   # a heavy shot breaks the lean: LeanPose springs home while the stumble clip fades in (no pose snap)
	_lunge_left = 0.0
	anim.play_action(clip, 0.0, 0.08)
	_set_state(State.HIT)


# -- knockdown / KO
const COUNT_FIRST := 0.5     ## s from the end of the fall to the referee's "1"
const COUNT_STEP := 0.9      ## s per number
const CORNER_SPEED := 1.4


func _do_knockdown(dir_prefix: String) -> void:
	stats.knockdowns += 1
	knockdown_dir = dir_prefix
	atk = {}
	buffer.clear()
	_clear_hurt()   # rocked rework
	_begin_ragdoll_fall(dir_prefix, "head", false)
	getup_count = _roll_getup_count()
	count_n = 0
	_set_state(State.FALL)
	knocked_down.emit(self)


## Plays a fall clip (retimed) and sets the FALL length to its duration.
func _begin_fall(fall: Dictionary, fade: float) -> void:
	var clip: String = fall["clip"]
	if not anim.player.has_animation(clip):
		clip = "F head KO"
	_fall_len = anim.clip_length(clip) / float(fall["speed"])
	anim.play_action(clip, _fall_len, fade)
	knock_t = 0.0


## Number the referee reaches before the fighter is up: 4..8 by damage, 10 (= out) when the head is gone.
func _roll_getup_count() -> int:
	if stats.head <= 3.0:
		return 10
	var ratio := clampf(stats.head / 50.0, 0.0, 1.0)
	var n := 4 + int(round((1.0 - ratio) * 3.0)) + maxi(stats.knockdowns - 1, 0) + rng.randi_range(0, 1)
	return clampi(n, 4, 8)


func _start_getup() -> void:
	knock_t = 0.0
	# pick the get-up from how the body actually lies (face up -> GetUpBack, face down -> GetUpFace)
	_getup_clip = KnockdownMotion.getup_clip(rig.skeleton) if rig.skeleton != null else KnockdownMotion.GETUP_FACE_UP
	if _ragdoll.active:
		_getup_clip = KnockdownMotion.GETUP_FACE_UP if _ragdoll.lying_face_up() else KnockdownMotion.GETUP_FACE_DOWN   # ragdoll: from the bodies
		_end_ragdoll_into_getup()
	else:
		anim.play_action(_getup_clip, 0.0, 0.2)
	_set_state(State.GETUP)


## The count reached ten: out.
func _lose_by_count() -> void:
	ko_method = "KO"
	_set_state(State.DOWN)
	got_ko.emit(self, "KO")


## Back on his feet but hurt: a brief rocked episode (HurtState decides the look and timing).
## Beating the count is not punished with a daze (owner 2026-10-28): the fighter comes back up clear-headed, with a
## short grace in which a single shot cannot rock him again (the knockdown rules still apply).
func _begin_post_getup_hurt() -> void:
	if practice:
		return
	stats.rock_grace = maxf(stats.rock_grace, POST_GETUP_ROCK_GRACE)
const POST_GETUP_ROCK_GRACE := 3.0


## Standing fighter during a count: walk to the neutral corner, then stand and watch (face_foe takes over).
func _walk_to_corner(dt: float) -> bool:
	if not frozen or corner_target == Vector3.INF or state != State.IDLE:
		return false
	var to := corner_target - global_position
	to.y = 0.0
	var target := Vector3.ZERO
	if to.length() > 0.12:
		target = to.normalized() * minf(CORNER_SPEED, to.length() * 4.0)
	var vh := Vector3(velocity.x, 0, velocity.z).lerp(target, 1.0 - exp(-10.0 * dt))
	velocity.x = vh.x
	velocity.z = vh.z
	return true


## The lying body is about 1.5 m long and the clips are in place: slide the fighter inward when his head or
## feet would end up through the ropes.
func _keep_lying_body_in_ring(dt: float) -> void:
	if _ragdoll.active:
		return   # the ragdoll collides with the ring walls itself
	var fwd := global_basis.z
	var limit := 2.85
	var push := Vector3.ZERO
	for end in [-0.8, 1.0]:
		var p := global_position + fwd * float(end)
		push.x += clampf(limit - absf(p.x), -1.0, 0.0) * signf(p.x)
		push.z += clampf(limit - absf(p.z), -1.0, 0.0) * signf(p.z)
	if push.length() > 0.01:
		move_and_collide(-push.limit_length(1.0) * minf(1.0, 2.0 * dt))


# -- ragdoll knockdown / KO (scripts/fighter/ragdoll.gd)
const RAGDOLL_FALL_MIN := 1.2    ## s of FALL before the count may start (when the body is already at rest)
const RAGDOLL_FALL_MAX := 4.5    ## s after which the count starts regardless
const GETUP_BLEND := 0.45        ## s from the ragdoll pose into the get-up clip
# hip position of the get-up clips' first frame (character-local x, z), measured with tools/probe_getup.gd
const GETUP_HIP_UP := Vector2(-0.030, -0.013)
const GETUP_HIP_DOWN := Vector2(-0.012, -0.022)


## Where the camera should look at the fighter: the ragdoll's body centre while it is simulated.
func body_focus_position() -> Vector3:
	if _ragdoll != null and _ragdoll.active:
		return (_ragdoll.pelvis_position() + _ragdoll.head_position()) * 0.5
	return global_position + Vector3(0, 0.9, 0)


## The punch behind this fall, as the ragdoll wants it: contact point, travel direction, speed, power, struck body.
func _ragdoll_hit_spec(dir_prefix: String, zone: String, ko: bool) -> Dictionary:
	var away := -dir_to_foe()   # the way a straight punch from the foe drives the body
	away.y = 0.0
	var spec := {"zone": zone}
	var fresh: bool = not _last_hit.is_empty() and absf(_time - float(_last_hit["t"])) < 0.05
	if fresh:
		var ev: Dictionary = _last_hit["ev"]
		var s: Dictionary = _last_hit["strike"]
		var vel: Vector3 = ev.get("velocity", Vector3.ZERO)
		spec["pos"] = ev["position"]
		spec["speed"] = clampf(float(ev["speed"]), 1.5, 5.5)
		spec["dir"] = vel.normalized() if vel.length() > 0.5 else away
		var power := 1.0
		if s.get("heavy", false):
			power += 0.2
		if s.get("power", false):
			power += 0.15
		spec["power"] = power
		if ev.get("hurt_side", "") != "":
			spec["side"] = ev["hurt_side"]
	else:
		# scripted fall (tests, tools): synthesise a punch of that direction class from the foe's side
		var lateral := Vector3(away.z, 0.0, -away.x)   # +90 deg about y
		var d := away
		match dir_prefix:
			"L":
				d = (away * 0.55 - lateral * 0.85).normalized()
			"R":
				d = (away * 0.55 + lateral * 0.85).normalized()
			"U":
				d = (away * 0.5 + Vector3.UP * 0.9).normalized()
			"O":
				d = (away * 0.6 + Vector3.DOWN * 0.8).normalized()
		spec["dir"] = d
		spec["speed"] = 4.5
		spec["power"] = 1.0
		spec["pos"] = _ragdoll.pelvis_position() if zone != "head" else _ragdoll.head_position()
	if ko:
		spec["power"] = float(spec["power"]) * 1.15
	var pos: Vector3 = spec["pos"]
	spec["body"] = _ragdoll.body_for_zone(zone, pos, String(spec.get("side", "")))
	# pose polish: what kind of blow this was (jab / straight / hook / upper / body / over) drives the fall recipe
	spec["kind"] = KnockdownMotion.fall_kind(zone, dir_prefix, String((_last_hit["strike"] as Dictionary).get("limb", "")) if fresh else "")
	spec["back"] = away
	return spec


## Starts the physics fall: simulation from the current animated pose + the punch's impulse. The capsule is switched
## off (the body is the ragdoll) and the animation tree stops so no clip fights the simulation.
func _begin_ragdoll_fall(dir_prefix: String, zone: String, ko: bool) -> void:
	var spec := _ragdoll_hit_spec(dir_prefix, zone, ko)
	anim.end_action(0.01)
	anim.tree.active = false
	($CollisionShape3D as CollisionShape3D).set_deferred("disabled", true)
	velocity = Vector3.ZERO
	_impulse = Vector3.ZERO
	_push = Vector3.ZERO
	_ragdoll.begin(spec, 0.10)
	_fall_len = RAGDOLL_FALL_MAX
	knock_t = 0.0
	_rd_settled_t = 0.0


## The capsule follows the body (ground position of the pelvis) so the camera, referee and foe logic keep working.
func _follow_ragdoll() -> void:
	var p: Vector3 = _ragdoll.pelvis_position()
	global_position = Vector3(p.x, 0.0, p.z)


## Count finished: leave the simulation, move the capsule under the body, turn it so the get-up clip's lying pose
## matches how the body lies, and blend from the ragdoll pose into the clip.
func _end_ragdoll_into_getup() -> void:
	_ragdoll.capture_pose()
	var hip: Vector3 = _ragdoll.bone_origin("pelvis")
	var head: Vector3 = _ragdoll.bone_origin("head")
	var h := head - hip
	h.y = 0.0
	if h.length() < 0.05:
		h = -global_basis.z
	h = h.normalized()
	var up := _getup_clip == KnockdownMotion.GETUP_FACE_UP
	var yaw := atan2(-h.x, -h.z) if up else atan2(h.x, h.z)
	var hl := GETUP_HIP_UP if up else GETUP_HIP_DOWN
	var rot := Basis(Vector3.UP, yaw)
	var off := rot * Vector3(hl.x, 0.0, hl.y)
	rotation.y = yaw
	global_position = Vector3(hip.x - off.x, 0.0, hip.z - off.z)
	_ragdoll.stop()
	($CollisionShape3D as CollisionShape3D).disabled = false
	anim.reactivate()
	anim.play_action(_getup_clip, 0.0, 0.02)
	_ragdoll.blend.start(GETUP_BLEND)


func _do_ko(method: String, dir_prefix: String, zone: String) -> void:
	atk = {}
	buffer.clear()
	_clear_hurt()   # rocked rework
	ko_method = method
	_begin_ragdoll_fall(dir_prefix, zone, true)
	_set_state(State.DOWN)
	got_ko.emit(self, method)


func _reset_ragdoll() -> void:
	if _ragdoll == null:
		return
	if _ragdoll.active or _ragdoll.blend.weight > 0.0:
		_ragdoll.reset()
		anim.reactivate()
		($CollisionShape3D as CollisionShape3D).disabled = false


func start_victory() -> void:
	atk = {}
	buffer.clear()
	var c: String = VICTORY[rng.randi() % VICTORY.size()]
	anim.play_action(c, 0.0, 0.25)
	_set_state(State.WIN)


func start_loss_pose() -> void:
	atk = {}
	buffer.clear()
	anim.play_action("Congrats", 0.0, 0.25)
	_set_state(State.WIN)


func reset_for_round(pos: Vector3, full_reset: bool) -> void:
	if _brain:
		_brain.on_round_start(full_reset)   # AI polish: CPU opens each round with a feeling-out period
	global_position = pos
	velocity = Vector3.ZERO
	_impulse = Vector3.ZERO
	_push = Vector3.ZERO
	bc.reset()
	atk = {}
	buffer.clear()
	slip_dir = 0
	counter_window = 0.0
	counter_power = 0.0
	rock_lock = 0.0
	hurt.clear()
	hurt.cooldown = 0.0
	frozen = false
	if full_reset:
		stats.reset_for_bout()
	_reset_ragdoll()   # ragdoll
	anim.end_action(0.05)
	_set_state(State.IDLE)
	state = State.IDLE
	stats_changed.emit()


func _update_stats(dt: float) -> void:
	var guarding := guard_on
	var low := state in [State.SLIP, State.CROUCH]
	stats.moving = Vector2(velocity.x, velocity.z).length() > 0.25   # fatigue pass: regen depends on what you are doing
	stats.busy = state == State.ATTACK
	stats.tick(dt, guarding, low)
	_stats_emit_t += dt
	if _stats_emit_t >= 0.1:
		_stats_emit_t = 0.0
		stats_changed.emit()


var _stats_emit_t := 0.0


# ---------------------------------------------------------------- animation
func _update_animation(dt: float) -> void:
	hurt.guard_up = guard_on   # rocked rework: pose layer reads these
	hurt.suppress = state in [State.FALL, State.COUNT, State.GETUP, State.DOWN, State.WIN]
	var lv := local_dir(Vector3(velocity.x, 0, velocity.z))
	var spd := Vector2(velocity.x, velocity.z).length()
	var norm := lv / WALK_SPEED
	# the walk clips plant their feet at ~0.86 m/s (tools/measure_gait.gd): scale playback to the real speed
	anim.set_locomotion(norm, clampf(spd / CLIP_WALK_SPEED, 0.7, 1.8) if spd > 0.1 else 1.0, stats.rocked and state == State.IDLE, dt)
	anim.update(dt)


var _debug_nodes: Array = []   ## MeshInstance3D of the hit / hurt / guard volume overlay (F3)
var _debug_marks: Array = []   ## {node, until}: contact flashes


## F3 overlay: every hit sphere (red), hurt hull (blue, torso orange) and guard hull (green); each landed blow flashes its contact point
## on the foe's skin (red hit, yellow glance, green block) for ~0.8 s.
func set_debug_boxes(on: bool) -> void:
	debug_boxes = on
	if on and _debug_nodes.is_empty():
		_add_debug_meshes()
	for n in _debug_nodes:
		if is_instance_valid(n):
			n.visible = on
	if not on:
		_clear_debug_marks()


func _add_debug_meshes() -> void:
	for hb in rig.hitboxes:
		_debug_for(hb, Color(1, 0.2, 0.1, 0.55))
	for hu in rig.hurtboxes:
		_debug_for(hu, Color(1.0, 0.6, 0.1, 0.35) if rig.torso.has(hu) else Color(0.2, 0.6, 1.0, 0.35))
	for g in rig.guards:
		_debug_for(g, Color(0.3, 1.0, 0.3, 0.35))


func _debug_for(area: Area3D, col: Color) -> void:
	for c in area.get_children():
		var cs := c as CollisionShape3D
		if cs == null:
			continue
		var mi := MeshInstance3D.new()
		if cs.shape is SphereShape3D:
			var m := SphereMesh.new()
			m.radius = (cs.shape as SphereShape3D).radius
			m.height = m.radius * 2.0
			mi.mesh = m
		elif cs.shape is CapsuleShape3D:
			var m := CapsuleMesh.new()
			m.radius = (cs.shape as CapsuleShape3D).radius
			m.height = (cs.shape as CapsuleShape3D).height
			mi.mesh = m
		elif cs.shape is BoxShape3D:
			var hu := area as HitAreas.Hurtbox
			var sz := (cs.shape as BoxShape3D).size
			var rc: float = hu.corner if hu != null else 0.0
			var m := BoxMesh.new()
			m.size = sz
			mi.mesh = m
			if rc > 0.0:   # rounded hull: a stack of capsules would be exact; the box is its bounding frame, drawn fainter
				col.a *= 0.6
		var mat := StandardMaterial3D.new()
		mat.albedo_color = col
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = false
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cs.add_child(mi)
		_debug_nodes.append(mi)


func _debug_flash(point: Vector3, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = 0.05
	m.height = 0.10
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_parent().add_child(mi)
	mi.global_position = point
	_debug_marks.append({"node": mi, "until": _time + 0.8})


func _tick_debug_marks() -> void:
	for i in range(_debug_marks.size() - 1, -1, -1):
		var d: Dictionary = _debug_marks[i]
		if _time >= float(d["until"]) or not is_instance_valid(d["node"]):
			if is_instance_valid(d["node"]):
				(d["node"] as Node).queue_free()
			_debug_marks.remove_at(i)


func _clear_debug_marks() -> void:
	for d in _debug_marks:
		if is_instance_valid(d["node"]):
			(d["node"] as Node).queue_free()
	_debug_marks.clear()


# ---------------------------------------------------------------- rocked / hurt rework (HurtState + RockedPose)
func _attach_rocked_pose(sk: Skeleton3D) -> void:
	_rocked_pose = RockedPoseScript.new()
	_rocked_pose.name = "RockedPose"
	_rocked_pose.hurt = hurt
	_rocked_pose.fighter = self
	sk.add_child(_rocked_pose)


## Fatigue pass: procedural drooping guard + breathing, and the ROCKED! / GASSED tag above the head.
func _attach_fatigue_layers(sk: Skeleton3D) -> void:
	var fp: SkeletonModifier3D = FatiguePoseScript.new()
	fp.name = "FatiguePose"
	fp.fighter = self
	sk.add_child(fp)   # after the rocked pose: it backs off while a hurt episode drives the arms
	var tag: Node3D = StatusTagScript.new()
	tag.name = "StatusTag"
	tag.fighter = self
	add_child(tag)


func _clear_hurt() -> void:
	hurt.clear()
	rock_lock = 0.0


## Head daze: replaces the old 1.2 s hit-stun lock. The stun clip only covers the flinch (HurtStateScript.ONSET),
## then the fighter is back in IDLE (can shuffle at half speed, hold a weak block) under the procedural pose.
func _begin_head_hurt(att: Fighter, s: Dictionary, sev: float, dir_prefix: String) -> void:
	hurt.start_head(sev, rng)
	stats.rocked = true
	stats.stun_left = hurt.total_len()
	rock_lock = hurt.daze_len
	buffer.clear()
	var sc := CombatRules.hit_clip(dir_prefix, "stun")
	_start_reaction(sc, minf(anim.clip_length(sc), HurtStateScript.ONSET + 0.05), s)
	apply_impulse(-dir_from(att), 0.03)
	state_changed.emit(self, "rocked")


## Body shot fold (separate from the head daze). Only for unblocked body hits that are hard enough / on a weak body.
func _try_begin_body_hurt(att: Fighter, s: Dictionary, total: float, counter: bool) -> void:
	if practice or is_acute_down():
		return
	var ratio := stats.body / maxf(stats.body_max, 1.0)
	if not hurt.body_trigger(total, ratio, counter):
		return
	var sev := HurtStateScript.body_severity(total, ratio)
	hurt.start_body(sev, String(s["limb"]) == "R", String(s["dir"]) in ["F", "U", "O"], rng)
	rock_lock = maxf(rock_lock, hurt.body_len)
	buffer.clear()
	state_changed.emit(self, "hurt_body")
