;; Fixture: an exported macro, and an exported macro that uses a private one.
(define-library (m mac)
  (import (scheme base))
  (export swap! twice)
  (begin
    (define-syntax swap!
      (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
    (define-syntax private-mac
      (syntax-rules () ((_ x) (* x 100))))
    (define-syntax twice
      (syntax-rules () ((_ x) (private-mac x))))))
