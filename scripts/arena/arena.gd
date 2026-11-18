class_name Arena
extends Node3D
## Boxing ring venue. Floor top is y = 0, ring centre at the origin.
## Colliders: StaticBody3D "Floor" (layer 1) and "RingWalls" with four boxes whose inner
## faces sit at +-WALL_HALF (3.02 m; with the 0.12 m capsule the root stops at 2.9 m).
## Camera cooperation: call update_camera(world_pos) each frame; ropes on the side the
## camera is looking through fade out so they never cut across the fighters.

const RING_HALF := 3.2
const WALL_HALF := 3.02   ## collider faces; with the 0.12 m body capsule (fighter.tscn) a fighter's root stops at 2.9 m, his back at the ropes (was 3.26 with the 0.36 m capsule)
const ROPE_HALF := 3.45
const CANVAS_HALF := 3.95
const GROUND_Y := -1.2
const WORLD_LAYER := 1
const ROPE_HEIGHTS := [0.45, 0.75, 1.05, 1.35]
const SIDES := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]

var kind := "ring"
var _side_nodes := {}  # Vector2i normal -> Array[GeometryInstance3D]
var _side_fade := {}   # Vector2i normal -> float 0..1
var _cam_pos := Vector3(0, 2, 8)
var _cam_look := Vector3.ZERO
var _posts: Array = []        # [{p: Vector2 (XZ), nodes: Array[GeometryInstance3D], fade: float}]
var _flash_mm: MultiMesh
var _flash_timer := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 1234
	_build_collision()
	_build_venue()
	_build_lights()
	_build_crowd()


func update_camera(cam_pos: Vector3, look := Vector3.ZERO) -> void:
	_cam_pos = cam_pos
	_cam_look = look


func get_bounds_half() -> float:
	return RING_HALF


func _process(delta: float) -> void:
	for n in _side_nodes:
		var vec := Vector2(n)
		var d := Vector2(_cam_pos.x, _cam_pos.z).dot(vec)
		# also fade a side whose ropes pass close to the camera (near a corner they cut across the frame edge)
		var along := Vector2(-vec.y, vec.x)
		var on_side := vec * ROPE_HALF + along * clampf(Vector2(_cam_pos.x, _cam_pos.z).dot(along), -ROPE_HALF, ROPE_HALF)
		var close := Vector2(_cam_pos.x, _cam_pos.z).distance_to(on_side) < 1.1
		var target := 1.0 if (d > ROPE_HALF + 0.25 or close) else 0.0
		var cur: float = _side_fade[n]
		var nxt := move_toward(cur, target, delta * 4.0)
		if nxt != cur:
			_side_fade[n] = nxt
			for gi: GeometryInstance3D in _side_nodes[n]:
				gi.transparency = nxt
				gi.visible = nxt < 0.98
	# Corner posts fade when they stand in the camera's line of sight to the fighters (they filled the frame
	# whenever the camera swung across a corner).
	var c2 := Vector2(_cam_pos.x, _cam_pos.z)
	var l2 := Vector2(_cam_look.x, _cam_look.z)
	for post: Dictionary in _posts:
		var pp: Vector2 = post["p"]
		var seg := l2 - c2
		var t := clampf((pp - c2).dot(seg) / maxf(seg.length_squared(), 0.0001), 0.0, 1.0)
		var blocking := (c2 + seg * t).distance_to(pp) < 0.75 and t < 0.92
		var near_cam := c2.distance_to(pp) < 2.2   # close posts fill the frame edge even off the sight line
		var ft := 1.0 if (blocking or near_cam) else 0.0
		var cur: float = post["fade"]
		var nxt := move_toward(cur, ft, delta * 5.0)
		if nxt != cur:
			post["fade"] = nxt
			for gi: GeometryInstance3D in post["nodes"]:
				gi.transparency = nxt
				gi.visible = nxt < 0.98
	_flash_timer -= delta
	if _flash_mm and _flash_timer <= 0.0:
		_flash_timer = 0.09
		_update_flashes()


