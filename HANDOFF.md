# Handoff: odoc-driver parallelism (persistent worker processes) + sherlodoc local docs

Self-contained handoff for a fresh agent. Repo: `~/dev/odoc` (an **OxCaml fork** of
`ocaml/odoc`, with `sherlodoc/` vendored in). Branch: **`odig-www-serving`**.
Switch: opam `janestreet` (`$OPAM_SWITCH_PREFIX` = `~/.opam/janestreet`), OCaml 5.x,
Eio 1.3, 128 cores, 242 GB RAM.

---

## 0. TL;DR — where things stand

Two threads of work happened in this session:

1. **(Mostly done, committed)** Fixed `sherlodoc serve` and wired its web UI to
   switch-local odoc HTML; generated docs with `odoc-driver` into `~/_html`. See §6.
2. **(ACTIVE)** Making **`odoc-driver` faster**. The driver is bottlenecked at
   ~4 CPU cores no matter `-j`. We ruled out several approaches, **shipped A2**, and
   built **A4 = persistent reused `odoc` worker processes**. A4 works: compile/link/
   html-generate now run on long-lived `odoc worker` processes, ~17–19 % faster on
   `astring` with **byte-identical HTML output**. Everything is committed (working
   tree clean). The active task is **extending/scaling A4**.

**The immediate next step in progress when we evacuated:** measuring A4 on a large
package (`core`, ~1983 units) across `-j 16/64` to see if the win grows at scale and
whether workers improve `-j` scaling. See §5 to re-run.

---

## 1. The driver-parallelism problem (well-characterized — don't re-investigate)

`odoc-driver` (`src/driver/`) documents a switch by spawning many short-lived `odoc`
subprocesses (compile-deps, compile, link, html-generate, …). Measured facts:

- It **caps at ~4 effective cores** (CPU ~360–400 %) regardless of `-j` (8/16/32/64/96
  all identical wall time) and regardless of dependency-graph breadth. Confirmed with
  `pidstat`: the driver is **one OS thread** (single Eio domain) pegged ~100 %.
- It runs on **one Eio domain** (`Eio_main.run` + `Fiber.fork_daemon` workers; no
  `Domain_manager`/`Executor_pool`). All fork/exec/pipe/wait syscalls funnel through
  that one thread, starving the workers (only 4–9 concurrent children at `-j 16`).
- **NOT** an env cap (raw busy-loop hits 1598 % at 16 cores), **NOT** disk
  (iowait 0), **NOT** the dependency critical path.
- Per-command driver-domain cost ≈ 4 ms, dominated by **per-command Eio machinery**
  (Switch + 2 pipes + `Fiber.pair` + 2 `Buf_read` drains + reaper fiber + GC), NOT the
  spawn itself (a spawn is ~0.35–0.77 ms; the big `execve`+`mmap`(~133 mmaps re-mapping
  the 25 MB odoc image) happen in the *child*, parallel/free).

### Approaches tried and the verdicts (all empirically tested — see git history / the
key learnings; **do not redo these**):

| # | Idea | Verdict |
|---|------|---------|
| **A1** | Spread spawns across OCaml domains (`Eio.Executor_pool`) | **WORSE** (13–27 s vs 10.6 s). `fork`/`clone3` doesn't parallelize across domains: kernel mm-lock contention + COW of a larger multi-heap address space. CPU never rises. |
| **A5** | Cheaper spawn (`posix_spawn`/vfork) | **REFUTED** by microbenchmark: vfork is *not* faster than fork; parent size is irrelevant (Linux COW fork is already cheap). Spawn isn't the bottleneck anyway. |
| **A3 (in-proc serial)** | Do compile-deps in-process on the main domain | **WORSE** (11.7 s). Loses the subprocesses' parallelism (serial `.cmt` parsing on one domain). |
| **A3 (across domains)** | Parse `.cmt` across `Executor_pool` domains | **domain-SAFE but 2× SLOWER** and worse with more domains. OCaml-5 **stop-the-world minor GC** barrier + per-job coordination dominates for fine-grained allocation-heavy jobs. |
| **A2** | Fix O(n²) output append + per-command env rebuild | **SHIPPED** (commit `4c6af199c`). Correct, low-risk; helps large switches. |
| **A4** | **Persistent reused processes** | **THE WIN** — see §2. |

**The deep insight that explains all the failures:** the driver's parallelism *is* the
subprocess model. The single OCaml domain is a serial dispatcher. You cannot raise
throughput by (a) moving work in-process (serial), (b) spreading across domains (shared
stop-the-world GC), or (c) cheapening spawns (not the bottleneck). **Subprocesses
parallelize where OCaml domains don't, because each has its own runtime + GC.** So the
only way to cut per-command cost while keeping parallelism is **separate REUSED
processes** (A4): independent GCs, but no repeated fork/exec/mmap.

