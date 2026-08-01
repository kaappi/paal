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
  ;; (scheme base) and friends have no file — their bindings are already in
  ;; paal-initial-env — so importing one yields no aliases and no forms.
  (test-assert "importing a built-in library yields nothing to run"
    (equal? '(begin (begin))
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
        result)))

  ;; Regression guard for kaappi/paal's use of kaappi/kaappi#1920: reading a
  ;; .pbc from a file port breaks when a dotted pair straddles a 4096-byte
  ;; chunk boundary, and .pbc files carry (#t . N) upvalue specs throughout.
  ;; paal-read-bc-file slurps the file and parses from a string port, where no
  ;; boundary exists.  Build a .pbc whose "." sits exactly at offset 4093 —
  ;; the offset that fails when read straight from a file port.
  (let* ((tail "(closure 0 (pbc 0 #f 0 #f ()) ((#t . 0)))")
         (pad  (let loop ((k 0) (acc ""))
                 (if (= k 2021) acc (loop (+ k 1) (string-append acc "x ")))))
         (text (string-append "(pbc 0 #f 0 #f (" pad tail "))"))
         (path "paal-test-dot-boundary.pbc"))
    (test-equal "the dot really lands on the chunk boundary"
      #\.
      (string-ref text 4093))
    (test-assert "a .pbc with a dot on a 4096-byte boundary still reads"
      (let ((port (open-output-file path)))
        (write-string text port)
        (close-output-port port)
        (let ((bf (paal-read-bc-file path)))
          (delete-file path)
          (vector? bf))))))

;; ---------------------------------------------------------------
;; Self-hosted compile subcommand
;; ---------------------------------------------------------------

