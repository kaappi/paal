;;; The SRFI conformance driver: one vendored kaappi test file in, one
;;; verdict out.  See tests/srfi/README.md.
;;;
;;; File-level verdicts, not per-assertion counts: the ~220 upstream files
;;; are heterogeneous — most are SRFI 64 suites or exit-code assertion
;;; scripts, a few are display-only — and the one contract they share is
;;; "completes quietly, or raises / exits nonzero on failure".  That is the
;;; same granularity kaappi's own CI holds them to, one process per file.
;;;
;;; Runs the HOST bytecode pipeline in process for the reason the R7RS
;;; driver does: shelling out to `paal file.scm` is ~500× slower.  `exit`
;;; and `emergency-exit` are rebound in the file's globals table to raise a
;;; sentinel the guard recognizes, so an assertion script's (exit 1) fails
;;; its file instead of killing the driver.

(define-library (paal-srfi-driver)
  (import (scheme base)
          (scheme write)
          (kaappi paal))
  (export run-srfi-file)
  (begin

    (define (value->line v)
      (let ((p (open-output-string)))
        (write v p)
        (let* ((s (get-output-string p))
               (n (string-length s)))
          (if (> n 120) (string-append (substring s 0 120) "…") s))))

    (define (condition->line e)
      (if (error-object? e)
          (let ((p (open-output-string)))
            (display (error-object-message e) p)
            (for-each (lambda (x) (display " " p) (write x p))
                      (error-object-irritants e))
            (let* ((s (get-output-string p))
                   (n (string-length s)))
              (if (> n 120) (string-append (substring s 0 120) "…") s)))
          (value->line e)))

    ;; 'pass, or (fail <one-line reason>).
    (define (run-srfi-file path)
      (guard (e ((and (pair? e) (eq? (car e) '%paal-srfi-exit))
                 (let ((code (if (null? (cdr e)) 0 (cadr e))))
                   (if (or (eqv? code 0) (eq? code #t))
                       'pass
                       (list 'fail (string-append "exit " (value->line code))))))
                (#t (list 'fail (condition->line e))))
        (let ((g (pkaappi-make-globals (list path))))
          (paal-run-bc
            (pkaappi-compile
              "(set! exit (lambda args (raise (cons (quote %paal-srfi-exit) args))))
               (set! emergency-exit exit)")
            g)
          (paal-run-bc (pkaappi-compile-file path) g)
          'pass)))))
