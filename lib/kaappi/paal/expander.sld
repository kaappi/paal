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

(define-library (kaappi paal expander)
  (import (scheme base))
  (export paal-expand paal-expand-all)
  (begin

    ;; Counter for introducing hygienic temporaries.
    (define %expander-counter 0)
    (define (fresh-name prefix)
      (set! %expander-counter (+ %expander-counter 1))
      (string->symbol
        (string-append prefix (number->string %expander-counter))))

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
                 ; Shorthand (define (f params) body...): convert to canonical form
                 ; and use expand-body so internal defines are lifted to letrec*.
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
            ((define-library)
             ;; Minimal: extract all (begin ...) declarations and splice.
             (let ((bodies (filter (lambda (d) (and (pair? d) (eq? (car d) 'begin)))
                                   (cddr form))))
               (paal-expand (cons 'begin (apply append (map cdr bodies))))))
            ((import export)
             ;; No-op: imports/exports not resolved during bootstrap.
             '(quote #f))
            ;; --- Procedure call or unrecognised form ---
            (else (map paal-expand form)))))

    (define (paal-expand-all forms)
      ;; Top-level begin is transparent in R7RS: splice its contents.
      ;; This is needed for define-record-type and define-library desugaring,
      ;; which both produce a top-level (begin (define ...) ...) form.
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
    ;;
    ;; Named let: (let name ((v e) ...) body...)
    ;;   → (letrec ((name (lambda (v ...) body...))) (name e ...))
    ;;
    ;; Plain let: (let ((v e) ...) body...)
    ;;   → ((lambda (v ...) body...) e ...)

    (define (expand-let form)
      (if (symbol? (cadr form))
          ;; named let
          (let* ((name     (cadr form))
                 (bindings (caddr form))
                 (body     (cdddr form))
                 (params   (map car bindings))
                 (inits    (map cadr bindings)))
            `(letrec ((,name (lambda ,params ,@body)))
               (,name ,@inits)))
          ;; plain let
          (let* ((bindings (cadr form))
                 (body     (cddr form))
                 (params   (map car bindings))
                 (inits    (map cadr bindings)))
            `((lambda ,params ,@body) ,@inits))))

    ;; ---------------------------------------------------------------
    ;; let*
    ;; ---------------------------------------------------------------
    ;;
    ;; (let* () body...)         → (begin body...)
    ;; (let* ((v e) rest...) b)  → (let ((v e)) (let* (rest...) b))

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
    ;;
    ;; (letrec ((v e) ...) body...)
    ;;   → (let ((v #f) ...) (set! v e) ... body...)
    ;;
    ;; letrec* uses the same encoding; sequential set! semantics are
    ;; equivalent since we have no parallelism in the bootstrap VM.

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
    ;;
    ;; (and)            → #t
    ;; (and e)          → e
    ;; (and e rest...)  → (if e (and rest...) #f)
    ;;
    ;; (or)             → #f
    ;; (or e)           → e
    ;; (or e rest...)   → (let ((_t e)) (if _t _t (or rest...)))

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
    ;;
    ;; (cond)                     → (if #f #f)
    ;; (cond (else e...))         → (begin e...)
    ;; (cond (t) rest...)         → (or t (cond rest...))
    ;; (cond (t => f) rest...)    → (let ((_v t)) (if _v (f _v) (cond rest...)))
    ;; (cond (t e...) rest...)    → (if t (begin e...) (cond rest...))

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
    ;;
    ;; (case key ((d...) e...) ... (else e...))
    ;; → (let ((_k key)) (cond ((memv _k '(d...)) e...) ... (else e...)))

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
    ;;
    ;; Expand a quasiquoted form to cons/append/list calls.
    ;; depth tracks nesting level for nested quasiquotes.
    ;;
    ;; Uses explicit list construction rather than quasiquote templates
    ;; to avoid kaappi's expander misinterpreting 'unquote-splicing as
    ;; a special form when it appears as a literal symbol in a template.

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
    ;;
    ;; (do ((v init step) ...) (test result...) cmd...)
    ;; → (let loop ((v init) ...)
    ;;     (if test
    ;;         (begin result...)
    ;;         (begin cmd... (loop step...))))
    ;;
    ;; If a binding omits the step, the variable keeps its value.

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
                                    (car spec)     ; no step → keep var
                                    (caddr spec)))
                              var-specs))
             (loop       (fresh-name "__paal_do")))
        `(let ,loop ,(map list vars inits)
           (if ,test
               (begin ,@(if (null? results) '((if #f #f)) results))
               (begin ,@commands (,loop ,@steps))))))

    ;; ---------------------------------------------------------------
    ;; Body expansion (internal defines → letrec*)
    ;; ---------------------------------------------------------------
    ;;
    ;; R7RS §5.3.2: leading (define ...) forms in a lambda body are
    ;; equivalent to a letrec*. expand-body hoists them.

    (define (define->binding d)
      ;; Convert (define ...) to a (name expr) letrec* binding pair.
      (if (pair? (cadr d))
          ;; (define (name params...) body...)
          (list (caadr d) (cons 'lambda (cons (cdadr d) (cddr d))))
          ;; (define name expr)
          (list (cadr d) (if (null? (cddr d)) #f (caddr d)))))

    (define (expand-body forms)
      ;; Expand a lambda body list. Leading (define ...) forms are lifted
      ;; to letrec*. Returns a list of expanded forms for ,@body splicing.
      (let loop ((rest forms) (defs '()))
        (cond
          ((null? rest)
           (if (null? defs)
               (error "paal-expand: empty lambda body")
               (error "paal-expand: lambda body has only definitions")))
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
    ;; define-record-type desugaring
    ;; ---------------------------------------------------------------
    ;;
    ;; Generates constructor, predicate, and field accessors/mutators
    ;; using vector storage. Layout: [type-tag, field0, field1, ...]
    ;; The type-tag is a fresh pair allocated once; eq? identity = type test.

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
             ;; 1-based vector index for a given field name.
             (field-idx   (lambda (fname)
                            (let loop ((fs ctor-fields) (i 1))
                              (cond
                                ((null? fs)
                                 (error "paal: define-record-type: field not in constructor" fname))
                                ((eq? (car fs) fname) i)
                                (else (loop (cdr fs) (+ i 1)))))))
             ;; (vector-set! v i field) for each constructor parameter.
             (ctor-sets   (let lp ((fs ctor-fields) (i 1) (acc '()))
                            (if (null? fs)
                                (reverse acc)
                                (lp (cdr fs) (+ i 1)
                                    (cons `(vector-set! v ,i ,(car fs)) acc)))))
             ;; Accessor and optional mutator defines per field spec.
             (field-defs  (apply append
                            (map (lambda (spec)
                                   (let* ((fname (car spec))
                                          (idx   (field-idx fname))
                                          (acc   (cadr spec))
                                          (mut   (and (pair? (cddr spec)) (caddr spec))))
                                     (if mut
                                         `((define (,acc obj) (vector-ref obj ,idx))
                                           (define (,mut obj val) (vector-set! obj ,idx val)))
                                         `((define (,acc obj) (vector-ref obj ,idx))))))
                                 field-specs))))
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
