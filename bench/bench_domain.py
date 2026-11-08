#!/usr/bin/env python3
"""Domain model for the benchmark tier, the CALCULATION stratum.

Pure: no I/O, no clock, no knowledge of Markdown or SVG. It owns one thing,
the vocabulary a benchmark result is expressed in, so no renderer re-derives it.

Stratification of `bench/`:

    boundary (actions)      bench/*.sh          spawn runtimes, read the clock,
                                                write the datum
    datum (data)            bench/*.yaml        inert, diffable, committed
    calculation (pure)      bench/*.py          datum -> Markdown, datum -> SVG

Ubiquitous language
-------------------
Workload      what is computed (`fib_recursive`, `sieve`). Has a KIND, because
              not every workload is comparable across every runtime.
Runtime       what computes it (`cw`, `python`, `wasmtime`). Has a FAMILY,
              because a script-vs-compiled gap is context, not a verdict.
Measurement   one (workload, runtime, mode) -> microseconds.
Suite         a machine + toolchain + date under which measurements are
              comparable. THE AGGREGATE ROOT: measurements from two Suites are
              not comparable and must never share a table or a chart. This is
              why a Linux dataset cannot "top up" a Mac one, it is a different
              Suite, not more rows.

Adapters (`from_cross_lang`, `from_wasm_ffi`) map a producer's YAML shape onto
the model. Renderers depend on the model, never on a YAML shape (DIP), so a
change to a harness's output touches exactly one adapter.
"""
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Tuple

# --- Runtimes -------------------------------------------------------------
# Order is deliberate, not a leaderboard. cljw is the subject (first). Then the
# interpreter peers it actually compares against, Python, Ruby, Node.js, and
# Babashka (a fellow JVM-free Clojure). cljw and Babashka are NOT adjacent: out
# of respect, and because the honest peer set is "interpreters", not a
# head-to-head. The compiled baselines (Java JIT, Go gc, C native) come last as
# a reference floor. TinyGo and Zig are intentionally absent: TinyGo is a Go
# variant whose role is the wasm comparison, and Zig, cljw's own
# implementation language, only restates the floor C already provides.

SUBJECT = "subject"
INTERPRETER = "interpreter"
COMPILED = "compiled"
WASM_HOST = "wasm-host"


@dataclass(frozen=True)
class Runtime:
    id: str
    display: str
    family: str


_RUNTIMES: Tuple[Runtime, ...] = (
    Runtime("cw", "ClojureWasm", SUBJECT),
    Runtime("python", "Python", INTERPRETER),
    Runtime("ruby", "Ruby", INTERPRETER),
    Runtime("node", "Node.js", INTERPRETER),
    Runtime("bb", "Babashka", INTERPRETER),
    Runtime("java", "Java", COMPILED),
    Runtime("go", "Go", COMPILED),
    Runtime("c", "C", COMPILED),
    Runtime("tgo", "TinyGo", COMPILED),
    Runtime("zig", "Zig", COMPILED),
    Runtime("wasmtime", "wasmtime", WASM_HOST),
)

BY_ID: Dict[str, Runtime] = {r.id: r for r in _RUNTIMES}

# Producers write either short (py/rb/js) or long (python/ruby/node) keys
# depending on the harness version; both name the same Runtime.
_ALIAS = {"py": "python", "rb": "ruby", "js": "node", "clojurewasm": "cw",
          "wt": "wasmtime"}

# The published cross-language column order.
CROSS_LANG_ORDER: Tuple[str, ...] = (
    "cw", "python", "ruby", "node", "bb", "java", "go", "c")

# The wasm-FFI column order: the subject against the reference wasm host.
WASM_FFI_ORDER: Tuple[str, ...] = ("cw", "wasmtime")


def runtime_id(raw: str) -> str:
    """Canonical Runtime id for a producer's key. Unknown keys pass through so
    a new runtime shows up as itself rather than silently vanishing."""
    return _ALIAS.get(raw, raw)


def display(rid: str) -> str:
    r = BY_ID.get(rid)
    return r.display if r else rid


def family(rid: str) -> str:
    r = BY_ID.get(rid)
    return r.family if r else INTERPRETER


# --- Workloads ------------------------------------------------------------
# A workload's kind decides which table it may appear in. `wasm_*` workloads
# exercise cljw's FFI surface and have no other-language source at all, so in a
# cross-language table they render as a cljw-only row with every other column
# empty, a shape that invites a comparison that was never measured. They are
# the wasm harness's workloads, and belong to its Suite.

