;; Fixture: renames over full (scheme base) — unenumerable, so the rename
;; pairs are taken on faith as the alias list — combined with a body that
;; shadows the renamed name.  The (srfi 101) shape.
(define-library (shadow relist)
  (import (except (scheme base) list)
          (rename (scheme base) (car %base-car) (list %base-list)))
  (export list first-of)
  (begin
    (define (list . args) (cons 'mine (%base-list args)))
    (define (first-of xs) (%base-car xs))))
