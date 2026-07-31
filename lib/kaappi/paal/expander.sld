;;; (kaappi paal expander) — Derived-form desugarer
;;;
;;; Stage 2 of the Paal compilation pipeline.
;;; Rewrites derived forms to core forms before analysis.
;;;
;;; Core forms passed through (recursing into sub-forms):
;;;   quote lambda define set! if begin
;;;
;;; Derived forms desugared:
;;;   let let* letrec letrec* named-let
;;;   and or when unless cond case do quasiquote
;;;   case-lambda define-values let-values let*-values
;;;   delay delay-force include include-ci cond-expand
;;;   define-syntax let-syntax letrec-syntax syntax-error
;;;   define-record-type

(define-library (kaappi paal expander)
  (import (scheme base) (scheme file) (scheme read))
  (export paal-expand paal-expand-all)
  (begin

    ;; ---------------------------------------------------------------
    ;; Counter for hygienic temporaries
    ;; ---------------------------------------------------------------

    (define %expander-counter 0)
    (define (fresh-name prefix)
      (set! %expander-counter (+ %expander-counter 1))
      (string->symbol
        (string-append prefix (number->string %expander-counter))))

    ;; ---------------------------------------------------------------
    ;; Macro environment — stores user-defined syntax transformers
    ;; ---------------------------------------------------------------
    ;;
    ;; %paal-macros: alist of (name . transformer)
    ;; A transformer is (lambda (form) expanded-form).
    ;; Mutable global; define-syntax side-effects it.

    (define %paal-macros '())

    (define (paal-macro-set! name transformer)
      (set! %paal-macros (cons (cons name transformer) %paal-macros)))

    (define (paal-macro-get name)
      (let ((entry (assq name %paal-macros)))
        (and entry (cdr entry))))

    ;; ---------------------------------------------------------------
    ;; Feature list for cond-expand
    ;; ---------------------------------------------------------------

    (define %paal-features '(pkaappi r7rs scheme))

    ;; ---------------------------------------------------------------
    ;; syntax-rules implementation
    ;; ---------------------------------------------------------------
    ;;
    ;; Ellipsis values are tagged with %ellipsis-tag so we can
    ;; distinguish them from regular list values in the env.

    (define %ellipsis-tag (list 'ellipsis))

    (define (make-ellipsis vals) (cons %ellipsis-tag vals))
    (define (ellipsis? x)        (and (pair? x) (eq? (car x) %ellipsis-tag)))
    (define (ellipsis-vals x)    (cdr x))

    ;; List utilities used by syntax-rules

    (define (list-take lst n)
      (if (or (= n 0) (null? lst))
          '()
          (cons (car lst) (list-take (cdr lst) (- n 1)))))

    (define (list-drop lst n)
      (if (or (= n 0) (null? lst))
          lst
          (list-drop (cdr lst) (- n 1))))

    (define (iota n)
      (let loop ((i (- n 1)) (acc '()))
        (if (< i 0) acc (loop (- i 1) (cons i acc)))))

    (define (has-false? lst)
      (and (pair? lst)
           (or (eq? (car lst) #f) (has-false? (cdr lst)))))

    ;; Collect all pattern variables from a pattern
    (define (pattern-vars pat lits)
      (cond
        ((eq? pat '_)   '())
        ((eq? pat '...) '())
        ((and (symbol? pat) (memq pat lits)) '())
        ((symbol? pat)  (list pat))
        ((not (pair? pat)) '())
        ((and (pair? (cdr pat)) (eq? (cadr pat) '...))
         (append (pattern-vars (car pat) lits)
                 (pattern-vars (cddr pat) lits)))
        (else
         (append (pattern-vars (car pat) lits)
                 (pattern-vars (cdr pat) lits)))))

    ;; Count how many non-ellipsis elements rest-pat requires
    (define (count-required rest-pat)
      (cond
        ((null? rest-pat) 0)
        ((and (pair? rest-pat)
              (pair? (cdr rest-pat))
              (eq? (cadr rest-pat) '...))
         (count-required (cddr rest-pat)))
        ((pair? rest-pat)
         (+ 1 (count-required (cdr rest-pat))))
        (else 0)))

    ;; Match pattern against form.
    ;; Returns an alist of (var . value) on success, #f on failure.
    ;; Ellipsis-bound vars have value (make-ellipsis list-of-values).
    (define (match-syntax pat frm lits)
      (cond
        ;; Underscore: match anything, no binding
        ((eq? pat '_) '())
        ;; Literal: must be the same symbol
        ((and (symbol? pat) (memq pat lits))
         (if (and (symbol? frm) (eq? pat frm)) '() #f))
        ;; Pattern variable: bind to form
        ((symbol? pat)
         (list (cons pat frm)))
        ;; Null: matches null
        ((null? pat)
         (if (null? frm) '() #f))
        ;; Non-pair datum: must be equal
        ((not (pair? pat))
         (if (equal? pat frm) '() #f))
        ;; Ellipsis: (subpat ...) [rest-pat...]
        ((and (pair? (cdr pat)) (eq? (cadr pat) '...))
         (let* ((subpat    (car pat))
                (rest-pat  (cddr pat))
                (pvars     (pattern-vars subpat lits))
                (n-req     (count-required rest-pat)))
           (if (not (list? frm))
               #f
               (let ((n-total (length frm)))
                 (if (< n-total n-req)
                     #f
                     (let* ((n-ell     (- n-total n-req))
                            (ell-frms  (list-take frm n-ell))
                            (rest-frms (list-drop frm n-ell))
                            (sub-envs  (map (lambda (f) (match-syntax subpat f lits))
                                            ell-frms)))
                       (if (has-false? sub-envs)
                           #f
                           (let* ((merged
                                   (map (lambda (v)
                                          (cons v
                                                (make-ellipsis
                                                  (map (lambda (e)
                                                         (let ((b (assq v e)))
                                                           (if b (cdr b) #f)))
                                                       sub-envs))))
                                        pvars))
                                  (rest-env
                                   (if (null? rest-pat)
                                       '()
                                       (match-syntax rest-pat rest-frms lits))))
                             (if rest-env
                                 (append merged rest-env)
                                 #f)))))))))
        ;; Pair: match recursively
        ((pair? pat)
         (if (pair? frm)
             (let ((e1 (match-syntax (car pat) (car frm) lits)))
               (and e1
                    (let ((e2 (match-syntax (cdr pat) (cdr frm) lits)))
                      (and e2 (append e1 e2)))))
             #f))
        ;; Anything else: must be equal
        (else (and (equal? pat frm) '()))))

    ;; Find variables in template that are bound to ellipsis values in env
    (define (find-ellipsis-vars tmpl env)
      (cond
        ((symbol? tmpl)
         (let ((b (assq tmpl env)))
           (if (and b (ellipsis? (cdr b))) (list tmpl) '())))
        ((pair? tmpl)
         (if (and (pair? (cdr tmpl)) (eq? (cadr tmpl) '...))
             (find-ellipsis-vars (car tmpl) env)
             (append (find-ellipsis-vars (car tmpl) env)
                     (find-ellipsis-vars (cdr tmpl) env))))
        (else '())))

    ;; Instantiate a template with pattern-variable bindings.
    ;; Ellipsis variables have (ellipsis-vals ...) values.
    (define (instantiate-template tmpl env)
      (cond
        ;; Symbol: look up in env
        ((symbol? tmpl)
         (let ((b (assq tmpl env)))
           (if b
               (let ((val (cdr b)))
                 (if (ellipsis? val)
                     (error "syntax-rules: ellipsis variable used outside ellipsis template" tmpl)
                     val))
               tmpl)))
        ;; Non-pair: datum
        ((not (pair? tmpl)) tmpl)
        ;; Ellipsis template: (subtempl ...)
        ((and (pair? (cdr tmpl)) (eq? (cadr tmpl) '...))
         (let* ((subtempl (car tmpl))
                (rest-tmpl (cddr tmpl))
                (evars     (find-ellipsis-vars subtempl env))
                (n         (if (null? evars)
                               0
                               (length (ellipsis-vals (cdr (assq (car evars) env)))))))
           (append
             (map (lambda (i)
                    (let* ((point-env
                            (map (lambda (v)
                                   (cons v (list-ref (ellipsis-vals (cdr (assq v env))) i)))
                                 evars))
                           (local-env (append point-env env)))
                      (instantiate-template subtempl local-env)))
                  (iota n))
             (instantiate-template rest-tmpl env))))
        ;; Regular pair
        (else
         (cons (instantiate-template (car tmpl) env)
               (instantiate-template (cdr tmpl) env)))))

    ;; Build a transformer from a syntax-rules spec.
    (define (make-transformer spec)
      (if (not (and (pair? spec) (eq? (car spec) 'syntax-rules)))
          (error "define-syntax: expected (syntax-rules ...) form" spec)
          (let ((literals (cadr spec))
                (clauses  (cddr spec)))
            (lambda (form)
              (let loop ((cls clauses))
                (if (null? cls)
                    (error "syntax-rules: no matching pattern" form)
                    ;; Strip keyword from both pattern and form
                    (let* ((clause   (car cls))
                           (pat-args (cdr (car clause)))
                           (template (cadr clause))
                           (env      (match-syntax pat-args (cdr form) literals)))
                      (if env
                          (instantiate-template template env)
                          (loop (cdr cls))))))))))

    ;; ---------------------------------------------------------------
    ;; append-map — avoids (apply append (map f lst)) which hits apply arity limits
    ;; when compiled to paal bytecode.
    ;; ---------------------------------------------------------------

    (define (append-map f lst)
      (if (null? lst)
          '()
          (append (f (car lst)) (append-map f (cdr lst)))))

    ;; ---------------------------------------------------------------
    ;; cond-expand helpers
    ;; ---------------------------------------------------------------

    (define (feature-all? reqs)
      (or (null? reqs)
          (and (feature-req? (car reqs)) (feature-all? (cdr reqs)))))

    (define (feature-any? reqs)
      (and (pair? reqs)
           (or (feature-req? (car reqs)) (feature-any? (cdr reqs)))))

    (define (feature-req? req)
      (cond
        ((symbol? req) (if (memq req %paal-features) #t #f))
        ((not (pair? req)) #f)
        ((eq? (car req) 'library) #f)
        ((eq? (car req) 'and) (feature-all? (cdr req)))
        ((eq? (car req) 'or)  (feature-any? (cdr req)))
        ((eq? (car req) 'not) (not (feature-req? (cadr req))))
        (else #f)))

    ;; ---------------------------------------------------------------
    ;; case-lambda helper
    ;; ---------------------------------------------------------------
    ;;
    ;; Count the proper part of a possibly-improper parameter list.

    (define (proper-length lst)
      (let loop ((l lst) (n 0))
        (if (or (null? l) (not (pair? l)))
            n
            (loop (cdr l) (+ n 1)))))

    ;; ---------------------------------------------------------------
    ;; Main dispatch
    ;; ---------------------------------------------------------------

    (define (paal-expand form)
      (if (not (pair? form))
          form
          (case (car form)
            ;; --- Core forms: recurse into sub-forms ---
            ((quote)
             form)
            ((lambda)
             `(lambda ,(cadr form) ,@(expand-body (cddr form))))
            ((define)
             (if (pair? (cadr form))
                 `(define ,(caadr form)
                    (lambda ,(cdadr form) ,@(expand-body (cddr form))))
                 `(define ,(cadr form)
                    ,@(if (null? (cddr form))
                          '()
                          (list (paal-expand (caddr form)))))))
            ((set!)
             `(set! ,(cadr form) ,(paal-expand (caddr form))))
            ((if)
             (if (null? (cdddr form))
                 `(if ,(paal-expand (cadr form))
                      ,(paal-expand (caddr form)))
                 `(if ,(paal-expand (cadr form))
                      ,(paal-expand (caddr form))
                      ,(paal-expand (cadddr form)))))
            ((begin)
             `(begin ,@(map paal-expand (cdr form))))
            ;; --- Derived forms: desugar then re-expand ---
            ((let)         (paal-expand (expand-let form)))
            ((let*)        (paal-expand (expand-let* form)))
            ((letrec letrec*)
                           (paal-expand (expand-letrec form)))
            ((and)         (paal-expand (expand-and (cdr form))))
            ((or)          (paal-expand (expand-or  (cdr form))))
            ((when)        (paal-expand (expand-when form)))
            ((unless)      (paal-expand (expand-unless form)))
            ((cond)        (paal-expand (expand-cond (cdr form))))
            ((case)        (paal-expand (expand-case form)))
            ((quasiquote)  (paal-expand (expand-qq (cadr form) 0)))
            ((do)          (paal-expand (expand-do form)))
            ((define-record-type)
             (paal-expand (expand-define-record-type form)))
            ((guard)
             (paal-expand (expand-guard form)))
            ;; --- New derived forms ---
            ((case-lambda)
             (paal-expand (expand-case-lambda form)))
            ((define-values)
             (paal-expand (expand-define-values form)))
            ((let-values)
             (paal-expand (expand-let-values form)))
            ((let*-values)
             (paal-expand (expand-let*-values form)))
            ((delay)
             ;; (delay expr) → (%paal-delay-impl (lambda () expr))
             ;; %paal-delay-impl creates a lazy promise (not forced until (force p)).
             ;; HOST version is in paal-initial-env; paal-compiled version overrides
             ;; it in pkaappi-make-globals for the bytecode VM path.
             `(%paal-delay-impl (lambda () ,(paal-expand (cadr form)))))
            ((delay-force)
             ;; delay-force (iterative): force inner promise when thunk returns a promise
             `(%paal-delay-impl (lambda () (force ,(paal-expand (cadr form))))))
            ((include)
             (paal-expand (expand-include (cdr form) #f)))
            ((include-ci)
             (paal-expand (expand-include (cdr form) #t)))
            ((cond-expand)
             (paal-expand (expand-cond-expand form)))
            ((syntax-error)
             ;; (syntax-error message irritant ...)
             (apply error (cdr form)))
            ;; --- Macro definition ---
            ((define-syntax)
             (let ((name          (cadr form))
                   (transformer-spec (caddr form)))
               (paal-macro-set! name (make-transformer transformer-spec))
               '(quote #f)))
            ((let-syntax)
             ;; Local macros: bind, expand body, restore
             (let* ((bindings (cadr form))
                    (body     (cddr form))
                    (saved    %paal-macros))
               (for-each (lambda (b)
                           (paal-macro-set! (car b) (make-transformer (cadr b))))
                         bindings)
               (let ((result (paal-expand `(begin ,@body))))
                 (set! %paal-macros saved)
                 result)))
            ((letrec-syntax)
             ;; Same as let-syntax for bootstrap (no true mutual recursion)
             (let* ((bindings (cadr form))
                    (body     (cddr form))
                    (saved    %paal-macros))
               (for-each (lambda (b)
                           (paal-macro-set! (car b) (make-transformer (cadr b))))
                         bindings)
               (let ((result (paal-expand `(begin ,@body))))
                 (set! %paal-macros saved)
                 result)))
            ;; --- Library forms ---
            ((define-library)
             (let ((bodies (filter (lambda (d) (and (pair? d) (eq? (car d) 'begin)))
                                   (cddr form))))
               (paal-expand (cons 'begin (append-map cdr bodies)))))
            ((import export)
             '(quote #f))
            ;; --- User-defined macro or procedure call ---
            (else
             (let ((macro (paal-macro-get (car form))))
               (if (and (symbol? (car form)) macro)
                   (paal-expand (macro form))
                   (map paal-expand form)))))))

    (define (paal-expand-all forms)
      (let splice ((fs forms))
        (if (null? fs)
            '()
            (let ((expanded (paal-expand (car fs))))
              (if (and (pair? expanded) (eq? (car expanded) 'begin))
                  (splice (append (cdr expanded) (cdr fs)))
                  (cons expanded (splice (cdr fs))))))))

    ;; ---------------------------------------------------------------
    ;; let
    ;; ---------------------------------------------------------------

    (define (expand-let form)
      (if (symbol? (cadr form))
          (let* ((name     (cadr form))
                 (bindings (caddr form))
                 (body     (cdddr form))
                 (params   (map car bindings))
                 (inits    (map cadr bindings)))
            `(letrec ((,name (lambda ,params ,@body)))
               (,name ,@inits)))
          (let* ((bindings (cadr form))
                 (body     (cddr form))
                 (params   (map car bindings))
                 (inits    (map cadr bindings)))
            `((lambda ,params ,@body) ,@inits))))

    ;; ---------------------------------------------------------------
    ;; let*
    ;; ---------------------------------------------------------------

    (define (expand-let* form)
      (let ((bindings (cadr form))
            (body     (cddr form)))
        (if (null? bindings)
            `(begin ,@body)
            `(let (,(car bindings))
               (let* ,(cdr bindings) ,@body)))))

    ;; ---------------------------------------------------------------
    ;; letrec / letrec*
    ;; ---------------------------------------------------------------

    (define (expand-letrec form)
      (let* ((bindings (cadr form))
             (body     (cddr form))
             (names    (map car bindings))
             (inits    (map cadr bindings)))
        `(let ,(map (lambda (n) `(,n #f)) names)
           ,@(map (lambda (n e) `(set! ,n ,e)) names inits)
           ,@body)))

    ;; ---------------------------------------------------------------
    ;; and / or
    ;; ---------------------------------------------------------------

    (define (expand-and exprs)
      (cond
        ((null? exprs)       '#t)
        ((null? (cdr exprs)) (car exprs))
        (else `(if ,(car exprs) (and ,@(cdr exprs)) #f))))

    (define (expand-or exprs)
      (cond
        ((null? exprs)       '#f)
        ((null? (cdr exprs)) (car exprs))
        (else
         (let ((t (fresh-name "__paal_t")))
           `(let ((,t ,(car exprs)))
              (if ,t ,t (or ,@(cdr exprs))))))))

    ;; ---------------------------------------------------------------
    ;; when / unless
    ;; ---------------------------------------------------------------

    (define (expand-when form)
      `(if ,(cadr form) (begin ,@(cddr form))))

    (define (expand-unless form)
      `(if (not ,(cadr form)) (begin ,@(cddr form))))

    ;; ---------------------------------------------------------------
    ;; cond
    ;; ---------------------------------------------------------------

    (define (expand-cond clauses)
      (if (null? clauses)
          '(if #f #f)
          (let ((clause (car clauses))
                (rest   (cdr clauses)))
            (cond
              ((and (pair? clause) (eq? (car clause) 'else))
               `(begin ,@(cdr clause)))
              ((= (length clause) 1)
               `(or ,(car clause) (cond ,@rest)))
              ((and (= (length clause) 3) (eq? (cadr clause) '=>))
               (let ((v (fresh-name "__paal_cv")))
                 `(let ((,v ,(car clause)))
                    (if ,v (,(caddr clause) ,v) (cond ,@rest)))))
              (else
               `(if ,(car clause)
                    (begin ,@(cdr clause))
                    (cond ,@rest)))))))

    ;; ---------------------------------------------------------------
    ;; case
    ;; ---------------------------------------------------------------

    (define (expand-case form)
      (let ((key     (cadr form))
            (clauses (cddr form))
            (k       (fresh-name "__paal_ck")))
        `(let ((,k ,key))
           (cond ,@(map (lambda (clause)
                          (if (eq? (car clause) 'else)
                              clause
                              `((memv ,k ',(car clause)) ,@(cdr clause))))
                        clauses)))))

    ;; ---------------------------------------------------------------
    ;; quasiquote
    ;; ---------------------------------------------------------------

    (define (expand-qq form depth)
      (cond
        ((vector? form)
         (list 'list->vector (expand-qq (vector->list form) depth)))
        ((not (pair? form))
         (list 'quote form))
        ((eq? (car form) 'unquote)
         (if (= depth 0)
             (cadr form)
             (list 'list
                   (list 'quote 'unquote)
                   (expand-qq (cadr form) (- depth 1)))))
        ((eq? (car form) 'quasiquote)
         (list 'list
               (list 'quote 'quasiquote)
               (expand-qq (cadr form) (+ depth 1))))
        ((and (pair? (car form)) (eq? (caar form) 'unquote-splicing))
         (if (= depth 0)
             (list 'append (cadar form) (expand-qq (cdr form) depth))
             (list 'cons
                   (list 'list (list 'quote 'unquote-splicing)
                               (expand-qq (cadar form) (- depth 1)))
                   (expand-qq (cdr form) depth))))
        (else
         (list 'cons (expand-qq (car form) depth) (expand-qq (cdr form) depth)))))

    ;; ---------------------------------------------------------------
    ;; do
    ;; ---------------------------------------------------------------

    (define (expand-do form)
      (let* ((var-specs  (cadr form))
             (exit-spec  (caddr form))
             (commands   (cdddr form))
             (test       (car exit-spec))
             (results    (cdr exit-spec))
             (vars       (map car var-specs))
             (inits      (map cadr var-specs))
             (steps      (map (lambda (spec)
                                (if (null? (cddr spec))
                                    (car spec)
                                    (caddr spec)))
                              var-specs))
             (loop       (fresh-name "__paal_do")))
        `(let ,loop ,(map list vars inits)
           (if ,test
               (begin ,@(if (null? results) '((if #f #f)) results))
               (begin ,@commands (,loop ,@steps))))))

    ;; ---------------------------------------------------------------
    ;; case-lambda
    ;; ---------------------------------------------------------------
    ;;
    ;; (case-lambda ((p...) body...) ...)
    ;; → (lambda %args (cond (arity-check (let ((p (car %args))...) body)) ...))
    ;;
    ;; We use let-destructuring (not apply) because apply on a paal closure
    ;; would cross the HOST/paal boundary. let expands to a direct call that
    ;; stays within the paal bytecode VM.

    (define (expand-case-lambda form)
      (let ((clauses  (cdr form))
            (args-var (fresh-name "__paal_args")))
        `(lambda ,args-var
           ,(case-lambda-dispatch args-var clauses))))

    ;; Generate (list-ref args-var i) accessor form
    (define (args-ref args-var i)
      (case i
        ((0) `(car ,args-var))
        ((1) `(cadr ,args-var))
        ((2) `(caddr ,args-var))
        ((3) `(cadddr ,args-var))
        (else `(list-ref ,args-var ,i))))

    ;; Generate let-bindings that destructure args-var into params
    (define (params->lets args-var params)
      (let loop ((p params) (i 0) (acc '()))
        (cond
          ((null? p) (reverse acc))
          ((pair? p)
           (loop (cdr p) (+ i 1)
                 (cons (list (car p) (args-ref args-var i)) acc)))
          ;; Rest variable (improper list tail)
          ((symbol? p)
           (reverse (cons (list p `(list-tail ,args-var ,i)) acc))))))

    (define (case-lambda-dispatch args-var clauses)
      (if (null? clauses)
          `(error "case-lambda: no matching arity" (length ,args-var))
          (let* ((clause (car clauses))
                 (params (car clause))
                 (body   (cdr clause))
                 (lets   (params->lets args-var params)))
            (cond
              ;; Pure rest parameter (symbol): matches any arity
              ((symbol? params)
               `(let ((,params ,args-var)) ,@body))
              ;; Exact arity (proper list)
              ((list? params)
               (let ((n (length params)))
                 `(if (= (length ,args-var) ,n)
                      (let ,lets ,@body)
                      ,(case-lambda-dispatch args-var (cdr clauses)))))
              ;; At-least-n arity (improper list)
              (else
               (let ((n (proper-length params)))
                 `(if (>= (length ,args-var) ,n)
                      (let ,lets ,@body)
                      ,(case-lambda-dispatch args-var (cdr clauses)))))))))

    ;; ---------------------------------------------------------------
    ;; define-values
    ;; ---------------------------------------------------------------
    ;;
    ;; (define-values (a b c) expr)
    ;; → (begin (define a #f) (define b #f) (define c #f)
    ;;          (call-with-values (lambda () expr)
    ;;            (lambda (ta tb tc) (set! a ta) (set! b tb) (set! c tc))))

    (define (expand-define-values form)
      (let* ((names     (cadr form))
             (expr      (caddr form))
             (tmp-names (map (lambda (n)
                               (fresh-name (string-append "__paal_dv_"
                                                          (symbol->string n))))
                             names)))
        `(begin
           ,@(map (lambda (n) `(define ,n #f)) names)
           (call-with-values
             (lambda () ,expr)
             (lambda ,tmp-names
               ,@(map (lambda (n t) `(set! ,n ,t)) names tmp-names))))))

    ;; ---------------------------------------------------------------
    ;; let-values / let*-values
    ;; ---------------------------------------------------------------
    ;;
    ;; (let-values (((a b) e1) ((c) e2)) body...)
    ;; → (call-with-values (lambda () e1)
    ;;     (lambda (a b)
    ;;       (call-with-values (lambda () e2)
    ;;         (lambda (c) body...))))

    (define (expand-let-values form)
      (let ((bindings (cadr form))
            (body     (cddr form)))
        (if (null? bindings)
            `(begin ,@body)
            (let* ((b     (car bindings))
                   (names (car b))
                   (expr  (cadr b)))
              `(call-with-values
                 (lambda () ,expr)
                 (lambda ,names
                   (let-values ,(cdr bindings) ,@body)))))))

    (define (expand-let*-values form)
      ;; let*-values binds sequentially; same structure as let-values.
      (let ((bindings (cadr form))
            (body     (cddr form)))
        (if (null? bindings)
            `(begin ,@body)
            (let* ((b     (car bindings))
                   (names (car b))
                   (expr  (cadr b)))
              `(call-with-values
                 (lambda () ,expr)
                 (lambda ,names
                   (let*-values ,(cdr bindings) ,@body)))))))

    ;; ---------------------------------------------------------------
    ;; include / include-ci
    ;; ---------------------------------------------------------------
    ;;
    ;; Read and splice all forms from each named file.
    ;; include-ci folds case (not yet implemented: treated same as include).

    (define (expand-include paths case-fold?)
      (cons 'begin
        (apply append
          (map (lambda (path)
                 (call-with-input-file path
                   (lambda (port)
                     (let loop ((form (read port)) (acc '()))
                       (if (eof-object? form)
                           (reverse acc)
                           (loop (read port) (cons form acc)))))))
               paths))))

    ;; ---------------------------------------------------------------
    ;; cond-expand
    ;; ---------------------------------------------------------------

    (define (expand-cond-expand form)
      (let loop ((clauses (cdr form)))
        (cond
          ((null? clauses)
           '(begin))    ; no matching clause and no else → void
          ((eq? (caar clauses) 'else)
           `(begin ,@(cdar clauses)))
          ((feature-req? (caar clauses))
           `(begin ,@(cdar clauses)))
          (else
           (loop (cdr clauses))))))

    ;; ---------------------------------------------------------------
    ;; Body expansion (internal defines → letrec*)
    ;; ---------------------------------------------------------------

    (define (define->binding d)
      (if (pair? (cadr d))
          (list (caadr d) (cons 'lambda (cons (cdadr d) (cddr d))))
          (list (cadr d) (if (null? (cddr d)) #f (caddr d)))))

    (define (expand-body forms)
      (let loop ((rest forms) (defs '()))
        (cond
          ((null? rest)
           (if (null? defs)
               (error "paal-expand: empty lambda body")
               (error "paal-expand: lambda body has only definitions")))
          ;; define-values in body: wrap remaining forms in let-values
          ((and (pair? (car rest)) (eq? (caar rest) 'define-values))
           (let* ((dvform    (car rest))
                  (names     (cadr dvform))
                  (expr      (caddr dvform))
                  (remaining (cdr rest))
                  (wrapped   `(let-values ((,names ,expr)) ,@remaining)))
             (if (null? defs)
                 (list (paal-expand wrapped))
                 (list (paal-expand
                         (cons 'letrec*
                           (cons (map define->binding (reverse defs))
                                 (list wrapped))))))))
          ((and (pair? (car rest)) (eq? (caar rest) 'define))
           (loop (cdr rest) (cons (car rest) defs)))
          (else
           (if (null? defs)
               (map paal-expand rest)
               (list (paal-expand
                       (cons 'letrec*
                         (cons (map define->binding (reverse defs))
                               rest)))))))))

    ;; ---------------------------------------------------------------
    ;; guard
    ;; ---------------------------------------------------------------
    ;;
    ;; (guard (var clause ...) body ...)
    ;;   => (%paal-guard-run (lambda () body ...)
    ;;                       (lambda (var) (cond clause ... (else (raise var)))))
    ;;
    ;; %paal-guard-run runs the body thunk under a HOST guard and, on an
    ;; exception, applies the handler to the condition.  Each pipeline provides
    ;; it differently: the tree-walking VM binds a plain HOST procedure, since
    ;; its closures are themselves HOST procedures, while the bytecode VM binds
    ;; a marker that do-call! recognizes and acts on (see vm-bc.sld).
    ;;
    ;; The trailing else re-raises unmatched conditions, per R7RS — but from the
    ;; handler's dynamic environment rather than the original one, so a
    ;; raise-continuable that no clause matches cannot be resumed.

    (define (expand-guard form)
      (let* ((var-and-clauses (cadr form))
             (var     (car var-and-clauses))
             (clauses (cdr var-and-clauses))
             (body    (cddr form))
             ; An explicit else already handles everything; a second one is an error.
             (has-else? (and (pair? clauses)
                             (let loop ((cs clauses))
                               (cond ((null? (cdr cs))
                                      (and (pair? (car cs)) (eq? (caar cs) 'else)))
                                     (else (loop (cdr cs)))))))
             (all-clauses (if has-else?
                              clauses
                              (append clauses `((else (raise ,var)))))))
        `(%paal-guard-run
           (lambda () ,@body)
           (lambda (,var) (cond ,@all-clauses)))))

    ;; ---------------------------------------------------------------
    ;; define-record-type desugaring
    ;; ---------------------------------------------------------------

    (define (expand-define-record-type form)
      (let* ((type-name   (cadr form))
             (ctor-spec   (caddr form))
             (pred-name   (cadddr form))
             (field-specs (cddddr form))
             (ctor-name   (car ctor-spec))
             (ctor-fields (cdr ctor-spec))
             (n           (length ctor-fields))
             (tag-var     (string->symbol
                            (string-append "%" (symbol->string type-name) "-tag")))
             (field-idx   (lambda (fname)
                            (let loop ((fs ctor-fields) (i 1))
                              (cond
                                ((null? fs)
                                 (error "paal: define-record-type: field not in constructor" fname))
                                ((eq? (car fs) fname) i)
                                (else (loop (cdr fs) (+ i 1)))))))
             (ctor-sets   (let lp ((fs ctor-fields) (i 1) (acc '()))
                            (if (null? fs)
                                (reverse acc)
                                (lp (cdr fs) (+ i 1)
                                    (cons `(vector-set! v ,i ,(car fs)) acc)))))
             (field-defs  (append-map
                            (lambda (spec)
                              (let* ((fname (car spec))
                                     (idx   (field-idx fname))
                                     (acc   (cadr spec))
                                     (mut   (and (pair? (cddr spec)) (caddr spec))))
                                (if mut
                                    `((define (,acc obj) (vector-ref obj ,idx))
                                      (define (,mut obj val) (vector-set! obj ,idx val)))
                                    `((define (,acc obj) (vector-ref obj ,idx))))))
                            field-specs)))
        `(begin
           (define ,tag-var (list (quote ,type-name)))
           (define (,ctor-name ,@ctor-fields)
             (let ((v (make-vector ,(+ 1 n))))
               (vector-set! v 0 ,tag-var)
               ,@ctor-sets
               v))
           (define (,pred-name obj)
             (and (vector? obj)
                  (= (vector-length obj) ,(+ 1 n))
                  (eq? (vector-ref obj 0) ,tag-var)))
           ,@field-defs)))

    ))
