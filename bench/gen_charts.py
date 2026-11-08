#!/usr/bin/env python3
"""Render a benchmark Suite as standalone SVG charts, one renderer, one job (SRP).

Sibling of `gen_cross_table.py`: both read the same `bench_domain.Suite`, so a
chart and a table can never disagree about what was measured. Neither knows the
producer's YAML shape (DIP); the adapters in `bench_domain` own that.

No dependencies, the SVG is emitted as text. gnuplot/matplotlib are not
installed in this project's shell and a chart is not worth a toolchain: the
output is a file anyone can open, diff, and (unlike a PNG) read in review.

Usage:
    yq -o=json bench/cross-lang-latest.yaml | python3 bench/gen_charts.py --out docs/assets/bench
    yq -o=json bench/wasm-ffi-latest.yaml   | python3 bench/gen_charts.py --out docs/assets/bench

Which charts are emitted follows from the Suite's kind, so the caller does not
choose (and cannot mis-choose) a chart the data does not support.

Colors come from the validated reference palette (dataviz skill,
references/palette.md). Both modes ship: the light step is painted onto the
element, the dark step overrides it under `prefers-color-scheme: dark`. Every
bar carries a direct value label, the light aqua step sits below 3:1 on the
light surface, and the palette's relief rule makes visible labels the
mitigation, not an option.
"""
import os
import sys

import bench_domain as dom

# --- Palette (validated: see dataviz references/palette.md) ---------------
# Categorical slots 1-3, the only three that clear the all-pairs floors in
# both modes. A fourth series folds into "Other" or faceting rather than
# taking slot 4.
#
# Every role is (light, dark). The LIGHT value is written onto the element as a
# presentation attribute and the dark value only ever appears in a `<style>`
# override, because that is the ordering that degrades correctly: librsvg
# renders `var(--x)` as black, and GitHub strips `<style>` out of Markdown-
# embedded SVG. A chart whose colours live only in CSS is a black rectangle in
# both of those renderers, measured, not assumed.
ROLES = {
    "surface": ("#fcfcfb", "#1a1a19"),
    "ink":     ("#0b0b0b", "#ffffff"),
    "ink2":    ("#52514e", "#c3c2b7"),
    "muted":   ("#898781", "#898781"),
    "grid":    ("#e1e0d9", "#2c2c2a"),
    "axis":    ("#c3c2b7", "#383835"),
    "s1":      ("#2a78d6", "#3987e5"),
    "s2":      ("#eb6834", "#d95926"),
    "s3":      ("#1baf7a", "#199e70"),
    "pos":     ("#2a78d6", "#3987e5"),
    "neg":     ("#e34948", "#e66767"),
    "mid":     ("#f0efec", "#383835"),
    # Ink for a label that had to move ONTO a fill. White clears 3:1 against
    # both steps of every categorical slot, which the body inks do not.
    "onfill":  ("#ffffff", "#ffffff"),
}
# Roles painted with `stroke` rather than `fill`; the dark override must match.
STROKE_ROLES = {"grid", "axis"}

FONT = 'system-ui, -apple-system, "Segoe UI", sans-serif'

# Family -> categorical slot. Colour follows the ENTITY (what kind of runtime
# this is), never its rank in the chart, a re-sort must not repaint anything.
FAMILY_SLOT = {dom.SUBJECT: "s1", dom.INTERPRETER: "s2", dom.COMPILED: "s3",
               dom.WASM_HOST: "s2"}
FAMILY_LABEL = {dom.SUBJECT: "ClojureWasm (subject)",
                dom.INTERPRETER: "interpreters",
                dom.COMPILED: "compiled baselines",
                dom.WASM_HOST: "reference wasm host"}


# --- SVG primitives (pure) ------------------------------------------------

def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def light(role):
    return ROLES[role][0]


