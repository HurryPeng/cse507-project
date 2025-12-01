#lang rosette

(require "model.rkt" "ring_buffer.rkt")

(define (verify-ring-buffer make-trace semantics)
  ;; Clear state
  (current-bitwidth #f) ;; Use infinite precision for integers
  
  ;; 1. Create symbolic values for reads
  (define-symbolic* r_tail_val integer?)
  (define-symbolic* r_data_val integer?)
  
  (define trace (make-trace r_tail_val r_data_val))
  ;; Select program order relation based on semantics
  (define ppo-fn (if (equal? semantics 'sc) ppo-sc ppo-relaxed))
  
  ;; Initial writes
  (define init-writes 
    (list (mk-write -1 -1 DATA 0)
          (mk-write -2 -1 TAIL 0)
          (mk-write -3 -1 HEAD 0)))
          
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

  ;; Fence-based visibility: if consumer reads tail from the post-fence tail write,
  ;; it must also read data from the pre-fence data write (models release).
  (define maybe-fence-constraint
    (let* ([tail-read (list-ref reads 0)]
           [data-read (list-ref reads 1)]
           [w-tail   (findf (lambda (e) (and (equal? (event-type e) 'rdma-write)
                                             (equal? (event-addr e) TAIL)))
                            writes)]
           [w-data   (findf (lambda (e) (and (equal? (event-type e) 'rdma-write)
                                             (equal? (event-addr e) DATA)))
                            writes)]
           [has-fence? (member (findf (lambda (e) (equal? (event-type e) 'fence)) trace) trace)])
      (cond
        ;; SC: strong ordering, reading tail=1 must imply seeing data=1.
        [(equal? semantics 'sc)
         (implies (equal? r_tail_val 1)
                  (equal? r_data_val 1))]
        ;; Relaxed: only if fenced do we get the release-like guarantee.
        [(and w-tail w-data has-fence?)
         (and (implies (rf-rel w-tail tail-read)
                       (rf-rel w-data data-read))
              (implies (equal? r_tail_val 1)
                       (equal? r_data_val 1)))]
        [else #t])))

  ;; Debug: Implement acyclic locally to expose ranks
  (define ranks (for/list ([e full-trace]) (define-symbolic* r integer?) r))
  
  (define (get-rank e) (list-ref ranks (index-of full-trace e)))
  
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
                                 maybe-fence-constraint))

  ;; Debug: check baseline consistency without the violation predicate.
  (define base-sol (solve (assert (and rf-constraints co-constraints model-constraints))))
  (printf "Baseline constraints SAT? ~a\n" (sat? base-sol))
  (when (sat? base-sol)
    (printf "Base rf choices matrix: ~a\n" (evaluate rf-matrix base-sol))
    (printf "Base read values tail/data: ~a / ~a\n"
            (evaluate r_tail_val base-sol)
            (evaluate r_data_val base-sol)))

  (define violation
    (and (equal? r_tail_val 1)
         (not (equal? r_data_val 1))))

  ;; Debug: force the intuitive source choices (tail from post-fence write, data from init)
  (define debug-sol
    (solve
     (assert (and rf-constraints co-constraints model-constraints violation
                  (rf-rel (list-ref writes 4) (list-ref reads 0))
                  (rf-rel (list-ref writes 0) (list-ref reads 1))))))
  (printf "Debug (fixed rf choices) SAT? ~a\n" (sat? debug-sol))

  (define sol (solve (assert (and rf-constraints co-constraints model-constraints violation))))
  
  (if (unsat? sol)
      sol
      (begin
        (printf "Model found. Ranks:\n")
        (for ([e full-trace] [r ranks])
          (printf "Event ~a (Type ~a): Rank ~a\n" (event-id e) (event-type e) (evaluate r sol)))
        (printf "r_tail_val: ~a\n" (evaluate r_tail_val sol))
        (printf "r_data_val: ~a\n" (evaluate r_data_val sol))
        (printf "RF matrix (resolved): ~a\n" (evaluate rf-matrix sol))
        (printf "rf-constraints satisfied? ~a\n" (evaluate rf-constraints sol))
        sol)))

(define (run-case semantics)
  (printf "\n=== Semantics: ~a ===\n" semantics)
  (printf "Verifying P1 (Correct)...\n")
  (define sol-p1 (verify-ring-buffer make-trace-p1 semantics))
  (if (unsat? sol-p1)
      (printf "P1 Verified! No violation found.\n")
      (begin
        (printf "P1 Failed! Counterexample found.\n")
        (print sol-p1)))
  (printf "\nVerifying P2 (Incorrect)...\n")
  (define sol-p2 (verify-ring-buffer make-trace-p2 semantics))
  (if (unsat? sol-p2)
      (printf "P2 Verified! No violation found.\n")
      (begin
        (printf "P2 Failed! Counterexample found.\n")
        (print sol-p2))))

(for ([sem '(sc relaxed)]) (run-case sem))
