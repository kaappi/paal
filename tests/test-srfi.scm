;;; Assert every vendored SRFI test file's verdict against the recorded
;;; baseline.  A ratchet, not a gate: mismatches in EITHER direction fail,
;;; so a fix must regenerate the baseline in the same commit and a
;;; regression cannot hide behind an improvement elsewhere.
;;;
;;; Run via `make test-srfi`; refresh via `make srfi-baseline`.

(import (scheme base)
        (scheme write)
        (scheme process-context)
        (srfi 1)
        (srfi 170)
        (paal-srfi-driver)
        (paal-srfi-expected)
        (paal-srfi-skip))

(define (scm-file? name)
  (let ((n (string-length name)))
    (and (> n 4) (string=? (substring name (- n 4) n) ".scm"))))

(define vendored
  (filter scm-file? (directory-files "tests/srfi/vendor")))

(define (log-file? name)
  (let ((n (string-length name)))
    (and (> n 4) (string=? (substring name (- n 4) n) ".log"))))

;; The vendored SRFI 64 runner writes <group>.log beside the process.
;; Snapshot first so only logs the run created are deleted.
(define logs-before (filter log-file? (directory-files ".")))

(define failures '())
(define (note! . parts)
  (set! failures (cons (apply string-append parts) failures)))

;; Coverage in both directions: every vendored file is either expected or
;; skipped; every expected/skip entry names a file that exists.
(for-each
  (lambda (f)
    (unless (or (assoc f expected-verdicts) (assoc f skip-files))
      (note! f ": vendored but neither expected nor skipped")))
  vendored)
(for-each
  (lambda (e)
    (unless (member (car e) vendored)
      (note! (car e) ": in the baseline but not vendored")))
  expected-verdicts)
(for-each
  (lambda (s)
    (unless (member (car s) vendored)
      (note! (car s) ": in the skip list but not vendored")))
  skip-files)

;; The verdicts themselves.
(define agreed 0)
(for-each
  (lambda (e)
    (let* ((file    (car e))
           (want    (cadr e))
           (got-v   (run-srfi-file (string-append "tests/srfi/vendor/" file)))
           (got     (if (eq? got-v 'pass) 'pass 'fail)))
      (if (eq? got want)
          (set! agreed (+ agreed 1))
          (note! file ": expected " (symbol->string want)
                 ", got " (symbol->string got)
                 (if (eq? got 'fail)
                     (string-append " — " (cadr got-v))
                     "")))))
  expected-verdicts)

;; Clean up runner logs the runs created.
(for-each
  (lambda (f)
    (when (and (log-file? f) (not (member f logs-before)))
      (delete-file f)))
  (directory-files "."))

(display "SRFI shelf: ")
(display agreed)
(display "/")
(display (length expected-verdicts))
(display " files agree with the baseline; ")
(display (length skip-files))
(display " skipped")
(newline)

(unless (null? failures)
  (for-each (lambda (m)
              (display "srfi-ratchet: " (current-error-port))
              (display m (current-error-port))
              (newline (current-error-port)))
            (reverse failures))
  (exit 1))
