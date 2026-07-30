(import (scheme base) (scheme write) (scheme process-context)
        (kaappi paal))

(define pass 0)
(define fail 0)

(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1))
             (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1))
             (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

;; --- Self-evaluating forms ---

(display "=== literals ===") (newline)

(check "integer"  42      (pkaappi-run-string "42"))
(check "negative" -7      (pkaappi-run-string "-7"))
(check "float"    3.14    (pkaappi-run-string "3.14"))
(check "true"     #t      (pkaappi-run-string "#t"))
(check "false"    #f      (pkaappi-run-string "#f"))
(check "string"   "hi"    (pkaappi-run-string "\"hi\""))
(check "empty list" '()   (pkaappi-run-string "'()"))
(check "quoted list" '(a b c) (pkaappi-run-string "'(a b c)"))

;; --- if ---

(display "=== if ===") (newline)

(check "if true"    1  (pkaappi-run-string "(if #t 1 2)"))
(check "if false"   2  (pkaappi-run-string "(if #f 1 2)"))
(check "if no-else" #f (pkaappi-run-string "(if #f 1)"))

;; --- begin ---

(display "=== begin ===") (newline)

(check "begin" 3 (pkaappi-run-string "(begin 1 2 3)"))

;; --- lambda ---

(display "=== lambda ===") (newline)

(check "identity"      5   (pkaappi-run-string "((lambda (x) x) 5)"))
(check "add"           3   (pkaappi-run-string "((lambda (x y) (+ x y)) 1 2)"))
(check "nested lambda" 6   (pkaappi-run-string "((lambda (x) ((lambda (y) (+ x y)) 4)) 2)"))
(check "nullary"       42  (pkaappi-run-string "((lambda () 42))"))
(check "variadic rest" '(1 2 3) (pkaappi-run-string "((lambda args args) 1 2 3)"))

;; --- define ---

(display "=== define ===") (newline)

(check "define var"  10 (pkaappi-run-string "(define x 10) x"))
(check "define fn"    7 (pkaappi-run-string "(define (add a b) (+ a b)) (add 3 4)"))
(check "recursive"  120 (pkaappi-run-string
  "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 5)"))

;; --- arithmetic ---

(display "=== arithmetic ===") (newline)

(check "+"   6   (pkaappi-run-string "(+ 1 2 3)"))
(check "-"   1   (pkaappi-run-string "(- 4 3)"))
(check "*"  12   (pkaappi-run-string "(* 3 4)"))
(check "/"   2   (pkaappi-run-string "(/ 6 3)"))
(check "="  #t   (pkaappi-run-string "(= 3 3)"))
(check "<"  #t   (pkaappi-run-string "(< 1 2)"))

;; --- list operations ---

(display "=== lists ===") (newline)

(check "cons"   '(1 2)  (pkaappi-run-string "(cons 1 '(2))"))
(check "car"    1       (pkaappi-run-string "(car '(1 2 3))"))
(check "cdr"    '(2 3)  (pkaappi-run-string "(cdr '(1 2 3))"))
(check "null?"  #t      (pkaappi-run-string "(null? '())"))
(check "pair?"  #t      (pkaappi-run-string "(pair? '(1))"))

;; --- Results ---

(newline)
(display "Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed") (newline)
(when (> fail 0) (exit 1))