CROSS_LANG = "cross-language"
WASM_FFI = "wasm-ffi"
# One `wasm/call` crossing, cljw-side loop, in nanoseconds: the axis the FFI
# Suite cannot see because its workloads loop inside the module. Subject-only
# (there is no wasmtime column for a cljw crossing).
WASM_PERCALL = "wasm-percall"


def workload_kind(name: str) -> str:
    return WASM_FFI if name.startswith("wasm_") else CROSS_LANG


# --- Suite ----------------------------------------------------------------

COLD = "cold"
WARM = "warm"


@dataclass(frozen=True)
class Suite:
    """Measurements taken under ONE machine + toolchain + date.

    `cells[mode][workload][runtime_id] = microseconds`. Microseconds is the
    model's internal unit; adapters convert at the boundary so no renderer
    multiplies by 1000 on its own.

    `unit` is the DISPLAY unit, and it belongs to the Suite rather than to a
    renderer: cross-language workloads land in tens of milliseconds, where µs
    resolution is the signal, while the wasm workloads run for seconds, where
    the same µs reads as six digits of false precision. A table and a chart of
    one Suite must agree about it, so it is asked of the Suite, not chosen twice.
    """
    kind: str
    env: Dict[str, str]
    date: str
    cells: Dict[str, Dict[str, Dict[str, float]]]
    startup: Dict[str, float] = field(default_factory=dict)
    unit: str = "µs"
    # sd[mode][workload][runtime_id] = microseconds of run-to-run dispersion,
    # when the producer recorded it. Empty for a Suite taken before harnesses
    # carried stddev.
    sd: Dict[str, Dict[str, Dict[str, float]]] = field(default_factory=dict)

    def fmt(self, v: Optional[float], absent: str = "-") -> str:
        """Microseconds -> the Suite's display unit, as a string."""
        if v is None:
            return absent
        if self.unit == "ns":
            return f"{round(v * 1000.0)}"
        return f"{round(v)}" if self.unit == "µs" else f"{v / 1000.0:.1f}"

    # -- queries (pure) --

    def workloads(self, mode: str = COLD) -> List[str]:
        """Workloads measured in `mode`, in the producer's order. A workload
        without a subject (`cw`) measurement is dropped: the subject is what
        every other column exists to contextualise, so a row without it is not
        a comparison."""
        return [w for w, cells in self.cells.get(mode, {}).items()
                if cells.get("cw") is not None]

    def runtimes(self, mode: str = COLD) -> List[str]:
        """Runtimes present in `mode`, in the Suite's canonical column order.
        A runtime absent from the data is dropped rather than shown empty."""
        present = {rid
                   for cells in self.cells.get(mode, {}).values()
                   for rid in cells}
        order = (WASM_FFI_ORDER if self.kind == WASM_FFI
                 else ("cw",) if self.kind == WASM_PERCALL
                 else CROSS_LANG_ORDER)
        return [rid for rid in order if rid in present]

    def micros(self, mode: str, workload: str, rid: str) -> Optional[float]:
        return self.cells.get(mode, {}).get(workload, {}).get(rid)

    def has(self, mode: str) -> bool:
        return bool(self.workloads(mode))

    # -- measurement quality --

    def rel_sd(self, mode: str = COLD) -> Optional[float]:
        """Median relative dispersion across every measurement in `mode`.
        None when the producer recorded no stddev."""
        vals = []
        for w, cells in self.sd.get(mode, {}).items():
            for rid, s in cells.items():
                m = self.micros(mode, w, rid)
                if m and s is not None:
                    vals.append(s / m)
        if not vals:
            return None
        vals.sort()
        n = len(vals)
        return vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) / 2

    def noise_floor(self, mode: str = COLD) -> float:
        """The ratio below which two measurements in this Suite are not
        distinguishable. Two independent draws each carrying sigma give a
        difference with sigma*sqrt(2), and 2 sigma is the usual bar for calling
        it real, so the floor is 1 + 2*sqrt(2)*rel_sd. A Suite with no recorded
        dispersion gets 1.0, meaning every difference is taken at face value,
        which is what the older Suites always did implicitly."""
        r = self.rel_sd(mode)
        return 1.0 if r is None else 1.0 + 2.828 * r

    def quality(self, mode: str = COLD) -> str:
        """One line a reader needs before believing any ranking here."""
        r = self.rel_sd(mode)
        bits = []
        if self.env.get("governor") and self.env["governor"] not in ("n/a", "performance"):
            bits.append(f"CPU governor `{self.env['governor']}`")
        if self.env.get("pinned") and self.env["pinned"] != "none":
            bits.append(f"pinned to `{self.env['pinned']}`")
        if r is not None:
            bits.append(f"median run-to-run dispersion **{r:.0%}**, so ratios "
                        f"under **{self.noise_floor(mode):.2f}x** are not "
                        f"distinguishable from noise")
        return "" if not bits else "_Measurement conditions: " + "; ".join(bits) + "._"

    def conditions(self) -> str:
        """One line naming what makes these measurements comparable. A chart or
        table without it is a number without a Suite."""
        e = self.env
        parts = [e.get("machine"), e.get("cpu"), e.get("ram") and f"{e['ram']} RAM",
                 e.get("os"), e.get("cljw"), e.get("wasmtime"),
                 e.get("engine") and f":engine {e['engine']}"]
        head = ", ".join(p for p in parts if p)
        tool = (f"{e.get('tool', 'hyperfine')} "
                f"**{e.get('warmup', '?')} warmup + {e.get('runs', '?')} runs**")
        tail = f", {self.date}" if self.date else ""
        return f"**Conditions:** {head}, {tool}{tail}."

    def mode_label(self, mode: str) -> str:
        """What a mode is CALLED in this Suite. "Cold-start" is a
        process-launch word: it is the right name when the thing measured is a
        whole runtime starting up, and the wrong one when both sides are
        already-running hosts executing the same module."""
        if self.kind == WASM_FFI:
            return ("Total wall-clock, module load + execution" if mode == COLD
                    else "Execution, load and startup subtracted")
        if self.kind == WASM_PERCALL:
            return "One `wasm/call` crossing, median of trials"
        return ("Cold-start wall-clock" if mode == COLD
                else "Warm, startup subtracted")

    def caveat(self) -> str:
        """The sentence that keeps the numbers from being over-read. It differs
        per Suite kind because the two Suites have different confounds, and a
        renderer is the wrong place to know which."""
        if self.kind == WASM_FFI:
            return ("_Both runtimes execute the SAME `.wasm` export with the same "
                    "in-module loop count, so this is wasm-execution against "
                    "wasm-execution, not language against language. `warm` "
                    "subtracts each runtime's own module-load + startup; at the "
                    "sub-10 ms end that subtraction is larger than the signal, so "
                    "read only the workloads that run for hundreds of ms._")
        if self.kind == WASM_PERCALL:
            return ("_The loop is on the cljw side and only the calls are timed: "
                    "one module instantiated once per engine, then trials of N "
                    "calls to a trivial `add` export. This is the axis the FFI "
                    "table above cannot see (its workloads loop inside the "
                    "module). `fn-call` is a plain Clojure function call in the "
                    "same process, the platform constant a crossing is measured "
                    "against. `-worker` rows run on a `future` thread. Engines "
                    "have opposite preferences: compute-bound bodies favour the "
                    "JIT (~15x, see `bench/wasm_jit_vs_interp.sh`), crossing-"
                    "heavy calls favour the interpreter._")
        return ("_Cold-start = process launch → exit (startup included). Only "
                "cold-start is shown: it is the metric that compares uniformly "
                "across languages. A startup-subtracted compute number is omitted "
                "because, for the fast languages, compute sits below process-spawn "
                "noise._")