def style_block():
    """Dark-mode overrides ONLY. The light values are already on the elements,
    so a renderer that ignores or strips this block still shows a correct
    light-mode chart instead of a silhouette."""
    rules = []
    for role, (lt, dk) in ROLES.items():
        if lt == dk:
            continue
        prop = "stroke" if role in STROKE_ROLES else "fill"
        rules.append(f".r-{role}{{{prop}:{dk}}}")
    return ("<style>@media (prefers-color-scheme:dark){"
            + "".join(rules) + "}</style>")


def bar(x, y, w, h, role, r=4, flip=False):
    """A bar with its DATA end rounded (r=4) and its baseline end square, so the
    mark reads as growing from the axis. `flip` mirrors it for a left-growing
    bar in a diverging chart. Minimum width keeps a near-zero value visible."""
    w = max(w, 1.5)
    rr = min(r, w, h / 2)
    if not flip:
        d = (f"M{x:.1f},{y:.1f} H{x + w - rr:.1f} Q{x + w:.1f},{y:.1f} "
             f"{x + w:.1f},{y + rr:.1f} V{y + h - rr:.1f} "
             f"Q{x + w:.1f},{y + h:.1f} {x + w - rr:.1f},{y + h:.1f} "
             f"H{x:.1f} Z")
    else:
        d = (f"M{x + w:.1f},{y:.1f} H{x + rr:.1f} Q{x:.1f},{y:.1f} "
             f"{x:.1f},{y + rr:.1f} V{y + h - rr:.1f} "
             f"Q{x:.1f},{y + h:.1f} {x + rr:.1f},{y + h:.1f} "
             f"H{x + w:.1f} Z")
    return f'<path d="{d}" fill="{light(role)}" class="r-{role}"/>'


def vline(x, y1, y2, role="grid"):
    return (f'<line x1="{x:.1f}" y1="{y1:.1f}" x2="{x:.1f}" y2="{y2:.1f}" '
            f'stroke="{light(role)}" stroke-width="1" class="r-{role}"/>')


# Text styling rides on presentation attributes, not on a CSS class, for the
# same degradation reason as the colours.
_TEXT = {
    "ttl": ("ink", 15, 600, "normal"),
    "sub": ("ink2", 11.5, 400, "normal"),
    "lab": ("ink2", 11.5, 400, "normal"),
    "val": ("ink2", 11, 500, "tabular-nums"),
    "ax":  ("muted", 10.5, 400, "tabular-nums"),
    "valon": ("onfill", 11, 600, "tabular-nums"),
}


def text(x, y, s, cls="lab", anchor="start"):
    role, size, weight, figures = _TEXT[cls]
    return (f'<text x="{x:.1f}" y="{y:.1f}" fill="{light(role)}" '
            f'class="r-{role}" font-family=\'{FONT}\' font-size="{size}" '
            f'font-weight="{weight}" font-variant-numeric="{figures}" '
            f'text-anchor="{anchor}">{esc(s)}</text>')


def legend(x, y, entries):
    """Always present for >= 2 series, so identity is never colour-alone."""
    out, cx = [], x
    for label, role in entries:
        out.append(f'<rect x="{cx:.1f}" y="{y - 8:.1f}" width="10" height="10" '
                   f'rx="2" fill="{light(role)}" class="r-{role}"/>')
        out.append(text(cx + 15, y, label, "sub"))
        cx += 15 + 7.0 * len(label) + 22
    return "".join(out)


def frame(width, height, title, subtitle, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
            f'height="{height}" viewBox="0 0 {width} {height}" role="img" '
            f'aria-label="{esc(title)}">'
            f'{style_block()}'
            f'<rect width="{width}" height="{height}" '
            f'fill="{light("surface")}" class="r-surface"/>'
            f'{text(20, 28, title, "ttl")}'
            f'{text(20, 46, subtitle, "sub")}'
            f'{body}</svg>')


