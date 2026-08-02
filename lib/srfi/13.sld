;;; SRFI 13 — String Library
;;;
;;; Names R7RS already binds compatibly (`string-copy`, `string-append`,
;;; `string-length`, `string-ref`, `string=?` and the other comparisons,
;;; `string-upcase`/`downcase`) are not redefined — importing this alongside
;;; `(scheme base)` would otherwise bind one name two ways, which R7RS 5.2
;;; makes an error.
;;;
;;; The searching, selection and case procedures take the full SRFI 13
;;; criterion — a character, a SRFI 14 char-set, or a predicate — and the
;;; optional start/end range arguments.  Per SRFI 13, a range selects the
;;; substring the procedure operates on, and the transformers
;;; (`string-reverse`, `string-titlecase`, `string-filter`, `string-delete`,
;;; the trims and pads) answer just that range's result.  The `!`
;;; linear-update variants are not implemented.
;;;
;;; `string-split` is not SRFI 13; it is kaappi's extension, kept
;;; kaappi-compatible: the delimiter is a *string* (a character is an error
;;; there too), an empty delimiter splits into one-character strings, and
;;; adjacent delimiters produce empty strings — the inverse of
;;; `string-join`.

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

    ;; A criterion is a char, a SRFI 14 char-set, or a predicate.  The
    ;; char-set case is recognized *structurally* rather than by importing
    ;; (srfi 14): its 1134 generated lines cost a measured 5.2 s of HOST
    ;; expansion, which every (import (srfi 13)) would pay for tables most
    ;; string programs never touch.  The contract this leans on is 14's
    ;; record representation — a paal record is a vector whose slot 0 is a
    ;; (list '<type-name>) tag, and <char-set>'s one field is a sorted list
    ;; of disjoint inclusive (lo . hi) code-point ranges — and the
    ;; membership loop below is 14's own %member?, early exit included.
    ;; The srfi13-charset shelf file and the unit pins break loudly if
    ;; either side of that contract moves.
    (define (%char-set-object? x)
      (and (vector? x)
           (= (vector-length x) 2)
           (pair? (vector-ref x 0))
           (eq? (car (vector-ref x 0)) '<char-set>)))

    (define (%char-set-has? cs c)
      (let ((cp (char->integer c)))
        (let loop ((rs (vector-ref cs 1)))
          (cond ((null? rs) #f)
                ((< cp (caar rs)) #f)
                ((<= cp (cdar rs)) #t)
                (else (loop (cdr rs)))))))

    ;; Normalize a criterion to a predicate once.
    (define (%char-match crit)
      (cond ((char? crit)             (lambda (c) (char=? c crit)))
            ((%char-set-object? crit) (lambda (c) (%char-set-has? crit c)))
            (else crit)))

    ;; Trailing optional [start [end]] over s, as a (start . end) pair.
    (define (%range s rest)
      (cons (if (pair? rest) (car rest) 0)
            (if (and (pair? rest) (pair? (cdr rest)))
                (cadr rest)
                (string-length s))))

    (define (string-every crit s . rest)
      (let* ((match (%char-match crit))
             (r (%range s rest)) (end (cdr r)))
        (let loop ((i (car r)) (last #t))
          (cond ((= i end) last)
                ((match (string-ref s i)) => (lambda (v) (loop (+ i 1) v)))
                (else #f)))))

    (define (string-any crit s . rest)
      (let* ((match (%char-match crit))
             (r (%range s rest)) (end (cdr r)))
        (let loop ((i (car r)))
          (cond ((= i end) #f)
                ((match (string-ref s i)))
                (else (loop (+ i 1)))))))

    (define (string-take s n)       (substring s 0 n))
    (define (string-drop s n)       (substring s n (string-length s)))
    (define (string-take-right s n) (substring s (- (string-length s) n)
                                               (string-length s)))
    (define (string-drop-right s n) (substring s 0 (- (string-length s) n)))

    ;; Longer than len keeps the *rightmost* len characters, per SRFI 13.
    ;; (string-pad s len [char start end])
    (define (string-pad s len . rest)
      (let* ((c (if (pair? rest) (car rest) #\space))
             (r (%range s (if (pair? rest) (cdr rest) '())))
             (sub (substring s (car r) (cdr r)))
             (n (string-length sub)))
        (if (>= n len)
            (substring sub (- n len) n)
            (string-append (make-string (- len n) c) sub))))

    (define (string-pad-right s len . rest)
      (let* ((c (if (pair? rest) (car rest) #\space))
             (r (%range s (if (pair? rest) (cdr rest) '())))
             (sub (substring s (car r) (cdr r)))
             (n (string-length sub)))
        (if (>= n len)
            (substring sub 0 len)
            (string-append sub (make-string (- len n) c)))))

    ;; (string-trim s [criterion start end]) — the result is the selected
    ;; range with matching characters dropped from the relevant side.
    (define (%trim-parts rest)
      (cons (%char-match (if (pair? rest) (car rest) char-whitespace?))
            (if (pair? rest) (cdr rest) '())))

    (define (string-trim s . rest)
      (let* ((p (%trim-parts rest)) (match (car p))
             (r (%range s (cdr p))) (end (cdr r)))
        (let loop ((i (car r)))
          (cond ((= i end) "")
                ((match (string-ref s i)) (loop (+ i 1)))
                (else (substring s i end))))))

    (define (string-trim-right s . rest)
      (let* ((p (%trim-parts rest)) (match (car p))
             (r (%range s (cdr p))) (start (car r)))
        (let loop ((i (cdr r)))
          (cond ((= i start) "")
                ((match (string-ref s (- i 1))) (loop (- i 1)))
                (else (substring s start i))))))

    (define (string-trim-both s . rest)
      (let* ((p (%trim-parts rest)) (match (car p))
             (r (%range s (cdr p))) (end (cdr r)))
        (let ((a (let loop ((i (car r)))
                   (if (and (< i end) (match (string-ref s i)))
                       (loop (+ i 1))
                       i))))
          (let ((b (let loop ((i end))
                     (if (and (> i a) (match (string-ref s (- i 1))))
                         (loop (- i 1))
                         i))))
            (substring s a b)))))

    ;; (string-prefix? s1 s2 [start1 end1 start2 end2]) — is s1's range a
    ;; prefix of s2's range?  Likewise the suffix test at the other end.
    (define (%range2 s2 rest)
      (%range s2 (if (and (pair? rest) (pair? (cdr rest))) (cddr rest) '())))

    (define (string-prefix? s1 s2 . rest)
      (let* ((r1 (%range s1 rest)) (r2 (%range2 s2 rest))
             (n1 (- (cdr r1) (car r1))))
        (and (<= n1 (- (cdr r2) (car r2)))
             (string=? (substring s1 (car r1) (cdr r1))
                       (substring s2 (car r2) (+ (car r2) n1))))))

    (define (string-suffix? s1 s2 . rest)
      (let* ((r1 (%range s1 rest)) (r2 (%range2 s2 rest))
             (n1 (- (cdr r1) (car r1))))
        (and (<= n1 (- (cdr r2) (car r2)))
             (string=? (substring s1 (car r1) (cdr r1))
                       (substring s2 (- (cdr r2) n1) (cdr r2))))))

    (define (string-index s crit . rest)
      (let* ((match (%char-match crit))
             (r (%range s rest)) (end (cdr r)))
        (let loop ((i (car r)))
          (cond ((>= i end) #f)
                ((match (string-ref s i)) i)
                (else (loop (+ i 1)))))))

    (define (string-index-right s crit . rest)
      (let* ((match (%char-match crit))
             (r (%range s rest)) (start (car r)))
        (let loop ((i (- (cdr r) 1)))
          (cond ((< i start) #f)
                ((match (string-ref s i)) i)
                (else (loop (- i 1)))))))

    ;; index of the first (last) char that does NOT satisfy the criterion —
    ;; the searches string-trim conceptually runs.
    (define (string-skip s crit . rest)
      (let ((match (%char-match crit)))
        (apply string-index s (lambda (c) (not (match c))) rest)))

    (define (string-skip-right s crit . rest)
      (let ((match (%char-match crit)))
        (apply string-index-right s (lambda (c) (not (match c))) rest)))

    (define (string-rindex s crit . rest)
      (apply string-index-right s crit rest))

    ;; (string-contains s1 s2 [start1 end1 start2 end2]) — index of the
    ;; first occurrence of s2's range within s1's range, or #f.  The answer
    ;; is an index into s1 itself.
    (define (string-contains s1 s2 . rest)
      (let* ((r1 (%range s1 rest)) (r2 (%range2 s2 rest))
             (pat (substring s2 (car r2) (cdr r2)))
             (m (string-length pat)) (end (cdr r1)))
        (let loop ((i (car r1)))
          (cond ((> (+ i m) end) #f)
                ((string=? pat (substring s1 i (+ i m))) i)
                (else (loop (+ i 1)))))))

    (define (string-count s crit . rest)
      (let* ((match (%char-match crit))
             (r (%range s rest)) (end (cdr r)))
        (let loop ((i (car r)) (n 0))
          (if (= i end)
              n
              (loop (+ i 1) (if (match (string-ref s i)) (+ n 1) n))))))

    ;; (string-join strings [delimiter [grammar]]) — grammar is 'infix
    ;; (default), 'strict-infix (the empty list is an error), 'suffix or
    ;; 'prefix, per SRFI 13.  (srfi 140)'s string-join tests the suffix
    ;; grammar through this seam.
    (define (string-join strings . rest)
      (let ((delim   (if (pair? rest) (car rest) " "))
            (grammar (if (and (pair? rest) (pair? (cdr rest)))
                         (cadr rest)
                         'infix)))
        (cond
          ((null? strings)
           (if (eq? grammar 'strict-infix)
               (error "string-join: empty list with strict-infix grammar")
               ""))
          (else
           (let ((joined (let loop ((l (cdr strings)) (acc (car strings)))
                           (if (null? l)
                               acc
                               (loop (cdr l) (string-append acc delim (car l)))))))
             (case grammar
               ((suffix) (string-append joined delim))
               ((prefix) (string-append delim joined))
               (else joined)))))))

    ;; kaappi's extension, kaappi-compatible: string delimiter only (a char
    ;; is an error there too), empty delimiter splits into one-character
    ;; strings, adjacent delimiters produce empty strings.
    (define (string-split s delim)
      (let ((n (string-length s)) (m (string-length delim)))
        (if (= m 0)
            (let loop ((i (- n 1)) (acc '()))
              (if (< i 0) acc (loop (- i 1) (cons (string (string-ref s i)) acc))))
            (let loop ((i 0) (start 0) (acc '()))
              (cond
                ((> (+ i m) n) (reverse (cons (substring s start n) acc)))
                ((string=? delim (substring s i (+ i m)))
                 (loop (+ i m) (+ i m) (cons (substring s start i) acc)))
                (else (loop (+ i 1) start acc)))))))

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

    (define (string-reverse s . rest)
      (let ((r (%range s rest)))
        (list->string (reverse (string->list s (car r) (cdr r))))))

    (define (string-concatenate strings)
      (let loop ((l strings) (acc ""))
        (if (null? l) acc (loop (cdr l) (string-append acc (car l))))))

    (define (string-fold kons knil s . rest)
      (let* ((r (%range s rest)) (end (cdr r)))
        (let loop ((i (car r)) (acc knil))
          (if (= i end)
              acc
              (loop (+ i 1) (kons (string-ref s i) acc))))))

    (define (string-fold-right kons knil s . rest)
      (let* ((r (%range s rest)) (start (car r)))
        (let loop ((i (- (cdr r) 1)) (acc knil))
          (if (< i start) acc (loop (- i 1) (kons (string-ref s i) acc))))))

    (define (string-delete crit s . rest)
      (let* ((match (%char-match crit))
             (r (%range s rest)) (end (cdr r)))
        (let loop ((i (car r)) (acc '()))
          (cond ((= i end) (list->string (reverse acc)))
                ((match (string-ref s i)) (loop (+ i 1) acc))
                (else (loop (+ i 1) (cons (string-ref s i) acc)))))))

    (define (string-filter crit s . rest)
      (let ((match (%char-match crit)))
        (apply string-delete (lambda (c) (not (match c))) s rest)))

    ;; (string-replace s1 s2 start1 end1 [start2 end2]) — s1 with
    ;; [start1,end1) replaced by s2's range.
    (define (string-replace s1 s2 start1 end1 . rest)
      (let ((r2 (%range s2 rest)))
        (string-append (substring s1 0 start1)
                       (substring s2 (car r2) (cdr r2))
                       (substring s1 end1 (string-length s1)))))

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
    ;; runs as words.  A range starts a fresh word.
    (define (string-titlecase s . rest)
      (let ((r (%range s rest)))
        (let loop ((cs (string->list s (car r) (cdr r))) (in-word? #f) (acc '()))
          (if (null? cs)
              (list->string (reverse acc))
              (let ((c (car cs)))
                (if (char-alphabetic? c)
                    (loop (cdr cs) #t
                          (cons (if in-word? (char-downcase c) (char-upcase c)) acc))
                    (loop (cdr cs) #f (cons c acc))))))))))
