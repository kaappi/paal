;;; (kaappi paal vm) — Bootstrap VM: tree-walking interpreter over IR
;;;
;;; Stage 4 of the Paal compilation pipeline.
;;; Evaluates IR nodes against an environment.
;;;
;;; Environment entries are mutable vector boxes (cons name #(val)) so
;;; that top-level defines are visible to recursive closures and set!
;;; works correctly.
;;;
;;; Tail calls use a tagged-thunk trampoline.  paal-eval takes a tail?
;;; flag; when #t and the node is ir:call, it returns a thunk instead of
;;; applying immediately.  The trampoline in paal-eval-program (and at
;;; every non-tail call site) forces thunks until a plain value emerges,
;;; bounding stack depth to O(1) per tail call.
;;;
;;; This tree-walking interpreter is the bootstrap VM.  It will be
;;; replaced by a bytecode emitter + register-based VM.

(define-library (kaappi paal vm)
  (import (scheme base) (scheme read) (kaappi paal ir))
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
    ;; Handles proper lists, pure variadic (symbol params), and
    ;; improper lists (x y . rest) via the recursive else branch.
    (define (env-bind env params args rest?)
      (cond
        ((and rest? (symbol? params))
         (env-extend env params args))
        ((null? params) env)
        (else
         (env-bind (env-extend env (car params) (car args))
                   (cdr params) (cdr args) rest?))))

    ;; --- Scheme-implemented gensym (kaappi has no built-in) ---

    (define %paal-gensym-counter 0)
    (define (paal-gensym)
      (set! %paal-gensym-counter (+ %paal-gensym-counter 1))
      (string->symbol
        (string-append "__paal_" (number->string %paal-gensym-counter))))

    ;; --- Promise tag (HOST side) ---
    ;; Unique pair used to tag paal promise vectors in the tree-walking VM.
    ;; The bytecode VM path allocates its own tag in pkaappi-make-globals.

    (define %paal-promise-tag (list 'paal-promise-tag))

    ;; --- Parameter cell key (HOST side) ---
    ;; Passing this to a parameter object returns its underlying cell.  Unique
    ;; and unexported, so only make-parameter and %paal-parameterize can ask.

    (define %paal-param-key (list 'paal-param-key))

    ;; --- Command-line for user programs ---
    ;; Set by pkaappi-set-command-line! before running a user file.
    ;; The paal-initial-env binds (command-line) to read this variable.

    (define %paal-command-line '())

    ;; --- Initial environment seeded with host primitives ---

    (define (paal-initial-env)
      (map (lambda (pair) (cons (car pair) (vector (cdr pair))))
           `(;; Arithmetic
             (+ . ,+) (- . ,-) (* . ,*) (/ . ,/)
             (= . ,=) (< . ,<) (> . ,>) (<= . ,<=) (>= . ,>=)
             (abs . ,abs) (max . ,max) (min . ,min)
             (floor . ,floor) (ceiling . ,ceiling)
             (truncate . ,truncate) (round . ,round)
             (expt . ,expt) (sqrt . ,sqrt)
             (modulo . ,modulo) (remainder . ,remainder) (quotient . ,quotient)
             (gcd . ,gcd) (lcm . ,lcm)
             (exact . ,exact) (inexact . ,inexact)
             (exact? . ,exact?) (inexact? . ,inexact?)
             (zero? . ,zero?) (positive? . ,positive?) (negative? . ,negative?)
             (odd? . ,odd?) (even? . ,even?)
             (number->string . ,number->string) (string->number . ,string->number)

             ;; Booleans
             (not . ,not) (boolean? . ,boolean?) (boolean=? . ,boolean=?)

             ;; Equivalence
             (eq? . ,eq?) (eqv? . ,eqv?) (equal? . ,equal?)

             ;; Pairs and lists
             (cons . ,cons) (car . ,car) (cdr . ,cdr) (list . ,list)
             (null? . ,null?) (pair? . ,pair?) (list? . ,list?)
             (length . ,length) (append . ,append) (reverse . ,reverse)
             (list-tail . ,list-tail) (list-ref . ,list-ref)
             (list-copy . ,list-copy)
             (assq . ,assq) (assv . ,assv) (assoc . ,assoc)
             (memq . ,memq) (memv . ,memv) (member . ,member)
             (caar . ,caar) (cadr . ,cadr) (cdar . ,cdar) (cddr . ,cddr)
             (caaar . ,caaar) (caadr . ,caadr) (cadar . ,cadar) (caddr . ,caddr)
             (cdaar . ,cdaar) (cdadr . ,cdadr) (cddar . ,cddar) (cdddr . ,cdddr)
             ;; 4-level c*r combinations (needed by paal-analyze for (if t c a))
             (caaaar . ,caaaar) (caaadr . ,caaadr) (caadar . ,caadar) (caaddr . ,caaddr)
             (cadaar . ,cadaar) (cadadr . ,cadadr) (caddar . ,caddar) (cadddr . ,cadddr)
             (cdaaar . ,cdaaar) (cdaadr . ,cdaadr) (cdadar . ,cdadar) (cdaddr . ,cdaddr)
             (cddaar . ,cddaar) (cddadr . ,cddadr) (cdddar . ,cdddar) (cddddr . ,cddddr)
             (set-car! . ,set-car!) (set-cdr! . ,set-cdr!)

             ;; Vectors
             (vector . ,vector) (make-vector . ,make-vector)
             (vector-ref . ,vector-ref) (vector-set! . ,vector-set!)
             (vector-length . ,vector-length) (vector? . ,vector?)
             (vector->list . ,vector->list) (list->vector . ,list->vector)
             (vector-fill! . ,vector-fill!) (vector-copy . ,vector-copy)
             (vector-copy! . ,vector-copy!) (vector-append . ,vector-append)

             ;; Strings
             (string? . ,string?) (string . ,string) (make-string . ,make-string)
             (string-length . ,string-length) (string-ref . ,string-ref)
             (string-copy . ,string-copy) (string-append . ,string-append)
             (string->list . ,string->list) (list->string . ,list->string)
             (string->symbol . ,string->symbol) (symbol->string . ,symbol->string)
             (string-upcase . ,string-upcase) (string-downcase . ,string-downcase)
             (string=? . ,string=?) (string<? . ,string<?)
             (string>? . ,string>?) (string<=? . ,string<=?) (string>=? . ,string>=?)
             (substring . ,substring)
             (string->number . ,string->number) (number->string . ,number->string)

             ;; Symbols
             (symbol? . ,symbol?) (symbol=? . ,symbol=?)
             (gensym . ,paal-gensym)

             ;; Characters
             (char? . ,char?)
             (char->integer . ,char->integer) (integer->char . ,integer->char)
             (char-alphabetic? . ,char-alphabetic?) (char-numeric? . ,char-numeric?)
             (char-whitespace? . ,char-whitespace?)
             (char-upper-case? . ,char-upper-case?) (char-lower-case? . ,char-lower-case?)
             (char-upcase . ,char-upcase) (char-downcase . ,char-downcase)
             (char=? . ,char=?) (char<? . ,char<?) (char>? . ,char>?)
             (char<=? . ,char<=?) (char>=? . ,char>=?)

             ;; Type predicates
             (number? . ,number?) (integer? . ,integer?) (real? . ,real?)
             (rational? . ,rational?) (complex? . ,complex?)
             (procedure? . ,procedure?)

             ;; I/O
             (display . ,display) (newline . ,newline) (write . ,write)
             (read . ,read) (read-char . ,read-char) (peek-char . ,peek-char)
             (write-char . ,write-char) (write-string . ,write-string)
             (read-line . ,read-line) (read-string . ,read-string)
             (eof-object? . ,eof-object?) (eof-object . ,eof-object)
             (char-ready? . ,char-ready?)
             (open-input-string . ,open-input-string)
             (open-output-string . ,open-output-string)
             (get-output-string . ,get-output-string)
             (open-input-file . ,open-input-file)
             (open-output-file . ,open-output-file)
             (close-input-port . ,close-input-port)
             (close-output-port . ,close-output-port)
             (current-input-port . ,current-input-port)
             (current-output-port . ,current-output-port)
             (current-error-port . ,current-error-port)
             (input-port? . ,input-port?) (output-port? . ,output-port?)
             (port? . ,port?)
             (flush-output-port . ,flush-output-port)
             (call-with-port . ,call-with-port)

             ;; Control
             (apply . ,apply) (map . ,map) (for-each . ,for-each)
             (values . ,values)
             ; A paal producer whose body is a tail call returns a trampoline
             ; thunk rather than its values, so force it in a multiple-value
             ; context before handing anything to the consumer.  Without this,
             ; the consumer is applied to the thunk itself as a single argument.
             (call-with-values . ,(lambda (producer consumer)
                                    (call-with-values
                                      (lambda () (trampoline-values (producer)))
                                      consumer)))
             (call-with-current-continuation . ,call-with-current-continuation)
             (call/cc . ,call/cc)
             (dynamic-wind . ,dynamic-wind)

             ;; Exceptions
             (error . ,error)
             ;; Both calls trampolined, and the thunk *inside* the handler's
             ;; extent: a paal lambda whose body is a tail call returns a thunk,
             ;; so an unforced (raise-continuable x) would happen after the
             ;; handler had been uninstalled.  The handler's own result is
             ;; forced too — for raise-continuable it becomes the value of the
             ;; raise, so it must be a value and not a thunk.
             (with-exception-handler
               . ,(lambda (handler thunk)
                    (with-exception-handler
                      (lambda (e) (trampoline (handler e)))
                      (lambda () (trampoline (thunk))))))
             (raise . ,raise) (raise-continuable . ,raise-continuable)
             ;; Target of the expander's `guard` desugaring.  Tree-walking closures
             ;; are HOST procedures, so body and handler are directly callable here;
             ;; the bytecode pipeline handles the marker in do-call! instead.
             ;;
             ;; Both calls must be trampolined *inside* the guard.  A paal lambda
             ;; whose body is a tail call returns a thunk rather than its value, so
             ;; returning that thunk unforced would defer the body's real work until
             ;; after the guard's dynamic extent had exited — and any exception it
             ;; raised would escape uncaught.
             (%paal-guard-run . ,(lambda (body handler)
                                   (guard (e (#t (trampoline (handler e))))
                                     (trampoline (body)))))
             (error-object? . ,error-object?)
             (error-object-message . ,error-object-message)
             (error-object-irritants . ,error-object-irritants)

             ;; Bytevectors
             (bytevector? . ,bytevector?) (make-bytevector . ,make-bytevector)
             (bytevector . ,bytevector) (bytevector-length . ,bytevector-length)
             (bytevector-u8-ref . ,bytevector-u8-ref)
             (bytevector-u8-set! . ,bytevector-u8-set!)
             (bytevector-copy . ,bytevector-copy)
             (bytevector-append . ,bytevector-append)

             ;; Arithmetic — R7RS extras
             (exact-integer? . ,exact-integer?)
             (square . ,square)
             (finite? . ,finite?) (infinite? . ,infinite?) (nan? . ,nan?)
             (floor/ . ,floor/) (floor-quotient . ,floor-quotient) (floor-remainder . ,floor-remainder)
             (truncate/ . ,truncate/) (truncate-quotient . ,truncate-quotient) (truncate-remainder . ,truncate-remainder)
             (numerator . ,numerator) (denominator . ,denominator)
             (exact-integer-sqrt . ,exact-integer-sqrt)

             ;; Lists — R7RS extras
             (make-list . ,make-list) (list-set! . ,list-set!)

             ;; Strings — R7RS extras (non-HOF)
             (string-set! . ,string-set!)
             (string-copy! . ,string-copy!)
             (string-fill! . ,string-fill!)
             (string->utf8 . ,string->utf8) (utf8->string . ,utf8->string)
             (string->vector . ,string->vector) (vector->string . ,vector->string)

             ;; Bytevectors — R7RS extras
             (bytevector-copy! . ,bytevector-copy!)

             ;; Ports — R7RS extras
             (close-port . ,close-port)
             (textual-port? . ,textual-port?) (binary-port? . ,binary-port?)
             (input-port-open? . ,input-port-open?) (output-port-open? . ,output-port-open?)

             ;; Binary I/O
             (read-u8 . ,read-u8) (peek-u8 . ,peek-u8)
             (u8-ready? . ,u8-ready?) (write-u8 . ,write-u8)

             ;; File operations
             (file-exists? . ,file-exists?)
             (delete-file . ,delete-file)
             (call-with-input-file . ,call-with-input-file)
             (call-with-output-file . ,call-with-output-file)
             (with-input-from-file . ,with-input-from-file)
             (with-output-to-file . ,with-output-to-file)
             (open-binary-input-file . ,open-binary-input-file)
             (open-binary-output-file . ,open-binary-output-file)

             ;; Exception predicates
             (read-error? . ,read-error?) (file-error? . ,file-error?)

             ;; Parameters
             ;;
             ;; Not HOST make-parameter: a HOST parameter can only be rebound by
             ;; HOST `parameterize`, which is syntax, so there is no procedural
             ;; way for %paal-parameterize to install a value into one.  These
             ;; parameters are closures over a 2-slot cell #(value converter)
             ;; instead; %paal-param-key retrieves the cell.  The bytecode
             ;; pipeline installs a paal-compiled equivalent over the top.
             ;;
             ;; Converter and thunk may be paal lambdas, which return trampoline
             ;; thunks rather than values, so each call is forced — and the body
             ;; is forced *inside* the guard, so a raise cannot escape the
             ;; restore. Same reasoning as %paal-guard-run above.
             (make-parameter
               . ,(lambda (init . rest)
                    (let* ((conv (if (null? rest) (lambda (x) x) (car rest)))
                           (cell (vector (trampoline (conv init)) conv)))
                      (lambda args
                        (cond
                          ((null? args) (vector-ref cell 0))
                          ((eq? (car args) %paal-param-key) cell)
                          (else (error "parameter: unexpected argument")))))))
             (%paal-parameterize
               . ,(lambda (params vals thunk)
                    (let* ((cells (map (lambda (p) (p %paal-param-key)) params))
                           (olds  (map (lambda (c) (vector-ref c 0)) cells))
                           (restore (lambda ()
                                      (for-each (lambda (c v) (vector-set! c 0 v))
                                                cells olds))))
                      (for-each (lambda (c v)
                                  (vector-set! c 0
                                               (trampoline ((vector-ref c 1) v))))
                                cells vals)
                      (let ((result (guard (e (#t (restore) (raise e)))
                                      (trampoline (thunk)))))
                        (restore)
                        result))))

             ;; Features
             (features . ,features)

             ;; Write extras
             (write-shared . ,write-shared) (write-simple . ,write-simple)

             ;; Promises — custom vector-based implementation so that delay/force
             ;; work correctly in the tree-walking VM.  (The bytecode VM path in
             ;; pkaappi-make-globals installs separate paal-compiled versions.)
             (%paal-delay-impl . ,(lambda (thunk)
               (let ((v (make-vector 3)))
                 (vector-set! v 0 %paal-promise-tag)
                 (vector-set! v 1 #f)
                 (vector-set! v 2 thunk)
                 v)))
             (promise? . ,(lambda (x)
               (and (vector? x) (= (vector-length x) 3)
                    (eq? (vector-ref x 0) %paal-promise-tag))))
             (make-promise . ,(lambda (x)
               (if (and (vector? x) (= (vector-length x) 3)
                        (eq? (vector-ref x 0) %paal-promise-tag))
                   x
                   (let ((v (make-vector 3)))
                     (vector-set! v 0 %paal-promise-tag)
                     (vector-set! v 1 #t)
                     (vector-set! v 2 x)
                     v))))
             (force . ,(lambda (p)
               (if (not (and (vector? p) (= (vector-length p) 3)
                             (eq? (vector-ref p 0) %paal-promise-tag)))
                   p
                   (if (vector-ref p 1)
                       (vector-ref p 2)
                       (let ((r ((vector-ref p 2))))
                         (vector-set! p 1 #t)
                         (vector-set! p 2 r)
                         r)))))

             ;; Inexact math — (scheme inexact)
             (sin . ,sin) (cos . ,cos) (tan . ,tan)
             (asin . ,asin) (acos . ,acos) (atan . ,atan)
             (exp . ,exp) (log . ,log)

             ;; Characters — case-insensitive (scheme char)
             (char-ci=? . ,char-ci=?) (char-ci<? . ,char-ci<?)
             (char-ci>? . ,char-ci>?) (char-ci<=? . ,char-ci<=?) (char-ci>=? . ,char-ci>=?)
             (char-foldcase . ,char-foldcase)

             ;; Strings — case-insensitive (scheme char)
             (string-ci=? . ,string-ci=?) (string-ci<? . ,string-ci<?)
             (string-ci>? . ,string-ci>?) (string-ci<=? . ,string-ci<=?) (string-ci>=? . ,string-ci>=?)
             (string-foldcase . ,string-foldcase)
             (digit-value . ,digit-value)

             ;; Time — (scheme time)
             (current-second . ,current-second)
             (current-jiffy . ,current-jiffy)
             (jiffies-per-second . ,jiffies-per-second)

             ;; Process context — (scheme process-context)
             ;; command-line is overridden in pkaappi-make-globals to return user args.
             ;; The HOST command-line is intentionally not exposed here.
             (command-line . ,(lambda () %paal-command-line))
             (exit . ,exit) (emergency-exit . ,emergency-exit)
             (get-environment-variable . ,get-environment-variable)
             (get-environment-variables . ,get-environment-variables)

             ;; Misc
             (void . ,(lambda () (if #f #f)))
             (not . ,not))))

    ;; --- Trampoline machinery ---
    ;;
    ;; A thunk is (cons %thunk-tag procedure).  The tag is a unique pair
    ;; (allocated once) so thunk? is a single eq? check.

    (define %thunk-tag (list 'paal-thunk))

    (define (make-thunk proc)   (cons %thunk-tag proc))
    (define (thunk? x)          (and (pair? x) (eq? (car x) %thunk-tag)))
    (define (thunk-force t)     ((cdr t)))

    (define (trampoline v)
      (let loop ((v v))
        (if (thunk? v) (loop (thunk-force v)) v)))

    ;; Like trampoline, but preserves multiple values from the final call.
    ;;
    ;; trampoline forces in a single-value context, which is fine for ordinary
    ;; calls but destroys a (values ...) produced in tail position.  Forcing
    ;; inside call-with-values keeps every value the last thunk yields; a lone
    ;; value that is itself a thunk means the trampoline has another hop to make.
    (define (trampoline-values v)
      (if (thunk? v)
          (call-with-values (lambda () (thunk-force v))
            (lambda vals
              (if (and (pair? vals) (null? (cdr vals)) (thunk? (car vals)))
                  (trampoline-values (car vals))
                  (apply values vals))))
          v))

    ;; --- Evaluator ---
    ;;
    ;; tail? = #t  → ir:call returns a thunk (O(1) tail call)
    ;; tail? = #f  → ir:call forces via trampoline before returning
    ;;
    ;; Tail positions: both arms of ir:if, last expr of ir:begin,
    ;;   lambda body, top-level exprs in paal-eval-program.
    ;; Non-tail: ir:if test, ir:call args, ir:set! val, ir:define val.

    (define (paal-eval node env tail?)
      (cond
        ((ir:const?  node) (ir:const-val node))
        ((ir:ref?    node) (env-lookup env (ir:ref-name node)))
        ((ir:if?     node)
         (if (paal-eval (ir:if-test node) env #f)
             (paal-eval (ir:if-then node) env tail?)
             (paal-eval (ir:if-else node) env tail?)))
        ((ir:begin?  node)
         (let ((exprs (ir:begin-exprs node)))
           (if (null? exprs)
               #f
               (let loop ((exprs exprs))
                 (if (null? (cdr exprs))
                     (paal-eval (car exprs) env tail?)
                     (begin
                       (paal-eval (car exprs) env #f)
                       (loop (cdr exprs))))))))
        ((ir:lambda? node)
         (let ((params (ir:lambda-params node))
               (body   (ir:lambda-body  node))
               (rest?  (ir:lambda-rest? node)))
           ;; Lambda body is always in tail position relative to its call.
           (lambda args
             (paal-eval body (env-bind env params args rest?) #t))))
        ((ir:set!? node)
         (env-set! env (ir:set!-name node)
                       (paal-eval (ir:set!-val node) env #f)))
        ((ir:define? node)
         (error "paal: define used as expression — use paal-eval-program"))
        ((ir:call? node)
         (let ((proc (paal-eval (ir:call-proc node) env #f))
               (args (map (lambda (a) (paal-eval a env #f))
                          (ir:call-args node))))
           (if tail?
               (make-thunk (lambda () (apply proc args)))
               (trampoline (apply proc args)))))
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
                         (box  (vector #f))
                         (env* (cons (cons name box) env))
                         (val  (trampoline (paal-eval (ir:define-val node) env* #f))))
                    (vector-set! box 0 val)
                    (loop (cdr ns) env* val))
                  (loop (cdr ns) env
                        (trampoline (paal-eval node env #t))))))))))
