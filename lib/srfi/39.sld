;;; SRFI 39 — Parameter objects
;;;
;;; make-parameter and parameterize are already provided: the former by the
;;; paal-native cell-based implementation in globals, the latter by the
;;; expander.  SRFI 39 permits (p v) to set a parameter, which R7RS dropped
;;; and paal does not support -- paal's parameter closure rejects any argument
;;; other than its internal cell key.  Everything else is present.
(define-library (srfi 39)
  (export)
  (begin))