# --- collision -------------------------------------------------------------------------

func _build_collision() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = WORLD_LAYER
	floor_body.collision_mask = 0
	var fs := CollisionShape3D.new()
	var fb := BoxShape3D.new()
	fb.size = Vector3(CANVAS_HALF * 2.0, 1.0, CANVAS_HALF * 2.0)
	fs.shape = fb
	fs.position = Vector3(0, -0.5, 0)
	floor_body.add_child(fs)
	add_child(floor_body)
	_build_walls_square(WALL_HALF)


func _build_walls_square(half: float) -> void:
	var walls := StaticBody3D.new()
	walls.name = "RingWalls"
	walls.collision_layer = WORLD_LAYER
	walls.collision_mask = 0
	var thick := 0.5
	var height := 3.0
	var span := half * 2.0 + thick * 2.0
	for n: Vector3 in SIDES:
		var cs := CollisionShape3D.new()
		cs.name = "Wall_%d_%d" % [int(n.x), int(n.z)]
		var bs := BoxShape3D.new()
		var along_x := absf(n.x) > 0.5
		bs.size = Vector3(thick, height, span) if along_x else Vector3(span, height, thick)
		cs.shape = bs
		cs.position = n * (half + thick * 0.5) + Vector3(0, height * 0.5, 0)
		walls.add_child(cs)
	add_child(walls)


# --- materials / helpers ---------------------------------------------------------------

