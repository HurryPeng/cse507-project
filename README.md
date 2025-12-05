# RDMA Verification with Rosette

Solver-aided exploration of a tiny RDMA ring buffer with per-operation memory orders (`sc`, `acq`, `rel`, `rlx`). We model just enough ordering to show how missing or misplaced synchronization breaks correctness.

## Files
- `model.rkt`: Axiomatic memory model; events carry per-op `mem-order` (`sc/acq/rel/rlx`); defines ppo, RF/CO/FR, and memory-order rules.
- `ring_buffer.rkt`: Concrete traces for the demo programs (P1, P2a, P2b) with per-op orders.
- `verify.rkt`: Verification driver that builds relations, checks consistency, and searches for violations.

## Prerequisites
- Racket
- Rosette (`raco pkg install rosette`)

## Running Verification
```bash
racket verify.rkt | tee verify.log
```

## Primitives (in traces)
- `write/read`: Local CPU ops.
- `rdma-write(addr, val, mem-order)`: Remote write with an attached memory order (`sc/acq/rel/rlx`).

## Memory Model (per-operation orders)
Each event has `mem-order ∈ {sc, acq, rel, rlx}`.
- **Relations vocabulary**:  
  - **RF (Reads-From)**: a read takes its value from exactly one write to the same address.  
  - **CO (Coherence order)**: a total order over writes to the same address.  
  - **FR (From-Read)**: if a read takes from `w`, then `fr(r, w')` when `w` is before `w'` in CO on the same address.
- **ppo (intra-thread order)**: program order on all events; no cross-thread edges unless induced by the rules below.
- **SC read latest-write**: `rf(w, r_sc) ⇒ ¬∃w2. sameAddr(w2,w) ∧ co(w,w2) ∧ rank(w2) < rank(r_sc)`.
- **SC totality**: for any distinct SC events `e1, e2`, ranks are ordered (`rank`-based acyclicity enforces this).
- **Release–Acquire hb**: `rf(w_rel, r_acq) ∧ rel(w_rel) ∧ acq(r_acq) ⇒ ∀e_pre,e_post. po(e_pre, w_rel) ∧ po(r_acq, e_post) ⇒ rank(e_pre) < rank(e_post)`.
- **Tail→Data strong sync**: if a tail read observes a tail write with `mem-order ∈ {sc, rel}` and the read is `{sc, acq}`, the corresponding data read must match the expected value.
- **Acyclicity**: `ppo ∪ rf ∪ co ∪ fr` is acyclic (rank-based).
- **Well-formed RF/CO**: RF picks exactly one same-address write with matching value per read; CO totally orders writes to the same address.

## What we check (violations)
- **Stale data after tail advance**: if consumer reads `tail ≥ k`, the paired data read must equal the expected value for slot `k`; otherwise violation.
- **Overwrite missed**: if both tail advances are seen but the second data read still equals the first round’s value (when values differ), flag violation.
- **Progress assumption**: consumer eventually reads the expected tail values (to focus on ordering/visibility issues).

## Programs and Outcomes (see `verify.log`)
- **P1 (all SC, safe)**: All ops use `sc`; tail/data pairings always match. Result: **UNSAT** (no violation).
- **P2 (all Relaxed, buggy)**: All ops `rlx`; tail can be observed before data is ordered/visible. Result: **SAT** (stale data possible).
- **P3 (Release/Acquire + Relaxed, safe)**: Producer uses `rel` for tail updates; consumer reads tail with `acq`; other ops are `rlx`. Result: **UNSAT** (no violation).

## Caveats
- Simplified single-host, multi-thread model; no RDMA network latency/QP ordering/flush semantics, no atomics beyond the mem-order rules above.
- SC/Acq/Rel here are C11-style abstractions, not hardware verbs.
