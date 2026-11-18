class_name SetupScreen
extends Control
## Fight setup. configure(mode) shows the rows relevant to the mode; START emits
## start_requested(config) with the Match.setup() dictionary.

signal start_requested(config: Dictionary)
signal back_requested

const RosterScript := preload("res://scripts/fighter/roster.gd")
const MODE_INFO := {
	"exhibition": {"title": "EXHIBITION", "sub": "Timed bout with a judged decision"},
	"sparring": {"title": "SPARRING", "sub": "Practice session - no knockouts, damage resets"},
	"training": {"title": "TRAINING", "sub": "Dummy work with infinite stamina"},
}

var mode := "exhibition"
var rows := {}
var _art: TextureRect
var _heading: Label
var _sub: Label
var _fighter_name: Label
var _fighter_style: Label
var _start: Button
var _back: Button
var _row_order: Array = []


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UICommon.BG
	UICommon.full_rect(bg)
	add_child(bg)
	_art = UICommon.art_rect("exhibition")
	add_child(_art)
	add_child(UICommon.side_shade(0.985, 0.62))
	add_child(UICommon.bottom_shade())

	var margin := MarginContainer.new()
	UICommon.full_rect(margin)
	margin.add_theme_constant_override("margin_left", 90)
	margin.add_theme_constant_override("margin_top", 56)
	margin.add_theme_constant_override("margin_bottom", 48)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(700, 0)
	col.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.add_theme_constant_override("separation", 8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(col)

	_sub = UICommon.label("", "CaptionLabel")
	_sub.add_theme_color_override("font_color", UICommon.AMBER)
	col.add_child(_sub)
	_heading = UICommon.label("", "HeadingLabel")
	_heading.add_theme_font_size_override("font_size", 84)
	_heading.add_theme_color_override("font_color", UICommon.IVORY)
	col.add_child(_heading)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 14)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)

	var fighter_opts: Array = []
	for id: String in RosterScript.ORDER:
		fighter_opts.append(_opt(RosterScript.def(id)["label"], id))
	var foe_opts: Array = [_opt("Auto", "auto")] + fighter_opts
	_add_row(col, "fighter", "FIGHTER", fighter_opts)
	_add_row(col, "foe", "OPPONENT FIGHTER", foe_opts)
	_add_row(col, "opponent", "OPPONENT", [_opt("CPU", "cpu"), _opt("Local 2P", "human")])
	_add_row(col, "difficulty", "CPU DIFFICULTY", [_opt("Easy", "easy"), _opt("Normal", "normal"), _opt("Hard", "hard")], 1)
	_add_row(col, "dummy", "DUMMY", [_opt("Stationary", "stationary"), _opt("Guarding", "guarding"), _opt("Moving", "moving")])
	_add_row(col, "rules", "RULES", [_opt("Boxing", "boxing"), _opt("Kickboxing", "kickboxing")], 1)
	_add_row(col, "rounds", "ROUNDS", [_opt("1", 1), _opt("3", 3), _opt("5", 5)], 1)
	_add_row(col, "length", "ROUND LENGTH", [_opt("2:00", 120), _opt("3:00", 180), _opt("5:00", 300)], 1)
	_add_row(col, "arena", "ARENA", [_opt("Boxing Ring", "ring"), _opt("Octagon", "octagon")])
	var move_opts: Array = [_opt("Toward foe (W)", "fighter"), _opt("Camera relative", "camera")]
	_add_row(col, "move_p1", "P1 MOVEMENT", move_opts)
	_add_row(col, "move_p2", "P2 MOVEMENT", move_opts)
	rows["move_p1"].select_value(GameSettings.movement_mode(0))
	rows["move_p2"].select_value(GameSettings.movement_mode(1))
	rows["fighter"].changed.connect(func(_v: Variant) -> void: _update_fighter_card())
	rows["opponent"].changed.connect(func(_v: Variant) -> void: _on_opponent_changed())

	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(fill)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 14)
	btns.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(btns)
	_start = UICommon.button("START FIGHT", "BtnStart", 400)
	_start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btns.add_child(_start)
	_back = UICommon.button("BACK", "BtnBack", 220)
	btns.add_child(_back)
	_start.pressed.connect(func() -> void: start_requested.emit(build_config()))
	_back.pressed.connect(func() -> void: back_requested.emit())

	# fighter card, bottom right
	var card_wrap := MarginContainer.new()
	UICommon.full_rect(card_wrap)
	card_wrap.add_theme_constant_override("margin_right", 90)
	card_wrap.add_theme_constant_override("margin_bottom", 48)
	card_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(card_wrap)
	var card := VBoxContainer.new()
	card.size_flags_horizontal = Control.SIZE_SHRINK_END
	card.size_flags_vertical = Control.SIZE_SHRINK_END
	card.custom_minimum_size = Vector2(520, 0)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_wrap.add_child(card)
	var yc := UICommon.label("YOUR FIGHTER", "CaptionLabel", HORIZONTAL_ALIGNMENT_RIGHT)
	yc.add_theme_color_override("font_color", UICommon.AMBER)
	card.add_child(yc)
	_fighter_name = UICommon.label("", "TitleLabel", HORIZONTAL_ALIGNMENT_RIGHT)
	_fighter_name.add_theme_font_size_override("font_size", 96)
	card.add_child(_fighter_name)
	_fighter_style = UICommon.label("", "CaptionLabel", HORIZONTAL_ALIGNMENT_RIGHT)
	_fighter_style.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card.add_child(_fighter_style)

	configure("exhibition")
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree():
			focus_first())


