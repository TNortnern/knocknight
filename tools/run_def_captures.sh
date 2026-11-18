#!/bin/bash
# usage: tools/run_def_captures.sh <out_dir_name e.g. before> <model> [view] [clips...]
G="C:/Users/trayn/Tools/godot-4.7.2/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe"
ROOT="${DEF_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
OUT="${DEF_OUT:-$ROOT/_build/def}/$1"; MODEL=$2; VIEW=${3:-game}; shift 3
CLIPS=${@:-"idle hold_q hold_e switch_qe switch_qeq switch_overlap tap_q tap_e tap_qe duck duck_q duck_e duck_switch slip_duck back"}
cd "$ROOT"
for c in $CLIPS; do
  "$G" --path . --fixed-fps 120 --script res://tools/capture_defence_play.gd -- model=$MODEL clip=$c view=$VIEW out=$OUT 2>&1 | grep -E "capture_defence_play|ERROR|SCRIPT" 
done
