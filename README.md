# RDMA Verification with Rosette

This project implements a solver-aided verification framework for RDMA-based ring buffers using Rosette.

## Files
- `model.rkt`: Axiomatic memory model; includes SC and Relaxed `ppo`.
- `ring_buffer.rkt`: Two-slot ring buffer traces (wrap-around). P1 has fences; P2 omits them.
- `verify.rkt`: Verification driver; runs both SC and Relaxed modes.

## Prerequisites
- Racket
- Rosette (`raco pkg install rosette`)

## Running Verification
```bash
racket verify.rkt | tee verify.log
```

## Current Results (see `verify.log`)
- With the current (still-rough) model both SC and Relaxed runs can produce counterexamples even for P1, highlighting that the visibility constraints need further strengthening. P2 exhibits the expected stale-read under relaxed ordering.

## Demo Story
- Two versions of an RDMA ring buffer: P1 with fences, P2 without. Producer writes data, then advances `tail`; consumer reads `tail` to decide which slot to consume and updates `head`.
- In strong ordering (SC), developers expect that once `tail` is 1/2, the corresponding data is visible. Under RDMA’s weaker ordering, `tail` can be observed before data is visible—classic “tail races ahead of data.”
- We model each version as a small trace and ask Rosette to find executions where `tail ≥ k` but `data_k` is stale. P2 quickly yields such a counterexample; P1 should be UNSAT once the visibility model is tightened. This illustrates how solver-aided verification surfaces subtle ordering bugs that are easy to miss by inspection.
