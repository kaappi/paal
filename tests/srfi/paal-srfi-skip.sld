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
        ("srfi14.scm"
         "passes (172 assertions) but costs ~4 minutes through the in-process pipeline: full-Unicode charset algebra.  Runtime, not correctness; revisit after the bytecode-encoding perf work")
        ("srfi263.scm"
         "passes but costs ~5.7 minutes through the in-process pipeline: a prototype object system, every message send a table walk.  Runtime, not correctness; revisit with srfi14 after the bytecode-encoding perf work")
        ("srfi252.scm"
         "does not finish inside 7 minutes in-process, so it has no measured verdict to record: property-based tests over generated sequences.  Skipped on runtime alone; measure again after the bytecode-encoding perf work")
        ("srfi59-nested-load-vicinity.scm"
         "asks what (program-vicinity) answers while a nested load runs, which means the script path has to be this file — but the driver runs every file inside one host script, so the vicinity is the driver's.  A harness limitation, not a paal one: srfi59.scm itself passes")
        ("srfi264.scm"
         "same runtime reason as srfi252 — still running at 200 s, having passed its first 450 assertions.  Its sibling srfi264-behavior.scm runs in 2 s and is not skipped")))))