func _opt(label: String, value: Variant) -> Dictionary:
	return {"label": label, "value": value}


func _add_row(parent: Control, key: String, title: String, options: Array, idx := 0) -> void:
	var r := ChoiceRow.new()
	r.name = "Row_" + key
	r.setup(title, options, idx)
	parent.add_child(r)
	rows[key] = r
	_row_order.append(r)


func focus_first() -> void:
	for r: ChoiceRow in _row_order:
		if r.visible:
			r.grab_focus()
			return


func configure(p_mode: String) -> void:
	mode = p_mode
	var info: Dictionary = MODE_INFO.get(mode, MODE_INFO["exhibition"])
	_heading.text = info["title"]
	_sub.text = String(info["sub"]).to_upper()
	_art.texture = UICommon.art(mode)
	var show := {
		"fighter": true,
		"foe": true,
		"opponent": mode == "exhibition",
		"difficulty": mode != "training",
		"dummy": mode == "training",
		"rules": true,
		"rounds": mode == "exhibition",
		"length": true,
		"arena": true,
		"move_p1": true,
		"move_p2": false,
	}
	for k: String in rows:
		rows[k].visible = show[k]
	var lr: ChoiceRow = rows["length"]
	match mode:
		"exhibition":
			lr.setup("ROUND LENGTH", [_opt("2:00", 120), _opt("3:00", 180), _opt("5:00", 300)], 1)
		"sparring":
			lr.setup("SESSION LENGTH", [_opt("3:00", 180), _opt("5:00", 300)], 1)
		"training":
			lr.setup("TIMER", [_opt("OFF", 0), _opt("2:00", 120), _opt("3:00", 180)], 0)
	lr.refresh()
	_on_opponent_changed()
	_update_fighter_card()
	if is_visible_in_tree():
		focus_first()


func _relink() -> void:
	UICommon.chain(_row_order + [_start, _back])
	_start.focus_neighbor_right = _start.get_path_to(_back)
	_back.focus_neighbor_left = _back.get_path_to(_start)


func _on_opponent_changed() -> void:
	if mode == "exhibition":
		rows["difficulty"].visible = rows["opponent"].value() == "cpu"
		rows["move_p2"].visible = rows["opponent"].value() == "human"
	else:
		rows["move_p2"].visible = false
	_relink()


func _update_fighter_card() -> void:
	var f: Dictionary = RosterScript.def(rows["fighter"].value())
	_fighter_name.text = String(f["name"]).to_upper()
	_fighter_style.text = "%s - %s" % [f["full"], f["style"]]


func build_config() -> Dictionary:
	var p1: String = rows["fighter"].value()
	var p2: String = rows["foe"].value()
	if p2 == "auto":
		p2 = RosterScript.auto_opponent(p1)
	var cfg := {
		"mode": mode,
		"p1_controller": "human",
		"p2_controller": "cpu",
		"p1_model": p1,
		"p2_model": p2,
		"rules": rows["rules"].value(),
		"rounds": 1,
		"round_seconds": int(rows["length"].value()),
		"cpu_difficulty": rows["difficulty"].value(),
		"arena": rows["arena"].value(),
		"p1_movement_mode": rows["move_p1"].value(),
		"p2_movement_mode": rows["move_p2"].value(),
	}
	GameSettings.set_movement_mode(0, cfg["p1_movement_mode"])
	if rows["move_p2"].visible:
		GameSettings.set_movement_mode(1, cfg["p2_movement_mode"])
	match mode:
		"exhibition":
			cfg["p2_controller"] = rows["opponent"].value()
			cfg["rounds"] = int(rows["rounds"].value())
		"sparring":
			cfg["p2_controller"] = "cpu"
		"training":
			cfg["p2_controller"] = "dummy"
			cfg["dummy_mode"] = rows["dummy"].value()
	return cfg
