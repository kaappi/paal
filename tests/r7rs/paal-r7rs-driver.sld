;;; (paal-r7rs-driver) — run kaappi's R7RS suite through paal, form by form
;;;
;;; Two things make the obvious harness unworkable, and this file is the
;;; response to both.
;;;
;;; paal is a whole-program compiler: pkaappi-compile-forms expands every form
;;; before emitting any of them, so ONE unsupported form anywhere means zero
;;; tests run.  `paal check` on the suite dies outright.  So the suite is driven
;;; one top-level form at a time, each in its own guard — a compile abort or a
;;; top-level raise then costs that form and nothing else.
;;;
;;; And the self-hosted path is ~500x slower than the HOST one (163 s against
;;; 0.30 s on a 59-line excerpt), so shelling out to `paal file.scm` is not
;;; viable for CI.  This runs the HOST bytecode pipeline in process.
;;;
;;; Definitions accumulate in one globals table across forms, exactly as they do
;;; in pkaappi-run-string-in, and paal-macros-reset! is deliberately NOT called
;;; per form — a define-syntax in the suite has to stay installed for the forms
;;; after it.

(define-library (paal-r7rs-driver)
  (import (scheme base) (kaappi paal))
  (export run-r7rs-suite! r7rs-sections r7rs-errors)
  (begin

    ;; Compile and run one form in `g`.  Separated so the guard in the caller
    ;; wraps expansion and execution alike — a form can fail at either.
    (define (run-form! form g)
      (paal-run-bc
        (paal-emit-program (paal-analyze-all (paal-expand-all (list form))))
        g))

    ;; -> (sections errors)
    ;;   sections : ((name pass fail) ...) as (chibi test) recorded them
    ;;   errors   : (index ...) of top-level forms that raised
    ;;
    ;; `skips` is a list of form indices to not run at all.  It exists for a
    ;; form that hangs: R7RS has no per-form timeout, so without it one
    ;; non-terminating form would wedge CI with no recourse.  Empty today.
    (define (run-r7rs-suite! path libdir skips)
      (paal-lib-path-add! libdir)
      (let ((g      (pkaappi-make-globals))
            (errors '()))
        (let loop ((forms (paal-read-file path)) (i 0))
          (if (null? forms)
              ;; (test-sections) is an alias the suite's own (import (chibi
              ;; test)) put in g, so it has to be called through the pipeline
              ;; too — it is not a HOST binding here.  The result is a list of
              ;; strings and numbers, so it crosses the boundary intact.
              (list (run-form! '(test-sections) g) (reverse errors))
              (begin
                (unless (memv i skips)
                  (guard (e (#t (set! errors (cons i errors))))
                    (run-form! (car forms) g)))
                (loop (cdr forms) (+ i 1)))))))

    (define (r7rs-sections result) (car result))
    (define (r7rs-errors result) (cadr result))))
