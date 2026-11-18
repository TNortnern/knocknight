class_name Hud
extends Control
## In-fight HUD. bind_match(match_node, config) wires it to a Match (or the stub).
## Bars are polled from the fighters every frame so they never go stale.

var _fighters: Array = []
var _config: Dictionary = {}
var _names: Array[Label] = []
var _health: Array[HudBar] = []
var _stamina: Array[HudBar] = []
var _guard: Array[HudBar] = []
var _round_label: Label
var _timer_label: Label
var _banner: Label
var _sub_banner: Label
var _floaters: Control
var _root_top: Control
var _banner_tween: Tween
var _sub_tween: Tween
var _banner_token := 0   ## bumped by a knockdown so a pending round-start "FIGHT!" never fires during a count
var _timed := true
var _rounds := 1
var _last_seconds := -1
var _snap := true
var _match: Node
var _flash: ColorRect
var _flash_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


func _build() -> void:
	_flash = ColorRect.new()
	_flash.color = Color(0.95, 0.2, 0.15, 0.0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UICommon.full_rect(_flash)
	add_child(_flash)

	var top := MarginContainer.new()
	_root_top = top
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.add_theme_constant_override("margin_left", 48)
	top.add_theme_constant_override("margin_right", 48)
	top.add_theme_constant_override("margin_top", 26)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 28)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(row)
	for i in 2:
		if i == 1:
			var center := VBoxContainer.new()
			center.custom_minimum_size = Vector2(230, 0)
			center.add_theme_constant_override("separation", -4)
			center.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_round_label = UICommon.label("ROUND 1", "CaptionLabel", HORIZONTAL_ALIGNMENT_CENTER)
			_round_label.add_theme_font_size_override("font_size", 22)
			_round_label.add_theme_color_override("font_color", UICommon.AMBER)
			center.add_child(_round_label)
			_timer_label = UICommon.label("3:00", "HudTimer", HORIZONTAL_ALIGNMENT_CENTER)
			center.add_child(_timer_label)
			row.add_child(center)
		row.add_child(_make_panel(i))

	_floaters = Control.new()
	_floaters.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UICommon.full_rect(_floaters)
	add_child(_floaters)

	var center_box := VBoxContainer.new()
	center_box.alignment = BoxContainer.ALIGNMENT_CENTER
	center_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UICommon.full_rect(center_box)
	center_box.offset_top = -60
	center_box.add_theme_constant_override("separation", -20)
	add_child(center_box)
	_banner = UICommon.label("", "BannerLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_banner.modulate.a = 0.0
	center_box.add_child(_banner)
	_sub_banner = UICommon.label("", "BannerLabel", HORIZONTAL_ALIGNMENT_CENTER)
	_sub_banner.add_theme_font_size_override("font_size", 230)
	_sub_banner.add_theme_color_override("font_color", UICommon.AMBER)
	_sub_banner.modulate.a = 0.0
	center_box.add_child(_sub_banner)
	_banner.resized.connect(func() -> void: _banner.pivot_offset = _banner.size * 0.5)
	_sub_banner.resized.connect(func() -> void: _sub_banner.pivot_offset = _sub_banner.size * 0.5)


func _make_panel(i: int) -> Control:
	var right := i == 1
	var accent := UICommon.RED if i == 0 else UICommon.BLUE
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 5)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_END if right else BoxContainer.ALIGNMENT_BEGIN
	head.add_theme_constant_override("separation", 12)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tag := UICommon.label("P%d" % (i + 1), "CaptionLabel")
	tag.add_theme_font_size_override("font_size", 20)
	tag.add_theme_color_override("font_color", accent.lightened(0.15))
	var nm := UICommon.label("FIGHTER", "HudName")
	_names.append(nm)
	if right:
		head.add_child(nm)
		head.add_child(tag)
	else:
		head.add_child(tag)
		head.add_child(nm)
	box.add_child(head)

	var hb := HudBar.new()
	hb.custom_minimum_size = Vector2(0, 28)
	hb.mirrored = right
	hb.fill_color = UICommon.IVORY
	hb.slant = 16
	_health.append(hb)
	box.add_child(hb)
	var sb := HudBar.new()
	sb.custom_minimum_size = Vector2(0, 12)
	sb.mirrored = right
	sb.fill_color = UICommon.GREEN
	sb.trail_color = Color(0.4, 0.82, 0.5, 0.35)
	sb.slant = 7
	_stamina.append(sb)
	var gb := HudBar.new()
	gb.custom_minimum_size = Vector2(0, 12)
	gb.mirrored = right
	gb.fill_color = UICommon.GUARD_BLUE
	gb.trail_color = Color(0.4, 0.65, 0.96, 0.35)
	gb.slant = 7
	_guard.append(gb)
	var sg := HBoxContainer.new()
	sg.add_theme_constant_override("separation", 8)
	sg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if right:
		sg.add_child(gb)
		sg.add_child(sb)
	else:
		sg.add_child(sb)
		sg.add_child(gb)
	box.add_child(sg)
	sb.caption = "STAMINA"
	gb.caption = "GUARD"
	return box


