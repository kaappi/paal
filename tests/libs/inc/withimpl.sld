;; Fixture: a library whose body `include`s files beside the .sld — the
;; (srfi 135) shape.  The suite runs from the repo root, so the property
;; under test is that these resolve against this file's directory, not the
;; process CWD.
(define-library (inc withimpl)
  (import (scheme base))
  (export impl-answer shouty-answer)
  (include "withimpl-impl.scm")
  (include-ci "withimpl-ci-impl.scm"))
