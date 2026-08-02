;; Fixture: shadows the very names the expander's own desugarings call —
;; list, car, length, vector-ref — and then uses quasiquote, case-lambda
;; and define-record-type in its body.  The machinery's emissions must
;; reach base through their %paal-base- spellings, not this library's
;; shadows.  SRFI 101 is the real-world case.
(define-library (shadow machinery)
  (import (except (scheme base) list car length vector-ref))
  (export list car length vector-ref
          qq-pair arity record-roundtrip)
  (begin
    (define (list . args) 'stolen-list)
    (define (car p) 'stolen-car)
    (define (length l) 'stolen-length)
    (define (vector-ref v i) 'stolen-vector-ref)
    ;; quasiquote → machinery cons/list/append
    (define (qq-pair a b) `(,a . (,b tail)))
    ;; case-lambda → machinery car/length/=
    (define arity
      (case-lambda
        ((x) 'one)
        ((x y) 'two)))
    ;; record type → machinery make-vector/vector-set!/vector-ref/list.
    ;; The field is named `v` deliberately: it captured the desugar's own
    ;; vector variable before that variable became a fresh name.
    (define-record-type <box2>
      (make-box2 v)
      box2?
      (v box2-v))
    (define (record-roundtrip x)
      (let ((b (make-box2 x)))
        (and (box2? b) (box2-v b))))))
