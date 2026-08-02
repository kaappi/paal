;; Fixture: excepts a base name, re-imports it renamed, and defines its own
;; under the public name — the (srfi 70) shape.  The alias %base-abs must
;; keep pointing at base's abs even though the body shadows the public name.
(define-library (shadow arith)
  (import (except (scheme base) abs)
          (rename (only (scheme base) abs) (abs %base-abs)))
  (export abs abs-via-base)
  (begin
    ;; Tagged so the test can tell whose abs it reached.
    (define (abs x) (list 'shadowed (%base-abs x)))
    (define (abs-via-base x) (%base-abs x))))
