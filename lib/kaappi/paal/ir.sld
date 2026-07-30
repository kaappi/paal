;;; (kaappi paal ir) — Intermediate Representation
;;;
;;; Defines tagged IR nodes produced by the analyzer and consumed by
;;; the emitter / VM.  Each node is a tagged list: (tag field ...).
;;;
;;; Node types:
;;;   (const val)                  — self-evaluating constant
;;;   (ref name)                   — variable reference
;;;   (if test then else)          — conditional
;;;   (begin exprs)                — sequencing
;;;   (lambda params body rest?)   — procedure
;;;   (call proc args)             — application
;;;   (set! name val)              — mutation
;;;   (define name val)            — top-level binding

(define-library (kaappi paal ir)
  (import (scheme base))
  (export
    ir:const   ir:ref    ir:if      ir:begin
    ir:lambda  ir:call   ir:set!    ir:define
    ir:const?  ir:ref?   ir:if?     ir:begin?
    ir:lambda? ir:call?  ir:set!?   ir:define?
    ir:const-val
    ir:ref-name
    ir:if-test ir:if-then ir:if-else
    ir:begin-exprs
    ir:lambda-params ir:lambda-body ir:lambda-rest?
    ir:call-proc ir:call-args
    ir:set!-name ir:set!-val
    ir:define-name ir:define-val)
  (begin

    (define (make-node tag . fields) (cons tag fields))
    (define (node-tag n) (car n))
    (define (node-ref n i) (list-ref (cdr n) i))

    (define (ir:const val)            (make-node 'const val))
    (define (ir:ref name)             (make-node 'ref name))
    (define (ir:if test then else)    (make-node 'if test then else))
    (define (ir:begin exprs)          (make-node 'begin exprs))
    (define (ir:lambda params body rest?) (make-node 'lambda params body rest?))
    (define (ir:call proc args)       (make-node 'call proc args))
    (define (ir:set! name val)        (make-node 'set! name val))
    (define (ir:define name val)      (make-node 'define name val))

    (define (ir:const?  n) (eq? (node-tag n) 'const))
    (define (ir:ref?    n) (eq? (node-tag n) 'ref))
    (define (ir:if?     n) (eq? (node-tag n) 'if))
    (define (ir:begin?  n) (eq? (node-tag n) 'begin))
    (define (ir:lambda? n) (eq? (node-tag n) 'lambda))
    (define (ir:call?   n) (eq? (node-tag n) 'call))
    (define (ir:set!?   n) (eq? (node-tag n) 'set!))
    (define (ir:define? n) (eq? (node-tag n) 'define))

    (define (ir:const-val n)     (node-ref n 0))
    (define (ir:ref-name n)      (node-ref n 0))
    (define (ir:if-test n)       (node-ref n 0))
    (define (ir:if-then n)       (node-ref n 1))
    (define (ir:if-else n)       (node-ref n 2))
    (define (ir:begin-exprs n)   (node-ref n 0))
    (define (ir:lambda-params n) (node-ref n 0))
    (define (ir:lambda-body n)   (node-ref n 1))
    (define (ir:lambda-rest? n)  (node-ref n 2))
    (define (ir:call-proc n)     (node-ref n 0))
    (define (ir:call-args n)     (node-ref n 1))
    (define (ir:set!-name n)     (node-ref n 0))
    (define (ir:set!-val n)      (node-ref n 1))
    (define (ir:define-name n)   (node-ref n 0))
    (define (ir:define-val n)    (node-ref n 1))))
