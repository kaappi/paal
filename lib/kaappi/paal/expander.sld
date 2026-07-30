;;; (kaappi paal expander) — Macro expander
;;;
;;; Stage 2 of the Paal compilation pipeline.
;;; Expands macros and desugars derived forms to core forms.
;;;
;;; Core forms: quote if begin lambda set! define define-syntax
;;;
;;; Currently a pass-through; full hygienic macro expansion will be
;;; implemented here.

(define-library (kaappi paal expander)
  (import (scheme base))
  (export paal-expand paal-expand-all)
  (begin

    (define core-forms
      '(quote if begin lambda set! define
        let-syntax letrec-syntax define-syntax syntax-rules))

    (define (paal-expand form)
      form)

    (define (paal-expand-all forms)
      (map paal-expand forms))))
