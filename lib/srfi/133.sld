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
    vector-empty? vector= vector-count vector-index vector-skip
    vector-fold vector-fold-right vector-reduce vector-reduce-right
    vector-unfold vector-tabulate
    vector-binary-search vector-any vector-every
    vector-swap! vector-reverse! vector-reverse-copy
    vector-concatenate vector->list* vector-partition
    vector-find vector-take vector-drop)
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

    (define (vector-find pred v)
      (let ((i (vector-index pred v)))
        (and i (vector-ref v i))))

    ;; (vector-fold kons knil v) — kons receives the accumulator first, per
    ;; SRFI 133, which is the opposite order from SRFI 1's fold.
    (define (vector-fold kons knil v)
      (let loop ((i 0) (acc knil))
        (if (= i (vector-length v))
            acc
            (loop (+ i 1) (kons acc (vector-ref v i))))))

    (define (vector-fold-right kons knil v)
      (let loop ((i (- (vector-length v) 1)) (acc knil))
        (if (< i 0)
            acc
            (loop (- i 1) (kons acc (vector-ref v i))))))

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

    ;; (vector-unfold f length seed) — f returns the element for each index.
    (define (vector-unfold f len seed)
      (let ((v (make-vector len)))
        (let loop ((i 0) (seed seed))
          (if (= i len)
              v
              (call-with-values (lambda () (f i seed))
                (lambda (elt next)
                  (vector-set! v i elt)
                  (loop (+ i 1) next)))))))

    (define (vector-tabulate proc len)
      (let ((v (make-vector len)))
        (let loop ((i 0))
          (if (= i len)
              v
              (begin (vector-set! v i (proc i)) (loop (+ i 1)))))))

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

    (define (vector-reverse! v)
      (let loop ((i 0) (j (- (vector-length v) 1)))
        (if (< i j)
            (begin (vector-swap! v i j) (loop (+ i 1) (- j 1)))
            v)))

    (define (vector-reverse-copy v)
      (let* ((n (vector-length v)) (out (make-vector n)))
        (let loop ((i 0))
          (if (= i n)
              out
              (begin (vector-set! out i (vector-ref v (- n 1 i)))
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
                         (loop (+ i 1) (+ at 1))))))))))
