;;; SRFI 64 — A Scheme API for test suites
;;;
;;; The commonly-used subset: the test forms, grouping, skip/expect-fail, and
;;; the result counters.  Enough to run a real suite and to eventually replace
;;; paal's dependency on `(kaappi test)`.
;;;
;;; The assertions are `syntax`, not procedures, because a test that raises
;;; must fail *that test* and let the run continue.  A procedural
;;; `(test-equal expected actual)` evaluates `actual` at the call site, so a
;;; raise escapes before the framework sees it and takes the rest of the group
;;; with it.  Thunking inside the macro is what makes a raise a failure rather
;;; than an abort — the same lesson `(kaappi test)` learned.
;;;
;;; Not implemented: test-apply, test-with-runner, custom runners, and the
;;; test-result-alist introspection beyond kind/name.

(define-library (srfi 64)
  (import (scheme base) (scheme write))
  (export
    test-begin test-end test-group test-group-with-cleanup
    test-assert test-eqv test-equal test-eq test-approximate
    test-error test-skip test-expect-fail
    test-runner-current test-runner-simple test-runner-null
    test-runner-pass-count test-runner-fail-count
    test-runner-xpass-count test-runner-xfail-count
    test-runner-skip-count test-runner-test-name
    test-exit
    ;; Exported because the assertion macros name them in their templates.
    ;; A library's private *values* are renamed to mangled names, and a
    ;; template still names the original — the same limitation that leaks
    ;; private macros, seen from the other side.  Exporting is the honest fix
    ;; until templates can be rewritten; the % prefix keeps them out of the
    ;; way, which paal reserves for exactly this.
    %assert %compare %run-test)
  (begin

    ;; --- runner state -------------------------------------------------
    ;;
    ;; One implicit runner.  SRFI 64 allows several, but a second one has no
    ;; use here and would need a parameter object per counter.

    (define %pass 0)
    (define %fail 0)
    (define %xpass 0)
    (define %xfail 0)
    (define %skip 0)
    (define %group-stack '())
    (define %current-name "")
    ;; Predicates queued by test-skip / test-expect-fail, consumed by the next
    ;; test whose name they match.  SRFI 64 specifiers may be a name string, a
    ;; count, or a predicate; string and predicate are supported.
    (define %skip-specs '())
    (define %fail-specs '())

    (define (test-runner-current) 'srfi-64-implicit-runner)
    (define (test-runner-simple)  'srfi-64-implicit-runner)
    (define (test-runner-null)    'srfi-64-implicit-runner)
    (define (test-runner-pass-count . r)  %pass)
    (define (test-runner-fail-count . r)  %fail)
    (define (test-runner-xpass-count . r) %xpass)
    (define (test-runner-xfail-count . r) %xfail)
    (define (test-runner-skip-count . r)  %skip)
    (define (test-runner-test-name . r)   %current-name)

    (define (%indent)
      (let loop ((n (length %group-stack)))
        (when (> n 0) (display "  ") (loop (- n 1)))))

    (define (test-begin name)
      (%indent)
      (display name) (newline)
      (set! %group-stack (cons name %group-stack)))

    (define (test-end . name)
      (unless (null? %group-stack)
        (set! %group-stack (cdr %group-stack))))

    ;; --- specifier matching -------------------------------------------

    (define (%matches? spec name)
      (cond ((string? spec) (and (string? name) (string=? spec name)))
            ((procedure? spec) (spec name))
            (else #f)))

    (define (%consume! specs name)
      ;; #t if any queued specifier matches; matching ones are removed, so a
      ;; specifier applies to one test, per SRFI 64.
      (let loop ((ss specs) (kept '()) (hit #f))
        (cond
          ((null? ss) (cons (reverse kept) hit))
          ((%matches? (car ss) name) (loop (cdr ss) kept #t))
          (else (loop (cdr ss) (cons (car ss) kept) hit)))))

    (define (test-skip spec)        (set! %skip-specs (cons spec %skip-specs)))
    (define (test-expect-fail spec) (set! %fail-specs (cons spec %fail-specs)))

    ;; --- the one place a result is recorded ---------------------------
    ;;
    ;; thunk returns #t for a pass.  It is called inside a guard, so a raise
    ;; is a failure of this test rather than the end of the run.

    (define (%run-test name thunk describe)
      (set! %current-name name)
      (let* ((sk (%consume! %skip-specs name))
             (xf (%consume! %fail-specs name)))
        (set! %skip-specs (car sk))
        (set! %fail-specs (car xf))
        (cond
          ((cdr sk)
           (set! %skip (+ %skip 1))
           (%indent) (display "    skip: ") (display name) (newline))
          (else
           (let ((ok (guard (e (#t (cons #f e))) (cons (thunk) #f))))
             (let ((passed (car ok)) (raised (cdr ok)))
               (cond
                 ((and passed (cdr xf))
                  (set! %xpass (+ %xpass 1))
                  (%indent) (display "    XPASS: ") (display name) (newline))
                 ((cdr xf)
                  (set! %xfail (+ %xfail 1))
                  (%indent) (display "    xfail: ") (display name) (newline))
                 (passed
                  (set! %pass (+ %pass 1))
                  (%indent) (display "    ok: ") (display name) (newline))
                 (else
                  (set! %fail (+ %fail 1))
                  (%indent) (display "    FAIL: ") (display name) (newline)
                  (when raised
                    (%indent) (display "      raised: ")
                    (display (if (error-object? raised)
                                 (error-object-message raised)
                                 raised))
                    (newline))
                  (when describe (describe))))))))))

    (define (%report-mismatch expected actual)
      (lambda ()
        (%indent) (display "      expected: ") (write expected) (newline)
        (%indent) (display "      actual:   ") (write actual) (newline)))

    ;; --- assertions ----------------------------------------------------
    ;;
    ;; Each thunks its expression, so a raise inside becomes a failed test
    ;; rather than an abort.  Every one accepts the optional leading name that
    ;; SRFI 64 allows.

    (define (%assert name thunk)
      (%run-test name (lambda () (and (thunk) #t)) #f))

    (define (%compare name same? expected-thunk actual-thunk)
      (let ((expected #f) (actual #f))
        (%run-test name
                   (lambda ()
                     (set! expected (expected-thunk))
                     (set! actual (actual-thunk))
                     (same? expected actual))
                   (lambda () ((%report-mismatch expected actual))))))

    (define-syntax test-assert
      (syntax-rules ()
        ((_ name expr) (%assert name (lambda () expr)))
        ((_ expr)      (%assert "test-assert" (lambda () expr)))))

    (define-syntax test-equal
      (syntax-rules ()
        ((_ name expected actual)
         (%compare name equal? (lambda () expected) (lambda () actual)))
        ((_ expected actual)
         (%compare "test-equal" equal? (lambda () expected) (lambda () actual)))))

    (define-syntax test-eqv
      (syntax-rules ()
        ((_ name expected actual)
         (%compare name eqv? (lambda () expected) (lambda () actual)))
        ((_ expected actual)
         (%compare "test-eqv" eqv? (lambda () expected) (lambda () actual)))))

    (define-syntax test-eq
      (syntax-rules ()
        ((_ name expected actual)
         (%compare name eq? (lambda () expected) (lambda () actual)))
        ((_ expected actual)
         (%compare "test-eq" eq? (lambda () expected) (lambda () actual)))))

    (define-syntax test-approximate
      (syntax-rules ()
        ((_ name expected actual err)
         (%compare name
                   (lambda (e a) (<= (- e err) a (+ e err)))
                   (lambda () expected) (lambda () actual)))
        ((_ expected actual err)
         (%compare "test-approximate"
                   (lambda (e a) (<= (- e err) a (+ e err)))
                   (lambda () expected) (lambda () actual)))))

    ;; Passes when the expression raises.  The error-type argument is accepted
    ;; and ignored: paal has no condition hierarchy to match against.
    (define-syntax test-error
      (syntax-rules ()
        ((_ name etype expr)
         (%run-test name (lambda () (guard (e (#t #t)) expr #f)) #f))
        ((_ name expr)
         (%run-test name (lambda () (guard (e (#t #t)) expr #f)) #f))
        ((_ expr)
         (%run-test "test-error" (lambda () (guard (e (#t #t)) expr #f)) #f))))

    (define-syntax test-group
      (syntax-rules ()
        ((_ name body ...)
         (begin (test-begin name) body ... (test-end name)))))

    ;; The cleanup form runs whether or not the body raised, which is the
    ;; whole point of this variant.
    (define-syntax test-group-with-cleanup
      (syntax-rules ()
        ((_ name body ... cleanup)
         (begin
           (test-begin name)
           (guard (e (#t cleanup (test-end name) (raise e)))
             body ...)
           cleanup
           (test-end name)))))

    ;; Not in SRFI 64, but every suite needs it and paal's runner has one.
    ;; Exits 1 if anything failed or unexpectedly passed.
    (define (test-exit)
      (newline)
      (display (+ %pass %fail %xpass %xfail %skip))
      (display " tests: ")
      (display %pass) (display " passed")
      (when (> %fail 0)  (display ", ") (display %fail)  (display " failed"))
      (when (> %xfail 0) (display ", ") (display %xfail) (display " expected failures"))
      (when (> %xpass 0) (display ", ") (display %xpass) (display " unexpected passes"))
      (when (> %skip 0)  (display ", ") (display %skip)  (display " skipped"))
      (newline)
      (if (or (> %fail 0) (> %xpass 0)) 1 0))))
