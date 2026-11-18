#!/bin/bash
# usage: tools/run_probe.sh <tag>   runs the hit probe: 3 scripted fighter pairs + the 90 s CPU fight in parallel, then the report.
# Output: _build/hits/probe_<tag>_*.jsonl and _build/hits/report_<tag>.md
G="C:/Users/trayn/Tools/godot-4.7.2/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe"
TAG=${1:-run}
shift
mkdir -p _build/hits
for pair in meshy_viper:meshy_oak meshy_oak:meshy_anvil meshy_anvil:meshy_viper; do
  n=$(echo $pair | tr ':' '_')
  "$G" --headless --fixed-fps 120 --path . --script res://tools/probe_hits.gd -- pair=$pair mode=scripted out=${TAG}_$n "$@" > _build/hits/log_${TAG}_$n.txt 2>&1 &
done
"$G" --headless --fixed-fps 120 --path . --script res://tools/probe_hits.gd -- mode=cpu cpu_pair=meshy_viper:meshy_oak out=${TAG}_cpu > _build/hits/log_${TAG}_cpu.txt 2>&1 &
wait
python -I tools/probe_hits_report.py _build/hits/probe_${TAG}_*.jsonl --md _build/hits/report_${TAG}.md > /dev/null
echo "done: _build/hits/report_${TAG}.md"
