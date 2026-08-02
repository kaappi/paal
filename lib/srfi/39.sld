;;; SRFI 39 — Parameter objects
;;;
;;; Both names are provided by the base environment: make-parameter by the
;;; paal-native cell-based implementation in globals, parameterize by the
;;; expander (syntax is not gated by imports).  This library re-exports the
;;; value so `(import (srfi 39))` grants it, and records the one SRFI 39
;;; behaviour beyond R7RS: `(p v)` sets the parameter's value through its
;;; converter, which both of paal's make-parameter implementations honour.
(define-library (srfi 39)
  (import (scheme base))
  (export make-parameter)
  (begin))
