#!/bin/bash
# runs the six KO captures (windowed). usage: tools/run_ko_captures.sh
G="C:/Users/trayn/Tools/godot-4.7.2/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe"
run() { timeout 110 "$G" --path . --script res://tools/capture_ko.gd -- "$@" 2>&1 | grep "p2 pos"; }
run punch=LJab tag=ko_jab
run punch=RJab tag=ko_cross
run punch=LHook tag=ko_hookL
run punch=RHook tag=ko_hookR gap=0.8 off=0.25
run punch=RUppercut tag=ko_upper gap=0.75
run punch=RBodyHook tag=ko_body mode=body gap=0.8
