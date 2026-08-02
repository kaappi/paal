;; Fixture: an unexported self-recursive macro.  Its template names itself,
;; and the clause head must not count as a pattern variable when the
;; library rename rewrites templates — or the self-call keeps the dropped
;; unmangled spelling and the second expansion step dies.  SRFI 148's aux
;; transformers are the real-world shape.
(define-library (shadow selfrec)
  (import (scheme base))
  (export count-args)
  (begin
    (define-syntax count-aux
      (syntax-rules ()
        ((_ acc) acc)
        ((_ acc x rest ...) (count-aux (+ acc 1) rest ...))))
    (define-syntax count-args
      (syntax-rules ()
        ((_ args ...) (count-aux 0 args ...))))))
