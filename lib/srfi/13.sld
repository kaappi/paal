;;; SRFI 13 — String Library
;;;
;;; The commonly-used subset.  Names R7RS already binds compatibly
;;; (`string-copy`, `string-append`, `string-length`, `string-ref`,
;;; `string=?` and the other comparisons, `string-upcase`/`downcase`) are not
;;; redefined — importing this alongside `(scheme base)` would otherwise bind
;;; one name two ways, which R7RS 5.2 makes an error.
;;;
;;; SRFI 13's optional start/end arguments are supported on the procedures
;;; where they carry their weight; the full every-procedure treatment, the
;;; `!` linear-update variants, and the char-set arguments (which need SRFI
;;; 14) are not implemented.

(define-library (srfi 13)
  (import (scheme base) (scheme char))
  (export
    string-null? string-every string-any
    string-take string-drop string-take-right string-drop-right
    string-pad string-pad-right
    string-trim string-trim-right string-trim-both
    string-prefix? string-suffix?
    string-index string-index-right string-rindex
    string-skip string-skip-right
    string-contains string-count
    string-join string-split string-tokenize
    string-reverse string-concatenate
    string-fold string-fold-right
    string-unfold string-unfold-right
    string-tabulate string-titlecase
    string-delete string-filter string-replace)
  (begin

    (define (string-null? s) (= (string-length s) 0))

    (define (string-every pred s)
      (let loop ((i 0) (last #t))
        (cond ((= i (string-length s)) last)
              ((pred (string-ref s i)) => (lambda (v) (loop (+ i 1) v)))
              (else #f))))

    (define (string-any pred s)
      (let loop ((i 0))
        (cond ((= i (string-length s)) #f)
              ((pred (string-ref s i)))
              (else (loop (+ i 1))))))

    (define (string-take s n)       (substring s 0 n))
    (define (string-drop s n)       (substring s n (string-length s)))
    (define (string-take-right s n) (substring s (- (string-length s) n)
                                               (string-length s)))
    (define (string-drop-right s n) (substring s 0 (- (string-length s) n)))

    ;; Longer than len keeps the *rightmost* len characters, per SRFI 13.
    (define (string-pad s len . rest)
      (let ((c (if (pair? rest) (car rest) #\space))
            (n (string-length s)))
        (if (>= n len)
            (substring s (- n len) n)
            (string-append (make-string (- len n) c) s))))

    (define (string-pad-right s len . rest)
      (let ((c (if (pair? rest) (car rest) #\space))
            (n (string-length s)))
        (if (>= n len)
            (substring s 0 len)
            (string-append s (make-string (- len n) c)))))

    (define (%trim-pred rest)
      (if (pair? rest) (car rest) char-whitespace?))

    (define (string-trim s . rest)
      (let ((pred (%trim-pred rest)) (n (string-length s)))
        (let loop ((i 0))
          (cond ((= i n) "")
                ((pred (string-ref s i)) (loop (+ i 1)))
                (else (substring s i n))))))

    (define (string-trim-right s . rest)
      (let ((pred (%trim-pred rest)))
        (let loop ((i (string-length s)))
          (cond ((= i 0) "")
                ((pred (string-ref s (- i 1))) (loop (- i 1)))
                (else (substring s 0 i))))))

    (define (string-trim-both s . rest)
      (apply string-trim (apply string-trim-right s rest) rest))

    (define (string-prefix? prefix s)
      (let ((np (string-length prefix)))
        (and (<= np (string-length s))
             (string=? prefix (substring s 0 np)))))

    (define (string-suffix? suffix s)
      (let ((ns (string-length suffix)) (n (string-length s)))
        (and (<= ns n)
             (string=? suffix (substring s (- n ns) n)))))

    ;; SRFI 13 takes a char/predicate; both are accepted here.
    (define (%char-match pred)
      (if (char? pred) (lambda (c) (char=? c pred)) pred))

    (define (string-index s pred . rest)
      (let ((match (%char-match pred))
            (start (if (pair? rest) (car rest) 0))
            (end   (if (and (pair? rest) (pair? (cdr rest)))
                       (cadr rest) (string-length s))))
        (let loop ((i start))
          (cond ((>= i end) #f)
                ((match (string-ref s i)) i)
                (else (loop (+ i 1)))))))

    (define (string-index-right s pred . rest)
      (let ((match (%char-match pred))
            (start (if (pair? rest) (car rest) 0))
            (end   (if (and (pair? rest) (pair? (cdr rest)))
                       (cadr rest) (string-length s))))
        (let loop ((i (- end 1)))
          (cond ((< i start) #f)
                ((match (string-ref s i)) i)
                (else (loop (- i 1)))))))

    ;; index of the first (last) char that does NOT satisfy the criterion —
    ;; the searches string-trim conceptually runs.
    (define (string-skip s pred . rest)
      (let ((match (%char-match pred)))
        (apply string-index s (lambda (c) (not (match c))) rest)))

    (define (string-skip-right s pred . rest)
      (let ((match (%char-match pred)))
        (apply string-index-right s (lambda (c) (not (match c))) rest)))

    (define (string-rindex s pred . rest)
      (apply string-index-right s pred rest))

    ;; Index of the first occurrence of `pat` in `s`, or #f.
    (define (string-contains s pat)
      (let ((n (string-length s)) (m (string-length pat)))
        (let loop ((i 0))
          (cond ((> (+ i m) n) #f)
                ((string=? pat (substring s i (+ i m))) i)
                (else (loop (+ i 1)))))))

    (define (string-count s pred)
      (let ((match (%char-match pred)))
        (let loop ((i 0) (n 0))
          (if (= i (string-length s))
              n
              (loop (+ i 1) (if (match (string-ref s i)) (+ n 1) n))))))

    ;; (string-join strings [delimiter [grammar]]) — infix is the default.
    (define (string-join strings . rest)
      (let ((delim (if (pair? rest) (car rest) " ")))
        (if (null? strings)
            ""
            (let loop ((l (cdr strings)) (acc (car strings)))
              (if (null? l)
                  acc
                  (loop (cdr l) (string-append acc delim (car l))))))))

    ;; Split on a single character delimiter.  Adjacent delimiters produce
    ;; empty strings, which is what makes this the inverse of string-join;
    ;; string-tokenize is the variant that drops them.
    (define (string-split s ch)
      (let ((n (string-length s)))
        (let loop ((i 0) (start 0) (acc '()))
          (cond
            ((= i n) (reverse (cons (substring s start n) acc)))
            ((char=? (string-ref s i) ch)
             (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
            (else (loop (+ i 1) start acc))))))

    (define (string-tokenize s . rest)
      (let ((pred (if (pair? rest)
                      (%char-match (car rest))
                      (lambda (c) (not (char-whitespace? c)))))
            (n (string-length s)))
        (let loop ((i 0) (start #f) (acc '()))
          (cond
            ((= i n) (reverse (if start (cons (substring s start n) acc) acc)))
            ((pred (string-ref s i))
             (loop (+ i 1) (or start i) acc))
            (start (loop (+ i 1) #f (cons (substring s start i) acc)))
            (else (loop (+ i 1) #f acc))))))

    (define (string-reverse s)
      (list->string (reverse (string->list s))))

    (define (string-concatenate strings)
      (let loop ((l strings) (acc ""))
        (if (null? l) acc (loop (cdr l) (string-append acc (car l))))))

    (define (string-fold kons knil s)
      (let loop ((i 0) (acc knil))
        (if (= i (string-length s))
            acc
            (loop (+ i 1) (kons (string-ref s i) acc)))))

    (define (string-fold-right kons knil s)
      (let loop ((i (- (string-length s) 1)) (acc knil))
        (if (< i 0) acc (loop (- i 1) (kons (string-ref s i) acc)))))

    (define (string-delete pred s)
      (let ((match (%char-match pred)))
        (list->string
          (let loop ((cs (string->list s)) (acc '()))
            (cond ((null? cs) (reverse acc))
                  ((match (car cs)) (loop (cdr cs) acc))
                  (else (loop (cdr cs) (cons (car cs) acc))))))))

    (define (string-filter pred s)
      (let ((match (%char-match pred)))
        (string-delete (lambda (c) (not (match c))) s)))

    ;; (string-replace s1 s2 start end) — s1 with [start,end) replaced by s2.
    (define (string-replace s1 s2 start end)
      (string-append (substring s1 0 start) s2
                     (substring s1 end (string-length s1))))

    ;; (string-unfold p f g seed [base [make-final]]) — the list unfold with
    ;; the result accumulated as characters onto `base`, and make-final
    ;; applied to the final seed for a suffix.
    (define (string-unfold p f g seed . rest)
      (let ((base       (if (pair? rest) (car rest) ""))
            (make-final (if (and (pair? rest) (pair? (cdr rest)))
                            (cadr rest)
                            (lambda (seed) ""))))
        (let loop ((seed seed) (acc '()))
          (if (p seed)
              (string-append base (list->string (reverse acc)) (make-final seed))
              (loop (g seed) (cons (f seed) acc))))))

    (define (string-unfold-right p f g seed . rest)
      (let ((base       (if (pair? rest) (car rest) ""))
            (make-final (if (and (pair? rest) (pair? (cdr rest)))
                            (cadr rest)
                            (lambda (seed) ""))))
        (let loop ((seed seed) (acc '()))
          (if (p seed)
              (string-append (make-final seed) (list->string acc) base)
              (loop (g seed) (cons (f seed) acc))))))

    (define (string-tabulate proc len)
      (let loop ((i (- len 1)) (acc '()))
        (if (< i 0)
            (list->string acc)
            (loop (- i 1) (cons (proc i) acc)))))

    ;; Upcase each character that follows a non-alphabetic one, downcase the
    ;; rest — the word model SRFI 13 specifies for casing, with alphabetic
    ;; runs as words.
    (define (string-titlecase s)
      (let loop ((cs (string->list s)) (in-word? #f) (acc '()))
        (if (null? cs)
            (list->string (reverse acc))
            (let ((c (car cs)))
              (if (char-alphabetic? c)
                  (loop (cdr cs) #t
                        (cons (if in-word? (char-downcase c) (char-upcase c)) acc))
                  (loop (cdr cs) #f (cons c acc)))))))))
