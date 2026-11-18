extends "res://tools/capture_fn_match.gd"
var transition := "release"
func _parse_args()->bool:
 for arg in OS.get_cmdline_user_args():
  if arg.begins_with("transition="): transition=arg.trim_prefix("transition=")
 return super._parse_args()
func _aim_static_camera()->void:
 super._aim_static_camera()
 capture_cam.fov=50.0
func _apply_input_tick(seq_name:String,tick:int)->void:
 super._apply_input_tick(seq_name,tick)
 if tick>=66:
  defender.external_input.lean=Vector2.ZERO
  if tick<108:
   match transition:
    "block": defender.external_input.block=true
    "right": defender.external_input.lean=Vector2(-1,0)
    "rapid": defender.external_input.lean=Vector2(-1,0) if tick<72 else Vector2(1,0)
    "block_pulse":
     if tick<72: defender.external_input.block=true
     else: defender.external_input.lean=Vector2(1,0)
    "duck": defender.external_input.duck=true
    "shell":
     defender.external_input.block=true
     defender.external_input.shell=true
    "backstep": defender.external_input.backstep=true
    "diagonal": defender.external_input.lean=Vector2(0.7071,0.7071)
 if tick==66: input_events.append({"tick":tick,"time":float(tick)/120.0,"control":"left to "+transition})
 if tick==108: input_events.append({"tick":tick,"time":float(tick)/120.0,"control":"release transition"})

func _frame_record(index:int,time_s:float,tick:int,image_path:String)->Dictionary:
 var row:Dictionary=super._frame_record(index,time_s,tick,image_path)
 if defender.authored_slip!=null:row["authored_combat_pose"]=defender.authored_slip.snapshot.duplicate(true)
 return row

func _fresh(pose_only:bool)->bool:
 var ok:bool=await super._fresh(pose_only)
 if ok and defender.authored_slip!=null:defender.authored_slip.record=true
 return ok
