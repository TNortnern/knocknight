class_name TitleMenu
extends Control
## Main menu. Emits mode_chosen("exhibition"|"sparring"|"training") or quit_requested.

signal mode_chosen(mode: String)
signal quit_requested

const BLURBS := {
	"BtnExhibition": "Timed bout. Pick your fighter, rules, rounds and opponent.",
	"BtnSparring": "Practice with a CPU partner. No knockouts, damage resets.",
	"BtnTraining": "Work combinations on a dummy. Infinite stamina.",
	"BtnQuit": "Leave the gym.",
}

var _art_a: TextureRect
var _art_b: TextureRect
var _blurb: Label
var _buttons: Array = []
var _fade: Tween


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UICommon.BG
	UICommon.full_rect(bg)
	add_child(bg)
	_art_a = UICommon.art_rect("title")
	add_child(_art_a)
	_art_b = UICommon.art_rect("title")
	_art_b.modulate.a = 0.0
	add_child(_art_b)
	add_child(UICommon.side_shade(0.97, 0.7))
	add_child(UICommon.bottom_shade())

	var margin := MarginContainer.new()
	UICommon.full_rect(margin)
	margin.add_theme_constant_override("margin_left", 110)
	margin.add_theme_constant_override("margin_top", 70)
	margin.add_theme_constant_override("margin_bottom", 56)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.custom_minimum_size = Vector2(560, 0)
	col.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(col)

	var kicker := UICommon.label("BOXING  /  KICKBOXING  /  FIGHT NIGHT", "CaptionLabel")
	kicker.add_theme_color_override("font_color", UICommon.AMBER)
	col.add_child(kicker)
	var t1 := UICommon.label("KNOCK", "TitleLabel")
	t1.add_theme_constant_override("line_spacing", -30)
	col.add_child(t1)
	var t2 := UICommon.label("NIGHT", "TitleLabel")
	t2.add_theme_color_override("font_color", UICommon.AMBER)
	col.add_child(t2)
	t1.add_theme_constant_override("outline_size", 8)
	t2.add_theme_constant_override("outline_size", 8)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 26)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(spacer)

	var items := [["EXHIBITION", "BtnExhibition"], ["SPARRING", "BtnSparring"], ["TRAINING", "BtnTraining"], ["QUIT", "BtnQuit"]]
	for it in items:
		var b := UICommon.button(it[0], it[1], 420)
		col.add_child(b)
		_buttons.append(b)
		b.focus_entered.connect(_on_focus.bind(b))
		b.pressed.connect(_on_pressed.bind(b))
	UICommon.chain(_buttons)

	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(fill)
	_blurb = UICommon.label("", "CaptionLabel")
	_blurb.custom_minimum_size = Vector2(520, 0)
	_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_blurb)
	var hint := UICommon.label("UP / DOWN  select      ENTER / A  confirm      ESC  pause in fight", "CaptionLabel")
	hint.modulate.a = 0.7
	col.add_child(hint)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree():
			focus_first())
	focus_first.call_deferred()


func focus_first() -> void:
	if _buttons.size() > 0 and is_inside_tree():
		(_buttons[0] as Button).grab_focus()


func _on_focus(b: Button) -> void:
	_blurb.text = BLURBS.get(b.name, "")
	var key := String(b.name).trim_prefix("Btn").to_lower()
	if not UICommon.ART.has(key):
		key = "title"
	_crossfade(key)


func _crossfade(key: String) -> void:
	var tex := UICommon.art(key)
	if _art_a.texture == tex and _art_b.modulate.a < 0.01:
		return
	_art_b.texture = tex
	if _fade:
		_fade.kill()
	_art_b.modulate.a = 0.0
	_fade = create_tween()
	_fade.tween_property(_art_b, "modulate:a", 1.0, 0.35)
	_fade.tween_callback(func() -> void:
		_art_a.texture = tex
		_art_b.modulate.a = 0.0)


func _on_pressed(b: Button) -> void:
	match String(b.name):
		"BtnExhibition":
			mode_chosen.emit("exhibition")
		"BtnSparring":
			mode_chosen.emit("sparring")
		"BtnTraining":
			mode_chosen.emit("training")
		"BtnQuit":
			quit_requested.emit()
