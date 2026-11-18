extends RefCounted
## Stand-in for the hit_flinch layer (scripts/fighter/hit_flinch.gd, liveliness branch): lets fight_stats / tests run the
## "flinch instead of hit clip" path before that layer exists. Counts the kicks it receives.
var kicks := 0

func kick(_dir: Vector3, _punch_dir: String, _zone: String, _strength: float) -> void:
	kicks += 1
