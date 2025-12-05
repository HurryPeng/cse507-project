#lang rosette

(require "model.rkt")
(provide (all-defined-out))

;; Addresses (two slots) and wrap-around head/tail
(define DATA0 0)
(define DATA1 1)
(define TAIL 2)
(define HEAD 3)

;; Helper to index read values
(define (rv rvals idx) (list-ref rvals idx))

;; P1: Correct Synchronization without QP/flush (ordered locally)
;; rvals: [tail0 data0 tail1 data1]
(define (make-trace-p1 rvals)
  (list
   ;; Producer publishes slot 0 and slot 1
   (mk-rdma-write 1 1 DATA0 1 'sc)
   (mk-rdma-write 2 1 TAIL 1 'sc)
   (mk-rdma-write 3 1 DATA1 2 'sc)
   (mk-rdma-write 4 1 TAIL 2 'sc)

   ;; Consumer round 1
   (mk-read 5 2 TAIL (rv rvals 0) 'sc)
   (mk-read 6 2 DATA0 (rv rvals 1) 'sc)
   (mk-write 7 2 HEAD 1 'sc)

   ;; Consumer round 2 (wrap head back to 0)
   (mk-read 8 2 TAIL (rv rvals 2) 'sc)
   (mk-read 9 2 DATA1 (rv rvals 3) 'sc)
   (mk-write 10 2 HEAD 0 'sc)))

;; P2: Missing ordering; tail may expose before data visible
(define (make-trace-p2a rvals)
  (list
   ;; Producer: tail updates issued before data is guaranteed visible
   (mk-rdma-write 1 1 TAIL 1 'rlx)
   (mk-rdma-write 2 1 DATA0 1 'rlx)
   (mk-rdma-write 3 1 TAIL 2 'rlx)
   (mk-rdma-write 4 1 DATA1 2 'rlx)

   ;; Consumer
   (mk-read 5 2 TAIL (rv rvals 0) 'rlx)
   (mk-read 6 2 DATA0 (rv rvals 1) 'rlx)
   (mk-write 7 2 HEAD 1 'rlx)
   (mk-read 8 2 TAIL (rv rvals 2) 'rlx)
   (mk-read 9 2 DATA1 (rv rvals 3) 'rlx)
   (mk-write 10 2 HEAD 0 'rlx)))

;; P3: Tail and data interleaved without explicit order (no flush/QP)
(define (make-trace-p2b rvals)
  (list
   ;; Producer without ordering primitives
   (mk-rdma-write 1 1 DATA0 1 'rlx)
   (mk-rdma-write 2 1 TAIL 1 'rel)
   (mk-rdma-write 3 1 DATA1 2 'rlx)
   (mk-rdma-write 4 1 TAIL 2 'rel)

   ;; Consumer
   (mk-read 5 2 TAIL (rv rvals 0) 'acq)
   (mk-read 6 2 DATA0 (rv rvals 1) 'rlx)
   (mk-write 7 2 HEAD 1 'rlx)
   (mk-read 8 2 TAIL (rv rvals 2) 'acq)
   (mk-read 9 2 DATA1 (rv rvals 3) 'rlx)
   (mk-write 10 2 HEAD 0 'rlx)))
