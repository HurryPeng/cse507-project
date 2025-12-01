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

;; P1: Correct Synchronization with fences around each publish/consume
;; rvals: [tail0 data0 tail1 data1]
(define (make-trace-p1 rvals)
  (list
   ;; Producer publishes slot 0
   (mk-rdma-write 1 1 DATA0 1)
   (mk-fence 2 1)
   (mk-rdma-write 3 1 TAIL 1)
   ;; Producer publishes slot 1
   (mk-rdma-write 4 1 DATA1 2)
   (mk-fence 5 1)
   (mk-rdma-write 6 1 TAIL 2)

   ;; Consumer round 1
   (mk-read 7 2 TAIL (rv rvals 0))
   (mk-fence 8 2)
   (mk-read 9 2 DATA0 (rv rvals 1))
   (mk-fence 10 2)
   (mk-write 11 2 HEAD 1)

   ;; Consumer round 2 (wrap head back to 0)
   (mk-read 12 2 TAIL (rv rvals 2))
   (mk-fence 13 2)
   (mk-read 14 2 DATA1 (rv rvals 3))
   (mk-fence 15 2)
   (mk-write 16 2 HEAD 0)))

;; P2: Missing fences; consumer may read stale data after seeing advanced tail
(define (make-trace-p2 rvals)
  (list
   ;; Producer publishes slot 0 and slot 1 without fences
   (mk-rdma-write 1 1 DATA0 1)
   (mk-rdma-write 2 1 TAIL 1)
   (mk-rdma-write 3 1 DATA1 2)
   (mk-rdma-write 4 1 TAIL 2)

   ;; Consumer without fences
   (mk-read 5 2 TAIL (rv rvals 0))
   (mk-read 6 2 DATA0 (rv rvals 1))
   (mk-write 7 2 HEAD 1)
   (mk-read 8 2 TAIL (rv rvals 2))
   (mk-read 9 2 DATA1 (rv rvals 3))
   (mk-write 10 2 HEAD 0)))
