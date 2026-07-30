(import (scheme base) (scheme file) (kaappi test) (kaappi paal))

(test-group "literals"
  (test-equal "integer"    42       (pkaappi-run-string "42"))
  (test-equal "negative"   -7       (pkaappi-run-string "-7"))
  (test-equal "float"      3.14     (pkaappi-run-string "3.14"))
  (test-equal "true"       #t       (pkaappi-run-string "#t"))
  (test-equal "false"      #f       (pkaappi-run-string "#f"))
  (test-equal "string"     "hi"     (pkaappi-run-string "\"hi\""))
  (test-equal "empty list" '()      (pkaappi-run-string "'()"))
  (test-equal "quoted"     '(a b c) (pkaappi-run-string "'(a b c)")))

(test-group "if"
  (test-equal "true"    1  (pkaappi-run-string "(if #t 1 2)"))
  (test-equal "false"   2  (pkaappi-run-string "(if #f 1 2)"))
  (test-equal "no-else" #f (pkaappi-run-string "(if #f 1)")))

(test-group "begin"
  (test-equal "sequence" 3 (pkaappi-run-string "(begin 1 2 3)")))

(test-group "lambda"
  (test-equal "identity"  5        (pkaappi-run-string "((lambda (x) x) 5)"))
  (test-equal "add"       3        (pkaappi-run-string "((lambda (x y) (+ x y)) 1 2)"))
  (test-equal "nested"    6        (pkaappi-run-string "((lambda (x) ((lambda (y) (+ x y)) 4)) 2)"))
  (test-equal "nullary"   42       (pkaappi-run-string "((lambda () 42))"))
  (test-equal "variadic"  '(1 2 3) (pkaappi-run-string "((lambda args args) 1 2 3)")))

(test-group "define"
  (test-equal "variable"  10  (pkaappi-run-string "(define x 10) x"))
  (test-equal "function"   7  (pkaappi-run-string "(define (add a b) (+ a b)) (add 3 4)"))
  (test-equal "recursive" 120 (pkaappi-run-string
    "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 5)")))

(test-group "arithmetic"
  (test-equal "+"   6  (pkaappi-run-string "(+ 1 2 3)"))
  (test-equal "-"   1  (pkaappi-run-string "(- 4 3)"))
  (test-equal "*"   12 (pkaappi-run-string "(* 3 4)"))
  (test-equal "/"   2  (pkaappi-run-string "(/ 6 3)"))
  (test-assert "="     (pkaappi-run-string "(= 3 3)"))
  (test-assert "<"     (pkaappi-run-string "(< 1 2)")))

(test-group "lists"
  (test-equal "cons"    '(1 2) (pkaappi-run-string "(cons 1 '(2))"))
  (test-equal "car"     1      (pkaappi-run-string "(car '(1 2 3))"))
  (test-equal "cdr"     '(2 3) (pkaappi-run-string "(cdr '(1 2 3))"))
  (test-assert "null?"         (pkaappi-run-string "(null? '())"))
  (test-assert "pair?"         (pkaappi-run-string "(pair? '(1))"))
  (test-equal "append"  '(1 2 3 4) (pkaappi-run-string "(append '(1 2) '(3 4))"))
  (test-equal "reverse" '(3 2 1)   (pkaappi-run-string "(reverse '(1 2 3))"))
  (test-equal "length"  3          (pkaappi-run-string "(length '(a b c))"))
  (test-equal "list-ref" 'b        (pkaappi-run-string "(list-ref '(a b c) 1)"))
  (test-equal "assq"    '(b 2)     (pkaappi-run-string "(assq 'b '((a 1) (b 2) (c 3)))"))
  (test-equal "member"  '(2 3)     (pkaappi-run-string "(member 2 '(1 2 3))")))

(test-group "set!"
  (test-equal "mutate" 2
    (pkaappi-run-string "(define x 1) (set! x 2) x"))
  (test-equal "closure over set!" 3
    (pkaappi-run-string
      "(define n 0)
       (define (bump!) (set! n (+ n 1)))
       (bump!) (bump!) (bump!) n")))

(test-group "lambda params"
  (test-equal "improper (x . rest)"
    '(2 3 4)
    (pkaappi-run-string "((lambda (x . rest) rest) 1 2 3 4)"))
  (test-equal "improper (x y . rest)"
    '(3 4)
    (pkaappi-run-string "((lambda (x y . rest) rest) 1 2 3 4)"))
  (test-equal "define shorthand rest"
    '(2 3)
    (pkaappi-run-string "(define (f x . rest) rest) (f 1 2 3)")))

(test-group "run-file"
  (let ((tmp "/tmp/paal-test-run-file.scm"))
    (let ((port (open-output-file tmp)))
      (display "(define (square x) (* x x)) (square 7)" port)
      (close-output-port port))
    (test-equal "pkaappi-run-file" 49 (pkaappi-run-file tmp))))

(test-exit)