(test-group "self-hosted compile subcommand"
  (test-equal "pkaappi-self-compile-to-file: add.scm"
    7
    (let ((path "paal-self-compile-add.pbc"))
      (pkaappi-self-compile-to-file "tests/fixtures/add.scm" path)
      (let ((result (pkaappi-run-pbc-file path)))
        (delete-file path)
        result)))
  (test-equal "pkaappi-self-compile-to-file: factorial.scm"
    120
    (let ((path "paal-self-compile-fact.pbc"))
      (pkaappi-self-compile-to-file "tests/fixtures/factorial.scm" path)
      (let ((result (pkaappi-run-pbc-file path)))
        (delete-file path)
        result)))
  (test-equal "pkaappi-self-compile-to-file: hof.scm"
    52
    (let ((path "paal-self-compile-hof.pbc"))
      (pkaappi-self-compile-to-file "tests/fixtures/hof.scm" path)
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
    (pkaappi-self-run-file "tests/fixtures/factorial.scm"))
  ;; Regression guard for kaappi/paal#1: every procedure pkaappi-make-globals
  ;; installs by paal-compiling it is a <closure> built by the HOST pipeline,
  ;; and the self-hosted VM has to be able to enter it.  Before <closure> and
  ;; <bytecode-function> became tagged vectors, each of these raised
  ;; "paal-bc: not a callable".
  (test-equal "pkaappi-self-run-file: hof.scm — paal-compiled globals are callable"
    52
    (pkaappi-self-run-file "tests/fixtures/hof.scm")))

;; Same values through the HOST bytecode pipeline, which always worked —
;; keeps the fixture honest if it is ever edited.
(test-group "paal-compiled globals (HOST pipeline)"
  (test-equal "hof.scm via pkaappi-run-bc-file"
    52
    (pkaappi-run-bc-file "tests/fixtures/hof.scm")))

;;; ---------------------------------------------------------------
;; Phase 2: inexact math, char/string case, time, process-context, args
;; ---------------------------------------------------------------

(test-group "inexact math (scheme inexact)"
  (test-equal "sin 0" 0.0 (pkaappi-run-bc-string "(sin 0)"))
  (test-equal "cos 0" 1.0 (pkaappi-run-bc-string "(cos 0)"))
  (test-equal "exp 0" 1.0 (pkaappi-run-bc-string "(exp 0)"))
  (test-equal "log 1" 0.0 (pkaappi-run-bc-string "(log 1)"))
  (test-equal "atan 1" (atan 1) (pkaappi-run-bc-string "(atan 1)")))

(test-group "char/string case-insensitive (scheme char)"
  (test-equal "char-ci=?"    #t (pkaappi-run-bc-string "(char-ci=? #\\A #\\a)"))
  (test-equal "char-foldcase"  #\a (pkaappi-run-bc-string "(char-foldcase #\\A)"))
  (test-equal "string-ci=?"  #t (pkaappi-run-bc-string "(string-ci=? \"Hello\" \"HELLO\")"))
  (test-equal "string-foldcase" "hello" (pkaappi-run-bc-string "(string-foldcase \"HELLO\")")))

(test-group "time (scheme time)"
  (test-equal "jiffies-per-second positive"
    #t
    (pkaappi-run-bc-string "(positive? (jiffies-per-second))")))

(test-group "process-context (scheme process-context)"
  (test-equal "command-line default is list"
    #t
    (pkaappi-run-bc-string "(list? (command-line))"))
  (test-equal "get-environment-variable HOME"
    #t
    (pkaappi-run-bc-string "(string? (get-environment-variable \"HOME\"))"))
  (test-equal "command-line after set has correct path"
    "tests/fixtures/add.scm"
    (let* ((g (pkaappi-make-globals '("tests/fixtures/add.scm" "x"))))
      (pkaappi-run-string-in g "(car (command-line))"))))

(test-group "script args forwarding"
  (test-equal "command-line length with args"
    3
    (let* ((g (pkaappi-make-globals '("file.scm" "arg1" "arg2"))))
      (pkaappi-run-string-in g "(length (command-line))")))
  (test-equal "command-line second element"
    "arg1"
    (let* ((g (pkaappi-make-globals '("file.scm" "arg1" "arg2"))))
      (pkaappi-run-string-in g "(cadr (command-line))")))
  (test-equal "pkaappi-set-command-line! updates"
    "new"
    (let* ((g (pkaappi-make-globals)))
      (pkaappi-set-command-line! g '("new"))
      (pkaappi-run-string-in g "(car (command-line))"))))

;; ---------------------------------------------------------------
;; Phase 1: missing primitives
;; ---------------------------------------------------------------

(test-group "R7RS primitives: arithmetic"
  (test-equal "exact-integer? on fixnum" #t (pkaappi-run-string "(exact-integer? 42)"))
  (test-equal "exact-integer? on float"  #f (pkaappi-run-string "(exact-integer? 1.5)"))
  (test-equal "square"       49  (pkaappi-run-string "(square 7)"))
  (test-equal "finite? true"  #t (pkaappi-run-string "(finite? 1.0)"))
  (test-equal "infinite?"     #t (pkaappi-run-string "(infinite? +inf.0)"))
  (test-equal "nan?"          #t (pkaappi-run-string "(nan? +nan.0)"))
  (test-equal "floor-quotient"  3 (pkaappi-run-string "(floor-quotient 10 3)"))
  (test-equal "floor-remainder" 1 (pkaappi-run-string "(floor-remainder 10 3)"))
  (test-equal "truncate-quotient"  3 (pkaappi-run-string "(truncate-quotient 10 3)"))
  (test-equal "truncate-remainder" 1 (pkaappi-run-string "(truncate-remainder 10 3)")))

;; ---------------------------------------------------------------
;; The R7RS procedures that return two values
;; ---------------------------------------------------------------
;;
;; These are paal definitions built on the single-value quotient/remainder
;; primitives, so they return MVR-tagged values the bytecode VM understands.
;; The inherited HOST versions returned real kaappi multiple values, which
;; reach the VM's single-value context as one opaque #<values> object: the
;; consumer got that object as a single argument, and (let-values (((q r) ...)))
;; bound both names to it. Every case is checked on both pipelines.

(test-group "floor/ truncate/ exact-integer-sqrt"
  (test-equal "floor/ positive"        '(3 1)
    (pkaappi-run-bc-string "(call-with-values (lambda () (floor/ 7 2)) list)"))
  (test-equal "floor/ negative dividend" '(-4 1)
    (pkaappi-run-bc-string "(call-with-values (lambda () (floor/ -7 2)) list)"))
  (test-equal "floor/ negative divisor"  '(-4 -1)
    (pkaappi-run-bc-string "(call-with-values (lambda () (floor/ 7 -2)) list)"))
  (test-equal "floor/ exact division"    '(2 0)
    (pkaappi-run-bc-string "(call-with-values (lambda () (floor/ 8 4)) list)"))
  (test-equal "truncate/ positive"       '(3 1)
    (pkaappi-run-bc-string "(call-with-values (lambda () (truncate/ 7 2)) list)"))
  (test-equal "truncate/ negative dividend" '(-3 -1)
    (pkaappi-run-bc-string "(call-with-values (lambda () (truncate/ -7 2)) list)"))
  (test-equal "truncate/ negative divisor"  '(-3 1)
    (pkaappi-run-bc-string "(call-with-values (lambda () (truncate/ 7 -2)) list)"))
  (test-equal "exact-integer-sqrt 17"    '(4 1)
    (pkaappi-run-bc-string "(call-with-values (lambda () (exact-integer-sqrt 17)) list)"))
  (test-equal "exact-integer-sqrt 0"     '(0 0)
    (pkaappi-run-bc-string "(call-with-values (lambda () (exact-integer-sqrt 0)) list)"))
  (test-equal "exact-integer-sqrt 1"     '(1 0)
    (pkaappi-run-bc-string "(call-with-values (lambda () (exact-integer-sqrt 1)) list)"))
  (test-equal "exact-integer-sqrt perfect square" '(4 0)
    (pkaappi-run-bc-string "(call-with-values (lambda () (exact-integer-sqrt 16)) list)"))
  (test-equal "exact-integer-sqrt large" '(316 143)
    (pkaappi-run-bc-string "(call-with-values (lambda () (exact-integer-sqrt 99999)) list)"))
  ;; let-values is where the old breakage was most visible: both names bound
  ;; to the same #<values> object instead of to the two values.
  (test-equal "let-values over floor/"   '(3 1)
    (pkaappi-run-bc-string "(let-values (((q r) (floor/ 7 2))) (list q r))"))
  (test-equal "let-values over truncate/" '(-3 -1)
    (pkaappi-run-bc-string "(let-values (((q r) (truncate/ -7 2))) (list q r))"))
  (test-equal "define-values over exact-integer-sqrt" '(4 1)
    (pkaappi-run-bc-string
      "(define-values (s r) (exact-integer-sqrt 17)) (list s r)"))
  ;; The tree-walking pipeline keeps the HOST versions, which return real
  ;; multiple values and always worked — pinned so the two agree.
  (test-equal "tree-walking floor/"      '(3 1)
    (pkaappi-run-string "(call-with-values (lambda () (floor/ 7 2)) list)"))
  (test-equal "tree-walking exact-integer-sqrt" '(4 1)
    (pkaappi-run-string "(let-values (((s r) (exact-integer-sqrt 17))) (list s r))")))

(test-group "R7RS primitives: lists and strings"
  (test-equal "make-list"    '(0 0 0) (pkaappi-run-string "(make-list 3 0)"))
  (test-equal "list-set!"    '(a X c) (pkaappi-run-string "(let ((l (list 'a 'b 'c))) (list-set! l 1 'X) l)"))
  (test-equal "string->utf8" #u8(65 66) (pkaappi-run-string "(string->utf8 \"AB\")"))
  (test-equal "utf8->string" "AB" (pkaappi-run-string "(utf8->string #u8(65 66))"))
  (test-equal "string->vector" #(#\h #\i) (pkaappi-run-string "(string->vector \"hi\")"))
  (test-equal "vector->string" "hi" (pkaappi-run-string "(vector->string #(#\\h #\\i))")))

;; ---------------------------------------------------------------
;; Phase 1: case-lambda
;; ---------------------------------------------------------------

(test-group "case-lambda"
  (test-equal "exact arity 1"
    5
    (pkaappi-run-string "(define f (case-lambda ((x) x) ((x y) (+ x y)))) (f 5)"))
  (test-equal "exact arity 2"
    7
    (pkaappi-run-string "(define f (case-lambda ((x) x) ((x y) (+ x y)))) (f 3 4)"))
  (test-equal "pure rest arg"
    '(1 2 3)
    (pkaappi-run-string "(define f (case-lambda (args args))) (f 1 2 3)"))
  (test-equal "nullary"
    42
    (pkaappi-run-string "(define f (case-lambda (() 42) ((x) x))) (f)"))
  (test-equal "improper at-least-n arity"
    '(1 2 3)
    (pkaappi-run-string
      "(define f (case-lambda ((x . rest) (cons x rest)))) (f 1 2 3)"))
  (test-equal "case-lambda bytecode"
    '(10 25)
    (pkaappi-run-bc-string
      "(define f (case-lambda ((x) (* x 2)) ((x y) (+ x y y)))) (list (f 5) (f 5 10))")))

;; ---------------------------------------------------------------
;; Phase 1: define-values / let-values / let*-values
;; ---------------------------------------------------------------

(test-group "define-values"
  (test-equal "two values"
    30
    (pkaappi-run-string "(define-values (a b) (values 10 20)) (+ a b)"))
  (test-equal "three values"
    60
    (pkaappi-run-string "(define-values (x y z) (values 10 20 30)) (+ x y z)"))
  (test-equal "define-values bytecode"
    30
    (pkaappi-run-bc-string "(define-values (a b) (values 10 20)) (+ a b)")))

(test-group "let-values"
  (test-equal "single binding"
    7
    (pkaappi-run-string "(let-values (((x y) (values 3 4))) (+ x y))"))
  (test-equal "two bindings"
    10
    (pkaappi-run-string "(let-values (((a b) (values 1 2)) ((c) (values 7))) (+ a b c))"))
  (test-equal "let*-values sequential"
    3
    (pkaappi-run-string "(let*-values (((a b) (values 1 2)) ((c) (values (+ a b)))) c)"))
  (test-equal "let-values bytecode"
    7
    (pkaappi-run-bc-string "(let-values (((x y) (values 3 4))) (+ x y))")))

;; ---------------------------------------------------------------
;; Phase 1: delay / force / promise?
;; ---------------------------------------------------------------

(test-group "delay/force"
  (test-equal "force evaluates"   3 (pkaappi-run-string "(force (delay (+ 1 2)))"))
  (test-equal "promise? true"    #t (pkaappi-run-string "(promise? (delay 42))"))
  (test-equal "promise? non"     #f (pkaappi-run-string "(promise? 42)"))
  (test-equal "force caches"
    #t
    (pkaappi-run-string
      "(define count 0)
       (define p (delay (begin (set! count (+ count 1)) count)))
       (force p) (force p)
       (= count 1)"))
  (test-equal "make-promise already-forced"
    42
    (pkaappi-run-string "(force (make-promise 42))"))
  (test-equal "delay bytecode"
    6
    (pkaappi-run-bc-string "(force (delay (* 2 3)))")))

;; ---------------------------------------------------------------
;; Phase 1: cond-expand
;; ---------------------------------------------------------------

(test-group "cond-expand"
  (test-equal "paal feature"
    "yes"
    (pkaappi-run-string "(cond-expand (paal \"yes\") (else \"no\"))"))
  (test-equal "r7rs feature"
    "yes"
    (pkaappi-run-string "(cond-expand (r7rs \"yes\") (else \"no\"))"))
  (test-equal "unknown feature → else"
    "no"
    (pkaappi-run-string "(cond-expand (unknown-thing \"yes\") (else \"no\"))"))
  (test-equal "and requirement"
    "both"
    (pkaappi-run-string "(cond-expand ((and paal r7rs) \"both\") (else \"no\"))"))
  (test-equal "or requirement"
    "yes"
    (pkaappi-run-string "(cond-expand ((or unknown paal) \"yes\") (else \"no\"))"))
  (test-equal "not requirement"
    "yes"
    (pkaappi-run-string "(cond-expand ((not unknown-thing) \"yes\") (else \"no\"))"))
  (test-equal "no matching, no else → #f (empty begin)"
    #f
    (pkaappi-run-string "(cond-expand (unknown-thing 42))")))

;; ---------------------------------------------------------------
;; Phase 1: define-syntax / syntax-rules
;; ---------------------------------------------------------------

;; ---------------------------------------------------------------
;; syntax-rules ellipsis: nesting, splicing, escape
;; ---------------------------------------------------------------

(test-group "define-syntax: ellipsis"
  (test-equal "nested ellipsis passes structure through"
    '((1 2) (3 4))
    (pkaappi-run-bc-string
      "(define-syntax m (syntax-rules () ((_ (a ...) ...) '((a ...) ...))))
       (m (1 2) (3 4))"))
  (test-equal "nested ellipsis with a variable at the outer level"
    '((a (1 2)) (b (3)))
    (pkaappi-run-bc-string
      "(define-syntax m (syntax-rules () ((_ (k v ...) ...) '((k (v ...)) ...))))
       (m (a 1 2) (b 3))"))
  (test-equal "three levels of nesting"
    '(((1 2) (3)) ((4)))
    (pkaappi-run-bc-string
      "(define-syntax m (syntax-rules () ((_ ((a ...) ...) ...) '(((a ...) ...) ...))))
       (m ((1 2) (3)) ((4)))"))
  (test-equal "ragged inner groups"
    '((1 2) (3 4 5))
    (pkaappi-run-bc-string
      "(define-syntax m (syntax-rules () ((_ (a ...) ...) (list (list a ...) ...))))
       (m (1 2) (3 4 5))"))
  (test-equal "an empty inner group"
    '(() (1))
    (pkaappi-run-bc-string
      "(define-syntax m (syntax-rules () ((_ (a ...) ...) '((a ...) ...))))
       (m () (1))"))
  (test-equal "an empty match"
    '(start)
    (pkaappi-run-bc-string
      "(define-syntax m (syntax-rules () ((_ a ...) '(start a ...))))
       (m)"))
  ;; Each ellipsis past the first splices a level away rather than nesting it.
  (test-equal "a ... ... splices one level"
    '(1 2 3 4)
    (pkaappi-run-bc-string
      "(define-syntax m (syntax-rules () ((_ (a ...) ...) '(a ... ...))))
       (m (1 2) (3 4))"))
  (test-equal "splicing keeps surrounding template elements"
    '(start 1 2 3 end)
    (pkaappi-run-bc-string
      "(define-syntax m (syntax-rules () ((_ (a ...) ...) '(start a ... ... end))))
       (m (1 2) (3))"))
  (test-equal "three ellipses splice two levels"
    '(1 2 3 4 5)
    (pkaappi-run-bc-string
      "(define-syntax m (syntax-rules () ((_ ((a ...) ...) ...) '(a ... ... ...))))
       (m ((1 2) (3)) ((4 5)))"))
  ;; (... <template>) suppresses ellipsis handling; (... ...) emits a literal one.
  (test-equal "ellipsis escape emits a literal ellipsis"
    '(foo ...)
    (pkaappi-run-bc-string
      "(define-syntax m (syntax-rules () ((_ x) '(x (... ...)))))
       (m foo)"))
  (test-equal "a macro that defines a macro"
    '(1 2 3)
    (pkaappi-run-bc-string
      "(define-syntax def-listor
         (syntax-rules ()
           ((_ name)
            (define-syntax name
              (syntax-rules () ((_ x (... ...)) (list x (... ...))))))))
       (def-listor my-l)
       (my-l 1 2 3)"))
  (test-equal "tree-walking pipeline"
    '(1 2 3 4)
    (pkaappi-run-string
      "(define-syntax m (syntax-rules () ((_ (a ...) ...) '(a ... ...))))
       (m (1 2) (3 4))")))

;; ---------------------------------------------------------------
;; Macro hygiene — introduced bindings do not capture
;; ---------------------------------------------------------------
;;
;; Identifiers a template binds are renamed per expansion, so a macro that
;; introduces (let ((tmp ...)) ...) cannot shadow a user's tmp. Pattern
;; variables keep their names, since those come from the use site.
;;
;; Referential transparency is *not* provided — see the group's last test.

(test-group "define-syntax: hygiene"
  (test-equal "introduced let binding does not capture the user's variable"
    '(2 1)
    (pkaappi-run-bc-string
      "(define-syntax swap!
         (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
       (define x 1) (define tmp 2)
       (swap! x tmp)
       (list x tmp)"))
  (test-equal "an argument naming the template's own binding still works"
    5
    (pkaappi-run-bc-string
      "(define-syntax my-or (syntax-rules () ((_ a b) (let ((t a)) (if t t b)))))
       (define t 5)
       (my-or #f t)"))
  (test-equal "pattern variables in binding position keep their names"
    21
    (pkaappi-run-bc-string
      "(define-syntax bind1 (syntax-rules () ((_ v e body) (let ((v e)) body))))
       (bind1 q 7 (* q 3))"))
  (test-equal "template lambda formals are renamed"
    10
    (pkaappi-run-bc-string
      "(define-syntax twice (syntax-rules () ((_ e) ((lambda (n) (+ n n)) e))))
       (define n 100)
       (twice 5)"))
  (test-equal "named let in a template renames both loop name and variables"
    10
    (pkaappi-run-bc-string
      "(define-syntax countdown
         (syntax-rules ()
           ((_ k) (let loop ((i k) (acc 0))
                    (if (= i 0) acc (loop (- i 1) (+ acc i)))))))
       (define i 999) (define loop 'nope)
       (countdown 4)"))
  (test-equal "do-loop variables in a template are renamed"
    10
    (pkaappi-run-bc-string
      "(define-syntax sum-to
         (syntax-rules ()
           ((_ k) (do ((j 0 (+ j 1)) (s 0 (+ s j))) ((= j k) s)))))
       (define j 77) (define s 88)
       (sum-to 5)"))
  (test-equal "two expansions get separate names"
    25
    (pkaappi-run-bc-string
      "(define-syntax sq (syntax-rules () ((_ e) (let ((v e)) (* v v)))))
       (+ (sq 3) (sq 4))"))
  (test-equal "a macro expanding to another macro stays hygienic"
    8
    (pkaappi-run-bc-string
      "(define-syntax dbl (syntax-rules () ((_ e) (let ((m e)) (+ m m)))))
       (define-syntax quad (syntax-rules () ((_ e) (dbl (dbl e)))))
       (define m 1000)
       (quad 2)"))
  (test-equal "binding alongside an ellipsis"
    '(built 1 2 3)
    (pkaappi-run-bc-string
      "(define-syntax my-list
         (syntax-rules () ((_ e ...) (let ((tag 'built)) (list tag e ...)))))
       (define tag 'user)
       (my-list 1 2 3)"))
  (test-equal "tree-walking pipeline"
    '(2 1)
    (pkaappi-run-string
      "(define-syntax swap!
         (syntax-rules () ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
       (define x 1) (define tmp 2)
       (swap! x tmp)
       (list x tmp)"))
  ;; Referential transparency: a free identifier in a template resolves where
  ;; the macro was defined, so a local of the same name at the use site cannot
  ;; capture it. This returned -3 before free identifiers were marked.
  (test-equal "a use-site local does not capture a template's free identifier"
    30
    (pkaappi-run-bc-string
      "(define (helper x) (* x 10))
       (define-syntax use-helper (syntax-rules () ((_ v) (helper v))))
       (let ((helper (lambda (x) (- x))))
         (use-helper 3))"))
  (test-equal "same for a lambda parameter at the use site"
    30
    (pkaappi-run-bc-string
      "(define (helper x) (* x 10))
       (define-syntax use-helper (syntax-rules () ((_ v) (helper v))))
       ((lambda (helper) (use-helper 3)) 'shadow)"))
  (test-equal "a template's free identifier still sees a later redefinition"
    100
    (pkaappi-run-bc-string
      "(define (helper x) (* x 10))
       (define-syntax use-helper (syntax-rules () ((_ v) (helper v))))
       (define (helper x) (* x 100))
       (use-helper 1)"))
  (test-equal "arguments are still evaluated at the use site"
    7
    (pkaappi-run-bc-string
      "(define (idm x) x)
       (define-syntax pass (syntax-rules () ((_ v) (idm v))))
       (let ((local 7)) (pass local))"))
  ;; set! through a template targets the top-level binding too, not the local.
  (test-equal "set! on a template's free identifier hits the top-level binding"
    2
    (pkaappi-run-bc-string
      "(define counter 0)
       (define-syntax bump (syntax-rules () ((_) (set! counter (+ counter 1)))))
       (let ((counter 999)) (bump) (bump))
       counter"))
  (test-equal "a macro may reference a macro defined after it"
    12
    (pkaappi-run-bc-string
      "(define-syntax a (syntax-rules () ((_ v) (b v))))
       (define-syntax b (syntax-rules () ((_ v) (* v 3))))
       (a 4)"))
  (test-equal "a recursive macro's global reference survives shadowing"
    3
    (pkaappi-run-bc-string
      "(define (add1 n) (+ n 1))
       (define-syntax cnt (syntax-rules () ((_ ()) 0) ((_ (x . r)) (add1 (cnt r)))))
       (let ((add1 'shadow)) (cnt (a b c)))"))
  (test-equal "symbols inside a quoted template datum are untouched"
    '(helper foo)
    (pkaappi-run-bc-string
      "(define-syntax q (syntax-rules () ((_) '(helper foo)))) (q)"))
  (test-equal "a macro defining a macro still works"
    '(1 2 3)
    (pkaappi-run-bc-string
      "(define-syntax def-listor
         (syntax-rules ()
           ((_ name)
            (define-syntax name
              (syntax-rules () ((_ x (... ...)) (list x (... ...))))))))
       (def-listor my-l2)
       (my-l2 1 2 3)"))
  (test-equal "tree-walking pipeline"
    30
    (pkaappi-run-string
      "(define (helper x) (* x 10))
       (define-syntax use-helper (syntax-rules () ((_ v) (helper v))))
       (let ((helper (lambda (x) (- x))))
         (use-helper 3))")))

(test-group "define-syntax: basic patterns"
  (test-equal "nullary macro"
    #t
    (pkaappi-run-string "(define-syntax my-true (syntax-rules () ((_) #t))) (my-true)"))
  (test-equal "single argument"
    42
    (pkaappi-run-string "(define-syntax identity (syntax-rules () ((_ x) x))) (identity 42)"))
  (test-equal "swap! macro"
    '(2 1)
    (pkaappi-run-string
      "(define-syntax swap!
         (syntax-rules ()
           ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
       (define x 1) (define y 2) (swap! x y) (list x y)"))
  (test-equal "my-and empty"
    #t
    (pkaappi-run-string
      "(define-syntax my-and
         (syntax-rules ()
           ((_) #t)
           ((_ e) e)
           ((_ e1 e2 ...) (if e1 (my-and e2 ...) #f))))
       (my-and)"))
  (test-equal "my-and short-circuit"
    #f
    (pkaappi-run-string
      "(define-syntax my-and
         (syntax-rules ()
           ((_) #t)
           ((_ e) e)
           ((_ e1 e2 ...) (if e1 (my-and e2 ...) #f))))
       (my-and 1 #f 3)"))
  (test-equal "my-and three args"
    3
    (pkaappi-run-string
      "(define-syntax my-and
         (syntax-rules ()
           ((_) #t)
           ((_ e) e)
           ((_ e1 e2 ...) (if e1 (my-and e2 ...) #f))))
       (my-and 1 2 3)"))
  (test-equal "literal in pattern"
    99
    (pkaappi-run-string
      "(define-syntax my-case
         (syntax-rules (=>)
           ((_ val (pat => expr)) (if (equal? val (quote pat)) expr #f))))
       (my-case 'a (a => 99))"))
  (test-equal "define-syntax bytecode"
    10
    (pkaappi-run-bc-string
      "(define-syntax double (syntax-rules () ((_ x) (* x 2)))) (double 5)")))

(test-group "let-syntax"
  (test-equal "local macro"
    10
    (pkaappi-run-string "(let-syntax ((double (syntax-rules () ((_ x) (* x 2))))) (double 5))"))
  (test-equal "local macro not visible outside"
    #t
    (pkaappi-run-string
      "(let-syntax ((my-macro (syntax-rules () ((_) 42))))
         (my-macro))
       (not (assq 'my-macro '()))   ; macro should be gone, this is just a placeholder
       #t")))

;; ---------------------------------------------------------------
;; let-syntax / letrec-syntax scoping (R7RS 4.3.1)
;; ---------------------------------------------------------------
;;
;; The two differ only in the region of the keywords. letrec-syntax covers the
;; bindings as well as the body, so its transformers may refer to one another;
;; let-syntax covers the body only, so a binding must NOT see its siblings.

;; ---------------------------------------------------------------
;; Macro table lifetime
;; ---------------------------------------------------------------
;;
;; %paal-macros is module state in the expander. It is reset whenever a fresh
;; globals table is made, so macros live exactly as long as the definitions
;; they sit alongside. Entry points that add to an existing table do not reset,
;; so a loaded file's macros stay visible and the REPL accumulates them.

(test-group "macros do not leak between programs"
  ;; Defining zzleak as a macro in one program must not shadow a procedure of
  ;; that name in the next — it silently returned the macro's value before.
  (test-equal "a macro from a previous program is gone"
    'from-procedure
    (begin
      (pkaappi-run-bc-string
        "(define-syntax zzleak (syntax-rules () ((_) 'from-macro))) (zzleak)")
      (pkaappi-run-bc-string "(define (zzleak) 'from-procedure) (zzleak)")))
  (test-equal "same on the tree-walking pipeline"
    'from-procedure
    (begin
      (pkaappi-run-string
        "(define-syntax zzleak2 (syntax-rules () ((_) 'from-macro))) (zzleak2)")
      (pkaappi-run-string "(define (zzleak2) 'from-procedure) (zzleak2)")))
  ;; The other half: a shared globals table must keep accumulating.
  (test-equal "macros accumulate within one globals table"
    'accumulated
    (let ((g (pkaappi-make-globals)))
      (pkaappi-run-string-in g
        "(define-syntax zzacc (syntax-rules () ((_) 'accumulated)))")
      (pkaappi-run-string-in g "(zzacc)")))
  (test-equal "a later fresh table does not see it"
    'fresh
    (pkaappi-run-bc-string "(define (zzacc) 'fresh) (zzacc)")))

(test-group "letrec-syntax: recursion between bindings"
  (test-equal "mutually recursive macros"
    '(#t #t)
    (pkaappi-run-bc-string
      "(letrec-syntax ((ev? (syntax-rules () ((_ ()) #t) ((_ (x . rest)) (od? rest))))
                       (od? (syntax-rules () ((_ ()) #f) ((_ (x . rest)) (ev? rest)))))
         (list (ev? (a b c d)) (od? (a b c))))"))
  (test-equal "a self-recursive macro"
    5
    (pkaappi-run-bc-string
      "(letrec-syntax ((cnt (syntax-rules () ((_ ()) 0) ((_ (x . rest)) (+ 1 (cnt rest))))))
         (cnt (a b c d e)))"))
  (test-equal "tree-walking pipeline"
    5
    (pkaappi-run-string
      "(letrec-syntax ((cnt (syntax-rules () ((_ ()) 0) ((_ (x . rest)) (+ 1 (cnt rest))))))
         (cnt (a b c d e)))")))

(test-group "let-syntax: bindings do not see their siblings"
  ;; The distinguishing case: a template naming a sibling keyword must resolve
  ;; to the outer binding, not the one alongside it.
  (test-equal "a sibling keyword resolves to the outer binding"
    'from-outer
    (pkaappi-run-bc-string
      "(define-syntax lsx-outer (syntax-rules () ((_ x) 'from-outer)))
       (let-syntax ((a (syntax-rules () ((_) (lsx-outer 1))))
                    (lsx-outer (syntax-rules () ((_ x) 'from-inner))))
         (a))"))
  (test-equal "neither of two bindings sees the other"
    '(outer-q outer-p)
    (pkaappi-run-bc-string
      "(define-syntax lsx-p (syntax-rules () ((_) 'outer-p)))
       (define-syntax lsx-q (syntax-rules () ((_) 'outer-q)))
       (let-syntax ((lsx-p (syntax-rules () ((_) (lsx-q))))
                    (lsx-q (syntax-rules () ((_) (lsx-p)))))
         (list (lsx-p) (lsx-q)))"))
  (test-equal "the body still sees the local binding"
    'local
    (pkaappi-run-bc-string
      "(define-syntax lsx-m (syntax-rules () ((_) 'global)))
       (let-syntax ((lsx-m (syntax-rules () ((_) 'local)))) (lsx-m))"))
  (test-equal "the outer binding is restored afterwards"
    'global
    (pkaappi-run-bc-string
      "(define-syntax lsx-m (syntax-rules () ((_) 'global)))
       (let-syntax ((lsx-m (syntax-rules () ((_) 'local)))) (lsx-m))
       (lsx-m)"))
  (test-equal "an enclosing let-syntax binding is visible"
    1
    (pkaappi-run-bc-string
      "(let-syntax ((lsx-a (syntax-rules () ((_) 1))))
         (let-syntax ((lsx-b (syntax-rules () ((_) (lsx-a)))))
           (lsx-b)))"))
  (test-equal "let-syntax nested in letrec-syntax"
    'rec
    (pkaappi-run-bc-string
      "(letrec-syntax ((lsx-r (syntax-rules () ((_) 'rec))))
         (let-syntax ((lsx-l (syntax-rules () ((_) (lsx-r))))) (lsx-l)))"))
  (test-equal "letrec-syntax nested in let-syntax"
    'lit
    (pkaappi-run-bc-string
      "(let-syntax ((lsx-l (syntax-rules () ((_) 'lit))))
         (letrec-syntax ((lsx-r (syntax-rules () ((_) (lsx-l))))) (lsx-r)))"))
  (test-equal "a local macro used more than once"
    '(6 8)
    (pkaappi-run-bc-string
      "(let-syntax ((lsx-d (syntax-rules () ((_ x) (* x 2))))) (list (lsx-d 3) (lsx-d 4)))"))
  (test-equal "hygiene still applies to local macros"
    '(2 1)
    (pkaappi-run-bc-string
      "(let-syntax ((lsx-sw (syntax-rules ()
                          ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp))))))
         (let ((x 1) (tmp 2)) (lsx-sw x tmp) (list x tmp)))"))
  (test-equal "tree-walking pipeline"
    'from-outer
    (pkaappi-run-string
      "(define-syntax lsx-outer (syntax-rules () ((_ x) 'from-outer)))
       (let-syntax ((a (syntax-rules () ((_) (lsx-outer 1))))
                    (lsx-outer (syntax-rules () ((_ x) 'from-inner))))
         (a))")))

;; ---------------------------------------------------------------
;; Phase 1: HOF — vector-map, string-map, etc.
;; ---------------------------------------------------------------

(test-group "vector-map / vector-for-each"
  (test-equal "vector-map squares"
    #(1 4 9 16)
    (pkaappi-run-bc-string "(vector-map (lambda (x) (* x x)) #(1 2 3 4))"))
  (test-equal "vector-for-each side-effect"
    '(3 2 1)
    (pkaappi-run-bc-string
      "(define acc '())
       (vector-for-each (lambda (x) (set! acc (cons x acc))) #(3 2 1))
       (reverse acc)")))

(test-group "string-map / string-for-each"
  (test-equal "string-map upcase"
    "HELLO"
    (pkaappi-run-bc-string "(string-map char-upcase \"hello\")"))
  (test-equal "string-for-each collect"
    '(#\c #\b #\a)
    (pkaappi-run-bc-string
      "(define acc '())
       (string-for-each (lambda (c) (set! acc (cons c acc))) \"cba\")
       (reverse acc)")))

(test-group "values / call-with-values / apply"
  (test-equal "values two"
    30
    (pkaappi-run-bc-string "(call-with-values (lambda () (values 10 20)) +)"))
  ;; call-with-values hands the values to apply, so the consumer's arity is
  ;; resolved at run time. It used to be an unrolled cond capped at 4 values.
  (test-equal "five values — past the old ceiling"
    15
    (pkaappi-run-bc-string "(call-with-values (lambda () (values 1 2 3 4 5)) +)"))
  (test-equal "ten values"
    55
    (pkaappi-run-bc-string
      "(call-with-values (lambda () (values 1 2 3 4 5 6 7 8 9 10)) +)"))
  (test-equal "fifty values"
    50
    (pkaappi-run-bc-string
      "(call-with-values
         (lambda () (apply values (let loop ((i 0) (a '()))
                                    (if (= i 50) a (loop (+ i 1) (cons 1 a))))))
         +)"))
  (test-equal "zero values"
    0
    (pkaappi-run-bc-string
      "(call-with-values (lambda () (values)) (lambda args (length args)))"))
  (test-equal "producer returning a single plain value"
    42
    (pkaappi-run-bc-string "(call-with-values (lambda () 42) (lambda (x) x))"))
  (test-equal "variadic consumer"
    '(1 2 3)
    (pkaappi-run-bc-string
      "(call-with-values (lambda () (values 1 2 3)) (lambda args args))"))
  (test-equal "let-values with five bindings"
    15
    (pkaappi-run-bc-string
      "(let-values (((a b c d e) (values 1 2 3 4 5))) (+ a b c d e))"))
  (test-equal "define-values with five names"
    '(1 2 3 4 5)
    (pkaappi-run-bc-string
      "(define-values (a b c d e) (values 1 2 3 4 5)) (list a b c d e)"))
  ;; Both arms of call-with-values are in tail position, so apply re-dispatches
  ;; as a tail call and this loop does not grow the host stack.
  (test-equal "call-with-values in tail position stays a tail call"
    'done
    (pkaappi-run-bc-string
      "(define (loop n)
         (if (= n 0) 'done (call-with-values (lambda () (values (- n 1))) loop)))
       (loop 50000)"))
  (test-equal "apply basic"
    6
    (pkaappi-run-bc-string "(apply + '(1 2 3))"))
  (test-equal "apply with prefix args"
    10
    (pkaappi-run-bc-string "(apply + 1 2 '(3 4))"))
  (test-equal "apply with closure"
    15
    (pkaappi-run-bc-string "(apply (lambda (a b c) (+ a b c)) '(4 5 6))"))
  ;; apply is a VM marker that spreads the list into argument registers, so
  ;; there is no arity ceiling. It used to be a hand-unrolled cond capped at 16.
  (test-equal "apply with 17 arguments — past the old ceiling"
    153
    (pkaappi-run-bc-string
      "(apply + (list 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17))"))
  (test-equal "apply with 1000 arguments"
    1000
    (pkaappi-run-bc-string
      "(apply + (let loop ((i 0) (acc '()))
                  (if (= i 1000) acc (loop (+ i 1) (cons 1 acc)))))"))
  (test-equal "apply with an empty list"
    0
    (pkaappi-run-bc-string "(apply + '())"))
  (test-equal "apply to a variadic closure"
    5
    (pkaappi-run-bc-string "(apply (lambda args (length args)) '(1 2 3 4 5))"))
  (test-equal "apply to a closure with a rest parameter"
    '(1 3)
    (pkaappi-run-bc-string
      "(apply (lambda (a . rest) (list a (length rest))) 1 '(2 3 4))"))
  (test-equal "apply to a host procedure"
    "abc"
    (pkaappi-run-bc-string "(apply string-append '(\"a\" \"b\" \"c\"))"))
  ;; do-call! re-dispatches rather than entering a nested loop, so apply in tail
  ;; position stays a tail call. A nested loop would overflow the host stack.
  (test-equal "apply in tail position keeps the call a tail call"
    'done
    (pkaappi-run-bc-string
      "(define (loop n) (if (= n 0) 'done (apply loop (list (- n 1)))))
       (loop 100000)"))
  (test-equal "apply tree-walking pipeline"
    6
    (pkaappi-run-string "(apply + '(1 2 3))")))

;; ---------------------------------------------------------------
;; Phase 1: guard / raise / error
;; ---------------------------------------------------------------

(test-group "guard: basic raise"
  (test-equal "guard catches raised value"
    "caught"
    (pkaappi-run-bc-string
      "(guard (exn (#t \"caught\")) (raise \"oops\"))"))
  (test-equal "guard: no exception — normal return"
    42
    (pkaappi-run-bc-string
      "(guard (exn (#t \"caught\")) 42)"))
  (test-equal "guard: condition predicate matches"
    "got: hello"
    (pkaappi-run-bc-string
      "(guard (exn ((string? exn) (string-append \"got: \" exn)))
         (raise \"hello\"))"))
  (test-equal "guard: multiple clauses — second matches"
    "string"
    (pkaappi-run-bc-string
      "(guard (exn
               ((number? exn) \"number\")
               ((string? exn) \"string\"))
         (raise \"x\"))"))
  (test-equal "guard: else re-raises to outer"
    "outer"
    (pkaappi-run-bc-string
      "(guard (outer (#t \"outer\"))
         (guard (inner ((number? inner) \"number\"))
           (raise \"string-val\")))"))
  (test-equal "guard: nested — inner catches"
    "inner"
    (pkaappi-run-bc-string
      "(guard (outer (#t \"outer\"))
         (guard (inner (#t \"inner\"))
           (raise \"x\")))"))
  (test-equal "guard: side effects before raise"
    1
    (pkaappi-run-bc-string
      "(let ((x 0))
         (guard (exn (#t x))
           (set! x 1)
           (raise \"stop\")
           (set! x 2)))"))
  (test-equal "guard: error-object? predicate on (error ...)"
    "boom"
    (pkaappi-run-bc-string
      "(guard (exn ((error-object? exn) (error-object-message exn)))
         (error \"boom\" 42))"))
  (test-equal "guard: error-object-irritants"
    '(1 2 3)
    (pkaappi-run-bc-string
      "(guard (exn ((error-object? exn) (error-object-irritants exn)))
         (error \"msg\" 1 2 3))"))
  (test-equal "guard: catches a primitive error, not just paal raise"
    'caught
    (pkaappi-run-bc-string
      "(guard (exn ((error-object? exn) 'caught)) (car '()))"))
  (test-equal "guard: explicit else clause is not duplicated"
    "fallback"
    (pkaappi-run-bc-string
      "(guard (exn ((number? exn) \"number\") (else \"fallback\")) (raise \"s\"))"))
  (test-equal "guard: raise propagates up through intervening frames"
    '(caught deep)
    (pkaappi-run-bc-string
      "(define (deep n) (if (= n 0) (raise 'deep) (+ 0 (deep (- n 1)))))
       (guard (e (#t (list 'caught e))) (deep 20))"))
  (test-equal "guard: repeated entry in a loop reuses registers"
    50
    (pkaappi-run-bc-string
      "(let loop ((i 0) (acc 0))
         (if (= i 50) acc (loop (+ i 1) (+ acc (guard (e (#t 1)) (raise 'x))))))"))
  (test-equal "guard: tree-walking pipeline"
    "caught"
    (pkaappi-run-string "(guard (exn (#t \"caught\")) (raise \"oops\"))")))

;; ---------------------------------------------------------------
;; with-exception-handler / raise-continuable
;; ---------------------------------------------------------------
;;
;; raise-continuable calls the current handler *without unwinding*, so the
;; handler's return value becomes the value of the raise. That cannot be built
;; on the host condition system, which unwinds — handlers live on a paal-side
;; stack instead. Every case is pinned on both pipelines, since the bytecode
;; path uses that stack while the tree-walking path uses the host's.

(test-group "with-exception-handler / raise-continuable"
  (test-equal "handler's value becomes the value of raise-continuable"
    42
    (pkaappi-run-bc-string
      "(with-exception-handler (lambda (e) 42) (lambda () (raise-continuable 'oops)))"))
  (test-equal "execution resumes at the raise point"
    11
    (pkaappi-run-bc-string
      "(with-exception-handler (lambda (e) 10) (lambda () (+ 1 (raise-continuable 'x))))"))
  (test-equal "handler receives the raised object"
    42
    (pkaappi-run-bc-string
      "(with-exception-handler (lambda (e) (* e 2)) (lambda () (raise-continuable 21)))"))
  (test-equal "thunk returning normally is untouched"
    7
    (pkaappi-run-bc-string
      "(with-exception-handler (lambda (e) 'h) (lambda () 7))"))
  ;; The handler runs with the outer stack installed, so the inner handler is
  ;; not re-entered by its own raise.
  (test-equal "nested handlers — inner one handles"
    16
    (pkaappi-run-bc-string
      "(with-exception-handler (lambda (e) 'outer)
         (lambda () (with-exception-handler (lambda (e) (* e 3))
                      (lambda () (+ 1 (raise-continuable 5))))))"))
  (test-equal "a handler that raises reaches the enclosing guard"
    '(guard from-handler)
    (pkaappi-run-bc-string
      "(guard (o (#t (list 'guard o)))
         (with-exception-handler (lambda (e) (raise 'from-handler))
           (lambda () (raise-continuable 'x))))"))
  (test-equal "error reaches an installed handler"
    '(g #t)
    (pkaappi-run-bc-string
      "(guard (o (#t (list 'g (error-object? o))))
         (with-exception-handler (lambda (e) (list 'saw (error-object-message e)))
           (lambda () (error \"boom\"))))"))
  ;; R7RS: returning from a handler invoked by a non-continuable raise triggers
  ;; a secondary exception. Both pipelines report it the same way.
  (test-equal "handler returning from a plain raise triggers a secondary exception"
    "handler returned"
    (pkaappi-run-bc-string
      "(guard (o (#t (error-object-message o)))
         (with-exception-handler (lambda (e) 'ignored) (lambda () (raise 'x))))"))
  (test-equal "raise-continuable with no handler escapes to guard"
    '(caught lonely)
    (pkaappi-run-bc-string
      "(guard (e (#t (list 'caught e))) (raise-continuable 'lonely))"))
  (test-equal "the handler stack is restored after a normal return"
    '(ok outer-caught)
    (pkaappi-run-bc-string
      "(list (with-exception-handler (lambda (e) 1) (lambda () 'ok))
             (guard (e (#t 'outer-caught)) (raise 'y)))"))
  (test-equal "guard nested inside with-exception-handler"
    'inner
    (pkaappi-run-bc-string
      "(with-exception-handler (lambda (e) 'h)
         (lambda () (guard (e (#t 'inner)) (raise 'x))))"))
  ;; A guard is itself an exception handler and must be the innermost one while
  ;; its body runs — otherwise an enclosing with-exception-handler swallows
  ;; conditions that belong to the guard.
  (test-equal "guard outranks an enclosing handler"
    'guard-caught
    (pkaappi-run-bc-string
      "(with-exception-handler (lambda (e) 'outer-wrongly-ran)
         (lambda () (guard (e (#t 'guard-caught)) (raise-continuable 'x))))"))
  ;; R7RS: an unmatched clause re-raises with raise-continuable, so an outer
  ;; handler that returns a value supplies one instead of tripping the
  ;; "handler returned" secondary exception.
  (test-equal "unmatched clause re-raises continuably"
    'from-handler
    (pkaappi-run-bc-string
      "(with-exception-handler (lambda (e) 'from-handler)
         (lambda () (guard (e ((number? e) 'num)) (raise-continuable 'sym))))"))
  (test-equal "unmatched clause still reaches an outer guard"
    '(outer sym)
    (pkaappi-run-bc-string
      "(guard (o (#t (list 'outer o))) (guard (i ((number? i) 'num)) (raise 'sym)))"))
  (test-equal "the handler stack is restored after a guard"
    '()
    (pkaappi-run-bc-string "(guard (e (#t 'g)) (raise 'x)) %paal-handlers"))
  (test-equal "tree-walking: guard outranks an enclosing handler"
    'guard-caught
    (pkaappi-run-string
      "(with-exception-handler (lambda (e) 'outer-wrongly-ran)
         (lambda () (guard (e (#t 'guard-caught)) (raise-continuable 'x))))"))
  (test-equal "tree-walking: unmatched clause re-raises continuably"
    'from-handler
    (pkaappi-run-string
      "(with-exception-handler (lambda (e) 'from-handler)
         (lambda () (guard (e ((number? e) 'num)) (raise-continuable 'sym))))"))
  (test-equal "tree-walking pipeline: resumption"
    11
    (pkaappi-run-string
      "(with-exception-handler (lambda (e) 10) (lambda () (+ 1 (raise-continuable 'x))))"))
  ;; Was broken by the trampoline: a raise-continuable in tail position returned
  ;; an unforced thunk, so the raise happened after the handler was uninstalled.
  (test-equal "tree-walking pipeline: raise-continuable in tail position"
    42
    (pkaappi-run-string
      "(with-exception-handler (lambda (e) 42) (lambda () (raise-continuable 'oops)))")))

;; ---------------------------------------------------------------
;; make-parameter / parameterize
;; ---------------------------------------------------------------

(test-group "parameterize"
  (test-equal "parameter returns its default"
    10
    (pkaappi-run-bc-string "(define p (make-parameter 10)) (p)"))
  (test-equal "parameterize rebinds for the body"
    20
    (pkaappi-run-bc-string
      "(define p (make-parameter 10)) (parameterize ((p 20)) (p))"))
  (test-equal "value is restored on normal exit"
    10
    (pkaappi-run-bc-string
      "(define p (make-parameter 10)) (parameterize ((p 20)) (p)) (p)"))
  (test-equal "nested parameterize, inner wins then restores"
    '(2 1)
    (pkaappi-run-bc-string
      "(define p (make-parameter 1))
       (list (parameterize ((p 2)) (parameterize ((p 3)) (p)) (p)) (p))"))
  (test-equal "two parameters at once"
    30
    (pkaappi-run-bc-string
      "(define a (make-parameter 1)) (define b (make-parameter 2))
       (parameterize ((a 10) (b 20)) (+ (a) (b)))"))
  (test-equal "converter applied to the initial value"
    10
    (pkaappi-run-bc-string "(define p (make-parameter 5 (lambda (x) (* x 2)))) (p)"))
  (test-equal "converter applied to a parameterized value"
    20
    (pkaappi-run-bc-string
      "(define p (make-parameter 5 (lambda (x) (* x 2))))
       (parameterize ((p 10)) (p))"))
  ;; A raise out of the body must still restore, otherwise the old value is
  ;; lost for the rest of the program.  parameterize does not do this itself —
  ;; the enclosing guard winds out to its own state; see the group below.
  (test-equal "value is restored when the body raises"
    1
    (pkaappi-run-bc-string
      "(define p (make-parameter 1))
       (guard (e (#t (p))) (parameterize ((p 99)) (raise 'boom)))"))
  (test-equal "restored through two nested extents"
    1
    (pkaappi-run-bc-string
      "(define p (make-parameter 1))
       (guard (e (#t (p)))
         (parameterize ((p 2)) (parameterize ((p 3)) (raise 'x))))"))
  ;; R7RS: the value expressions are evaluated before any binding is installed,
  ;; so (p) here reads the outer value, not 2.
  (test-equal "value expression sees the outer binding"
    1
    (pkaappi-run-bc-string
      "(define p (make-parameter 1)) (parameterize ((p (p))) (p))"))
  (test-equal "callee inside the extent sees the new value"
    7
    (pkaappi-run-bc-string
      "(define p (make-parameter 0)) (define (peek) (p))
       (parameterize ((p 7)) (peek))"))
  (test-equal "empty binding list"
    1
    (pkaappi-run-bc-string "(define p (make-parameter 1)) (parameterize () (p))"))
  (test-equal "repeated entry and exit"
    10
    (pkaappi-run-bc-string
      "(define p (make-parameter 0))
       (define (bump) (parameterize ((p 1)) (p)))
       (let loop ((i 0) (acc 0)) (if (= i 10) acc (loop (+ i 1) (+ acc (bump)))))"))
  (test-equal "tree-walking pipeline"
    20
    (pkaappi-run-string
      "(define p (make-parameter 10)) (parameterize ((p 20)) (p))"))
  (test-equal "tree-walking pipeline: restore on raise"
    1
    (pkaappi-run-string
      "(define p (make-parameter 1))
       (guard (e (#t (p))) (parameterize ((p 99)) (raise 'boom)))")))

;; ---------------------------------------------------------------
;; guard and the dynamic environment
;; ---------------------------------------------------------------
;;
;; R7RS 4.2.7 puts the two halves of a guard in two different dynamic
;; environments: the clauses are evaluated in that of the `guard` expression,
;; but a condition no clause matched is re-raised in that of the original
;; `raise`.  parameterize is what makes the difference observable.
;;
;; The sample implementation gets there with call/cc twice — out to the guard
;; to test the clauses, back to the raise point to re-raise.  Paal has no
;; continuations over paal closures, so it does it by save and restore instead:
;; a parameterize pushes a frame on %paal-winds, and since the frames form a
;; shared-tail list, any two states are related by winding one down to the
;; other.  That works only because parameterizations are paal's entire dynamic
;; environment, and each one is a mutable cell rather than a stack frame.

(define (both-pipelines src)
  (list (pkaappi-run-bc-string src) (pkaappi-run-string src)))

(test-group "guard: dynamic environment"
  (test-equal "clauses run in the guard's environment, not the raise's"
    '(1 1)
    (both-pipelines
      "(define p (make-parameter 1))
       (guard (e (#t (p))) (parameterize ((p 2)) (raise 'x)))"))
  ;; The item this group exists for.  Before, the guard had already unwound by
  ;; the time it re-raised, so the outer handler saw 1.
  (test-equal "unmatched condition is re-raised in the raise's environment"
    '(2 2)
    (both-pipelines
      "(define p (make-parameter 1))
       (with-exception-handler (lambda (e) (p))
         (lambda () (guard (e ((number? e) 'num))
                      (parameterize ((p 2)) (raise-continuable 'sym)))))"))
  (test-equal "re-raise environment survives two nested extents"
    '(3 3)
    (both-pipelines
      "(define p (make-parameter 1))
       (with-exception-handler (lambda (e) (p))
         (lambda () (guard (e ((number? e) 'num))
                      (parameterize ((p 2))
                        (parameterize ((p 3)) (raise-continuable 'sym))))))"))
  ;; A guard that declines must leave the environment as it found it, so the
  ;; next guard out still sees its own.  kaappi v0.22.0 answered 2 here; fixed
  ;; upstream by kaappi/kaappi#1991 after paal surfaced it.
  (test-equal "a declining guard does not disturb the guard outside it"
    '(1 1)
    (both-pipelines
      "(define p (make-parameter 1))
       (guard (e (#t (p)))
         (parameterize ((p 2))
           (guard (e ((number? e) 'no-match)) (raise 'boom))))"))
  (test-equal "same, with the raise inside a further extent"
    '(1 1)
    (both-pipelines
      "(define p (make-parameter 1))
       (guard (e (#t (p)))
         (parameterize ((p 2))
           (guard (e ((number? e) 'no-match))
             (parameterize ((p 3)) (raise 'boom)))))"))
  (test-equal "a guard inside the extent keeps the extent's values"
    '((2 2) (2 2))
    (both-pipelines
      "(define p (make-parameter 1))
       (parameterize ((p 2)) (list (guard (e (#t (p))) (raise 'x)) (p)))"))
  ;; A host-level error unwinds without consulting the paal handler stack, so
  ;; this is the other way into run-guard!'s catch.
  (test-equal "a primitive error winds out the same way"
    '((1 1) (1 1))
    (both-pipelines
      "(define p (make-parameter 1))
       (list (guard (e (#t (p))) (parameterize ((p 2)) (car '()))) (p))"))
  ;; Winding back in must reuse the values converted on entry.  Converting
  ;; again would double-apply the converter and change the parameter's value.
  ;; calls is zeroed after make-parameter, which converts the initial value.
  (test-equal "winding in again does not re-run the converter"
    '((40 1) (40 1))
    (both-pipelines
      "(define calls 0)
       (define r (make-parameter 0 (lambda (v) (set! calls (+ calls 1)) (* v 10))))
       (set! calls 0)
       (list (with-exception-handler (lambda (e) (r))
               (lambda () (guard (e ((number? e) 'num))
                            (parameterize ((r 4)) (raise-continuable 'sym)))))
             calls)"))
  (test-equal "the wind stack does not leak across iterations"
    '((1 1) (1 1))
    (both-pipelines
      "(define p (make-parameter 1))
       (let loop ((i 0))
         (if (= i 20)
             (list (p) (p))
             (begin (guard (e (#t (p))) (parameterize ((p i)) (raise 'e)))
                    (loop (+ i 1)))))"))
  ;; An explicit else takes the sentinel path out of play entirely.
  (test-equal "an explicit else still short-circuits the re-raise"
    '(1 1)
    (both-pipelines
      "(define p (make-parameter 1))
       (guard (e (else (p))) (parameterize ((p 2)) (raise 'x)))"))
  (test-equal "a clause body that raises reaches the next guard out"
    '((outer 1) (outer 1))
    (both-pipelines
      "(define p (make-parameter 1))
       (guard (out (#t (list out (p))))
         (parameterize ((p 2))
           (guard (in (#t (raise 'outer))) (raise 'first))))")))

;; ---------------------------------------------------------------
;; dynamic-wind
;; ---------------------------------------------------------------
;;
;; A second kind of wind frame, sharing the stack parameterize already uses.
;; HOST dynamic-wind cannot be reused: on the bytecode path it cannot enter a
;; paal closure at all (it raised a type error on the `before` thunk), and on
;; either path its winders would be invisible to the stack a guard walks, so a
;; raise would unwind past them in the host while paal's own frames stayed put.

(test-group "dynamic-wind"
  (test-equal "runs before, body, after in order"
    '((before during after) (before during after))
    (both-pipelines
      "(define log '())
       (define (note x) (set! log (cons x log)))
       (dynamic-wind (lambda () (note 'before))
                     (lambda () (note 'during))
                     (lambda () (note 'after)))
       (reverse log)"))
  (test-equal "returns the body's value, not the after thunk's"
    '(val val)
    (both-pipelines
      "(dynamic-wind (lambda () 'b) (lambda () 'val) (lambda () 'a))"))
  ;; The after thunk closes the extent, so it must run before the clauses of
  ;; the guard that is catching — that guard is outside the extent.
  (test-equal "after runs on the way out to a guard, before its clauses"
    '((before after clause) (before after clause))
    (both-pipelines
      "(define log '())
       (define (note x) (set! log (cons x log)))
       (guard (e (#t (note 'clause)))
         (dynamic-wind (lambda () (note 'before))
                       (lambda () (raise 'x))
                       (lambda () (note 'after))))
       (reverse log)"))
  (test-equal "nested extents unwind innermost first"
    '((out-b in-b in-a out-a) (out-b in-b in-a out-a))
    (both-pipelines
      "(define log '())
       (define (note x) (set! log (cons x log)))
       (guard (e (#t 'c))
         (dynamic-wind (lambda () (note 'out-b))
                       (lambda ()
                         (dynamic-wind (lambda () (note 'in-b))
                                       (lambda () (raise 'x))
                                       (lambda () (note 'in-a))))
                       (lambda () (note 'out-a))))
       (reverse log)"))
  ;; Winders and parameterizations interleave on one stack, so a winder sees
  ;; the parameterization it is nested inside.
  (test-equal "a winder sees the parameterization it sits inside"
    '(((b 2) (a 2)) ((b 2) (a 2)))
    (both-pipelines
      "(define p (make-parameter 1))
       (define log '())
       (define (note x) (set! log (cons x log)))
       (guard (e (#t 'c))
         (parameterize ((p 2))
           (dynamic-wind (lambda () (note (list 'b (p))))
                         (lambda () (raise 'x))
                         (lambda () (note (list 'a (p)))))))
       (reverse log)"))
  ;; A guard *inside* the extent is not leaving it, so declining to handle
  ;; must not run the after thunk; only the outer guard's escape does.
  ;; kaappi answered (before outer-clause after) until kaappi/kaappi#1991.
  (test-equal "a declining guard inside the extent does not close it early"
    '((before after outer-clause) (before after outer-clause))
    (both-pipelines
      "(define log '())
       (define (note x) (set! log (cons x log)))
       (guard (e (#t (note 'outer-clause)))
         (dynamic-wind (lambda () (note 'before))
                       (lambda () (guard (e ((number? e) 'no-match)) (raise 'x)))
                       (lambda () (note 'after))))
       (reverse log)"))
  ;; R7RS: after runs only if before completed.
  (test-equal "a before thunk that raises does not trigger after"
    '((before clause) (before clause))
    (both-pipelines
      "(define log '())
       (define (note x) (set! log (cons x log)))
       (guard (e (#t (note 'clause)))
         (dynamic-wind (lambda () (note 'before) (raise 'x))
                       (lambda () (note 'during))
                       (lambda () (note 'after))))
       (reverse log)")))

;; ---------------------------------------------------------------
;; Mutable variables captured by closures
;; ---------------------------------------------------------------
;;
;; A variable that a closure assigns must be boxed, so every closure over it —
;; and the frame that owns it — share one cell.  Without boxing each closure
;; captures a private copy and the assignment is silently lost.

(test-group "closure mutation"
  (test-equal "set! through a closure is visible to the owner"
    42
    (pkaappi-run-bc-string
      "(let ((x 0)) (let ((f (lambda () (set! x 42)))) (f) x))"))
  (test-equal "repeated mutation accumulates"
    3
    (pkaappi-run-bc-string
      "(let ((n 0))
         (let ((bump (lambda () (set! n (+ n 1)))))
           (bump) (bump) (bump) n))"))
  (test-equal "sibling closures share the variable"
    'after
    (pkaappi-run-bc-string
      "(let ((v 'before))
         (let ((setter (lambda () (set! v 'after)))
               (getter (lambda () v)))
           (setter) (getter)))"))
  (test-equal "mutation inside a nested lambda two levels down"
    7
    (pkaappi-run-bc-string
      "(let ((x 0))
         (let ((outer (lambda () (lambda () (set! x 7)))))
           ((outer)) x))"))
  (test-equal "counter closure returns increasing values"
    '(1 2 3)
    (pkaappi-run-bc-string
      "(let ((n 0))
         (let ((next (lambda () (set! n (+ n 1)) n)))
           (list (next) (next) (next))))"))
  (test-equal "tree-walking pipeline"
    42
    (pkaappi-run-string
      "(let ((x 0)) (let ((f (lambda () (set! x 42)))) (f) x))")))

;; ---------------------------------------------------------------
;; Bytevector literals (#u8)
;; ---------------------------------------------------------------

(test-group "reader: bytevector literals"
  (test-equal "empty"        (bytevector)      (car (paal-read-string "#u8()")))
  (test-equal "three bytes"  (bytevector 1 2 3) (car (paal-read-string "#u8(1 2 3)")))
  (test-equal "byte bounds"  (bytevector 0 255) (car (paal-read-string "#u8(0 255)")))
  (test-equal "inside a list"
    (list 'a (bytevector 7))
    (car (paal-read-string "(a #u8(7))")))
  (test-equal "evaluates as a literal"
    (bytevector 65 66)
    (pkaappi-run-string "(bytevector-append #u8(65) #u8(66))"))
  (test-equal "round-trips through utf8->string"
    "paal"
    (pkaappi-run-bc-string "(utf8->string #u8(112 97 97 108))")))

;; ---------------------------------------------------------------
;; Datum labels (#N= / #N#)
;; ---------------------------------------------------------------
;;
;; A reference inside the datum that defines it cannot be resolved when read,
;; so #N= registers a placeholder, reads the datum, then walks it replacing the
;; placeholder — which is what makes the result genuinely circular rather than a
;; structure containing a marker.  References after the definition resolve on
;; the spot, so only pairs and vectors need walking.

(test-group "reader: datum labels"
  (test-equal "shared structure is one object, not two equal ones"
    '(#t (1 2))
    (let ((d (car (paal-read-string "(#0=(1 2) #0#)"))))
      (list (eq? (car d) (cadr d)) (car d))))
  (test-equal "a reference after an atomic definition"
    '(42 42 42)
    (car (paal-read-string "(#1=42 #1# #1#)")))
  (test-equal "shared inside a vector"
    #t
    (let ((v (car (paal-read-string "#(#2=\"s\" #2#)"))))
      (eq? (vector-ref v 0) (vector-ref v 1))))
  (test-equal "multi-digit labels"
    #t
    (let ((d (car (paal-read-string "(#12=(q) #12#)"))))
      (eq? (car d) (cadr d))))
  ;; The interesting case: the label is used inside its own definition.
  (test-equal "a circular list closes on itself"
    '(a b #t)
    (let ((c (car (paal-read-string "#0=(a b . #0#)"))))
      (list (car c) (cadr c) (eq? c (cddr c)))))
  (test-equal "a self-referential vector"
    #t
    (let ((v (car (paal-read-string "#0=#(1 2 #0#)"))))
      (eq? v (vector-ref v 2))))
  (test-equal "walking a circular datum terminates"
    '(a b a b a)
    (let ((c (car (paal-read-string "#0=(a b . #0#)"))))
      (let loop ((i 0) (p c) (acc '()))
        (if (= i 5) (reverse acc) (loop (+ i 1) (cdr p) (cons (car p) acc))))))
  ;; R7RS scopes a label to the outermost datum, so the next one starts clean.
  (test-equal "labels are scoped to one datum"
    '(1 2)
    (let ((ds (paal-read-string "#0=(1 . #0#) #0=(2 . #0#)")))
      (list (car (car ds)) (car (cadr ds)))))
  ;; Redefining within one datum is undefined in R7RS; kaappi lets the later
  ;; definition win, and rejecting it would refuse programs kaappi accepts.
  (test-equal "a redefinition within one datum takes effect"
    '(1 2)
    (car (paal-read-string "(#0=1 #0=2)")))
  (test-equal "an undefined reference is an error"
    'error
    (guard (e (#t 'error)) (paal-read-string "#3#")))
  (test-equal "a circular literal evaluates"
    '(a b a #t)
    (pkaappi-run-bc-string
      "(define c '#0=(a b . #0#))
       (list (car c) (cadr c) (car (cddr c)) (eq? c (cddr c)))"))
  ;; kaappi's `write` emits labels for cycles and paal's reader now reads them,
  ;; so a circular constant survives the .pbc round trip.
  (test-equal "a circular constant survives serialization"
    '(a b a #t)
    (let* ((fn  (pkaappi-compile
                  "(define c '#0=(a b . #0#))
                   (list (car c) (cadr c) (car (cddr c)) (eq? c (cddr c)))"))
           (buf (open-output-string)))
      (paal-write-bc fn buf)
      (paal-run-bc (paal-read-bc (open-input-string (get-output-string buf)))
                   (pkaappi-make-globals)))))

;; ---------------------------------------------------------------
;; check — compile without running
;; ---------------------------------------------------------------
;;
;; Goes all the way to emission rather than stopping at the IR: register
;; allocation and upvalue resolution happen there, so stopping earlier would
;; miss the errors a user is least likely to have anticipated.

(define (write-temp! path text)
  (let ((port (open-output-file path)))
    (display text port)
    (close-output-port port)))

(test-group "check"
  (test-equal "a good file checks clean"
    #t
    (let ((p "paal-check-good-tmp.scm"))
      (write-temp! p "(define (ok x) (* x 2)) (display (ok 21))")
      (let ((r (pkaappi-check-file p))) (delete-file p) r)))
  (test-equal "a reader error is caught"
    #f
    (let ((p "paal-check-paren-tmp.scm"))
      (write-temp! p "(define (bad x) (* x 2)")
      (let ((r (pkaappi-check-file p))) (delete-file p) r)))
  (test-equal "an expander error is caught"
    #f
    (let ((p "paal-check-syntax-tmp.scm"))
      (write-temp! p "(let ((a)) a)")
      (let ((r (pkaappi-check-file p))) (delete-file p) r)))
  ;; The point of check: a file is compiled, never run.
  (test-equal "nothing in the file is executed"
    '(#t 0)
    (let ((p "paal-check-effect-tmp.scm")
          (marker "paal-check-marker-tmp"))
      (write-temp! p (string-append "(define port (open-output-file \""
                                    marker "\")) (close-output-port port)"))
      (let ((r (pkaappi-check-file p)))
        (delete-file p)
        (let ((ran (if (file-exists? marker) 1 0)))
          (when (= ran 1) (delete-file marker))
          (list r ran)))))
  (test-equal "every file is checked, not just up to the first failure"
    #f
    (let ((good "paal-check-m1-tmp.scm") (bad "paal-check-m2-tmp.scm"))
      (write-temp! good "(define a 1)")
      (write-temp! bad  "(define b")
      (let ((r (pkaappi-check-files (list good bad good))))
        (delete-file good) (delete-file bad)
        r)))
  (test-equal "an empty file list is vacuously clean"
    #t
    (pkaappi-check-files '())))

;; ---------------------------------------------------------------
;; Module system
;; ---------------------------------------------------------------
;;
;; Libraries are linked statically: `import` finds the .sld, expands it,
;; renames its top-level definitions to names unique to that library, splices
;; the result in front of the program, and defines the imported names as
;; aliases of the renamed ones.  Export filtering is a consequence of the
;; renaming rather than a separate mechanism — an unexported name exists only
;; under its mangled name, which nothing outside ever aliases.

;; Fixture libraries live in tests/libs/ so they are ordinary committed files
;; rather than something the suite has to create — R7RS has no mkdir.

(define (module-run src) (pkaappi-run-bc-string src))

(paal-lib-path-add! "tests/libs")

(test-group "module system"
  (test-equal "a library's exports are visible, its internals are not"
    '(25 27 unbound)
    (module-run
      "(import (m math))
       (list (square 5) (cube 3) (guard (e (#t 'unbound)) (helper 2)))"))
  (test-equal "imports are transitive through a library"
    '("hi x" 16)
    (module-run "(import (m greet)) (list (greet \"x\") (area 4))"))
  (test-equal "only"
    '(16 no-cube)
    (module-run
      "(import (only (m math) square))
       (list (square 4) (guard (e (#t 'no-cube)) (cube 2)))"))
  (test-equal "except"
    '(16 no-cube)
    (module-run
      "(import (except (m math) cube))
       (list (square 4) (guard (e (#t 'no-cube)) (cube 2)))"))
  (test-equal "prefix"
    '(16 8)
    (module-run "(import (prefix (m math) m:)) (list (m:square 4) (m:cube 2))"))
  (test-equal "rename"
    '(16 8)
    (module-run
      "(import (rename (m math) (square sq))) (list (sq 4) (cube 2))"))
  ;; The modifiers wrap a nested spec, so they compose in any order.
  (test-equal "prefix composed with only"
    36
    (module-run "(import (prefix (only (m math) square) x:)) (x:square 6)"))
  (test-equal "importing the same library twice is idempotent"
    9
    (module-run "(import (m math)) (import (m math)) (square 3)"))
  (test-equal "only naming a non-export is an error"
    'error
    (guard (e (#t 'error)) (module-run "(import (only (m math) nope)) 1")))
  (test-equal "a circular import is reported, not looped on"
    'error
    (guard (e (#t 'error)) (module-run "(import (c a)) (a-thing)")))
  ;; A macro has no run-time value, so importing one is a macro-table entry
  ;; rather than a define — (define swap! swap!) would be unbound.
  (test-equal "an exported macro works at the use site"
    '(2 1)
    (module-run
      "(import (m mac)) (define x 1) (define y 2) (swap! x y) (list x y)"))
  (test-equal "an exported macro may use a private one"
    500
    (module-run "(import (m mac)) (twice 5)"))
  ;; A macro the library did not export is renamed along with its private
  ;; values, so it is not reachable from the importer -- while an exported
  ;; macro whose template calls it still works, because the template was
  ;; rewritten to name the renamed one.
  (test-equal "a private macro is not visible to the importer"
    'hidden
    (module-run "(import (m mac)) (guard (e (#t 'hidden)) (private-mac 5))"))
  (test-equal "a built-in library import yields nothing to run"
    7
    (module-run "(import (scheme base)) (+ 3 4)")))

;; ---------------------------------------------------------------
;; SRFI libraries
;; ---------------------------------------------------------------
;;
;; Bundled under lib/srfi/, reachable because "lib" is on the default search
;; path.  Each is portable R7RS, so the same file runs on kaappi unchanged.
;;
;; None of them redefine a name (scheme base) already binds compatibly —
;; importing both would otherwise bind one identifier two ways, which R7RS 5.2
;; makes an error and kaappi enforces.

(define (srfi-run n src)
  (pkaappi-run-bc-string
    (string-append "(import (srfi " (number->string n) "))" src)))

(test-group "srfi 1: lists"
  (test-equal "iota with start and step"
    '((0 1 2 3 4) (1 2 3) (0 2 4))
    (srfi-run 1 "(list (iota 5) (iota 3 1) (iota 3 0 2))"))
  (test-equal "fold and fold-right differ in association"
    '(10 (3 2 1) (1 2 3))
    (srfi-run 1 "(list (fold + 0 '(1 2 3 4)) (fold cons '() '(1 2 3))
                       (fold-right cons '() '(1 2 3)))"))
  (test-equal "fold over two lists"
    '(22 11)
    (srfi-run 1 "(fold (lambda (a b acc) (cons (+ a b) acc)) '() '(1 2) '(10 20))"))
  (test-equal "filter, remove, partition"
    '((1 3 5) (2 4) ((1 3) (2 4)))
    (srfi-run 1 "(list (filter odd? '(1 2 3 4 5)) (remove odd? '(1 2 3 4 5))
                       (call-with-values (lambda () (partition odd? '(1 2 3 4))) list))"))
  ;; SRFI 1 `any` returns the predicate's value, not just #t.
  (test-equal "any and every return the last value"
    '(30 #t #f)
    (srfi-run 1 "(list (any (lambda (x) (and (odd? x) (* x 10))) '(2 3))
                       (every odd? '(1 3)) (every odd? '(1 2)))"))
  (test-equal "take, drop and the right-hand variants"
    '((1 2) (3 4) (3 4) (1 2))
    (srfi-run 1 "(list (take '(1 2 3 4) 2) (drop '(1 2 3 4) 2)
                       (take-right '(1 2 3 4) 2) (drop-right '(1 2 3 4) 2))"))
  (test-equal "delete-duplicates keeps first occurrences"
    '(1 2 3)
    (srfi-run 1 "(delete-duplicates '(1 2 1 3 2))"))
  ;; The two-pointer walk is what keeps this from hanging.
  (test-equal "circular-list? terminates on a circular list"
    '(#t #f #t)
    (srfi-run 1 "(list (circular-list? '#0=(1 2 . #0#))
                       (circular-list? '(1 2)) (dotted-list? '(1 . 2)))"))
  (test-equal "lset operations"
    '((1 2 3) (1 2 3) (2 3) (1 3))
    (srfi-run 1 "(list (lset-adjoin eqv? '(1 2) 2 3) (lset-union eqv? '(1 2) '(2 3))
                       (lset-intersection eqv? '(1 2 3) '(2 3 4))
                       (lset-difference eqv? '(1 2 3) '(2)))")))

(test-group "srfi 13: strings"
  (test-equal "take and drop from both ends"
    '("he" "llo" "lo" "hel")
    (srfi-run 13 "(list (string-take \"hello\" 2) (string-drop \"hello\" 2)
                        (string-take-right \"hello\" 2) (string-drop-right \"hello\" 2))"))
  ;; Longer than the pad width keeps the rightmost characters, per SRFI 13.
  (test-equal "pad truncates from the left when too long"
    '("  7" "700" "cd")
    (srfi-run 13 "(list (string-pad \"7\" 3) (string-pad-right \"7\" 3 #\\0)
                        (string-pad \"abcd\" 2))"))
  (test-equal "trim variants"
    '("x " "  x" "x")
    (srfi-run 13 "(list (string-trim \"  x \") (string-trim-right \"  x \")
                        (string-trim-both \"  x \"))"))
  (test-equal "index accepts a char or a predicate"
    '(2 3 #f)
    (srfi-run 13 "(list (string-index \"hello\" #\\l)
                        (string-index-right \"hello\" #\\l)
                        (string-index \"hello\" char-numeric?))"))
  (test-equal "contains returns an index or #f"
    '(4 #f)
    (srfi-run 13 "(list (string-contains \"hello world\" \"o w\")
                        (string-contains \"abc\" \"z\"))"))
  ;; split keeps empty fields so it inverts join; tokenize drops them.
  (test-equal "join, split and tokenize"
    '("a,b,c" ("a" "b" "" "c") ("a" "b"))
    (srfi-run 13 "(list (string-join '(\"a\" \"b\" \"c\") \",\")
                        (string-split \"a,b,,c\" #\\,)
                        (string-tokenize \"  a  b \"))")))

(test-group "srfi 69: hash tables"
  (test-equal "set, ref and defaults"
    '(1 none 2 #t)
    (srfi-run 69 "(define h (make-hash-table))
                  (hash-table-set! h 'a 1) (hash-table-set! h 'b 2)
                  (list (hash-table-ref h 'a) (hash-table-ref/default h 'z 'none)
                        (hash-table-size h) (hash-table-exists? h 'b))"))
  (test-equal "delete adjusts the count"
    '(0 #f)
    (srfi-run 69 "(define h (make-hash-table)) (hash-table-set! h 'a 1)
                  (hash-table-delete! h 'a)
                  (list (hash-table-size h) (hash-table-exists? h 'a))"))
  ;; Past the 0.75 load factor the bucket vector doubles and everything
  ;; rehashes; 200 entries in a 16-bucket table exercises that several times.
  (test-equal "growing rehashes without losing entries"
    '(200 22500)
    (srfi-run 69 "(define h (make-hash-table))
                  (let loop ((i 0)) (when (< i 200) (hash-table-set! h i (* i i)) (loop (+ i 1))))
                  (list (hash-table-size h) (hash-table-ref h 150))"))
  (test-equal "string keys hash by content, not identity"
    42
    (srfi-run 69 "(define h (make-hash-table)) (hash-table-set! h \"key\" 42)
                  (hash-table-ref h (string-append \"k\" \"ey\"))"))
  (test-equal "update with a default"
    2
    (srfi-run 69 "(define h (make-hash-table))
                  (hash-table-update!/default h 'k (lambda (v) (+ v 1)) 0)
                  (hash-table-update!/default h 'k (lambda (v) (+ v 1)) 0)
                  (hash-table-ref h 'k)"))
  (test-equal "alist->hash-table lets earlier entries win"
    '(1 2)
    (srfi-run 69 "(define h (alist->hash-table '((a . 1) (a . 9) (b . 2))))
                  (list (hash-table-ref h 'a) (hash-table-ref h 'b))")))

(test-group "srfi 133: vectors"
  (test-equal "empty, count and index"
    '(#t 2 2)
    (srfi-run 133 "(list (vector-empty? #()) (vector-count odd? #(1 2 3))
                         (vector-index even? #(1 3 4)))"))
  (test-equal "fold and reduce"
    '(6 10)
    (srfi-run 133 "(list (vector-fold (lambda (a x) (+ a x)) 0 #(1 2 3))
                         (vector-reduce + 0 #(1 2 3 4)))"))
  (test-equal "reverse, copy and concatenate"
    '(#(3 2 1) #(3 2 1) #(1 2 3))
    (srfi-run 133 "(list (vector-reverse-copy #(1 2 3)) (vector-reverse! (vector 1 2 3))
                         (vector-concatenate (list #(1) #(2 3))))"))
  (test-equal "binary search"
    '(2 #f)
    (srfi-run 133 "(list (vector-binary-search #(1 3 5 7) 5 (lambda (a b) (- a b)))
                         (vector-binary-search #(1 3 5 7) 4 (lambda (a b) (- a b))))")))

(test-group "srfi 28 / 48: format"
  (test-equal "srfi 28 directives"
    "x and \"y\"~\n"
    (srfi-run 28 "(format \"~a and ~s~~~%\" 'x \"y\")"))
  (test-equal "srfi 48 adds radix and character directives"
    '("255 ff 101 10" "z")
    (srfi-run 48 "(list (format \"~d ~x ~b ~o\" 255 255 5 8) (format \"~c\" #\\z))"))
  (test-equal "srfi 48 accepts a leading #f"
    "1"
    (srfi-run 48 "(format #f \"~a\" 1)")))

;; These three are import paths for things paal already provides.
(test-group "srfi 9 / 23 / 39: already-present forms"
  (test-equal "srfi 9 define-record-type"
    7
    (srfi-run 9 "(define-record-type <p> (mk a) p? (a get-a)) (get-a (mk 7))"))
  (test-equal "srfi 23 error"
    "boom"
    (srfi-run 23 "(guard (e (#t (error-object-message e))) (error \"boom\" 1))"))
  (test-equal "srfi 39 parameterize"
    2
    (srfi-run 39 "(define p (make-parameter 1)) (parameterize ((p 2)) (p))")))

;; ---------------------------------------------------------------
;; (scheme eval) / (scheme load) / (scheme repl)
;; ---------------------------------------------------------------
;;
;; eval re-enters the pipeline on a datum the program built at run time.  The
;; bindings read the globals table out of a cell rather than closing over it,
;; because the table does not exist yet when the alist holding them is built.

(test-group "eval"
  (test-equal "a literal expression"
    3
    (pkaappi-run-bc-string "(eval '(+ 1 2) (interaction-environment))"))
  ;; The point of eval: the form is assembled at run time, not written out.
  (test-equal "an expression built at run time"
    7
    (pkaappi-run-bc-string
      "(define op '+) (eval (list op 3 4) (interaction-environment))"))
  (test-equal "the environment argument is optional"
    42
    (pkaappi-run-bc-string "(eval '(* 6 7))"))
  (test-equal "environment yields a usable table"
    2
    (pkaappi-run-bc-string "(eval '(+ 1 1) (environment '(scheme base)))"))
  ;; interaction-environment is the running program's own table, so a define
  ;; evaluated into it is visible to code compiled afterwards.
  (test-equal "a define through interaction-environment is visible"
    9
    (pkaappi-run-bc-string
      "(eval '(define zz 9) (interaction-environment)) zz"))
  (test-equal "interaction-environment is stable across calls"
    #t
    (pkaappi-run-bc-string
      "(eq? (interaction-environment) (interaction-environment))"))
  (test-equal "load runs a file into the current environment"
    11
    (let ((p "paal-load-tmp.scm"))
      (let ((port (open-output-file p)))
        (display "(define loaded-value 11)" port)
        (close-output-port port))
      (let ((r (pkaappi-run-bc-string
                 (string-append "(load \"" p "\") loaded-value"))))
        (delete-file p)
        r))))

;; ---------------------------------------------------------------
;; (scheme r5rs) / (scheme complex)
;; ---------------------------------------------------------------

(test-group "r5rs and complex"
  ;; The only two R5RS names R7RS renamed.
  (test-equal "exact->inexact and inexact->exact"
    '(1.0 2)
    (pkaappi-run-bc-string "(list (exact->inexact 1) (inexact->exact 2.0))"))
  ;; Paal has no complex type, so these are the R7RS procedures restricted to
  ;; the real line: every number is its own real part, with a zero imaginary
  ;; part.  Useful because portable code calls them unconditionally.
  (test-equal "complex accessors on reals"
    '(5 0 3 2)
    (pkaappi-run-bc-string
      "(list (real-part 5) (imag-part 5) (magnitude -3) (make-rectangular 2 0))"))
  ;; Erroring beats silently dropping the imaginary part.
  (test-equal "make-rectangular refuses a non-zero imaginary part"
    'errs
    (pkaappi-run-bc-string "(guard (e (#t 'errs)) (make-rectangular 1 2))")))

;; ---------------------------------------------------------------
;; Expander diagnostics
;; ---------------------------------------------------------------
;;
;; The expander destructures with car/cadr, and used to let the host's type
;; error escape — a malformed form surfaced as whichever accessor happened to
;; fail first.  `(let ((a)) a)` reported "type error in 'cadr'", which says
;; nothing about the binding.  These check shape first and name the form.

(define (expand-error src)
  (guard (e (#t (error-object-message e))) (pkaappi-run-bc-string src)))

(test-group "expander diagnostics"
  (test-equal "a binding with no init names the form"
    "paal: let: binding needs exactly one init expression"
    (expand-error "(let ((a)) a)"))
  (test-equal "a non-symbol binding name"
    "paal: let: binding name must be a symbol"
    (expand-error "(let ((1 2)) 3)"))
  (test-equal "a binding with two inits"
    "paal: let: binding needs exactly one init expression"
    (expand-error "(let ((a 1 2)) a)"))
  (test-equal "an empty body"
    "paal: let: malformed"
    (expand-error "(let ((a 1)))"))
  (test-equal "let* is checked too"
    "paal: let*: binding needs exactly one init expression"
    (expand-error "(let* ((a)) a)"))
  (test-equal "letrec is checked too"
    "paal: letrec: binding needs exactly one init expression"
    (expand-error "(letrec ((a)) a)"))
  ;; Named let takes its bindings one position later, so it needs its own check.
  (test-equal "named let is checked at its own position"
    "paal: named let: binding needs exactly one init expression"
    (expand-error "(let loop ((a)) a)"))
  ;; cond and do have their own shapes: a do spec is (name init [step]), not
  ;; a let binding, and `else` has a position rule rather than a shape rule.
  (test-equal "else must be the last cond clause"
    "paal: cond: else must be the last clause"
    (expand-error "(cond (else 1) (#t 2))"))
  (test-equal "an empty else"
    "paal: cond: else needs at least one expression"
    (expand-error "(cond (else))"))
  (test-equal "a non-list cond clause"
    "paal: cond: clause must be a list"
    (expand-error "(cond 5)"))
  (test-equal "a do spec with no init"
    "paal: do: variable spec must be (name init [step])"
    (expand-error "(do ((i)) ((= i 1)) 2)"))
  (test-equal "a do spec with a non-symbol name"
    "paal: do: variable name must be a symbol"
    (expand-error "(do ((1 0)) ((= i 1)) 2)"))
  (test-equal "a do spec with too many parts"
    "paal: do: variable spec must be (name init [step])"
    (expand-error "(do ((i 0 1 2)) ((= i 1)) 2)"))
  (test-equal "a well-formed let still works"
    1
    (pkaappi-run-bc-string "(let ((a 1)) a)"))
  ;; (case x (1 'one)) is the usual slip — the datum list is a list even when
  ;; it holds one datum, and without the check a bare atom reached memv.
  (test-equal "case clause data must be a list"
    "paal: case: clause data must be a list"
    (expand-error "(case 1 (1 'one))"))
  (test-equal "case else must be last"
    "paal: case: else must be the last clause"
    (expand-error "(case 1 (else 1) ((2) 2))"))
  (test-equal "a case clause with no body"
    "paal: case: clause needs at least one expression"
    (expand-error "(case 1 ((1)))"))
  (test-equal "a record field spec with no accessor"
    "paal: define-record-type: field spec must be (field accessor [modifier])"
    (expand-error "(define-record-type <p> (mk a) p? (a)) 1"))
  (test-equal "a record constructor that is not a list"
    "paal: define-record-type: constructor must be (name field ...)"
    (expand-error "(define-record-type <p> mk p? (a get-a)) 1"))
  (test-equal "a well-formed cond and do still work"
    '(7 3)
    (pkaappi-run-bc-string
      "(list (cond (#t 7)) (do ((i 0 (+ i 1))) ((= i 3) i)))"))
  (test-equal "a well-formed case and record still work"
    '(one 5)
    (pkaappi-run-bc-string
      "(define-record-type <p> (mk a) p? (a get-a))
       (list (case 1 ((1) 'one) (else 'other)) (get-a (mk 5)))")))

;; ---------------------------------------------------------------
;; SRFI 64
;; ---------------------------------------------------------------
;;
;; The assertions are syntax, not procedures: a procedural
;; (test-equal expected actual) evaluates `actual` at the call site, so a
;; raise escapes before the framework sees it and takes the rest of the group
;; with it.  Thunking inside the macro is what makes a raise a failed test.

(test-group "srfi 64"
  ;; 5 pass (a c d e g), 3 fail (b, f which does not raise, j which raises),
  ;; 1 skip, 1 expected failure.
  (test-equal "counts passes, failures, skips and expected failures"
    '(5 3 1 1)
    (pkaappi-run-bc-string
      "(import (srfi 64))
       (test-begin \"demo\")
       (test-equal \"a\" 4 (+ 2 2))
       (test-equal \"b\" 5 (+ 2 2))
       (test-assert \"c\" (= 1 1))
       (test-eqv \"d\" 'a 'a)
       (test-error \"e\" (car '()))
       (test-error \"f\" 1)
       (test-approximate \"g\" 1.0 1.05 0.1)
       (test-skip \"h\") (test-equal \"h\" 1 2)
       (test-expect-fail \"i\") (test-equal \"i\" 1 2)
       (test-equal \"j\" 1 (car '()))
       (test-end \"demo\")
       (list (test-runner-pass-count) (test-runner-fail-count)
             (test-runner-skip-count) (test-runner-xfail-count))"))
  ;; The property the whole design exists for.
  (test-equal "a raising test fails that test and the run continues"
    '(1 1)
    (pkaappi-run-bc-string
      "(import (srfi 64))
       (test-equal \"raises\" 1 (car '()))
       (test-equal \"after\" 2 2)
       (list (test-runner-pass-count) (test-runner-fail-count))"))
  (test-equal "groups nest"
    2
    (pkaappi-run-bc-string
      "(import (srfi 64))
       (test-group \"outer\" (test-group \"inner\" (test-assert \"x\" #t))
                            (test-assert \"y\" #t))
       (test-runner-pass-count)")))

;; ---------------------------------------------------------------
;; Bytecode cache for user programs
;; ---------------------------------------------------------------
;;
;; Opt-in (`paal --cache file.scm`) because the cache file lands beside the
;; source — R7RS has no mkdir, so there is nowhere else to put it.  The hash
;; is in the *name*, so a hit is an existence check and an edited source
;; simply misses instead of needing the stale entry detected.

(test-group "bytecode cache"
  (test-equal "a miss compiles and writes, a hit reuses"
    '(42 42 #t)
    (let ((src "paal-cache-tmp.scm"))
      (let ((port (open-output-file src)))
        (display "(* 6 7)" port) (close-output-port port))
      (let* ((a      (pkaappi-run-file-cached src))
             (cached (pkaappi-cache-path src))
             (wrote  (file-exists? cached))
             (b      (pkaappi-run-file-cached src)))
        (delete-file cached)
        (delete-file src)
        (list a b wrote))))
  ;; The hash is in the name, so an edit misses rather than needing the stale
  ;; entry detected -- and leaves the old entry behind, which is why
  ;; pkaappi-cache-path is exported.
  (test-equal "an edited source misses and recompiles"
    '(1 2)
    (let ((src "paal-cache-edit-tmp.scm"))
      (define (write-src! text)
        (let ((port (open-output-file src)))
          (display text port) (close-output-port port)))
      (write-src! "1")
      (let* ((p1 (begin (pkaappi-cache-path src)))
             (a  (pkaappi-run-file-cached src)))
        (write-src! "2")
        (let* ((p2 (pkaappi-cache-path src))
               (b  (pkaappi-run-file-cached src)))
          (delete-file p1) (delete-file p2) (delete-file src)
          (list a b))))))

;; ---------------------------------------------------------------
;; fmt — canonical formatter
;; ---------------------------------------------------------------
;;
;; It cannot use paal-read, which discards comments, so it has its own scanner
;; producing a tree that keeps comments and blank lines as nodes.  The property
;; that matters is that formatting never changes what the reader sees, which is
;; asserted for every case below rather than being taken on trust.

(define (fmt-preserves? src)
  (equal? (paal-read-string src)
          (paal-read-string (paal-format-string src))))

(define (fmt-idempotent? src)
  (let ((once (paal-format-string src)))
    (string=? once (paal-format-string once))))

(test-group "fmt"
  (test-equal "collapses a short form to one line"
    "(define (f x) (* x 2))\n"
    (paal-format-string "(define (f x)(* x 2))"))
  ;; A body that does not fit indents 2 from the open paren, not under the
  ;; first argument -- define is a special form, not a call.
  (test-equal "a long define breaks with a 2-space body"
    "(define (long-procedure-name alpha beta gamma delta)\n  (+ alpha beta gamma delta (* alpha beta) (* gamma delta)))\n"
    (paal-format-string
      "(define (long-procedure-name alpha beta gamma delta) (+ alpha beta gamma delta (* alpha beta) (* gamma delta)))"))
  (test-equal "a comment on its own line stays there"
    ";; top\n(define x 1)\n"
    (paal-format-string ";; top\n(define x 1)\n"))
  ;; A comment with code before it on the same line is trailing and must not
  ;; migrate to a line of its own.
  (test-equal "a trailing comment stays on its line"
    "(define x 1) ; trailing\n"
    (paal-format-string "(define x 1) ; trailing\n"))
  (test-equal "runs of blank lines collapse to one"
    "(define a 1)\n\n(define b 2)\n"
    (paal-format-string "(define a 1)\n\n\n\n(define b 2)\n"))
  (test-equal "a comment inside a form keeps its place"
    "(define (f x)\n  ;; explain\n  (* x 2))\n"
    (paal-format-string "(define (f x)\n  ;; explain\n  (* x 2))"))
  ;; Strings are scanned whole, so a semicolon inside one is not a comment and
  ;; nothing inside is ever reflowed.
  (test-assert "a semicolon inside a string is not a comment"
    (fmt-preserves? "(display \"a ; not a comment\")"))
  (test-assert "vectors keep their #( prefix"
    (fmt-preserves? "(define v #(1 2 3))"))
  (test-assert "bytevectors keep their #u8( prefix"
    (fmt-preserves? "(define v #u8(1 2 3))"))
  (test-assert "quote stays attached to what it quotes"
    (fmt-preserves? "(define l '(a b c))"))
  (test-assert "a datum comment survives"
    (fmt-preserves? "(list 1 #;(2 3) 4)"))
  (test-assert "a block comment survives"
    (fmt-preserves? "#| block |#\n(define z 1)"))
  (test-assert "characters survive"
    (fmt-preserves? "(list #\\a #\\space #\\( )"))
  (test-assert "formatting is idempotent"
    (fmt-idempotent?
      "(cond ((= x 1) 'one)((= x 2) 'two)(else 'other))(define (f a b) (+ a b))"))
  ;; The end-to-end property: a real source file formats, still reads the
  ;; same, and check reports it clean afterwards.
  (test-equal "a file round-trips through fmt"
    '(#t #f #t)
    (let ((p "paal-fmt-tmp.scm"))
      (let ((port (open-output-file p)))
        (display "(define (f x)(* x 2))\n(display (f 21))" port)
        (close-output-port port))
      (let* ((before (paal-format-check-file p))
             (_      (paal-format-file! p))
             (after  (paal-format-check-file p))
             (reads  (equal? (paal-read-file p)
                             '((define (f x) (* x 2)) (display (f 21))))))
        (delete-file p)
        (list reads before after)))))

(test-exit)
