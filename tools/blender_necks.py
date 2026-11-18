"""Neck / upper-trapezius / upper-back hump fix for the five Meshy fighter models (KnockNight).

Run (re-runnable, idempotent: always starts from the ORIGINAL glb in git history):

  blender.exe --background --python tools/blender_necks.py -- \
      [--models viper_alt,anvil,...] [--measure] [--render DIR] [--apply] [--tag before|after]

  --measure   print + write neck measurements for the original and (with --apply) edited mesh
  --render D  Blender renders (front / side / rear 3/4 close-ups) into D
  --apply     compute the deformation in Blender, write the edited glb into assets/fighters/meshy/

Method:
  1. The ORIGINAL glb is read from git (BASE_REV, git-lfs smudged), never from the working tree.
  2. It is imported into Blender (glTF importer), checked vertex-for-vertex against the glb POSITION
     accessor, and the deformation is applied to the Blender mesh as a smooth field of REST position
     (height-band x distance-from-neck-axis falloff). Coincident / UV-split vertices therefore move
     identically. Bones, skin weights, UVs, materials and textures are not touched.
  3. Two fields are composed: hump_field (posterior-only pull of the upper back toward a lumbar->nape chord, measured
     per model) then neck_field (neck girth + trapezius lowering). Both are pure functions of rest position.
  4. The edited positions are read back from Blender and written into the original glb's POSITION
     and NORMAL accessors in place (everything else byte-identical); a verification diff is run.
"""
import sys, os, json, struct, subprocess, math, hashlib

import numpy as np

BASE_REV = "fa7a385"
MODELS = ["viper_alt", "anvil", "oak", "boxer1", "boxer2"]
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = "assets/fighters/meshy/%s.glb"
BIN_TAG = b"BIN" + bytes([0])


# ---------------------------------------------------------------------------------------------
# glb IO
# ---------------------------------------------------------------------------------------------
def original_glb_bytes(name):
    rel = REL % name
    blob = subprocess.run(["git", "show", "%s:%s" % (BASE_REV, rel)], cwd=ROOT, capture_output=True, check=True).stdout
    if blob.startswith(b"version https://git-lfs"):
        oid = [l.split(b":")[1] for l in blob.splitlines() if l.startswith(b"oid sha256:")][0].decode()
        common = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=ROOT, capture_output=True, check=True).stdout.decode().strip()
        if not os.path.isabs(common):
            common = os.path.join(ROOT, common)
        path = os.path.join(common, "lfs", "objects", oid[:2], oid[2:4], oid)
        if os.path.exists(path):
            blob = open(path, "rb").read()
        else:
            blob = subprocess.run(["git", "lfs", "smudge"], input=blob, cwd=ROOT, capture_output=True, check=True).stdout
        assert hashlib.sha256(blob).hexdigest() == oid, "LFS object hash mismatch"
    assert blob[:4] == b"glTF"
    return blob


class Glb:
    def __init__(self, data):
        self.data = bytes(data)
        magic, ver, ln = struct.unpack("<4sII", self.data[:12])
        off = 12
        self.chunks = []  # (type, start, length)
        while off < ln:
            cl, ct = struct.unpack("<I4s", self.data[off:off + 8])
            self.chunks.append((ct, off + 8, cl))
            off += 8 + cl
        j = [c for c in self.chunks if c[0] == b"JSON"][0]
        b = [c for c in self.chunks if c[0] == b"BIN\x00"][0]
        self.js = json.loads(self.data[j[1]:j[1] + j[2]])
        self.bin_start, self.bin_len = b[1], b[2]
        self.json_start, self.json_len = j[1], j[2]

    def acc_layout(self, i):
        a = self.js["accessors"][i]
        bv = self.js["bufferViews"][a["bufferView"]]
        nc = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a["type"]]
        dt = {5126: np.float32, 5123: np.uint16, 5125: np.uint32, 5121: np.uint8, 5120: np.int8, 5122: np.int16}[a["componentType"]]
        off = self.bin_start + bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        assert not bv.get("byteStride") or bv["byteStride"] == nc * np.dtype(dt).itemsize, "interleaved accessor not supported"
        return off, a["count"], nc, dt

    def acc(self, i):
        off, cnt, nc, dt = self.acc_layout(i)
        return np.frombuffer(self.data, dtype=dt, count=cnt * nc, offset=off).reshape(cnt, nc)

    def with_vec3(self, accessor_values, pos_acc=None):
        """accessor_values: {accessor_index: float32 (N,3) array}. Only those accessor bytes change in the BIN chunk.
        If POSITION's bounds change (the hump was the back-most point of the model) the accessor min/max in the JSON
        chunk are updated too; nothing else in the JSON changes."""
        buf = bytearray(self.data)
        for i, arr in accessor_values.items():
            off, cnt, nc, dt = self.acc_layout(i)
            assert dt == np.float32 and nc == 3 and arr.shape == (cnt, 3)
            buf[off:off + cnt * 12] = np.ascontiguousarray(arr, dtype="<f4").tobytes()
        if pos_acc is not None:
            P = np.asarray(accessor_values[pos_acc], dtype=np.float32)
            a = self.js["accessors"][pos_acc]
            nmin, nmax = [float(v) for v in P.min(0)], [float(v) for v in P.max(0)]
            if not (np.array_equal(np.float32(a["min"]), np.float32(nmin)) and np.array_equal(np.float32(a["max"]), np.float32(nmax))):
                js = json.loads(json.dumps(self.js))
                js["accessors"][pos_acc]["min"], js["accessors"][pos_acc]["max"] = nmin, nmax
                raw = json.dumps(js, separators=(",", ":")).encode("utf-8")
                raw += b" " * ((4 - len(raw) % 4) % 4)
                binc = bytes(buf[self.bin_start:self.bin_start + self.bin_len])
                total = 12 + 8 + len(raw) + 8 + len(binc)
                return (struct.pack("<4sII", b"glTF", 2, total) + struct.pack("<I4s", len(raw), b"JSON") + raw
                        + struct.pack("<I4s", len(binc), BIN_TAG) + binc)
        return bytes(buf)


