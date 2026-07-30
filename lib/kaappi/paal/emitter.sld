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
  (import (scheme base) (kaappi paal ir) (kaappi paal bytecode))
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
        (vector parent '() '() next-r arity variadic? locals 0)))

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

    ;; Returns (local . reg), (upvalue . idx), or (global . sym)
    (define (resolve e name)
      (cond
        ((assq name (e-locals e))
         => (lambda (pair) (cons 'local (cdr pair))))
        (else
         (let ((uv (capture-upvalue! e name)))
           (if uv
               (cons 'upvalue uv)
               (cons 'global name))))))

    ;; Try to capture name from parent chain; returns upvalue index or #f.
    (define (capture-upvalue! e name)
      (let ((parent (e-parent e)))
        (and parent
             (let ((res (resolve-in e name parent)))
               (and res
                    (let ((is-local? (eq? (car res) 'local))
                          (src-idx   (cdr res)))
                      (add-upvalue! e name is-local? src-idx)))))))

    ;; Resolve name in the context of a child's parent.
    ;; Returns (local . reg), (upvalue . idx), or #f.
    (define (resolve-in child name parent)
      (cond
        ((assq name (e-locals parent))
         => (lambda (pair) (cons 'local (cdr pair))))
        (else
         ; Check if already an upvalue of parent
         (let loop ((uvs (e-upvalues parent)) (i 0))
           (cond
             ((null? uvs) #f)
             ((eq? (caar uvs) name) (cons 'upvalue i))
             (else (loop (cdr uvs) (+ i 1))))))))

    ;; Register a new upvalue in e; return its index.
    (define (add-upvalue! e name is-local? src-idx)
      (let ((existing (let loop ((uvs (e-upvalues e)) (i 0))
                        (cond
                          ((null? uvs) #f)
                          ((eq? (caar uvs) name) i)
                          (else (loop (cdr uvs) (+ i 1)))))))
        (or existing
            (let ((idx (length (e-upvalues e))))
              (vector-set! e 2
                (append (vector-ref e 2)
                        (list (list name is-local? src-idx))))
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
      (let ((res (resolve e name)))
        (case (car res)
          ((local)
           (let ((src (cdr res)))
             (unless (= src dst)
               (e-emit! e `(move ,dst ,src)))))
          ((upvalue)
           (e-emit! e `(get-upvalue ,dst ,(cdr res))))
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
           (let ((res (resolve e (ir:set!-name node))))
             (case (car res)
               ((local)   (e-emit! e `(move ,(cdr res) ,val-reg)))
               ((upvalue) (e-emit! e `(set-upvalue ,(cdr res) ,val-reg)))
               ((global)  (e-emit! e `(set-global ,(cdr res) ,val-reg)))))
           (e-free-reg! e)
           (emit-const! e #f dst)))   ; set! returns unspecified

        ((ir:define? node)
         (error "paal-emitter: ir:define in expression position"))

        ((ir:call? node)
         (emit-call! e node dst tail?))

        (else
         (error "paal-emitter: unknown IR node" node))))

    ;; ---------------------------------------------------------------
    ;; Lambda compilation
    ;; ---------------------------------------------------------------

    (define (emit-lambda! e node dst)
      (let* ((params   (ir:lambda-params node))
             (body     (ir:lambda-body   node))
             (variadic? (ir:lambda-rest? node))
             (child-e  (make-emitter e params variadic?))
             (body-dst (e-alloc-reg! child-e)))
        (emit-node! child-e body body-dst #t)
        (e-emit! child-e `(return ,body-dst))
        (let* ((fn    (finalize! child-e #f))
               (specs (map (lambda (uv)
                             ; uv = (name is-local? src-idx)
                             (cons (cadr uv) (caddr uv)))
                           (e-upvalues child-e))))
          (e-emit! e `(closure ,dst ,fn ,specs)))))

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
                    (let ((val-reg (e-alloc-reg! top-e)))
                      (emit-node! top-e (ir:define-val node) val-reg #f)
                      (e-emit! top-e `(define-global ,(ir:define-name node) ,val-reg))
                      (e-free-reg! top-e)
                      (loop (cdr ns) val-reg))
                    (let ((reg (e-alloc-reg! top-e)))
                      ; Only the last expression is in tail position.
                      (emit-node! top-e node reg is-last?)
                      (e-free-reg! top-e)
                      (loop (cdr ns) reg))))))))))
