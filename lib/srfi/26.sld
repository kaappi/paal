;;; SRFI 26 — Notation for specializing parameters (cut, cute)
;;;
;;; Adapted for paal.  The reference implementation threads a
;;; template-introduced slot variable through a recursive helper macro —
;;; introduced by one expansion step, bound only by a later one — which
;;; needs the per-identifier provenance paal's expander does not track
;;; (the same boundary docs/TODO.md records for R7RS §4.3's deferred
;;; torture cases).  Here the macros only classify each argument as a
;;; slot marker or a thunk, and a runtime builder closes over the parts;
;;; every identifier a template introduces is bound within that same
;;; template.
;;;
;;; Semantics per SRFI 26: cut evaluates its operator and non-slot
;;; expressions at application time (the thunks run per invocation),
;;; cute at construction time (the thunks run once); <...> as the final
;;; argument makes the procedure variadic in the rest.
(define-library (srfi 26)
  (import (scheme base))
  (export cut cute)
  (begin
    ;; parts: each element is the symbol %cut-slot or a thunk; the first
    ;; is the operator position.  Expressions can never collide with the
    ;; marker — they arrive wrapped in lambdas.
    (define (%cut-call parts rest? args)
      (let loop ((ps parts) (as args) (acc '()))
        (cond
          ((null? ps)
           (let ((call (reverse acc)))
             (cond
               (rest?      (apply (car call) (append (cdr call) as)))
               ((null? as) (apply (car call) (cdr call)))
               (else (error "cut: too many arguments" as)))))
          ((eq? (car ps) '%cut-slot)
           (if (null? as)
               (error "cut: too few arguments")
               (loop (cdr ps) (cdr as) (cons (car as) acc))))
          (else (loop (cdr ps) as (cons ((car ps)) acc))))))

    (define (%cut-make parts rest?)
      (lambda args (%cut-call parts rest? args)))

    ;; cute forces each expression thunk exactly once, now, and rewraps
    ;; the value so %cut-call treats both kinds alike.
    (define (%cute-make parts rest?)
      (%cut-make (map (lambda (p)
                        (if (eq? p '%cut-slot)
                            p
                            (let ((v (p))) (lambda () v))))
                      parts)
                 rest?))

    ;; Classify the arguments left to right, accumulating quoted markers
    ;; and thunks, then hand the list to the builder `k`.
    (define-syntax %cut-parts
      (syntax-rules (<> <...>)
        ((_ k (acc ...))         (k (list acc ...) #f))
        ((_ k (acc ...) <...>)   (k (list acc ...) #t))
        ((_ k (acc ...) <> . se) (%cut-parts k (acc ... (quote %cut-slot)) . se))
        ((_ k (acc ...) e . se)  (%cut-parts k (acc ... (lambda () e)) . se))))

    (define-syntax cut
      (syntax-rules ()
        ((_ . se) (%cut-parts %cut-make () . se))))

    (define-syntax cute
      (syntax-rules ()
        ((_ . se) (%cut-parts %cute-make () . se))))))
