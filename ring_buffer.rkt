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

;; P1: Correct Synchronization with flush/publish on same QP
;; rvals: [tail0 data0 tail1 data1]
(define (make-trace-p1 rvals)
  (list
   ;; Producer publishes slot 0 and slot 1 on the same QP (ordered)
   (mk-rdma-write 1 1 DATA0 1 'qp-a)
   (mk-flush 2 1 'qp-a) ;; ensure data0 visible
   (mk-rdma-write 3 1 TAIL 1 'qp-a)
   (mk-rdma-write 4 1 DATA1 2 'qp-a)
   (mk-flush 5 1 'qp-a) ;; ensure data1 visible
   (mk-rdma-write 6 1 TAIL 2 'qp-a)

   ;; Consumer round 1
   (mk-read 7 2 TAIL (rv rvals 0))
   (mk-read 8 2 DATA0 (rv rvals 1))
   (mk-write 9 2 HEAD 1)

   ;; Consumer round 2 (wrap head back to 0)
   (mk-read 10 2 TAIL (rv rvals 2))
   (mk-read 11 2 DATA1 (rv rvals 3))
   (mk-write 12 2 HEAD 0)))

;; P2a: Cross-QP tail (no order), but data flushes exist (missing publish on tail)
(define (make-trace-p2a rvals)
  (list
   ;; Producer: same qp, no flush; tail may expose before data visible
   (mk-rdma-write 1 1 TAIL 1 'qp-a)
   (mk-rdma-write 2 1 DATA0 1 'qp-a)
   (mk-rdma-write 3 1 TAIL 2 'qp-a)
   (mk-rdma-write 4 1 DATA1 2 'qp-a)

   ;; Consumer
   (mk-read 7 2 TAIL (rv rvals 0))
   (mk-read 8 2 DATA0 (rv rvals 1))
   (mk-write 9 2 HEAD 1)
   (mk-read 10 2 TAIL (rv rvals 2))
   (mk-read 11 2 DATA1 (rv rvals 3))
   (mk-write 12 2 HEAD 0)))

;; P2b: Cross-QP tail with data flushes (order gap remains)
(define (make-trace-p2b rvals)
  (list
   ;; Producer: data on qp-a with flushes, tail on qp-b (no cross-QP order)
   (mk-rdma-write 1 1 DATA0 1 'qp-a)
   (mk-flush 2 1 'qp-a)
   (mk-rdma-write 3 1 TAIL 1 'qp-b)
   (mk-rdma-write 4 1 DATA1 2 'qp-a)
   (mk-flush 5 1 'qp-a)
   (mk-rdma-write 6 1 TAIL 2 'qp-b)

   ;; Consumer without fences
   (mk-read 5 2 TAIL (rv rvals 0))
   (mk-read 6 2 DATA0 (rv rvals 1))
   (mk-write 7 2 HEAD 1)
   (mk-read 8 2 TAIL (rv rvals 2))
   (mk-read 9 2 DATA1 (rv rvals 3))
   (mk-write 10 2 HEAD 0)))
