;; Fixture: `(include "../updir-impl.scm")` — the (srfi 171 meta) shape, a
;; sub-directory library including from its parent directory.
(define-library (inc deeper updir)
  (import (scheme base))
  (export updir-answer)
  (include "../updir-impl.scm"))
