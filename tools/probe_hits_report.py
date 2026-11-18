"""python -I tools/probe_hits_report.py _build/hits/probe_<tag>.jsonl [more.jsonl ...] [--md out.md]
Turns the tools/probe_hits.gd log into the tables: outcomes, visible-contact false negatives / false positives with ranked causes,
reaction coverage per outcome, damage-zero cases.

Definitions (all distances are between decimated skin vertices, m):
  visible contact  : glove vs foe head / neck / torso / gloves + forearms closer than VIS_TOUCH at some frame of the punch
  FALSE NEGATIVE   : visible contact, registered outcome = whiff
  FALSE POSITIVE   : registered hit / glance / block / parry, nothing of the foe closer than FP_FAR the whole punch
  reaction visible : peak displacement of the foe's visible head / chest / glove joints in the 0.25 s after contact above 2 cm
"""
import json
import sys
from collections import Counter, defaultdict

VIS_TOUCH = 0.012
FP_FAR = 0.03
VISIBLE = 0.02
REG = ("hit", "glance", "block", "parry", "clash", "evaded")   # evaded = the foe got his head out of the way, the glove still touched him: felt, no damage, the punch stays a miss
CLASSES = ("vis_head", "vis_neck", "vis_torso", "vis_glove")


def load(paths):
    rows = []
    for p in paths:
        for line in open(p):
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def vis_min(r):
    return min(r[c] for c in CLASSES)


def visible_contact(r):
    return vis_min(r) <= VIS_TOUCH


def peak(r, joints=("Head", "Chest", "LGlove", "RGlove")):
    rc = r.get("react") or {}
    return max([rc.get(j, 0.0) for j in joints] + [0.0])


def fn_cause(r):
    """Why did a punch that visibly touched register nothing."""
    fv = r["first_vis"]
    if not fv:
        return "n/a"
    want = ("vis_head", "vis_neck") if r["zone"] == "head" else ("vis_torso",)
    hit_want = [k for k in want if k in fv]
    key = min(hit_want, key=lambda k: fv[k]["frame"]) if hit_want else min(fv, key=lambda k: fv[k]["frame"])
    f = fv[key]
    zone = r["zone"]
    cls = key.replace("vis_", "")
    if not f["in_window"]:
        return "%s touched outside the strike window (%s, phase %s)" % (cls, "early" if f["phase"] in ("startup", "committed") else "late", f["phase"])
    gp = {"head": f["gp_head"], "neck": f["gp_head"], "torso": f["gp_body"], "glove": f["gp_guard"]}[cls]
    if cls in ("head", "neck") and zone == "head":
        if f["why"] == "window_closed":
            return "head touched, strike window closed (phase %s)" % f["phase"]
        if gp > 0.0:
            return "gameplay head volume %.1f cm short of the visible head (volume miss)" % (gp * 100)
        return "head volume touched but no registration (%s)" % f["why"]
    if cls == "torso" and zone == "head":
        return "head punch touched the torso only (zone filter)"
    if cls in ("head", "neck") and zone == "body":
        return "body punch touched the head only (zone filter)"
    if cls == "torso" and zone == "body":
        if gp > 0.0:
            return "gameplay body volume %.1f cm short of the visible torso (volume miss)" % (gp * 100)
        return "body volume touched but no registration (%s)" % f["why"]
    if cls == "glove":
        if gp > 0.0:
            return "gameplay guard volume %.1f cm short of the visible glove / forearm (volume miss)" % (gp * 100)
        return "touched the foe's glove / forearm, foe not blocking (%s)" % f["why"]
    return "other"


def pct(a, b):
    return "%5.1f%%" % (100.0 * a / b) if b else "   n/a"


