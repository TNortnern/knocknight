extends RefCounted
## CPU stamina management helpers (fatigue pass). Preload, don't reference by class name.
##   - recovering(): hysteresis so the CPU backs off with its guard up when gassed and only re-engages once it has caught its breath
##   - tame(): a tired CPU throws jabs, not hooks / uppercuts (and a gassed one cannot throw power anyway)
##   - foe_tired(): a gassed opponent is pressed (same pocket / power-shot behaviour as for a rocked one)

const ENTER := 0.27          ## start recovering below this stamina ratio
const EXIT := 0.55           ## resume fighting above this
const TAME_BELOW := 0.40     ## below this ratio power shots are swapped for jabs
const FOE_TIRED := 0.28      ## the foe is "tired" below this ratio...
const SELF_OK := 0.45        ## ...and we press it only while we ourselves still have this much


static func recovering(was: bool, ratio: float) -> bool:
	if was:
		return ratio < EXIT
	return ratio < ENTER


static func tame(tag: String, ratio: float, rng: RandomNumberGenerator) -> String:
	if ratio >= TAME_BELOW:
		return tag
	if tag.contains("Hook") or tag.contains("Uppercut") or tag.contains("Kick"):
		var body := tag.contains("Body")
		var side := "L" if tag.begins_with("L") else "R"
		if rng.randf() < 0.75:
			return side + ("BodyJab" if body else "Jab")
	return tag


static func foe_tired(foe: Object, own_ratio: float) -> bool:
	if foe == null or own_ratio < SELF_OK:
		return false
	return foe.stats.stamina_ratio() < FOE_TIRED and not foe.stats.infinite_stamina
