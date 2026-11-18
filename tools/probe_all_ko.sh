#!/bin/bash
# prints the REST line of the six scripted KOs at 3 stances each (headless). usage: tools/probe_all_ko.sh
G="C:/Users/trayn/Tools/godot-4.7.2/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe"
run() { timeout 100 "$G" --headless --fixed-fps 120 --path . --script res://tools/probe_ko.gd -- "$@" 2>&1 | grep -E "^REST|ERROR|SCRIPT" | tr '\n' ' '; echo; }
for v in "gap=0.85 off=0.0" "gap=0.75 off=0.25" "gap=0.95 off=-0.2"; do
run punch=LJab $v
run punch=RJab $v
run punch=LHook $v
run punch=RHook $v
run punch=RUppercut $v
run punch=RBodyHook mode=body $v
done