# --- Adapters (YAML shape -> Suite) ---------------------------------------

def _us(ms) -> Optional[float]:
    """Producer YAML is milliseconds; the model is microseconds."""
    return None if ms is None else float(ms) * 1000.0


def from_cross_lang(data: dict) -> Suite:
    """`bench/compare_langs.sh --yaml` shape:

        benchmarks: {<workload>: {cold: {<lang>: ms}, warm: {...}}}
        startup_ms: {<lang>: ms}
    """
    cells: Dict[str, Dict[str, Dict[str, float]]] = {COLD: {}, WARM: {}}
    sd: Dict[str, Dict[str, Dict[str, float]]] = {COLD: {}, WARM: {}}
    for name, modes in (data.get("benchmarks") or {}).items():
        if workload_kind(name) != CROSS_LANG:
            continue
        for mode in (COLD, WARM):
            row = ((modes or {}).get(mode) or {})
            if row:
                cells[mode][name] = {runtime_id(k): _us(v) for k, v in row.items()}
            srow = ((modes or {}).get(f"{mode}_sd") or {})
            if srow:
                sd[mode][name] = {runtime_id(k): _us(v) for k, v in srow.items()}
    return Suite(
        kind=CROSS_LANG,
        env=data.get("env") or {},
        date=data.get("date", ""),
        cells=cells,
        startup={runtime_id(k): _us(v)
                 for k, v in (data.get("startup_ms") or {}).items()},
        sd=sd,
    )


