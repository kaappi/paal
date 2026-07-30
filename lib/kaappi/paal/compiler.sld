;;; (kaappi paal compiler) — Analyzer: expanded forms → IR
;;;
;;; Stage 3 of the Paal compilation pipeline.
;;; Converts expanded S-expressions into IR nodes.

(define-library (kaappi paal compiler)
  (import (scheme base) (kaappi paal ir))
  (export paal-analyze paal-analyze-all)
  (begin

    (define (self-evaluating? x)
      (or (boolean? x) (number? x) (string? x) (char? x)
          (null? x) (vector? x) (bytevector? x)))

    (define (paal-analyze form)
      (cond
        ((self-evaluating? form) (ir:const form))
        ((symbol? form)          (ir:ref form))
        ((pair? form)
         (case (car form)
           ((quote)  (ir:const (cadr form)))
           ((if)     (ir:if (paal-analyze (cadr form))
                            (paal-analyze (caddr form))
                            (if (null? (cdddr form))
                                (ir:const #f)
                                (paal-analyze (cadddr form)))))
           ((begin)  (ir:begin (map paal-analyze (cdr form))))
           ((lambda) (analyze-lambda (cdr form)))
           ((set!)   (ir:set! (cadr form) (paal-analyze (caddr form))))
           ((define) (analyze-define (cdr form)))
           (else     (ir:call (paal-analyze (car form))
                              (map paal-analyze (cdr form))))))
        (else (error "paal-analyze: unrecognized form" form))))

    (define (analyze-lambda rest)
      (let* ((params   (car rest))
             (body     (cdr rest))
             (body-ir  (ir:begin (map paal-analyze body))))
        (cond
          ((symbol? params) (ir:lambda params body-ir #t))
          ((null?   params) (ir:lambda '() body-ir #f))
          ;; proper list → rest?=#f; improper list (x . rest) → rest?=#t
          ((pair?   params) (ir:lambda params body-ir (not (list? params))))
          (else (error "analyze-lambda: bad parameter list" params)))))

    (define (analyze-define rest)
      (if (pair? (car rest))
          ;; shorthand: (define (name params...) body...) or (define (name x . rest) ...)
          (let ((name   (caar rest))
                (params (cdar rest)))
            (ir:define name
              (ir:lambda params
                         (ir:begin (map paal-analyze (cdr rest)))
                         (not (list? params)))))
          ;; plain: (define name val)
          (ir:define (car rest)
            (if (null? (cdr rest))
                (ir:const #f)
                (paal-analyze (cadr rest))))))

    (define (paal-analyze-all forms)
      (map paal-analyze forms))))