class Model:
    def __init__(self, name, glb_bytes=None):
        self.name = name
        self.glb = Glb(glb_bytes if glb_bytes is not None else original_glb_bytes(name))
        js = self.glb.js
        sk = js["skins"][0]
        self.jn = [js["nodes"][j]["name"] for j in sk["joints"]]
        ibm = np.transpose(self.glb.acc(sk["inverseBindMatrices"]).reshape(-1, 4, 4), (0, 2, 1)).astype(float)
        self.jpos = np.array([np.linalg.inv(m)[:3, 3] for m in ibm])
        pr = js["meshes"][0]["primitives"][0]
        self.pos_acc, self.nrm_acc = pr["attributes"]["POSITION"], pr["attributes"]["NORMAL"]
        self.P = self.glb.acc(self.pos_acc).astype(float)
        self.N = self.glb.acc(self.nrm_acc).astype(float)
        self.T = self.glb.acc(pr["indices"]).astype(np.int64).reshape(-1, 3)

    def joint(self, n):
        return self.jpos[self.jn.index(n)]


# ---------------------------------------------------------------------------------------------
# measurements (all in glTF rest space, metres; +y up, +z forward, +x = character left)
# ---------------------------------------------------------------------------------------------
def slice_loops(P, T, y):
    ya, yb, yc = P[T[:, 0], 1] - y, P[T[:, 1], 1] - y, P[T[:, 2], 1] - y
    s = np.stack([ya, yb, yc], 1)
    cross = (s.min(1) < 0) & (s.max(1) >= 0)
    segs = []
    for t in T[cross]:
        pts = []
        for a, b in ((t[0], t[1]), (t[1], t[2]), (t[2], t[0])):
            da, db = P[a, 1] - y, P[b, 1] - y
            if (da < 0) != (db < 0):
                f = da / (da - db)
                pts.append(P[a] + f * (P[b] - P[a]))
        if len(pts) == 2:
            segs.append(pts)
    key = lambda p: (round(p[0] * 1e5), round(p[2] * 1e5))
    adj = {}
    for i, (a, b) in enumerate(segs):
        adj.setdefault(key(a), []).append((i, 0))
        adj.setdefault(key(b), []).append((i, 1))
    used, loops = set(), []
    for i in range(len(segs)):
        if i in used:
            continue
        used.add(i)
        loop = [segs[i][0], segs[i][1]]
        cur, start = key(segs[i][1]), key(segs[i][0])
        while cur != start:
            nxt = None
            for (j, e) in adj.get(cur, []):
                if j not in used:
                    nxt = (j, e)
                    break
            if nxt is None:
                break
            j, e = nxt
            used.add(j)
            p = segs[j][1 - e]
            loop.append(p)
            cur = key(p)
        loops.append(np.array(loop))
    return loops


def loop_perimeter_area(L):
    per = np.sum(np.linalg.norm(np.diff(L[:, [0, 2]], axis=0), axis=1))
    x, z = L[:, 0], L[:, 2]
    area = 0.5 * abs(np.sum(x[:-1] * z[1:] - x[1:] * z[:-1]))
    return per, area


def point_in_loop(L, px, pz):
    x, z = L[:, 0], L[:, 2]
    c = False
    for i in range(len(L) - 1):
        if (z[i] > pz) != (z[i + 1] > pz) and px < (x[i + 1] - x[i]) * (pz - z[i]) / (z[i + 1] - z[i]) + x[i]:
            c = not c
    return c


def axis_loop(m, P, y):
    """The cross-section loop of the body at height y that contains the neck axis (None if absent)."""
    nk = m.joint("neck")
    best = None
    for L in slice_loops(P, m.T, y):
        if point_in_loop(L, nk[0], nk[2]):
            if best is None or loop_perimeter_area(L)[1] > loop_perimeter_area(best)[1]:
                best = L
    return best


