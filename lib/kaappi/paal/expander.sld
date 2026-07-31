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
  (export paal-expand paal-expand-all paal-macros-reset! gref-name
          paal-lib-path-add! paal-lib-paths-list paal-libraries-reset!)
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

    ;; Drop every macro definition.  %paal-macros is module state, so without
    ;; this a define-syntax in one program stays installed for the next and
    ;; silently shadows a procedure of the same name there.  Callers reset it
    ;; when they create a fresh globals table, giving macros the same lifetime
    ;; as the definitions they sit alongside — `load`-style entry points that
    ;; add to an existing table deliberately do not reset, so macros accumulate
    ;; across loaded files and across REPL inputs.
    ;; Loaded libraries are reset alongside the macros, and for the same
    ;; reason: both are expander state scoped to one program.  A library's
    ;; forms are spliced into the program that imports it, so a second program
    ;; needs them spliced again — remembering that they had already been
    ;; emitted would hand the next program aliases pointing at definitions that
    ;; are not in its globals table.  Keeping the two in one procedure means a
    ;; new call site cannot reset one and forget the other.
    (define (paal-macros-reset!)
      (set! %paal-macros '())
      (paal-libraries-reset!))

    ;; ---------------------------------------------------------------
    ;; Feature list for cond-expand
    ;; ---------------------------------------------------------------

    ;; `kaappi` is here because paal targets the same language: a library
    ;; guarded by (cond-expand (kaappi ...)) is written against primitives paal
    ;; also provides, and excluding ourselves would send such code down a
    ;; portable-fallback path for no reason.
    (define %paal-features '(paal kaappi r7rs scheme))

    ;; ---------------------------------------------------------------
    ;; Library system
    ;; ---------------------------------------------------------------
    ;;
    ;; Paal links libraries statically.  `(import (foo bar))` finds foo/bar.sld
    ;; on the library path, expands it, renames its top-level definitions to
    ;; names unique to that library, and splices the result in front of the
    ;; importing program — then defines the imported names as aliases of the
    ;; renamed ones.
    ;;
    ;; Export filtering falls out of the renaming rather than needing a
    ;; mechanism: a name the library did not export exists only under its
    ;; mangled name, which nothing outside ever aliases.  Selective import is
    ;; then just a transformation on the alias list, which is why `only`,
    ;; `except`, `rename` and `prefix` compose in any order.
    ;;
    ;; Renaming runs *after* expansion, over core forms only, so `lambda` is the
    ;; single binder the substitution has to know about.  Doing it before
    ;; expansion would mean teaching it every derived binding form.
    ;;
    ;; Splicing rather than separate compilation matches paal's flat globals,
    ;; and matches where the binary is going anyway — a bundled `paal` carries
    ;; its libraries with it.

    (define %paal-lib-paths '("."))
    (define %paal-libraries '())      ; name -> alist of public-name -> internal
    (define %paal-loading   '())      ; names being loaded, for cycle detection
    (define %paal-pending   '())      ; library forms not yet handed to a program
    (define %paal-emitted   '())      ; names whose forms have been handed over

    (define (paal-lib-path-add! dir)
      (unless (member dir %paal-lib-paths)
        (set! %paal-lib-paths (append %paal-lib-paths (list dir)))))

    ;; Read back for the self-hosted entry points.  Under self-hosting the
    ;; loaded pipeline is a second copy of this library with its own
    ;; %paal-lib-paths, and --lib-path was only ever applied to the HOST copy —
    ;; so the loaded expander searched "." alone and silently found nothing.
    (define (paal-lib-paths-list) %paal-lib-paths)

    (define (paal-libraries-reset!)
      (set! %paal-libraries '())
      (set! %paal-loading '())
      (set! %paal-pending '())
      (set! %paal-emitted '()))

    ;; `(scheme base)` and friends have no file: their bindings are already in
    ;; paal-initial-env, so importing one is a no-op that yields no aliases.
    (define (builtin-library? name)
      (and (pair? name) (eq? (car name) 'scheme)))

    (define (library-name->path name)
      (let loop ((parts name) (acc ""))
        (if (null? parts)
            (string-append acc ".sld")
            (loop (cdr parts)
                  (if (string=? acc "")
                      (symbol->string (car parts))
                      (string-append acc "/" (symbol->string (car parts))))))))

    (define (find-library-file name)
      (let ((rel (library-name->path name)))
        (let loop ((dirs %paal-lib-paths))
          (cond
            ((null? dirs) #f)
            ((file-exists? (string-append (car dirs) "/" rel))
             (string-append (car dirs) "/" rel))
            (else (loop (cdr dirs)))))))

    (define (library-name->tag name)
      (let loop ((parts name) (acc "%"))
        (if (null? parts)
            acc
            (loop (cdr parts)
                  (string-append acc (symbol->string (car parts)) "%")))))

    (define (read-forms-from path)
      (call-with-input-file path
        (lambda (port)
          (let loop ((form (read port)) (acc '()))
            (if (eof-object? form)
                (reverse acc)
                (loop (read port) (cons form acc)))))))

    ;; --- import specs ---------------------------------------------------
    ;;
    ;; Each returns an alias list: (visible-name . internal-name).  The
    ;; modifiers wrap a nested spec, so (prefix (only (m) a b) x:) works.

    (define (resolve-import spec)
      (cond
        ((not (pair? spec)) (error "paal: malformed import spec" spec))
        ((eq? (car spec) 'only)
         (let ((base (resolve-import (cadr spec))) (names (cddr spec)))
           (for-each (lambda (n)
                       (unless (assq n base)
                         (error "paal: `only` names a binding the library does not export" n)))
                     names)
           (filter (lambda (p) (memq (car p) names)) base)))
        ((eq? (car spec) 'except)
         (let ((base (resolve-import (cadr spec))) (names (cddr spec)))
           (for-each (lambda (n)
                       (unless (assq n base)
                         (error "paal: `except` names a binding the library does not export" n)))
                     names)
           (filter (lambda (p) (not (memq (car p) names))) base)))
        ((eq? (car spec) 'prefix)
         (let ((base (resolve-import (cadr spec)))
               (pfx  (symbol->string (caddr spec))))
           (map (lambda (p)
                  (cons (string->symbol
                          (string-append pfx (symbol->string (car p))))
                        (cdr p)))
                base)))
        ((eq? (car spec) 'rename)
         (let ((base (resolve-import (cadr spec))) (pairs (cddr spec)))
           (map (lambda (p)
                  (let ((hit (assq (car p) pairs)))
                    (if hit (cons (cadr hit) (cdr p)) p)))
                base)))
        (else (library-exports spec))))

    ;; --- loading --------------------------------------------------------

    (define (library-exports name)
      (cond
        ((builtin-library? name) '())
        ((assoc name %paal-libraries) => cdr)
        ((member name %paal-loading)
         (error "paal: circular import" (reverse (cons name %paal-loading))))
        (else (load-library! name))))

    ;; A name with no file on the path resolves to no aliases rather than an
    ;; error, which is what `import` did before there was a library system.
    ;; Paal's own stages depend on that: pkaappi-load-file deliberately loads
    ;; every pipeline .sld into one shared globals table, and each of them
    ;; imports (kaappi paal ir) — a name that is never on the search path,
    ;; because the table already holds what it would provide.
    ;;
    ;; The cost is that a mistyped library name does nothing instead of saying
    ;; so.  Making it an error needs the pipeline's own loading to stop going
    ;; through `import`; see docs/TODO.md.
    (define (load-library! name)
      (let ((path (find-library-file name)))
        (if (not path)
            (begin
              (set! %paal-libraries (cons (cons name '()) %paal-libraries))
              '())
            (begin
              (set! %paal-loading (cons name %paal-loading))
              (let ((result (load-library-from name path)))
                (set! %paal-loading (cdr %paal-loading))
                result)))))

    ;; A .sld holds exactly one define-library.  Anything else in the file is
    ;; ignored, which is what makes a library file also loadable as a script.
    (define (load-library-from name path)
      (let ((form (let loop ((fs (read-forms-from path)))
                    (cond
                      ((null? fs)
                       (error "paal: no define-library in file" path))
                      ((and (pair? (car fs)) (eq? (caar fs) 'define-library))
                       (car fs))
                      (else (loop (cdr fs)))))))
        (install-library! name (cddr form))))

    (define (decls-of decls tag)
      (filter (lambda (d) (and (pair? d) (eq? (car d) tag))) decls))

    ;; (export a b (rename internal external)) -> alist external -> internal
    (define (export-alist decls)
      (let loop ((ds (decls-of decls 'export)) (acc '()))
        (if (null? ds)
            (reverse acc)
            (loop (cdr ds)
                  (let inner ((specs (cdr (car ds))) (acc acc))
                    (cond
                      ((null? specs) acc)
                      ((symbol? (car specs))
                       (inner (cdr specs) (cons (cons (car specs) (car specs)) acc)))
                      ((and (pair? (car specs)) (eq? (caar specs) 'rename))
                       (inner (cdr specs)
                              (cons (cons (caddr (car specs)) (cadr (car specs)))
                                    acc)))
                      (else (error "paal: malformed export spec" (car specs)))))))))

    (define (install-library! name decls)
      (let* ((imports  (append-map cdr (decls-of decls 'import)))
             ;; The library's own imports first: they may define macros its
             ;; body uses, and expansion is where a macro takes effect.
             (prologue (map expand-one-import imports))
             (bodies   (append-map cdr (decls-of decls 'begin)))
             (includes (decls-of decls 'include))
             (included (append-map (lambda (d) (cdr (expand-include (cdr d) #f)))
                                   includes))
             (exports  (export-alist decls))
             ;; Expand to core forms.  Renaming afterwards only has to know
             ;; about `lambda`, since every other binder is gone by then.
             (core     (paal-expand-all (append included bodies)))
             (defined  (top-level-defined core))
             (tag      (library-name->tag name))
             (renames  (map (lambda (n)
                              (cons n (string->symbol
                                        (string-append tag (symbol->string n)))))
                            defined))
             (renamed  (map (lambda (f) (rename-core f renames)) core)))
        ;; A library's macros all stay installed, including ones it did not
        ;; export.  Dropping the private ones is what you want for hygiene, and
        ;; it was the first thing tried — but an *exported* macro whose template
        ;; calls a private one then breaks at the use site, because the
        ;; template still names it and the table no longer has it.  Fixing that
        ;; properly means rewriting exported templates to name the private
        ;; macro under a mangled name, and by this point a transformer is a
        ;; closure over its rules rather than data one can walk.
        ;;
        ;; So the trade is: a private macro name leaks into the importer, where
        ;; it can collide.  The alternative silently breaks working library
        ;; code, which is worse.  Private *values* are unaffected — those are
        ;; renamed, and the renaming is what hides them.  See docs/TODO.md.
        %paal-macros
        (let ((export-map
               (map (lambda (e)
                      (let ((hit (assq (cdr e) renames)))
                        (cons (car e) (if hit (cdr hit) (cdr e)))))
                    exports)))
          (set! %paal-libraries (cons (cons name export-map) %paal-libraries))
          (set! %paal-pending
                (append %paal-pending
                        (list (cons name (append prologue renamed)))))
          export-map)))

    ;; The entries %paal-macros gained since `older` — it only ever grows by
    ;; consing, so the new ones are exactly the prefix before the old head.
    (define (take-until lst older)
      (if (or (null? lst) (eq? lst older))
          '()
          (cons (car lst) (take-until (cdr lst) older))))

    (define (top-level-defined forms)
      (let loop ((fs forms) (acc '()))
        (cond
          ((null? fs) (reverse acc))
          ((and (pair? (car fs)) (eq? (caar fs) 'define)
                (pair? (cdar fs)) (symbol? (cadr (car fs)))
                (not (memq (cadr (car fs)) acc)))
           (loop (cdr fs) (cons (cadr (car fs)) acc)))
          (else (loop (cdr fs) acc)))))

    ;; --- capture-avoiding rename over core forms -------------------------

    (define (formal-names f)
      (cond ((symbol? f) (list f))
            ((pair? f)   (append (formal-names (car f)) (formal-names (cdr f))))
            (else '())))

    (define (drop-renames renames shadowed)
      (filter (lambda (p) (not (memq (car p) shadowed))) renames))

    (define (rename-core form renames)
      (cond
        ((null? renames) form)
        ((symbol? form)
         (let ((hit (assq form renames))) (if hit (cdr hit) form)))
        ((not (pair? form)) form)
        ((eq? (car form) 'quote) form)
        ((and (eq? (car form) 'lambda) (pair? (cdr form)))
         (let ((inner (drop-renames renames (formal-names (cadr form)))))
           (cons 'lambda
                 (cons (cadr form)
                       (map (lambda (f) (rename-core f inner)) (cddr form))))))
        (else
         (let loop ((f form) (acc '()))
           (cond
             ((null? f) (reverse acc))
             ((not (pair? f))                 ; improper tail
              (append (reverse acc) (rename-core f renames)))
             (else (loop (cdr f) (cons (rename-core (car f) renames) acc))))))))

    ;; --- the import form -------------------------------------------------

    ;; Aliases for one spec.  Loading happens here, so a library's macros are
    ;; installed before anything that uses them is expanded.
    ;; An exported *macro* has no run-time value to alias — `(define swap!
    ;; swap!)` would reference an unbound variable.  Renaming it is a macro
    ;; table entry instead, pointing at the same transformer.
    (define (expand-one-import spec)
      (let ((aliases (resolve-import spec)))
        (cons 'begin
              (filter-map
                (lambda (p)
                  (let ((transformer (paal-macro-get (cdr p))))
                    (cond
                      (transformer
                       (unless (eq? (car p) (cdr p))
                         (paal-macro-set! (car p) transformer))
                       #f)
                      (else (list 'define (car p) (cdr p))))))
                aliases))))

    (define (filter-map f lst)
      (let loop ((l lst) (acc '()))
        (if (null? l)
            (reverse acc)
            (let ((v (f (car l))))
              (loop (cdr l) (if v (cons v acc) acc))))))

    ;; Everything loaded but not yet handed to a program, in dependency order.
    (define (drain-pending!)
      (let ((out (append-map
                   (lambda (entry)
                     (if (member (car entry) %paal-emitted)
                         '()
                         (begin
                           (set! %paal-emitted (cons (car entry) %paal-emitted))
                           (cdr entry))))
                   %paal-pending)))
        (set! %paal-pending '())
        out))

    (define (expand-import form)
      (let ((aliases (map expand-one-import (cdr form))))
        ;; Library bodies must precede the aliases that name into them, and
        ;; both must precede the importing program.
        (cons 'begin (append (drain-pending!) aliases))))

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

    (define (concat-lists ls)
      (if (null? ls) '() (append (car ls) (concat-lists (cdr ls)))))

    ;; How many ellipses a template element is followed by.  One is the ordinary
    ;; case; each extra one splices a further level, so (x ... ...) flattens what
    ;; ((x ...) ...) would have nested.
    (define (count-ellipses l)
      (if (and (pair? l) (eq? (car l) '...))
          (+ 1 (count-ellipses (cdr l)))
          0))

    (define (drop-ellipses l)
      (if (and (pair? l) (eq? (car l) '...))
          (drop-ellipses (cdr l))
          l))

    ;; Expand `subtempl` across `depth` levels of ellipsis, returning a flat list
    ;; of the results.  At depth 1 each iteration contributes one element; deeper
    ;; down each contributes a list, and those are concatenated — which is what
    ;; makes the extra ellipses splice rather than nest.
    (define (expand-ellipsis subtempl depth env)
      (let* ((evars (find-ellipsis-vars subtempl env))
             (n     (if (null? evars)
                        0
                        (length (ellipsis-vals (cdr (assq (car evars) env)))))))
        (concat-lists
          (map (lambda (i)
                 (let* ((point-env
                         (map (lambda (v)
                                (cons v (list-ref (ellipsis-vals (cdr (assq v env))) i)))
                              evars))
                        (local-env (append point-env env)))
                   (if (= depth 1)
                       (list (instantiate-template subtempl local-env))
                       (expand-ellipsis subtempl (- depth 1) local-env))))
               (iota n)))))

    ;; (<ellipsis> <template>) — R7RS ellipsis escape: the template is used with
    ;; ellipses having no special meaning.  Pattern variables still substitute.
    ;; Overwhelmingly used as (... ...) to emit a literal ellipsis, in a macro
    ;; that itself expands to a macro definition.
    (define (instantiate-escaped tmpl env)
      (cond
        ((symbol? tmpl)
         (let ((b (assq tmpl env)))
           (if b (cdr b) tmpl)))
        ((pair? tmpl)
         (cons (instantiate-escaped (car tmpl) env)
               (instantiate-escaped (cdr tmpl) env)))
        (else tmpl)))

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
        ;; Ellipsis escape — must precede the ellipsis-template case, since
        ;; (... ...) also looks like "subtemplate followed by ellipsis".
        ((and (eq? (car tmpl) '...) (pair? (cdr tmpl)) (null? (cddr tmpl)))
         (instantiate-escaped (cadr tmpl) env))
        ;; Ellipsis template: (subtempl ... [... ...]) rest
        ((and (pair? (cdr tmpl)) (eq? (cadr tmpl) '...))
         (let* ((subtempl  (car tmpl))
                (depth     (count-ellipses (cdr tmpl)))
                (rest-tmpl (drop-ellipses (cdr tmpl))))
           (append
             (expand-ellipsis subtempl depth env)
             (instantiate-template rest-tmpl env))))
        ;; Regular pair
        (else
         (cons (instantiate-template (car tmpl) env)
               (instantiate-template (cdr tmpl) env)))))

    ;; A transformer whose output is expanded in `env` rather than in whatever
    ;; macro environment is current where the macro is used.  let-syntax needs
    ;; this so a binding cannot see its siblings; letrec-syntax deliberately
    ;; uses the plain transformer, which is what lets its bindings refer to one
    ;; another.
    ;;
    ;; Expanding here means the caller's (paal-expand (macro form)) runs over an
    ;; already-expanded form. That is harmless — core forms simply recurse into
    ;; their sub-forms and no macro uses remain.
    (define (make-scoped-transformer spec env)
      (let ((base (make-transformer spec)))
        (lambda (form)
          (let ((saved %paal-macros))
            (set! %paal-macros env)
            (let ((result (paal-expand (base form))))
              (set! %paal-macros saved)
              result)))))

    ;; ---------------------------------------------------------------
    ;; Hygiene: rename identifiers the template itself binds
    ;; ---------------------------------------------------------------
    ;;
    ;; A template that introduces its own binding — (let ((tmp a)) ...) — would
    ;; otherwise capture a user variable of the same name:
    ;;
    ;;   (define-syntax swap!
    ;;     (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
    ;;   (define x 1) (define tmp 2)
    ;;   (swap! x tmp)        ; the macro's tmp shadowed the user's
    ;;
    ;; Collecting those identifiers and giving each a fresh name per expansion
    ;; fixes it.  Pattern variables are excluded — they carry names from the use
    ;; site and must keep them — as are literals and the ellipsis marker.
    ;;
    ;; Renaming is applied by adding the substitutions to the same environment
    ;; instantiate-template already consults for pattern variables.
    ;;
    ;; This covers capture, which is the half of hygiene that bites in practice.
    ;; It does not give referential transparency: a free identifier in a template
    ;; still resolves at the use site, so a macro calling `helper` picks up a
    ;; local `helper` at the call site rather than the one visible where the
    ;; macro was defined.  That needs the expander to track each identifier's
    ;; definition environment, which this purely structural design has no place
    ;; to put.

    (define (template-bound-ids tmpl pattern-vars literals)
      (let ((acc '()))
        (define (note! s)
          (when (and (symbol? s)
                     (not (eq? s '...))
                     (not (memq s pattern-vars))
                     (not (memq s literals))
                     (not (memq s acc)))
            (set! acc (cons s acc))))
        ;; formals: a symbol, a proper list, or an improper list
        (define (note-formals! f)
          (cond ((symbol? f) (note! f))
                ((pair? f)   (note-formals! (car f)) (note-formals! (cdr f)))
                (else        #f)))
        ;; ((v e) ...) for let/letrec/do, (((a b) e) ...) for let-values
        (define (note-bindings! bs)
          (when (pair? bs)
            (when (pair? (car bs)) (note-formals! (car (car bs))))
            (note-bindings! (cdr bs))))
        (define (walk-list l)
          (when (pair? l) (walk (car l)) (walk-list (cdr l))))
        (define (walk t)
          (when (pair? t)
            (let ((head (car t)))
              (cond
                ((and (eq? head 'lambda) (pair? (cdr t)))
                 (note-formals! (cadr t))
                 (walk-list (cddr t)))
                ((and (eq? head 'let) (pair? (cdr t)) (symbol? (cadr t))
                      (pair? (cddr t)))
                 ;; named let binds the loop name too
                 (note! (cadr t))
                 (note-bindings! (caddr t))
                 (walk-list (cdddr t)))
                ((and (memq head '(let let* letrec letrec* let-values let*-values))
                      (pair? (cdr t)))
                 (note-bindings! (cadr t))
                 (walk-list (cddr t)))
                ((and (eq? head 'do) (pair? (cdr t)))
                 (note-bindings! (cadr t))
                 (walk-list (cddr t)))
                ((and (eq? head 'guard) (pair? (cdr t)) (pair? (cadr t)))
                 (note! (car (cadr t)))
                 (walk-list (cddr t)))
                (else (walk-list t))))))
        (walk tmpl)
        acc))

    ;; (old . fresh) for each identifier the template binds.
    (define (hygiene-renames tmpl pattern-vars literals)
      (map (lambda (s)
             (cons s (fresh-name (string-append "%h-" (symbol->string s) "-"))))
           (template-bound-ids tmpl pattern-vars literals)))

    ;; ---------------------------------------------------------------
    ;; Referential transparency: free identifiers resolve at the macro's
    ;; definition site, not the use site
    ;; ---------------------------------------------------------------
    ;;
    ;;   (define (helper x) (* x 10))
    ;;   (define-syntax use-helper (syntax-rules () ((_ v) (helper v))))
    ;;   (let ((helper (lambda (x) (- x)))) (use-helper 3))
    ;;
    ;; R7RS says 30 — the template's `helper` is the one visible where the macro
    ;; was defined.  Without this it picked up the use site's local and gave -3.
    ;;
    ;; A free template identifier is rewritten to %gref%<name>, which the emitter
    ;; and the tree-walking VM both resolve straight to the top level, skipping
    ;; any binding the use site happens to have introduced.  That is exact when
    ;; the macro was defined at top level, which is where paal's macros live —
    ;; the macro table is global, so a macro has no other definition environment
    ;; to refer to.
    ;;
    ;; Keywords must not be rewritten: `let` in a template is syntax, not a
    ;; variable.  Neither must macro names, or the use would stop expanding —
    ;; paal-expand additionally unmarks a marked head that turns out to name a
    ;; macro, which covers one defined after this one.

    (define %expander-keywords
      '(quote lambda define set! if begin
        let let* letrec letrec* and or when unless cond case do
        quasiquote unquote unquote-splicing else =>
        define-record-type define-library import export
        guard parameterize case-lambda
        define-values let-values let*-values
        delay delay-force include include-ci cond-expand syntax-error
        define-syntax let-syntax letrec-syntax syntax-rules
        ... _))

    (define %gref-prefix "%gref%")

    (define (gref-symbol name)
      (string->symbol (string-append %gref-prefix (symbol->string name))))

    ;; Free identifiers of a template: symbols that are not pattern variables,
    ;; not bound by the template, not literals, not keywords, and not currently
    ;; macros.
    (define (template-free-ids tmpl pattern-vars bound literals)
      (let ((acc '()))
        (define (note! s)
          (when (and (symbol? s)
                     (not (memq s pattern-vars))
                     (not (memq s bound))
                     (not (memq s literals))
                     (not (memq s %expander-keywords))
                     ;; Already marked — a template that came from an enclosing
                     ;; macro's expansion.  Marking twice yields %gref%%gref%x,
                     ;; which strips to a name nothing is bound to.
                     (not (gref-name s))
                     (not (paal-macro-get s))
                     (not (memq s acc)))
            (set! acc (cons s acc))))
        (define (walk t)
          (cond
            ((symbol? t) (note! t))
            ((pair? t)
             (cond
               ;; (quote datum) contributes no references
               ((eq? (car t) 'quote) #f)
               ;; A nested syntax-rules belongs to the macro being *defined*
               ;; here, not to this one: its pattern variables and `_` are not
               ;; free identifiers of this template, and its own free
               ;; identifiers should resolve where that inner macro is defined.
               ((eq? (car t) 'syntax-rules) #f)
               (else (walk (car t)) (walk (cdr t)))))
            (else #f)))
        (walk tmpl)
        acc))

    (define (referential-renames tmpl pattern-vars bound literals)
      (map (lambda (s) (cons s (gref-symbol s)))
           (template-free-ids tmpl pattern-vars bound literals)))

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
                          ;; Fresh renames per expansion, so two uses of the same
                          ;; macro never share an introduced name.  They go into
                          ;; the same env instantiate-template already consults,
                          ;; after the pattern bindings so those take precedence.
                          (let* ((pvars   (map car env))
                                 (bound   (template-bound-ids template pvars literals))
                                 (renames (map (lambda (s)
                                                 (cons s (fresh-name
                                                           (string-append
                                                             "%h-" (symbol->string s) "-"))))
                                               bound))
                                 (frees   (referential-renames
                                            template pvars bound literals)))
                            (instantiate-template
                              template
                              (append env renames frees)))
                          (loop (cdr cls))))))))))

    ;; ---------------------------------------------------------------
    ;; append-map — kept from when apply was capped at 16 arguments and
    ;; (apply append (map f lst)) overflowed it while self-compiling.  apply is
    ;; a VM marker now with no ceiling, so this is only a clarity choice.
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
            ((parameterize)
             (paal-expand (expand-parameterize form)))
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
             ;; R7RS 4.3.1: a keyword's region is the *body* only, so a binding
             ;; does not see its siblings.  Each transformer therefore expands
             ;; its output in the environment from before any of these bindings
             ;; were installed — which is exactly what letrec-syntax below does
             ;; not do, and the only thing that distinguishes the two here.
             (let* ((bindings (cadr form))
                    (body     (cddr form))
                    (saved    %paal-macros))
               (for-each (lambda (b)
                           (paal-macro-set! (car b)
                                            (make-scoped-transformer (cadr b) saved)))
                         bindings)
               (let ((result (paal-expand `(begin ,@body))))
                 (set! %paal-macros saved)
                 result)))
            ((letrec-syntax)
             ;; R7RS 4.3.1: the region covers the bindings as well as the body,
             ;; so the transformers may refer to each other and to themselves.
             ;; Installing them all before expanding anything gives that for
             ;; free, since a use expands against whatever is current.
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
            ;; A define-library evaluated as a program form -- `paal file.sld`,
            ;; or pkaappi-load-file on a pipeline stage.  Its own imports are
            ;; honoured, but its body is spliced unrenamed: there is no importer
            ;; here to hide anything from, and paal's own stages rely on
            ;; loading this way into one shared globals table.
            ((define-library)
             (let* ((decls    (cddr form))
                    (imports  (append-map cdr (decls-of decls 'import)))
                    (prologue (map expand-one-import imports))
                    (bodies   (append-map cdr (decls-of decls 'begin))))
               (paal-expand
                 (cons 'begin (append (drain-pending!) prologue bodies)))))
            ((import)
             (expand-import form))
            ;; A top-level `export` outside a define-library has nothing to
            ;; act on; inside one, install-library! reads it directly.
            ((export)
             '(quote #f))
            ;; --- User-defined macro or procedure call ---
            (else
             (let ((macro (paal-macro-get (car form))))
               (cond
                 ((and (symbol? (car form)) macro)
                  (paal-expand (macro form)))
                 ;; A template's free identifier was marked %gref% before we knew
                 ;; whether it named a macro — it may name one defined after the
                 ;; macro that referenced it.  Unmark and expand as a macro use.
                 ((and (symbol? (car form))
                       (gref-name (car form))
                       (paal-macro-get (gref-name (car form))))
                  (paal-expand (cons (gref-name (car form)) (cdr form))))
                 (else (map paal-expand form))))))))

    ;; Strip the %gref% marker, or #f when the symbol does not carry one.
    ;; Shared with the emitter and the tree-walking VM, which resolve a marked
    ;; identifier straight to the top level.
    (define (gref-name sym)
      (let ((s (symbol->string sym)))
        (and (> (string-length s) 6)
             (string=? (substring s 0 6) "%gref%")
             (string->symbol (substring s 6 (string-length s))))))

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
    ;;                       (lambda (var) (cond clause ... (else %paal-guard-no-match))))
    ;;
    ;; %paal-guard-run runs the body thunk under a HOST guard and, on an
    ;; exception, applies the handler to the condition.  Each pipeline provides
    ;; it differently: the tree-walking VM binds a plain HOST procedure, since
    ;; its closures are themselves HOST procedures, while the bytecode VM binds
    ;; a marker that do-call! recognizes and acts on (see vm-bc.sld).
    ;;
    ;; A clause list with no else gets an implicit (else %paal-guard-no-match)
    ;; rather than an outright re-raise.  R7RS re-raises an unmatched condition
    ;; in the dynamic environment of the original raise, not the guard's, so the
    ;; re-raise has to be surrounded by the wind dance that gets back there —
    ;; and that belongs to the machinery, which knows both states.  Returning a
    ;; sentinel is how the handler says "nothing matched, it is yours".

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
                              (append clauses '((else %paal-guard-no-match))))))
        `(%paal-guard-run
           (lambda () ,@body)
           (lambda (,var) (cond ,@all-clauses)))))

    ;; ---------------------------------------------------------------
    ;; parameterize
    ;; ---------------------------------------------------------------
    ;;
    ;; (parameterize ((p v) ...) body ...)
    ;;   => (%paal-parameterize (list p ...) (list v ...) (lambda () body ...))
    ;;
    ;; Both parameter and value expressions are evaluated before any binding is
    ;; installed, which R7RS requires.  Wrapping them in `list` gets that for
    ;; free, since arguments are evaluated before the call.
    ;;
    ;; %paal-parameterize installs the new values, runs the thunk, and restores
    ;; the old ones — on normal return and on a raise alike.  Both pipelines
    ;; bind it; see the note in lib/kaappi/paal.sld.

    (define (expand-parameterize form)
      (let ((bindings (cadr form))
            (body     (cddr form)))
        `(%paal-parameterize
           (list ,@(map car bindings))
           (list ,@(map cadr bindings))
           (lambda () ,@body))))

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
