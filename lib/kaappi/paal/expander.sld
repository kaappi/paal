;;; (kaappi paal expander) — Derived-form desugarer
;;;
;;; Pipeline stage 2.
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
  (import (scheme base) (scheme file) (scheme read)
          (kaappi paal embedded))
  (export paal-expand paal-expand-all paal-expand-all-for-file
          paal-macros-reset! gref-name
          paal-lib-path-add! paal-lib-paths-list paal-libraries-reset!
          paal-feature-list paal-import-grant-predicate)
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

    ;; The syntax-rules spec is kept beside the transformer.  A transformer
    ;; alone is a closure over its rules, and a library that renames its
    ;; top-level bindings has to rewrite the templates that name them —
    ;; which needs the rules as data.  See rename-macro-templates! below.
    (define %paal-macro-specs '())

    (define (paal-macro-set! name transformer . spec)
      (set! %paal-macros (cons (cons name transformer) %paal-macros))
      (unless (null? spec)
        (set! %paal-macro-specs (cons (cons name (car spec)) %paal-macro-specs))))

    (define (paal-macro-spec name)
      (let ((hit (assq name %paal-macro-specs)))
        (and hit (cdr hit))))

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
      (set! %paal-macro-specs '())
      ;; A load-library! that errored out leaves its include-context frame up
      ;; (same exposure %paal-loading has); a fresh program must not resolve
      ;; its includes against the dead library's directory.
      (set! %paal-include-dirs '())
      (paal-libraries-reset!))

    ;; ---------------------------------------------------------------
    ;; Feature list for cond-expand
    ;; ---------------------------------------------------------------

    ;; `kaappi` is here because paal targets the same language: a library
    ;; guarded by (cond-expand (kaappi ...)) is written against primitives paal
    ;; also provides, and excluding ourselves would send such code down a
    ;; portable-fallback path for no reason.
    ;; Only what actually holds.  exact-closed, exact-complex, ieee-float and
    ;; posix are inherited from kaappi's runtime, which advertises exactly
    ;; those; full-unicode and ratios are NOT in kaappi's list, so paal does not
    ;; claim them either.  `scheme` is a paal extension rather than an R7RS
    ;; feature identifier, kept because paal's own cond-expands use it.
    (define %paal-features
      '(paal kaappi r7rs exact-closed exact-complex ieee-float posix scheme))

    ;; The same list `features` answers with.  It used to answer with the
    ;; *host's*, which does not contain `paal`, so a program asking what it was
    ;; running on and a cond-expand asking the same question disagreed.
    (define (paal-feature-list) %paal-features)

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

    ;; "lib" is on the default path because paal's bundled SRFIs live in
    ;; lib/srfi/.  It resolves when paal runs from its own tree; an installed
    ;; binary will need the directory passed with --lib-path until Phase 6
    ;; bundles them in.
    (define %paal-lib-paths '("." "lib"))
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

    ;; R7RS 4.1.7 leaves include resolution implementation-defined; kaappi
    ;; resolves a relative path against the directory of the *including file*,
    ;; and real libraries rely on it — (srfi 135) includes "135-impl.scm"
    ;; beside its .sld, (srfi 171 meta) includes "../171-meta-impl.scm".
    ;; Resolving against the process CWD instead made both unloadable from
    ;; anywhere but one directory.
    ;;
    ;; The stack holds one context per file being processed: the .sld's
    ;; directory while a library installs, the program file's while a program
    ;; expands, #f for embedded sources, which have no directory and must not
    ;; inherit an unrelated one.  Empty stack or #f on top means paths pass
    ;; through untouched — the old behavior, which is also the right one for
    ;; a bare filename run from its own directory.
    ;;
    ;; An include *inside an included file* resolves against the outer file's
    ;; directory, not its own — the included forms are expanded after this
    ;; frame is the context, and the sibling-file layout every real library
    ;; uses makes the two the same directory.  Recorded rather than solved:
    ;; solving it needs a context marker every form walker understands.
    (define %paal-include-dirs '())

    (define (include-dir-push! d)
      (set! %paal-include-dirs (cons d %paal-include-dirs)))
    (define (include-dir-pop!)
      (set! %paal-include-dirs (cdr %paal-include-dirs)))

    ;; #f for a path with no directory part.
    (define (paal-dirname path)
      (let loop ((i (- (string-length path) 1)))
        (cond ((< i 0) #f)
              ((char=? (string-ref path i) #\/) (substring path 0 i))
              (else (loop (- i 1))))))

    (define (resolve-include-path p)
      (let ((top (and (pair? %paal-include-dirs) (car %paal-include-dirs))))
        (if (or (not top)
                (= (string-length p) 0)
                (char=? (string-ref p 0) #\/))
            p
            (string-append top "/" p))))

    (define (paal-libraries-reset!)
      (set! %paal-libraries '())
      (set! %paal-loading '())
      (set! %paal-pending '())
      (set! %paal-emitted '()))

    ;; Libraries that resolve to nothing because their bindings are already in
    ;; the globals table:
    ;;
    ;;   (scheme ...)      — paal-initial-env provides them.
    ;;   (kaappi paal ...) — paal's own pipeline stages.  pkaappi-load-file
    ;;                       loads every one into a single shared table by
    ;;                       design, so importing one must not pull a second,
    ;;                       renamed copy in beside it.  They do have files
    ;;                       under lib/, which is on the default search path
    ;;                       for the bundled SRFIs, so this cannot be left to
    ;;                       the not-found fallback.
    ;; A library whose names are already in the globals table, so importing
    ;; it emits identity aliases rather than loading a file: every (scheme …)
    ;; library, paal's own stages, and each library the exports table below
    ;; names — (kaappi ffi), (srfi 27) and the rest of the host-native set,
    ;; which have no .sld anywhere because their procedures are Zig.  A
    ;; table entry therefore shadows any same-named file, so numbers used
    ;; here must stay off the portable-SRFI shelf.
    (define (builtin-library? name)
      (and (pair? name)
           (or (eq? (car name) 'scheme)
               (and (eq? (car name) 'kaappi)
                    (pair? (cdr name))
                    (eq? (cadr name) 'paal))
               (and (scheme-lib-exports name) #t))))

    ;; --- what each (scheme …) library exports -----------------------------
    ;;
    ;; `(import (scheme base))` used to hand a program `sin`, `ffi-open` and
    ;; `spawn` as well, because every `(scheme …)` name resolved to an empty
    ;; export list against one flat globals table.  A program could import too
    ;; little and still run — and then fail on a conforming implementation.
    ;;
    ;; The table below names the *small* libraries exhaustively and lets
    ;; `(scheme base)` be everything else.  That inversion is deliberate: base
    ;; has some 200 names and enumerating it by hand would put a typo between a
    ;; correct program and compiling, whereas a name missing from a small
    ;; library is at worst over-permissive.  A name listed here is exported by
    ;; that library and by no other, so `(scheme base)` does not cover it.
    ;;
    ;; Values only, not syntax.  `let`, `guard`, `define-record-type` and the
    ;; rest are dispatched by keyword in paal-expand regardless of what was
    ;; imported, so `(import (scheme base))` does not gate them.  Restricting
    ;; syntax is a separate axis and is not attempted here.
    (define %paal-scheme-lib-exports
      '(((scheme inexact) acos asin atan cos exp finite? infinite? log nan?
                          sin sqrt tan)
        ((scheme complex) angle imag-part magnitude make-polar make-rectangular
                          real-part)
        ;; The 24 compositions of depth three and four.  Depth two — caar,
        ;; cadr, cdar, cddr — is `(scheme base)` and stays out of this list;
        ;; R7RS 6.4 counts twenty-eight in all, and the split is 4 + 24.
        ((scheme cxr)     caaar caadr cadar caddr cdaar cdadr cddar cdddr
                          caaaar caaadr caadar caaddr cadaar cadadr caddar
                          cadddr cdaaar cdaadr cdadar cdaddr cddaar cddadr
                          cdddar cddddr)
        ((scheme char)    char-alphabetic? char-ci<=? char-ci<? char-ci=?
                          char-ci>=? char-ci>? char-downcase char-foldcase
                          char-lower-case? char-numeric? char-upcase
                          char-upper-case? char-whitespace? digit-value
                          string-ci<=? string-ci<? string-ci=? string-ci>=?
                          string-ci>? string-downcase string-foldcase
                          string-upcase)
        ((scheme file)    call-with-input-file call-with-output-file delete-file
                          file-exists? open-binary-input-file
                          open-binary-output-file open-input-file
                          open-output-file with-input-from-file
                          with-output-to-file)
        ((scheme lazy)    force make-promise promise?)
        ((scheme load)    load)
        ((scheme process-context) command-line emergency-exit exit
                          get-environment-variable get-environment-variables)
        ((scheme read)    read)
        ((scheme repl)    interaction-environment)
        ((scheme time)    current-jiffy current-second jiffies-per-second)
        ((scheme write)   display write write-shared write-simple)
        ((scheme eval)    environment eval)
        ((scheme r5rs)    exact->inexact inexact->exact)
        ((kaappi ffi)     ffi-open ffi-fn ffi-close ffi-callback
                          ffi-callback-release ffi-callback? ffi-bytevector-ptr)
        ((kaappi diagnostics) error-object-code)
        ;; Host-native SRFIs: the procedures are Zig primitives bound in
        ;; paal-initial-env, so the libraries resolve as builtins — there is
        ;; no .sld to load, on disk or embedded.
        ((srfi 27)        default-random-source make-random-source
                          random-integer random-real
                          random-source-pseudo-randomize!
                          random-source-randomize!
                          random-source-state-ref random-source-state-set!
                          random-source?)
        ((srfi 258)       generate-uninterned-symbol string->uninterned-symbol
                          symbol-interned?)
        ((srfi 260)       generate-symbol)
        ((kaappi fibers)  spawn yield fiber-join fiber? make-channel
                          channel-send channel-receive channel? channel-close!
                          channel-closed? channel-timeout-exception?
                          processor-count)))

    ;; Every name any small library claims — the complement of `(scheme base)`.
    (define (scheme-lib-claimed-names)
      (append-map cdr %paal-scheme-lib-exports))

    (define (scheme-lib-exports name)
      (let ((hit (assoc name %paal-scheme-lib-exports)))
        (and hit (cdr hit))))

    ;; A library name component may be a number — (srfi 1), (srfi 133) — so
    ;; symbol->string alone is not enough.
    (define (name-part->string p)
      (cond ((symbol? p) (symbol->string p))
            ((number? p) (number->string p))
            (else (error "paal: bad library name component" p))))

    (define (library-name->path name)
      (let loop ((parts name) (acc ""))
        (if (null? parts)
            (string-append acc ".sld")
            (loop (cdr parts)
                  (if (string=? acc "")
                      (name-part->string (car parts))
                      (string-append acc "/" (name-part->string (car parts))))))))

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
                  (string-append acc (name-part->string (car parts)) "%")))))

    ;; open-input-file rather than call-with-input-file: the latter is a HOST
    ;; procedure, and under self-hosting the thunk handed to it is a paal
    ;; closure, which HOST code cannot enter — it failed with "not a
    ;; procedure".  The same trap applies anywhere a paal lambda is passed to
    ;; a host higher-order procedure.
    ;;
    ;; Slurped and parsed from a string port rather than read straight off the
    ;; file port, for the reason `paal-read-bc-file` does the same in
    ;; serializer.sld: kaappi's `read` parses a file port in 4096-byte chunks
    ;; and loses lexer state at every boundary (kaappi/kaappi#1920,
    ;; kaappi/kaappi#2043).  A `.sld` is a single ~4 KB-and-up datum full of
    ;; comments, so this is not a corner: a library whose comment happens to
    ;; straddle byte 4096 failed to load at all, with `read error` and nothing
    ;; naming the file, and one whose comment straddles it a certain way loads
    ;; with extra symbols spliced into the library body instead.  A string port
    ;; hands the reader the whole text at once, so there is no boundary.
    (define (read-forms-from path)
      (paal-read-forms-from-string (read-file-as-string path)))

    ;; The include-ci variant: see the comment above expand-include.
    (define (read-forms-from-ci path)
      (paal-read-forms-from-string
        (string-append "#!fold-case\n" (read-file-as-string path))))

    ;; string-append per chunk rather than collecting and applying: this file
    ;; is compiled by paal for the self-hosted path, and paal's own `apply`
    ;; would be handed one argument per chunk.
    (define (read-file-as-string path)
      (let ((port (open-input-file path)))
        (let loop ((acc ""))
          (let ((chunk (read-string 4096 port)))
            (if (eof-object? chunk)
                (begin (close-input-port port) acc)
                (loop (string-append acc chunk)))))))

    ;; --- import specs ---------------------------------------------------
    ;;
    ;; Each returns an alias list: (visible-name . internal-name).  The
    ;; modifiers wrap a nested spec, so (prefix (only (m) a b) x:) works.

    (define (resolve-import spec)
      (cond
        ((not (pair? spec)) (error "paal: malformed import spec" spec))
        ;; Over a library that grants everything — `(scheme base)` has no
        ;; enumerable export list — the names are taken on faith as identity
        ;; aliases: they cannot be *validated*, but they can be granted
        ;; exactly, which is what makes `only` over base narrow.  A name base
        ;; does not actually have then surfaces at run time as an unbound
        ;; global rather than at the check.  Outer modifiers compose over the
        ;; manufactured aliases like over any others, so
        ;; (prefix (only (scheme base) car) b:) defines and grants b:car.
        ((eq? (car spec) 'only)
         (if (grants-everything? (cadr spec))
             (map (lambda (n) (cons n n)) (cddr spec))
             (let ((base (resolve-import (cadr spec))) (names (cddr spec)))
               (for-each (lambda (n)
                           (unless (assq n base)
                             (error "paal: `only` names a binding the library does not export" n)))
                         names)
               (filter (lambda (p) (memq (car p) names)) base))))
        ((eq? (car spec) 'except)
         (let ((base (resolve-import (cadr spec))) (names (cddr spec)))
           (unless (grants-everything? (cadr spec))
             (for-each (lambda (n)
                         (unless (assq n base)
                           (error "paal: `except` names a binding the library does not export" n)))
                       names))
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
           (if (and (null? base) (grants-everything? (cadr spec)))
               ;; Over base itself nothing is enumerable, so the pairs ARE
               ;; the alias list: (rename (scheme base) (car %car)) imports
               ;; base's car as %car, and every unnamed base name stays
               ;; ambient under its own spelling.  Taken on faith like
               ;; `only` over base — an old name base does not actually
               ;; have surfaces at run time as an unbound global.  SRFI 101
               ;; is this shape.
               (map (lambda (p) (cons (cadr p) (car p))) pairs)
               (map (lambda (p)
                      (let ((hit (assq (car p) pairs)))
                        (if hit (cons (cadr hit) (cdr p)) p)))
                    base))))
        (else (library-exports spec))))

    ;; --- loading --------------------------------------------------------

    (define (library-exports name)
      (cond
        ;; A builtin's names are already in the globals table, so its aliases
        ;; are identities — `(sin . sin)`.  They exist so `only`/`except` can
        ;; validate against a real export list and `prefix`/`rename` can
        ;; transform one; `expand-one-import` drops identities rather than
        ;; emitting `(define sin sin)` for every name in the library.
        ((builtin-library? name)
         (let ((exports (scheme-lib-exports name)))
           (if exports (map (lambda (n) (cons n n)) exports) '())))
        ((assoc name %paal-libraries) => cdr)
        ((member name %paal-loading)
         (error "paal: circular import" (reverse (cons name %paal-loading))))
        (else (load-library! name))))

    ;; A name with no file anywhere on the path is an error.  This was a
    ;; silent no-op while paal's own stages relied on it -- each imports
    ;; (kaappi paal ir), which is never on the search path -- but those names
    ;; are recognised by builtin-library? now, so nothing legitimate reaches
    ;; here.  The error names the searched path, since "not found" is almost
    ;; always a --lib-path that was not passed.
    ;; A bundled library is consulted before the search path, so a file on
    ;; disk cannot shadow one — that would make a binary's behaviour depend on
    ;; its working directory, which is what bundling exists to avoid.
    (define (load-library! name)
      (let ((embedded (paal-embedded-source name)))
        (if embedded
            (begin
              (set! %paal-loading (cons name %paal-loading))
              (let ((result (install-library-source! name embedded)))
                (set! %paal-loading (cdr %paal-loading))
                result))
            (load-library-from-path! name))))

    (define (install-library-source! name text)
      (let ((form (let loop ((fs (paal-read-forms-from-string text)))
                    (cond
                      ((null? fs)
                       (error "paal: no define-library in bundled source" name))
                      ((and (pair? (car fs)) (eq? (caar fs) 'define-library))
                       (car fs))
                      (else (loop (cdr fs)))))))
        ;; #f, not nothing: an embedded library has no directory, and letting
        ;; it inherit whatever file happens to be enclosing the import would
        ;; make its includes resolve differently per call site.
        (include-dir-push! #f)
        (let ((result (install-library! name (cddr form))))
          (include-dir-pop!)
          result)))

    (define (paal-read-forms-from-string text)
      (let ((port (open-input-string text)))
        (let loop ((form (read port)) (acc '()))
          (if (eof-object? form)
              (reverse acc)
              (loop (read port) (cons form acc))))))

    (define (load-library-from-path! name)
      (let ((path (find-library-file name)))
        (if (not path)
            (error "paal: library not found"
                   (list name (library-name->path name) %paal-lib-paths))
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
        ;; The whole install runs under the .sld's directory, so its includes
        ;; — declaration and body alike — resolve beside the file that names
        ;; them.  No unwind protection, same as %paal-loading above: an error
        ;; aborts the expansion, and the next fresh program resets the stack.
        (include-dir-push! (paal-dirname path))
        (let ((result (install-library! name (cddr form))))
          (include-dir-pop!)
          result)))

    (define (decls-of decls tag)
      (filter (lambda (d) (and (pair? d) (eq? (car d) tag))) decls))

    ;; R7RS 5.6.1 lets two declarations produce further declarations:
    ;; cond-expand chooses among declaration lists, and
    ;; include-library-declarations splices a file of them.  Both are
    ;; rewritten away up front — recursively, since each may yield more of
    ;; either — so everything downstream reads one flat vocabulary:
    ;; export / import / begin / include / include-ci.
    ;; The included files are read like `include` reads its own, with no
    ;; case folding; a library wanting folded declarations can put a
    ;; #!fold-case directive at the top of the file.
    (define (normalize-decls decls)
      (append-map
        (lambda (d)
          (cond
            ((not (pair? d)) (list d))
            ((eq? (car d) 'cond-expand)
             (normalize-decls (cond-expand-select (cdr d))))
            ((eq? (car d) 'include-library-declarations)
             (normalize-decls
               (apply append
                      (map (lambda (p) (read-forms-from (resolve-include-path p)))
                           (cdr d)))))
            (else (list d))))
        decls))

    ;; The library's body, gathered in declaration order.  R7RS 5.6.1 makes
    ;; begin, include and include-ci equal citizens; collecting the begins
    ;; and the includes in separate passes reordered them, so an included
    ;; file could not use a name a later begin defines — or vice versa.
    (define (body-forms-of decls)
      (append-map
        (lambda (d)
          (cond
            ((not (pair? d)) '())
            ((eq? (car d) 'begin)      (cdr d))
            ((eq? (car d) 'include)    (cdr (expand-include (cdr d) #f)))
            ((eq? (car d) 'include-ci) (cdr (expand-include (cdr d) #t)))
            (else '())))
        decls))

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

    (define (install-library! name decls0)
      (let* ((decls    (normalize-decls decls0))
             (%scope    (import-scope-save))
             (imports  (append-map cdr (decls-of decls 'import)))
             ;; The library's own imports first: they may define macros its
             ;; body uses, and expansion is where a macro takes effect.
             (prologue (map expand-one-import imports))
             (bodies   (body-forms-of decls))
             (exports  (export-alist decls))
             (macros-before %paal-macros)
             ;; Expand to core forms.  Renaming afterwards only has to know
             ;; about `lambda`, since every other binder is gone by then.
             ;; expand-nested, not paal-expand-all: this runs *inside* the
             ;; expansion of the program that imported this library, and
             ;; paal-expand-all resets the import-scope state — so an
             ;; `(import (scheme base) (srfi 1))` lost its own base grant the
             ;; moment (srfi 1)'s body was expanded, and `+` became unbound.
             (core     (expand-nested bodies))
             (%restored (import-scope-restore! %scope))
             ;; The prologue is renamed along with the body.  It used to be
             ;; spliced in untouched, so a library's *imports* landed in its
             ;; importer under their own names: `(import (m greet))` handed you
             ;; `cube`, which `(m greet)` does not export, because `(m greet)`
             ;; imports `(m math)`. Imports were effectively transitive.
             ;;
             ;; Flattened first — expand-one-import returns a `begin` per spec,
             ;; and top-level-defined does not see through one.
             (flat-pro (append-map (lambda (p)
                                     (if (and (pair? p) (eq? (car p) 'begin))
                                         (cdr p)
                                         (list p)))
                                   prologue))
             (all-core (append flat-pro core))
             (defined  (top-level-defined all-core))
             (tag      (library-name->tag name))
             (renames  (map (lambda (n)
                              (cons n (string->symbol
                                        (string-append tag (symbol->string n)))))
                            defined))
             ;; Prologue and body take different renamings.  A prologue form
             ;; is an alias define `(define local imported)` whose RHS was
             ;; resolved at import time — base's own name, or another
             ;; library's already-mangled global.  A body may legally define
             ;; the very name an alias's RHS spells, when the import
             ;; excepted it: SRFI 70 excepts base's `quotient`, re-imports it
             ;; as `%quotient`, and defines its own `quotient`.  Renaming the
             ;; alias's RHS with the body's map repointed the import at the
             ;; shadow — and evaluated it before the shadow's define ran, so
             ;; the library died with an unbound mangled global.  Only the
             ;; alias's *own* name is this library's to rename.
             (renamed  (append
                         (map (lambda (f) (rename-alias-define f renames))
                              flat-pro)
                         (map (lambda (f) (rename-core f renames)) core))))
        ;; Rewrite this library's macro templates so they name the renamed
        ;; bindings, and mangle the macros it did not export so they stop
        ;; being visible to the importer.  Both directions of the same
        ;; problem: a template names things by their original name, so
        ;; renaming anything means rewriting the templates that reach it.
        (let* ((own-entries (take-until %paal-macros macros-before))
               (own-macros (map car own-entries))
               (macro-renames
                (filter-map
                  (lambda (m)
                    (and (not (assq m exports))
                         (cons m (string->symbol
                                   (string-append tag (symbol->string m))))))
                  own-macros))
               (all-renames (append renames macro-renames)))
          ;; Paired with their specs, since the table entries are about to be
          ;; dropped and looked up again under new names.
          (rename-macro-templates!
            (map (lambda (n) (cons n (paal-macro-spec n))) own-macros)
            all-renames))
        ;; Exported macros stay installed under their own names, private ones
        ;; under the mangled names — an exported template may call a private
        ;; macro, so the private entries must remain resolvable, just not
        ;; under any name an importer could utter.  See docs/TODO.md ("A
        ;; macro template can name a library's private binding").
        (let ((export-map
               (map (lambda (e)
                      (let ((hit (assq (cdr e) renames)))
                        (cons (car e) (if hit (cdr hit) (cdr e)))))
                    exports)))
          (set! %paal-libraries (cons (cons name export-map) %paal-libraries))
          (set! %paal-pending
                (append %paal-pending (list (cons name renamed))))
          export-map)))

    ;; The prologue-only renamer: the defined name through the map, the RHS
    ;; untouched (see the renamed binding in install-library!).  Anything
    ;; that is not a plain alias define falls back to rename-core — today
    ;; expand-one-import emits nothing else, and the fallback keeps a future
    ;; emission from silently skipping renaming.
    (define (rename-alias-define f renames)
      (if (and (pair? f) (eq? (car f) 'define)
               (pair? (cdr f)) (symbol? (cadr f))
               (pair? (cddr f)) (null? (cdddr f)))
          (let ((hit (assq (cadr f) renames)))
            (list 'define (if hit (cdr hit) (cadr f)) (caddr f)))
          (rename-core f renames)))

    ;; Rewrite this library's macro templates so they name the renamed
    ;; bindings.  Without it an exported macro whose template calls a private
    ;; helper breaks at the use site: the helper is renamed and the template
    ;; still names the original.  SRFI 64's assertions are exactly this shape.
    ;;
    ;; A template's pattern variables, the clause's literals, and the ellipsis
    ;; are left alone -- those names come from the use site, not from here.
    (define (rename-template tmpl renames pvars literals ell)
      (cond
        ((symbol? tmpl)
         (if (or (eq? tmpl '...) (eq? tmpl ell)
                 (memq tmpl pvars) (memq tmpl literals))
             tmpl
             (let ((hit (assq tmpl renames)))
               (cond
                 (hit (cdr hit))
                 ;; A spec that came through resolve-transformer-spec was
                 ;; instantiated once already, so its free identifiers
                 ;; carry %gref% marks — follow the mark through the
                 ;; rename, the way rename-core does.  SRFI 148 defines
                 ;; its later macros via em-syntax-rules, so their stored
                 ;; specs are exactly this shape.
                 ((gref-name tmpl)
                  => (lambda (bare)
                       (let ((h2 (assq bare renames)))
                         (if h2 (gref-symbol (cdr h2)) tmpl))))
                 (else tmpl)))))
        ((pair? tmpl)
         (cons (rename-template (car tmpl) renames pvars literals ell)
               (rename-template (cdr tmpl) renames pvars literals ell)))
        ((vector? tmpl)
         (list->vector
           (map (lambda (x) (rename-template x renames pvars literals ell))
                (vector->list tmpl))))
        (else tmpl)))

    (define (rename-syntax-rules spec renames)
      (let* ((ell      (spec-ellipsis spec))
             (literals (spec-literals spec))
             (clauses  (spec-clauses spec))
             ;; Preserve the spec's shape: a custom ellipsis identifier stays
             ;; in second position.
             (head     (if (symbol? (cadr spec))
                           (list 'syntax-rules ell literals)
                           (list 'syntax-rules literals))))
        (append head
                (map (lambda (clause)
                       ;; Operands only, the way the matcher strips the
                       ;; keyword: the head is the macro's own name, and
                       ;; counting it as a pattern variable exempted a
                       ;; self-recursive template's self-call from the
                       ;; rename — SRFI 148's aux transformers are exactly
                       ;; that shape.
                       (let ((pvars (pattern-vars (if (pair? (car clause))
                                                      (cdr (car clause))
                                                      (car clause))
                                                  literals ell)))
                         (list (car clause)
                               (rename-template (cadr clause) renames
                                                pvars literals ell))))
                     clauses))))

    ;; Rebuild every macro `names` covers from its stored spec, with `renames`
    ;; applied.  A macro whose own name is in `renames` is reinstalled under
    ;; the new name, which is what actually hides an unexported one.
    (define (rename-macro-templates! names renames)
      ;; Drop the old entries first.  paal-macro-set! conses, so reinstalling
      ;; without this would leave the unexported name resolvable and the
      ;; mangling would hide nothing.
      (let ((old (map car names)))
        (set! %paal-macros
              (filter (lambda (m) (not (memq (car m) old))) %paal-macros))
        (set! %paal-macro-specs
              (filter (lambda (m) (not (memq (car m) old))) %paal-macro-specs)))
      (for-each
        (lambda (entry)
          (let ((name (car entry)) (spec (cdr entry)))
            (when spec
              (let* ((spec* (rename-syntax-rules spec renames))
                     (hit   (assq name renames))
                     (final (if hit (cdr hit) name)))
                ;; Library macros are top-level: the empty definition env.
                (paal-macro-set! final (make-transformer spec* '()) spec*)))))
        names))

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
         (let ((hit (assq form renames)))
           (cond
             (hit (cdr hit))
             ;; A %gref%-marked reference — a macro template's free
             ;; identifier, instantiated into this body by a use of the
             ;; macro inside its own library.  The mark said "resolve at
             ;; top level"; the name it carries is being renamed, so the
             ;; mark must follow the rename or the reference resolves to
             ;; a global that no longer exists.  SRFI 35 is the shape:
             ;; define-condition-type's template names
             ;; make-condition-type, and the library itself uses the
             ;; macro.
             ((gref-name form)
              => (lambda (bare)
                   (let ((h2 (assq bare renames)))
                     (if h2 (gref-symbol (cdr h2)) form))))
             (else form))))
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
        ;; Record what this spec grants before emitting anything, so the
        ;; post-expansion scope check knows what the program is entitled to.
        ;; A builtin library grants its export list; a user library grants the
        ;; visible half of its alias list, which is what `only`/`prefix`/
        ;; `rename` have already transformed.
        (import-scope-note! spec (map car aliases))
        (import-scope-note-aliases!
          (map car (filter (lambda (p) (not (eq? (car p) (cdr p)))) aliases)))
        (cons 'begin
              (filter-map
                (lambda (p)
                  (let ((transformer (paal-macro-get (cdr p))))
                    (cond
                      (transformer
                       (unless (eq? (car p) (cdr p))
                         (paal-macro-set! (car p) transformer))
                       #f)
                      ;; An identity alias is a builtin's own name, already in
                      ;; the globals table -- `(define sin sin)` would be a
                      ;; self-reference emitted once per name in the library.
                      ((eq? (car p) (cdr p)) #f)
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
      (let* ((aliases (map expand-one-import (cdr form)))
             (bodies  (drain-pending!)))
        (import-scope-note-library! bodies)
        ;; Library bodies must precede the aliases that name into them, and
        ;; both must precede the importing program.
        (cons 'begin (append bodies aliases))))

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

    ;; A syntax-rules spec is (syntax-rules (lit ...) clause ...) or, with a
    ;; custom ellipsis identifier, (syntax-rules ell (lit ...) clause ...).
    ;; The three readers below accept both shapes; everything downstream asks
    ;; them rather than assuming cadr is the literals list.
    (define (spec-ellipsis spec)
      (if (symbol? (cadr spec)) (cadr spec) '...))
    (define (spec-literals spec)
      (if (symbol? (cadr spec)) (caddr spec) (cadr spec)))
    (define (spec-clauses spec)
      (if (symbol? (cadr spec)) (cdddr spec) (cddr spec)))

    ;; Is x the ellipsis, *acting* as one?  R7RS 4.3.2 gives the literals list
    ;; priority: an identifier that is both the ellipsis and a literal is a
    ;; literal everywhere — which is how (syntax-rules ... (...) ...) writes
    ;; rules about a literal `...` with no working ellipsis at all.
    (define (ellipsis-mark? x ell lits)
      (and (eq? x ell) (not (memq x lits))))

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

    ;; Collect all pattern variables from a pattern.  The literals check comes
    ;; first: a literal is a literal even when spelled _ or like the ellipsis.
    (define (pattern-vars pat lits ell)
      (cond
        ((and (symbol? pat) (memq pat lits)) '())
        ((eq? pat '_)   '())
        ((ellipsis-mark? pat ell lits) '())
        ((symbol? pat)  (list pat))
        ((vector? pat)  (pattern-vars (vector->list pat) lits ell))
        ((not (pair? pat)) '())
        ((and (pair? (cdr pat)) (ellipsis-mark? (cadr pat) ell lits))
         (append (pattern-vars (car pat) lits ell)
                 (pattern-vars (cddr pat) lits ell)))
        (else
         (append (pattern-vars (car pat) lits ell)
                 (pattern-vars (cdr pat) lits ell)))))

    ;; Count how many non-ellipsis elements rest-pat requires
    (define (count-required rest-pat ell lits)
      (cond
        ((null? rest-pat) 0)
        ((and (pair? rest-pat)
              (pair? (cdr rest-pat))
              (ellipsis-mark? (cadr rest-pat) ell lits))
         (count-required (cddr rest-pat) ell lits))
        ((pair? rest-pat)
         (+ 1 (count-required (cdr rest-pat) ell lits)))
        (else 0)))

    ;; Two denotations are the same when both are the top level (no lexical
    ;; entry) or literally the same environment entry.
    (define (denotation-eq? a b)
      (if (and (not a) (not b)) #t (eq? a b)))

    ;; Match pattern against form.
    ;; Returns an alist of (var . value) on success, #f on failure.
    ;; Ellipsis-bound vars have value (make-ellipsis list-of-values).
    ;;
    ;; use-env is the lexical environment at the macro use, def-env the one
    ;; where the macro was defined; the literal branch compares denotations
    ;; across the two.
    (define (match-syntax pat frm lits ell use-env def-env)
      (cond
        ;; Literal: matches when the use-site occurrence denotes the same
        ;; binding the literal denotes at the definition site (R7RS 4.3.2's
        ;; rule, under paal's denotation approximation: unbound-lexically on
        ;; both sides — the top level — is one denotation, and anything else
        ;; must be the same environment entry).  A use site that rebinds the
        ;; name therefore un-matches the literal, the else-shadowing rule
        ;; generalized to every literal.  Checked before _ and before the
        ;; variable case — the literals list wins, so a pattern may treat _
        ;; or the ellipsis itself as a literal.  A %gref% mark on the form
        ;; means top level by construction; a %core% mark names the keyword,
        ;; which matches the literal of the same spelling.
        ((and (symbol? pat) (memq pat lits))
         (cond
           ((not (symbol? frm)) #f)
           ((gref-name frm)
            => (lambda (g)
                 (if (and (eq? g pat)
                          (denotation-eq? #f (cenv-lookup def-env pat)))
                     '() #f)))
           ((core-name frm)
            => (lambda (c) (if (eq? c pat) '() #f)))
           ((eq? frm pat)
            (if (denotation-eq? (cenv-lookup use-env frm)
                                (cenv-lookup def-env pat))
                '() #f))
           (else #f)))
        ;; Underscore: match anything, no binding
        ((eq? pat '_) '())
        ;; Pattern variable: bind to form
        ((symbol? pat)
         (list (cons pat frm)))
        ;; Null: matches null
        ((null? pat)
         (if (null? frm) '() #f))
        ;; Vector pattern: elementwise, ellipses included, via the list walk
        ((vector? pat)
         (and (vector? frm)
              (match-syntax (vector->list pat) (vector->list frm) lits ell use-env def-env)))
        ;; Non-pair datum: must be equal
        ((not (pair? pat))
         (if (equal? pat frm) '() #f))
        ;; Ellipsis: (subpat <ell> rest-pat ... [. tail-pat])
        ;;
        ;; The form may be improper — R7RS allows (P1 ... Pe <ellipsis> . Px)
        ;; — so the walk is over the proper prefix, and a dotted tail is the
        ;; rest pattern's to match.  list-take/list-drop already stop at the
        ;; prefix boundary.
        ((and (pair? (cdr pat)) (ellipsis-mark? (cadr pat) ell lits))
         (let* ((subpat    (car pat))
                (rest-pat  (cddr pat))
                (pvars     (pattern-vars subpat lits ell))
                (n-req     (count-required rest-pat ell lits))
                (n-total   (proper-length frm)))
           (if (< n-total n-req)
               #f
               (let* ((n-ell     (- n-total n-req))
                      (ell-frms  (list-take frm n-ell))
                      (rest-frms (list-drop frm n-ell))
                      (sub-envs  (map (lambda (f) (match-syntax subpat f lits ell use-env def-env))
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
                                 ;; No rest pattern: the whole form must have
                                 ;; been consumed, tail included.
                                 (if (null? rest-frms) '() #f)
                                 (match-syntax rest-pat rest-frms lits ell use-env def-env))))
                       (if rest-env
                           (append merged rest-env)
                           #f)))))))
        ;; Pair: match recursively
        ((pair? pat)
         (if (pair? frm)
             (let ((e1 (match-syntax (car pat) (car frm) lits ell use-env def-env)))
               (and e1
                    (let ((e2 (match-syntax (cdr pat) (cdr frm) lits ell use-env def-env)))
                      (and e2 (append e1 e2)))))
             #f))
        ;; Anything else: must be equal
        (else (and (equal? pat frm) '()))))

    ;; Find variables in template that are bound to ellipsis values in env
    (define (find-ellipsis-vars tmpl env ell lits)
      (cond
        ((symbol? tmpl)
         (let ((b (assq tmpl env)))
           (if (and b (ellipsis? (cdr b))) (list tmpl) '())))
        ((vector? tmpl)
         (find-ellipsis-vars (vector->list tmpl) env ell lits))
        ((pair? tmpl)
         ;; `(sub ... rest)` used to return only sub's variables and drop the
         ;; tail, so a variable appearing *after* the ellipsis was never bound
         ;; per iteration: `((b ... a) ...)` reported "ellipsis variable used
         ;; outside ellipsis template a".  The tail belongs to the same
         ;; iteration as `sub`, so its variables count too — with the ellipses
         ;; themselves dropped first, since a run of them is depth, not content.
         (if (and (pair? (cdr tmpl)) (ellipsis-mark? (cadr tmpl) ell lits))
             (append (find-ellipsis-vars (car tmpl) env ell lits)
                     (find-ellipsis-vars (drop-ellipses (cdr tmpl) ell lits) env ell lits))
             (append (find-ellipsis-vars (car tmpl) env ell lits)
                     (find-ellipsis-vars (cdr tmpl) env ell lits))))
        (else '())))

    (define (concat-lists ls)
      (if (null? ls) '() (append (car ls) (concat-lists (cdr ls)))))

    ;; How many ellipses a template element is followed by.  One is the ordinary
    ;; case; each extra one splices a further level, so (x ... ...) flattens what
    ;; ((x ...) ...) would have nested.
    (define (count-ellipses l ell lits)
      (if (and (pair? l) (ellipsis-mark? (car l) ell lits))
          (+ 1 (count-ellipses (cdr l) ell lits))
          0))

    (define (drop-ellipses l ell lits)
      (if (and (pair? l) (ellipsis-mark? (car l) ell lits))
          (drop-ellipses (cdr l) ell lits)
          l))

    ;; Expand `subtempl` across `depth` levels of ellipsis, returning a flat list
    ;; of the results.  At depth 1 each iteration contributes one element; deeper
    ;; down each contributes a list, and those are concatenated — which is what
    ;; makes the extra ellipses splice rather than nest.  Only penv is sliced
    ;; per iteration — ellipsis values are pattern bindings; subst rides along.
    (define (expand-ellipsis subtempl depth penv subst ell lits)
      (let* ((evars (find-ellipsis-vars subtempl penv ell lits))
             (n     (if (null? evars)
                        0
                        (length (ellipsis-vals (cdr (assq (car evars) penv)))))))
        (concat-lists
          (map (lambda (i)
                 (let* ((point-env
                         (map (lambda (v)
                                (cons v (list-ref (ellipsis-vals (cdr (assq v penv))) i)))
                              evars))
                        (local-env (append point-env penv)))
                   (if (= depth 1)
                       (list (instantiate-template subtempl local-env subst ell lits))
                       (expand-ellipsis subtempl (- depth 1) local-env subst ell lits))))
               (iota n)))))

    ;; (<ellipsis> <template>) — R7RS ellipsis escape: the template is used with
    ;; ellipses having no special meaning.  Pattern variables still substitute.
    ;; Overwhelmingly used as (... ...) to emit a literal ellipsis, in a macro
    ;; that itself expands to a macro definition.
    (define (instantiate-escaped tmpl penv subst)
      (cond
        ((symbol? tmpl)
         (let ((b (assq tmpl penv)))
           (if b
               (cdr b)
               (let ((r (assq tmpl subst)))
                 (if r (cdr r) tmpl)))))
        ((vector? tmpl)
         (list->vector (instantiate-escaped (vector->list tmpl) penv subst)))
        ((pair? tmpl)
         ;; Quoted data takes pattern variables but not renames — same rule as
         ;; instantiate-template below.
         (if (and (eq? (car tmpl) 'quote) (pair? (cdr tmpl)) (null? (cddr tmpl)))
             (list 'quote (instantiate-escaped (cadr tmpl) penv '()))
             (cons (instantiate-escaped (car tmpl) penv subst)
                   (instantiate-escaped (cdr tmpl) penv subst))))
        (else tmpl)))

    ;; Instantiate a template.  Two environments with different reach:
    ;;
    ;;   penv   pattern variables — substituted everywhere, (quote ...)
    ;;          included, because R7RS says a pattern variable in quoted data
    ;;          stands for the matched form.
    ;;   subst  the expander's own renames — hygiene %h- names for
    ;;          template-bound identifiers and %gref% marks for free ones —
    ;;          suppressed under quote, because those exist to steer variable
    ;;          *resolution* and quoted data resolves nothing.  Without the
    ;;          split, a template reading (let ((tmp 1)) (list tmp 'tmp))
    ;;          returned (1 %h-tmp-3): the rename leaked into the datum.
    ;;
    ;; Ellipsis variables have (ellipsis-vals ...) values in penv.
    (define (instantiate-template tmpl penv subst ell lits)
      (cond
        ;; Symbol: pattern variables first, then renames
        ((symbol? tmpl)
         (let ((b (assq tmpl penv)))
           (if b
               (let ((val (cdr b)))
                 (if (ellipsis? val)
                     (error "syntax-rules: ellipsis variable used outside ellipsis template" tmpl)
                     val))
               (let ((r (assq tmpl subst)))
                 (if r (cdr r) tmpl)))))
        ;; Vector template: rebuild from the list instantiation, so ellipses
        ;; inside vectors come along for free
        ((vector? tmpl)
         (list->vector
           (instantiate-template (vector->list tmpl) penv subst ell lits)))
        ;; Non-pair: datum
        ((not (pair? tmpl)) tmpl)
        ;; Ellipsis escape — must precede the ellipsis-template case, since
        ;; (... ...) also looks like "subtemplate followed by ellipsis".
        ((and (ellipsis-mark? (car tmpl) ell lits)
              (pair? (cdr tmpl)) (null? (cddr tmpl)))
         (instantiate-escaped (cadr tmpl) penv subst))
        ;; Quoted data: pattern variables substitute, renames do not.
        ((and (eq? (car tmpl) 'quote) (pair? (cdr tmpl)) (null? (cddr tmpl)))
         (list 'quote (instantiate-template (cadr tmpl) penv '() ell lits)))
        ;; Ellipsis template: (subtempl <ell> [<ell> ...]) rest
        ((and (pair? (cdr tmpl)) (ellipsis-mark? (cadr tmpl) ell lits))
         (let* ((subtempl  (car tmpl))
                (depth     (count-ellipses (cdr tmpl) ell lits))
                (rest-tmpl (drop-ellipses (cdr tmpl) ell lits)))
           (append
             (expand-ellipsis subtempl depth penv subst ell lits)
             (instantiate-template rest-tmpl penv subst ell lits))))
        ;; Regular pair
        (else
         (cons (instantiate-template (car tmpl) penv subst ell lits)
               (instantiate-template (cdr tmpl) penv subst ell lits)))))


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

    (define (template-bound-ids tmpl pattern-vars literals ell)
      (let ((acc '()))
        (define (note! s)
          (when (and (symbol? s)
                     (not (ellipsis-mark? s ell literals))
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
            ;; A nested template — one produced by an enclosing expansion —
            ;; carries its keywords %core%-marked; binder recognition must
            ;; see through the mark.
            (let ((head (let ((h (car t)))
                          (if (symbol? h) (or (core-name h) h) h))))
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
                ;; Definitions bind too (R7RS 5.3.2): a template that
                ;; introduces (define n v) binds n — as a letrec* variable in
                ;; a body, hygienically invisible at top level — and the
                ;; shorthand's formals are its lambda's.  Treating the name
                ;; as free instead is what used to turn it into a %gref%
                ;; global and break every macro-produced definition.
                ((and (eq? head 'define) (pair? (cdr t)))
                 (if (pair? (cadr t))
                     (begin (note! (car (cadr t)))
                            (note-formals! (cdr (cadr t))))
                     (note! (cadr t)))
                 (walk-list (cddr t)))
                ((and (eq? head 'define-values) (pair? (cdr t)))
                 (note-formals! (cadr t))
                 (walk-list (cddr t)))
                ((and (eq? head 'define-syntax) (pair? (cdr t)))
                 (note! (cadr t))
                 (walk-list (cddr t)))
                (else (walk-list t)))))
          (when (vector? t)
            (walk-list (vector->list t))))
        (walk tmpl)
        acc))


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

    ;; ---------------------------------------------------------------
    ;; %core% marks: a template's keywords survive use-site shadowing
    ;; ---------------------------------------------------------------
    ;;
    ;; Once dispatch consults the lexical environment, (let ((if car)) ...)
    ;; makes `if` a variable — which is right for the user's code and wrong
    ;; for a template that meant the special form: a macro expanding to
    ;; (if c a b) must mean `if` wherever it is used.  So instantiation marks
    ;; a template's keyword occurrences %core%<name>, and the dispatcher
    ;; strips the mark and dispatches the keyword directly, past whatever the
    ;; use site binds.  The mark is the keyword sibling of %gref% and rides
    ;; the same subst list, so it never reaches quoted data (C1's split) and
    ;; never reaches the IR (the dispatcher consumes it).
    ;;
    ;; Not markable: quote and the quasiquote trio, matched structurally by
    ;; walkers that must see them bare; syntax-rules, whose specs stay
    ;; literal (nested specs are skipped whole anyway); the module forms,
    ;; which the library walkers match; and the ellipsis and _.

    (define %core-prefix "%core%")

    (define (core-symbol name)
      (string->symbol (string-append %core-prefix (symbol->string name))))

    ;; Strip the %core% marker, or #f when the symbol does not carry one.
    (define (core-name sym)
      (let ((s (symbol->string sym)))
        (and (> (string-length s) 6)
             (string=? (substring s 0 6) "%core%")
             (string->symbol (substring s 6 (string-length s))))))

    (define %core-markable
      '(lambda define set! if begin
        let let* letrec letrec* and or when unless cond case do
        define-record-type guard parameterize case-lambda
        define-values let-values let*-values
        delay delay-force include include-ci cond-expand syntax-error
        define-syntax let-syntax letrec-syntax
        else =>))

    ;; (k . %core%k) for each markable keyword occurring in the template —
    ;; outside nested syntax-rules, and skipping any keyword the macro's own
    ;; definition environment shadows as a variable, since the template then
    ;; means that variable.
    (define (template-core-marks tmpl pvars literals ell def-env)
      (let ((acc '()))
        (define (note! s)
          (when (and (symbol? s)
                     (memq s %core-markable)
                     (not (eq? s ell))
                     (not (memq s pvars))
                     (not (memq s literals))
                     (not (let ((d (cenv-lookup def-env s)))
                            (and (pair? d) (eq? (car d) 'variable))))
                     (not (assq s acc)))
            (set! acc (cons (cons s (core-symbol s)) acc))))
        (define (walk t)
          (cond
            ((symbol? t) (note! t))
            ((vector? t) (walk (vector->list t)))
            ((pair? t)
             (cond
               ((eq? (car t) 'quote) #f)
               ((eq? (car t) 'syntax-rules) #f)
               (else (walk (car t)) (walk (cdr t)))))
            (else #f)))
        (walk tmpl)
        acc))

    ;; Free identifiers of a template: symbols that are not pattern variables,
    ;; not bound by the template, not literals, not keywords, and not the
    ;; ellipsis.  Macro names are included — classify-frees decides what each
    ;; free identifier becomes.
    (define (template-free-ids tmpl pattern-vars bound literals ell)
      (let ((acc '()))
        (define (note! s)
          (when (and (symbol? s)
                     (not (eq? s ell))
                     (not (memq s pattern-vars))
                     (not (memq s bound))
                     (not (memq s literals))
                     (not (memq s %expander-keywords))
                     ;; Already marked — a template that came from an enclosing
                     ;; macro's expansion.  Marking twice yields %gref%%gref%x,
                     ;; which strips to a name nothing is bound to.
                     (not (gref-name s))
                     (not (core-name s))
                     (not (memq s acc)))
            (set! acc (cons s acc))))
        (define (walk t)
          (cond
            ((symbol? t) (note! t))
            ((vector? t) (walk (vector->list t)))
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

    ;; What each free identifier of a template becomes, judged against the
    ;; macro's *definition* environment:
    ;;
    ;;   local macro there        →  its global alias, so the use site cannot
    ;;                               intercept the name
    ;;   variable there, renamed  →  the rename
    ;;   variable there, plain    →  stays bare; within the definition region
    ;;                               the use site resolves it to that binding
    ;;   anything else            →  %gref%<name>: top-level resolution — the
    ;;                               global macro or value the template saw —
    ;;                               past whatever the use site binds
    (define (classify-frees tmpl pattern-vars bound literals ell def-env)
      (let loop ((ids (template-free-ids tmpl pattern-vars bound literals ell))
                 (acc '()))
        (if (null? ids)
            (reverse acc)
            (let* ((s (car ids))
                   (d (cenv-lookup def-env s)))
              (loop (cdr ids)
                    (cond
                      ((and (pair? d) (eq? (car d) 'macro))
                       (cons (cons s (cdr d)) acc))
                      ((and (pair? d) (eq? (car d) 'variable))
                       (if (cdr d) (cons (cons s (cdr d)) acc) acc))
                      (else
                       (cons (cons s (gref-symbol s)) acc))))))))

    ;; SRFI 147, which kaappi supports: the transformer-spec position of
    ;; define-syntax / let-syntax / letrec-syntax accepts, beyond a literal
    ;; (syntax-rules …): a macro use that expands — possibly through
    ;; several macros — into a transformer spec; a bare keyword, aliasing
    ;; an existing macro; and (begin <define-syntax>… <spec>), private
    ;; helper macros followed by the final spec.  SRFI 148 needs all three
    ;; together — its em-syntax-rules bottoms out through exactly
    ;; (begin (define-syntax a spec) a).
    ;;
    ;; Resolved in the *definition* environment, since the spec is text
    ;; written where the binding form is; heads may arrive %core%-marked
    ;; when the spec came out of a template.  Fuel-bounded so a spec that
    ;; never converges is a compile error, not a hang.  Callers store the
    ;; resolved spec, so rename-macro-templates! always sees syntax-rules.
    ;;
    ;; Like kaappi, aliasing a builtin special form is out: a bare keyword
    ;; must name a syntax-rules macro whose spec is on record.
    (define (spec-head-is? s sym)
      (and (pair? s) (symbol? (car s))
           (or (eq? (car s) sym) (eq? (core-name (car s)) sym))))

    ;; 4096, not a small bound: SRFI 148's aux transformers step once per
    ;; template token, so a realistic em-syntax-rules use burns hundreds of
    ;; steps before bottoming out.
    (define (resolve-transformer-spec spec0 env)
      (let resolve ((spec spec0) (fuel 4096))
        (cond
          ((zero? fuel)
           (error "define-syntax: transformer spec does not converge" spec0))
          ;; Bare keyword: the new name aliases an existing macro — resolve
          ;; to its recorded spec so the alias is a full rebuild, renameable
          ;; like any other.
          ((symbol? spec)
           (let* ((d (cenv-lookup env spec))
                  (gname (cond
                           ((and (pair? d) (eq? (car d) 'macro)) (cdr d))
                           ((gref-name spec))
                           (else spec)))
                  (s (paal-macro-spec gname)))
             (or s
                 (error "define-syntax: keyword alias names no syntax-rules macro"
                        spec))))
          ;; (begin defs … final): install the helpers, then resolve the
          ;; final spec — usually a bare reference to a helper just
          ;; installed.  The helper names are hygiene-fresh when this shape
          ;; comes out of a template, so installing them globally is safe.
          ((spec-head-is? spec 'begin)
           (let loop ((ds (cdr spec)))
             (cond
               ((null? ds)
                (error "define-syntax: empty begin transformer spec" spec0))
               ((null? (cdr ds)) (resolve (car ds) (- fuel 1)))
               (else
                (let ((d (car ds)))
                  (unless (spec-head-is? d 'define-syntax)
                    (error "define-syntax: a begin transformer spec allows only define-syntax before the final spec"
                           d))
                  (let ((hspec (resolve-transformer-spec (caddr d) env)))
                    (paal-macro-set! (cadr d)
                                     (make-transformer hspec env)
                                     hspec))
                  (loop (cdr ds)))))))
          (else
           (let ((t (and (pair? spec)
                         (symbol? (car spec))
                         (not (eq? (car spec) 'syntax-rules))
                         (body-macro-transformer (car spec) env))))
             (if t
                 (resolve (t spec env) (- fuel 1))
                 spec))))))

    ;; Build a transformer from a syntax-rules spec — either shape, with or
    ;; without the custom ellipsis identifier (see spec-ellipsis above).
    ;;
    ;; def-env is the lexical environment where the macro is *defined*: '()
    ;; for top-level define-syntax, the surrounding cenv for let-syntax and
    ;; letrec-syntax.  It steers classify-frees and the %core% marking above.
    ;; The transformer receives the use-site environment as well; the matcher
    ;; consults it for denotation-aware literals.
    (define (make-transformer spec def-env)
      (if (not (and (pair? spec) (eq? (car spec) 'syntax-rules)
                    (pair? (cdr spec))
                    (list? (spec-literals spec))))
          (error "define-syntax: expected (syntax-rules ...) form" spec)
          (let ((ell      (spec-ellipsis spec))
                (literals (spec-literals spec))
                (clauses  (spec-clauses spec)))
            (lambda (form use-env)
              (let loop ((cls clauses))
                (if (null? cls)
                    (error "syntax-rules: no matching pattern" form)
                    ;; Strip keyword from both pattern and form
                    (let* ((clause   (car cls))
                           (pat-args (cdr (car clause)))
                           (template (cadr clause))
                           (env      (match-syntax pat-args (cdr form) literals ell use-env def-env)))
                      (if env
                          ;; Fresh renames per expansion, so two uses of the same
                          ;; macro never share an introduced name.  Pattern
                          ;; bindings and renames travel separately: pattern
                          ;; variables substitute even inside quoted data,
                          ;; renames never do — see instantiate-template.
                          ;; Order in subst: bound renames, then frees, then
                          ;; keyword marks — a template-bound `else` is its
                          ;; rename, not a mark.
                          (let* ((pvars   (map car env))
                                 (bound   (template-bound-ids template pvars literals ell))
                                 (renames (map (lambda (s)
                                                 (cons s (fresh-name
                                                           (string-append
                                                             "%h-" (symbol->string s) "-"))))
                                               bound))
                                 (frees   (classify-frees
                                            template pvars bound literals ell def-env))
                                 (marks   (template-core-marks
                                            template pvars literals ell def-env)))
                            (instantiate-template
                              template env (append renames frees marks) ell literals))
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

    ;; srfi-<n> → n, or #f when the symbol is not that shape.
    (define (srfi-feature-number sym)
      (let* ((s (symbol->string sym)) (n (string-length s)))
        (and (> n 5)
             (string=? (substring s 0 5) "srfi-")
             (let loop ((i 5))
               (cond ((= i n) (string->number (substring s 5 n)))
                     ((let ((c (string-ref s i)))
                        (and (char>=? c #\0) (char<=? c #\9)))
                      (loop (+ i 1)))
                     (else #f))))))

    (define (feature-req? req)
      (cond
        ((symbol? req)
         (cond
           ((memq req %paal-features) #t)
           ;; srfi-<n> is the feature spelling of (library (srfi <n>)) —
           ;; kaappi routes both through one availability check, and so
           ;; does this: the id holds exactly when the import would
           ;; resolve.  Deliberately not added to (features)' answer,
           ;; matching kaappi, whose list also stops at the named
           ;; capabilities.
           ((srfi-feature-number req)
            => (lambda (n) (feature-req? (list 'library (list 'srfi n)))))
           (else #f)))
        ((not (pair? req)) #f)
        ;; (library <name>) asks whether that library can be imported here.
        ;; It was hard-wired to #f, so the common
        ;; `(cond-expand ((library (srfi 1)) ...) (else ...))` idiom always
        ;; took the fallback even when (srfi 1) was right there.
        ((eq? (car req) 'library)
         (and (pair? (cdr req))
              (let ((name (cadr req)))
                (or (builtin-library? name)
                    (and (paal-embedded-source name) #t)
                    (and (find-library-file name) #t)))))
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
    ;; Compile-time lexical environment (cenv)
    ;; ---------------------------------------------------------------
    ;;
    ;; An immutable alist of (name . denotation) threaded through expansion:
    ;;
    ;;   (variable . #f)      lexically bound value, spelling kept
    ;;   (variable . rename)  lexically bound value under a rename
    ;;   (macro . alias)      local macro; transformer lives in %paal-macros
    ;;                        under the alias
    ;;
    ;; The single place value bindings enter is the lambda case of the
    ;; dispatcher — every derived binder desugars to a lambda before its body
    ;; is expanded, so threading one case covers let, do, named let and all
    ;; the rest.  Top level is the empty environment, which paal's own
    ;; define-heavy sources fast-path through.

    (define (cenv-lookup env name)
      (let ((hit (assq name env)))
        (and hit (cdr hit))))

    (define (cenv-extend-var env name)
      (cons (cons name (cons 'variable #f)) env))

    (define (cenv-extend-formals env formals)
      (cond
        ((symbol? formals) (cenv-extend-var env formals))
        ((pair? formals)
         (cenv-extend-formals
           (if (symbol? (car formals))
               (cenv-extend-var env (car formals))
               env)
           (cdr formals)))
        (else env)))

    (define (cenv-bind-macro env name alias)
      (cons (cons name (cons 'macro alias)) env))

    ;; The six symbols compiler.sld dispatches on.  A lambda formal spelling
    ;; one of them is α-renamed so the expanded output stays unambiguous —
    ;; (lambda (if) (if 1)) must not read as a conditional downstream.  Other
    ;; keywords need no rename: the analyzer treats them as ordinary heads.
    (define %analyzer-keywords '(quote lambda define set! if begin))

    ;; Extend env with a lambda's formals, renaming analyzer keywords.
    ;; Returns (env . formals), formals rewritten where renamed.
    (define (cenv-bind-lambda env formals)
      (cond
        ((symbol? formals)
         (if (memq formals %analyzer-keywords)
             (let ((r (fresh-name (string-append "%kw-" (symbol->string formals) "-"))))
               (cons (cons (cons formals (cons 'variable r)) env) r))
             (cons (cenv-extend-var env formals) formals)))
        ((pair? formals)
         (let ((head (car formals)))
           (cond
             ((and (symbol? head) (memq head %analyzer-keywords))
              (let* ((r    (fresh-name (string-append "%kw-" (symbol->string head) "-")))
                     (rest (cenv-bind-lambda
                             (cons (cons head (cons 'variable r)) env)
                             (cdr formals))))
                (cons (car rest) (cons r (cdr rest)))))
             ((symbol? head)
              (let ((rest (cenv-bind-lambda (cenv-extend-var env head)
                                            (cdr formals))))
                (cons (car rest) (cons head (cdr rest)))))
             (else
              (let ((rest (cenv-bind-lambda env (cdr formals))))
                (cons (car rest) (cons head (cdr rest))))))))
        (else (cons env formals))))

    ;; A (variable . rename) hit, or #f.
    (define (cenv-variable-rename env name)
      (let ((d (cenv-lookup env name)))
        (and (pair? d) (eq? (car d) 'variable) (cdr d))))

    ;; ---------------------------------------------------------------
    ;; Main dispatch
    ;; ---------------------------------------------------------------

    ;; The exported entry point: one top-level form, empty environment.
    (define (paal-expand form)
      (expand-form form '()))

    ;; Dispatch order, and why:
    ;;
    ;;   1. a %core%-marked head is the keyword, unconditionally — the mark
    ;;      exists so a template's `if` survives a use site that binds `if`;
    ;;   2. a %gref%-marked head naming a global macro is that macro — the
    ;;      template saw it past whatever the use site binds;
    ;;   3. a lexical denotation wins over everything else: a variable makes
    ;;      the form a plain application (keyword shadowing, R7RS 4.3), a
    ;;      local macro expands through its alias;
    ;;   4. the keyword table;
    ;;   5. global macros;
    ;;   6. a plain application.
    (define (expand-form form env)
      (cond
        ;; A symbol: apply a lexical rename; strip a stray keyword mark.
        ((symbol? form)
         (or (core-name form)
             (cenv-variable-rename env form)
             form))
        ((not (pair? form)) form)
        ((not (symbol? (car form)))
         (map (lambda (f) (expand-form f env)) form))
        (else
         (let* ((head  (car form))
                (cname (core-name head)))
           (cond
             (cname
              (dispatch-core (cons cname (cdr form)) env))
             ((let ((g (gref-name head)))
                (and g (paal-macro-get g) g))
              => (lambda (g)
                   (expand-form ((paal-macro-get g) (cons g (cdr form)) env)
                                env)))
             ((cenv-lookup env head)
              => (lambda (d)
                   (if (eq? (car d) 'macro)
                       (expand-form ((paal-macro-get (cdr d)) form env) env)
                       (map (lambda (f) (expand-form f env)) form))))
             (else (dispatch-core form env)))))))

    (define (dispatch-core form env)
      (case (car form)
            ;; --- Core forms: recurse into sub-forms ---
            ((quote)
             form)
            ((lambda)
             (let ((bf (cenv-bind-lambda env (cadr form))))
               `(lambda ,(cdr bf)
                  ,@(expand-body (cddr form) (car bf)))))
            ((define)
             (if (pair? (cadr form))
                 (let ((bf (cenv-bind-lambda env (cdadr form))))
                   `(define ,(caadr form)
                      (lambda ,(cdr bf)
                        ,@(expand-body (cddr form) (car bf)))))
                 `(define ,(cadr form)
                    ,@(if (null? (cddr form))
                          '()
                          (list (expand-form (caddr form) env))))))
            ((set!)
             (let* ((name (cadr form))
                    (r    (and (symbol? name)
                               (cenv-variable-rename env name))))
               `(set! ,(or r name) ,(expand-form (caddr form) env))))
            ((if)
             (if (null? (cdddr form))
                 `(if ,(expand-form (cadr form) env)
                      ,(expand-form (caddr form) env))
                 `(if ,(expand-form (cadr form) env)
                      ,(expand-form (caddr form) env)
                      ,(expand-form (cadddr form) env))))
            ((begin)
             `(begin ,@(map (lambda (f) (expand-form f env)) (cdr form))))
            ;; --- Derived forms: desugar then re-expand ---
            ;; env passes through unchanged: any binding a derived form
            ;; introduces surfaces as a lambda in its desugaring, and the
            ;; lambda case above extends the environment when the re-expansion
            ;; reaches it.
            ((let)         (expand-form (expand-let form) env))
            ((let*)        (expand-form (expand-let* form) env))
            ((letrec)      (expand-form (expand-letrec form) env))
            ((letrec*)     (expand-form (expand-letrec* form) env))
            ((and)         (expand-form (expand-and (cdr form)) env))
            ((or)          (expand-form (expand-or  (cdr form)) env))
            ((when)        (expand-form (expand-when form) env))
            ((unless)      (expand-form (expand-unless form) env))
            ((cond)        (expand-form (expand-cond (cdr form) env) env))
            ((case)        (expand-form (expand-case form env) env))
            ((quasiquote)  (expand-form (expand-qq (cadr form) 0) env))
            ((do)          (expand-form (expand-do form) env))
            ((define-record-type)
             (expand-form (expand-define-record-type form) env))
            ((guard)
             (expand-form (expand-guard form env) env))
            ((parameterize)
             (expand-form (expand-parameterize form) env))
            ;; --- New derived forms ---
            ((case-lambda)
             (expand-form (expand-case-lambda form) env))
            ((define-values)
             (expand-form (expand-define-values form) env))
            ((let-values)
             (expand-form (expand-let-values form) env))
            ((let*-values)
             (expand-form (expand-let*-values form) env))
            ((delay)
             ;; (delay expr) → (%paal-delay-impl (lambda () expr))
             ;; %paal-delay-impl creates a lazy promise (not forced until (force p)).
             ;; HOST version is in paal-initial-env; paal-compiled version overrides
             ;; it in pkaappi-make-globals for the bytecode VM path.
             `(%paal-delay-impl (lambda () ,(expand-form (cadr form) env))))
            ((delay-force)
             ;; delay-force (iterative): force inner promise when thunk returns a promise
             `(%paal-delay-impl (lambda () (force ,(expand-form (cadr form) env)))))
            ((include)
             (expand-form (expand-include (cdr form) #f) env))
            ((include-ci)
             (expand-form (expand-include (cdr form) #t) env))
            ((cond-expand)
             (expand-form (expand-cond-expand form) env))
            ((syntax-error)
             ;; (syntax-error message irritant ...)
             (apply error (cdr form)))
            ;; --- Macro definition ---
            ((define-syntax)
             (let* ((name (cadr form))
                    (transformer-spec
                      (resolve-transformer-spec (caddr form) env)))
               (paal-macro-set! name (make-transformer transformer-spec env)
                                transformer-spec)
               '(quote #f)))
            ;; R7RS 4.3.1 gives the two forms one difference: the region of a
            ;; let-syntax keyword is the body only, so a binding cannot see
            ;; its siblings, while letrec-syntax includes the bindings, so
            ;; they can.  Both scope through the cenv now: each transformer is
            ;; installed globally under a fresh %mac- alias — a name no source
            ;; can utter — and the body's environment maps the source names to
            ;; the aliases, so the macros are exactly as local as the
            ;; environment entry.  The definition environment handed to
            ;; make-transformer is what separates the two forms: the outer env
            ;; for let-syntax, the extended one for letrec-syntax, which is
            ;; how a sibling reference in a template resolves outward in one
            ;; and to the sibling in the other.
            ((let-syntax letrec-syntax)
             (let* ((letrec?  (eq? (car form) 'letrec-syntax))
                    (bindings (cadr form))
                    (body     (cddr form))
                    (aliases  (map (lambda (b)
                                     (fresh-name
                                       (string-append
                                         "%mac-" (symbol->string (car b)) "-")))
                                   bindings))
                    (env*     (let bind ((bs bindings) (as aliases) (e env))
                                (if (null? bs)
                                    e
                                    (bind (cdr bs) (cdr as)
                                          (cenv-bind-macro e (car (car bs))
                                                           (car as))))))
                    (def-env  (if letrec? env* env)))
               (for-each (lambda (b a)
                           (paal-macro-set! a
                             (make-transformer
                               (resolve-transformer-spec (cadr b) def-env)
                               def-env)))
                         bindings aliases)
               ;; The body is a *body* (R7RS 4.3.1 and 5.3.2): a leading
               ;; definition is scoped to it, so (let-syntax () (define x 2))
               ;; defines an inner x, not the enclosing one.  An empty body
               ;; keeps the old begin, which expand-body would reject.
               (if (null? body)
                   '(begin)
                   (expand-form `(let () ,@body) env*))))
            ;; --- Library forms ---
            ;; A define-library evaluated as a program form -- `paal file.sld`,
            ;; or pkaappi-load-file on a pipeline stage.  Its own imports are
            ;; honoured, but its body — begins and includes in declaration
            ;; order — is spliced unrenamed: there is no importer here to hide
            ;; anything from, and paal's own stages rely on loading this way
            ;; into one shared globals table.
            ((define-library)
             (let* ((decls    (normalize-decls (cddr form)))
                    (%scope   (import-scope-save))
                    (imports  (append-map cdr (decls-of decls 'import)))
                    (prologue (map expand-one-import imports))
                    (%restored (import-scope-restore! %scope))
                    (bodies   (body-forms-of decls)))
               (paal-expand
                 (cons 'begin (append (drain-pending!) prologue bodies)))))
            ((import)
             (expand-import form))
            ;; A top-level `export` outside a define-library has nothing to
            ;; act on; inside one, install-library! reads it directly.
            ((export)
             '(quote #f))
            ;; --- Global macro or plain application ---
            ;; (%gref% heads and lexical denotations were handled before the
            ;; keyword table — see expand-form.)
            (else
             (let ((macro (paal-macro-get (car form))))
               (if macro
                   (expand-form (macro form env) env)
                   (map (lambda (f) (expand-form f env)) form))))))

    ;; Strip the %gref% marker, or #f when the symbol does not carry one.
    ;; Shared with the emitter and the tree-walking VM, which resolve a marked
    ;; identifier straight to the top level.
    (define (gref-name sym)
      (let ((s (symbol->string sym)))
        (and (> (string-length s) 6)
             (string=? (substring s 0 6) "%gref%")
             (string->symbol (substring s 6 (string-length s))))))

    ;; Expand a form list without touching the import-scope state.  Library
    ;; bodies go through this: they are expanded while the importing program is
    ;; mid-expansion, and must neither reset its state nor be checked against
    ;; its imports.
    ;; The state is saved and restored, not merely left alone: a library body
    ;; contains its *own* `(import …)` forms, and those would otherwise grant
    ;; the importing program whatever the library imported.  `(srfi 1)` imports
    ;; `(scheme base)`, so `(import (srfi 1))` alone was silently granting base
    ;; — the same leak the library prologue has, arriving by a different route.
    (define (expand-nested forms)
      (let splice ((fs forms))
        (if (null? fs)
            '()
            (let ((e (paal-expand (car fs))))
              (if (and (pair? e) (eq? (car e) 'begin))
                  (splice (append (cdr e) (cdr fs)))
                  (cons e (splice (cdr fs))))))))

    ;; A library is expanded while the importing program is mid-expansion, and
    ;; both its import *prologue* and its *body* run through expand-one-import
    ;; and paal-expand — so both would otherwise grant the importing program
    ;; whatever the library imported.  `(srfi 1)` imports `(scheme base)`, so
    ;; `(import (srfi 1))` alone silently granted base: `sin` was correctly
    ;; rejected while `car` sailed through, which is precisely the shape of an
    ;; unearned base grant.  Same leak as the library prologue, by another
    ;; route.  Save around the whole of it, restore after.
    (define (import-scope-save)
      (list %import-seen? %import-base-excepts %import-allowed %import-alias-defs))

    (define (import-scope-restore! saved)
      (set! %import-seen?         (car saved))
      (set! %import-base-excepts  (cadr saved))
      (set! %import-allowed       (caddr saved))
      (set! %import-alias-defs    (cadddr saved))
      #t)

    (define (paal-expand-all forms)
      (import-scope-reset!)
      (let ((expanded (expand-nested forms)))
        (check-import-scope! expanded)
        expanded))

    ;; The entry point for expanding a *file's* forms: the same expansion under
    ;; the file's directory as include context, so `(include "sibling.scm")` in
    ;; a program resolves the way it does in a library — beside the file that
    ;; wrote it, matching kaappi.  Guarded so the frame comes down when
    ;; expansion raises: `check` keeps going after a broken file, and the next
    ;; file's includes must not resolve against this one's directory.
    (define (paal-expand-all-for-file path forms)
      (include-dir-push! (paal-dirname path))
      (guard (e (#t (include-dir-pop!) (raise e)))
        (let ((expanded (paal-expand-all forms)))
          (include-dir-pop!)
          expanded)))

    ;; --- import scope checking --------------------------------------------
    ;;
    ;; What makes `(import (scheme base))` mean anything.  Emitting aliases
    ;; cannot do it: the globals table already holds every primitive under its
    ;; public name, so `(define sin sin)` restricts nothing and `get-global sin`
    ;; finds it regardless.  The restriction has to be a *check* — after
    ;; expansion, every free global reference must be one the program is
    ;; entitled to.
    ;;
    ;; Only programs with a top-level `import` are checked.  That is the escape
    ;; hatch, and it is load-bearing rather than a convenience: every one of
    ;; paal's own tests is a bare script, as are `paal eval`, the REPL, the
    ;; globals blob and each `.pbc` the pipeline loads.  R7RS requires an
    ;; import; a program that supplies one is asking to be held to it.
    ;;
    ;; `%import-seen?` and `%import-allowed` are expander module state, which is
    ;; safe here where `%paal-lib-paths` would not be: expansion and this check
    ;; happen inside one copy of the expander. The two-copies hazard is between
    ;; the pipeline and the globals table, which this never crosses.

    (define %import-seen?   #f)   ; did the program have a top-level import
    ;; One entry per base-rooted spec with no `only` on its modifier path;
    ;; each is that spec's excluded names, so plain (scheme base) contributes
    ;; '() — everything unclaimed — and (except (scheme base) car) a set the
    ;; check consults.  A list of sets rather than one flag or one set
    ;; because imports union: (import (except (scheme base) car)
    ;; (scheme base)) grants car back through the second spec.
    (define %import-base-excepts '())
    (define %import-allowed '())  ; names granted by the imports it did have
    (define %import-lib-defs '()) ; names defined by spliced library bodies
    (define %import-alias-defs '()) ; names defined by emitted import aliases

    (define (import-scope-reset!)
      (set! %import-seen? #f)
      (set! %import-base-excepts '())
      (set! %import-allowed '())
      (set! %import-lib-defs '())
      (set! %import-alias-defs '()))

    ;; A library's body is spliced in ahead of the program that imported it,
    ;; and it is governed by its *own* imports — not the importer's.  Checking
    ;; it against the importer's is how the first attempt at this rejected
    ;; (chibi test) for using `reverse`.  So the names its body defines are
    ;; recorded, and the forms defining them are skipped.
    (define (import-scope-note-library! forms)
      (set! %import-lib-defs (append (top-level-defined forms) %import-lib-defs)))

    ;; Called by expand-import for each spec, before the aliases are emitted.
    ;; `(scheme r5rs)` counts as base: it exports the whole R5RS language, and
    ;; paal's entry for it names only `exact->inexact` / `inexact->exact`
    ;; because those are the two R7RS *renamed*, not because they are all of
    ;; it.  Treating the export list as exhaustive would reject a program that
    ;; imports r5rs alone and uses `car`.
    ;; Seen through the modifiers, so `(only (scheme base) car)` is still
    ;; recognized as resting on base — the predicate answers "is there no
    ;; export list to validate or filter against", which is a property of the
    ;; root.  What the *grant* then is depends on the modifier path:
    ;; import-scope-note! narrows it by the `only` and `except` found there.
    (define (grants-everything? spec)
      (cond
        ((not (pair? spec)) #f)
        ((memq (car spec) '(only except prefix rename))
         (grants-everything? (cadr spec)))
        (else (or (equal? spec '(scheme base)) (equal? spec '(scheme r5rs))))))

    ;; Is there an `only` anywhere on the modifier path?  If so the spec's
    ;; whole grant is the aliases `only` manufactured (transformed by any
    ;; outer modifiers), and no base-wide grant applies.
    (define (base-only-path? spec)
      (and (pair? spec)
           (memq (car spec) '(only except prefix rename))
           (or (eq? (car spec) 'only)
               (base-only-path? (cadr spec)))))

    ;; Every name an `except` along the modifier path removes.
    (define (base-except-union spec)
      (if (and (pair? spec) (memq (car spec) '(only except prefix rename)))
          (if (eq? (car spec) 'except)
              (append (cddr spec) (base-except-union (cadr spec)))
              (base-except-union (cadr spec)))
          '()))

    ;; `(prefix (scheme inexact) m:)` emits `(define m:sin sin)`, whose
    ;; right-hand side names the *internal* binding — which the program was not
    ;; granted, and must not be, or the prefix would restrict nothing.  So the
    ;; alias forms themselves are exempt from the check, exactly as library
    ;; bodies are: both are expander output rather than program text.
    (define (import-scope-note-aliases! names)
      (set! %import-alias-defs (append names %import-alias-defs)))

    (define (import-scope-note! spec names)
      (set! %import-seen? #t)
      (when (and (grants-everything? spec)
                 (not (base-only-path? spec)))
        (set! %import-base-excepts
              (cons (base-except-union spec) %import-base-excepts)))
      (set! %import-allowed (append names %import-allowed)))

    ;; A name a program may reference: one it defined, one an import granted,
    ;; or — if it imported (scheme base) — anything no small library claims.
    ;; `%`-prefixed names are always allowed: they are paal's own plumbing
    ;; (%paal-vm-raise, %paal-winds, the %gref% hygiene marker) and appear in
    ;; expander output rather than in the program.
    (define (import-allows? name defined)
      (or (memq name defined)
          (memq name %import-allowed)
          (internal-name? name)
          (and (not (memq name (scheme-lib-claimed-names)))
               (let loop ((es %import-base-excepts))
                 (and (pair? es)
                      (or (not (memq name (car es)))
                          (loop (cdr es))))))))

    (define (internal-name? name)
      (let ((s (symbol->string name)))
        (and (> (string-length s) 0) (char=? (string-ref s 0) #\%))))

    ;; The same grant computation as the check above, packaged for
    ;; `environment`: given import specs as data, answer whether each named
    ;; global belongs in the resulting table.  #f when any spec roots in a
    ;; file-backed library — resolving one of those *loads* it, with macro
    ;; and pending-form side effects inside the caller's program, and its
    ;; definitions would then have to run in the child table; until the
    ;; module system can do that, such an environment stays a full table.
    ;; %-prefixed plumbing is always kept, as in the check.
    (define (import-spec-root spec)
      (if (and (pair? spec) (memq (car spec) '(only except prefix rename)))
          (import-spec-root (cadr spec))
          spec))

    (define (paal-import-grant-predicate specs)
      (let loop ((ss specs) (names '()) (excepts '()))
        (cond
          ((null? ss)
           (let ((claimed (scheme-lib-claimed-names)))
             (lambda (name)
               (or (internal-name? name)
                   (memq name names)
                   (and (not (memq name claimed))
                        (let scan ((es excepts))
                          (and (pair? es)
                               (or (not (memq name (car es)))
                                   (scan (cdr es))))))))))
          ((not (builtin-library? (import-spec-root (car ss))))
           #f)
          (else
           (let* ((spec    (car ss))
                  (aliases (resolve-import spec))
                  (vis     (map car aliases)))
             (loop (cdr ss)
                   (append vis names)
                   (if (and (grants-everything? spec)
                            (not (base-only-path? spec)))
                       (cons (base-except-union spec) excepts)
                       excepts)))))))

    (define (library-body-form? form)
      (and (pair? form) (eq? (car form) 'define)
           (pair? (cdr form)) (symbol? (cadr form))
           (or (memq (cadr form) %import-lib-defs)
               (memq (cadr form) %import-alias-defs))
           #t))

    (define (check-import-scope! forms)
      (when %import-seen?
        (let ((defined (append (top-level-defined forms) %import-lib-defs)))
          (for-each (lambda (form)
                      (unless (library-body-form? form)
                        (check-refs! form '() defined)))
                    forms))))

    ;; Walk core forms collecting free references.  By this point the program is
    ;; quote/if/begin/lambda/set!/define plus application, so `bound` only ever
    ;; grows at a lambda.
    (define (check-refs! form bound defined)
      (cond
        ((symbol? form)
         (unless (or (memq form bound) (import-allows? form defined))
           (error (string-append
                    "paal: unbound variable `" (symbol->string form)
                    "` — no imported library exports it")
                  form)))
        ((not (pair? form)) #t)
        ((eq? (car form) 'quote) #t)
        ((eq? (car form) 'lambda)
         (for-each (lambda (b) (check-refs! b (append (formal-names (cadr form)) bound) defined))
                   (cddr form)))
        ((eq? (car form) 'define)
         (check-refs! (caddr form) bound defined))
        ((eq? (car form) 'set!)
         (check-refs! (caddr form) bound defined))
        (else
         (for-each (lambda (sub) (check-refs! sub bound defined)) form))))

    ;; ---------------------------------------------------------------
    ;; let
    ;; ---------------------------------------------------------------

    ;; ---------------------------------------------------------------
    ;; Syntax checking for binding forms
    ;; ---------------------------------------------------------------
    ;;
    ;; The expander destructures with car/cadr and used to let the host's type
    ;; error escape, so a malformed form was reported as whichever accessor
    ;; happened to fail first — `(let ((a)) a)` came out as "type error in
    ;; 'cadr': expected pair, got ()", which says nothing about the binding.
    ;; These name the form and show it.

    (define (syntax-error* msg form)
      (error (string-append "paal: " msg) form))

    ;; ((name init) ...) — each binding a two-element list with a symbol name.
    (define (check-bindings! bindings form what)
      (unless (list? bindings)
        (syntax-error* (string-append what ": bindings must be a list") form))
      (for-each
        (lambda (b)
          (cond
            ((not (pair? b))
             (syntax-error* (string-append what ": binding must be (name init)") form))
            ((not (symbol? (car b)))
             (syntax-error* (string-append what ": binding name must be a symbol") form))
            ((or (not (pair? (cdr b))) (not (null? (cddr b))))
             (syntax-error*
               (string-append what ": binding needs exactly one init expression")
               form))))
        bindings))

    (define (check-body! body form what)
      (when (null? body)
        (syntax-error* (string-append what ": body must have at least one form")
                       form)))

    (define (check-shape! form what min-len)
      (unless (and (list? form) (>= (length form) min-len))
        (syntax-error* (string-append what ": malformed") form)))

    ;; A do variable spec is (name init) or (name init step) -- not the same
    ;; shape as a let binding, so it needs its own check.
    (define (check-do-specs! specs form)
      (unless (list? specs)
        (syntax-error* "do: variable specs must be a list" form))
      (for-each
        (lambda (spec)
          (cond
            ((not (pair? spec))
             (syntax-error* "do: variable spec must be (name init [step])" form))
            ((not (symbol? (car spec)))
             (syntax-error* "do: variable name must be a symbol" form))
            ((or (not (pair? (cdr spec)))
                 (and (pair? (cddr spec)) (not (null? (cdddr spec)))))
             (syntax-error* "do: variable spec must be (name init [step])" form))))
        specs))

    (define (expand-let form)
      (check-shape! form "let" 3)
      (if (symbol? (cadr form))
          (let* ((name     (cadr form))
                 (bindings (caddr form))
                 (body     (cdddr form))
                 (ignore1  (check-bindings! bindings form "named let"))
                 (ignore2  (check-body! body form "named let"))
                 (params   (map car bindings))
                 (inits    (map cadr bindings)))
            ;; letrec* rather than letrec: with a single binding the two are
            ;; equivalent, and letrec*'s expansion has no temporaries, which
            ;; keeps this — paal's hottest derived form — one layer shallower.
            `(letrec* ((,name (lambda ,params ,@body)))
               (,name ,@inits)))
          (let* ((bindings (cadr form))
                 (body     (cddr form))
                 (ignore1  (check-bindings! bindings form "let"))
                 (ignore2  (check-body! body form "let"))
                 (params   (map car bindings))
                 (inits    (map cadr bindings)))
            `((lambda ,params ,@body) ,@inits))))

    ;; ---------------------------------------------------------------
    ;; let*
    ;; ---------------------------------------------------------------

    (define (expand-let* form)
      (check-shape! form "let*" 3)
      (let ((bindings (cadr form))
            (body     (cddr form)))
        (check-bindings! bindings form "let*")
        (check-body! body form "let*")
        (if (null? bindings)
            `(begin ,@body)
            `(let (,(car bindings))
               (let* ,(cdr bindings) ,@body)))))

    ;; ---------------------------------------------------------------
    ;; letrec / letrec*
    ;; ---------------------------------------------------------------

    ;; letrec* assigns each variable as its init is evaluated, left to right,
    ;; so a later init sees the values of earlier ones.
    (define (expand-letrec* form)
      (check-shape! form "letrec*" 3)
      (let* ((bindings (cadr form))
             (body     (cddr form))
             (ignore1  (check-bindings! bindings form "letrec*"))
             (ignore2  (check-body! body form "letrec*"))
             (names    (map car bindings))
             (inits    (map cadr bindings)))
        `(let ,(map (lambda (n) `(,n #f)) names)
           ,@(map (lambda (n e) `(set! ,n ,e)) names inits)
           ,@body)))

    ;; letrec evaluates every init before assigning any variable (R7RS 4.2.2),
    ;; so the inits land in fresh temporaries first.  An init that reads a
    ;; sibling's *value* is an error under R7RS; here it sees the #f
    ;; placeholder and fails wherever #f is unwelcome, rather than quietly
    ;; getting letrec* semantics.  Mutual recursion is unaffected — lambda
    ;; inits only close over the bindings, which exist from the outer let on.
    (define (expand-letrec form)
      (check-shape! form "letrec" 3)
      (let* ((bindings (cadr form))
             (body     (cddr form))
             (ignore1  (check-bindings! bindings form "letrec"))
             (ignore2  (check-body! body form "letrec"))
             (names    (map car bindings))
             (inits    (map cadr bindings))
             (temps    (map (lambda (n) (fresh-name "__paal_rec")) names)))
        `(let ,(map (lambda (n) `(,n #f)) names)
           (let ,(map (lambda (t e) `(,t ,e)) temps inits)
             ,@(map (lambda (n t) `(set! ,n ,t)) names temps)
             ,@body))))

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
      `(if (%paal-base-not ,(cadr form)) (begin ,@(cddr form))))

    ;; ---------------------------------------------------------------
    ;; cond
    ;; ---------------------------------------------------------------

    ;; else and => are clause keywords only while the use site has not bound
    ;; them as variables — (let ((=> #f)) (cond (#t => 'ok))) is an ordinary
    ;; clause whose second expression happens to be the variable =>, and
    ;; yields 'ok.  A template's marked %core%else / %core%=> always count:
    ;; the macro meant the keyword, whatever its use site binds.  The marked
    ;; spellings are also what the expander's own desugarings emit, so a
    ;; machinery else can never be captured.

    (define %core-else  (core-symbol 'else))
    (define %core-arrow (core-symbol '=>))

    (define (clause-else? x env)
      (or (eq? x %core-else)
          (and (eq? x 'else)
               (let ((d (cenv-lookup env 'else)))
                 (not (and (pair? d) (eq? (car d) 'variable)))))))

    (define (clause-arrow? x env)
      (or (eq? x %core-arrow)
          (and (eq? x '=>)
               (let ((d (cenv-lookup env '=>)))
                 (not (and (pair? d) (eq? (car d) 'variable)))))))

    (define (expand-cond clauses env)
      (if (null? clauses)
          '(if #f #f)
          (let ((clause (car clauses))
                (rest   (cdr clauses)))
            (cond
              ((not (pair? clause))
               (syntax-error* "cond: clause must be a list" clause))
              ((and (clause-else? (car clause) env) (not (null? rest)))
               (syntax-error* "cond: else must be the last clause" clause))
              ((and (clause-else? (car clause) env) (null? (cdr clause)))
               (syntax-error* "cond: else needs at least one expression" clause)))
            (cond
              ((and (pair? clause) (clause-else? (car clause) env))
               `(begin ,@(cdr clause)))
              ((= (length clause) 1)
               `(or ,(car clause) (cond ,@rest)))
              ((and (= (length clause) 3) (clause-arrow? (cadr clause) env))
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

    (define (expand-case form env)
      (check-shape! form "case" 2)
      (check-case-clauses! (cddr form))
      (let ((key     (cadr form))
            (clauses (cddr form))
            (k       (fresh-name "__paal_ck")))
        `(let ((,k ,key))
           (cond ,@(map (lambda (clause) (case-clause k clause env)) clauses)))))

    ;; `case` with `=>` hands the receiver **the key**, not the test value.
    ;; Splicing (cdr clause) into a cond clause got this wrong: cond's own `=>`
    ;; passes the value its test produced, which here is the (memv k ...) result
    ;; — so (case 3 ((3) => (lambda (x) (* x 2)))) multiplied the list (3).
    ;; R7RS 4.2.1 is explicit that it is the key.  So the `=>` clauses are
    ;; rewritten here rather than routed through cond's.
    ;;
    ;; Emitted else clauses are marked %core%else so a use site that bound
    ;; `else` as a variable cannot capture the machinery's.
    (define (case-clause k clause env)
      (cond
        ((and (clause-else? (car clause) env)
              (pair? (cdr clause)) (clause-arrow? (cadr clause) env))
         `(,%core-else (,(caddr clause) ,k)))
        ((clause-else? (car clause) env)
         `(,%core-else ,@(cdr clause)))
        ((and (pair? (cdr clause)) (clause-arrow? (cadr clause) env))
         `((%paal-base-memv ,k ',(car clause)) (,(caddr clause) ,k)))
        (else `((%paal-base-memv ,k ',(car clause)) ,@(cdr clause)))))

    ;; ---------------------------------------------------------------
    ;; quasiquote
    ;; ---------------------------------------------------------------

    ;; Emits the construction calls under %paal-base- spellings: a library
    ;; that defines `list`, `cons` or `append` (SRFI 101 defines all three)
    ;; must not capture the machinery's own emissions when install-library!
    ;; renames its definitions.  Same for case's memv, unless's not,
    ;; case-lambda's destructuring and the record-type layout below.
    (define (expand-qq form depth)
      (cond
        ((vector? form)
         (list '%paal-base-list->vector (expand-qq (vector->list form) depth)))
        ((not (pair? form))
         (list 'quote form))
        ((eq? (car form) 'unquote)
         (if (= depth 0)
             (cadr form)
             (list '%paal-base-list
                   (list 'quote 'unquote)
                   (expand-qq (cadr form) (- depth 1)))))
        ((eq? (car form) 'quasiquote)
         (list '%paal-base-list
               (list 'quote 'quasiquote)
               (expand-qq (cadr form) (+ depth 1))))
        ((and (pair? (car form)) (eq? (caar form) 'unquote-splicing))
         (if (= depth 0)
             (list '%paal-base-append (cadar form) (expand-qq (cdr form) depth))
             (list '%paal-base-cons
                   (list '%paal-base-list (list 'quote 'unquote-splicing)
                               (expand-qq (cadar form) (- depth 1)))
                   (expand-qq (cdr form) depth))))
        (else
         (list '%paal-base-cons
               (expand-qq (car form) depth)
               (expand-qq (cdr form) depth)))))

    ;; ---------------------------------------------------------------
    ;; do
    ;; ---------------------------------------------------------------

    (define (expand-do form)
      (check-shape! form "do" 3)
      (let* ((var-specs  (cadr form))
             (exit-spec  (caddr form))
             (ignore1    (check-do-specs! var-specs form))
             (ignore2    (if (and (pair? exit-spec) (list? exit-spec))
                             #t
                             (syntax-error* "do: exit clause must be (test result ...)"
                                            form)))
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
        ((0) `(%paal-base-car ,args-var))
        ((1) `(%paal-base-cadr ,args-var))
        ((2) `(%paal-base-caddr ,args-var))
        ((3) `(%paal-base-cadddr ,args-var))
        (else `(%paal-base-list-ref ,args-var ,i))))

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
           (reverse (cons (list p `(%paal-base-list-tail ,args-var ,i)) acc))))))

    (define (case-lambda-dispatch args-var clauses)
      (if (null? clauses)
          `(%paal-base-error "case-lambda: no matching arity"
                             (%paal-base-length ,args-var))
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
                 `(if (%paal-base-= (%paal-base-length ,args-var) ,n)
                      (let ,lets ,@body)
                      ,(case-lambda-dispatch args-var (cdr clauses)))))
              ;; At-least-n arity (improper list)
              (else
               (let ((n (proper-length params)))
                 `(if (%paal-base->= (%paal-base-length ,args-var) ,n)
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

    ;; The empty-bindings base is (let () ...), not (begin ...): R7RS 4.2.2
    ;; makes a let-values body a *body*, so a leading definition belongs to it
    ;; — (let*-values () (define x 2) #f) defines its own x — where a begin
    ;; left the define sitting in expression position and the whole form
    ;; failed at emission.
    (define (expand-let-values form)
      (let ((bindings (cadr form))
            (body     (cddr form)))
        (if (null? bindings)
            `(let () ,@body)
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
            `(let () ,@body)
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
    ;;
    ;; R7RS 4.1.7 has include-ci read its files as if they began with
    ;; #!fold-case — and since read-forms-from slurps the file into a string
    ;; port, that is implemented literally: the directive is prepended to the
    ;; text, the host read honours it, and a #!no-fold-case inside the file
    ;; overrides it from that point on, exactly as it would in a file that
    ;; really started with the directive.

    ;; Reads through read-forms-from for the reason given there: passing a
    ;; paal closure to HOST call-with-input-file cannot work under
    ;; self-hosting.
    (define (expand-include paths case-fold?)
      (let ((read-one (if case-fold? read-forms-from-ci read-forms-from)))
        (cons 'begin
              (apply append
                     (map (lambda (p) (read-one (resolve-include-path p)))
                          paths)))))

    ;; ---------------------------------------------------------------
    ;; cond-expand
    ;; ---------------------------------------------------------------

    ;; Clause selection alone, shared with normalize-decls: cond-expand
    ;; appears both as an expression and as a library declaration (R7RS
    ;; 5.6.1), and only what the chosen clause splices into differs.
    (define (cond-expand-select clauses)
      (cond
        ((null? clauses) '())    ; no matching clause and no else → nothing
        ((eq? (caar clauses) 'else) (cdar clauses))
        ((feature-req? (caar clauses)) (cdar clauses))
        (else (cond-expand-select (cdr clauses)))))

    (define (expand-cond-expand form)
      (cons 'begin (cond-expand-select (cdr form))))

    ;; ---------------------------------------------------------------
    ;; Body expansion (internal defines → letrec*)
    ;; ---------------------------------------------------------------

    (define (define->binding d)
      (if (pair? (cadr d))
          (list (caadr d) (cons 'lambda (cons (cdadr d) (cddr d))))
          (list (cadr d) (if (null? (cddr d)) #f (caddr d)))))

    ;; R7RS 5.3.2: definitions may appear inside a `begin` at the head of a
    ;; body, and the `begin` splices into it.  `cond-expand`, `include` and
    ;; `include-ci` all expand to one, so without this
    ;; `(cond-expand (paal (define x 2) x))` inside a body failed at emission
    ;; with `ir:define in expression position` — the definition had been left
    ;; sitting in expression position by a `begin` nobody spliced.
    ;;
    ;; Returns the forms to splice in, or #f if this is not a splicing form.
    ;; The three derived forms are expanded one step here because expand-body
    ;; walks *unexpanded* forms: at this point a cond-expand is still a
    ;; cond-expand, not yet the `begin` it becomes.
    ;; A *macro use* at the head of a body is deliberately not expanded here,
    ;; though R7RS 5.3.2 allows a macro to produce a definition.  Expanding one
    ;; step made `(let () (def x 2) x)` work, but it cannot make the general
    ;; case work and it made the neighbouring case worse: a template that
    ;; *introduces* a definition name gets that name marked `%gref%` — paal
    ;; treats a template's free identifiers as top-level references, and does
    ;; not recognize `define` in a template as a binding position — so the name
    ;; became a letrec* binding that the emitter still resolved as a global, and
    ;; the compile error turned into a runtime `set! on unbound variable`.
    ;;
    ;; It also bought nothing measurable: the R7RS suite scores identically with
    ;; and without it.  Making both shapes work needs the hygiene model changed,
    ;; not this function.
    ;; The head symbol with any %core% mark stripped, or #f for a non-symbol
    ;; head.  Body scanning must treat a template's marked (%core%define ...)
    ;; exactly like a source (define ...): a macro whose template introduces a
    ;; definition instantiates with the keyword marked, and the scan is where
    ;; that definition must be recognized.
    (define (body-head form)
      (and (pair? form)
           (symbol? (car form))
           (let ((h (car form)))
             (or (core-name h) h))))

    (define (body-splice form)
      (and (pair? form)
           (case (body-head form)
             ((begin)       (cdr form))
             ((cond-expand) (cdr (expand-cond-expand form)))
             ((include)     (cdr (expand-include (cdr form) #f)))
             ((include-ci)  (cdr (expand-include (cdr form) #t)))
             (else          #f))))

    ;; The value names a body defines, from a cheap structural scan — enough
    ;; for a body macro's definition environment to know that a name used in
    ;; a template is a sibling definition rather than a top-level reference,
    ;; forward references included (R7RS 5.3.2 regions cover the whole body).
    ;; Head begins are looked through; anything subtler falls back to the
    ;; %gref% default, which is the pre-existing behavior.
    (define (body-defined-names forms)
      (let loop ((fs forms) (acc '()))
        (cond
          ((null? fs) acc)
          ((not (pair? (car fs))) (loop (cdr fs) acc))
          (else
           (let ((f (car fs)))
             (case (body-head f)
               ((define)
                (loop (cdr fs)
                      (cons (if (pair? (cadr f)) (caadr f) (cadr f)) acc)))
               ((define-values)
                (let flatten ((n (cadr f)) (acc acc))
                  (cond ((symbol? n) (loop (cdr fs) (cons n acc)))
                        ((pair? n) (flatten (cdr n)
                                            (if (symbol? (car n))
                                                (cons (car n) acc)
                                                acc)))
                        (else (loop (cdr fs) acc)))))
               ((begin)
                (loop (append (cdr f) (cdr fs)) acc))
               (else (loop (cdr fs) acc))))))))

    ;; The transformer a head symbol denotes inside a body, or #f: a %core%
    ;; mark names the keyword (never a macro), a lexical variable shadows
    ;; everything, a local macro answers through its alias, a %gref% mark
    ;; through the global table it pinned, and otherwise the global table.
    (define (body-macro-transformer head env)
      (and (symbol? head)
           (not (core-name head))
           (let ((d (cenv-lookup env head)))
             (cond
               ((and (pair? d) (eq? (car d) 'macro)) (paal-macro-get (cdr d)))
               ((pair? d) #f)
               ((gref-name head) => (lambda (g) (paal-macro-get g)))
               (else (paal-macro-get head))))))

    (define (expand-body forms env)
      (let loop ((rest forms) (defs '()) (env env))
        (cond
          ((null? rest)
           (if (null? defs)
               (error "paal-expand: empty lambda body")
               (error "paal-expand: lambda body has only definitions")))
          ;; define-values in body: wrap remaining forms in let-values
          ((eq? (body-head (car rest)) 'define-values)
           (let* ((dvform    (car rest))
                  (names     (cadr dvform))
                  (expr      (caddr dvform))
                  (remaining (cdr rest))
                  (wrapped   `(let-values ((,names ,expr)) ,@remaining)))
             (if (null? defs)
                 (list (expand-form wrapped env))
                 (list (expand-form
                         (cons 'letrec*
                           (cons (map define->binding (reverse defs))
                                 (list wrapped)))
                         env)))))
          ((eq? (body-head (car rest)) 'define)
           (loop (cdr rest) (cons (car rest) defs) env))
          ;; A body define-syntax scopes to this body (R7RS 5.3.2): the
          ;; transformer installs under a fresh %mac- alias, the environment
          ;; maps the source name to it for the rest of the scan — the
          ;; hoisted defines re-expand under that environment, so the macro's
          ;; region is the whole body — and the definition environment the
          ;; transformer closes over knows this body's value names, so a
          ;; template may reference a sibling defined later and resolve to
          ;; it rather than to the top level.
          ((eq? (body-head (car rest)) 'define-syntax)
           (let* ((dsform (car rest))
                  (name   (cadr dsform))
                  (spec   (caddr dsform))
                  (alias  (fresh-name
                            (string-append "%mac-" (symbol->string name) "-")))
                  (def-env
                    (cenv-bind-macro
                      (let extend ((ns (body-defined-names forms)) (e env))
                        (if (null? ns)
                            e
                            (extend (cdr ns) (cenv-extend-var e (car ns)))))
                      name alias)))
             (paal-macro-set! alias
               (make-transformer (resolve-transformer-spec spec def-env)
                                 def-env))
             (loop (cdr rest) defs (cenv-bind-macro env name alias))))
          ;; Splice and re-examine, so definitions inside reach the `define`
          ;; arm above and a nested begin unwraps too.
          ((body-splice (car rest))
           => (lambda (spliced) (loop (append spliced (cdr rest)) defs env)))
          ;; A macro use at the head of a body may produce a definition
          ;; (R7RS 5.3.2).  Instantiate exactly one step — no recursive
          ;; expansion, so every node of the output is still expanded once,
          ;; later, in its final position — and re-examine what came out: a
          ;; produced (%core%define ...) reaches the define arm above, a
          ;; produced expression falls through to the else arm on the next
          ;; visit.
          ((body-macro-transformer (body-head (car rest)) env)
           => (lambda (t)
                (loop (cons (t (car rest) env) (cdr rest)) defs env)))
          (else
           (if (null? defs)
               (map (lambda (f) (expand-form f env)) rest)
               (list (expand-form
                       (cons 'letrec*
                         (cons (map define->binding (reverse defs))
                               rest))
                       env)))))))

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

    (define (expand-guard form env)
      (let* ((var-and-clauses (cadr form))
             (var     (car var-and-clauses))
             (clauses (cdr var-and-clauses))
             (body    (cddr form))
             ; An explicit else already handles everything; a second one is an error.
             (has-else? (and (pair? clauses)
                             (let loop ((cs clauses))
                               (cond ((null? (cdr cs))
                                      (and (pair? (car cs))
                                           (clause-else? (caar cs) env)))
                                     (else (loop (cdr cs)))))))
             ; The implicit clause is machinery, so its else is the marked
             ; spelling a use-site binding cannot capture.
             (all-clauses (if has-else?
                              clauses
                              (append clauses
                                      (list (list %core-else
                                                  '%paal-guard-no-match))))))
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

    ;; A case clause is ((datum ...) expr ...) or (else expr ...).  The datum
    ;; list must be a list -- (case x (1 'one)) is the usual slip, and without
    ;; the check it reached memv as a bare atom.
    ;;
    ;; %core%else counts as else: a `case` arriving from a syntax-rules
    ;; template carries its keywords marked, and this validator runs before
    ;; the denotation-aware dispatch that already accepts the mark — checking
    ;; the literal spelling alone rejected every macro that expands to a
    ;; `case` with an else clause (SRFI 67's compare machinery was the find).
    (define (check-case-clauses! clauses)
      (let loop ((cs clauses))
        (unless (null? cs)
          (let ((clause (car cs)))
            (cond
              ((not (pair? clause))
               (syntax-error* "case: clause must be a list" clause))
              ((or (eq? (car clause) 'else)
                   (eq? (car clause) %core-else))
               (when (pair? (cdr cs))
                 (syntax-error* "case: else must be the last clause" clause))
               (when (null? (cdr clause))
                 (syntax-error* "case: else needs at least one expression" clause)))
              ((not (list? (car clause)))
               (syntax-error* "case: clause data must be a list" clause))
              ((null? (cdr clause))
               (syntax-error* "case: clause needs at least one expression" clause)))
            (loop (cdr cs))))))

    (define (check-record-fields! specs form)
      (for-each
        (lambda (spec)
          (cond
            ((not (pair? spec))
             (syntax-error* "define-record-type: field spec must be a list" form))
            ((not (symbol? (car spec)))
             (syntax-error* "define-record-type: field name must be a symbol" form))
            ((or (null? (cdr spec))
                 (and (pair? (cddr spec)) (not (null? (cdddr spec)))))
             (syntax-error*
               "define-record-type: field spec must be (field accessor [modifier])"
               form))))
        specs))

    (define (expand-define-record-type form)
      (check-shape! form "define-record-type" 4)
      (unless (symbol? (cadr form))
        (syntax-error* "define-record-type: type name must be a symbol" form))
      (unless (and (pair? (caddr form)) (symbol? (car (caddr form))))
        (syntax-error* "define-record-type: constructor must be (name field ...)"
                       form))
      (unless (symbol? (cadddr form))
        (syntax-error* "define-record-type: predicate must be a symbol" form))
      (check-record-fields! (cddddr form) form)
      (let* ((type-name   (cadr form))
             (ctor-spec   (caddr form))
             (pred-name   (cadddr form))
             (field-specs (cddddr form))
             (ctor-name   (car ctor-spec))
             (ctor-fields (cdr ctor-spec))
             ;; The record's slots cover every field spec — R7RS 5.5 lets a
             ;; field stay out of the constructor, unspecified until its
             ;; modifier runs (SRFI 64's test-runner is that shape) — so
             ;; indexing goes by the spec list, and the constructor names
             ;; must each appear in it.
             (all-fields  (map car field-specs))
             (n           (length all-fields))
             (tag-var     (string->symbol
                            (string-append "%" (symbol->string type-name) "-tag")))
             (field-idx   (lambda (fname)
                            (let loop ((fs all-fields) (i 1))
                              (cond
                                ((null? fs)
                                 (error "paal: define-record-type: constructor field not among the field names" fname))
                                ((eq? (car fs) fname) i)
                                (else (loop (cdr fs) (+ i 1)))))))
             ;; Fresh, not `v`: the constructor's formals are the user's
             ;; field names, and a field named v captured the machinery's
             ;; vector variable — (make-box2 42) stored the vector into
             ;; itself and answered a circular record.
             (rec-var     (fresh-name "__paal_rec"))
             (ctor-sets   (map (lambda (f)
                                 `(%paal-base-vector-set! ,rec-var
                                                          ,(field-idx f) ,f))
                               ctor-fields))
             (field-defs  (append-map
                            (lambda (spec)
                              (let* ((fname (car spec))
                                     (idx   (field-idx fname))
                                     (acc   (cadr spec))
                                     (mut   (and (pair? (cddr spec)) (caddr spec))))
                                (if mut
                                    `((define (,acc obj)
                                        (%paal-base-vector-ref obj ,idx))
                                      (define (,mut obj val)
                                        (%paal-base-vector-set! obj ,idx val)))
                                    `((define (,acc obj)
                                        (%paal-base-vector-ref obj ,idx))))))
                            field-specs)))
        `(begin
           (define ,tag-var (%paal-base-list (quote ,type-name)))
           (define (,ctor-name ,@ctor-fields)
             (let ((,rec-var (%paal-base-make-vector ,(+ 1 n))))
               (%paal-base-vector-set! ,rec-var 0 ,tag-var)
               ,@ctor-sets
               ,rec-var))
           (define (,pred-name obj)
             (and (%paal-base-vector? obj)
                  (%paal-base-= (%paal-base-vector-length obj) ,(+ 1 n))
                  (%paal-base-eq? (%paal-base-vector-ref obj 0) ,tag-var)))
           ,@field-defs)))

    ))
