;;; SRFI 9 — Defining Record Types
;;;
;;; define-record-type is a core form in paal's expander (it desugars to
;;; tagged vectors), so this library exists only to give the SRFI its import
;;; path.  Importing it is a no-op that succeeds.
(define-library (srfi 9)
  (export)
  (begin))
