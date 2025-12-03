# RDMA Verification with Rosette

Solver-aided exploration of a tiny RDMA ring buffer under two memory semantics (SC / Relaxed). We model just enough ordering to show how missing synchronization breaks correctness.

## Files
- `model.rkt`: Axiomatic memory model; defines events, program order (ppo), RF/CO/FR relations, SC vs Relaxed differences, and QP-aware flush visibility.
- `ring_buffer.rkt`: Concrete traces for the demo programs (P1, P2a, P2b).
- `verify.rkt`: Verification driver that builds the relations, checks consistency, and searches for violations.

## Prerequisites
- Racket
- Rosette (`raco pkg install rosette`)

## Running Verification
```bash
racket verify.rkt | tee verify.log
```

## Primitives (in traces)
- `write/read`: Local CPU ops (used for consumer head updates and reads).
- `rdma-write(qp, addr, val)`: Remote write on queue pair `qp`; ordered only with ops on the same `qp`.
- `flush(qp)`: Visibility/sync on one `qp`; guarantees that earlier writes on that `qp` are visible before later ops on that `qp`. Gives **no ordering** across different QPs.

## Memory Model
- **Program order (Relaxed)**: Orders local ops within a thread and RDMA/flush ops on the *same* `qp`. Different QPs are unordered.
- **SC vs Relaxed read rule**: SC forces a read to take the latest preceding write to that address; Relaxed permits an older write unless made visible via same-QP ordering/flush.
- **No global fences/atomics**: Only per-QP ordering plus the above read rule; no cross-QP synchronization.
- **Progress assumptions**: For the demo, consumer eventually sees tail advance to the expected values so we can focus on data staleness/ordering bugs.

## Programs and Outcomes (see `verify.log`)
- **P1 (safe)**: Producer uses one QP (`qp-a`), writes `data0`, `flush`, `tail=1`, writes `data1`, `flush`, `tail=2`; consumer reads tail/data twice. Result: **UNSAT** (no violation) under SC and Relaxed—flush keeps data visible before tail.
- **P2a (bug: missing flush)**: Same QP but no flush; tail can be observed before data is visible. Result: **SAT** under SC/Relaxed—consumer can read `tail=2` while data still 0.
- **P2b (bug: cross-QP ordering gap)**: Data writes and flushes on `qp-a`, tail updates on `qp-b`; cross-QP ordering is absent. Result: **SAT** under SC/Relaxed—tail can race ahead of data across QPs.

## Caveats
- Simplified RDMA: QP ordering and per-QP flush only; no fencing, completion queues, or RDMA read/atomics.
- Current cases do not separate SC vs Relaxed outcomes because no address is written multiple times after being observed; SC only tightens the “latest write” rule.