def _loop_dims(L):
    per, area = loop_perimeter_area(L)
    return dict(w=float(L[:, 0].max() - L[:, 0].min()), d=float(L[:, 2].max() - L[:, 2].min()), per=float(per))


def measure(m, lm, P=None):
    """Neck metrics (cm) from the mesh. `lm` are the landmarks of the ORIGINAL mesh so before / after use the same heights.

    mid-neck   : cross-section at 3 cm under the chin line (the visible neck, whatever merges into it)
    waist      : smallest-circumference cross-section between 10 cm and 0.5 cm under the chin line
    head       : widest / deepest / longest-circumference cross-section above the Head joint
    trap slope : top of the trapezius shelf at the neck wall (|x| = 11 cm) minus at the shoulder joint x (vertices below
                 the chin line only, so the head and ears never count)
    visible neck length: from the chin line down to where the silhouette first reaches 85 % of the head half width
                 (front view: x extent; side view: nape moves 4 cm behind its position at the chin line)
    """
    P = m.P if P is None else P
    chin, xs = lm["chin"], lm["shoulder_x"]
    hd = m.joint("Head")
    out = {"model": m.name, "H": float(P[:, 1].max() - P[:, 1].min()), "chin_y": chin}
    loops = {}

    def loop_at(y):
        k = round(y, 4)
        if k not in loops:
            loops[k] = axis_loop(m, P, y)
        return loops[k]

    mid = _loop_dims(loop_at(chin - 0.03))
    out.update(mid_w=mid["w"] * 100, mid_d=mid["d"] * 100, mid_circ=mid["per"] * 100)
    best = None
    for y in np.arange(chin - 0.10, chin - 0.004, 0.005):
        L = loop_at(y)
        if L is None:
            continue
        dd = _loop_dims(L)
        if best is None or dd["per"] < best[1]["per"]:
            best = (y, dd)
    out.update(waist_y=float(best[0]), waist_w=best[1]["w"] * 100, waist_d=best[1]["d"] * 100, waist_circ=best[1]["per"] * 100)
    hbest = None
    for y in np.arange(hd[1] + 0.01, hd[1] + 0.12, 0.005):
        L = loop_at(y)
        if L is None:
            continue
        dd = _loop_dims(L)
        hbest = dd if hbest is None else dict(w=max(hbest["w"], dd["w"]), d=max(hbest["d"], dd["d"]), per=max(hbest["per"], dd["per"]))
    out.update(head_w=hbest["w"] * 100, head_d=hbest["d"] * 100, head_circ=hbest["per"] * 100)
    out["waist_over_head_w"] = out["waist_w"] / out["head_w"]
    out["mid_over_head_w"] = out["mid_w"] / out["head_w"]
    out["waist_circ_over_head"] = out["waist_circ"] / out["head_circ"]

    def top_at(x0, x1):
        s_ = (np.abs(P[:, 0]) >= x0) & (np.abs(P[:, 0]) < x1) & (P[:, 1] < chin + 0.02) & (P[:, 1] > chin - 0.30) & (np.abs(P[:, 2] - lm["cz"]) < 0.14)
        return float(P[s_, 1].max())
    yn, ys = top_at(0.10, 0.12), top_at(xs - 0.01, xs + 0.01)
    out.update(trap_y_neck=yn, trap_y_shoulder=ys, trap_slope_cm=(yn - ys) * 100, trap_below_chin_cm=(chin - yn) * 100)
    hh = out["head_w"] / 200.0
    # front: silhouette half width
    L0 = None
    vf = 0.0
    for y in np.arange(chin, chin - 0.20, -0.0025):
        L = loop_at(y) if round(y, 4) in loops or True else None
        if L is None:
            break
        if (L[:, 0].max() - L[:, 0].min()) / 2 >= 0.85 * hh:
            break
        vf = chin - y
    out["visible_front_cm"] = vf * 100
    L = loop_at(chin)
    nape0 = L[np.abs(L[:, 0]) < 0.025][:, 2].min()
    vs = 0.0
    for y in np.arange(chin, chin - 0.20, -0.0025):
        L = loop_at(y)
        if L is None:
            break
        if L[np.abs(L[:, 0]) < 0.025][:, 2].min() < nape0 - 0.04:
            break
        vs = chin - y
    out["visible_side_cm"] = vs * 100
    # ---- upper-back hump: how far the central back sits behind the lumbar->nape chord, and where the back-most z is
    ys = lm["prof_y"]
    sel = (ys >= lm["y_l"] + 0.10) & (ys <= chin - 0.04)
    bb = []
    for y in ys[sel]:
        L = loop_at(y)
        cc = L[np.abs(L[:, 0]) < 0.025][:, 2]
        bb.append(cc.min())
    bb = np.array(bb)
    chord = lm["chord_l"][1] + (lm["chord_t"][1] - lm["chord_l"][1]) * (ys[sel] - lm["y_l"]) / (lm["y_t"] - lm["y_l"])
    pr = chord - bb
    out.update(hump_prot_cm=float(pr.max() * 100), hump_prot_y=float(ys[sel][np.argmax(pr)]),
               back_z_cm=float(bb.min() * 100), back_z_y=float(ys[sel][np.argmin(bb)]))
    return out