def from_wasm_ffi(data: dict) -> Suite:
    """`bench/wasm_bench.sh --yaml` shape:

        benchmarks: {<workload>: {cold_ms: {cw: ms, wasmtime: ms}, warm_ms: {...}}}
        startup_ms: {cw: ms, wasmtime: ms}

    The env block carries `engine`, which is load-bearing here: zwasm's default
    tier is JIT-first, so the default column is JIT-vs-JIT, not interp-vs-JIT.
    """
    cells: Dict[str, Dict[str, Dict[str, float]]] = {COLD: {}, WARM: {}}
    for name, modes in (data.get("benchmarks") or {}).items():
        for mode, key in ((COLD, "cold_ms"), (WARM, "warm_ms")):
            row = ((modes or {}).get(key) or {})
            if not row:
                continue
            cells[mode][name] = {runtime_id(k): _us(v) for k, v in row.items()}
    return Suite(
        kind=WASM_FFI,
        env=data.get("env") or {},
        date=data.get("date", ""),
        cells=cells,
        startup={runtime_id(k): _us(v)
                 for k, v in (data.get("startup_ms") or {}).items()},
        unit="ms",
    )


def from_wasm_percall(data: dict) -> Suite:
    """`cljw -cp bench -m wasm-percall --yaml=FILE` shape (bench/wasm_percall.clj):

        percall_ns:            {<cell>: {median: ns, min: ns, max: ns, sd: ns}}
        platform_constant_ns:  {fn-call: {median: ns, min: ns, max: ns, sd: ns}}

    Cells are `<engine>-<thread>` (auto / jit / interp x main / worker). The
    platform constant is a workload like any other so it renders as a row the
    reader can compare against, but it is kept in its own key by the producer
    so a regression in it is distinguishable from one in the engine. Medians
    become the cell value and `sd` its dispersion, both converted to the
    model's microseconds at this boundary; the Suite displays ns.
    """
    cells: Dict[str, Dict[str, Dict[str, float]]] = {COLD: {}}
    sd: Dict[str, Dict[str, Dict[str, float]]] = {COLD: {}}
    rows = dict(data.get("percall_ns") or {})
    rows.update(data.get("platform_constant_ns") or {})
    for cell, stats in rows.items():
        stats = stats or {}
        if stats.get("median") is None:
            continue
        cells[COLD][cell] = {"cw": stats["median"] / 1000.0}
        if stats.get("sd") is not None:
            sd[COLD][cell] = {"cw": stats["sd"] / 1000.0}
    env = dict(data.get("env") or {})
    env.setdefault("tool", "bench/wasm_percall.clj")
    env.setdefault("warmup", "1")
    env.setdefault("runs", str(env.get("trials", "?")))
    return Suite(
        kind=WASM_PERCALL,
        env=env,
        date=data.get("date", ""),
        cells=cells,
        unit="ns",
        sd=sd,
    )


def detect(data: dict) -> Suite:
    """Pick the adapter from the datum's own shape, so a caller does not have to
    know which harness wrote the file."""
    if "percall_ns" in data:
        return from_wasm_percall(data)
    benches = data.get("benchmarks") or {}
    first = next(iter(benches.values()), {}) or {}
    return from_wasm_ffi(data) if "cold_ms" in first else from_cross_lang(data)


# --- Formatting helpers shared by renderers -------------------------------

def ratio(subject: Optional[float], baseline: Optional[float]) -> Optional[float]:
    if not subject or not baseline:
        return None
    return subject / baseline


def load(argv: Iterable[str], stdin) -> Suite:
    """The one I/O concession, kept here so each renderer's main() is two lines.
    Reads JSON (from `yq -o=json`) from a path argument or stdin."""
    import json
    argv = list(argv)
    raw = open(argv[0]).read() if argv else stdin.read()
    return detect(json.loads(raw))
