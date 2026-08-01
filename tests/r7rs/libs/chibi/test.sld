;;; Vendored from kaappi's lib/chibi/test.sld — see ../../README.md.
;;;
;;; The ONE adaptation is the %sections accumulator and the three accessors at
;;; the end: the harness needs per-section counts as data, and upstream only
;;; prints them.  Everything else, in particular test-approx=?'s 1e-6 relative
;;; tolerance, must stay byte-identical — the suite hard-codes constants like
;;; 3.14159265358979 that compare equal only under that tolerance.

(define-library (chibi test)
  (import (scheme base) (scheme write) (scheme complex))
  (export test test-assert test-error test-values test-begin test-end
          test-sections test-totals test-reset!)
  (begin

    (define pass-count 0)
    (define fail-count 0)
    (define total-pass 0)
    (define total-fail 0)
    (define current-section "")

    ;; (section pass fail) per test-end, in encounter order.  Accumulated
    ;; rather than printed because the harness asserts against a manifest.
    ;;
    ;; Recorded only for a test-end that closes a test-begin.  The suite calls
    ;; test-end more often than test-begin — there is a trailing pair at the end
    ;; of the file — and upstream's test-end resets nothing, so an unmatched one
    ;; re-reports the previous section's counts verbatim.  Printing is left
    ;; alone, so the transcript stays identical to upstream's.
    (define %sections '())
    (define %section-open? #f)

    (define (test-sections) (reverse %sections))
    (define (test-totals) (list total-pass total-fail))

    (define (test-reset!)
      (set! pass-count 0) (set! fail-count 0)
      (set! total-pass 0) (set! total-fail 0)
      (set! current-section "") (set! %sections '()) (set! %section-open? #f))

    (define (%close-section!)
      (when %section-open?
        (set! total-pass (+ total-pass pass-count))
        (set! total-fail (+ total-fail fail-count))
        (set! %sections (cons (list current-section pass-count fail-count) %sections))
        (set! %section-open? #f)))

    (define (test-begin name)
      ;; A test-begin that arrives while a section is still open closes it
      ;; first.  The suite has no (test-end) for "6.13 Input and output" -- it
      ;; goes straight on to (test-begin "Read syntax") -- so without this its
      ;; assertions run but their counts are discarded, and the whole section
      ;; is invisible to the baseline.
      (%close-section!)
      (set! current-section name)
      (set! %section-open? #t)
      (set! pass-count 0)
      (set! fail-count 0)
      (display "== ")
      (display name)
      (display " ==")
      (newline))

    (define (test-end . args)
      (%close-section!)
      (display "  ")
      (display pass-count)
      (display " pass, ")
      (display fail-count)
      (display " fail")
      (newline))

    (define (test-pass)
      (set! pass-count (+ pass-count 1)))

    (define (test-fail expected actual)
      (set! fail-count (+ fail-count 1))
      (display "FAIL [")
      (display current-section)
      (display "]: expected ")
      (write expected)
      (display " got ")
      (write actual)
      (newline))

    ;; Inexact real results are compared with a small relative tolerance, the
    ;; way the real (chibi test) does: the R7RS suite hard-codes constants like
    ;; 3.14159265358979 that differ from a full-precision result only in the
    ;; last few digits. Exact values, and any non-real/complex values, use
    ;; equal?. NaN/inf match through the equal? fast path.
    (define (test-approx=? a b)
      (or (equal? a b)
          (and (real? a) (real? b)
               (let ((diff (abs (- a b))))
                 (<= diff (* 1e-6 (max 1.0 (abs a) (abs b))))))
          (and (complex? a) (complex? b)
               (not (real? a)) (not (real? b))
               (test-approx=? (real-part a) (real-part b))
               (test-approx=? (imag-part a) (imag-part b)))))

    (define (test-equal? expected actual)
      (cond
        ((and (number? expected) (number? actual)
              (inexact? expected) (inexact? actual))
         (test-approx=? expected actual))
        ((and (complex? expected) (complex? actual)
              (not (real? expected)) (not (real? actual)))
         (test-approx=? expected actual))
        (else (equal? expected actual))))

    (define-syntax test
      (syntax-rules ()
        ((test expected expr)
         (guard (e (#t (test-fail expected (list 'error: e))))
           (let ((res expr))
             (if (test-equal? expected res)
                 (test-pass)
                 (test-fail expected res)))))
        ((test name expected expr)
         (test expected expr))))

    (define-syntax test-assert
      (syntax-rules ()
        ((test-assert expr)
         (test #t (if expr #t #f)))
        ((test-assert name expr)
         (test-assert expr))))

    (define-syntax test-error
      (syntax-rules ()
        ((test-error expr)
         (test #t (guard (e (#t #t)) expr #f)))
        ((test-error name expr)
         (test-error expr))))

    (define-syntax test-values
      (syntax-rules ()
        ((test-values expected expr)
         (test (call-with-values (lambda () expected) list)
               (call-with-values (lambda () expr) list)))))

    ))
