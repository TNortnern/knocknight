extends RefCounted
## Sweat / spit burst on head hits (port of web impact.js ImpactSpray: gravity 4.8, sweat 1-2.3 m/s with 22-46 ms-ish life,
## spit 2-3.3 m/s, blue-white droplets). One short-lived CPUParticles3D per emitter, freed when it has played out.

static var _mesh: QuadMesh
static var _mat: StandardMaterial3D


static func _droplet_mesh() -> QuadMesh:
	if _mesh == null:
		_mat = StandardMaterial3D.new()
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_mat.billboard_keep_scale = true
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.vertex_color_use_as_albedo = true
		_mat.albedo_color = Color(0.82, 0.92, 1.0, 0.9)
		_mesh = QuadMesh.new()
		_mesh.size = Vector2(1, 1)
		_mesh.material = _mat
	return _mesh


## Emit `sweat` and `spit` droplets at `origin` travelling along `dir` (world space). Returns the nodes spawned.
static func emit(parent: Node, origin: Vector3, dir: Vector3, sweat: int, spit: int) -> Array:
	var out: Array = []
	if parent == null or not parent.is_inside_tree():
		return out
	if dir.length_squared() < 1e-8:
		dir = Vector3(0, 0, 1)
	dir = dir.normalized()
	if sweat > 0:
		out.append(_burst(parent, origin, dir, sweat, 1.0, 2.3, 0.010, 0.020, 0.22, 0.46, 40.0, 0.5))
	if spit > 0:
		out.append(_burst(parent, origin, dir, spit, 2.0, 3.3, 0.024, 0.036, 0.28, 0.46, 12.0, 0.0))
	return out


static func _burst(parent: Node, origin: Vector3, dir: Vector3, amount: int, v0: float, v1: float, s0: float, s1: float, l0: float, l1: float, spread: float, lift: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.mesh = _droplet_mesh()
	p.amount = maxi(1, amount)
	p.one_shot = true
	p.explosiveness = 1.0
	p.lifetime = l1
	p.lifetime_randomness = 1.0 - l0 / l1
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.05
	p.direction = dir + Vector3(0, lift * 0.3, 0)
	p.spread = spread
	p.initial_velocity_min = v0
	p.initial_velocity_max = v1
	p.gravity = Vector3(0, -4.8, 0)
	p.scale_amount_min = s0
	p.scale_amount_max = s1
	p.local_coords = false
	p.top_level = true
	parent.add_child(p)
	p.global_position = origin
	p.emitting = true
	var tree := parent.get_tree()
	if tree != null:
		tree.create_timer(l1 + 0.2).timeout.connect(func(): if is_instance_valid(p): p.queue_free())
	return p
