"""Measure how much handwriting moves DOWN vs UP while the pen touches the surface,
split into printed words and joined (cursive) words.

Data: the DeepWriting dataset (research/eval license, not included here):
  https://files.ait.ethz.ch/projects/deepwriting/deepwriting_dataset.zip
Unzip it and pass the path to deepwriting_training.npz (or _validation.npz).

    python3 measure_stroke_direction.py path/to/deepwriting_training.npz

A word counts as CURSIVE when it has 4+ characters written at >= 2.5 characters
per pen stroke (joined script), and PRINT at <= 1 character per stroke.
Coordinates follow the pad convention: y increases downward. Requires numpy.
"""
import sys
import numpy as np


def spans(start, end):
    s, e = np.flatnonzero(start), np.flatnonzero(end)
    out, k = [], 0
    for a in s:
        while k < len(e) and e[k] < a:
            k += 1
        if k >= len(e):
            break
        out.append((int(a), int(e[k])))
        k += 1
    return out


def main(path):
    d = np.load(path, allow_pickle=True)
    # Pull each array once: NpzFile decompresses again on every d[key] access.
    SL, SOW, EOW, SOC, EOC = (d["strokes"], d["sow_labels"], d["eow_labels"],
                              d["soc_labels"], d["eoc_labels"])
    mean, std = d["mean"][:2], d["std"][:2]
    acc = {g: dict(words=0, more_down=0, dn=0.0, up=0.0, end_lo=0, end_hi=0,
                   steep_dn=0.0, steep_up=0.0, ang_dn=[], ang_up=[])
           for g in ("print", "cursive")}
    for i, raw in enumerate(SL):
        raw = np.asarray(raw, float)
        if raw.ndim != 2 or len(raw) < 2:
            continue
        xy = np.cumsum(raw[:, :2] * std + mean, 0)
        pu = raw[:, 2] > 0.5
        sid = np.concatenate([[0], np.cumsum(pu[:-1])])
        chars = spans(SOC[i], EOC[i])
        for a, b in spans(SOW[i], EOW[i]):
            n_chars = sum(1 for ca, cb in chars if ca >= a and cb <= b)
            if n_chars < 4:
                continue
            ratio = n_chars / len(np.unique(sid[a:b + 1]))
            g = "cursive" if ratio >= 2.5 else ("print" if ratio <= 1.0 else None)
            if g is None:
                continue
            o = acc[g]
            mv = np.diff(xy[a:b + 1], axis=0)[~pu[a:b]]       # pen-down moves only
            dy = mv[:, 1]
            dn, up = dy[dy > 0].sum(), -dy[dy < 0].sum()
            o["words"] += 1
            o["more_down"] += int(dn > up)
            o["dn"] += dn
            o["up"] += up
            L = np.hypot(mv[:, 0], mv[:, 1])
            ang = np.degrees(np.arctan2(np.abs(dy), np.abs(mv[:, 0])))  # 90 = vertical
            steep = ang >= 60
            o["steep_dn"] += L[steep & (dy > 0)].sum()
            o["steep_up"] += L[steep & (dy < 0)].sum()
            if L[dy > 0].sum() > 0:
                o["ang_dn"].append((ang[dy > 0] * L[dy > 0]).sum() / L[dy > 0].sum())
            if L[dy < 0].sum() > 0:
                o["ang_up"].append((ang[dy < 0] * L[dy < 0]).sum() / L[dy < 0].sum())
            for k in np.unique(sid[a:b + 1]):
                ys = xy[a:b + 1, 1][sid[a:b + 1] == k]
                if len(ys) > 1:
                    o["end_lo"] += int(ys[-1] > ys[0])
                    o["end_hi"] += int(ys[-1] < ys[0])
    for g, o in acc.items():
        print(f"{g}: {o['words']} words")
        print(f"  vertical pen-down travel going down   {o['dn'] / (o['dn'] + o['up']):.1%}")
        print(f"  strokes that end lower than they start {o['end_lo'] / (o['end_lo'] + o['end_hi']):.1%}")
        print(f"  words with more down than up travel    {o['more_down'] / o['words']:.1%}")
        print(f"  steep (>= 60 deg) travel going down    {o['steep_dn'] / (o['steep_dn'] + o['steep_up']):.1%}")
        print(f"  median slope, downstrokes vs upstrokes {np.median(o['ang_dn']):.0f} vs {np.median(o['ang_up']):.0f} deg")


if __name__ == "__main__":
    main(sys.argv[1])