# --- binding ---------------------------------------------------------------------------

func bind_match(m: Node, config: Dictionary = {}) -> void:
	_match = m
	_config = config
	_rounds = int(config.get("rounds", 1))
	_timed = int(config.get("round_seconds", 180)) > 0
	_timer_label.visible = _timed
	var mode := String(config.get("mode", "exhibition"))
	_round_label.text = "ROUND 1 / %d" % _rounds if mode == "exhibition" else mode.to_upper()
	_fighters = []
	_snap = true
	_refresh_fighters()
	m.round_started.connect(_on_round_started)
	m.round_ended.connect(_on_round_ended)
	m.match_ended.connect(_on_match_ended)
	m.timer_changed.connect(_on_timer)
	m.hit_landed.connect(_on_hit)
	m.knockdown.connect(_on_knockdown)
	m.count_tick.connect(_on_count)
	if m.has_signal("referee_break"):
		m.referee_break.connect(func() -> void: banner("BREAK", UICommon.AMBER, 0.5, 0.5))   # body contact: referee separates a clinch
	if m.has_signal("fight_resumed"):
		m.fight_resumed.connect(_on_fight_resumed)
	if m.has_signal("fighter_state_changed"):
		m.fighter_state_changed.connect(_on_fighter_state)   # fatigue pass: rocked cue


func _frac(f: Object, prop: String, max_prop: String) -> float:
	var v: Variant = f.get(prop)
	var mx: Variant = f.get(max_prop)
	if v == null or mx == null or float(mx) <= 0.0:
		return 1.0
	return clampf(float(v) / float(mx), 0.0, 1.0)


func _poll(snap: bool) -> void:
	for i in mini(2, _fighters.size()):
		var f: Object = _fighters[i]
		if not is_instance_valid(f):
			continue
		var h := _frac(f, "health", "health_max")
		_health[i].set_target(h, snap)
		_health[i].fill_color = UICommon.RED.lightened(0.1) if h < 0.25 else UICommon.IVORY
		var sr := _frac(f, "stamina", "stamina_max")
		_stamina[i].set_target(sr, snap)
		_tint_stamina(_stamina[i], sr)
		_guard[i].set_target(_frac(f, "guard", "guard_max"), snap)


