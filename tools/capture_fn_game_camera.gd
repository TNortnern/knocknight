extends "res://tools/capture_fn_match.gd"
## Capture-only: retain the real moving match camera while using the same deterministic input fixture.
func _freeze_live_camera() -> void:
 capture_cam = main.get("current_camera") as Camera3D
 if capture_cam == null:
  _fail("match did not expose its live camera")
  return
 capture_cam.make_current()

func _aim_static_camera() -> void:
 pass

func _update_capture_orbit(_tick: int) -> void:
 pass

func _camera_record() -> Dictionary:
 var doc: Dictionary = super._camera_record()
 doc["view"] = "actual FightCamera (live gameplay camera)"
 doc["static"] = false
 doc["framing"] = "actual gameplay"
 doc["orbit_approximation"] = {}
 return doc
