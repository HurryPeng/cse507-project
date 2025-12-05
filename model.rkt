#lang rosette

(provide (all-defined-out))
(require racket/list)


;; Events
;; mem-order: 'sc | 'acq | 'rel | 'rlx
(struct event (id thread-id type addr val mem-order) #:transparent)

;; Event types are just symbols: 'read, 'write


;; Helper to create events
(define (mk-read id tid addr val mem-order) (event id tid 'read addr val mem-order))
(define (mk-write id tid addr val mem-order) (event id tid 'write addr val mem-order))

;; Program Order (po)
;; e1 ->po e2 if same thread and e1.id < e2.id
(define (po trace e1 e2)
  (and (equal? (event-thread-id e1) (event-thread-id e2))
       (< (event-id e1) (event-id e2))))

;; Reads-From (rf)
;; e1 (write) ->rf e2 (read)
;; This is usually the thing we solve for.
;; We can represent it as a symbolic choice: for each read, choose one write.

(define (get-writes trace addr)
  (filter (lambda (e) (and (member (event-type e) '(write rdma-write))
                           (equal? (event-addr e) addr)))
          trace))

(define (get-reads trace)
  (filter (lambda (e) (equal? (event-type e) 'read)) trace))

;; Coherence Order (co)
;; Total order on writes to same address.

;; From-Read (fr)
;; r ->fr w if r reads from w' and w' ->co w
(define (fr trace rf co e1 e2)
  (ormap (lambda (w_prime)
            (and (rf w_prime e1)
                 (co w_prime e2)))
          trace))

;; Rank-based acyclicity check
(define (acyclic? rel trace)
  ;; For each event e, there exists a rank r(e).
  ;; If rel(a, b), then rank(a) < rank(b).
  (define ranks 
    (for/list ([e trace]) 
      (define-symbolic* r integer?)
      r))
  
  (define (get-rank e)
    (list-ref ranks (index-of trace e)))

  (for/and ([e1 trace] [e2 trace])
    (implies (rel e1 e2)
             (< (get-rank e1) (get-rank e2)))))

;; RDMA Events are symbols: 'rdma-write, 'rdma-read


;; Helper for RDMA
(define (mk-rdma-write id tid addr val mem-order) (event id tid 'rdma-write addr val mem-order))

;; Relaxed Program Order (ppo)
;; Simplified: only orders local ops (reads/writes) within a thread.

(define (is-local? e)
  (or (equal? (event-type e) 'read)
      (equal? (event-type e) 'write)))

(define (ppo-relaxed trace e1 e2)
  (and (po trace e1 e2)
       ;; Strong local ordering (SC for local ops)
       (and (is-local? e1) (is-local? e2))))

;; SC Program Order: everything is ordered by program order.
(define (ppo-sc trace e1 e2)
  (po trace e1 e2))

;; Consistency Axiom
;; acyclic(ppo | rf | co | fr)
;; Well-formedness checks
(define (well-formed-rf trace rf)
  (for/and ([r trace])
    (if (equal? (event-type r) 'read)
        (ormap (lambda (w) 
                  (and (rf w r)
                       (equal? (event-addr w) (event-addr r))
                       (equal? (event-val w) (event-val r))))
                trace)
        #t)))

(define (well-formed-co trace co)
  (for/and ([w1 trace] [w2 trace])
    (implies (co w1 w2)
             (and (equal? (event-addr w1) (event-addr w2))
                  (or (equal? (event-type w1) 'write) (equal? (event-type w1) 'rdma-write))
                  (or (equal? (event-type w2) 'write) (equal? (event-type w2) 'rdma-write))))))

(define (consistent? trace rf co)
  (define (union r1 r2) (lambda (x y) (or (r1 x y) (r2 x y))))
  
  (define fr-rel (lambda (x y) (fr trace rf co x y)))
  (define rf-rel (lambda (x y) (rf x y))) ;; rf is already a function/relation
  (define co-rel (lambda (x y) (co x y)))
  (define ppo-rel (lambda (x y) (ppo-relaxed trace x y)))

  (define combined-rel
    (union ppo-rel
           (union rf-rel
                  (union co-rel fr-rel))))

  (and (well-formed-rf trace rf)
       (well-formed-co trace co)
       (acyclic? combined-rel trace)))