## Fatigue pass: the stamina bar turns amber under 40 % and flashes red with a GASSED caption under 20 %.
func _tint_stamina(bar: HudBar, sr: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	if sr < 0.20:
		var k := 0.5 + 0.5 * sin(t * 12.0)
		bar.fill_color = UICommon.GREEN.lerp(Color(1.0, 0.2, 0.15), 0.45 + 0.55 * k)
		bar.modulate.a = 0.55 + 0.45 * k
		bar.caption = "GASSED"
		bar.queue_redraw()
	elif sr < 0.40:
		bar.fill_color = UICommon.AMBER
		bar.modulate.a = 1.0
		bar.caption = ""
		bar.queue_redraw()
	elif bar.fill_color != UICommon.GREEN or bar.modulate.a < 1.0 or bar.caption != "":
		bar.fill_color = UICommon.GREEN
		bar.modulate.a = 1.0
		bar.caption = ""
		bar.queue_redraw()


func _refresh_fighters() -> void:
	if _match == null or not is_instance_valid(_match):
		return
	var fs: Array = _match.get_fighters()
	if fs.size() < 2:
		return
	_fighters = fs
	for i in 2:
		var nm: Variant = (fs[i] as Object).get("display_name")
		_names[i].text = String(nm).to_upper() if nm != null else "P%d" % (i + 1)
	_snap = true


func _process(_delta: float) -> void:
	if not _fighters.is_empty() and (_match == null or not is_instance_valid(_match)):
		_fighters = []
		return
	if _fighters.size() < 2:
		_refresh_fighters()
		if _fighters.size() < 2:
			return
	_poll(_snap)
	_snap = false


# --- events ----------------------------------------------------------------------------

func _on_timer(seconds_left: float) -> void:
	var s := int(ceil(seconds_left))
	if s == _last_seconds:
		return
	_last_seconds = s
	_timer_label.text = "%d:%02d" % [s / 60, s % 60]
	var low := s <= 10
	_timer_label.add_theme_color_override("font_color", UICommon.RED.lightened(0.2) if low else UICommon.IVORY)


func _on_round_started(r: int) -> void:
	if String(_config.get("mode", "exhibition")) == "exhibition":
		_round_label.text = "ROUND %d / %d" % [r, _rounds]
	_last_seconds = -1
	_banner_token += 1
	var token := _banner_token
	_hide_count()
	if String(_config.get("mode", "exhibition")) == "exhibition":
		banner("ROUND %d" % r, UICommon.IVORY, 1.0)
		await get_tree().create_timer(1.15).timeout
		if is_inside_tree() and token == _banner_token:
			banner("FIGHT!", UICommon.AMBER, 0.8, 1.0)
	else:
		banner("FIGHT!", UICommon.AMBER, 0.8, 1.0)


func _on_round_ended(_r: int) -> void:
	_banner_token += 1   # a pending round-start FIGHT! must not appear over the round-over banner
	banner("ROUND OVER", UICommon.IVORY, 1.6, 0.6)


func _on_match_ended(result: Dictionary) -> void:
	_hide_count()
	var method := String(result.get("method", ""))
	match method:
		"KO":
			banner("K.O.", UICommon.RED.lightened(0.15), 4.0)
		"TKO":
			banner("T.K.O.", UICommon.RED.lightened(0.15), 4.0)
		"Decision":
			banner("DECISION", UICommon.IVORY, 3.0, 0.7)
		"Draw":
			banner("DRAW", UICommon.IVORY, 3.0, 0.7)
		_:
			banner(method.to_upper(), UICommon.IVORY, 3.0, 0.7)


func _on_knockdown(_index: int) -> void:
	_banner_token += 1
	_hide_count()
	banner("KNOCKDOWN", UICommon.RED.lightened(0.15), 1.1, 0.7)
	_flash_screen(0.25)


## Rocked cue: a quick amber screen flash (the ROCKED! tag itself floats over the fighter, see status_tag.gd).
func _on_fighter_state(_index: int, state: String) -> void:
	if state == "rocked":
		pass   # the camera's post pass (fx/impact_post) now owns the rocked screen treatment


## Referee count: one big number per tick, held until the next one (or until the fighter is up / the bout is over).
func _on_count(_index: int, n: int) -> void:
	_banner_token += 1
	if _banner_tween:
		_banner_tween.kill()
	_banner.modulate.a = 0.0   # the KNOCKDOWN banner has done its job; numbers only from here
	_sub_banner.text = str(n)
	_sub_banner.modulate.a = 1.0
	_sub_banner.scale = Vector2(1.6, 1.6)
	if _sub_tween:
		_sub_tween.kill()
	_sub_tween = create_tween()
	_sub_tween.tween_property(_sub_banner, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_fight_resumed() -> void:
	_hide_count()
	banner("FIGHT!", UICommon.AMBER, 0.6, 0.8)


func _hide_count() -> void:
	if _sub_tween:
		_sub_tween.kill()
	_sub_tween = create_tween()
	_sub_tween.tween_property(_sub_banner, "modulate:a", 0.0, 0.15)


## What the big banner / the count numeral currently show ("" when invisible). For tests.
func banner_text() -> String:
	return _banner.text if _banner.modulate.a > 0.05 else ""


func count_text() -> String:
	return _sub_banner.text if _sub_banner.modulate.a > 0.05 else ""


func banner(text: String, color: Color, hold: float, size_scale := 1.0) -> void:
	_banner.text = text
	_banner.add_theme_color_override("font_color", color)
	_banner.add_theme_font_size_override("font_size", int(150 * size_scale))
	_banner.pivot_offset = _banner.size * 0.5
	_banner.scale = Vector2(1.6, 1.6)
	_banner.modulate.a = 0.0
	if _banner_tween:
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.set_parallel(true)
	_banner_tween.tween_property(_banner, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_banner_tween.tween_property(_banner, "modulate:a", 1.0, 0.12)
	_banner_tween.chain().tween_interval(hold)
	_banner_tween.chain().tween_property(_banner, "modulate:a", 0.0, 0.3)


func _flash_screen(strength: float) -> void:
	if _flash_tween:
		_flash_tween.kill()
	_flash.color.a = strength
	_flash_tween = create_tween()
	_flash_tween.tween_property(_flash, "color:a", 0.0, 0.35)


func _on_hit(_attacker: int, info: Dictionary) -> void:
	var strength := String(info.get("strength", "light"))
	var blocked := bool(info.get("blocked", false))
	var dmg := float(info.get("damage", 0.0))
	var pos: Vector3 = info.get("position", Vector3.ZERO)
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.is_position_behind(pos):
		return
	var sp := cam.unproject_position(pos)
	var local := get_global_transform_with_canvas().affine_inverse() * sp
	var lbl := Label.new()
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.theme_type_variation = &"HudName"
	var size_px := 30
	var col := UICommon.IVORY
	var txt := str(int(round(dmg)))
	if info.get("parry", false):
		txt = "PARRY"
		col = UICommon.AMBER
		size_px = 40
	elif blocked:
		txt = "BLOCK" if not info.get("partial", false) else "BLOCK  " + str(int(round(dmg)))
		col = UICommon.GUARD_BLUE
		size_px = 28
	else:
		if info.get("pierce", false):
			txt = "PIERCED  " + txt
		match strength:
			"medium":
				size_px = 40
				col = UICommon.AMBER
			"heavy":
				size_px = 56
				col = UICommon.RED.lightened(0.2)
		if info.get("trade", false):   # exchange: both fists landed together; the one that landed better is highlighted
			txt = "TRADE  " + txt
			if info.get("trade_won", false):
				col = UICommon.AMBER
		elif info.get("counter", false):
			txt = "COUNTER  " + txt
			col = UICommon.AMBER
	lbl.text = txt
	lbl.add_theme_font_size_override("font_size", size_px)
	lbl.add_theme_color_override("font_color", col)
	lbl.position = local + Vector2(randf_range(-40, 40) - 30, -50)
	_floaters.add_child(lbl)
	lbl.pivot_offset = Vector2(30, size_px * 0.5)
	lbl.scale = Vector2(1.5, 1.5) if strength == "heavy" and not blocked else Vector2(1.2, 1.2)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(lbl, "scale", Vector2.ONE, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "position:y", lbl.position.y - 80.0, 0.8).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.35).set_delay(0.45)
	tw.chain().tween_callback(lbl.queue_free)
	if false:   # heavy-hit red flash replaced by the post pass warm vignette
		_flash_screen(0.12)
