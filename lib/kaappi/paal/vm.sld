;;; (kaappi paal vm) — Bootstrap VM: tree-walking interpreter over IR
;;;
;;; Stage 4 of the Paal compilation pipeline.
;;; Evaluates IR nodes against an environment.
;;;
;;; Environment entries are mutable vector boxes (cons name #(val)) so
;;; that top-level defines are visible to recursive closures and set!
;;; works correctly.
;;;
;;; This tree-walking interpreter is the bootstrap VM.  It will be
;;; replaced by a bytecode emitter + register-based VM.

(define-library (kaappi paal vm)
  (import (scheme base) (kaappi paal ir))
  (export paal-eval paal-eval-program paal-initial-env)
  (begin

    ;; --- Mutable boxed environments ---
    ;; Each frame: (name . #(val))  — the vector is mutable in place.

    (define (env-lookup env name)
      (let ((pair (assq name env)))
        (if pair
            (vector-ref (cdr pair) 0)
            (error "paal: unbound variable" name))))

    (define (env-extend env name val)
      (cons (cons name (vector val)) env))

    (define (env-set! env name val)
      (let ((pair (assq name env)))
        (if pair
            (vector-set! (cdr pair) 0 val)
            (error "paal: set! on unbound variable" name))))

    ;; Bind a parameter list against actual arguments.
    (define (env-bind env params args rest?)
      (cond
        ((and rest? (symbol? params))
         (env-extend env params args))
        ((null? params) env)
        (else
         (env-bind (env-extend env (car params) (car args))
                   (cdr params) (cdr args) rest?))))

    ;; --- Initial environment seeded with host primitives ---

    (define (paal-initial-env)
      (map (lambda (pair) (cons (car pair) (vector (cdr pair))))
           `((+  . ,+)  (-  . ,-)  (*  . ,*)  (/  . ,/)
             (=  . ,=)  (<  . ,<)  (>  . ,>)  (<= . ,<=) (>= . ,>=)
             (eq? . ,eq?) (eqv? . ,eqv?) (equal? . ,equal?)
             (not . ,not)
             (cons . ,cons) (car . ,car) (cdr . ,cdr) (list . ,list)
             (null? . ,null?) (pair? . ,pair?) (length . ,length)
             (number? . ,number?) (string? . ,string?) (symbol? . ,symbol?)
             (boolean? . ,boolean?) (procedure? . ,procedure?) (char? . ,char?)
             (display . ,display) (newline . ,newline) (write . ,write)
             (string-append . ,string-append) (string-length . ,string-length)
             (string->number . ,string->number) (number->string . ,number->string)
             (apply . ,apply) (map . ,map) (for-each . ,for-each)
             (error . ,error) (values . ,values))))

    ;; --- Evaluator ---

    (define (paal-eval node env)
      (cond
        ((ir:const?  node) (ir:const-val node))
        ((ir:ref?    node) (env-lookup env (ir:ref-name node)))
        ((ir:if?     node)
         (if (paal-eval (ir:if-test node) env)
             (paal-eval (ir:if-then node) env)
             (paal-eval (ir:if-else node) env)))
        ((ir:begin?  node)
         (let loop ((exprs (ir:begin-exprs node)) (val #f))
           (if (null? exprs)
               val
               (loop (cdr exprs) (paal-eval (car exprs) env)))))
        ((ir:lambda? node)
         (let ((params (ir:lambda-params node))
               (body   (ir:lambda-body  node))
               (rest?  (ir:lambda-rest? node)))
           (lambda args
             (paal-eval body (env-bind env params args rest?)))))
        ((ir:set!? node)
         (env-set! env (ir:set!-name node)
                       (paal-eval (ir:set!-val node) env)))
        ((ir:define? node)
         (error "paal: define used as expression — use paal-eval-program"))
        ((ir:call? node)
         (let ((proc (paal-eval (ir:call-proc node) env))
               (args (map (lambda (a) (paal-eval a env))
                          (ir:call-args node))))
           (apply proc args)))
        (else (error "paal-eval: unknown IR node" node))))

    ;; Evaluate a sequence of top-level IR nodes, threading defines
    ;; into the environment with forward-visible mutable boxes so that
    ;; recursive and mutually-recursive definitions work.
    (define (paal-eval-program nodes)
      (let loop ((ns nodes) (env (paal-initial-env)) (last #f))
        (if (null? ns)
            last
            (let ((node (car ns)))
              (if (ir:define? node)
                  (let* ((name (ir:define-name node))
                         (box  (vector #f))                     ; placeholder
                         (env* (cons (cons name box) env))      ; visible immediately
                         (val  (paal-eval (ir:define-val node) env*)))
                    (vector-set! box 0 val)                     ; fill in
                    (loop (cdr ns) env* val))
                  (loop (cdr ns) env (paal-eval node env)))))))))
