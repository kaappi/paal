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
             `(lambda ,(cadr form) ,@(map paal-expand (cddr form))))
            ((define)
             (if (pair? (cadr form))
                 `(define ,(cadr form) ,@(map paal-expand (cddr form)))
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
            ;; --- Procedure call or unrecognised form ---
            (else (map paal-expand form)))))

    (define (paal-expand-all forms)
      (map paal-expand forms))

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
               (begin ,@commands (,loop ,@steps))))))))
