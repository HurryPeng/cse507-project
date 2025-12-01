# RDMA Verification with Rosette

This project implements a solver-aided verification framework for RDMA-based ring buffers using Rosette.

## Files
- `model.rkt`: Axiomatic memory model; includes SC and Relaxed `ppo`.
- `ring_buffer.rkt`: Trace definitions for P1 (with fences) and P2 (missing fences).
- `verify.rkt`: Verification driver; runs both SC and Relaxed modes.

## Prerequisites
- Racket
- Rosette (`raco pkg install rosette`)

## Running Verification
```bash
racket verify.rkt | tee verify.log
```

## Current Results (see `verify.log`)
- **SC semantics**: P1 ✅ (no violation), P2 ✅ (strong ordering hides the bug).
- **Relaxed semantics**: P1 ✅ (fence enforces order), P2 ❌ (counterexample: reads `tail=1` but `data=0`).
