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
    pkaappi-compile pkaappi-run-bc-string pkaappi-run-bc-file
    ;; Multi-file sequential loading
    pkaappi-make-globals pkaappi-load-file pkaappi-run-string-in)
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

    (define (pkaappi-compile-forms forms)
      (paal-emit-program (paal-analyze-all (paal-expand-all forms))))

    (define (pkaappi-compile src)
      (pkaappi-compile-forms (paal-read-string src)))

    (define (pkaappi-run-bc-string src)
      (let* ((fn      (pkaappi-compile src))
             (globals (paal-make-globals
                        (map (lambda (pair)
                               (cons (car pair) (vector-ref (cdr pair) 0)))
                             (paal-initial-env)))))
        (paal-run-bc fn globals)))

    (define (pkaappi-run-bc-file path)
      (let* ((fn      (pkaappi-compile-forms (paal-read-file path)))
             (globals (paal-make-globals
                        (map (lambda (pair)
                               (cons (car pair) (vector-ref (cdr pair) 0)))
                             (paal-initial-env)))))
        (paal-run-bc fn globals)))

    ;; --- Multi-file sequential loading ---

    ;; Create a fresh globals table seeded with kaappi primitives.
    ;; The returned object can be passed to pkaappi-load-file repeatedly;
    ;; each call accumulates the loaded file's definitions in place.
    (define (pkaappi-make-globals)
      (let ((g (paal-make-globals
                  (map (lambda (pair) (cons (car pair) (vector-ref (cdr pair) 0)))
                       (paal-initial-env)))))
        ; Install paal-native map/for-each/filter, replacing the HOST stubs.
        ; HOST map cannot call paal closures; these paal-compiled versions can.
        ; map handles 1 or 2 list args (covers all usage in paal's own source).
        (paal-run-bc
          (pkaappi-compile
            "(define (map f lst . rest)
               (if (null? lst)
                   '()
                   (if (null? rest)
                       (cons (f (car lst)) (map f (cdr lst)))
                       (cons (f (car lst) (car (car rest)))
                             (map f (cdr lst) (cdr (car rest)))))))
             (define (for-each f lst . rest)
               (if (null? lst)
                   (if #f #f)
                   (begin
                     (if (null? rest)
                         (f (car lst))
                         (f (car lst) (car (car rest))))
                     (if (null? rest)
                         (for-each f (cdr lst))
                         (for-each f (cdr lst) (cdr (car rest)))))))
             (define (filter pred lst)
               (if (null? lst)
                   '()
                   (if (pred (car lst))
                       (cons (car lst) (filter pred (cdr lst)))
                       (filter pred (cdr lst)))))")
          g)
        g))

    ;; Compile a .sld or .scm file and run it into an existing globals table.
    ;; New names defined by the file are added to globals via define-global ops.
    ;; Returns globals for easy chaining: (pkaappi-load-file b (pkaappi-load-file a g))
    (define (pkaappi-load-file path globals)
      (paal-run-bc (pkaappi-compile-forms (paal-read-file path)) globals)
      globals)

    ;; Compile and evaluate a source string in an existing globals table.
    ;; get-global ops resolve against all previously loaded definitions.
    (define (pkaappi-run-string-in globals src)
      (paal-run-bc (pkaappi-compile src) globals))))
