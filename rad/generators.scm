;;;
;;; Data Generators
;;;

(define-library (rad generators)

   (import
      (owl base)
      (owl sys)
      (rad shared)
      (only (owl primop) halt))

   (export 
      string->generator-priorities         ;; done at cl args parsing time
      generator-priorities->generator      ;; done after cl args
      )

   (begin

      (define (rand-block-size rs)
         (lets ((rs n (rand rs max-block-size)))
            (values rs (max n min-block-size))))

      ;; bvec|F bvec → bvec
      (define (merge head tail)
         (if head
            (list->vector (vec-foldr cons (vec-foldr cons null tail) head))
            tail))

      (define (finish rs len)
         (lets ((rs n (rand rs (+ len 1)))) ;; 1/(n+1) probability of possibly adding extra data
            (if (eq? n 0)
               (lets
                  ((rs bits (rand-range rs 1 16))
                   (rs len (rand rs (<< 1 bits)))
                   (rs bytes (random-numbers rs 256 len)))
                  (list (list->byte-vector bytes)))
               null)))

      ;; store length so that extra data can be generated in case of no or very 
      ;; little sample data, which would cause one or very few possible outputs

      (define (stream-port rs port)
         (lets ((rs first (rand-block-size rs)))
            (let loop ((rs rs) (last #false) (wanted first) (len 0)) ;; 0 = block ready (if any)
               (let ((block (get-block port wanted)))
                  (cond
                     ((eof? block) ;; end of stream
                        (if (not (eq? port stdin)) (fclose port))
                        (if last
                           (cons last (finish rs (+ len (sizeb last))))
                           (finish rs len)))
                     ((not block) ;; read error, could be treated as error
                        (if (not (eq? port stdin)) (fclose port))
                        (if last (list last) null))
                     ((eq? (sizeb block) wanted)
                        ;; a block of required (deterministic) size is ready
                        (lets
                           ((block (merge last block))
                            (rs next (rand-block-size rs)))
                           (pair block (loop rs #false next (+ len (sizeb block))))))
                     (else
                        (loop rs (merge last block)
                           (- wanted (sizeb block))
                           len)))))))

      ;; rs port → rs' (bvec ...), closes port unless stdin
      (define (port->stream rs port)
         (lets ((rs seed (rand rs 100000000000000000000)))
            (values rs
               (λ () (stream-port (seed->rands seed) port)))))

      ;; dict paths → gen
      ;; gen :: rs → rs' ll meta
      (define (stdin-generator rs online?)
         (lets 
            ((rs ll (port->stream rs stdin))
             (ll (if online? ll (force-ll ll)))) ;; preread if necessary
            (λ (rs)
               ;; note: independent of rs. could in offline case read big chunks and resplit each.
               ;; not doing now because online case is 99.9% of stdin uses
               (values rs ll (put empty 'generator 'stdin)))))

      (define (random-block rs n out)
         (if (eq? n 0)
            (values rs (list->byte-vector out))
            (lets ((digit rs (uncons rs #f)))
               (random-block rs (- n 1) (cons (fxband digit 255) out)))))

      (define (random-stream rs)
         (lets 
            ((rs n (rand-range rs 32 max-block-size))
             (rs b (random-block rs n null))
             (rs ip (rand-range rs 1 100))
             (rs o (rand rs ip)))
            (if (eq? o 0) ;; end
               (list b)
               (pair b (random-stream rs)))))
      
      (define (random-generator rs)
         (lets ((rs seed (rand rs 1111111111111111111111111111111111111)))
            (values rs 
               (random-stream (seed->rands seed))
               (put empty 'generator 'random))))

      ;; paths → (rs → rs' ll|#false meta|error-str)
      (define (file-streamer paths)
         (lets
            ((paths (list->vector paths))
             (n (vec-len paths)))
            (define (gen rs)
               (lets
                  ((rs n (rand rs n))
                   (path (vec-ref paths n))
                   (port (open-input-file path)))
                  (if port
                     (lets ((rs ll (port->stream rs port)))
                        (values rs ll 
                           (list->ff (list '(generator . file) (cons 'source path)))))
                     (begin   
                        (if (dir->list path)
                           (print*-to stderr (list "Error: failed to open '" path "'. Please use -r if you want to include samples from directories."))
                           (print*-to stderr (list "Error: failed to open '" path "'")))
                        (halt exit-read-error)))))
            gen))

      (define (string->generator-priorities str)
         (lets
            ((ps (map c/=/ (c/,/ str))) ; ((name [priority-str]) ..)
             (ps (map selection->priority ps)))
            (if (all self ps) ps #false)))

      ;; ((pri . gen) ...) → (rs → gen output)
      (define (mux-generators gs)
         (lets
            ((gs (sort car> gs))
             (n (fold + 0 (map car gs))))
            (define (gen rs)
               (lets
                  ((rs n (rand rs n)))
                  ((choose-pri gs n) rs)))
            gen))

      (define (priority->generator rs args fail n)
         ;; → (priority . generator) | #false
         (λ (pri)
            (if pri
               (lets ((name priority pri))
                  (cond
                     ((equal? name "stdin")
                        ;; a generator to read data from stdin
                        ;; check n and preread if necessary
                        (if (first (λ (x) (equal? x "-")) args #false)
                           ;; "-" was given, so start stdin generator + possibly preread
                           (cons priority
                              (stdin-generator rs (eq? n 1)))
                           #false))
                     ((equal? name "file")
                        (let ((args (keep (λ (x) (not (equal? x "-"))) args)))
                           (if (null? args)
                              #false ; no samples given, don't start this one
                              (cons priority (file-streamer args)))))
                     ((equal? name "random")
                        (cons priority random-generator))
                     (else
                        (fail (list "Unknown data generator: " name)))))
               (fail "Bad generator priority"))))

      (define (generator-priorities->generator rs pris args fail n)
         (lets 
            ((gs (map (priority->generator rs args fail n) pris))
             (gs (keep self gs)))
            (cond
               ((null? gs) (fail "no generators"))
               ((null? (cdr gs)) (cdar gs))
               (else (mux-generators gs)))))

))
