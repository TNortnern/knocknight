"""Body-mechanics curves for a slip: reference video frames vs game capture frames, measured with the same 2D pose model.

usage: python -I posecurves.py --model pose_landmarker_full.task --ref-dir REFCACHE_DIR --ref-crop x,y,w,h
                               --game-dir CAPTURE_DIR --game-start S --game-crop x,y,w,h --dur D --out PREFIX --title TEXT
Writes PREFIX.csv and PREFIX.png. Everything is in body units: lengths are divided by that side's own frame-0 torso length
(shoulder-mid to hip-mid), so the two characters / cameras compare directly. Screen x: + = screen-right, y: + = down.
Analysis aid for tuning shape and timing; the graders still judge the pixels.
"""
import argparse, csv, glob, math, os
import mediapipe as mp
from mediapipe.tasks import python as mpt
from mediapipe.tasks.python import vision
from PIL import Image
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

FPS = 30
NOSE, LEYE, REYE, LEAR, REAR, LSH, RSH, LWR, RWR, LHIP, RHIP, LKNEE, RKNEE, LANK, RANK = 0, 2, 5, 7, 8, 11, 12, 15, 16, 23, 24, 25, 26, 27, 28
METRICS = [
    ("head_rel_x", "head x from hip-mid (torso lengths)"),
    ("head_rel_y", "head y from hip-mid (torso lengths, + down)"),
    ("head_drop", "head drop since frame 0 (torso lengths)"),
    ("hip_x", "hip-mid x since frame 0 (torso lengths)"),
    ("hip_drop", "hip-mid drop since frame 0 (torso lengths)"),
    ("trunk_lat", "trunk lean from vertical, screen plane (deg, + = top to screen-right)"),
    ("sh_tilt", "shoulder line tilt (deg, + = screen-right shoulder lower)"),
    ("head_tilt", "eye line tilt (deg, + = screen-right eye lower)"),
    ("neck_len", "head to shoulder-mid distance (torso lengths)"),
    ("knee_l", "left knee angle (deg, 180 = straight)"),
    ("knee_r", "right knee angle (deg, 180 = straight)"),
    ("wrist_sl_x", "screen-left wrist x from shoulder-mid (torso lengths)"),
    ("wrist_sl_y", "screen-left wrist y from shoulder-mid (torso lengths, + down)"),
    ("wrist_sr_x", "screen-right wrist x from shoulder-mid (torso lengths)"),
    ("wrist_sr_y", "screen-right wrist y from shoulder-mid (torso lengths, + down)"),
    ("t3_roll", "3D trunk roll change since frame 0 (deg, pose-model world coords)"),
    ("t3_pitch", "3D trunk pitch change since frame 0 (deg, + = top away from camera)"),
    ("t3_yaw", "3D shoulder-line yaw change since frame 0 (deg)"),
    ("t3_neck", "3D hip-shoulder-head angle (deg, 180 = head in line with trunk)"),
]


def crop_box(s):
    x, y, w, h = [int(v) for v in s.split(",")]
    return (x, y, x + w, y + h)


def measure(model, frames, box):
    opts = vision.PoseLandmarkerOptions(base_options=mpt.BaseOptions(model_asset_path=model),
                                        running_mode=vision.RunningMode.VIDEO, num_poses=1,
                                        min_pose_detection_confidence=0.3, min_tracking_confidence=0.3)
    out = []
    with vision.PoseLandmarker.create_from_options(opts) as lm:
        for i, f in enumerate(frames):
            im = Image.open(f).convert("RGB").crop(box)
            w, h = im.size
            r = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=np.asarray(im)), int(i * 1000 / FPS))
            if not r.pose_landmarks:
                out.append(None)
                continue
            L = r.pose_landmarks[0]
            row = [(p.x * w, p.y * h, p.visibility) for p in L]
            row.append(np.array([[p.x, p.y, p.z] for p in r.pose_world_landmarks[0]]) if r.pose_world_landmarks else None)
            out.append(row)
    return out


def pt(L, i):
    return np.array(L[i][:2])


def mid(L, a, b):
    return (pt(L, a) + pt(L, b)) * 0.5


def ang(a, b, c):
    v1, v2 = a - b, c - b
    return math.degrees(math.acos(np.clip(np.dot(v1, v2) / (np.linalg.norm(v1) * np.linalg.norm(v2) + 1e-9), -1, 1)))


