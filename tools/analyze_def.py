"""python -I tools/analyze_def.py <capture_dir> [model ...]   (capture_dir = _build/def/before etc.)
Reads every <dir>/<model>/<clip>/trace.json (from tools/capture_defence_play.gd) and derives the defence metrics.
Writes <dir>/metrics.json and prints a table."""
import json, sys, os, math

d = sys.argv[1]
models = sys.argv[2:] or sorted(m for m in os.listdir(d) if os.path.isdir(os.path.join(d, m)))
HZ = 120.0


def load(m, c):
    p = os.path.join(d, m, c, "trace.json")
    return json.load(open(p)) if os.path.exists(p) else None


def first_cross(ts, vs, thr, t0, rising=True):
    for t, v in zip(ts, vs):
        if t >= t0 and ((v >= thr) if rising else (v <= thr)):
            return t
    return None


def head_dev(tr):
    rows = tr["rows"]
    t0 = min([e[0] for e in tr["events"]] or [0.4])
    base = [r for r in rows if r["t"] / HZ < t0 - 0.05]
    base = base[len(base) // 2:] or rows[:10]
    n = len(base)
    return rows, tuple(sum(r["head"][i] for r in base) / n for i in range(3))


def clip_metrics(tr):
    rows, b = head_dev(tr)
    for r in rows:
        if "neck_flex" not in r:
            r["neck_flex"] = math.degrees(math.atan2(r["head"][2] - r["neck"][2], r["head"][1] - r["neck"][1]) - math.atan2(r["shm"][2] - r["hips"][2], r["shm"][1] - r["hips"][1]))
    ts = [r["t"] / HZ for r in rows]
    dx = [r["head"][0] - b[0] for r in rows]
    dy = [r["head"][1] - b[1] for r in rows]
    dz = [r["head"][2] - b[2] for r in rows]
    dm = [math.sqrt(a * a + c * c + e * e) for a, c, e in zip(dx, dy, dz)]
    out = {"peak_dx": max(dx, key=abs), "peak_drop": -min(dy), "peak_dz": max(dz, key=abs), "peak_3d": max(dm)}
    ev = tr["events"]
    out["pen_max_cm"] = 100.0 * max(max(r["pen_l"]["torso"], r["pen_r"]["torso"]) for r in rows)
    out["pen_glove_cm"] = 100.0 * max(max(r["pen_l"]["glove_torso"], r["pen_r"]["glove_torso"]) for r in rows)
    out["pen_forearm_cm"] = 100.0 * max(max(r["pen_l"]["forearm_torso"], r["pen_r"]["forearm_torso"]) for r in rows)
    out["pen_head_cm"] = 100.0 * max(max(r["pen_l"]["head"], r["pen_r"]["head"]) for r in rows)
    out["pen_time_gt5mm_s"] = sum(1 for r in rows if max(r["pen_l"]["torso"], r["pen_r"]["torso"]) > 0.005) / HZ
    kn = [min(r["knee_Left"], r["knee_Right"]) for r in rows]
    out["knee_min_deg"] = min(kn)
    out["knee_rest_deg"] = sum(r["knee_Left"] for r in rows[:20]) / 20.0
    out["kneeyaw_absmax"] = max(max(r["kneeyaw_Left"], r["kneeyaw_Right"]) for r in rows)
    out["kneeyaw_rest"] = sum(r["kneeyaw_Left"] for r in rows[:20]) / 20.0
    out["kneefwd_min_cm"] = min(min(r["kneefwd_Left"], r["kneefwd_Right"]) for r in rows)
    out["trunk_roll_peak"] = max((r["trunk_roll"] for r in rows), key=abs)
    out["trunk_pitch_peak"] = max((r["trunk_pitch"] for r in rows), key=abs)
    out["neck_flex_peak"] = max((r["neck_flex"] - rows[10]["neck_flex"] for r in rows), key=abs)
    out["head_roll_peak"] = max((r["head_roll"] for r in rows), key=abs)
    f0 = rows[10]
    out["foot_drift_cm"] = 100.0 * max(max(math.dist(r["foot_Left"], f0["foot_Left"]), math.dist(r["foot_Right"], f0["foot_Right"])) for r in rows)
    out["knee_dx_dev_cm"] = 100.0 * max(max(abs(r["kneex_Left"] - f0["kneex_Left"]), abs(r["kneex_Right"] - f0["kneex_Right"])) for r in rows)
    out["neck_len_rest_cm"] = 100 * f0["neck_len"]
    out["neck_len_min_cm"] = 100 * min(r["neck_len"] for r in rows)
    out["neck_len_max_cm"] = 100 * max(r["neck_len"] for r in rows)
    nk = [n for n in tr.get("neck", []) if n.get("front_rest", 0) > 0]
    if nk:
        out["front_min_pct"] = 100 * min(n["front_len"] / n["front_rest"] for n in nk)
        out["front_max_pct"] = 100 * max(n["front_len"] / n["front_rest"] for n in nk)
        out["neckw_max_pct"] = 100 * max(n["band_w"] / nk[0]["band_w"] for n in nk)
        out["neckd_max_pct"] = 100 * max(n["band_d"] / nk[0]["band_d"] for n in nk)
        out["front_rest_cm"] = 100 * nk[0]["front_rest"]
    if ev:
        press = [e for e in ev if e[2]]
        rel = [e for e in ev if not e[2]]
        t_press = press[0][0]
        c = tr["clip"]
        if c == "back":
            val = [abs(v) for v in dz]
        elif c.startswith("duck") or c == "slip_duck":
            val = [-y for y in dy]
        else:
            val = [abs(x) for x in dx]
        t_rel0 = rel[-1][0] if rel else ts[-1]
        win = sorted(v for t, v in zip(ts, val) if t_press + 0.5 <= t <= t_rel0)
        pk = win[len(win) // 2] if len(win) > 4 else max(val)   # plateau (median of the held part): robust to idle sway
        out["pk_val"] = pk
        t90 = first_cross(ts, val, 0.9 * pk, t_press)
        out["t90_s"] = None if t90 is None else t90 - t_press
        t50 = first_cross(ts, val, 0.5 * pk, t_press)
        out["t50_s"] = None if t50 is None else t50 - t_press
        if rel:
            t_rel = rel[-1][0] if c in ("duck_q", "duck_e", "duck_switch", "slip_duck") else rel[0][0]
            pk_at = max(v for t, v in zip(ts, val) if t <= t_rel + 0.001)
            tr10 = first_cross(ts, val, max(0.1 * pk_at, 0.05), t_rel, rising=False)
            out["return_s"] = None if tr10 is None else tr10 - t_rel
    sp = [(dx[i + 1] - dx[i - 1]) * HZ / 2 for i in range(1, len(dx) - 1)]
    ac = [(sp[i + 1] - sp[i - 1]) * HZ / 2 for i in range(1, len(sp) - 1)]
    out["head_speed_max"] = max(abs(s) for s in sp)
    out["head_accel_max"] = max(abs(a) for a in ac) if ac else 0
    out["head_jump_cm"] = 100 * max(math.dist(rows[i]["head"], rows[i + 1]["head"]) for i in range(len(rows) - 1))
    return out


def switch_metrics(tr, t_switch, t_end):
    rows, b = head_dev(tr)
    ts = [r["t"] / HZ for r in rows]
    dx = [r["head"][0] - b[0] for r in rows]
    pre = max(v for t, v in zip(ts, dx) if t < t_switch)
    post = min(v for t, v in zip(ts, dx) if t_switch <= t <= t_end)
    t90 = first_cross(ts, dx, pre - 0.9 * (pre - post), t_switch, rising=False)
    t50 = first_cross(ts, dx, pre - 0.5 * (pre - post), t_switch, rising=False)
    lo = pre - 0.75 * (pre - post)
    hi = pre - 0.25 * (pre - post)
    spd = [abs((dx[i + 1] - dx[i - 1]) * HZ / 2) for i in range(1, len(dx) - 1) if t_switch <= ts[i] <= t_end and lo <= dx[i] <= hi]
    return {"pre_peak": pre, "post_peak": post, "t90_s": None if t90 is None else t90 - t_switch,
            "t50_s": None if t50 is None else t50 - t_switch, "min_speed_mid": min(spd) if spd else None}


result = {}
for m in models:
    result[m] = {}
    for c in sorted(os.listdir(os.path.join(d, m))):
        tr = load(m, c)
        if tr is None or not tr["rows"]:
            continue
        r = clip_metrics(tr)
        if c in ("switch_qe", "switch_overlap"):
            r["switch"] = switch_metrics(tr, 1.2, 2.0)
        if c == "switch_qeq":
            r["switch"] = switch_metrics(tr, 1.1, 1.8)
        if c == "duck_switch":
            r["switch"] = switch_metrics(tr, 1.4, 1.9)
        result[m][c] = r
json.dump(result, open(os.path.join(d, "metrics.json"), "w"), indent=1)


def fmt(v):
    return "-" if v is None else (f"{v:.2f}" if isinstance(v, float) else str(v))


cols = ["peak_dx", "peak_drop", "t90_s", "return_s", "pen_max_cm", "pen_glove_cm", "pen_forearm_cm", "pen_head_cm", "knee_min_deg",
        "kneeyaw_absmax", "kneefwd_min_cm", "trunk_roll_peak", "neck_flex_peak", "foot_drift_cm", "neck_len_min_cm", "neck_len_max_cm", "front_min_pct", "front_max_pct", "neckw_max_pct", "head_jump_cm"]
for m in result:
    print("==", m)
    print("clip".ljust(15) + " ".join(c[:10].rjust(10) for c in cols))
    for c, r in result[m].items():
        print(c.ljust(15) + " ".join(fmt(r.get(k)).rjust(10) for k in cols))
        if "switch" in r:
            print("   switch:", {k: (round(v, 3) if isinstance(v, float) else v) for k, v in r["switch"].items()})
