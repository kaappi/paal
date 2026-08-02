;;; (kaappi paal lint) — post-compile warnings for `paal check`
;;;
;;; Two lints over emitted bytecode, both warnings and never rejections —
;;; kaappi's invariant, kept here: a valid program is a valid program, and
;;; anything this file is unsure about it stays silent about.
;;;
;;; Unknown top-level variable: a get-global name the program neither
;;; defines (no define-global anywhere in the tree) nor inherits from the
;;; runtime (the caller says what is known, as a predicate — the check
;;; driver hands in the names of a freshly built globals table, which is the
;;; bytecode runtime's real surface, blob definitions included).  Such a
;;; name is a guaranteed unbound-global error if the reference ever runs.
;;;
;;; Arity: a direct call to a program-defined procedure with an argument
;;; count its lambda list cannot accept.  "Direct" is taken literally — the
;;; callee register was loaded by get-global in straight-line code — and
;;; "program-defined" conservatively: the name was define-globald exactly
;;; once in the whole tree, from a closure instruction, and never set!.
;;; Anything cleverer (redefinition, first-class use, control flow between
;;; load and call) drops the tracking rather than risking a false warning.
;;;
;;; Warnings are data, not text:
;;;   (unknown-variable NAME)
;;;   (arity NAME EXPECTED VARIADIC? GOT)
;;; The driver renders them; the suite asserts on them.

(define-library (kaappi paal lint)
  (import (scheme base)
          (kaappi paal bytecode))
  (export paal-lint-program)
  (begin

    ;; Every function in the tree, entry first, breadth-first.
    (define (%all-functions fn)
      (let loop ((queue (list fn)) (acc '()))
        (if (null? queue)
            (reverse acc)
            (let* ((f    (car queue))
                   (code (bytecode-function-code f))
                   (n    (vector-length code)))
              (let scan ((i 0) (children '()))
                (if (= i n)
                    (loop (append (cdr queue) (reverse children))
                          (cons f acc))
                    (let ((instr (vector-ref code i)))
                      (scan (+ i 1)
                            (if (and (pair? instr)
                                     (eq? (car instr) 'closure))
                                (cons (caddr instr) children)
                                children)))))))))

    ;; The register an instruction writes, or #f, or 'all when unknown —
    ;; a shape this table has not heard of invalidates everything rather
    ;; than silently tracking through it.
    (define (%writes instr)
      (if (not (pair? instr))
          'all
          (case (car instr)
            ((load-const load-true load-false load-nil move
              get-global get-upvalue closure)
             (cadr instr))
            ;; A call writes its base — and the callee's frame writes the
            ;; caller's registers above it, so from a tracker's view a call
            ;; invalidates everything.
            ((call tail-call) 'all)
            ((set-global define-global set-upvalue return
              jump jump-if-false halt)
             #f)
            (else 'all))))

    ;; Straight-line register tracking shared by both scans: `track` maps a
    ;; register to what interests the scan (a global name, or a closure's
    ;; function).  Any jump — in either direction, taken or not — clears the
    ;; map, so only unbroken get-global→call (or closure→define-global)
    ;; sequences are ever trusted; that is exactly how the emitter lays out
    ;; direct calls and top-level defines.
    (define (%assq-del alist key)
      (cond ((null? alist) '())
            ((eqv? (car (car alist)) key) (cdr alist))
            (else (cons (car alist) (%assq-del (cdr alist) key)))))

    ;; Pass 1 over one function: define-global facts.
    ;; Answers (defines sets candidates):
    ;;   defines     ((name . count) ...)
    ;;   sets        (name ...)              set-global targets
    ;;   candidates  ((name . fn) ...)       define-global fed by closure
    (define (%scan-defines f defines sets candidates)
      (let ((code (bytecode-function-code f)))
        (let loop ((i 0) (track '())
                   (defines defines) (sets sets) (candidates candidates))
          (if (= i (vector-length code))
              (list defines sets candidates)
              (let ((instr (vector-ref code i)))
                (cond
                  ((and (pair? instr) (eq? (car instr) 'closure))
                   (loop (+ i 1)
                         (cons (cons (cadr instr) (caddr instr))
                               (%assq-del track (cadr instr)))
                         defines sets candidates))
                  ((and (pair? instr) (eq? (car instr) 'define-global))
                   (let* ((name (cadr instr))
                          (src  (caddr instr))
                          (hit  (assq name defines))
                          (fn   (assv src track)))
                     (loop (+ i 1) track
                           (if hit
                               (begin (set-cdr! hit (+ (cdr hit) 1)) defines)
                               (cons (cons name 1) defines))
                           sets
                           (if fn
                               (cons (cons name (cdr fn)) candidates)
                               candidates))))
                  ((and (pair? instr) (eq? (car instr) 'set-global))
                   (loop (+ i 1) track defines
                         (cons (cadr instr) sets) candidates))
                  ((and (pair? instr)
                        (memq (car instr) '(jump jump-if-false)))
                   (loop (+ i 1) '() defines sets candidates))
                  (else
                   (let ((w (%writes instr)))
                     (loop (+ i 1)
                           (cond ((eq? w 'all) '())
                                 (w (%assq-del track w))
                                 (else track))
                           defines sets candidates)))))))))

    ;; Pass 2 over one function: get-global uses and direct-call arities.
    ;; callee-arity: name -> (arity . variadic?) alist for trusted names.
    ;; Answers (uses warnings), uses in first-encounter order (reversed by
    ;; the caller).
    (define (%scan-uses f callee-arity uses warnings)
      (let ((code (bytecode-function-code f)))
        (let loop ((i 0) (track '()) (uses uses) (warnings warnings))
          (if (= i (vector-length code))
              (list uses warnings)
              (let ((instr (vector-ref code i)))
                (cond
                  ((and (pair? instr) (eq? (car instr) 'get-global))
                   (let ((dst (cadr instr)) (name (caddr instr)))
                     (loop (+ i 1)
                           (cons (cons dst name) (%assq-del track dst))
                           (if (memq name uses) uses (cons name uses))
                           warnings)))
                  ((and (pair? instr)
                        (memq (car instr) '(call tail-call)))
                   (let* ((base  (cadr instr))
                          (nargs (caddr instr))
                          (hit   (assv base track))
                          (known (and hit (assq (cdr hit) callee-arity))))
                     (loop (+ i 1)
                           '()   ; a call clobbers registers; start over
                           uses
                           (if (and known
                                    (let ((arity    (car (cdr known)))
                                          (variadic (cdr (cdr known))))
                                      (if variadic
                                          (< nargs arity)
                                          (not (= nargs arity)))))
                               (cons (list 'arity (cdr hit)
                                           (car (cdr known))
                                           (cdr (cdr known))
                                           nargs)
                                     warnings)
                               warnings))))
                  ((and (pair? instr)
                        (memq (car instr) '(jump jump-if-false)))
                   (loop (+ i 1) '() uses warnings))
                  (else
                   (let ((w (%writes instr)))
                     (loop (+ i 1)
                           (cond ((eq? w 'all) '())
                                 (w (%assq-del track w))
                                 (else track))
                           uses warnings)))))))))

    ;; fn: the emitted program.  known?: does the runtime bind this name.
    ;; Answers the warnings, unknown-variable first, in encounter order.
    (define (paal-lint-program fn known?)
      (let ((fns (%all-functions fn)))
        ;; Pass 1: definition facts across the whole tree.
        (let loop ((fs fns) (defines '()) (sets '()) (candidates '()))
          (if (pair? fs)
              (let ((r (%scan-defines (car fs) defines sets candidates)))
                (loop (cdr fs) (car r) (cadr r) (caddr r)))
              (let* ((defined? (lambda (name) (assq name defines)))
                     ;; Trust a candidate only if its name was defined once
                     ;; and never assigned.
                     (callee-arity
                       (let keep ((cs candidates) (acc '()))
                         (cond
                           ((null? cs) acc)
                           ((let ((name (car (car cs))))
                              (and (= 1 (cdr (assq name defines)))
                                   (not (memq name sets))
                                   (not (assq name acc))))
                            (keep (cdr cs)
                                  (cons (cons (car (car cs))
                                              (cons (bytecode-function-arity
                                                      (cdr (car cs)))
                                                    (bytecode-function-variadic?
                                                      (cdr (car cs)))))
                                        acc)))
                           (else (keep (cdr cs) acc))))))
                ;; Pass 2: uses and arity checks.
                (let scan ((fs fns) (uses '()) (warnings '()))
                  (if (pair? fs)
                      (let ((r (%scan-uses (car fs) callee-arity
                                           uses warnings)))
                        (scan (cdr fs) (car r) (cadr r)))
                      (append
                        (let unknowns ((us (reverse uses)) (acc '()))
                          (cond
                            ((null? us) (reverse acc))
                            ((or (defined? (car us)) (known? (car us)))
                             (unknowns (cdr us) acc))
                            (else
                             (unknowns (cdr us)
                                       (cons (list 'unknown-variable (car us))
                                             acc)))))
                        (reverse warnings)))))))))))