def report(rows, out):
    P = lambda *a: out.append(" ".join(str(x) for x in a))
    n = len(rows)
    P("punches logged: %d (scripted %d, cpu %d)" % (n, sum(r["mode"] == "scripted" for r in rows), sum(r["mode"] == "cpu" for r in rows)))
    P("")
    # --- outcomes
    P("### Outcomes by foe state")
    states = sorted({r["state"] for r in rows})
    P("| foe state | punches | hit | glance | block | parry | clash | evaded | whiff |")
    P("|---|---|---|---|---|---|---|---|---|")
    for st in states + ["ALL"]:
        sub = [r for r in rows if st == "ALL" or r["state"] == st]
        c = Counter(r["outcome"] for r in sub)
        P("| %s | %d | %d | %d | %d | %d | %d | %d | %d |" % (st, len(sub), c["hit"], c["glance"], c["block"], c["parry"], c["clash"], c["evaded"], c["whiff"]))
    P("")
    # --- visible contact vs registration
    vc = [r for r in rows if visible_contact(r)]
    fn = [r for r in vc if r["outcome"] == "whiff"]
    fp = [r for r in rows if r["outcome"] in REG and vis_min(r) > FP_FAR and r["outcome"] != "clash"]
    P("### Visible contact vs registered outcome")
    P("- punches whose visible glove touched the visible foe (<= %.0f mm): %d of %d" % (VIS_TOUCH * 1000, len(vc), n))
    P("- FALSE NEGATIVES (visible contact, registered whiff): %d  = %s of visible contacts" % (len(fn), pct(len(fn), len(vc)).strip()))
    P("- FALSE POSITIVES (registered, nothing within %.0f mm): %d = %s of registered" % (FP_FAR * 1000, len(fp), pct(len(fp), sum(r["outcome"] in REG for r in rows)).strip()))
    P("")
    P("False-negative causes, ranked:")
    cc = Counter(fn_cause(r) for r in fn)
    for k, v in cc.most_common():
        P("  %3d  %s" % (v, k))
    P("")
    P("False-negative split by foe state / punch zone:")
    for st in states:
        sub = [r for r in vc if r["state"] == st]
        P("  %-6s visible %3d  whiff %3d (%s)" % (st, len(sub), sum(r["outcome"] == "whiff" for r in sub), pct(sum(r["outcome"] == "whiff" for r in sub), len(sub)).strip()))
    for z in ("head", "body"):
        sub = [r for r in vc if r["zone"] == z]
        P("  zone %-5s visible %3d  whiff %3d (%s)" % (z, len(sub), sum(r["outcome"] == "whiff" for r in sub), pct(sum(r["outcome"] == "whiff" for r in sub), len(sub)).strip()))
    P("")
    P("False-positive causes (registered with no visible touch):")
    cp = Counter((r["outcome"], r["why"]) for r in fp)
    for k, v in cp.most_common():
        P("  %3d  %s / %s" % (v, k[0], k[1]))
    if fp:
        worst = sorted(fp, key=lambda r: -vis_min(r))[:5]
        for r in worst:
            P("     e.g. %s %s gap %.2f foe %s: %s at visible distance %.1f cm (gameplay head %.1f / guard %.1f cm)" % (
                r["key"], r["tag"], r["gap"], r["state"], r["outcome"], vis_min(r) * 100, r["gp_head"] * 100, r["gp_guard"] * 100))
    P("")
    # --- pass-through
    P("### Pass-through on registered head hits")
    heads = [r for r in rows if r["outcome"] == "hit" and r["zone"] == "head" and r["vis_head"] <= VIS_TOUCH]
    if heads:
        deep = [r for r in heads if r["vis_head_inside"] >= 0.25]
        P("- registered clean head hits with the visible glove on the visible head: %d; glove >= 25%% inside the head at some frame: %d (%s)" % (
            len(heads), len(deep), pct(len(deep), len(heads)).strip()))
        P("- mean max share of glove samples inside the head: %.0f%%" % (100 * sum(r["vis_head_inside"] for r in heads) / len(heads)))
        late = [r for r in heads if "vis_head" in r["first_vis"] and r.get("hit_rel", -1) >= 0]
        if late:
            lag = [(r["hit_rel"] - r["first_vis"]["vis_head"]["rel"]) for r in late]
            P("- frames (8.3 ms) between the glove first touching the visible head and the hit registering: mean %.1f, max %d" % (sum(lag) / len(lag), max(lag)))
    P("")
    # --- reactions
    P("### Reaction coverage: foe motion in the 0.25 s after contact, against the no-punch control (visible skin centroids, fighter frame)")
    P("visible reaction = head or chest moved > 2 cm; for a block / parry / clash a glove moving > 2 cm counts too")
    P("| outcome | n | head > 2 cm | chest > 2 cm | glove > 2 cm | VISIBLE REACTION | median head (cm) | median chest (cm) | median glove (cm) |")
    P("|---|---|---|---|---|---|---|---|---|")

    def vis_react(r):
        if r["outcome"] in ("block", "parry", "clash"):
            return peak(r, ("Head", "Chest", "LGlove", "RGlove")) > VISIBLE
        return peak(r, ("Head", "Chest")) > VISIBLE

    def med(sub, js):
        v = sorted(peak(r, js) for r in sub)
        return v[len(v) // 2] * 100
    for oc in ("hit", "glance", "block", "parry", "clash", "evaded", "whiff"):
        sub = [r for r in rows if r["outcome"] == oc and (oc != "whiff" or visible_contact(r)) and r.get("react")]
        lbl = oc + (" (visible touch)" if oc == "whiff" else "")
        if not sub:
            P("| %s | 0 | - | - | - | - | - | - | - |" % lbl)
            continue
        h = sum(peak(r, ("Head",)) > VISIBLE for r in sub)
        c = sum(peak(r, ("Chest",)) > VISIBLE for r in sub)
        g = sum(peak(r, ("LGlove", "RGlove")) > VISIBLE for r in sub)
        v = sum(vis_react(r) for r in sub)
        P("| %s | %d | %s | %s | %s | %s | %.1f | %.1f | %.1f |" % (lbl, len(sub), pct(h, len(sub)).strip(), pct(c, len(sub)).strip(), pct(g, len(sub)).strip(),
                                                              pct(v, len(sub)).strip(), med(sub, ("Head",)), med(sub, ("Chest",)), med(sub, ("LGlove", "RGlove"))))
    sub = [r for r in rows if r["outcome"] in ("hit", "glance", "block", "parry", "clash") and r.get("react")]
    nr = [r for r in sub if not vis_react(r)]
    P("")
    P("registered outcomes with NO visible reaction: %d of %d (%s)" % (len(nr), len(sub), pct(len(nr), len(sub)).strip()))
    for oc in ("hit", "glance", "block", "parry", "clash"):
        k = [r for r in nr if r["outcome"] == oc]
        if k:
            P("    %s: %d" % (oc, len(k)))
    ctrl = [r["ctrl_noise"] for r in rows if "ctrl_noise" in r]
    if ctrl:
        P("control repeatability (two fresh no-punch runs differ by at most): %.2f mm" % (max(ctrl) * 1000))
    P("")
    # --- damage
    P("### Damage")
    P("| outcome | n | mean | min | zero (<0.01) |")
    P("|---|---|---|---|---|")
    for oc in ("hit", "glance", "block", "parry", "clash", "evaded", "whiff"):
        sub = [r for r in rows if r["outcome"] == oc]
        if not sub:
            continue
        d = [r["damage"] for r in sub]
        P("| %s | %d | %.2f | %.2f | %d |" % (oc, len(sub), sum(d) / len(d), min(d), sum(x < 0.01 for x in d)))
    zero_hit = [r for r in rows if r["outcome"] == "hit" and r["damage"] < 0.01]
    P("- registered clean hits that did zero damage: %d" % len(zero_hit))
    for r in zero_hit[:6]:
        P("     %s %s gap %.2f foe %s why=%s flags=%s dmg=%.3f" % (r["key"], r["tag"], r["gap"], r["state"], r["why"], r["info_flags"], r["damage"]))
    P("- damage by (outcome, why):")
    byw = defaultdict(list)
    for r in rows:
        byw[(r["outcome"], r["why"])].append(r["damage"])
    for k, v in sorted(byw.items(), key=lambda kv: -len(kv[1])):
        P("    %-8s %-26s n=%3d mean %.2f" % (k[0], k[1], len(v), sum(v) / len(v)))
    P("")
    # --- by gap
    P("### Hit rate by root gap (scripted, head punches, foe idle)")
    P("| gap | punches | registered | whiff | visible touch |")
    P("|---|---|---|---|---|")
    gaps = sorted({r["gap"] for r in rows if r["mode"] == "scripted"}, reverse=True)
    for g in gaps:
        sub = [r for r in rows if r["mode"] == "scripted" and abs(r["gap"] - g) < 1e-6 and r["zone"] == "head" and r["state"] == "idle"]
        if sub:
            P("| %.2f | %d | %d | %d | %d |" % (g, len(sub), sum(r["outcome"] in REG for r in sub), sum(r["outcome"] == "whiff" for r in sub), sum(visible_contact(r) for r in sub)))
    P("")
    # --- registration timing against the first visible touch
    P("### Registration timing against the visible glove first touching the visible target (frames of 8.3 ms; the fist moves 5-8 cm per frame)")
    P("(negative = the hit registered BEFORE the visible touch, positive = after it; 0 +- 1 is as good as per-frame sampling can resolve)")
    P("| fighter pair | target | n | median | within +-1 | late by > 2 | early by > 2 |")
    P("|---|---|---|---|---|---|---|")
    for cls, label, zone in (("vis_head", "head", "head"), ("vis_torso", "torso", "body")):
        by = defaultdict(list)
        for r in rows:
            fv = r["first_vis"].get(cls)
            if fv and r["zone"] == zone and r.get("hit_rel", -1) >= 0 and r["outcome"] in ("hit", "glance"):
                by[r["key"].split("|")[0]].append(r["hit_rel"] - fv["rel"])
        for k, v in sorted(by.items()):
            v.sort()
            P("| %s | %s | %d | %+d | %s | %s | %s |" % (k, label, len(v), v[len(v) // 2], pct(sum(abs(x) <= 1 for x in v), len(v)).strip(),
                                                      pct(sum(x > 2 for x in v), len(v)).strip(), pct(sum(x < -2 for x in v), len(v)).strip()))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    md = None
    if "--md" in sys.argv:
        md = sys.argv[sys.argv.index("--md") + 1]
        args = [a for a in args if a != md]
    rows = load(args)
    out = []
    report(rows, out)
    text = "\n".join(out)
    print(text)
    if md:
        open(md, "w").write(text + "\n")
