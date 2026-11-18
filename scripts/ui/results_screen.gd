class_name ResultsScreen
extends Control
## Post-fight results. show_result(result, names, config) then wait for
## rematch_requested / menu_requested.

signal rematch_requested
signal menu_requested

var _kicker: Label
var _headline: Label
var _method: Label
var _detail: Label
var _buttons: Array = []
var _art: TextureRect


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_art = UICommon.art_rect("title")
	add_child(_art)
	var dim := ColorRect.new()
	dim.color = Color(0.015, 0.016, 0.02, 0.84)
	UICommon.full_rect(dim)
	add_child(dim)
	add_child(UICommon.bottom_shade())
	var center := CenterContainer.new()
	UICommon.full_rect(center)
	add_child(center)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(760, 0)
	col.add_theme_constant_override("separation", 8)
	center.add_child(col)
	_kicker = UICommon.label("FINAL RESULT", "CaptionLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_kicker.add_theme_color_override("font_color", UICommon.AMBER)
	_kicker.add_theme_font_size_override("font_size", 24)
	col.add_child(_kicker)
	_headline = UICommon.label("", "TitleLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_headline.add_theme_font_size_override("font_size", 130)
	col.add_child(_headline)
	_method = UICommon.label("", "HeadingLabel", HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_method)
	_detail = UICommon.label("", "CaptionLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_detail.add_theme_font_size_override("font_size", 22)
	col.add_child(_detail)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 36)
	col.add_child(sp)
	var rematch := UICommon.button("REMATCH", "BtnRematch", 760)
	rematch.alignment = HORIZONTAL_ALIGNMENT_CENTER
	rematch.pressed.connect(func() -> void: rematch_requested.emit())
	col.add_child(rematch)
	var menu := UICommon.button("MAIN MENU", "BtnMenu", 760)
	menu.alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu.pressed.connect(func() -> void: menu_requested.emit())
	col.add_child(menu)
	_buttons = [rematch, menu]
	UICommon.chain(_buttons)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree():
			focus_first())


func focus_first() -> void:
	if _buttons.size() > 0 and is_inside_tree():
		(_buttons[0] as Button).grab_focus()


func show_result(result: Dictionary, names: Array, config: Dictionary) -> void:
	var winner := int(result.get("winner", -1))
	var method := String(result.get("method", ""))
	var mode := String(config.get("mode", "exhibition"))
	if mode == "sparring" or mode == "training":
		_kicker.text = "SESSION COMPLETE"
		_headline.text = "WELL WORKED"
		_method.text = mode.to_upper()
	elif winner < 0 or winner >= names.size():
		_kicker.text = "FINAL RESULT"
		_headline.text = "DRAW"
		_method.text = "DOUBLE K.O." if method == "KO" else "NO WINNER"
	else:
		_kicker.text = "WINNER"
		_headline.text = String(names[winner]).to_upper()
		_method.text = {"KO": "BY KNOCKOUT", "TKO": "BY TECHNICAL KNOCKOUT", "Decision": "BY DECISION"}.get(method, method.to_upper())
	_headline.add_theme_color_override("font_color", UICommon.AMBER if winner >= 0 else UICommon.IVORY)
	var rules := String(config.get("rules", "")).capitalize()
	_detail.text = "%s  -  %s  -  %d round%s" % [" vs ".join(PackedStringArray(names.map(func(n: Variant) -> String: return String(n).to_upper()))), rules, int(config.get("rounds", 1)), "" if int(config.get("rounds", 1)) == 1 else "s"]
	focus_first()
