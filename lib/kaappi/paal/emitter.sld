;;; (kaappi paal emitter) — IR → bytecode compiler
;;;
;;; Converts IR node trees produced by (kaappi paal compiler) into
;;; bytecode-function objects executable by (kaappi paal vm-bc).
;;;
;;; Two-pass compilation:
;;;   Pass 1: emit instructions with symbolic jump labels
;;;   Pass 2: resolve labels to relative integer offsets
;;;
;;; Name resolution (innermost wins):
;;;   local register   — lambda parameter or let-bound local
;;;   upvalue          — captured from an enclosing lambda
;;;   global           — top-level define or initial-env binding

(define-library (kaappi paal emitter)
  (import (scheme base) (kaappi paal ir) (kaappi paal bytecode)
          (kaappi paal expander))
  (export paal-emit-program)
  (begin

    ;; ---------------------------------------------------------------
    ;; Emitter state (mutable vector)
    ;; ---------------------------------------------------------------
    ;; [0] parent emitter or #f
    ;; [1] code: list of instructions (in order)
    ;; [2] upvalues: list of (is-local? . source-index)
    ;; [3] next-reg: next allocatable register index
    ;; [4] arity: number of required parameters
    ;; [5] variadic?: boolean
    ;; [6] locals: alist (name . reg)
    ;; [7] label-counter: integer (per-emitter)

    (define (make-emitter parent params variadic?)
      (let* ((fixed    (if (list? params) params
                           (if (pair? params) (proper-list params) '())))
             (rest-sym (if (list? params) #f
                           (if (pair? params) (last-pair-cdr params)
                               (if (symbol? params) params #f))))
             (arity    (length fixed))
             ; Parameters occupy registers 0 .. arity-1 (+ arity for rest if any)
             (locals   (let loop ((ps fixed) (i 0) (acc '()))
                         (if (null? ps)
                             (if rest-sym
                                 (cons (cons rest-sym arity) acc)
                                 acc)
                             (loop (cdr ps) (+ i 1) (cons (cons (car ps) i) acc)))))
             (next-r   (+ arity (if rest-sym 1 0))))
        ; [8] boxed-locals: alist (name . box-reg) for mutable captured params
        (vector parent '() '() next-r arity variadic? locals 0 '())))

    (define (proper-list p)
      (if (pair? p) (cons (car p) (proper-list (cdr p))) '()))

    (define (last-pair-cdr p)
      (if (pair? (cdr p)) (last-pair-cdr (cdr p)) (cdr p)))

    ;; Accessors / mutators

    (define (e-parent e)          (vector-ref e 0))
    (define (e-code e)            (vector-ref e 1))
    (define (e-upvalues e)        (vector-ref e 2))
    (define (e-next-reg e)        (vector-ref e 3))
    (define (e-arity e)           (vector-ref e 4))
    (define (e-variadic? e)       (vector-ref e 5))
    (define (e-locals e)          (vector-ref e 6))
    (define (e-label-counter e)   (vector-ref e 7))
    (define (e-boxed e)           (vector-ref e 8))

    (define (e-add-boxed! e name box-reg)
      (vector-set! e 8 (cons (cons name box-reg) (vector-ref e 8))))

    (define (e-emit! e instr)
      (vector-set! e 1 (append (vector-ref e 1) (list instr))))

    (define (e-alloc-reg! e)
      (let ((r (vector-ref e 3)))
        (vector-set! e 3 (+ r 1))
        r))

    (define (e-free-reg! e)
      (vector-set! e 3 (- (vector-ref e 3) 1)))

    (define (e-fresh-label! e)
      (let ((n (vector-ref e 7)))
        (vector-set! e 7 (+ n 1))
        (string->symbol (string-append "L" (number->string n)))))

    (define (e-add-local! e name reg)
      (vector-set! e 6 (cons (cons name reg) (vector-ref e 6))))

    (define (e-code-pos e) (length (vector-ref e 1)))

    ;; ---------------------------------------------------------------
    ;; Name resolution
    ;; ---------------------------------------------------------------

    ;; Returns (local . reg), (local-boxed . box-reg),
    ;;         (upvalue . idx), (upvalue-boxed . idx), or (global . sym)
    (define (resolve e name)
      (cond
        ((assq name (e-locals e))
         => (lambda (pair)
              (let ((box-entry (assq name (e-boxed e))))
                (if box-entry
                    (cons 'local-boxed (cdr box-entry))
                    (cons 'local (cdr pair))))))
        (else
         (let ((uv (capture-upvalue! e name)))
           (if uv
               (let* ((uv-entry (list-ref (e-upvalues e) uv))
                      (boxed?   (cadddr uv-entry)))
                 (if boxed? (cons 'upvalue-boxed uv) (cons 'upvalue uv)))
               (cons 'global name))))))

    ;; Try to capture name from parent chain; returns upvalue index or #f.
    ;; Recursively walks ancestors so that multi-level upvalue capture works
    ;; even when an intermediate lambda hasn't yet compiled its own reference
    ;; to the variable (which happens when callees are compiled before args).
    ;; Propagates is-boxed? through the chain so child emitters know whether
    ;; upvalue accesses need box-ref / box-set! indirection.
    (define (capture-upvalue! e name)
      (let ((parent (e-parent e)))
        (and parent
             (let ((res (resolve-in e name parent)))
               (if res
                   (let* ((tag       (car res))
                          (src-idx   (cadr res))
                          (is-boxed? (caddr res))
                          (is-local? (or (eq? tag 'local) (eq? tag 'local-boxed))))
                     (add-upvalue! e name is-local? src-idx is-boxed?))
                   ; Not found in parent's locals or current upvalues.
                   ; Force upvalue addition through the ancestor chain.
                   (let ((ancestor-idx (capture-upvalue! parent name)))
                     (and ancestor-idx
                          (let* ((parent-uv (list-ref (e-upvalues parent) ancestor-idx))
                                 (is-boxed? (cadddr parent-uv)))
                            (add-upvalue! e name #f ancestor-idx is-boxed?)))))))))

    ;; Resolve name in the context of a child's parent.
    ;; Returns (tag src-or-idx is-boxed?) or #f.
    ;;   tag: local | local-boxed | upvalue
    (define (resolve-in child name parent)
      (cond
        ((assq name (e-locals parent))
         => (lambda (pair)
              (let ((box-entry (assq name (e-boxed parent))))
                (if box-entry
                    (list 'local-boxed (cdr box-entry) #t)
                    (list 'local (cdr pair) #f)))))
        (else
         (let loop ((uvs (e-upvalues parent)) (i 0))
           (cond
             ((null? uvs) #f)
             ((eq? (caar uvs) name)
              ; Inherit is-boxed? from parent's upvalue entry (4th element)
              (list 'upvalue i (cadddr (car uvs))))
             (else (loop (cdr uvs) (+ i 1))))))))

    ;; Register a new upvalue in e; return its index.
    ;; Each upvalue entry: (name is-local? src-idx is-boxed?)
    (define (add-upvalue! e name is-local? src-idx is-boxed?)
      (let ((existing (let loop ((uvs (e-upvalues e)) (i 0))
                        (cond
                          ((null? uvs) #f)
                          ((eq? (caar uvs) name) i)
                          (else (loop (cdr uvs) (+ i 1)))))))
        (or existing
            (let ((idx (length (e-upvalues e))))
              (vector-set! e 2
                (append (vector-ref e 2)
                        (list (list name is-local? src-idx is-boxed?))))
              idx))))

    ;; ---------------------------------------------------------------
    ;; Label resolution (pass 2)
    ;; ---------------------------------------------------------------

    (define (resolve-labels instrs)
      ; Build label-name → instruction-index map (labels removed from code)
      (let* ((filtered (filter (lambda (i) (not (eq? (car i) 'label))) instrs))
             (label-map
               (let loop ((raw instrs) (pos 0) (acc '()))
                 (if (null? raw) acc
                     (if (eq? (caar raw) 'label)
                         (loop (cdr raw) pos (cons (cons (cadr (car raw)) pos) acc))
                         (loop (cdr raw) (+ pos 1) acc))))))
        (list->vector
          (map (lambda (instr pos)
                 (define (resolve-label lbl)
                   (let ((entry (assq lbl label-map)))
                     (if entry
                         (- (cdr entry) pos 1)
                         (error "paal-emitter: undefined label" lbl))))
                 (case (car instr)
                   ((jump)          `(jump ,(resolve-label (cadr instr))))
                   ((jump-if-false) `(jump-if-false ,(cadr instr)
                                                    ,(resolve-label (caddr instr))))
                   (else instr)))
               filtered
               (let loop ((i 0) (n (length filtered)) (acc '()))
                 (if (= i n) (reverse acc) (loop (+ i 1) n (cons i acc))))))))

    ;; ---------------------------------------------------------------
    ;; Finalize emitter → bytecode-function
    ;; ---------------------------------------------------------------

    (define (finalize! e name)
      (make-bytecode-function
        (resolve-labels (e-code e))
        (e-arity e)
        (e-variadic? e)
        (length (e-upvalues e))
        name))

    ;; ---------------------------------------------------------------
    ;; Emit helpers
    ;; ---------------------------------------------------------------

    (define (emit-const! e val dst)
      (cond
        ((eq? val #t)   (e-emit! e `(load-true  ,dst)))
        ((eq? val #f)   (e-emit! e `(load-false ,dst)))
        ((null? val)    (e-emit! e `(load-nil   ,dst)))
        (else           (e-emit! e `(load-const ,dst ,val)))))

    (define (emit-ref! e name dst)
      ;; A %gref% identifier came from a macro template's free position, so it
      ;; must resolve where the macro was defined — the top level — rather than
      ;; through whatever locals the use site introduced.
      (let ((g (gref-name name)))
        (if g
            (e-emit! e `(get-global ,dst ,g))
            (emit-local-ref! e name dst))))

    (define (emit-local-ref! e name dst)
      (let ((res (resolve e name)))
        (case (car res)
          ((local)
           (let ((src (cdr res)))
             (unless (= src dst)
               (e-emit! e `(move ,dst ,src)))))
          ((local-boxed)
           (e-emit! e `(box-ref ,dst ,(cdr res))))
          ((upvalue)
           (e-emit! e `(get-upvalue ,dst ,(cdr res))))
          ((upvalue-boxed)
           (let ((tmp (e-alloc-reg! e)))
             (e-emit! e `(get-upvalue ,tmp ,(cdr res)))
             (e-emit! e `(box-ref ,dst ,tmp))
             (e-free-reg! e)))
          ((global)
           (e-emit! e `(get-global ,dst ,(cdr res)))))))

    ;; ---------------------------------------------------------------
    ;; Core compiler: emit-node!
    ;; ---------------------------------------------------------------

    (define (emit-node! e node dst tail?)
      (cond

        ((ir:const? node)
         (emit-const! e (ir:const-val node) dst))

        ((ir:ref? node)
         (emit-ref! e (ir:ref-name node) dst))

        ((ir:if? node)
         (let* ((test-reg (e-alloc-reg! e))
                (else-lbl (e-fresh-label! e))
                (end-lbl  (e-fresh-label! e)))
           (emit-node! e (ir:if-test node) test-reg #f)
           (e-emit! e `(jump-if-false ,test-reg ,else-lbl))
           (e-free-reg! e)
           (emit-node! e (ir:if-then node) dst tail?)
           ; Always jump over the else branch.
           ; When tail?=#t and then ends with tail-call, this is dead code
           ; but necessary for non-call then-branches (e.g. literal values).
           (e-emit! e `(jump ,end-lbl))
           (e-emit! e `(label ,else-lbl))
           (emit-node! e (ir:if-else node) dst tail?)
           (e-emit! e `(label ,end-lbl))))

        ((ir:begin? node)
         (let ((exprs (ir:begin-exprs node)))
           (if (null? exprs)
               (emit-const! e #f dst)
               (let loop ((exprs exprs))
                 (if (null? (cdr exprs))
                     (emit-node! e (car exprs) dst tail?)
                     (let ((tmp (e-alloc-reg! e)))
                       (emit-node! e (car exprs) tmp #f)
                       (e-free-reg! e)
                       (loop (cdr exprs))))))))

        ((ir:lambda? node)
         (emit-lambda! e node dst))

        ((ir:set!? node)
         (let ((val-reg (e-alloc-reg! e)))
           (emit-node! e (ir:set!-val node) val-reg #f)
           ;; Like emit-ref!, a %gref% target assigns the top-level binding the
           ;; macro saw, not a same-named local at the use site.
           (let ((res (let ((g (gref-name (ir:set!-name node))))
                        (if g
                            (cons 'global g)
                            (resolve e (ir:set!-name node))))))
             (case (car res)
               ((local)
                (e-emit! e `(move ,(cdr res) ,val-reg)))
               ((local-boxed)
                (e-emit! e `(box-set! ,(cdr res) ,val-reg)))
               ((upvalue)
                (e-emit! e `(set-upvalue ,(cdr res) ,val-reg)))
               ((upvalue-boxed)
                (let ((tmp (e-alloc-reg! e)))
                  (e-emit! e `(get-upvalue ,tmp ,(cdr res)))
                  (e-emit! e `(box-set! ,tmp ,val-reg))
                  (e-free-reg! e)))
               ((global)
                (e-emit! e `(set-global ,(cdr res) ,val-reg)))))
           (e-free-reg! e)
           (emit-const! e #f dst)))   ; set! returns unspecified

        ((ir:define? node)
         (error "paal-emitter: ir:define in expression position"))

        ((ir:call? node)
         (emit-call! e node dst tail?))

        (else
         (error "paal-emitter: unknown IR node" node))))

    ;; ---------------------------------------------------------------
    ;; Mutable-captured variable analysis
    ;; ---------------------------------------------------------------
    ;;
    ;; A lambda param must be boxed if it is BOTH:
    ;;   - assigned via set! in the lambda body (not inside nested lambdas), AND
    ;;   - referenced inside a nested ir:lambda (i.e. captured).
    ;; This covers the letrec/named-let pattern:
    ;;   (let ((f #f)) (set! f (lambda ...)) f)

    (define (collect-set-targets node)
      ; Names that appear as (set! name ...) targets anywhere inside node,
      ; including inside nested lambdas.  Crossing lambda boundaries is what
      ; makes closure mutation work: if a nested lambda assigns the variable,
      ; every closure over it — and the frame that owns it — must share one
      ; cell, so the variable has to be boxed.  Capturing by value instead
      ; would give each closure a private copy and silently drop the write.
      (cond
        ((ir:set!?   node) (cons (ir:set!-name node)
                                 (collect-set-targets (ir:set!-val node))))
        ((ir:lambda? node) (collect-set-targets (ir:lambda-body node)))
        ((ir:begin?  node) (apply append (map collect-set-targets (ir:begin-exprs node))))
        ((ir:if?     node) (append (collect-set-targets (ir:if-test node))
                                   (collect-set-targets (ir:if-then node))
                                   (collect-set-targets (ir:if-else node))))
        ((ir:call?   node) (apply append
                                   (cons (collect-set-targets (ir:call-proc node))
                                         (map collect-set-targets (ir:call-args node)))))
        ((ir:define? node) (collect-set-targets (ir:define-val node)))
        (else '())))

    (define (collect-captured node params)
      ; Params that appear as refs inside any ir:lambda in node (at any depth).
      (cond
        ((ir:lambda? node)
         (collect-free-refs-in-body (ir:lambda-body node) params))
        ((ir:begin?  node) (apply append (map (lambda (e) (collect-captured e params))
                                              (ir:begin-exprs node))))
        ((ir:if?     node) (append (collect-captured (ir:if-test node) params)
                                   (collect-captured (ir:if-then node) params)
                                   (collect-captured (ir:if-else node) params)))
        ((ir:call?   node) (apply append
                                   (cons (collect-captured (ir:call-proc node) params)
                                         (map (lambda (a) (collect-captured a params))
                                              (ir:call-args node)))))
        ((ir:set!?   node) (collect-captured (ir:set!-val node) params))
        ((ir:define? node) (collect-captured (ir:define-val node) params))
        (else '())))

    (define (collect-free-refs-in-body node params)
      ; All refs to names in params anywhere inside node (crossing lambda boundaries).
      ; A set! target counts as a use: a closure that assigns the variable needs
      ; the cell just as much as one that reads it.
      (cond
        ((ir:ref?    node) (if (memq (ir:ref-name node) params)
                               (list (ir:ref-name node)) '()))
        ((ir:lambda? node) (collect-free-refs-in-body (ir:lambda-body node) params))
        ((ir:begin?  node) (apply append (map (lambda (e) (collect-free-refs-in-body e params))
                                              (ir:begin-exprs node))))
        ((ir:if?     node) (append (collect-free-refs-in-body (ir:if-test node) params)
                                   (collect-free-refs-in-body (ir:if-then node) params)
                                   (collect-free-refs-in-body (ir:if-else node) params)))
        ((ir:call?   node) (apply append
                                   (cons (collect-free-refs-in-body (ir:call-proc node) params)
                                         (map (lambda (a) (collect-free-refs-in-body a params))
                                              (ir:call-args node)))))
        ((ir:set!?   node) (append (if (memq (ir:set!-name node) params)
                                       (list (ir:set!-name node)) '())
                                   (collect-free-refs-in-body (ir:set!-val node) params)))
        ((ir:define? node) (collect-free-refs-in-body (ir:define-val node) params))
        (else '())))

    (define (must-box-vars params body)
      ; Returns the subset of params that must be stored in mutable boxes.
      (let ((sets     (collect-set-targets body))
            (captured (collect-captured body params)))
        (filter (lambda (n) (and (memq n sets) (memq n captured))) params)))

    ;; ---------------------------------------------------------------
    ;; Lambda compilation
    ;; ---------------------------------------------------------------

    ;; `name` is the identifier a top-level define is binding this lambda to,
    ;; or #f for a genuinely anonymous one.  It reaches the bytecode-function
    ;; purely so a profile report can say `fact` rather than #f; nothing in the
    ;; call path reads it.
    (define (emit-lambda! e node dst . opt)
      (let* ((params    (ir:lambda-params node))
             (body      (ir:lambda-body   node))
             (variadic? (ir:lambda-rest?  node))
             (child-e   (make-emitter e params variadic?))
             ;; Every name the lambda binds, the rest parameter included —
             ;; it lives in a register like the fixed ones, so a captured
             ;; and mutated rest parameter needs a box exactly as they do.
             ;; It used to be dropped here, so (define (mk . args)
             ;; (lambda () ... (set! args ...))) compiled the set! against
             ;; an unboxed capture and the mutation never stuck — SRFI
             ;; 158's generators are that shape.
             (flat-params (cond
                            ((symbol? params) (list params))
                            ((list? params)   params)
                            ((pair? params)   (append (proper-list params)
                                                      (list (last-pair-cdr params))))
                            (else '())))
             (to-box    (must-box-vars flat-params body)))
        ; Box mutable-captured params before allocating body-dst so boxes
        ; sit between params and scratch registers in the register layout.
        (for-each
          (lambda (name)
            (let* ((param-reg (cdr (assq name (e-locals child-e))))
                   (box-reg   (e-alloc-reg! child-e)))
              (e-emit! child-e `(make-box ,box-reg ,param-reg))
              (e-add-boxed! child-e name box-reg)))
          to-box)
        (let ((body-dst (e-alloc-reg! child-e)))
          (emit-node! child-e body body-dst #t)
          (e-emit! child-e `(return ,body-dst))
          (let* ((fn    (finalize! child-e (if (null? opt) #f (car opt))))
                 (specs (map (lambda (uv)
                               ; uv = (name is-local? src-idx is-boxed?)
                               ; VM only needs is-local? and src-idx to capture the value
                               (cons (cadr uv) (caddr uv)))
                             (e-upvalues child-e))))
            (e-emit! e `(closure ,dst ,fn ,specs))))))

    ;; ---------------------------------------------------------------
    ;; Call compilation
    ;; ---------------------------------------------------------------

    (define (emit-call! e node dst tail?)
      (let* ((proc-node (ir:call-proc node))
             (arg-nodes (ir:call-args node))
             (nargs     (length arg-nodes))
             ; Allocate callee slot; args follow consecutively.
             (base      (e-next-reg e)))
        (vector-set! e 3 (+ base 1 nargs))   ; reserve base + 1 + nargs slots
        ; Compile callee into base
        (emit-node! e proc-node base #f)
        ; Compile args into base+1, base+2, ...
        (let loop ((args arg-nodes) (i 1))
          (unless (null? args)
            (emit-node! e (car args) (+ base i) #f)
            (loop (cdr args) (+ i 1))))
        ; Emit call
        (if tail?
            (e-emit! e `(tail-call ,base ,nargs))
            (e-emit! e `(call ,base ,nargs)))
        ; After a non-tail call, result is in reg[base]; move to dst if different.
        (vector-set! e 3 (+ base 1))   ; free arg slots, result is in base
        (unless (or tail? (= base dst))
          (e-emit! e `(move ,dst ,base))
          (e-free-reg! e))
        (when (and (not tail?) (= base dst))
          ; base == dst; just consume the slot
          (vector-set! e 3 base))))   ; actually keep base as dst

    ;; ---------------------------------------------------------------
    ;; Top-level program emission
    ;; ---------------------------------------------------------------
    ;;
    ;; Emits a nullary top-level function that executes a sequence of
    ;; top-level IR nodes (which may include ir:define).

    (define (paal-emit-program nodes)
      (let ((top-e (make-emitter #f '() #f)))
        (let loop ((ns nodes) (last-reg 0))
          (if (null? ns)
              (begin
                (e-emit! top-e `(return ,last-reg))
                (finalize! top-e 'top-level))
              (let ((node    (car ns))
                    (is-last? (null? (cdr ns))))
                (if (ir:define? node)
                    (let ((val-reg (e-alloc-reg! top-e))
                          (val     (ir:define-val node)))
                      (if (ir:lambda? val)
                          (emit-lambda! top-e val val-reg (ir:define-name node))
                          (emit-node! top-e val val-reg #f))
                      (e-emit! top-e `(define-global ,(ir:define-name node) ,val-reg))
                      (e-free-reg! top-e)
                      (loop (cdr ns) val-reg))
                    (let ((reg (e-alloc-reg! top-e)))
                      ; Only the last expression is in tail position.
                      (emit-node! top-e node reg is-last?)
                      (e-free-reg! top-e)
                      (loop (cdr ns) reg))))))))))
