#lang rosette

(require "model.rkt" "ring_buffer.rkt")

(define (verify-ring-buffer make-trace read-count semantics)
  ;; Clear state
  (current-bitwidth #f) ;; Use infinite precision for integers
  
  ;; 1. Create symbolic values for reads
  (define read-vals
    (for/list ([i read-count])
      (define-symbolic* rv integer?)
      rv))
  
  (define trace (make-trace read-vals))
  ;; Select program order relation based on semantics
  (define ppo-fn (if (equal? semantics 'sc) ppo-sc ppo-relaxed))
  
  ;; Initial writes
  (define init-writes 
    (list (mk-write -1 -1 DATA0 0)
          (mk-write -2 -1 DATA1 0)
          (mk-write -3 -1 TAIL 0)
          (mk-write -4 -1 HEAD 0)))
          
  (define full-trace (append init-writes trace))
  
  ;; 2. Synthesize RF (one-hot choices per read)
  (define reads (filter (lambda (e) (equal? (event-type e) 'read)) full-trace))
  (define writes (filter (lambda (e) (or (equal? (event-type e) 'write) 
                                         (equal? (event-type e) 'rdma-write))) full-trace))

  (printf "Reads: ~a\n" reads)
  (printf "Writes: ~a\n" writes)

  (define rf-matrix
    (for/list ([r reads])
      (for/list ([w writes])
        (define-symbolic* b boolean?)
        b)))

  (define (rf-rel w r)
    (define r-idx (index-of reads r))
    (define w-idx (index-of writes w))
    (and r-idx w-idx
         (list-ref (list-ref rf-matrix r-idx) w-idx)))

  (define (bool->int b) (if b 1 0))

  (define rf-constraints
    (for/and ([r reads] [ri (in-naturals)])
      (define choices (list-ref rf-matrix ri))
      (and
       (= 1 (apply + (map bool->int choices)))
       (for/and ([w writes] [wi (in-naturals)])
         (implies (list-ref choices wi)
                  (and (equal? (event-addr r) (event-addr w))
                       (equal? (event-val r) (event-val w)))))
       ;; Make the chosen value explicit to avoid underspecified models
       (= (event-val r)
          (apply + (for/list ([w writes] [wi (in-naturals)])
                     (* (bool->int (list-ref choices wi))
                        (event-val w))))))))

  ;; 3. Synthesize CO
  ;; We only care about CO for same address.
  (define write-ranks
    (for/list ([w writes])
      (define-symbolic* rank integer?)
      rank))
      
  (define (get-co-rank w)
    (list-ref write-ranks (index-of writes w)))
    
  (define co-constraints
    (for/and ([w1 writes] [w2 writes])
      (and
       ;; Total order logic
       (implies (and (equal? (event-addr w1) (event-addr w2))
                     (not (equal? w1 w2)))
                (not (equal? (get-co-rank w1) (get-co-rank w2))))
       ;; Init is first
       (implies (and (equal? (event-addr w1) (event-addr w2))
                     (< (event-id w1) 0) ;; w1 is init
                     (> (event-id w2) 0)) ;; w2 is not init
                (< (get-co-rank w1) (get-co-rank w2))))))

  (define (co-rel w1 w2)
    (and (member w1 writes) (member w2 writes)
         (equal? (event-addr w1) (event-addr w2))
         (< (get-co-rank w1) (get-co-rank w2))))

  ;; Ranks for combined relation (used for acyclicity and visibility checks)
  (define ranks (for/list ([e full-trace]) (define-symbolic* r integer?) r))
  (define (get-rank e) (list-ref ranks (index-of full-trace e)))

  ;; Latest-visible constraint: a read cannot select an older write if a later
  ;; co-write appears earlier in the execution (by rank). Approximates "read most recent visible".
  (define latest-visible-constraint
    (for/and ([r reads] [w writes])
      (implies (rf-rel w r)
               (for/and ([w2 writes])
                 (implies (and (equal? (event-addr w2) (event-addr w))
                               (co-rel w w2)
                               (< (get-rank w2) (get-rank r)))
                          #f)))))

  ;; Release-acquire style: if a read observes a write w_rel, then any producer
  ;; write w_pre that is ppo-before w_rel must become visible to subsequent reads
  ;; of the same address in the reading thread.
  (define release-acquire-constraint
    (for/and ([r_acq reads] [w_rel writes])
      (implies (rf-rel w_rel r_acq)
               (for/and ([w_pre writes])
                 (implies (and (equal? (event-thread-id w_pre) (event-thread-id w_rel))
                               (ppo-fn full-trace w_pre w_rel))
                          (for/and ([r_use reads])
                            (implies (and (ppo-fn full-trace r_acq r_use)
                                          (equal? (event-addr r_use) (event-addr w_pre)))
                                     (and (< (get-rank w_pre) (get-rank r_use))
                                          (for/and ([w_src writes])
                                            (implies (rf-rel w_src r_use)
                                                     (not (co-rel w_src w_pre))))))))))))

  ;; Derived happens-before: if r_acq reads from w_rel, then anything ppo-before w_rel
  ;; must happen before anything ppo-after r_acq.
  (define derived-hb-constraint
    (for/and ([r_acq reads] [w_rel writes])
      (implies (rf-rel w_rel r_acq)
               (for/and ([w_pre writes])
                 (implies (ppo-fn full-trace w_pre w_rel)
                          (for/and ([e_post full-trace])
                            (implies (ppo-fn full-trace r_acq e_post)
                                     (< (get-rank w_pre) (get-rank e_post)))))))))

  (define acyclic-constraints
    (for/and ([e1 full-trace] [e2 full-trace])
      (let ([rel (or (ppo-fn full-trace e1 e2)
                     (rf-rel e1 e2)
                     (co-rel e1 e2)
                     (fr full-trace rf-rel co-rel e1 e2))])
        (implies rel (< (get-rank e1) (get-rank e2))))))
        
  (define model-constraints (and (well-formed-rf full-trace rf-rel)
                                 (well-formed-co full-trace co-rel)
                                 acyclic-constraints
                                 latest-visible-constraint
                                 release-acquire-constraint
                                 derived-hb-constraint))

  ;; Debug: check baseline consistency without the violation predicate.
  (define base-sol (solve (assert (and rf-constraints co-constraints model-constraints))))
  (printf "Baseline constraints SAT? ~a\n" (sat? base-sol))
  (when (sat? base-sol)
    (printf "Base rf choices matrix: ~a\n" (evaluate rf-matrix base-sol))
    (printf "Base read values: ~a\n"
            (evaluate read-vals base-sol)))

  ;; Violation: if consumer sees tail>=k, corresponding data_k should match.
  (define (stale? idx tail-expected data-expected)
    (and (>= (list-ref read-vals idx) tail-expected)
         (not (equal? (list-ref read-vals (add1 idx)) data-expected))))
  ;; We expect two rounds: tail/data pairs at indices 0/1 and 2/3.
  (define violation
    (or (stale? 0 1 1)
        (stale? 2 2 2)))

  ;; Debug: force the intuitive source choices (tail from post-fence write, data from init)
  (printf "Debug (fixed rf choices) skipped in generalized model.\n")

  (define sol (solve (assert (and rf-constraints co-constraints model-constraints violation))))
  
  (if (unsat? sol)
      sol
      (begin
        (printf "Model found. Ranks:\n")
        (for ([e full-trace] [r ranks])
          (printf "Event ~a (Type ~a): Rank ~a\n" (event-id e) (event-type e) (evaluate r sol)))
        (printf "Read values: ~a\n" (evaluate read-vals sol))
        (printf "RF matrix (resolved): ~a\n" (evaluate rf-matrix sol))
        (printf "rf-constraints satisfied? ~a\n" (evaluate rf-constraints sol))
        (printf "latest-visible? ~a\n" (evaluate latest-visible-constraint sol))
        (printf "release-acquire? ~a\n" (evaluate release-acquire-constraint sol))
        (printf "derived-hb? ~a\n" (evaluate derived-hb-constraint sol))
        sol)))

(define (run-case semantics)
  (printf "\n=== Semantics: ~a ===\n" semantics)
  (printf "Verifying P1 (Correct)...\n")
  (define sol-p1 (verify-ring-buffer make-trace-p1 4 semantics))
  (if (unsat? sol-p1)
      (printf "P1 Verified! No violation found.\n")
      (begin
        (printf "P1 Failed! Counterexample found.\n")
        (print sol-p1)))
  (printf "\nVerifying P2 (Incorrect)...\n")
  (define sol-p2 (verify-ring-buffer make-trace-p2 4 semantics))
  (if (unsat? sol-p2)
      (printf "P2 Verified! No violation found.\n")
      (begin
        (printf "P2 Failed! Counterexample found.\n")
        (print sol-p2))))

(for ([sem '(sc relaxed)]) (run-case sem))