def curves(lms):
    first = next((L for L in lms if L is not None), None)
    if first is None:
        return []
    hip0, sh0 = mid(first, LHIP, RHIP), mid(first, LSH, RSH)
    T0 = np.linalg.norm(sh0 - hip0)
    head0 = (pt(first, NOSE) + pt(first, LEAR) + pt(first, REAR)) / 3.0
    t3_0 = None
    rows = []
    for L in lms:
        if L is None:
            rows.append({k: float("nan") for k, _ in METRICS})
            continue
        hip, sh = mid(L, LHIP, RHIP), mid(L, LSH, RSH)
        head = (pt(L, NOSE) + pt(L, LEAR) + pt(L, REAR)) / 3.0
        # screen-right / screen-left points by x, so the tilt sign does not depend on which way the fighter faces
        s_a, s_b = sorted([pt(L, LSH), pt(L, RSH)], key=lambda p: p[0])
        e_a, e_b = sorted([pt(L, LEYE), pt(L, REYE)], key=lambda p: p[0])
        tr = sh - hip
        row = {
            "head_rel_x": (head[0] - hip[0]) / T0, "head_rel_y": (head[1] - hip[1]) / T0,
            "head_drop": (head[1] - head0[1]) / T0,
            "hip_x": (hip[0] - hip0[0]) / T0, "hip_drop": (hip[1] - hip0[1]) / T0,
            "trunk_lat": math.degrees(math.atan2(tr[0], -tr[1])),
            "sh_tilt": math.degrees(math.atan2(s_b[1] - s_a[1], s_b[0] - s_a[0])),
            "head_tilt": math.degrees(math.atan2(e_b[1] - e_a[1], e_b[0] - e_a[0])),
            "neck_len": np.linalg.norm(head - sh) / T0,
        }
        for side, (a, b, c) in (("knee_l", (LHIP, LKNEE, LANK)), ("knee_r", (RHIP, RKNEE, RANK))):
            vis = min(L[a][2], L[b][2], L[c][2])
            row[side] = ang(pt(L, a), pt(L, b), pt(L, c)) if vis > 0.5 else float("nan")
        w_a, w_b = sorted([pt(L, LWR), pt(L, RWR)], key=lambda p: p[0])
        row["wrist_sl_x"], row["wrist_sl_y"] = (w_a[0] - sh[0]) / T0, (w_a[1] - sh[1]) / T0
        row["wrist_sr_x"], row["wrist_sr_y"] = (w_b[0] - sh[0]) / T0, (w_b[1] - sh[1]) / T0
        W = L[-1]
        if W is not None:
            t = (W[LSH] + W[RSH]) / 2 - (W[LHIP] + W[RHIP]) / 2
            sl = W[LSH] - W[RSH]
            a3 = (math.degrees(math.atan2(t[0], -t[1])), math.degrees(math.atan2(t[2], -t[1])), math.degrees(math.atan2(sl[2], sl[0])))
            if t3_0 is None:
                t3_0 = a3
            row["t3_roll"], row["t3_pitch"] = a3[0] - t3_0[0], a3[1] - t3_0[1]
            row["t3_yaw"] = (a3[2] - t3_0[2] + 180.0) % 360.0 - 180.0
            hd = (W[LEAR] + W[REAR]) / 2
            row["t3_neck"] = ang(W[LHIP] / 2 + W[RHIP] / 2, (W[LSH] + W[RSH]) / 2, hd)
        else:
            for k in ("t3_roll", "t3_pitch", "t3_yaw", "t3_neck"):
                row[k] = float("nan")
        rows.append(row)
    return rows


def main():
    ap = argparse.ArgumentParser()
    for k in ("--model", "--ref-dir", "--ref-crop", "--game-dir", "--game-crop", "--out"):
        ap.add_argument(k, required=True)
    ap.add_argument("--game-start", type=float, required=True)
    ap.add_argument("--dur", type=float, required=True)
    ap.add_argument("--title", default="")
    a = ap.parse_args()
    n = int(round(a.dur * FPS)) + 1
    rf = sorted(glob.glob(os.path.join(a.ref_dir, "f_*.png")))[:n]
    gf = sorted(f for f in glob.glob(os.path.join(a.game_dir, "*.png")) if "_sheet" not in f and "preview" not in f)
    g0 = int(round(a.game_start * FPS))
    gf = gf[g0:g0 + n]
    ref = curves(measure(a.model, rf, crop_box(a.ref_crop)))
    game = curves(measure(a.model, gf, crop_box(a.game_crop)))
    with open(a.out + ".csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["t"] + ["ref_" + k for k, _ in METRICS] + ["game_" + k for k, _ in METRICS])
        for i in range(max(len(ref), len(game))):
            r = ref[i] if i < len(ref) else {}
            g = game[i] if i < len(game) else {}
            w.writerow(["%.3f" % (i / FPS)] + ["%.3f" % r.get(k, float("nan")) for k, _ in METRICS]
                       + ["%.3f" % g.get(k, float("nan")) for k, _ in METRICS])
    fig, axs = plt.subplots(5, 4, figsize=(19, 16))
    for ax, (k, label) in zip(axs.flat, METRICS):
        ax.plot([i / FPS for i in range(len(ref))], [r[k] for r in ref], "-o", ms=3, color="#d08020", label="REFERENCE")
        ax.plot([i / FPS for i in range(len(game))], [g[k] for g in game], "--s", ms=3, color="#2080d0", label="CURRENT")
        ax.set_title(label, fontsize=9)
        ax.grid(alpha=0.3)
    axs.flat[0].legend(fontsize=8)
    axs.flat[-1].axis("off")
    fig.suptitle(a.title + "  (pose-model curves, time from clip start, s)")
    fig.tight_layout()
    fig.savefig(a.out + ".png", dpi=80)
    print("wrote", a.out + ".png", "ref frames", len(rf), "detected", sum(1 for r in ref if not math.isnan(r["trunk_lat"])),
          "game frames", len(gf), "detected", sum(1 for g in game if not math.isnan(g["trunk_lat"])))


if __name__ == "__main__":
    main()
