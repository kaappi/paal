;; Fixture: (c a) and (c b) import each other, to exercise cycle detection.
(define-library (c a)
  (import (scheme base) (c b))
  (export a-thing)
  (begin (define (a-thing) (b-thing))))