def fmt_measure(r):
    rows = [
        "%s (H %.3f m, chin line y=%.3f)" % (r["model"], r["H"], r["chin_y"]),
        "  mid-neck (chin-3cm): width %.1f depth %.1f circ %.1f cm | waist (min circ, y=%.3f): width %.1f depth %.1f circ %.1f cm" % (
            r["mid_w"], r["mid_d"], r["mid_circ"], r["waist_y"], r["waist_w"], r["waist_d"], r["waist_circ"]),
        "  head: width %.1f depth %.1f circ %.1f cm | waist/head width %.2f, mid/head width %.2f, waist/head circ %.2f" % (
            r["head_w"], r["head_d"], r["head_circ"], r["waist_over_head_w"], r["mid_over_head_w"], r["waist_circ_over_head"]),
        "  trapezius: shelf %.1f cm below chin line at the neck wall, slope neck->shoulder %.1f cm" % (r["trap_below_chin_cm"], r["trap_slope_cm"]),
        "  visible neck length: front %.1f cm, side %.1f cm" % (r["visible_front_cm"], r["visible_side_cm"]),
        "  upper back: hump protrusion behind lumbar->nape chord %.1f cm (at y=%.3f); back-most z %.1f cm at y=%.3f" % (r["hump_prot_cm"], r["hump_prot_y"], r["back_z_cm"], r["back_z_y"]),
    ]
    return chr(10).join(rows)