---

## 2. A4 — persistent worker processes (THE ACTIVE WORK)

Premise (validated): one `odoc compile-deps <f>` = 6.0 ms but **99 % is process
startup** (300 files batched = 0.07 ms/file work). Every command pays that ~6 ms
startup. A persistent worker pays it once.

### 2a. Beachhead — `compile-deps` workers (commit `876cbb031`)
- odoc: `odoc compile-deps --worker` loop (`src/odoc/bin/main.ml`): read one file path
  per line on stdin, print its deps + a blank-line terminator, until EOF.
- driver: `src/driver/compile_deps_pool.ml`/`.mli` — `Stream`-based free-worker queue of
  N persistent procs; capability-probed; respawn-on-death + fallback; env gate
  `ODOC_DRIVER_NO_DEP_WORKERS`. `Odoc.compile_deps` routes through it.
- Result: ~10 % faster on astring; correct.

### 2b. Full — `compile`/`link`/`html-generate` workers (commit `7fc12be98`, msg "test")
This is the main payload. **A 6-agent audit** concluded full A4 is **feasible with a
bounded per-unit reset — no deep refactor**, because the usual blocker is *absent*: the
loader reads `.cmt`/`.cmi` directly via `Cmt_format`/`Cmi_format` and **never touches
`Load_path`/`Clflags`/`Persistent_env`/`Env.set_unit_name`**; the render side has no
global state.

**The reset checklist (run before each unit in a worker) — implemented as exported
functions, and VALIDATED complete:**
```
Odoc_model.Names.reset_unique_id ()      (* names.ml: unique_id:=None [MANDATORY] + internal_counter:=0 *)
Odoc_model.Paths.Identifier.reset_counters ()  (* paths.ml: include%d_/module_arg_%d_ counters *)
Odoc_xref2.Ident.reset ()                (* xref2/ident.ml:191 — REQUIRED for the LINK path *)
Resolver.clear_caches ()                 (* resolver.ml: process-global unit_cache (stale .odoc) + self:=None *)
Odoc_xref2.Tools.reset_caches ()         (* tools.ml — we also ADDED the omitted HandleCanonicalModuleMemo.clear *)
```
(This matches what odoc's own test harness `test/xref2/lib/common.cppo.ml` resets:
`Tools.reset_caches` + `Ident.reset`.)

**The worker** (`src/odoc/bin/main.ml`, in the final `let () =` block): special-cases
`Sys.argv = [| _; "worker" |]` *before* the normal `Cmd.eval_value`. Loop per request:
read a **count-prefixed argv** (a line with the arg count, then that many lines — robust
to empty args like `--parent-id ""`), run the reset preamble, `Cmd.eval_value ~argv
~catch:true main` (the command group `main` is reusable pure data), reply a single
`OK`/`ERR` line. `handle_error` gained a `worker_active` ref → raises `Command_failed`
instead of `exit()` so a failed unit doesn't kill the worker.

**The driver pool** (`src/driver/odoc_worker_pool.ml`/`.mli`): mirrors compile_deps_pool
but sends a full argv and reads `OK`/`ERR`. Capability-probes (`odoc worker` </dev/null
exits 0 iff supported). `run cmd : (unit, exn) result option` — `Some (Ok ())` success,
`Some (Error _)` command failed (raise → unit skipped, like one-shot), `None` =
no pool / worker died (caller falls back to one-shot). Env gate `ODOC_DRIVER_NO_WORKERS`.
`Odoc.run_odoc` (in `src/driver/odoc.ml`) routes `compile`/`link`/`html_generate`
through it; `bin/odoc_driver.ml` calls `Odoc_worker_pool.init`.

**Measured (astring, -j 16, same in-tree binary, A/B via the env gates):**
- all one-shot: 7.0 s / 536 % CPU; persistent workers: **5.8 s / 442 %** → **~17 %**.
- **FULL HTML byte-identical: 1033/1033 files.** 0 fallbacks.
- Caveat: 86/402 `.odocl` differ in *internal identifier numbering only* — benign, does
  NOT reach the rendered HTML (which is identical); worker mode is internally
  deterministic. (Likely the loader's closure-private `Implementation.counter` for
  impl/source units + page unique-id; see §4.)

---

## 3. Current git state (everything committed; tree clean)

