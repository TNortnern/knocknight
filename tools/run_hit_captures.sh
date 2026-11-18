#!/bin/bash
# usage: tools/run_hit_captures.sh   (windowed) captures the evidence cases to _build/hits/frames/<case>_NNN.png, then make_hits_sheet2.py builds the sheets
G="C:/Users/trayn/Tools/godot-4.7.2/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe"
cap() { "$G" --fixed-fps 120 --path . --script res://tools/capture_hits.gd -- case=$1 att=$2 foe=$3 tag=$4 gap=$5 state=$6 ${7:-} 2>&1 | grep "^captured"; }
cap head_jab meshy_viper meshy_oak LJab 1.0 idle
cap head_hook meshy_viper meshy_oak RHook 0.95 idle
cap uppercut meshy_oak meshy_anvil LUppercut 0.9 idle
cap body_hit meshy_viper meshy_oak LBodyHook 0.9 idle
cap blocked meshy_viper meshy_oak LJab 1.0 block
cap glance meshy_viper meshy_oak RJab 0.9 idle
cap slip_hook meshy_viper meshy_oak RHook 1.2 slip
cap body_block meshy_viper meshy_oak LBodyHook 0.9 block body=1
