;;; (kaappi paal) — Paal Kaappi public API
;;;
;;; Provides the full compilation pipeline as a single importable library.
;;; Individual stages can also be imported directly via (kaappi paal <stage>).

(define-library (kaappi paal)
  (import (scheme base)
          (kaappi paal reader)
          (kaappi paal expander)
          (kaappi paal compiler)
          (kaappi paal vm))
  (export
    ;; Reader
    paal-read paal-read-string paal-read-all paal-read-file
    ;; Expander
    paal-expand paal-expand-all
    ;; Compiler (analyzer)
    paal-analyze paal-analyze-all
    ;; VM
    paal-eval paal-eval-program paal-initial-env
    ;; High-level pipeline
    pkaappi-run-string pkaappi-run-file)
  (begin

    (define (pkaappi-run-string src)
      (paal-eval-program
        (paal-analyze-all
          (paal-expand-all
            (paal-read-string src)))))

    (define (pkaappi-run-file path)
      (paal-eval-program
        (paal-analyze-all
          (paal-expand-all
            (paal-read-file path)))))))
