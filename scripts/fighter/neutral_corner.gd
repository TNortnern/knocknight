extends RefCounted
## Neutral corners of the square ring: the two corners that are not the fighters' own (red (-,+) and blue (+,-),
## see arena.gd wedges), i.e. (-,-) and (+,+). During a count the standing fighter walks to the nearer one.

const INSET := 2.35


static func pick(standing: Vector3, downed: Vector3) -> Vector3:
	var best := Vector3.INF
	var best_score := -1e9
	for c in [Vector2(-1, -1), Vector2(1, 1)]:
		var p := Vector3(c.x * INSET, 0.0, c.y * INSET)
		var score := -Vector2(p.x - standing.x, p.z - standing.z).length() + 0.35 * Vector2(p.x - downed.x, p.z - downed.z).length()
		if score > best_score:
			best_score = score
			best = p
	return best
