;;; SRFI 133 — Vector Library (R7RS-compatible)
;;;
;;; The commonly-used subset.  `vector-map`, `vector-for-each`, `vector-fill!`,
;;; `vector-copy`, `vector-copy!` and `vector-append` are R7RS names paal
;;; already binds with compatible semantics, so they are not redefined here —
;;; importing this alongside `(scheme base)` would otherwise bind one name two
;;; ways, which R7RS 5.2 makes an error.
;;;
;;; Not implemented: the multi-vector forms of vector-fold and friends beyond
;;; two vectors, vector-unfold-right's full generality, and the `!` variants
;;; that SRFI 133 marks as linear-update.

(define-library (srfi 133)
  (import (scheme base))
  (export
    vector-empty? vector= vector-count vector-index vector-index-right
    vector-skip vector-skip-right
    vector-fold vector-fold-right vector-reduce vector-reduce-right
    vector-unfold vector-unfold-right vector-unfold! vector-unfold-right!
    vector-tabulate vector-cumulate
    vector-binary-search vector-any vector-every
    vector-swap! vector-reverse! vector-reverse-copy vector-reverse-copy!
    vector-map!
    vector-concatenate vector-append-subvectors vector->list* vector-partition
    vector-find vector-take vector-drop
    reverse-vector->list reverse-list->vector)
  (begin

    (define (vector-empty? v) (= (vector-length v) 0))

    (define (vector= elt= . vs)
      (cond
        ((null? vs) #t)
        ((null? (cdr vs)) #t)
        (else
         (let outer ((a (car vs)) (rest (cdr vs)))
           (if (null? rest)
               #t
               (let ((b (car rest)))
                 (and (= (vector-length a) (vector-length b))
                      (let inner ((i 0))
                        (cond ((= i (vector-length a)) #t)
                              ((elt= (vector-ref a i) (vector-ref b i))
                               (inner (+ i 1)))
                              (else #f)))
                      (outer b (cdr rest)))))))))

    (define (vector-count pred v)
      (let loop ((i 0) (n 0))
        (if (= i (vector-length v))
            n
            (loop (+ i 1) (if (pred (vector-ref v i)) (+ n 1) n)))))

    (define (vector-index pred v)
      (let loop ((i 0))
        (cond ((= i (vector-length v)) #f)
              ((pred (vector-ref v i)) i)
              (else (loop (+ i 1))))))

    (define (vector-skip pred v)
      (vector-index (lambda (x) (not (pred x))) v))

    (define (vector-index-right pred v)
      (let loop ((i (- (vector-length v) 1)))
        (cond ((< i 0) #f)
              ((pred (vector-ref v i)) i)
              (else (loop (- i 1))))))

    (define (vector-skip-right pred v)
      (vector-index-right (lambda (x) (not (pred x))) v))

    (define (vector-find pred v)
      (let ((i (vector-index pred v)))
        (and i (vector-ref v i))))

    ;; (vector-fold kons knil v) — kons receives the accumulator first, per
    ;; SRFI 133, which is the opposite order from SRFI 1's fold.
    ;; n-ary, stopping at the shortest vector, per SRFI 133.  The
    ;; one-vector arms stay inlined so the common case pays no apply.
    (define (vector-fold kons knil v . rest)
      (if (null? rest)
          (let loop ((i 0) (acc knil))
            (if (= i (vector-length v))
                acc
                (loop (+ i 1) (kons acc (vector-ref v i)))))
          (let* ((vs (cons v rest))
                 (n (apply min (map vector-length vs))))
            (let loop ((i 0) (acc knil))
              (if (= i n)
                  acc
                  (loop (+ i 1)
                        (apply kons acc
                               (map (lambda (u) (vector-ref u i)) vs))))))))

    (define (vector-fold-right kons knil v . rest)
      (if (null? rest)
          (let loop ((i (- (vector-length v) 1)) (acc knil))
            (if (< i 0)
                acc
                (loop (- i 1) (kons acc (vector-ref v i)))))
          (let* ((vs (cons v rest))
                 (n (apply min (map vector-length vs))))
            (let loop ((i (- n 1)) (acc knil))
              (if (< i 0)
                  acc
                  (loop (- i 1)
                        (apply kons acc
                               (map (lambda (u) (vector-ref u i)) vs))))))))

    (define (vector-reduce f knil v)
      (if (vector-empty? v)
          knil
          (let loop ((i 1) (acc (vector-ref v 0)))
            (if (= i (vector-length v))
                acc
                (loop (+ i 1) (f acc (vector-ref v i)))))))

    (define (vector-reduce-right f knil v)
      (if (vector-empty? v)
          knil
          (let ((n (vector-length v)))
            (let loop ((i (- n 2)) (acc (vector-ref v (- n 1))))
              (if (< i 0)
                  acc
                  (loop (- i 1) (f acc (vector-ref v i))))))))

    ;; (vector-unfold f length seed ...) — zero or more seeds, which is
    ;; the arity kaappi's native one takes: f is called as (f i seed ...)
    ;; and answers (values elt next-seed ...).  The seedless form is the
    ;; common one, and it used to reach a three-parameter definition and
    ;; read whatever the register held.
    (define (vector-unfold f len . seeds)
      (let ((v (make-vector len)))
        (let loop ((i 0) (seeds seeds))
          (if (= i len)
              v
              (call-with-values (lambda () (apply f i seeds))
                (lambda (elt . next)
                  (vector-set! v i elt)
                  (loop (+ i 1) next)))))))

    (define (vector-tabulate proc len)
      (let ((v (make-vector len)))
        (let loop ((i 0))
          (if (= i len)
              v
              (begin (vector-set! v i (proc i)) (loop (+ i 1)))))))

    ;; The rest of the unfold family, seeds variadic throughout: f is
    ;; (f i seed ...) answering (values elt next-seed ...).  The ! variants
    ;; fill [start,end) of an existing vector, the -right ones fill from
    ;; the highest index down.
    (define (vector-unfold-right f len . seeds)
      (let ((v (make-vector len)))
        (let loop ((i (- len 1)) (seeds seeds))
          (if (< i 0)
              v
              (call-with-values (lambda () (apply f i seeds))
                (lambda (elt . next)
                  (vector-set! v i elt)
                  (loop (- i 1) next)))))))

    (define (vector-unfold! f v start end . seeds)
      (let loop ((i start) (seeds seeds))
        (if (>= i end)
            v
            (call-with-values (lambda () (apply f i seeds))
              (lambda (elt . next)
                (vector-set! v i elt)
                (loop (+ i 1) next))))))

    (define (vector-unfold-right! f v start end . seeds)
      (let loop ((i (- end 1)) (seeds seeds))
        (if (< i start)
            v
            (call-with-values (lambda () (apply f i seeds))
              (lambda (elt . next)
                (vector-set! v i elt)
                (loop (- i 1) next))))))

    ;; (vector-cumulate f knil v) — v's running fold: element i of the result
    ;; is the fold of v's first i+1 elements.
    (define (vector-cumulate f knil v)
      (let* ((len (vector-length v))
             (out (make-vector len)))
        (let loop ((i 0) (acc knil))
          (if (= i len)
              out
              (let ((acc (f acc (vector-ref v i))))
                (vector-set! out i acc)
                (loop (+ i 1) acc))))))

    ;; cmp returns negative, zero or positive.
    (define (vector-binary-search v value cmp)
      (let loop ((lo 0) (hi (- (vector-length v) 1)))
        (if (> lo hi)
            #f
            (let* ((mid (quotient (+ lo hi) 2))
                   (c   (cmp (vector-ref v mid) value)))
              (cond ((= c 0) mid)
                    ((< c 0) (loop (+ mid 1) hi))
                    (else    (loop lo (- mid 1))))))))

    (define (vector-any pred v)
      (let loop ((i 0))
        (cond ((= i (vector-length v)) #f)
              ((pred (vector-ref v i)))
              (else (loop (+ i 1))))))

    (define (vector-every pred v)
      (let loop ((i 0) (last #t))
        (cond ((= i (vector-length v)) last)
              ((pred (vector-ref v i)) => (lambda (r) (loop (+ i 1) r)))
              (else #f))))

    (define (vector-swap! v i j)
      (let ((tmp (vector-ref v i)))
        (vector-set! v i (vector-ref v j))
        (vector-set! v j tmp)))

    ;; (vector-reverse! v [start end]) — reverse the range in place.
    (define (vector-reverse! v . rest)
      (let* ((start (if (pair? rest) (car rest) 0))
             (end   (if (and (pair? rest) (pair? (cdr rest)))
                        (cadr rest) (vector-length v))))
        (let loop ((i start) (j (- end 1)))
          (if (< i j)
              (begin (vector-swap! v i j) (loop (+ i 1) (- j 1)))
              v))))

    ;; (vector-reverse-copy v [start end]) — the range, reversed, as a
    ;; fresh vector.
    (define (vector-reverse-copy v . rest)
      (let* ((start (if (pair? rest) (car rest) 0))
             (end   (if (and (pair? rest) (pair? (cdr rest)))
                        (cadr rest) (vector-length v)))
             (n (- end start))
             (out (make-vector n)))
        (let loop ((i 0))
          (if (= i n)
              out
              (begin (vector-set! out i (vector-ref v (- end 1 i)))
                     (loop (+ i 1)))))))

    ;; (vector-reverse-copy! to at from [start [end]]) — from's [start,end)
    ;; into to at `at`, reversed.  Reads before writes via an intermediate
    ;; copy, so to and from may be the same vector with overlapping ranges.
    (define (vector-reverse-copy! to at from . rest)
      (let* ((start (if (pair? rest) (car rest) 0))
             (end   (if (and (pair? rest) (pair? (cdr rest)))
                        (cadr rest) (vector-length from)))
             (n     (- end start))
             (tmp   (make-vector n)))
        (let read ((i 0))
          (when (< i n)
            (vector-set! tmp i (vector-ref from (+ start i)))
            (read (+ i 1))))
        (let write ((i 0))
          (if (= i n)
              to
              (begin
                (vector-set! to (+ at i) (vector-ref tmp (- n 1 i)))
                (write (+ i 1)))))))

    ;; (vector-map! f v ...) — like vector-map, writing into the first
    ;; vector; over the shortest length when given several.
    (define (vector-map! f v . rest)
      (let ((len (let loop ((vs rest) (n (vector-length v)))
                   (if (null? vs)
                       n
                       (loop (cdr vs) (min n (vector-length (car vs))))))))
        (let loop ((i 0))
          (if (= i len)
              v
              (begin
                (vector-set! v i
                  (apply f (vector-ref v i)
                           (map (lambda (u) (vector-ref u i)) rest)))
                (loop (+ i 1)))))))

    (define (vector-concatenate vs)
      (let* ((total (let loop ((l vs) (n 0))
                      (if (null? l) n (loop (cdr l) (+ n (vector-length (car l)))))))
             (out   (make-vector total)))
        (let loop ((l vs) (at 0))
          (if (null? l)
              out
              (let ((v (car l)))
                (let copy ((i 0))
                  (if (= i (vector-length v))
                      (loop (cdr l) (+ at (vector-length v)))
                      (begin (vector-set! out (+ at i) (vector-ref v i))
                             (copy (+ i 1))))))))))

    (define (vector->list* v start end)
      (let loop ((i (- end 1)) (acc '()))
        (if (< i start) acc (loop (- i 1) (cons (vector-ref v i) acc)))))

    (define (vector-take v n) (vector-copy v 0 n))
    (define (vector-drop v n) (vector-copy v n (vector-length v)))

    ;; Returns the reordered vector and the count of elements satisfying pred.
    (define (vector-partition pred v)
      (let* ((n   (vector-length v))
             (out (make-vector n))
             (cnt 0))
        (let loop ((i 0) (at 0))
          (if (= i n)
              (set! cnt at)
              (if (pred (vector-ref v i))
                  (begin (vector-set! out at (vector-ref v i))
                         (loop (+ i 1) (+ at 1)))
                  (loop (+ i 1) at))))
        (let loop ((i 0) (at cnt))
          (if (= i n)
              (values out cnt)
              (if (pred (vector-ref v i))
                  (loop (+ i 1) at)
                  (begin (vector-set! out at (vector-ref v i))
                         (loop (+ i 1) (+ at 1))))))))

    ;; (vector-append-subvectors v1 s1 e1 v2 s2 e2 ...) — the named ranges
    ;; appended into one fresh vector.
    (define (vector-append-subvectors . args)
      (let* ((total (let loop ((a args) (n 0))
                      (if (null? a)
                          n
                          (loop (cdddr a) (+ n (- (caddr a) (cadr a)))))))
             (out   (make-vector total)))
        (let loop ((a args) (at 0))
          (if (null? a)
              out
              (let ((v (car a)) (start (cadr a)) (end (caddr a)))
                (let copy ((i start) (at at))
                  (if (= i end)
                      (loop (cdddr a) at)
                      (begin (vector-set! out at (vector-ref v i))
                             (copy (+ i 1) (+ at 1))))))))))

    (define (reverse-vector->list v . rest)
      (let ((start (if (pair? rest) (car rest) 0))
            (end   (if (and (pair? rest) (pair? (cdr rest)))
                       (cadr rest) (vector-length v))))
        (let loop ((i start) (acc '()))
          (if (= i end)
              acc
              (loop (+ i 1) (cons (vector-ref v i) acc))))))

    (define (reverse-list->vector lst)
      (let* ((n   (length lst))
             (out (make-vector n)))
        (let loop ((l lst) (i (- n 1)))
          (if (null? l)
              out
              (begin (vector-set! out i (car l))
                     (loop (cdr l) (- i 1)))))))))
