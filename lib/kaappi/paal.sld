;;; (kaappi paal) — Paal Kaappi public API
;;;
;;; Provides both the tree-walking VM pipeline and the bytecode pipeline.
;;; Individual stages can also be imported directly via (kaappi paal <stage>).

(define-library (kaappi paal)
  (import (scheme base)
          (kaappi paal reader)
          (kaappi paal expander)
          (kaappi paal compiler)
          (kaappi paal vm)
          (kaappi paal emitter)
          (kaappi paal vm-bc))
  (export
    ;; Reader
    paal-read paal-read-string paal-read-all paal-read-file
    ;; Expander
    paal-expand paal-expand-all
    ;; Compiler (analyzer)
    paal-analyze paal-analyze-all
    ;; Tree-walking VM
    paal-eval paal-eval-program paal-initial-env
    ;; Bytecode pipeline
    paal-emit-program paal-run-bc paal-make-globals
    ;; High-level pipeline (tree-walking)
    pkaappi-run-string pkaappi-run-file
    ;; High-level pipeline (bytecode)
    pkaappi-compile pkaappi-run-bc-string pkaappi-run-bc-file)
  (begin

    ;; --- Tree-walking pipeline ---

    (define (pkaappi-run-string src)
      (paal-eval-program
        (paal-analyze-all
          (paal-expand-all
            (paal-read-string src)))))

    (define (pkaappi-run-file path)
      (paal-eval-program
        (paal-analyze-all
          (paal-expand-all
            (paal-read-file path)))))

    ;; --- Bytecode pipeline ---

    (define (pkaappi-compile src)
      (paal-emit-program
        (paal-analyze-all
          (paal-expand-all
            (paal-read-string src)))))

    (define (pkaappi-run-bc-string src)
      (let* ((fn      (pkaappi-compile src))
             (globals (paal-make-globals
                        (map (lambda (pair)
                               (cons (car pair) (vector-ref (cdr pair) 0)))
                             (paal-initial-env)))))
        (paal-run-bc fn globals)))

    (define (pkaappi-run-bc-file path)
      (let* ((fn      (paal-emit-program
                        (paal-analyze-all
                          (paal-expand-all
                            (paal-read-file path)))))
             (globals (paal-make-globals
                        (map (lambda (pair)
                               (cons (car pair) (vector-ref (cdr pair) 0)))
                             (paal-initial-env)))))
        (paal-run-bc fn globals)))))
