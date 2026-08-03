;;; SRFI 1 — List Library
;;;
;;; The commonly-used subset, written in portable R7RS so it runs on paal and
;;; on kaappi unchanged.  Procedures R7RS already provides under the same name
;;; and semantics (`map`, `for-each`, `length`, `append`, `reverse`,
;;; `list-tail`, `list-ref`, `member`, `assoc`, `list-copy`) are deliberately
;;; not redefined: importing this library alongside `(scheme base)` would then
;;; bind one name two ways, which R7RS 5.2 makes an error.
;;;
;;; Not implemented: the linear-update (`!`) variants, circular-list support,
;;; `list-index` on multiple lists, and the comparator-taking set operations
;;; beyond the basic four.

(define-library (srfi 1)
  (import (scheme base))
  (export
    ;; constructors
    xcons cons* make-list list-tabulate iota circular-list
    ;; predicates
    proper-list? circular-list? dotted-list? null-list? not-pair?
    list=
    ;; selectors
    first second third fourth fifth sixth seventh eighth ninth tenth
    car+cdr take drop take-right drop-right last last-pair
    split-at
    ;; miscellaneous
    zip unzip1 unzip2 concatenate append-reverse length+
    ;; folds and friends
    fold fold-right reduce reduce-right append-map filter-map
    unfold unfold-right
    pair-fold pair-fold-right pair-for-each map-in-order
    ;; filtering and searching
    filter remove partition find find-tail any every list-index
    take-while drop-while span break count
    delete delete-duplicates
    ;; association lists
    alist-copy alist-cons alist-delete del-assq del-assv del-assoc
    ;; sets over lists
    lset-adjoin lset-union lset-intersection lset-difference
    lset= lset-xor)
  (begin

    ;; --- constructors ------------------------------------------------

    (define (xcons d a) (cons a d))

    (define (cons* first . rest)
      (let recur ((x first) (rest rest))
        (if (null? rest)
            x
            (cons x (recur (car rest) (cdr rest))))))

    (define (list-tabulate n proc)
      (let loop ((i (- n 1)) (acc '()))
        (if (< i 0) acc (loop (- i 1) (cons (proc i) acc)))))

    ;; (iota count [start [step]])
    (define (iota count . rest)
      (let ((start (if (pair? rest) (car rest) 0))
            (step  (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) 1)))
        (let loop ((i (- count 1)) (acc '()))
          (if (< i 0)
              acc
              (loop (- i 1) (cons (+ start (* i step)) acc))))))

    ;; The one SRFI 1 constructor whose result is deliberately cyclic.  At
    ;; least one element, or there is no pair to close the knot through.
    (define (circular-list first . rest)
      (let ((l (cons first rest)))
        (set-cdr! (last-pair l) l)
        l))

    ;; --- predicates --------------------------------------------------

    ;; Walks with two pointers so a circular list terminates rather than
    ;; hanging: the fast pointer laps the slow one exactly when there is a
    ;; cycle.  proper-list? and dotted-list? need the same walk.
    (define (%classify x)
      ;; 'proper, 'circular or 'dotted
      (let loop ((slow x) (fast x) (first? #t))
        (cond
          ((null? fast) 'proper)
          ((not (pair? fast)) 'dotted)
          ((null? (cdr fast)) 'proper)
          ((not (pair? (cdr fast))) 'dotted)
          ((and (not first?) (eq? slow fast)) 'circular)
          (else (loop (cdr slow) (cddr fast) #f)))))

    (define (proper-list? x)   (eq? (%classify x) 'proper))
    (define (circular-list? x) (eq? (%classify x) 'circular))
    (define (dotted-list? x)   (eq? (%classify x) 'dotted))

    (define (null-list? x)
      (cond ((null? x) #t)
            ((pair? x) #f)
            (else (error "null-list?: argument is neither null nor a pair" x))))

    (define (not-pair? x) (not (pair? x)))

    (define (list= elt= . lists)
      (cond
        ((null? lists) #t)
        ((null? (cdr lists)) #t)
        (else
         (let outer ((a (car lists)) (rest (cdr lists)))
           (if (null? rest)
               #t
               (let ((b (car rest)))
                 (and (let inner ((x a) (y b))
                        (cond ((null? x) (null? y))
                              ((null? y) #f)
                              ((elt= (car x) (car y)) (inner (cdr x) (cdr y)))
                              (else #f)))
                      (outer b (cdr rest)))))))))

    ;; --- selectors ---------------------------------------------------

    (define (first x)   (car x))
    (define (second x)  (cadr x))
    (define (third x)   (caddr x))
    (define (fourth x)  (cadddr x))
    (define (fifth x)   (list-ref x 4))
    (define (sixth x)   (list-ref x 5))
    (define (seventh x) (list-ref x 6))
    (define (eighth x)  (list-ref x 7))
    (define (ninth x)   (list-ref x 8))
    (define (tenth x)   (list-ref x 9))

    (define (car+cdr p) (values (car p) (cdr p)))

    (define (take lst k)
      (let loop ((l lst) (k k) (acc '()))
        (if (= k 0)
            (reverse acc)
            (loop (cdr l) (- k 1) (cons (car l) acc)))))

    (define (drop lst k)
      (let loop ((l lst) (k k))
        (if (= k 0) l (loop (cdr l) (- k 1)))))

    ;; Advance a second pointer k ahead, then walk both to the end.
    (define (take-right lst k)
      (let loop ((lag lst) (lead (drop lst k)))
        (if (pair? lead) (loop (cdr lag) (cdr lead)) lag)))

    (define (drop-right lst k)
      (let loop ((lag lst) (lead (drop lst k)) (acc '()))
        (if (pair? lead)
            (loop (cdr lag) (cdr lead) (cons (car lag) acc))
            (reverse acc))))

    (define (last-pair lst)
      (let loop ((l lst))
        (if (pair? (cdr l)) (loop (cdr l)) l)))

    (define (last lst) (car (last-pair lst)))

    ;; (values (take lst n) (drop lst n)) in one pass over the prefix.
    (define (split-at lst n)
      (let loop ((l lst) (k n) (acc '()))
        (if (= k 0)
            (values (reverse acc) l)
            (loop (cdr l) (- k 1) (cons (car l) acc)))))

    ;; --- miscellaneous -----------------------------------------------

    (define (zip . lists) (apply map list lists))

    (define (unzip1 lst) (map car lst))

    (define (unzip2 lst)
      (values (map car lst) (map cadr lst)))

    (define (concatenate lists) (apply append lists))

    (define (append-reverse rev tail)
      (let loop ((l rev) (acc tail))
        (if (null? l) acc (loop (cdr l) (cons (car l) acc)))))

    ;; length, except a circular list answers #f and a dotted list its pair
    ;; count is not needed — SRFI 1 leaves dotted lists to `length`'s error.
    ;; Same two-pointer walk the predicates use.
    (define (length+ lst)
      (let loop ((slow lst) (fast lst) (n 0))
        (cond ((null? fast) n)
              ((not (pair? fast)) (error "length+: not a proper or circular list" lst))
              ((null? (cdr fast)) (+ n 1))
              ((eq? (cdr fast) slow) #f)
              (else (loop (cdr slow) (cddr fast) (+ n 2))))))

    ;; --- folds -------------------------------------------------------

    (define (fold kons knil lst . rest)
      (if (null? rest)
          (let loop ((l lst) (acc knil))
            (if (null? l) acc (loop (cdr l) (kons (car l) acc))))
          (let loop ((ls (cons lst rest)) (acc knil))
            (if (%any-null? ls)
                acc
                (loop (map cdr ls) (apply kons (append (map car ls) (list acc))))))))

    (define (fold-right kons knil lst . rest)
      (if (null? rest)
          (let loop ((l lst))
            (if (null? l) knil (kons (car l) (loop (cdr l)))))
          (let loop ((ls (cons lst rest)))
            (if (%any-null? ls)
                knil
                (apply kons (append (map car ls) (list (loop (map cdr ls)))))))))

    (define (%any-null? ls)
      (cond ((null? ls) #f)
            ((null? (car ls)) #t)
            (else (%any-null? (cdr ls)))))

    (define (reduce f ridentity lst)
      (if (null? lst) ridentity (fold f (car lst) (cdr lst))))

    (define (reduce-right f ridentity lst)
      (if (null? lst)
          ridentity
          (let loop ((l lst))
            (if (null? (cdr l))
                (car l)
                (f (car l) (loop (cdr l)))))))

    (define (append-map f lst . rest)
      (apply append (apply map f lst rest)))

    (define (filter-map f lst . rest)
      (let loop ((l (apply map f lst rest)) (acc '()))
        (cond ((null? l) (reverse acc))
              ((car l) (loop (cdr l) (cons (car l) acc)))
              (else (loop (cdr l) acc)))))

    ;; (unfold p f g seed) — p says when to stop, f maps, g steps.
    ;; Both take SRFI 1's optional fifth argument, which kaappi's own
    ;; answers to: `unfold`'s tail-gen is *called on the final seed* to
    ;; make the tail (default: the empty list), while `unfold-right`'s is
    ;; the initial tail value itself, not a procedure.  (srfi 158)'s
    ;; generator-unfold passes one straight through.
    (define (unfold p f g seed . tail-gen)
      (let ((make-tail (if (pair? tail-gen)
                           (car tail-gen)
                           (lambda (seed) '()))))
        (let loop ((seed seed) (acc '()))
          (if (p seed)
              (append (reverse acc) (make-tail seed))
              (loop (g seed) (cons (f seed) acc))))))

    (define (unfold-right p f g seed . tail)
      (let loop ((seed seed) (acc (if (pair? tail) (car tail) '())))
        (if (p seed) acc (loop (g seed) (cons (f seed) acc)))))

    ;; The pair-walking folds see each successive pair, not each element.
    ;; The cdr is taken before kons runs, so a kons that set-cdr!s the pair
    ;; it was handed — SRFI 1's own destructive-reverse example — does not
    ;; derail the walk.
    (define (pair-fold kons knil lst)
      (let loop ((l lst) (acc knil))
        (if (pair? l)
            (let ((tail (cdr l)))
              (loop tail (kons l acc)))
            acc)))

    (define (pair-fold-right kons knil lst)
      (let loop ((l lst))
        (if (pair? l)
            (kons l (loop (cdr l)))
            knil)))

    (define (pair-for-each proc lst)
      (let loop ((l lst))
        (when (pair? l)
          (let ((tail (cdr l)))
            (proc l)
            (loop tail)))))

    ;; map with the application order guaranteed left to right.  paal's map
    ;; happens to walk that way, but the guarantee is this name's whole
    ;; contract, so it gets its own loop rather than an alias.
    (define (map-in-order f lst . rest)
      (if (null? rest)
          (let loop ((l lst) (acc '()))
            (if (null? l)
                (reverse acc)
                (let ((v (f (car l))))
                  (loop (cdr l) (cons v acc)))))
          (let loop ((ls (cons lst rest)) (acc '()))
            (if (let scan ((ls ls)) (and (pair? ls) (or (null? (car ls)) (scan (cdr ls)))))
                (reverse acc)
                (let ((v (apply f (map car ls))))
                  (loop (map cdr ls) (cons v acc)))))))

    ;; --- filtering and searching -------------------------------------

    (define (filter pred lst)
      (let loop ((l lst) (acc '()))
        (cond ((null? l) (reverse acc))
              ((pred (car l)) (loop (cdr l) (cons (car l) acc)))
              (else (loop (cdr l) acc)))))

    (define (remove pred lst)
      (filter (lambda (x) (not (pred x))) lst))

    (define (partition pred lst)
      (let loop ((l lst) (yes '()) (no '()))
        (cond ((null? l) (values (reverse yes) (reverse no)))
              ((pred (car l)) (loop (cdr l) (cons (car l) yes) no))
              (else (loop (cdr l) yes (cons (car l) no))))))

    (define (find pred lst)
      (let ((tail (find-tail pred lst)))
        (and tail (car tail))))

    (define (find-tail pred lst)
      (let loop ((l lst))
        (cond ((null? l) #f)
              ((pred (car l)) l)
              (else (loop (cdr l))))))

    ;; Returns the last application's value, not just #t, per SRFI 1.
    (define (any pred lst . rest)
      (if (null? rest)
          (let loop ((l lst))
            (cond ((null? l) #f)
                  ((pred (car l)))
                  (else (loop (cdr l)))))
          (let loop ((ls (cons lst rest)))
            (cond ((%any-null? ls) #f)
                  ((apply pred (map car ls)))
                  (else (loop (map cdr ls)))))))

    (define (every pred lst . rest)
      (if (null? rest)
          (let loop ((l lst) (last #t))
            (cond ((null? l) last)
                  ((pred (car l)) => (lambda (v) (loop (cdr l) v)))
                  (else #f)))
          (let loop ((ls (cons lst rest)) (last #t))
            (cond ((%any-null? ls) last)
                  ((apply pred (map car ls)) => (lambda (v) (loop (map cdr ls) v)))
                  (else #f)))))

    ;; n-ary, stopping at the shortest list, per SRFI 1.  The one-list arm
    ;; stays inlined so the common case pays no apply.
    (define (list-index pred lst . rest)
      (if (null? rest)
          (let loop ((l lst) (i 0))
            (cond ((null? l) #f)
                  ((pred (car l)) i)
                  (else (loop (cdr l) (+ i 1)))))
          (let loop ((ls (cons lst rest)) (i 0))
            (cond ((any null? ls) #f)
                  ((apply pred (map car ls)) i)
                  (else (loop (map cdr ls) (+ i 1)))))))

    (define (take-while pred lst)
      (let loop ((l lst) (acc '()))
        (if (or (null? l) (not (pred (car l))))
            (reverse acc)
            (loop (cdr l) (cons (car l) acc)))))

    (define (drop-while pred lst)
      (let loop ((l lst))
        (if (or (null? l) (not (pred (car l)))) l (loop (cdr l)))))

    (define (span pred lst)
      (values (take-while pred lst) (drop-while pred lst)))

    (define (break pred lst)
      (span (lambda (x) (not (pred x))) lst))

    (define (count pred lst)
      (let loop ((l lst) (n 0))
        (cond ((null? l) n)
              ((pred (car l)) (loop (cdr l) (+ n 1)))
              (else (loop (cdr l) n)))))

    ;; (delete x lst [=]) — equal? by default
    (define (delete x lst . rest)
      (let ((elt= (if (pair? rest) (car rest) equal?)))
        (filter (lambda (y) (not (elt= x y))) lst)))

    (define (delete-duplicates lst . rest)
      (let ((elt= (if (pair? rest) (car rest) equal?)))
        (let loop ((l lst) (acc '()))
          (cond ((null? l) (reverse acc))
                ((%member? (car l) acc elt=) (loop (cdr l) acc))
                (else (loop (cdr l) (cons (car l) acc)))))))

    (define (%member? x lst elt=)
      (cond ((null? lst) #f)
            ((elt= x (car lst)) #t)
            (else (%member? x (cdr lst) elt=))))

    ;; --- association lists -------------------------------------------

    (define (alist-copy alist)
      (map (lambda (p) (cons (car p) (cdr p))) alist))

    (define (alist-cons key datum alist)
      (cons (cons key datum) alist))

    ;; The optional comparison defaults to equal?, and the key is its first
    ;; argument, per SRFI 1 — (= key entry-key).
    (define (alist-delete key alist . rest)
      (let ((same? (if (pair? rest) (car rest) equal?)))
        (filter (lambda (p) (not (same? key (car p)))) alist)))

    (define (%del-as key alist same?)
      (filter (lambda (p) (not (same? key (car p)))) alist))

    (define (del-assq key alist)  (%del-as key alist eq?))
    (define (del-assv key alist)  (%del-as key alist eqv?))
    (define (del-assoc key alist) (%del-as key alist equal?))

    ;; --- sets over lists ---------------------------------------------

    ;; New elements are consed on the front, matching the SRFI 1 reference
    ;; implementation and kaappi: (lset-adjoin eqv? '(1 2) 2 3) is (3 1 2).
    ;; The spec leaves the order open; the shelf's tests pin kaappi's.
    (define (lset-adjoin elt= lst . elts)
      (fold (lambda (e acc)
              (if (%member? e acc elt=) acc (cons e acc)))
            lst elts))

    (define (lset-union elt= . lists)
      (if (null? lists)
          '()
          (fold (lambda (l acc)
                  (fold (lambda (e acc)
                          (if (%member? e acc elt=) acc (cons e acc)))
                        acc l))
                (car lists) (cdr lists))))

    (define (lset-intersection elt= lst . rest)
      (filter (lambda (e)
                (let loop ((ls rest))
                  (cond ((null? ls) #t)
                        ((%member? e (car ls) elt=) (loop (cdr ls)))
                        (else #f))))
              lst))

    (define (lset-difference elt= lst . rest)
      (filter (lambda (e)
                (let loop ((ls rest))
                  (cond ((null? ls) #t)
                        ((%member? e (car ls) elt=) #f)
                        (else (loop (cdr ls))))))
              lst))

    ;; Set equality is mutual containment; chained across the arguments the
    ;; way = chains across numbers.  No arguments or one argument is #t.
    (define (lset= elt= . lists)
      (let ((subset? (lambda (a b)
                       (let loop ((l a))
                         (cond ((null? l) #t)
                               ((%member? (car l) b elt=) (loop (cdr l)))
                               (else #f))))))
        (let loop ((ls lists))
          (cond ((null? ls) #t)
                ((null? (cdr ls)) #t)
                ((and (subset? (car ls) (cadr ls))
                      (subset? (cadr ls) (car ls)))
                 (loop (cdr ls)))
                (else #f)))))

    ;; Symmetric difference, folded pairwise across the arguments.
    (define (lset-xor elt= . lists)
      (let ((xor2 (lambda (a b)
                    (append (filter (lambda (e) (not (%member? e b elt=))) a)
                            (filter (lambda (e) (not (%member? e a elt=))) b)))))
        (if (null? lists)
            '()
            (let loop ((acc (car lists)) (ls (cdr lists)))
              (if (null? ls)
                  acc
                  (loop (xor2 acc (car ls)) (cdr ls)))))))))
