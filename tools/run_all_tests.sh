#!/bin/bash
# runs the whole test list; prints PASS/FAIL per test. usage: tools/run_all_tests.sh > _build/tests.log
G="C:/Users/trayn/Tools/godot-4.7.2/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe"
t() { local name=$1; shift; local out; out=$(timeout 900 "$G" --headless "$@" --path . --script res://tests/$name.gd 2>&1); local code=$?; echo "== $name exit=$code $(echo "$out" | grep -E '^(PASS|FAIL)' | tail -1)"; echo "$out" | grep -E "FAIL|SCRIPT ERROR|Parse Error" | head -8; }
for n in test_fighter_import test_combat_rules test_input_movement test_guard_style test_rocked test_menu_to_fight ui_flow_test test_rock_camera test_fight_sim test_defence_family test_lean test_knockdown test_fatigue test_punch_variety test_exchange test_commitment test_alive test_guard; do
  [ -f tests/$n.gd ] || continue
  t $n
done
t test_pose_limits --fixed-fps 120   # seeded ragdoll falls: wall-clock physics steps are not reproducible under load
t test_motion_smooth --fixed-fps 120
t test_camera_steady --fixed-fps 120
t test_ragdoll --fixed-fps 120
t test_meshy_roster --fixed-fps 120
t test_no_tpose --fixed-fps 120
t test_body_spacing --fixed-fps 120   # seeded CPU bouts
t test_body_contact --fixed-fps 120
t test_hit_contact --fixed-fps 120   # contact-only hits, volume fit to the visible mesh, body contact on touch
t test_hit_registration --fixed-fps 120   # visible contact always registers, every outcome is felt, no glove through the head, volumes on the visible skin
