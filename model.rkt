#lang rosette

(provide (all-defined-out))
(require racket/list)


;; Events (qp optional, mainly for RDMA ops)
(struct event (id thread-id type addr val qp) #:transparent)

;; Event types are just symbols: 'read, 'write, 'fence


;; Helper to create events
(define (mk-read id tid addr val) (event id tid 'read addr val #f))
(define (mk-write id tid addr val) (event id tid 'write addr val #f))
(define (mk-fence id tid) (event id tid 'fence #f #f #f))
(define (mk-flush id tid qp) (event id tid 'flush #f #f qp))

;; Execution trace: a list of events
;; We will assume a fixed number of events for bounded verification.

;; Relations are represented as functions: (id1 id2) -> boolean

(define (make-relation trace name)
  ;; For symbolic execution, we might want to synthesize this.
  ;; But typically we define the relation based on the trace and some symbolic choices.
  ;; For now, let's assume we pass in the relation as a function.
  'placeholder)

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
  (filter (lambda (e) (and (equal? (event-type e) 'write)
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

;; Graph utilities
(define (transitive-closure rel trace)
  ;; Naive implementation for small traces
  ;; Returns a function (id1 id2) -> boolean
  (define (tc x y)
    (or (rel x y)
        (exists (lambda (z) (and (tc x z) (tc z y))) trace)))
  tc)
;; Note: The above recursive TC is not good for Rosette. 
;; Better to use matrix multiplication or iterative approach if trace size is fixed.
;; For now, let's define acyclicity directly if possible, or use a bounded unrolling.

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


;; Helper for RDMA with qp label
(define (mk-rdma-write id tid addr val qp) (event id tid 'rdma-write addr val qp))

;; Relaxed Program Order (ppo)
;; ppo includes:
;; 1. Local dependencies (e.g. addr dependency, data dependency - simplified here to just program order for local ops if we assume SC local)
;; 2. Fences order everything.
;; 3. RDMA ops are NOT ordered with local ops or other RDMA ops unless fenced.

(define (is-local? e)
  (or (equal? (event-type e) 'read)
      (equal? (event-type e) 'write)))

(define (is-fence? e)
  (equal? (event-type e) 'fence))

(define (same-qp? e1 e2)
  (and (member (event-type e1) '(rdma-write flush))
       (member (event-type e2) '(rdma-write flush))
       (equal? (event-qp e1) (event-qp e2))))

(define (ppo-relaxed trace e1 e2)
  (and (po trace e1 e2)
       (or
        ;; Strong local ordering (SC for local ops)
        (and (is-local? e1) (is-local? e2))
        ;; RDMA writes on the same QP are ordered
        (same-qp? e1 e2))))

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