# ---------------------------------------------------------------------------------------------
# the deformation: a smooth field of rest position
# ---------------------------------------------------------------------------------------------
def sstep(a, b, x):
    t = np.clip((np.asarray(x, dtype=float) - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# per-model strengths. girth_x / girth_z: how much the neck / near-trap column is slimmed (fraction removed at the
# core); drop: how far the upper trapezius is lowered (m).  Tuned from the measurements (see report).
PARAMS = {
    "viper_alt": dict(girth_x=0.10, girth_zb=0.14, girth_zf=0.04, drop=0.030, hump=0.60),
    "oak":       dict(girth_x=0.14, girth_zb=0.16, girth_zf=0.05, drop=0.034, hump=0.65),
    "boxer1":    dict(girth_x=0.10, girth_zb=0.14, girth_zf=0.04, drop=0.030, hump=0.60),
    "anvil":     dict(girth_x=0.34, girth_zb=0.22, girth_zf=0.08, drop=0.040, flare=0.27, ramp=0.17, hump=0.58),
    "boxer2":    dict(girth_x=0.28, girth_zb=0.20, girth_zf=0.07, drop=0.038, flare=0.26, ramp=0.16, hump=0.58),
}


def landmarks(m):
    """chin underside height, neck centre and shoulder x, measured on the ORIGINAL mesh."""
    nk, hd, hf, sh = m.joint("neck"), m.joint("Head"), m.joint("headfront"), m.joint("LeftArm")
    chin = None
    prev = None
    for y in np.arange(nk[1] - 0.04, hd[1] + 0.02, 0.0025):
        L = axis_loop(m, m.P, y)
        if L is None:
            continue
        zf = L[np.abs(L[:, 0]) < 0.025][:, 2].max()
        if zf >= 0.6 * hf[2]:
            chin = y if prev is None else prev[0] + (y - prev[0]) * (0.6 * hf[2] - prev[1]) / (zf - prev[1])
            break
        prev = (y, zf)
    L = axis_loop(m, m.P, chin - 0.03)
    c = L[np.abs(L[:, 0]) < 0.025][:, 2]
    # ---- central back profile (|x| < 2.5 cm) for the hump field: back-most z (b) and front z (f) per height
    ys = np.arange(m.joint("Hips")[1] - 0.04, chin + 0.03, 0.005)
    bz, fz, ok = [], [], []
    for y in ys:
        Lp = axis_loop(m, m.P, y)
        if Lp is None:
            bz.append(np.nan), fz.append(np.nan)
            continue
        cc = Lp[np.abs(Lp[:, 0]) < 0.025][:, 2]
        bz.append(cc.min()), fz.append(cc.max())
    bz, fz = np.array(bz), np.array(fz)
    good = ~np.isnan(bz)
    bz = np.interp(ys, ys[good], bz[good])
    fz = np.interp(ys, ys[good], fz[good])
    k = np.ones(5) / 5.0
    bs = np.convolve(np.pad(bz, 2, mode="edge"), k, mode="valid")      # 2.5 cm moving average
    fs = np.convolve(np.pad(fz, 2, mode="edge"), k, mode="valid")
    spine01 = m.joint("Spine01")[1]
    sel = (ys >= m.joint("Hips")[1] + 0.08) & (ys <= spine01)
    y_l = float(ys[sel][np.argmax(bs[sel])])                            # most forward back point = lumbar curve
    y_t = float(chin)
    zl = float(np.interp(y_l, ys, bs))
    zt = float(np.interp(y_t, ys, bs))
    chord = zl + (zt - zl) * (ys - y_l) / (y_t - y_l)
    prot = np.where((ys >= y_l) & (ys <= y_t), np.maximum(0.0, chord - bs), 0.0)   # metres the back sits behind the chord
    return dict(chin=float(chin), cz=float(0.5 * (c.max() + c.min())), cx=0.0, shoulder_x=float(sh[0]),
                prof_y=ys, prof_b=bs, prof_f=fs, prof_prot=prot, y_l=y_l, y_t=y_t, chord_l=(y_l, zl), chord_t=(y_t, zt))


def neck_field(P, lm, prm):
    """P: (N,3) rest positions (glTF space, metres) -> new positions.

    Pure function of position with compact support, so coincident / UV-split vertices move identically.
      1. girth: x and z offsets from the neck centre are scaled down inside a height band (under the chin up to just
         above it), a lateral falloff (neck column -> shoulder cap) and a depth falloff (chest / upper back untouched);
         the back of the neck (nape) is slimmed more than the throat.
      2. trapezius: the upper trapezius shelf beside the neck is lowered by `drop` (fading out toward the shoulder cap,
         the chest and the upper-back hump), which exposes the neck between the jaw line and the traps.
    """
    P = np.asarray(P, dtype=float)
    x, y, z = P[:, 0] - lm["cx"], P[:, 1], P[:, 2]
    chin, cz, xs = lm["chin"], lm["cz"], lm["shoulder_x"]
    ax = np.abs(x)
    # height band for girth: ramps in from 13 -> 6 cm below the chin line, ramps out 0 -> 5 cm above it (soft, no groove at the skull base)
    wy = sstep(chin - 0.13, chin - 0.06, y) * (1.0 - sstep(chin, chin + 0.05, y))
    # the throat / face side must not move above the chin underside
    wy = wy * (1.0 - sstep(cz + 0.02, cz + 0.06, z) * sstep(chin - 0.015, chin + 0.003, y))
    wl = 1.0 - sstep(0.06, prm.get("flare", 0.20), ax)                      # lateral: neck column -> shoulder cap
    wzf = 1.0 - sstep(cz + 0.06, cz + 0.13, z)            # chest front
    wzb = 1.0 - sstep(cz - 0.10, cz - 0.20, z)            # upper back
    w = wy * wl * wzf * wzb
    back = sstep(cz + 0.03, cz - 0.04, z)                  # 0 at the throat -> 1 at the nape
    kz = prm["girth_zf"] + (prm["girth_zb"] - prm["girth_zf"]) * back
    nx = x * (1.0 - prm["girth_x"] * w)
    nz = cz + (z - cz) * (1.0 - kz * w)
    # trapezius lowering
    gx = sstep(0.05, prm.get("ramp", 0.12), ax) * (1.0 - sstep(0.13, xs * 1.7, ax))   # lateral: neck wall -> shoulder cap -> arm
    gy = sstep(chin - 0.17, chin - 0.08, y) * (1.0 - sstep(chin - 0.005, chin + 0.02, y))
    gz = (1.0 - sstep(cz + 0.04, cz + 0.10, z)) * (1.0 - sstep(cz - 0.12, cz - 0.24, z))
    dy = -prm["drop"] * gx * gy * gz
    out = np.stack([nx + lm["cx"], y + dy, nz], 1)
    return out


def hump_field(P, lm, prm):
    """Posterior-only pull of the upper back toward the spine line (z moves forward only).

    The central back profile b(y) (measured on the original mesh) sits `prot(y)` behind a straight chord from the lumbar
    curve to the nape; each back-surface vertex is moved forward by hump * prot(y) * window(y), fading laterally before the
    scapula edges / shoulder caps (|x| bell, compact support) and with depth (the chest and flanks never move).
    """
    P = np.asarray(P, dtype=float)
    x, y, z = P[:, 0] - lm["cx"], P[:, 1], P[:, 2]
    chin = lm["chin"]
    ys = lm["prof_y"]
    prot = np.interp(y, ys, lm["prof_prot"], left=0.0, right=0.0)
    zmid = 0.5 * (np.interp(y, ys, lm["prof_b"]) + np.interp(y, ys, lm["prof_f"]))
    win = sstep(lm["y_l"], lm["y_l"] + 0.08, y) * (1.0 - sstep(chin - 0.10, chin - 0.025, y))
    ax = np.abs(x)
    lat = np.exp(-(ax / 0.18) ** 2) * (1.0 - sstep(0.22, 0.30, ax))
    dep = sstep(zmid - 0.02, zmid - 0.09, z)
    dz = prm["hump"] * prot * win * lat * dep
    out = P.copy()
    out[:, 2] = z + dz
    return out


def full_field(P, lm, prm):
    """hump field first, then the neck field evaluated on the displaced point (both smooth => composite smooth)."""
    return neck_field(hump_field(P, lm, prm), lm, prm)


def field_normals(P, N, lm, prm, eps=2e-4):
    """Transform normals with the inverse-transpose of the field's numerical Jacobian."""
    P = np.asarray(P, dtype=float)
    base = full_field(P, lm, prm)
    J = np.zeros((len(P), 3, 3))
    for k in range(3):
        d = np.zeros(3)
        d[k] = eps
        J[:, :, k] = (full_field(P + d, lm, prm) - full_field(P - d, lm, prm)) / (2 * eps)
    Nn = np.einsum("nij,nj->ni", np.linalg.inv(J).transpose(0, 2, 1), np.asarray(N, dtype=float))
    ln = np.linalg.norm(Nn, axis=1, keepdims=True)
    return Nn / np.maximum(ln, 1e-12)
# ---------------------------------------------------------------------------------------------
# Blender side
# ---------------------------------------------------------------------------------------------
def bl_import(glb_bytes, name):
    """Import glb bytes into a clean Blender scene (textures copied next to a temp glb). Returns (mesh_obj, armature_obj)."""
    import bpy, shutil
    tmp = os.path.join(ROOT, "_build", "necks", "tmp_" + name)
    os.makedirs(tmp, exist_ok=True)
    src = os.path.join(ROOT, "assets", "fighters", "meshy")
    for f in os.listdir(src):
        if f.startswith(name) and f.lower().endswith((".jpg", ".png")):
            shutil.copy(os.path.join(src, f), tmp)
    path = os.path.join(tmp, name + ".glb")
    open(path, "wb").write(glb_bytes)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    bpy.ops.import_scene.gltf(filepath=path)
    mesh = [o for o in bpy.data.objects if o.type == "MESH" and o.name.startswith("char1")][0]
    arm = [o for o in bpy.data.objects if o.type == "ARMATURE"][0]
    return mesh, arm


def bl_coords(mesh):
    """Blender local vertex coordinates (N,3)."""
    n = len(mesh.data.vertices)
    co = np.zeros(n * 3)
    mesh.data.vertices.foreach_get("co", co)
    return co.reshape(-1, 3)


def bl_to_gltf(co_local, arm):
    """Blender mesh-local (cm, z-up) -> glTF rest space (m, y-up): world = arm.matrix_world @ co; (x, y, z) -> (x, z, -y)."""
    s = arm.matrix_world.to_scale()[0]
    w = co_local * s
    return np.stack([w[:, 0], w[:, 2], -w[:, 1]], 1)


def gltf_to_bl(P, arm):
    s = arm.matrix_world.to_scale()[0]
    return np.stack([P[:, 0], -P[:, 2], P[:, 1]], 1) / s


def bl_render(out_dir, tag, name, views=("front", "side", "rear34"), center=(0.0, 1.58), span=0.60, res=700):
    import bpy
    from mathutils import Vector
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.render.resolution_x = sc.render.resolution_y = res
    sc.render.film_transparent = False
    sh = sc.display.shading
    sh.light = "STUDIO"
    sh.color_type = "TEXTURE"
    sh.show_shadows = True
    sh.show_cavity = False
    sc.view_settings.view_transform = "Standard"
    w = bpy.data.worlds.new("w")
    w.color = (0.32, 0.34, 0.38)
    sc.world = w
    cam_d = bpy.data.cameras.new("cam")
    cam = bpy.data.objects.new("cam", cam_d)
    sc.collection.objects.link(cam)
    sc.camera = cam
    cam_d.type = "ORTHO"
    cam_d.ortho_scale = span
    cam_d.clip_end = 20
    # blender world: x right, -y = character front, z up. glTF z (forward) = blender -y
    target = Vector((0.0, -0.02, center[1]))
    angles = {"front": 0.0, "side": 90.0, "rear34": 180.0 - 35.0, "front34": 35.0, "rear": 180.0}
    os.makedirs(out_dir, exist_ok=True)
    for v in views:
        a = math.radians(angles[v])
        # azimuth 0 = camera in front (-y); 90 = camera on +x (character left side)
        d = Vector((math.sin(a), -math.cos(a), 0.12)).normalized() * 4.0
        cam.location = target + d
        # clip anything nearer than 0.30 m to the target plane: the T-pose arms and gloves would block the side views
        cam_d.clip_start = 4.0 - (0.30 if v != "front" else 1.0)
        direction = target - cam.location
        cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = os.path.join(out_dir, "%s_%s_%s.png" % (name, tag, v))
        bpy.ops.render.render(write_still=True)


def edit_in_blender(name, out_glb_path, render_dir=None):
    """Import the ORIGINAL glb into Blender, apply the field to the Blender mesh, read the result back and write the
    edited glb (POSITION + NORMAL accessors only). Returns (Model, new_P, new_N, info)."""
    m = Model(name)
    lm = landmarks(m)
    prm = PARAMS[name]
    mesh, arm = bl_import(m.glb.data, name)
    co0 = bl_coords(mesh)
    P_bl0 = bl_to_gltf(co0, arm)
    assert len(co0) == len(m.P), "Blender import changed the vertex count"
    err = np.abs(P_bl0 - m.P).max()
    assert err < 2e-5, "Blender import vertex order/positions differ from the glb accessor (%g)" % err
    # deformation evaluated on the Blender mesh (rest positions as Blender holds them)
    P_new_bl = full_field(P_bl0, lm, prm)
    mesh.data.vertices.foreach_set("co", gltf_to_bl(P_new_bl, arm).reshape(-1))
    mesh.data.update()
    if render_dir:
        bl_render(render_dir, "after_blender", name, center=(0.0, m.joint("neck")[1] + 0.02))
    co1 = bl_coords(mesh)
    delta = bl_to_gltf(co1, arm) - P_bl0                  # what Blender moved, in glTF metres
    moved = np.linalg.norm(delta, axis=1) > 1e-7          # > 0.1 micron; everything else stays bit-identical
    newP = m.P.copy()
    newP[moved] = (m.P + delta)[moved]
    newP32 = m.glb.acc(m.pos_acc).copy()
    newP32[moved] = newP[moved].astype(np.float32)
    # normals: inverse-transpose Jacobian of the field, only for moved vertices
    newN32 = m.glb.acc(m.nrm_acc).copy()
    Nn = field_normals(m.P[moved], m.N[moved], lm, prm)
    newN32[moved] = Nn.astype(np.float32)
    blob = m.glb.with_vec3({m.pos_acc: newP32, m.nrm_acc: newN32}, pos_acc=m.pos_acc)
    os.makedirs(os.path.dirname(out_glb_path), exist_ok=True)
    open(out_glb_path, "wb").write(blob)
    return m, lm, newP32.astype(float), blob, int(moved.sum())


def integrity_diff(name, new_blob):
    """Proves the edited glb equals the original except POSITION / NORMAL bytes (+ the POSITION min/max bounds in JSON)."""
    old = original_glb_bytes(name)
    og, ng = Glb(old), Glb(new_blob)
    lines, ok = [], True
    lines.append("file size %d -> %d, BIN chunk %d -> %d bytes" % (len(old), len(new_blob), og.bin_len, ng.bin_len))
    ok &= og.bin_len == ng.bin_len
    pa = og.js["meshes"][0]["primitives"][0]["attributes"]["POSITION"]
    ja, jb = json.loads(json.dumps(og.js)), json.loads(json.dumps(ng.js))
    bounds_changed = ja["accessors"][pa]["min"] != jb["accessors"][pa]["min"] or ja["accessors"][pa]["max"] != jb["accessors"][pa]["max"]
    for j in (ja, jb):
        j["accessors"][pa].pop("min"), j["accessors"][pa].pop("max")
    same_json = ja == jb
    ok &= same_json
    lines.append("glTF JSON (nodes, skins, joint names + rest transforms, materials, images, all other accessors) identical apart from POSITION min/max: %s; POSITION bounds %s" % (
        same_json, "updated (hump was the back-most point)" if bounds_changed else "unchanged"))
    pr = og.js["meshes"][0]["primitives"][0]
    allowed = np.zeros(og.bin_len, bool)
    for acc_i in (pr["attributes"]["POSITION"], pr["attributes"]["NORMAL"]):
        off, cnt, nc, dt = og.acc_layout(acc_i)
        allowed[off - og.bin_start:off - og.bin_start + cnt * nc * np.dtype(dt).itemsize] = True
    a = np.frombuffer(old, np.uint8)[og.bin_start:og.bin_start + og.bin_len]
    b = np.frombuffer(new_blob, np.uint8)[ng.bin_start:ng.bin_start + ng.bin_len]
    diff = a != b
    outside = int((diff & ~allowed).sum())
    ok &= outside == 0
    lines.append("BIN bytes changed: %d total, %d outside the POSITION/NORMAL accessors (%s)" % (diff.sum(), outside, "OK" if outside == 0 else "FAIL"))
    # per-attribute: everything but POSITION / NORMAL identical (explicit)
    for key, i in pr["attributes"].items():
        same = np.array_equal(og.acc(i), ng.acc(i))
        lines.append("  attribute %-11s %s" % (key, "identical" if same else "changed"))
        ok &= same or key in ("POSITION", "NORMAL")
    same_idx = np.array_equal(og.acc(pr["indices"]), ng.acc(pr["indices"]))
    lines.append("  indices (triangles)      %s" % ("identical" if same_idx else "changed"))
    ok &= same_idx
    ibm = og.js["skins"][0]["inverseBindMatrices"]
    same_ibm = np.array_equal(og.acc(ibm), ng.acc(ibm))
    lines.append("  inverseBindMatrices      %s" % ("identical" if same_ibm else "changed"))
    ok &= same_ibm
    # POSITION bounds still valid
    Pn = ng.acc(pr["attributes"]["POSITION"])
    pa = og.js["accessors"][pr["attributes"]["POSITION"]]
    pacc = ng.js["accessors"][pr["attributes"]["POSITION"]]
    bounds_ok = np.array_equal(np.float32(Pn.min(0)), np.float32(pacc["min"])) and np.array_equal(np.float32(Pn.max(0)), np.float32(pacc["max"]))
    lines.append("  POSITION min/max in JSON equal the new vertex bounds: %s" % bounds_ok)
    ok &= bounds_ok
    # coincident-vertex consistency: vertices sharing an original position moved identically (no cracks)
    Po, Pe = og.acc(pr["attributes"]["POSITION"]), Pn
    keyv = [tuple(r) for r in Po.view(np.uint32)]
    groups = {}
    for i, k in enumerate(keyv):
        groups.setdefault(k, []).append(i)
    bad = 0
    nsplit = 0
    for k, idx in groups.items():
        if len(idx) > 1:
            nsplit += 1
            if not all(np.array_equal(Pe[idx[0]].view(np.uint32), Pe[j].view(np.uint32)) for j in idx[1:]):
                bad += 1
    lines.append("  coincident (UV-split) position groups: %d, moved inconsistently: %d (%s)" % (nsplit, bad, "OK" if bad == 0 else "FAIL"))
    ok &= bad == 0
    # normals: unit length, same hemisphere as before
    Nn, No = ng.acc(pr["attributes"]["NORMAL"]).astype(float), og.acc(pr["attributes"]["NORMAL"]).astype(float)
    ln = np.linalg.norm(Nn, axis=1)
    dots = (Nn * No).sum(1)
    lines.append("  normals: |n| in [%.4f, %.4f], min dot(old,new)=%.3f" % (ln.min(), ln.max(), dots.min()))
    ok &= bool(abs(ln - 1).max() < 1e-3 and dots.min() > 0.2)
    return lines, bool(ok)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]

    def arg(k, d=None):
        return argv[argv.index(k) + 1] if k in argv else d

    names = arg("--models", ",".join(MODELS)).split(",")
    outdir = os.path.abspath(os.path.join(ROOT, arg("--out", "_build/necks/out")))
    rdir = os.path.abspath(os.path.join(ROOT, arg("--render", "_build/necks/blr"))) if "--render" in argv else None
    report = []
    for n in names:
        m = Model(n)
        lm0 = landmarks(m)
        before = measure(m, lm0)
        report.append("== %s BEFORE\n%s" % (n, fmt_measure(before)))
        if "--render-before" in argv and rdir:
            bl_import(m.glb.data, n)
            bl_render(rdir, "before", n, center=(0.0, m.joint("neck")[1] + 0.02))
            bl_render(rdir, "before_wide", n, center=(0.0, m.joint("neck")[1] - 0.05), span=0.95, views=("side", "rear34", "rear"))
        if "--apply" in argv or "--write" in argv:
            dest = os.path.join(ROOT, REL % n) if "--apply" in argv else os.path.join(outdir, n + ".glb")
            m, lm, Pe, blob, nmoved = edit_in_blender(n, dest, rdir)
            lines, ok = integrity_diff(n, blob)
            after = measure(m, lm0, Pe)
            report.append("== %s AFTER (chin %.3f, chord y %.3f-%.3f, params %s, %d vertices moved)\n%s" % (n, lm["chin"], lm["y_l"], lm["y_t"], PARAMS[n], nmoved, fmt_measure(after)))
            report.append("-- integrity diff vs %s:%s: %s\n   %s" % (BASE_REV, REL % n, "PASS" if ok else "FAIL", "\n   ".join(lines)))
            if rdir:   # re-import the FINAL glb and render it (proves the file, not just Blender's in-memory edit)
                mesh, arm = bl_import(blob, n)
                bl_render(rdir, "after", n, center=(0.0, m.joint("neck")[1] + 0.02))
                bl_render(rdir, "after_wide", n, center=(0.0, m.joint("neck")[1] - 0.05), span=0.95, views=("side", "rear34", "rear"))
    txt = "\n".join(report)
    print(txt)
    if "--report" in argv:
        open(os.path.abspath(os.path.join(ROOT, arg("--report"))), "w", encoding="utf-8").write(txt + "\n")