def nice_ticks(vmax, n=5):
    """Round tick steps, so the axis reads in human numbers rather than in
    whatever the data's maximum happened to be."""
    if vmax <= 0:
        return [0]
    raw = vmax / n
    mag = 10 ** (len(str(int(raw))) - 1) if raw >= 1 else 0.1
    for m in (1, 2, 2.5, 5, 10):
        if raw <= mag * m:
            step = mag * m
            break
    else:
        step = mag * 10
    ticks, t = [], 0.0
    while t <= vmax * 1.0001:
        ticks.append(t)
        t += step
    ticks.append(t)
    return ticks


# --- Chart: magnitude by runtime -----------------------------------------

def chart_runtime_medians(suite, mode=dom.COLD):
    """Median across workloads, one bar per runtime. The median (not the mean)
    because a single heavy workload should not decide a runtime's position."""
    runtimes = suite.runtimes(mode)
    workloads = suite.workloads(mode)
    meds = []
    for r in runtimes:
        vals = sorted(v for v in (suite.micros(mode, w, r) for w in workloads)
                      if v is not None)
        if not vals:
            continue
        n = len(vals)
        meds.append((r, (vals[n // 2] if n % 2 else
                         (vals[n // 2 - 1] + vals[n // 2]) / 2), n))
    meds.sort(key=lambda t: t[1])

    row, pad_t, left, right = 26, 78, 132, 92
    width, height = 860, pad_t + row * len(meds) + 54
    plot_w = width - left - right
    vmax = max(m for _, m, _ in meds)
    ticks = nice_ticks(vmax)
    scale = plot_w / ticks[-1]

    body = []
    for t in ticks:
        x = left + t * scale
        body.append(vline(x, pad_t - 10, pad_t + row * len(meds)))
        body.append(text(x, pad_t + row * len(meds) + 16,
                         suite.fmt(t), "ax", "middle"))
    for i, (r, med, n) in enumerate(meds):
        y = pad_t + i * row
        role = FAMILY_SLOT[dom.family(r)]
        # 2px surface gap between adjacent bars: bar height is row - 2 - 6.
        body.append(bar(left, y, med * scale, row - 8, role))
        body.append(text(left - 10, y + row / 2 - 1, dom.display(r), "lab", "end"))
        body.append(text(left + med * scale + 8, y + row / 2 - 1,
                         f"{suite.fmt(med)} {suite.unit}", "val"))
    body.append(vline(left, pad_t - 10, pad_t + row * len(meds), "axis"))

    fams = []
    for f in (dom.SUBJECT, dom.INTERPRETER, dom.COMPILED, dom.WASM_HOST):
        if any(dom.family(r) == f for r, _, _ in meds):
            fams.append((FAMILY_LABEL[f], FAMILY_SLOT[f]))
    body.append(legend(20, 64, fams))

    return frame(width, height,
                 f"Median {mode}-start across {len(workloads)} workloads",
                 f"lower is better · {suite.env.get('cpu', '')} · {suite.date}",
                 "".join(body))


# --- Chart: polarity, subject against its peer floor ----------------------

def chart_subject_vs_peers(suite, mode=dom.COLD, family=dom.INTERPRETER):
    """Per workload: how the subject lands against the FASTEST runtime of a peer
    family. Polarity is the job, so this is a diverging chart around 1.0, two
    hues with a neutral midline, never a rainbow. Plotted on log2 so "half the
    time" and "twice the time" are the same distance from the midline; a linear
    ratio axis squashes every win into the left tenth of the plot.

    The axis is only made SYMMETRIC when both polarities actually occur. A
    dataset that lands entirely on one side gets a one-sided axis, because a
    symmetric one would spend half the canvas, and half the legend, on a
    polarity the data does not contain.
    """
    import math
    peers = [r for r in suite.runtimes(mode)
             if dom.family(r) == family and r != "cw"]
    rows = []
    for w in suite.workloads(mode):
        mine = suite.micros(mode, w, "cw")
        best = [b for b in (suite.micros(mode, w, p) for p in peers)
                if b is not None]
        if mine is None or not best:
            continue
        rows.append((w, mine / min(best)))
    if not rows:
        return None
    rows.sort(key=lambda t: t[1])

    row, pad_t, left, right = 21, 96, 168, 118
    width, height = 860, pad_t + row * len(rows) + 46
    plot_w = width - left - right
    bottom = pad_t + row * len(rows)

    logs = [math.log2(r) for _, r in rows]
    any_faster, any_slower = any(l < 0 for l in logs), any(l > 0 for l in logs)
    pad = 1.08
    if any_faster and any_slower:
        span = max(0.6, max(abs(l) for l in logs) * pad)
        lo, hi = -span, span
    elif any_slower:
        lo, hi = 0.0, max(0.6, max(logs) * pad)
    else:
        lo, hi = min(-0.6, min(logs) * pad), 0.0

    def x_of(lg):
        return left + (lg - lo) / (hi - lo) * plot_w

    mid = x_of(0.0)
    body = [f'<rect x="{mid - 1:.1f}" y="{pad_t - 12:.1f}" width="2" '
            f'height="{row * len(rows) + 12:.1f}" fill="{light("mid")}" '
            f'class="r-mid"/>']
    for lg in range(-4, 5):
        if not lo <= lg <= hi:
            continue
        x = x_of(lg)
        if lg:
            body.append(vline(x, pad_t - 12, bottom))
        body.append(text(x, bottom + 16,
                         "1.0×" if lg == 0 else f"{2 ** lg:g}×", "ax", "middle"))

    # A difference smaller than the Suite's own dispersion is not a result.
    # Draw those neutral and say so, rather than painting noise as a win or a
    # loss: the colour is the claim, and the claim would be unsupported.
    floor = suite.noise_floor(mode)

    for i, (w, ratio) in enumerate(rows):
        y = pad_t + i * row
        x = x_of(math.log2(ratio))
        faster = ratio < 1.0
        noise = (1.0 / floor) <= ratio <= floor
        role = "mid" if noise else ("pos" if faster else "neg")
        label = ("within noise" if noise else
                 (f"{1 / ratio:.1f}× faster" if faster
                  else f"{ratio:.1f}× slower"))
        wpx = 6.2 * len(label)
        if faster:
            body.append(bar(x, y, mid - x, row - 7, role, flip=True))
            # A long bar runs its outside label into the workload-name column.
            # Move that one label onto the fill rather than shortening the scale
            # for every row: the collision is the label's problem, not the axis's.
            if x - 8 - wpx < left:
                body.append(text(x + 8, y + row / 2 - 1, label,
                                 "val" if noise else "valon"))
            else:
                body.append(text(x - 8, y + row / 2 - 1, label, "val", "end"))
        else:
            body.append(bar(mid, y, x - mid, row - 7, role))
            if x + 8 + wpx > width - 12:
                body.append(text(x - 8, y + row / 2 - 1, label,
                                 "val" if noise else "valon", "end"))
            else:
                body.append(text(x + 8, y + row / 2 - 1, label, "val"))
        body.append(text(left - 12, y + row / 2 - 1, w, "lab", "end"))

    # Only the polarities the data contains get a legend entry, a swatch for an
    # absent series invites the reader to look for marks that are not there.
    entries = ([("ClojureWasm faster", "pos")] if any_faster else []) + \
              ([("ClojureWasm slower", "neg")] if any_slower else [])
    if any(1.0 / floor <= r <= floor for _, r in rows):
        entries.append((f"within noise (<{floor:.2f}x)", "mid"))
    body.append(legend(20, 78, entries))

    # With one peer the honest headline names it; with several, the bar is the
    # FASTEST of them, which is a floor rather than an opponent.
    named = dom.display(peers[0]) if len(peers) == 1 else f"fastest {family} peer"
    eng = suite.env.get("engine")
    return frame(
        width, height,
        f"ClojureWasm vs {named}, per workload",
        f"{mode} ratio, log₂ scale · "
        + (f":engine {eng} · " if eng else
           f"peers: {', '.join(dom.display(p) for p in peers)} · ")
        + str(suite.date),
        "".join(body))


# --- Chart: two runtimes head to head -------------------------------------

def chart_head_to_head(suite, mode=dom.WARM, a="cw", b="wasmtime"):
    """Grouped bars, two series. Used for the wasm FFI Suite, where the honest
    comparison is one named runtime against one named runtime rather than a
    field."""
    workloads = [w for w in suite.workloads(mode)
                 if suite.micros(mode, w, a) is not None
                 and suite.micros(mode, w, b) is not None]
    if not workloads:
        return None
    vals = [v for w in workloads
            for v in (suite.micros(mode, w, a), suite.micros(mode, w, b))]
    vmax, vmin = max(vals), min(v for v in vals if v > 0)
    # A shared linear axis is only readable while the values stay within about
    # 1.5 orders of magnitude. Past that the largest workload owns the axis and
    # every other bar collapses to a sliver that encodes nothing, the classic
    # magnitude-span anti-pattern. Rather than eyeball it per dataset, refuse:
    # the ratio chart answers the same question scale-free, and the absolute
    # numbers stay in the table where four orders read fine.
    if vmax / vmin > 50:
        return None
    ticks = nice_ticks(vmax)

    grp, barh, pad_t, left, right = 44, 17, 92, 118, 104
    width, height = 860, pad_t + grp * len(workloads) + 46
    plot_w = width - left - right
    scale = plot_w / ticks[-1]

    body = []
    for t in ticks:
        x = left + t * scale
        body.append(vline(x, pad_t - 12, pad_t + grp * len(workloads)))
        body.append(text(x, pad_t + grp * len(workloads) + 16,
                         suite.fmt(t), "ax", "middle"))
    for i, w in enumerate(workloads):
        y = pad_t + i * grp
        for j, (rid, slot) in enumerate(((a, "s1"), (b, "s2"))):
            v = suite.micros(mode, w, rid)
            # 2px surface gap between the two bars of a group.
            yy = y + j * (barh + 2)
            body.append(bar(left, yy, v * scale, barh, slot))
            body.append(text(left + v * scale + 8, yy + barh / 2 + 3.5,
                             f"{suite.fmt(v)}", "val"))
        body.append(text(left - 12, y + barh + 2, w, "lab", "end"))
    body.append(vline(left, pad_t - 12, pad_t + grp * len(workloads), "axis"))
    body.append(legend(20, 74, [(dom.display(a), "s1"),
                                (dom.display(b), "s2")]))

    eng = suite.env.get("engine")
    return frame(
        width, height,
        f"Wasm execution: {dom.display(a)} vs {dom.display(b)} ({mode}, {suite.unit})",
        (f"same .wasm export, same in-module loop count · "
         f"{':engine ' + eng + ' · ' if eng else ''}lower is better · {suite.date}"),
        "".join(body))


# --- Boundary -------------------------------------------------------------

def main():
    argv = sys.argv[1:]
    out_dir = "."
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] == "--out":
            out_dir = argv[i + 1]
            i += 2
        else:
            rest.append(argv[i])
            i += 1

    suite = dom.load(rest, sys.stdin)
    os.makedirs(out_dir, exist_ok=True)

    # The Suite's kind picks the charts, so a caller cannot ask for one the data
    # does not support.
    if suite.kind == dom.WASM_FFI:
        charts = {
            "wasm_ffi_ratio": chart_subject_vs_peers(suite, dom.WARM,
                                                     dom.WASM_HOST),
            "wasm_ffi_warm": chart_head_to_head(suite, dom.WARM),
            "wasm_ffi_cold": chart_head_to_head(suite, dom.COLD),
        }
    else:
        charts = {"cross_lang_medians": chart_runtime_medians(suite, dom.COLD),
                  "cross_lang_vs_peers": chart_subject_vs_peers(suite, dom.COLD)}

    for name, svg in charts.items():
        if svg is None:
            continue
        path = os.path.join(out_dir, f"{name}.svg")
        with open(path, "w") as f:
            f.write(svg + "\n")
        print(path)


if __name__ == "__main__":
    main()
