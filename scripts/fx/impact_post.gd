extends CanvasLayer
## Full-screen post pass for the impact / rocked presentation (blur, rock vignette, warm vignette, contact flash).
## Sits below the HUD layer so the HUD stays sharp. Drive with set_state() each frame; hides itself while the tree is paused.

const SHADER := preload("res://scripts/fx/impact_post.gdshader")

var rect: ColorRect
var mat: ShaderMaterial
var _warm_alpha := 0.0
var _warm_warm := 0.0
var _warm_side := 1.0
var _flash_t := 99.0
var _flash_life := 0.11
var _flash_peak := 0.0
var _flash_uv := Vector2(0.5, 0.4)
var _flash_radius := 0.03
var _rock := 0.0
var _rock_impulse := 0.0
var _rock_target := 0.0
var _blur := 0.0


func _init() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS
	rect = ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mat = ShaderMaterial.new()
	mat.shader = SHADER
	rect.material = mat
	rect.visible = false
	add_child(rect)


func _process(_dt: float) -> void:
	# the camera stops updating while paused; never leave a frozen smear over the pause menu
	if rect.visible and get_tree().paused:
		rect.visible = false


## A head/body hit: warm vignette + contact flash (screen-impact.js consume()).
func hit(fx_strength: float, head: bool, side: float, uv: Vector2, rocked: bool) -> void:
	if head:
		_warm_side = side
		_warm_warm = maxf(_warm_warm, fx_strength)
		_warm_alpha = maxf(_warm_alpha, clampf(0.06 + fx_strength * 0.17, 0.0, 0.27))
	var peak := (0.16 + fx_strength * 0.48) if head else (0.16 + fx_strength * 0.3)
	_flash_peak = peak
	_flash_life = 0.085 + (0.025 if (rocked or fx_strength > 0.7) else 0.012)
	_flash_t = 0.0
	_flash_uv = uv
	_flash_radius = 0.022 + 0.045 * fx_strength
	if rocked:
		_rock_impulse = maxf(_rock_impulse, 0.5)


## Per frame. rocked_now: a fighter is in the rocked state. blur: 0..1 smear strength.
func set_state(dt: float, blur: float, blur_dir: Vector2, roll_rad: float, zoom_deg: float, rocked_now: bool) -> void:
	dt = minf(dt, 0.05)
	_warm_alpha *= exp(-7.5 * dt)
	_warm_warm *= exp(-5.0 * dt)
	if _warm_alpha < 0.002:
		_warm_alpha = 0.0
	_flash_t += dt
	_rock_impulse *= exp(-1.8 * dt)
	if _rock_impulse < 0.002:
		_rock_impulse = 0.0
	_rock_target = maxf(0.6 if rocked_now else 0.0, _rock_impulse)
	var rate := 8.0 if _rock_target > _rock else 3.0
	_rock += (_rock_target - _rock) * (1.0 - exp(-rate * dt))
	if _rock < 0.002:
		_rock = 0.0
	_blur = clampf(blur, 0.0, 1.0)
	var flash_a := _flash_peak * (1.0 - _flash_t / _flash_life) if _flash_t < _flash_life else 0.0
	var paused := get_tree() != null and get_tree().paused
	if paused:
		_blur = 0.0
	var any := _blur > 0.001 or _rock > 0.02 or _warm_alpha > 0.002 or flash_a > 0.003
	rect.visible = any and not paused
	if not rect.visible:
		return
	mat.set_shader_parameter("blur_strength", _blur)
	mat.set_shader_parameter("blur_dir", blur_dir)
	mat.set_shader_parameter("blur_roll", clampf(roll_rad, -0.30, 0.30))
	mat.set_shader_parameter("blur_zoom", clampf(zoom_deg, -20.0, 20.0))
	mat.set_shader_parameter("rock", _rock)
	mat.set_shader_parameter("warm_alpha", clampf(_warm_alpha, 0.0, 0.28))
	mat.set_shader_parameter("warm_side", _warm_side)
	mat.set_shader_parameter("flash", Vector4(_flash_uv.x, _flash_uv.y, _flash_radius, flash_a))


func clear() -> void:
	_warm_alpha = 0.0
	_warm_warm = 0.0
	_rock = 0.0
	_rock_impulse = 0.0
	_blur = 0.0
	_flash_t = 99.0
	rect.visible = false


func state() -> Dictionary:
	return {"blur": _blur, "rock": _rock, "warm": _warm_alpha, "visible": rect.visible}
