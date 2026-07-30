;;; (kaappi paal) — Paal Kaappi public API
;;;
;;; Provides both the tree-walking VM pipeline and the bytecode pipeline.
;;; Individual stages can also be imported directly via (kaappi paal <stage>).

(define-library (kaappi paal)
  (import (scheme base)
          (scheme file)
          (kaappi paal reader)
          (kaappi paal expander)
          (kaappi paal compiler)
          (kaappi paal vm)
          (kaappi paal emitter)
          (kaappi paal vm-bc)
          (kaappi paal serializer))
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
    pkaappi-make-globals pkaappi-load-file pkaappi-run-string-in
    ;; Self-hosted run
    pkaappi-self-run-file
    ;; Serializer
    paal-write-bc paal-read-bc paal-write-bc-file paal-read-bc-file
    pkaappi-compile-to-file pkaappi-run-pbc-file)
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
      ; Seed the alist with pkaappi-make-globals itself (HOST procedure) so that
      ; paal code loaded via pkaappi-load-file can call it to create fresh globals.
      (let* ((base-alist (map (lambda (pair) (cons (car pair) (vector-ref (cdr pair) 0)))
                              (paal-initial-env)))
             (g (paal-make-globals (cons (cons 'pkaappi-make-globals pkaappi-make-globals)
                                         base-alist))))
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
      (paal-run-bc (pkaappi-compile src) globals))

    ;; --- Serializer high-level API ---

    (define (pkaappi-compile-to-file input output)
      (let ((fn (pkaappi-compile-forms (paal-read-file input))))
        (paal-write-bc-file fn output)))

    (define (pkaappi-run-pbc-file path)
      (let* ((fn      (paal-read-bc-file path))
             (globals (paal-make-globals
                        (map (lambda (pair)
                               (cons (car pair) (vector-ref (cdr pair) 0)))
                             (paal-initial-env)))))
        (paal-run-bc fn globals)))

    ;; --- Self-hosted run ---

    ; Library file load order for paal's own pipeline.
    (define %paal-lib-files
      '("lib/kaappi/paal/ir.sld"
        "lib/kaappi/paal/bytecode.sld"
        "lib/kaappi/paal/reader.sld"
        "lib/kaappi/paal/expander.sld"
        "lib/kaappi/paal/compiler.sld"
        "lib/kaappi/paal/frame.sld"
        "lib/kaappi/paal/emitter.sld"
        "lib/kaappi/paal/vm-bc.sld"))

    ; Load paal's 8 library files into a fresh globals, then compile and run the
    ; user's file through the loaded pipeline (reader, expander, emitter, VM).
    ; Falls back to HOST pipeline if library source files are not accessible
    ; (e.g. standalone binary mode where .sld files are not on disk).
    (define (pkaappi-self-run-file path)
      (if (file-exists? "lib/kaappi/paal/ir.sld")
          (let ((g (pkaappi-make-globals)))
            (for-each (lambda (p) (pkaappi-load-file p g)) %paal-lib-files)
            (pkaappi-run-string-in g
              (string-append
                "(paal-run-bc"
                "  (paal-emit-program"
                "    (paal-analyze-all"
                "      (paal-expand-all"
                "        (paal-read-file \"" path "\"))))"
                "  (pkaappi-make-globals))")))
          (pkaappi-run-bc-file path)))))
