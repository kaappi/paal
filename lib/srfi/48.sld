;;; SRFI 48 — Intermediate Format Strings
;;;
;;; Adds ~d ~b ~o ~x (radix), ~c (character), ~w (write), ~y (pretty-print,
;;; here the same as write since paal has no pretty printer), ~? / ~k
;;; (recursive format), ~_ (space), ~t (tab), ~& (freshline), ~h (help) and
;;; the column-aligned numeric directive ~[w[,d]]F to SRFI 28's set —
;;; matching the directive set of kaappi's (srfi 48).
;;;
;;; Like SRFI 28's, `format` here takes the format string first.  SRFI 48 also
;;; allows a leading port or #f/#t argument; that form is supported.
(define-library (srfi 48)
  (import (scheme base) (scheme char) (scheme write))
  (export format)
  (begin
    (define (%pad-left s width)
      (let ((slen (string-length s)))
        (if (>= slen width)
            s
            (string-append (make-string (- width slen) #\space) s))))

    ;; num printed with exactly `decimals` digits after the point, rounded.
    (define (%format-float num decimals)
      (let* ((neg (negative? num))
             (abs-num (abs num))
             (int-part (exact (truncate abs-num)))
             (frac (- abs-num int-part))
             (multiplier (expt 10 decimals))
             (frac-digits (exact (round (* frac multiplier))))
             (carry (if (>= frac-digits multiplier) 1 0))
             (frac-digits2 (if (>= frac-digits multiplier) 0 frac-digits))
             (int-str (number->string (+ int-part carry)))
             (frac-str (number->string frac-digits2))
             (frac-padded (if (< (string-length frac-str) decimals)
                              (string-append
                                (make-string (- decimals (string-length frac-str)) #\0)
                                frac-str)
                              frac-str)))
        (string-append (if neg "-" "") int-str "." frac-padded)))

    ;; ~[w[,d]]F: obj right-aligned in `width` columns, numbers with `decimals`
    ;; fraction digits when given.  Strings and other objects just pad.
    (define (%format-fixed out obj width decimals)
      (cond
        ((string? obj)
         (display (%pad-left obj width) out))
        ((number? obj)
         (if decimals
             (display (%pad-left (%format-float (+ obj 0.0) decimals) width) out)
             (display (%pad-left (number->string obj) width) out)))
        (else
         (let ((p (open-output-string)))
           (display obj p)
           (display (%pad-left (get-output-string p) width) out)))))

    (define %format-help
      (string-append
        "~a display  ~s write  ~w write  ~d decimal  ~x hex  ~o octal"
        "  ~b binary  ~c character  ~y pretty-print  ~? ~k indirection"
        "  ~[w[,d]]F fixed  ~% ~n newline  ~& freshline  ~t tab  ~_ space"
        "  ~~ tilde  ~h help"))

    ;; The loop threads nl? — was the last character emitted a newline — so
    ;; ~& (freshline) can start a line only when not already at one.  After a
    ;; displayed argument the answer is taken as no, as kaappi's does.
    (define (%format-to out fmt args)
      (let loop ((i 0) (args args) (nl? #f))
        (if (>= i (string-length fmt))
            #t
            (let ((c (string-ref fmt i)))
              (if (and (char=? c #\~) (< (+ i 1) (string-length fmt)))
                  (let ((d (char-downcase (string-ref fmt (+ i 1)))))
                    (cond
                      ((char=? d #\a) (display (car args) out) (loop (+ i 2) (cdr args) #f))
                      ((char=? d #\s) (write (car args) out) (loop (+ i 2) (cdr args) #f))
                      ((char=? d #\w) (write (car args) out) (loop (+ i 2) (cdr args) #f))
                      ((char=? d #\y) (write (car args) out) (loop (+ i 2) (cdr args) #f))
                      ((char=? d #\d) (display (number->string (car args) 10) out)
                                      (loop (+ i 2) (cdr args) #f))
                      ((char=? d #\b) (display (number->string (car args) 2) out)
                                      (loop (+ i 2) (cdr args) #f))
                      ((char=? d #\o) (display (number->string (car args) 8) out)
                                      (loop (+ i 2) (cdr args) #f))
                      ((char=? d #\x) (display (number->string (car args) 16) out)
                                      (loop (+ i 2) (cdr args) #f))
                      ((char=? d #\c) (write-char (car args) out) (loop (+ i 2) (cdr args) #f))
                      ((or (char=? d #\?) (char=? d #\k))
                       (%format-to out (car args) (cadr args))
                       (loop (+ i 2) (cddr args) #f))
                      ((char=? d #\%) (newline out) (loop (+ i 2) args #t))
                      ((char=? d #\n) (newline out) (loop (+ i 2) args #t))
                      ((char=? d #\&) (unless nl? (newline out)) (loop (+ i 2) args #t))
                      ((char=? d #\_) (write-char #\space out) (loop (+ i 2) args #f))
                      ((char=? d #\t) (write-char #\tab out) (loop (+ i 2) args #f))
                      ((char=? d #\~) (write-char #\~ out) (loop (+ i 2) args #f))
                      ((char=? d #\h) (display %format-help out) (loop (+ i 2) args #f))
                      ((char-numeric? d)
                       (let parse ((j (+ i 1)) (width 0) (decs #f))
                         (if (>= j (string-length fmt))
                             (error "format: incomplete ~F directive" fmt)
                             (let ((ch (string-ref fmt j)))
                               (cond
                                 ((char-numeric? ch)
                                  (let ((digit (- (char->integer ch) (char->integer #\0))))
                                    (if decs
                                        (parse (+ j 1) width (+ (* decs 10) digit))
                                        (parse (+ j 1) (+ (* width 10) digit) #f))))
                                 ((char=? ch #\,)
                                  (parse (+ j 1) width 0))
                                 ((char=? (char-downcase ch) #\f)
                                  (%format-fixed out (car args) width decs)
                                  (loop (+ j 1) (cdr args) #f))
                                 (else
                                  (error "format: expected F after width" ch)))))))
                      (else (error "format: unknown directive" d))))
                  (begin (write-char c out) (loop (+ i 1) args (char=? c #\newline))))))))

    ;; (format fmt arg ...) -> string
    ;; (format #f fmt arg ...) -> string
    ;; (format #t fmt arg ...) -> writes to current output, returns unspecified
    ;; (format port fmt arg ...) -> writes to port
    (define (format first . rest)
      (cond
        ((string? first)
         (let ((out (open-output-string)))
           (%format-to out first rest)
           (get-output-string out)))
        ((eq? first #f)
         (let ((out (open-output-string)))
           (%format-to out (car rest) (cdr rest))
           (get-output-string out)))
        ((eq? first #t)
         (%format-to (current-output-port) (car rest) (cdr rest))
         (if #f #f))
        (else
         (%format-to first (car rest) (cdr rest))
         (if #f #f))))))
