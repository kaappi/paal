;; Exercises the procedures pkaappi-make-globals installs by paal-compiling them.
;; These are the ones that cross the HOST/self-hosted boundary as <closure>
;; values, so this fixture is what catches a regression of kaappi/paal#1 —
;; add.scm and factorial.scm use none of them and stayed green throughout.

(define (sum lst) (apply + lst))

(sum (list (car (map (lambda (x) (* x 2)) (list 5)))          ; map            => 10
           (length (filter odd? (list 1 2 3 4 5)))            ; filter         =>  3
           (vector-ref (vector-map (lambda (x) (+ x 1))
                                   (vector 6)) 0)             ; vector-map     =>  7
           (string-length (string-map char-upcase "abcd"))    ; string-map     =>  4
           (call-with-values (lambda () (values 2 3)) *)      ; values         =>  6
           (force (delay 9))                                  ; delay/force    =>  9
           (if (promise? (delay 1)) 1 0)                       ; promise?       =>  1
           (let ((n 0))
             (for-each (lambda (x) (set! n (+ n x))) (list 1 2 3))
             n)                                               ; for-each       =>  6
           (let ((n 0))
             (vector-for-each (lambda (x) (set! n (+ n x))) (vector 4))
             n)                                               ; vector-for-each=>  4
           (let ((n 0))
             (string-for-each (lambda (c) (set! n (+ n 1))) "ab")
             n)))                                             ; string-for-each=>  2
;; => 10 + 3 + 7 + 4 + 6 + 9 + 1 + 6 + 4 + 2 = 52
