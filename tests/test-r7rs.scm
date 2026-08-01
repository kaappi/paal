;;; R7RS conformance — kaappi's suite, run through paal, asserted against a
;;; recorded per-section baseline.
;;;
;;; This is a ratchet, not a pass/fail gate: paal does not pass the whole suite
;;; and will not for a while.  What it gates is *change* — a section that gains
;;; a failure fails this file, and a section that gains a pass fails it too,
;;; forcing the baseline to be refreshed deliberately.  The diff of that refresh
;;; is the evidence a fix did what it claimed.
;;;
;;; Equality per section, not `<=`: sections are large, and an inequality gate
;;; lets a new failure hide behind a new pass in the same section.
;;;
;;; To refresh:  make r7rs-baseline > tests/r7rs/paal-r7rs-expected.sld
;;; then read the diff.

(import (scheme base) (scheme write) (kaappi test)
        (paal-r7rs-driver) (paal-r7rs-expected))

;; The suite prints its own transcript — section headers and a FAIL line per
;; failing assertion.  Captured rather than let loose on stdout, because 131
;; expected FAIL lines every run would bury a real one from tests/test-paal.scm.
;; It is replayed below if, and only if, the counts moved.
(define %transcript (open-output-string))

(define result
  (parameterize ((current-output-port %transcript))
    (run-r7rs-suite! "tests/r7rs/r7rs-tests.scm" "tests/r7rs/libs" '())))

(define sections (r7rs-sections result))

(test-group "r7rs conformance"
  (test-equal "every expected section ran, and no others"
    (map car expected-sections)
    (map car sections))

  ;; One assertion per section, named for it, so a regression says
  ;; "6.10 Control Features" rather than diffing a 19-element list.
  (for-each
    (lambda (expected)
      (let ((got (assoc (car expected) sections)))
        (test-equal (car expected)
                    (cdr expected)
                    (if got (cdr got) 'section-missing))))
    expected-sections)

  ;; A top-level form that raises takes every assertion inside it with it, so
  ;; these are tracked separately from the counts — the indices are stable
  ;; because the suite is vendored and pinned.
  (test-equal "top-level forms that raise"
    expected-errors
    (r7rs-errors result)))

;; Detail on demand: only when something moved, so the common case stays quiet.
;; Before test-exit, which exits 1 on any failure and would cut this off.
(unless (equal? (map cdr expected-sections) (map cdr sections))
  (newline)
  (display "--- r7rs suite transcript (counts moved; refresh the baseline) ---")
  (newline)
  (display (get-output-string %transcript))
  (newline))

(test-exit)
