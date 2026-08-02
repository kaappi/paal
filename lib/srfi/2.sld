;; [paal adaptation] the empty-claws clause is split: upstream's
;; (begin #t body ...) relies on kaappi hoisting a body-opening define out
;; of an expression-position begin, which paal (with R7RS) rejects.
;; (let () body ...) is the SRFI's own stated semantics — the body is a
;; let* body — and the separate no-body clause keeps the empty case #t.
;; Upstream's #2073 (claws-with-no-body must return the last claw's value)
;; is untouched: it is recorded as a defect there and pinned by its suite.
(define-library (srfi 2)
  (import (scheme base))
  (export and-let*)
  (begin
    (define-syntax and-let*
      (syntax-rules ()
        ((and-let* ())
         #t)
        ((and-let* () body ...)
         (let () body ...))
        ((and-let* ((var expr) rest ...) body ...)
         (let ((var expr))
           (if var (and-let* (rest ...) body ...) #f)))
        ((and-let* ((expr) rest ...) body ...)
         (if expr (and-let* (rest ...) body ...) #f))
        ((and-let* (bound-var rest ...) body ...)
         (if bound-var (and-let* (rest ...) body ...) #f))))))
