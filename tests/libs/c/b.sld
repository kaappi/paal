(define-library (c b)
  (import (scheme base) (c a))
  (export b-thing)
  (begin (define (b-thing) 42)))
