;;; SRFI 28 — Basic Format Strings
;;;
;;; ~a display, ~s write, ~% newline, ~~ tilde.  SRFI 48 builds on this and is
;;; a separate file so importing 28 alone gets only what 28 specifies.
(define-library (srfi 28)
  (import (scheme base) (scheme write))
  (export format)
  (begin
    (define (format fmt . args)
      (let ((out (open-output-string)))
        (let loop ((i 0) (args args))
          (if (>= i (string-length fmt))
              (get-output-string out)
              (let ((c (string-ref fmt i)))
                (if (and (char=? c #\~) (< (+ i 1) (string-length fmt)))
                    (let ((d (string-ref fmt (+ i 1))))
                      (cond
                        ((or (char=? d #\a) (char=? d #\A))
                         (display (car args) out) (loop (+ i 2) (cdr args)))
                        ((or (char=? d #\s) (char=? d #\S))
                         (write (car args) out) (loop (+ i 2) (cdr args)))
                        ((char=? d #\%) (newline out) (loop (+ i 2) args))
                        ((char=? d #\~) (write-char #\~ out) (loop (+ i 2) args))
                        (else (error "format: unknown directive" d))))
                    (begin (write-char c out) (loop (+ i 1) args)))))))))) 
