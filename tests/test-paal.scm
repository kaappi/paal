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

;; ----------------------------------------------------------------
;; Expander tests (Phase 2)
;; ----------------------------------------------------------------

(test-group "let"
  (test-equal "simple"   3  (pkaappi-run-string "(let ((x 1) (y 2)) (+ x y))"))
  (test-equal "body seq" 2  (pkaappi-run-string "(let ((x 1)) (+ x 0) (+ x 1))"))
  (test-equal "scope"    10 (pkaappi-run-string
    "(define x 10) (let ((x 99)) #f) x"))
  (test-equal "nested"   6  (pkaappi-run-string
    "(let ((x 1)) (let ((y 2)) (let ((z 3)) (+ x y z))))")))

(test-group "let*"
  (test-equal "seq binding" 6 (pkaappi-run-string "(let* ((x 2) (y (* x 3))) y)"))
  (test-equal "empty"       5 (pkaappi-run-string "(let* () 5)")))

(test-group "letrec"
  (test-equal "mutual recursion" #t
    (pkaappi-run-string
      "(letrec ((even? (lambda (n) (if (= n 0) #t (odd?  (- n 1)))))
                (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
         (even? 100))"))
  (test-equal "self-recursive" 120
    (pkaappi-run-string
      "(letrec ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1)))))))
         (fact 5))")))

(test-group "named-let"
  (test-equal "sum loop" 10
    (pkaappi-run-string
      "(let loop ((i 0) (s 0))
         (if (= i 5) s (loop (+ i 1) (+ s i))))"))
  (test-equal "build list" '(0 1 2 3 4)
    (pkaappi-run-string
      "(let loop ((i 4) (acc '()))
         (if (< i 0) acc (loop (- i 1) (cons i acc))))")))

(test-group "and"
  (test-equal "empty"         #t (pkaappi-run-string "(and)"))
  (test-equal "single true"    1 (pkaappi-run-string "(and 1)"))
  (test-equal "all true"       3 (pkaappi-run-string "(and 1 2 3)"))
  (test-equal "short-circuit" #f (pkaappi-run-string "(and 1 #f 3)")))

(test-group "or"
  (test-equal "empty"         #f (pkaappi-run-string "(or)"))
  (test-equal "first true"     1 (pkaappi-run-string "(or 1 2 3)"))
  (test-equal "all false"     #f (pkaappi-run-string "(or #f #f #f)"))
  (test-equal "second true"    2 (pkaappi-run-string "(or #f 2 3)")))

(test-group "when/unless"
  (test-equal "when true"  99 (pkaappi-run-string "(when #t 99)"))
  (test-assert "when false"   (not (pkaappi-run-string "(when #f 99)")))
  (test-equal "unless false" 42 (pkaappi-run-string "(unless #f 42)"))
  (test-assert "unless true"  (not (pkaappi-run-string "(unless #t 42)"))))

(test-group "cond"
  (test-equal "first true"  1 (pkaappi-run-string "(cond (#t 1) (#t 2))"))
  (test-equal "else"        3 (pkaappi-run-string "(cond (#f 1) (else 3))"))
  (test-equal "=> arrow"    4 (pkaappi-run-string
    "(cond ((+ 2 2) => (lambda (x) x)))"))
  (test-equal "test only"   7 (pkaappi-run-string "(cond (#f) (7))")))

(test-group "case"
  (test-equal "match first"  'a (pkaappi-run-string
    "(case 1 ((1) 'a) ((2) 'b) (else 'c))"))
  (test-equal "match second" 'b (pkaappi-run-string
    "(case 2 ((1) 'a) ((2) 'b) (else 'c))"))
  (test-equal "else"         'c (pkaappi-run-string
    "(case 9 ((1) 'a) ((2) 'b) (else 'c))"))
  (test-equal "multi-datum"  'yes (pkaappi-run-string
    "(case 3 ((1 2 3) 'yes) (else 'no))")))

(test-group "quasiquote"
  (test-equal "plain"    '(a b c) (pkaappi-run-string "`(a b c)"))
  (test-equal "unquote"  '(a 42 c)
    (pkaappi-run-string "(define x 42) `(a ,x c)"))
  (test-equal "splicing" '(a 1 2 3 d)
    (pkaappi-run-string "(define xs '(1 2 3)) `(a ,@xs d)"))
  (test-equal "nested"   '(1 (2 3))
    (pkaappi-run-string
      "(let ((a 1) (b '(2 3))) `(,a ,b))")))

(test-group "do"
  (test-equal "sum" 10
    (pkaappi-run-string
      "(do ((i 0 (+ i 1)) (s 0 (+ s i)))
           ((= i 5) s))"))
  (test-equal "build list" '(4 3 2 1 0)
    (pkaappi-run-string
      "(do ((i 0 (+ i 1)) (acc '() (cons i acc)))
           ((= i 5) acc))")))

;; ----------------------------------------------------------------
;; TCO tests (Phase 3) — all would stack-overflow without a trampoline
;; ----------------------------------------------------------------

(test-group "tail calls"
  (test-equal "self-tail-recursive loop (1M)" 'done
    (pkaappi-run-string
      "(define (loop n)
         (if (= n 0) 'done (loop (- n 1))))
       (loop 1000000)"))

  (test-equal "tail call to different function" 42
    (pkaappi-run-string
      "(define (even? n) (if (= n 0) #t (odd?  (- n 1))))
       (define (odd?  n) (if (= n 0) #f (even? (- n 1))))
       (if (even? 100000) 42 0)"))

  (test-equal "named-let tail loop (1M)" 500000
    (pkaappi-run-string
      "(let loop ((n 1000000) (acc 0))
         (if (= n 0) acc (loop (- n 1) (+ acc 1/2))))"))

  (test-equal "tail call in cond else" 0
    (pkaappi-run-string
      "(define (count-down n)
         (cond ((= n 0) 0)
               (else (count-down (- n 1)))))
       (count-down 500000)"))

  (test-equal "non-tail call still works (fib)" 6765
    (pkaappi-run-string
      "(define (fib n)
         (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
       (fib 20)")))

;; ----------------------------------------------------------------
;; Self-hosted reader tests (Phase 5)
;; ----------------------------------------------------------------

(test-group "reader: atoms"
  (test-equal "integer"   42      (car (paal-read-string "42")))
  (test-equal "negative"  -7      (car (paal-read-string "-7")))
  (test-equal "float"     3.14    (car (paal-read-string "3.14")))
  (test-equal "true"      #t      (car (paal-read-string "#t")))
  (test-equal "false"     #f      (car (paal-read-string "#f")))
  (test-equal "true-long" #t      (car (paal-read-string "#true")))
  (test-equal "symbol"    'hello  (car (paal-read-string "hello")))
  (test-equal "+"         '+      (car (paal-read-string "+")))
  (test-equal "..."       '...    (car (paal-read-string "...")))
  (test-equal "string"    "hi"    (car (paal-read-string "\"hi\""))))

(test-group "reader: characters"
  (test-equal "space"     #\space   (car (paal-read-string "#\\space")))
  (test-equal "newline"   #\newline (car (paal-read-string "#\\newline")))
  (test-equal "tab"       #\tab     (car (paal-read-string "#\\tab")))
  (test-equal "single"    #\a       (car (paal-read-string "#\\a")))
  (test-equal "hex"       #\A       (car (paal-read-string "#\\x41"))))

(test-group "reader: string escapes"
  (test-equal "newline" (string #\newline) (car (paal-read-string "\"\\n\"")))
  (test-equal "tab"     (string #\tab)     (car (paal-read-string "\"\\t\"")))
  (test-equal "quote"   "\""              (car (paal-read-string "\"\\\"\"")))
  (test-equal "hex"     "A"              (car (paal-read-string "\"\\x41;\""))))

(test-group "reader: lists"
  (test-equal "empty"  '()      (car (paal-read-string "()")))
  (test-equal "simple" '(1 2 3) (car (paal-read-string "(1 2 3)")))
  (test-equal "nested" '(a (b c) d) (car (paal-read-string "(a (b c) d)")))
  (test-equal "dotted" '(a . b) (car (paal-read-string "(a . b)")))
  (test-equal "vector" #(1 2 3) (car (paal-read-string "#(1 2 3)"))))

(test-group "reader: abbreviations"
  (test-equal "quote"  '(quote x)            (car (paal-read-string "'x")))
  (test-equal "quasi"  '(quasiquote x)       (car (paal-read-string "`x")))
  (test-equal "unq"    '(unquote x)          (car (paal-read-string ",x")))
  (test-equal "splice" '(unquote-splicing x) (car (paal-read-string ",@x"))))

(test-group "reader: comments"
  (test-equal "line comment"  '(1 3)  (paal-read-string "1 ; skip this\n 3"))
  (test-equal "block comment" '(1 3)  (paal-read-string "1 #| skip |# 3"))
  (test-equal "nested block"  '(1 3)  (paal-read-string "1 #| a #| b |# c |# 3"))
  (test-equal "datum comment" '(1 3)  (paal-read-string "1 #;2 3")))

(test-group "reader: multiple forms"
  (test-equal "two" '(a b)   (paal-read-string "a b"))
  (test-equal "three" '(1 2 3) (paal-read-string "1 2 3")))

(test-group "reader: read paal source"
  ; The test gate: paal can read its own source files.
  (let ((forms (paal-read-file "lib/kaappi/paal/reader.sld")))
    (test-assert "reader.sld is non-empty" (> (length forms) 0))
    (test-equal  "starts with define-library"
                 'define-library (caar forms)))
  (let ((forms (paal-read-file "lib/kaappi/paal/ir.sld")))
    (test-assert "ir.sld is non-empty" (> (length forms) 0)))
  (let ((forms (paal-read-file "lib/kaappi/paal/expander.sld")))
    (test-assert "expander.sld is non-empty" (> (length forms) 0))))

;; ----------------------------------------------------------------
;; Bytecode VM tests (Phase 4) — same programs via pkaappi-run-bc-string
;; ----------------------------------------------------------------

(test-group "bytecode: literals"
  (test-equal "integer"  42      (pkaappi-run-bc-string "42"))
  (test-equal "boolean"  #t      (pkaappi-run-bc-string "#t"))
  (test-equal "string"   "hi"    (pkaappi-run-bc-string "\"hi\""))
  (test-equal "quoted"   '(a b)  (pkaappi-run-bc-string "'(a b)")))

(test-group "bytecode: arithmetic"
  (test-equal "+"  6  (pkaappi-run-bc-string "(+ 1 2 3)"))
  (test-equal "*" 12  (pkaappi-run-bc-string "(* 3 4)"))
  (test-equal "="  #t (pkaappi-run-bc-string "(= 5 5)")))

(test-group "bytecode: if"
  (test-equal "true"    1  (pkaappi-run-bc-string "(if #t 1 2)"))
  (test-equal "false"   2  (pkaappi-run-bc-string "(if #f 1 2)"))
  (test-equal "no-else" #f (pkaappi-run-bc-string "(if #f 1)")))

(test-group "bytecode: define and call"
  (test-equal "var"  10  (pkaappi-run-bc-string "(define x 10) x"))
  (test-equal "fn"    7  (pkaappi-run-bc-string "(define (add a b) (+ a b)) (add 3 4)"))
  (test-equal "recursive" 120
    (pkaappi-run-bc-string
      "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 5)")))

(test-group "bytecode: closures"
  (test-equal "closure over define" 3
    (pkaappi-run-bc-string
      "(define (make-adder n) (lambda (x) (+ n x)))
       (define add3 (make-adder 3))
       (add3 0)"))
  (test-equal "counter with set!" 3
    (pkaappi-run-bc-string
      "(define n 0)
       (define (bump!) (set! n (+ n 1)))
       (bump!) (bump!) (bump!) n")))

(test-group "bytecode: derived forms"
  (test-equal "let"  3  (pkaappi-run-bc-string "(let ((x 1) (y 2)) (+ x y))"))
  (test-equal "cond" 2  (pkaappi-run-bc-string "(cond (#f 1) (else 2))"))
  (test-equal "and"  #f (pkaappi-run-bc-string "(and 1 #f 3)"))
  (test-equal "quasiquote" '(a 42 c)
    (pkaappi-run-bc-string "(define x 42) `(a ,x c)")))

(test-group "bytecode: tail calls"
  (test-equal "1M loop" 'done
    (pkaappi-run-bc-string
      "(define (loop n) (if (= n 0) 'done (loop (- n 1))))
       (loop 1000000)")))

;; ----------------------------------------------------------------
;; Internal defines (Phase 6 pre-work)
;; ----------------------------------------------------------------

(test-group "internal defines"
  (test-equal "define in lambda body"
    3
    (pkaappi-run-string
      "((lambda ()
         (define x 1)
         (define y 2)
         (+ x y)))"))
  (test-equal "recursive internal define"
    120
    (pkaappi-run-string
      "((lambda ()
         (define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
         (fact 5)))"))
  (test-equal "internal define in let body"
    5
    (pkaappi-run-string
      "(let ((a 2))
         (define b 3)
         (+ a b))"))
  (test-equal "mutual internal defines"
    #t
    (pkaappi-run-string
      "((lambda ()
         (define (even? n) (if (= n 0) #t (odd?  (- n 1))))
         (define (odd?  n) (if (= n 0) #f (even? (- n 1))))
         (even? 10)))"))
  (test-equal "bc: internal define"
    3
    (pkaappi-run-bc-string
      "((lambda ()
         (define x 1)
         (define y 2)
         (+ x y)))")))

;; ----------------------------------------------------------------
;; define-record-type (Phase 6 pre-work)
;; ----------------------------------------------------------------

(test-group "define-record-type"
  (test-equal "constructor and accessor"
    42
    (pkaappi-run-string
      "(define-record-type <point>
         (make-point x y)
         point?
         (x point-x)
         (y point-y))
       (point-x (make-point 42 0))"))
  (test-assert "predicate true"
    (pkaappi-run-string
      "(define-record-type <foo> (make-foo v) foo? (v foo-v))
       (foo? (make-foo 1))"))
  (test-assert "predicate false on other value"
    (not (pkaappi-run-string
           "(define-record-type <foo> (make-foo v) foo? (v foo-v))
            (foo? 42)")))
  (test-equal "mutator"
    99
    (pkaappi-run-string
      "(define-record-type <cell>
         (make-cell val)
         cell?
         (val cell-val set-cell-val!))
       (define c (make-cell 0))
       (set-cell-val! c 99)
       (cell-val c)"))
  (test-equal "two fields, second accessor"
    7
    (pkaappi-run-string
      "(define-record-type <pair>
         (make-pair a b)
         pair-record?
         (a pair-a)
         (b pair-b))
       (pair-b (make-pair 3 7))"))
  (test-equal "bc: record-type constructor and accessor"
    42
    (pkaappi-run-bc-string
      "(define-record-type <box>
         (make-box val)
         box?
         (val box-val))
       (box-val (make-box 42))")))

;; ----------------------------------------------------------------
;; define-library / import / export (Phase 6 pre-work)
;; ----------------------------------------------------------------

(test-group "define-library"
  (test-assert "import expands to no-op"
    (equal? '(quote #f)
            (paal-expand '(import (scheme base)))))
  (test-assert "export expands to no-op"
    (equal? '(quote #f)
            (paal-expand '(export foo bar))))
  (test-equal "expand define-library produces begin"
    'begin
    (let ((forms (paal-read-file "lib/kaappi/paal/ir.sld")))
      (car (paal-expand (car forms)))))
  (test-assert "paal reads its own ir.sld"
    (let ((forms (paal-read-file "lib/kaappi/paal/ir.sld")))
      (and (> (length forms) 0)
           (eq? 'define-library (caar forms))))))

;; ----------------------------------------------------------------
;; Self-load integration (Stage 6 gate)
;; ----------------------------------------------------------------

(test-group "self-load: ir + compiler"
  (let ((g (pkaappi-make-globals)))
    (pkaappi-load-file "lib/kaappi/paal/ir.sld" g)
    (test-assert "ir:const? works after loading ir.sld"
      (pkaappi-run-string-in g "(ir:const? (ir:const 42))"))
    (test-assert "ir:ref? works"
      (pkaappi-run-string-in g "(ir:ref? (ir:ref 'x))"))
    (test-equal "ir:const-val works"
      42
      (pkaappi-run-string-in g "(ir:const-val (ir:const 42))"))
    (test-equal "ir:if-test works"
      #t
      (pkaappi-run-string-in g
        "(ir:const-val (ir:if-test (ir:if (ir:const #t) (ir:const 1) (ir:const 2))))"))
    (pkaappi-load-file "lib/kaappi/paal/compiler.sld" g)
    (test-assert "paal-analyze of literal produces ir:const"
      (pkaappi-run-string-in g "(ir:const? (paal-analyze 42))"))
    (test-assert "paal-analyze of symbol produces ir:ref"
      (pkaappi-run-string-in g "(ir:ref? (paal-analyze 'x))"))
    (test-assert "paal-analyze of (if ...) produces ir:if"
      (pkaappi-run-string-in g "(ir:if? (paal-analyze '(if #t 1 2)))"))))

(test-group "self-load: ir+bytecode+compiler+frame"
  ;; Load files that don't use named-let (letrec self-reference requires
  ;; mutable upvalue cells, not yet supported in the bytecode VM).
  ;; reader.sld, expander.sld, emitter.sld use 'let loop' and are deferred.
  ;; paal-analyze-all uses (map paal-analyze ...) but HOST map can't call
  ;; paal closures; use paal-analyze directly instead.
  (let ((g (pkaappi-make-globals)))
    (for-each (lambda (path) (pkaappi-load-file path g))
              '("lib/kaappi/paal/ir.sld"
                "lib/kaappi/paal/bytecode.sld"
                "lib/kaappi/paal/compiler.sld"
                "lib/kaappi/paal/frame.sld"))
    (test-assert "paal-analyze of (if ...) produces ir:if"
      (pkaappi-run-string-in g "(ir:if? (paal-analyze '(if #t 1 2)))"))
    (test-assert "paal-analyze of (quote ...) produces ir:const"
      (pkaappi-run-string-in g "(ir:const? (paal-analyze '(quote hello)))"))
    (test-assert "paal-analyze of (set! ...) produces ir:set!"
      (pkaappi-run-string-in g "(ir:set!? (paal-analyze '(set! x 99)))"))
    (test-assert "closure? from frame.sld works on paal-compiled closure"
      (pkaappi-run-string-in g
        "(closure? (make-closure (paal-analyze 42) (vector)))"))))

(test-group "run-file"
  (let ((tmp "/tmp/paal-test-run-file.scm"))
    (let ((port (open-output-file tmp)))
      (display "(define (square x) (* x x)) (square 7)" port)
      (close-output-port port))
    (test-equal "pkaappi-run-file" 49 (pkaappi-run-file tmp))))

;; ---------------------------------------------------------------
;; letrec / named-let (mutable upvalue fix)
;; ---------------------------------------------------------------

(test-group "letrec / named-let (mutable upvalue fix)"
  (test-equal "named-let loop counts to 10"
    10
    (pkaappi-run-string "(let loop ((x 0)) (if (= x 10) x (loop (+ x 1))))"))
  (test-equal "letrec factorial"
    120
    (pkaappi-run-string "(letrec ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))) (fact 5))"))
  (test-equal "letrec mutual recursion"
    #t
    (pkaappi-run-string "(letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
                   (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
           (even? 10))"))
  (test-equal "letrec* factorial"
    6
    (pkaappi-run-string "(letrec* ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))) (fact 3))"))
  (test-equal "named-let accumulator"
    45
    (pkaappi-run-string "(let loop ((i 0) (sum 0))
           (if (= i 10) sum (loop (+ i 1) (+ sum i))))"))
  (test-equal "letrec function passed as arg"
    10
    (pkaappi-run-string "(letrec ((f (lambda (n) (if (= n 0) 0 (+ 1 (f (- n 1))))))) (f 10))")))

;; ---------------------------------------------------------------
;; self-load: reader + expander (post-letrec-fix)
;; ---------------------------------------------------------------

(test-group "self-load: reader + expander (post-letrec-fix)"
  (let ((g (pkaappi-make-globals)))
    (pkaappi-load-file "lib/kaappi/paal/ir.sld" g)
    (pkaappi-load-file "lib/kaappi/paal/reader.sld" g)
    (test-equal "paal-read-string works after self-load"
      '(42)
      (pkaappi-run-string-in g "(paal-read-string \"42\")"))
    (pkaappi-load-file "lib/kaappi/paal/expander.sld" g)
    (test-assert "paal-expand works after self-load"
      (pair? (pkaappi-run-string-in g "(paal-expand '(if #t 1 2))")))))

;; ---------------------------------------------------------------
;; Stage 6 milestone: full self-load
;; ---------------------------------------------------------------

(test-group "stage-6 milestone: full self-load"
  (let ((g (pkaappi-make-globals)))
    (for-each (lambda (path) (pkaappi-load-file path g))
              '("lib/kaappi/paal/ir.sld"
                "lib/kaappi/paal/bytecode.sld"
                "lib/kaappi/paal/reader.sld"
                "lib/kaappi/paal/expander.sld"
                "lib/kaappi/paal/compiler.sld"
                "lib/kaappi/paal/frame.sld"
                "lib/kaappi/paal/emitter.sld"))
    (test-equal "paal map with paal closure"
      '(2 4 6)
      (pkaappi-run-string-in g
        "(define (double x) (* x 2)) (map double '(1 2 3))"))
    (test-assert "paal-analyze-all works (map paal-analyze)"
      (pkaappi-run-string-in g
        "(list? (paal-analyze-all '(42 (+ 1 2))))"))
    (test-assert "full pipeline: expand->analyze->emit produces bytecode-function"
      (pkaappi-run-string-in g
        "(bytecode-function? (paal-emit-program
           (paal-analyze-all
             (paal-expand-all '((define (add x y) (+ x y)))))))"))
    ; The loaded paal-emit-program returns a paal-encoded bytecode-function
    ; (a vector from paal's define-record-type expansion, not a HOST record).
    ; Verify the loaded pipeline runs end-to-end and produces a vector.
    (test-assert "loaded compiler pipeline produces bytecode structure"
      (pkaappi-run-string-in g
        "(vector? (paal-emit-program
                    (paal-analyze-all
                      (paal-expand-all '((define (add x y) (+ x y)) (add 3 4))))))"))))

;; ---------------------------------------------------------------
;; Stage 6 complete: self-execute
;; ---------------------------------------------------------------

(test-group "stage-6 complete: self-execute"
  (let ((g (pkaappi-make-globals)))
    (for-each (lambda (path) (pkaappi-load-file path g))
              '("lib/kaappi/paal/ir.sld"
                "lib/kaappi/paal/bytecode.sld"
                "lib/kaappi/paal/reader.sld"
                "lib/kaappi/paal/expander.sld"
                "lib/kaappi/paal/compiler.sld"
                "lib/kaappi/paal/frame.sld"
                "lib/kaappi/paal/emitter.sld"
                "lib/kaappi/paal/vm-bc.sld"))
    (test-equal "self-hosted (add 3 4) evaluates to 7"
      7
      (pkaappi-run-string-in g
        "(paal-run-bc
           (paal-emit-program
             (paal-analyze-all
               (paal-expand-all '((define (add x y) (+ x y)) (add 3 4)))))
           (pkaappi-make-globals))"))
    (test-equal "self-hosted factorial via loaded pipeline"
      120
      (pkaappi-run-string-in g
        "(paal-run-bc
           (paal-emit-program
             (paal-analyze-all
               (paal-expand-all
                 '((define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
                   (fact 5)))))
           (pkaappi-make-globals))"))))

;; ---------------------------------------------------------------
;; Bar-quoted symbols |...|
;; ---------------------------------------------------------------

(test-group "bar-quoted symbols"
  (test-equal "simple bar symbol"
    (string->symbol "hello")
    (car (paal-read-string "|hello|")))
  (test-equal "symbol with spaces"
    (string->symbol "foo bar")
    (car (paal-read-string "|foo bar|")))
  (test-equal "symbol with parens"
    (string->symbol "a(b)c")
    (car (paal-read-string "|a(b)c|")))
  (test-equal "backslash escape"
    (string->symbol "a|b")
    (car (paal-read-string "|a\\|b|"))))

;; ---------------------------------------------------------------
;; Bytecode serializer
;; ---------------------------------------------------------------

(define (round-trip-run src)
  (let* ((fn  (pkaappi-compile src))
         (buf (open-output-string))
         (_   (paal-write-bc fn buf))
         (fn2 (paal-read-bc (open-input-string (get-output-string buf))))
         (g   (paal-make-globals
                (map (lambda (p) (cons (car p) (vector-ref (cdr p) 0)))
                     (paal-initial-env)))))
    (paal-run-bc fn2 g)))

(test-group "bytecode serializer"
  (test-equal "round-trip: arithmetic"
    3
    (round-trip-run "(+ 1 2)"))
  (test-equal "round-trip: closure/upvalue"
    7
    (round-trip-run "(define (add x y) (+ x y)) (add 3 4)"))
  (test-equal "round-trip: recursion"
    120
    (round-trip-run "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 5)"))
  (test-equal "file round-trip"
    120
    (let ((path "paal-test-tmp.pbc"))
      (pkaappi-compile-to-file "tests/fixtures/factorial.scm" path)
      (let ((result (pkaappi-run-pbc-file path)))
        (delete-file path)
        result))))

;; ---------------------------------------------------------------
;; Self-hosted run subcommand
;; ---------------------------------------------------------------

(test-group "self-hosted run subcommand"
  (test-equal "pkaappi-self-run-file: add.scm returns 7"
    7
    (pkaappi-self-run-file "tests/fixtures/add.scm"))
  (test-equal "pkaappi-self-run-file: factorial.scm returns 120"
    120
    (pkaappi-self-run-file "tests/fixtures/factorial.scm")))

(test-exit)
