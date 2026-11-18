extends Node3D
## Floating state tag above a fighter's head (billboard Label3D): "ROCKED!" while the head daze lasts,
## "GASSED" while fatigue is high. Purely visual; reads Fighter.stats / Fighter.fatigue each frame.
## Preload it, don't reference it by class name.

var fighter: Node3D

const ROCKED_COLOR := Color(1.0, 0.82, 0.12)
const GASSED_COLOR := Color(1.0, 0.45, 0.12)
const HEIGHT := 1.98

var _label: Label3D
var _pop := 0.0
var _was_rocked := false
var _t := 0.0
var _a := 0.0
var _col := Color.WHITE


func _ready() -> void:
	position = Vector3(0, HEIGHT, 0)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = false
	_label.pixel_size = 0.0026
	_label.font_size = 96
	_label.outline_size = 20
	_label.outline_modulate = Color(0.05, 0.02, 0.02, 1.0)
	_label.render_priority = 5
	_label.modulate.a = 0.0
	_label.visible = false
	add_child(_label)


func _process(dt: float) -> void:
	if fighter == null or not is_instance_valid(fighter) or _label == null:
		return
	_t += dt
	var rocked: bool = fighter.stats.rocked and fighter.hurt.is_head() and not fighter.hurt.suppress
	var lvl: float = fighter.fatigue
	var gassed: bool = lvl > 0.5 and not rocked and not fighter.hurt.suppress and fighter.state_name in ["idle", "attack", "slip", "crouch", "hit"]
	if rocked and not _was_rocked:
		_pop = 1.0
	_was_rocked = rocked
	_pop = maxf(_pop - dt * 3.0, 0.0)
	var target_a := 0.0
	if rocked:
		_label.text = "ROCKED!"
		_col = ROCKED_COLOR
		_label.pixel_size = 0.0026 * (1.0 + 0.5 * _pop + 0.06 * sin(_t * 14.0))
		target_a = 1.0
	elif gassed:
		_label.text = "GASSED"
		_col = GASSED_COLOR
		_label.pixel_size = 0.0017
		target_a = 0.55 + 0.45 * (0.5 + 0.5 * sin(_t * 7.0))
	_a = move_toward(_a, target_a, dt * 6.0)
	_label.modulate = Color(_col.r, _col.g, _col.b, _a)
	_label.visible = _a > 0.01
