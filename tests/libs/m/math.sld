;; Fixture for the module-system tests: helper is deliberately not exported.
(define-library (m math)
  (export square cube)
  (begin
    (define (helper x) (* x x))
    (define (square x) (helper x))
    (define (cube x) (* x (helper x)))))
