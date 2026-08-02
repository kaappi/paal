;; Fixture: include-library-declarations resolves beside the .sld too.
(define-library (inc decls)
  (import (scheme base))
  (include-library-declarations "decls-part.scm"))
