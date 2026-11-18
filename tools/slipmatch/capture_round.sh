#!/bin/bash
# usage: capture_round.sh ROUND   -> captures into $SP/rounds/rROUND/{front_a,front_b,rear_c}/ and builds composites
# Fixed: model, cameras, resolution, input timeline, --fixed-fps 120 (deterministic).
set -e
R=$1
WT="$(cd "$(dirname "$0")/../.." && pwd)"
G="C:/Users/trayn/Tools/godot-4.7.2/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe"
REF="$WT/reference/fightnight4-slip-dodge-short.mp4"
OUT="$WT/_build/slipmatch/r$R"
mkdir -p "$OUT"
cd "$WT"
cap() { # name scenario release extra...
  local name=$1 sc=$2 rel=$3; shift 3
  rm -rf "$OUT/$name"
  timeout 600 "$G" --path . --fixed-fps 120 --script res://tools/capture_fn_match.gd -- scenario=$sc model=meshy_anvil \
    out="$OUT/$name" fps=30 start=0.2 release=$rel width=720 height=1280 "$@" > "$OUT/$name.log" 2>&1 || true
  grep -E "SCRIPT ERROR|Parse Error" "$OUT/$name.log" | head -5 || true
  ls "$OUT/$name"/*.png > /dev/null 2>&1 || { echo "capture $name FAILED"; tail -5 "$OUT/$name.log"; }
}
FRONT="solo=true view=front yaw=6 elevation=0 fullbody=false look_y=1.40 dist=1.80"   # r6: reference figure scale + placement; r9: look_y 1.46 -> 1.40 (the loaded stance sits the head ~6 cm lower); r10: yaw 0 -> 6 (chest squarer, as in the reference; larger yaws hide the face behind the lead glove); r10: the A input is 0.15 s earlier (onset alignment, same ramp)
SCEN_A=slip_r; SCEN_B=slip_l
REF_CROP_FRONT=0,160,1080,1600; GAME_CROP_FRONT=0,107,720,1067
REF_CROP_REAR=${REF_CROP_REAR:-0,0,1080,1920}; GAME_CROP_REAR=${GAME_CROP_REAR:-0,0,720,1280}
cap front_a $SCEN_A 0.90 seconds=1.6 start=0.05 lean_ramp=0.30 release_ramp=0.06 $FRONT shift_x=-0.16   # human thumb: stick eases in/out (round 2 setup fix)
cap front_b $SCEN_B 0.65 seconds=1.4 lean_ramp=0.25 release_ramp=0.06 $FRONT shift_x=-0.03
# r8/r9: the opponent throws the jab the fighter slips under; r9: the whole C input is 0.06 s earlier (onset alignment only, motion speed unchanged)
cap rear_c slip_l 0.27 seconds=0.8 amplitude=0.85 lean_fwd=0.55 view=reference yaw=50 side=-1 elevation=38 start=0.14 opponent_tag=LJab opponent_time=0.05
C="python -I $WT/tools/slipmatch/slipcomp.py --ref $REF --cache $WT/_build/slipmatch/_refcache"
$C --ref-start 22.85 --dur 1.40 --ref-crop $REF_CROP_FRONT --game "$OUT/front_a" --game-start 0.10 --game-crop $GAME_CROP_FRONT --out "$OUT/A_front_slip" --title "A: front view, slip (head to screen-left), held"
$C --ref-start 24.40 --dur 1.00 --ref-crop $REF_CROP_FRONT --game "$OUT/front_b" --game-start 0.18 --game-crop $GAME_CROP_FRONT --out "$OUT/B_front_slip" --title "B: front view, quick slip (head to screen-right)"
$C --ref-start 4.70 --dur 0.60 --ref-crop $REF_CROP_REAR --game "$OUT/rear_c" --game-start 0.00 --game-crop $GAME_CROP_REAR --out "$OUT/C_rear_slip" --title "C: rear 3/4 view, slip under a punch"
echo "round $R captures + composites in $OUT"
# Body-mechanics curves (pose model, same on both sides): analysis aid for the executor; graders see only the composites.
PM=_build/slipmatch/_models/pose_landmarker_full.task
if [ -f "$PM" ]; then
  # measurement-only front captures: wider full-upper-body framing so the pose model sees the whole trunk (composites keep the reference framing)
  MEAS="solo=true view=front yaw=6 elevation=0 fullbody=false look_y=1.40 dist=2.15 shift_x=-0.06"
  cap meas_a $SCEN_A 0.90 seconds=1.6 start=0.05 lean_ramp=0.30 release_ramp=0.06 $MEAS
  cap meas_b $SCEN_B 0.65 seconds=1.4 lean_ramp=0.25 release_ramp=0.06 $MEAS
  # r10: motion in composite-cell units (what the graders see) from the composite captures themselves
  python -I tools/slipmatch/cellcurves.py "$PM" "$WT/_build/slipmatch/_refcache/ref_22.850_1.400" $REF_CROP_FRONT "$OUT/front_a" 0.10 $GAME_CROP_FRONT 1.4 > "$OUT/A_cell.txt" 2>&1 &
  python -I tools/slipmatch/cellcurves.py "$PM" "$WT/_build/slipmatch/_refcache/ref_24.400_1.000" $REF_CROP_FRONT "$OUT/front_b" 0.18 $GAME_CROP_FRONT 1.0 > "$OUT/B_cell.txt" 2>&1 &
  PC="python -I tools/slipmatch/posecurves.py --model $PM"
  $PC --ref-dir "$WT/_build/slipmatch/_refcache/ref_22.850_1.400" --ref-crop $REF_CROP_FRONT --game-dir "$OUT/meas_a" --game-start 0.10 --game-crop $GAME_CROP_FRONT --dur 1.40 --out "$OUT/A_curves" --title "A r$R" 2>&1 | grep wrote
  $PC --ref-dir "$WT/_build/slipmatch/_refcache/ref_24.400_1.000" --ref-crop $REF_CROP_FRONT --game-dir "$OUT/meas_b" --game-start 0.18 --game-crop $GAME_CROP_FRONT --dur 1.00 --out "$OUT/B_curves" --title "B r$R" 2>&1 | grep wrote
  $PC --ref-dir "$WT/_build/slipmatch/_refcache/ref_4.700_0.600" --ref-crop $REF_CROP_REAR --game-dir "$OUT/rear_c" --game-start 0.00 --game-crop $GAME_CROP_REAR --dur 0.60 --out "$OUT/C_curves" --title "C r$R" 2>&1 | grep wrote
fi
wait