```
7fc12be98 test                                  <- FULL A4 (compile/link/html workers + resets + worker mode). 12 files. NEEDS a real commit message.
876cbb031 add persistent compile-deps worker processes   <- A4 beachhead
4c6af199c driver: drop O(n^2) output append and per-command env rebuild   <- A2 (shipped, good msg)
4bf2aa78e Use the odoc url directly for Entry.link        <- sherlodoc local-docs link (see §6)
934193a85 support serving odig HTML                       <- sherlodoc /doc route + restored www
...
```
`git status` is clean. **`7fc12be98` has placeholder message "test"** — reword it (e.g.
`git commit --amend` if not pushed, or note for the PR): *"driver: run compile/link/
html-generate on persistent odoc worker processes"*.

---

## 4. Prioritized NEXT STEPS

1. **Finish the in-progress `core` scaling measurement** (§5). Shows if the win grows at
   scale and whether workers improve `-j` scaling (the big open question).
2. **Route the remaining odoc commands** through `Odoc_worker_pool` (mechanical, biggest
   lever on the win): in `src/driver/odoc.ml`, the `!odoc` commands that `ignore @@
   Cmd_outputs.submit ...` — `compile_impl` (~line 130), `compile_index`,
   `sidebar_generate`, `compile_asset`, `html_generate_asset`, `html_generate_source`.
   **Do NOT route**: `compile_md` (uses `!odoc_md`, a different binary), `compile_deps`
   (own pool), `classify`/count-occurrences (capture stdout). Each routed command needs
   clean stdout (warnings go to stderr) — verify the OK/ERR protocol isn't corrupted.
3. **Measure the full switch** (`odoc_driver` no args = all installed; was ~9470 units)
   — where the real 2–4× should show.
4. **Eliminate the 86 `.odocl` internal-numbering diffs** for full determinism: expose
   and reset the loader's `Implementation.counter` (`src/loader/implementation.ml:13`,
   closure-private — used for `local_%s_%d`/`def_%d` source anchors, the impl path) and
   check page/mld `--unique-id` handling. Re-run the byte-compare in §5b.