func _mat(color: Color, rough := 0.7, metal := 0.0, emit := Color(0, 0, 0), emit_energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	if emit_energy > 0.0:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = emit_energy
	return m


func _box(parent: Node, size: Vector3, pos: Vector3, mat: Material, nm := "Box") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _cyl(parent: Node, radius: float, height: float, pos: Vector3, mat: Material, nm := "Cyl", sides := 20) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = sides
	m.rings = 1
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _noise_tex(freq: float, seed_v: int) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.frequency = freq
	n.seed = seed_v
	var t := NoiseTexture2D.new()
	t.noise = n
	t.width = 512
	t.height = 512
	t.seamless = true
	return t


func _build_ground() -> void:
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var gp := PlaneMesh.new()
	gp.size = Vector2(80, 80)
	ground.mesh = gp
	ground.position.y = GROUND_Y
	ground.material_override = _mat(Color(0.035, 0.037, 0.045), 0.35, 0.3)
	add_child(ground)


# --- ring ------------------------------------------------------------------------------

func _build_venue() -> void:
	kind = "ring"
	_build_ground()
	var ring := Node3D.new()
	ring.name = "Ring"
	add_child(ring)

	# Canvas: a thin slab with a woven noise texture
	var canvas_mat := _mat(Color(0.2, 0.22, 0.28), 0.92)
	canvas_mat.albedo_texture = _noise_tex(0.05, 7)
	canvas_mat.uv1_scale = Vector3(6, 6, 1)
	_box(ring, Vector3(CANVAS_HALF * 2, 0.12, CANVAS_HALF * 2), Vector3(0, -0.06, 0), canvas_mat, "Canvas")

	# Skirt
	var skirt_h := -GROUND_Y - 0.12
	_box(ring, Vector3(CANVAS_HALF * 2 - 0.02, skirt_h, CANVAS_HALF * 2 - 0.02),
		Vector3(0, -0.12 - skirt_h * 0.5, 0), _mat(Color(0.05, 0.055, 0.065), 0.6), "Skirt")
	# LED strip around the skirt foot (under-lighting)
	var led := _mat(Color(1, 0.78, 0.34), 0.4, 0.0, Color(1, 0.7, 0.25), 3.0)
	var strip_y := GROUND_Y + 0.08
	for n: Vector3 in SIDES:
		var along_x := absf(n.x) > 0.5
		var sz := Vector3(0.03, 0.04, CANVAS_HALF * 2) if along_x else Vector3(CANVAS_HALF * 2, 0.04, 0.03)
		_box(ring, sz, n * (CANVAS_HALF - 0.005) + Vector3(0, strip_y, 0), led, "LED")
	_box(ring, Vector3(CANVAS_HALF * 2 + 0.06, 0.04, CANVAS_HALF * 2 + 0.06), Vector3(0, -0.1, 0),
		_mat(Color(0.8, 0.62, 0.25), 0.4, 0.8), "Trim")

	# Canvas markings: boundary stripe + logo + corner wedges
	var stripe := _mat(Color(0.86, 0.82, 0.74), 0.9)
	var sh := 3.05
	for n: Vector3 in SIDES:
		var along_x := absf(n.x) > 0.5
		var sz := Vector3(0.07, 0.006, sh * 2 + 0.07) if along_x else Vector3(sh * 2 + 0.07, 0.006, 0.07)
		_box(ring, sz, n * sh + Vector3(0, 0.003, 0), stripe, "Stripe")
	var logo := Label3D.new()
	logo.name = "Logo"
	logo.text = "KNOCKNIGHT"
	logo.font_size = 260
	logo.pixel_size = 0.0045
	logo.modulate = Color(0.93, 0.88, 0.8, 0.9)
	logo.outline_size = 0
	logo.double_sided = false
	logo.rotation_degrees = Vector3(-90, 0, 0)
	logo.position = Vector3(0, 0.008, 0)
	ring.add_child(logo)
	var wedge_cols := [Color(0.72, 0.13, 0.12), Color(0.15, 0.32, 0.7)]
	for i in 2:
		var w := _box(ring, Vector3(0.9, 0.006, 0.9), Vector3(-2.55 if i == 0 else 2.55, 0.003, 2.55 if i == 0 else -2.55), _mat(wedge_cols[i], 0.9), "CornerWedge%d" % i)
		w.rotation_degrees.y = 45

	# Posts
	var steel := _mat(Color(0.1, 0.1, 0.115), 0.35, 0.9)
	var pad_cols := [Color(0.78, 0.14, 0.12), Color(0.17, 0.36, 0.78), Color(0.88, 0.85, 0.8), Color(0.88, 0.85, 0.8)]
	var corners := [Vector2(-1, 1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, -1)]
	for i in 4:
		var c: Vector2 = corners[i]
		var p := Vector3(c.x * ROPE_HALF, 0, c.y * ROPE_HALF)
		var post_nodes: Array = []
		post_nodes.append(_cyl(ring, 0.075, 1.75, p + Vector3(0, 0.875, 0), steel, "Post%d" % i))
		post_nodes.append(_cyl(ring, 0.13, 1.1, p + Vector3(0, 0.9, 0), _mat(pad_cols[i], 0.75), "PostPad%d" % i, 16))
		post_nodes.append(_cyl(ring, 0.1, 0.06, p + Vector3(0, 1.78, 0), steel, "PostCap%d" % i))
		for h: float in ROPE_HEIGHTS:
			post_nodes.append(_cyl(ring, 0.05, 0.1, p + Vector3(0, h, 0), steel, "Turnbuckle", 10))
		_posts.append({"p": Vector2(p.x, p.z), "nodes": post_nodes, "fade": 0.0})

	# Ropes grouped per side so they can fade independently
	var rope_cols := [Color(0.8, 0.14, 0.12), Color(0.9, 0.87, 0.82), Color(0.8, 0.14, 0.12), Color(0.9, 0.87, 0.82)]
	var strap := _mat(Color(0.88, 0.85, 0.78), 0.8)
	for n: Vector3 in SIDES:
		var key := Vector2i(int(n.x), int(n.z))
		var list: Array = []
		var along_x := absf(n.x) > 0.5
		for r in ROPE_HEIGHTS.size():
			var rope := _cyl(ring, 0.028, ROPE_HALF * 2.0, n * ROPE_HALF + Vector3(0, ROPE_HEIGHTS[r], 0),
				_mat(rope_cols[r], 0.55), "Rope", 10)
			if along_x:
				rope.rotation_degrees.x = 90
			else:
				rope.rotation_degrees.z = 90
			list.append(rope)
		for s in [-1.1, 1.1]:
			var sz := Vector3(0.02, 1.0, 0.06) if along_x else Vector3(0.06, 1.0, 0.02)
			var off := Vector3(0, 0.9, s) if along_x else Vector3(s, 0.9, 0)
			list.append(_box(ring, sz, n * ROPE_HALF + off, strap, "Strap"))
		_side_nodes[key] = list
		_side_fade[key] = 0.0

	_build_ringside(ring)


func _build_ringside(parent: Node) -> void:
	var dark := _mat(Color(0.06, 0.065, 0.075), 0.5, 0.2)
	var trim := _mat(Color(0.8, 0.62, 0.25), 0.4, 0.8)
	var h := 6.6
	for n: Vector3 in SIDES:
		var along_x := absf(n.x) > 0.5
		var sz := Vector3(0.12, 0.9, h * 2) if along_x else Vector3(h * 2, 0.9, 0.12)
		_box(parent, sz, n * h + Vector3(0, GROUND_Y + 0.45, 0), dark, "Barricade")
		var tsz := Vector3(0.16, 0.04, h * 2 + 0.04) if along_x else Vector3(h * 2 + 0.04, 0.04, 0.16)
		_box(parent, tsz, n * h + Vector3(0, GROUND_Y + 0.92, 0), trim, "BarricadeTrim")
	for i in 4:
		var a := deg_to_rad(45 + 90 * i)
		var p := Vector3(cos(a), 0, sin(a)) * 5.2
		_box(parent, Vector3(1.2, 0.05, 0.6), p + Vector3(0, GROUND_Y + 0.7, 0), dark, "Table")
		_box(parent, Vector3(1.1, 0.7, 0.5), p + Vector3(0, GROUND_Y + 0.35, 0), dark, "TableBody")


# --- lights ----------------------------------------------------------------------------

func _build_lights() -> void:
	var rig := Node3D.new()
	rig.name = "LightRig"
	add_child(rig)
	var truss := _mat(Color(0.08, 0.08, 0.09), 0.4, 0.9)
	var h := 7.6
	var r := 4.4
	for n: Vector3 in SIDES:
		var along_x := absf(n.x) > 0.5
		var sz := Vector3(0.18, 0.18, r * 2) if along_x else Vector3(r * 2, 0.18, 0.18)
		_box(rig, sz, n * r + Vector3(0, h, 0), truss, "Truss")
	var lamp_glow := _mat(Color(1, 0.95, 0.85), 0.3, 0.0, Color(1, 0.92, 0.78), 6.0)
	var i := 0
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var pos := Vector3(sx * r, h - 0.1, sz * r)
			var aim := Vector3(-sx * 0.6, 0.0, -sz * 0.6)
			var spot := SpotLight3D.new()
			spot.name = "Spot%d" % i
			spot.light_color = Color(1.0, 0.93, 0.82)
			spot.light_energy = 14.0
			spot.spot_range = 20.0
			spot.spot_angle = 30.0
			spot.spot_angle_attenuation = 0.8
			spot.shadow_enabled = i < 2
			spot.shadow_bias = 0.04
			spot.light_volumetric_fog_energy = 1.2
			add_child(spot)
			spot.look_at_from_position(pos, aim, Vector3.UP)
			var can := _box(rig, Vector3(0.45, 0.35, 0.45), pos, truss, "LampCan")
			can.look_at_from_position(pos, aim, Vector3.UP)
			var lens := _cyl(rig, 0.17, 0.04, pos + (aim - pos).normalized() * 0.25, lamp_glow, "Lens", 12)
			lens.look_at_from_position(lens.position, aim, Vector3.UP)
			lens.rotate_object_local(Vector3.RIGHT, PI * 0.5)
			i += 1
	var fill := OmniLight3D.new()
	fill.name = "TopFill"
	fill.position = Vector3(0, 5.0, 0)
	fill.light_energy = 1.6
	fill.omni_range = 14.0
	fill.light_color = Color(0.85, 0.9, 1.0)
	add_child(fill)


# --- crowd -----------------------------------------------------------------------------

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	var face := (b - a).cross(c - a)
	# Godot front faces are clockwise; flip when the geometric normal disagrees
	var pts := [a, c, b] if face.dot(n) >= 0.0 else [a, b, c]
	for p: Vector3 in pts:
		st.set_normal(n)
		st.add_vertex(p)


func _annulus(r0: float, r1: float, y0: float, y1: float, segs: int, mat: Material, parent: Node) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in segs:
		var a0 := TAU * s / segs
		var a1 := TAU * (s + 1) / segs
		var p00 := Vector3(cos(a0) * r0, y1, sin(a0) * r0)
		var p01 := Vector3(cos(a1) * r0, y1, sin(a1) * r0)
		var p10 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
		var p11 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
		_tri(st, p00, p10, p11, Vector3.UP)
		_tri(st, p00, p11, p01, Vector3.UP)
		var b00 := Vector3(p00.x, y0, p00.z)
		var b01 := Vector3(p01.x, y0, p01.z)
		var nrm := -Vector3(cos((a0 + a1) * 0.5), 0, sin((a0 + a1) * 0.5))
		_tri(st, b00, p00, p01, nrm)
		_tri(st, b00, p01, b01, nrm)
	var mi := MeshInstance3D.new()
	mi.name = "Tier"
	mi.mesh = st.commit()
	mi.material_override = mat
	parent.add_child(mi)


func _build_crowd() -> void:
	var crowd := Node3D.new()
	crowd.name = "Crowd"
	add_child(crowd)
	var tier_mat := _mat(Color(0.045, 0.047, 0.055), 0.8)
	var tiers := 7
	var r_start := 10.0
	var depth := 1.5
	var rise := 0.65
	var torso_xf: Array[Transform3D] = []
	var head_xf: Array[Transform3D] = []
	var torso_col: Array[Color] = []
	var head_col: Array[Color] = []
	var shirt := [Color(0.07, 0.07, 0.09), Color(0.12, 0.05, 0.05), Color(0.05, 0.07, 0.12), Color(0.1, 0.1, 0.1),
		Color(0.14, 0.12, 0.08), Color(0.06, 0.09, 0.07), Color(0.18, 0.18, 0.2), Color(0.22, 0.08, 0.06)]
	var skin := [Color(0.34, 0.22, 0.16), Color(0.22, 0.14, 0.1), Color(0.45, 0.3, 0.22), Color(0.12, 0.08, 0.06), Color(0.5, 0.36, 0.28)]
	for k in tiers:
		var r0 := r_start + depth * k
		var y_top := GROUND_Y + 0.55 + rise * k
		_annulus(r0, r0 + depth, y_top - rise, y_top, 48, tier_mat, crowd)
		var rc := r0 + depth * 0.55
		var count := int(TAU * rc / 0.62)
		for j in count:
			var a := TAU * (j + _rng.randf() * 0.6) / count
			var rr := rc + _rng.randf_range(-0.25, 0.25)
			var p := Vector3(cos(a) * rr, y_top, sin(a) * rr)
			var s := _rng.randf_range(0.9, 1.12)
			var bas := Basis(Vector3.UP, -a + PI * 0.5).scaled(Vector3(s, s, s))
			torso_xf.append(Transform3D(bas, p + Vector3(0, 0.62 * s, 0)))
			head_xf.append(Transform3D(bas, p + Vector3(0, 1.2 * s, 0)))
			torso_col.append(shirt[_rng.randi() % shirt.size()])
			head_col.append(skin[_rng.randi() % skin.size()])
	var torso_mesh := CapsuleMesh.new()
	torso_mesh.radius = 0.2
	torso_mesh.height = 0.95
	torso_mesh.radial_segments = 8
	torso_mesh.rings = 2
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.12
	head_mesh.height = 0.24
	head_mesh.radial_segments = 8
	head_mesh.rings = 4
	crowd.add_child(_multi(torso_mesh, torso_xf, torso_col, "Torsos"))
	crowd.add_child(_multi(head_mesh, head_xf, head_col, "Heads"))

	# Phone-flash sparkles scattered across the crowd
	var flash_mesh := QuadMesh.new()
	flash_mesh.size = Vector2(0.22, 0.22)
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.vertex_color_use_as_albedo = true
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	var rg := Gradient.new()
	rg.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	rg.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.5), Color(1, 1, 1, 0)])
	var rt := GradientTexture2D.new()
	rt.gradient = rg
	rt.fill = GradientTexture2D.FILL_RADIAL
	rt.fill_from = Vector2(0.5, 0.5)
	rt.fill_to = Vector2(1.0, 0.5)
	rt.width = 64
	rt.height = 64
	fm.albedo_texture = rt
	_flash_mm = MultiMesh.new()
	_flash_mm.transform_format = MultiMesh.TRANSFORM_3D
	_flash_mm.use_colors = true
	_flash_mm.mesh = flash_mesh
	_flash_mm.instance_count = 90
	for i in 90:
		var k := _rng.randi() % tiers
		var a := _rng.randf() * TAU
		var rr := r_start + depth * k + depth * 0.55
		var y := GROUND_Y + 0.55 + rise * k + 1.0
		_flash_mm.set_instance_transform(i, Transform3D(Basis(), Vector3(cos(a) * rr, y, sin(a) * rr)))
		_flash_mm.set_instance_color(i, Color(0, 0, 0, 0))
	var fmi := MultiMeshInstance3D.new()
	fmi.name = "Flashes"
	fmi.multimesh = _flash_mm
	fmi.material_override = fm
	fmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	crowd.add_child(fmi)

	for i in 4:
		var a := deg_to_rad(90.0 * i + 45.0)
		var dir := Vector3(cos(a), 0, sin(a))
		var holder := Node3D.new()
		holder.name = "Banner%d" % i
		crowd.add_child(holder)
		holder.look_at_from_position(dir * 13.0 + Vector3(0, 9.0, 0), Vector3(0, 9.0, 0), Vector3.UP)
		_box(holder, Vector3(7.5, 2.1, 0.12), Vector3.ZERO, _mat(Color(0.02, 0.02, 0.025), 0.3, 0.5), "Panel")
		var lbl := Label3D.new()
		lbl.text = "KNOCKNIGHT"
		lbl.font_size = 160
		lbl.pixel_size = 0.0105
		lbl.modulate = Color(1.0, 0.8, 0.34)
		lbl.shaded = false
		lbl.double_sided = false
		lbl.position = Vector3(0, 0, 0.08)
		lbl.rotation_degrees.y = 180
		holder.add_child(lbl)
		var edge := _mat(Color(1, 0.78, 0.34), 0.4, 0.0, Color(1, 0.7, 0.25), 2.5)
		_box(holder, Vector3(7.6, 0.07, 0.14), Vector3(0, -1.08, 0), edge, "EdgeBottom")
		_box(holder, Vector3(7.6, 0.07, 0.14), Vector3(0, 1.08, 0), edge, "EdgeTop")


func _multi(mesh: Mesh, xfs: Array[Transform3D], cols: Array[Color], nm: String) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
		mm.set_instance_color(i, cols[i])
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	var mi := MultiMeshInstance3D.new()
	mi.name = nm
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _update_flashes() -> void:
	var n := _flash_mm.instance_count
	for i in 5:
		_flash_mm.set_instance_color(_rng.randi() % n, Color(4.0, 3.8, 3.2, 1.0))
	for i in 8:
		_flash_mm.set_instance_color(_rng.randi() % n, Color(0, 0, 0, 0))
