;; Fixture: imports another library, so `area` exercises transitive imports.
(define-library (m greet)
  (import (scheme base) (m math))
  (export greet area)
  (begin
    (define (greet who) (string-append "hi " who))
    (define (area r) (square r))))