5. **Unify the two pools** (compile-deps + generic) to halve resident workers (2N → N):
   one `odoc worker` pool with a captured-stdout protocol (compile-deps needs the
   command's stdout; others just need OK/ERR).
6. Reword the `7fc12be98` commit; consider upstreaming to `ocaml/odoc` (the audit +
   reset checklist is the valuable artifact).

---

## 5. How to build / test / measure

```bash
cd ~/dev/odoc
# Build (dev). Release is barely different in speed here but use it for big runs:
dune build src/odoc/bin/main.exe src/driver/bin/odoc_driver.exe
dune build --profile release src/odoc/bin/main.exe src/driver/bin/odoc_driver.exe
INTREE=_build/default/src/odoc/bin/main.exe        # has the new `worker` mode
BIN=_build/default/src/driver/bin/odoc_driver.exe
STD="$OPAM_SWITCH_PREFIX/lib/ocaml"
```
**IMPORTANT:** the driver must use the **in-tree** odoc (`--odoc $INTREE`) for workers —
the opam odoc 3.2.1 has no `worker` mode (the pool capability-probe detects this and
cleanly falls back to one-shot).

### 5a. A/B speed (env gates disable the pools → all one-shot)
```bash
# workers OFF (baseline):
ODOC_DRIVER_NO_WORKERS=1 ODOC_DRIVER_NO_DEP_WORKERS=1 \
  $BIN astring --odoc $INTREE --odocl-dir /tmp/off-od --html-dir /tmp/off-h -j 16
# workers ON:
  $BIN astring --odoc $INTREE --odocl-dir /tmp/on-od  --html-dir /tmp/on-h  -j 16
```

### 5b. Correctness — full HTML must be byte-identical
```bash
for rel in $(cd /tmp/off-h && find . -name '*.html'); do
  cmp -s "/tmp/off-h/$rel" "/tmp/on-h/$rel" || echo "DIFFER: $rel"; done   # expect none
```

### 5c. The in-progress core scaling sweep (re-run if needed)
Script was `/tmp/cw.sh` (deleted on evacuation). Re-create: loop `M in off on`,
`J in 16 64`, run `$BIN core --odoc $INTREE --odocl-dir … --html-dir … -j $J`, time it,
record html count. core is big (~1983 units, minutes/run); run isolated (no concurrent
driver runs — they interfere with timing) and in the background.

### 5d. Direct `odoc worker` test (no driver) — proves resets are complete
```bash
# one-shot reference vs one worker process compiling all units; must be byte-identical:
F="$STD/stdlib__Map.cmti $STD/stdlib__Set.cmti $STD/stdlib__List.cmti $STD/stdlib__Format.cmti"
mkdir -p /tmp/ref /tmp/wrk
for f in $F; do $INTREE compile "$f" --parent-id pkg --output-dir /tmp/ref -I "$STD"; done
{ for f in $F; do n=8; printf '%d\ncompile\n%s\n--parent-id\npkg\n--output-dir\n/tmp/wrk\n-I\n%s\n' "$n" "$f" "$STD"; done; } | $INTREE worker
# (note: the worker protocol is COUNT-PREFIXED: a line with the arg count, then that many arg lines)
for r in $(cd /tmp/ref && find . -name '*.odoc'); do cmp -s /tmp/ref/$r /tmp/wrk/$r || echo "DIFFER $r"; done
```
Validated earlier: 6 stdlib modules → byte-identical; fault-tolerant (`OK ERR OK`).

---

## 6. The other (mostly-done) work: sherlodoc local docs + odig

Committed on this branch. Summary so the fresh agent isn't surprised by it:

- **`sherlodoc serve` "please install dream"**: the odoc-vendored sherlodoc had the
  `www` (Dream webserver) library *removed* during the subtree import (the `(select)`
  in `sherlodoc/cli/dune` could never find `www`). We **restored `sherlodoc/www/`** from
  the upstream art-w/sherlodoc commit just before its deletion, fixed ppx_blob paths
  (`www/static/…` → `sherlodoc/www/static/…`) and added `Page`/`Impl` to
  `www/ui.ml`'s `string_of_kind`. Commit `934193a85`.
- **Local docs linking**: `sherlodoc/www/www.ml` serves the odoc HTML under a
  `/doc/**` `Dream.static` route (`SHERLODOC_DOC_DIR`, default the odig cache);
  `Db.Entry.link` (`sherlodoc/db/entry.ml`) now emits `<doc_base>/<t.url>` (default
  `/doc`). For **odoc-driver** HTML the url already includes the package, so the link is
  just `doc_base ^ "/" ^ t.url` (commit `4bf2aa78e`). Indexing & serving are decoupled:
  build the DB with the **opam** sherlodoc (matching odoc magic), serve with the local
  binary. Docs were generated by `odoc_driver` into `~/_html`; a combined search DB is
  at `/tmp/sherlodoc.marshal` (may not survive evacuation).
- **`odig` is no longer needed** — `odoc-driver` (the official driver, `odoc_driver`
  binary, source in `src/driver/`) does whole-switch generation and is what we use.

There are detailed notes in `~/.claude/projects/-home-ubuntu-dev-odoc/memory/`
(`odoc-driver-parallelism.md`, `sherlodoc-local-docs-linking.md`) — **but those may not
survive evacuation**; this file is self-contained.

---

## 7. Gotchas / key facts

- **Use the in-tree odoc for the driver** (`--odoc $INTREE`); opam odoc lacks `worker`.
  The driver compiles fresh `.odoc` so the in-tree odoc's `%%VERSION%%` magic is fine
  (the magic only matters when *reading* pre-existing `.odocl`).
- **Worker protocols differ**: `compile-deps --worker` = one path/line, blank-line-
  terminated response (dep lines). Generic `worker` = **count-prefixed** argv in,
  single `OK`/`ERR` line out. Don't confuse them.
- **Don't reset** `Env.unique_id` (xref2/env.ml:25, monotonic — resetting causes env_id
  collisions) or `Cmti.read_module_expr` (one-time dispatch knot).
- Sandbox here sometimes kills long-running network servers; the worker measurements
  don't need a server. For timing, run driver measurements **isolated** (concurrent
  runs interfere).
- `git status` clean ≠ nothing to do — the A4 work is in `7fc12be98 "test"`.

---

## 8. File map (the A4 surface)

| File | Role |
|------|------|
| `src/odoc/bin/main.ml` | `worker` mode + `compile-deps --worker` + `worker_active`/`handle_error` |
| `src/model/names.ml`/`.mli` | `reset_unique_id` |
| `src/model/paths.ml`/`.mli` | `Identifier.reset_counters` |
| `src/odoc/resolver.ml`/`.mli` | `clear_caches` (unit_cache) |
| `src/xref2/tools.ml` | `reset_caches` (+ added `HandleCanonicalModuleMemo.clear`) |
| `src/xref2/ident.ml` | `reset` (already existed, exported) |
| `src/loader/implementation.ml` | `counter` (closure-private — expose for next-step §4.4) |
| `src/driver/compile_deps_pool.ml`/`.mli` | beachhead pool |
| `src/driver/odoc_worker_pool.ml`/`.mli` | generic compile/link/html pool |
| `src/driver/odoc.ml` | `run_odoc` routing + `compile_deps` routing |
| `src/driver/bin/odoc_driver.ml` | pool `init` calls |
| `src/driver/` (run.ml, worker_pool.ml, cmd_outputs.ml) | A2 changes; single-domain fiber pool (unchanged for subprocess execution) |
