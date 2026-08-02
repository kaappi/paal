;;; Hand-curated skips: vendored files the driver must not run, each with
;;; the reason on record.  A file listed here is asserted to EXIST by
;;; tests/test-srfi.scm, so a stale entry is noticed when the file goes.
(define-library (paal-srfi-skip)
  (export skip-files)
  (begin
    ;; (file reason)
    (define skip-files
      '(("srfi1-gc-stress.scm"
         "host GC stress harness: minutes-long by design, exercises the host collector rather than the shelf")
        ("srfi158-audit.scm"
         "needs (srfi 160 u8), which arrives with the Phase 2 host-native bindings — unskip then")
        ("srfi14.scm"
         "passes (172 assertions) but costs ~4 minutes through the in-process pipeline: full-Unicode charset algebra.  Runtime, not correctness; revisit after the bytecode-encoding perf work")))))
