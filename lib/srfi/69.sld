;;; SRFI 69 — Basic Hash Tables
;;;
;;; Separate chaining over a vector of buckets, grown when the load factor
;;; passes 0.75.  The table is a tagged vector rather than a record, matching
;;; the convention the rest of paal uses for values that may cross the
;;; HOST/self-hosted boundary: a record type's identity is per compiled copy,
;;; while an interned symbol is the same object in both.
;;;
;;; hash for a string or symbol is the usual multiply-and-add over the
;;; characters; anything else falls back to a constant, which is correct but
;;; degrades that key's lookups to a linear scan of its bucket.  Numbers get an
;;; exact-integer path so numeric keys, the other common case, spread properly.

(define-library (srfi 69)
  (import (scheme base) (scheme char))
  (export
    make-hash-table hash-table? hash-table-set! hash-table-ref
    hash-table-ref/default hash-table-delete! hash-table-exists?
    hash-table-size hash-table-keys hash-table-values hash-table-walk
    hash-table-fold hash-table->alist alist->hash-table
    hash-table-update! hash-table-update!/default hash-table-copy
    hash-table-clear! hash string-hash string-ci-hash hash-by-identity)
  (begin

    (define %ht-tag '%srfi69-hash-table)
    (define %initial-buckets 16)

    ;; #(tag buckets count equal-proc hash-proc)
    (define (%buckets t)   (vector-ref t 1))
    (define (%count t)     (vector-ref t 2))
    (define (%equiv t)     (vector-ref t 3))
    (define (%hashfn t)    (vector-ref t 4))
    (define (%set-buckets! t v) (vector-set! t 1 v))
    (define (%set-count! t n)   (vector-set! t 2 n))

    (define (hash-table? x)
      (and (vector? x) (= (vector-length x) 5) (eq? (vector-ref x 0) %ht-tag)))

    ;; (make-hash-table [equal [hash]])
    (define (make-hash-table . rest)
      (let ((eq-proc (if (pair? rest) (car rest) equal?))
            (h-proc  (if (and (pair? rest) (pair? (cdr rest)))
                         (cadr rest)
                         hash)))
        (vector %ht-tag (make-vector %initial-buckets '()) 0 eq-proc h-proc)))

    ;; --- hashing -----------------------------------------------------

    (define (string-hash s . rest)
      (let ((bound (if (pair? rest) (car rest) 0)))
        (let loop ((i 0) (h 5381))
          (if (= i (string-length s))
              (if (> bound 0) (modulo h bound) h)
              (loop (+ i 1)
                    (modulo (+ (* h 33) (char->integer (string-ref s i)))
                            1000000007))))))

    (define (string-ci-hash s . rest)
      (apply string-hash (string-foldcase s) rest))

    (define (hash obj . rest)
      (let ((bound (if (pair? rest) (car rest) 0))
            (h (cond
                 ((string? obj) (string-hash obj))
                 ((symbol? obj) (string-hash (symbol->string obj)))
                 ((char? obj)   (char->integer obj))
                 ((and (number? obj) (exact? obj) (integer? obj)) (abs obj))
                 ((number? obj) (abs (exact (truncate obj))))
                 ((boolean? obj) (if obj 1 0))
                 ((null? obj) 2)
                 ((pair? obj) 3)
                 ((vector? obj) (vector-length obj))
                 (else 0))))
        (if (> bound 0) (modulo h bound) h)))

    (define (hash-by-identity obj . rest) (apply hash obj rest))

    (define (%index t key)
      (modulo ((%hashfn t) key) (vector-length (%buckets t))))

    ;; --- core operations ---------------------------------------------

    (define (%assoc-in t key bucket)
      (let ((same? (%equiv t)))
        (let loop ((b bucket))
          (cond ((null? b) #f)
                ((same? key (caar b)) (car b))
                (else (loop (cdr b)))))))

    (define (hash-table-set! t key value)
      (let* ((i   (%index t key))
             (bkt (vector-ref (%buckets t) i))
             (hit (%assoc-in t key bkt)))
        (if hit
            (set-cdr! hit value)
            (begin
              (vector-set! (%buckets t) i (cons (cons key value) bkt))
              (%set-count! t (+ (%count t) 1))
              (when (> (* 4 (%count t)) (* 3 (vector-length (%buckets t))))
                (%grow! t))))))

    ;; Rehash into a table twice the size.  Entries are re-consed rather than
    ;; moved so the old buckets can be dropped whole.
    (define (%grow! t)
      (let* ((old (%buckets t))
             (new (make-vector (* 2 (vector-length old)) '())))
        (%set-buckets! t new)
        (let loop ((i 0))
          (when (< i (vector-length old))
            (for-each
              (lambda (entry)
                (let ((j (%index t (car entry))))
                  (vector-set! new j (cons entry (vector-ref new j)))))
              (vector-ref old i))
            (loop (+ i 1))))))

    ;; (hash-table-ref t key [failure [success]])
    (define (hash-table-ref t key . rest)
      (let ((hit (%assoc-in t key (vector-ref (%buckets t) (%index t key)))))
        (cond
          (hit (if (and (pair? rest) (pair? (cdr rest)))
                   ((cadr rest) (cdr hit))
                   (cdr hit)))
          ((pair? rest) ((car rest)))
          (else (error "hash-table-ref: no such key" key)))))

    (define (hash-table-ref/default t key default)
      (let ((hit (%assoc-in t key (vector-ref (%buckets t) (%index t key)))))
        (if hit (cdr hit) default)))

    (define (hash-table-exists? t key)
      (and (%assoc-in t key (vector-ref (%buckets t) (%index t key))) #t))

    (define (hash-table-delete! t key)
      (let* ((i     (%index t key))
             (bkt   (vector-ref (%buckets t) i))
             (same? (%equiv t))
             (kept  (let loop ((b bkt) (acc '()) (found #f))
                      (cond
                        ((null? b) (cons (reverse acc) found))
                        ((same? key (caar b)) (loop (cdr b) acc #t))
                        (else (loop (cdr b) (cons (car b) acc) found))))))
        (vector-set! (%buckets t) i (car kept))
        (when (cdr kept) (%set-count! t (- (%count t) 1)))))

    (define (hash-table-size t) (%count t))

    (define (hash-table-walk t proc)
      (let loop ((i 0))
        (when (< i (vector-length (%buckets t)))
          (for-each (lambda (e) (proc (car e) (cdr e)))
                    (vector-ref (%buckets t) i))
          (loop (+ i 1)))))

    (define (hash-table-fold t kons knil)
      (let ((acc knil))
        (hash-table-walk t (lambda (k v) (set! acc (kons k v acc))))
        acc))

    (define (hash-table-keys t)
      (hash-table-fold t (lambda (k v acc) (cons k acc)) '()))

    (define (hash-table-values t)
      (hash-table-fold t (lambda (k v acc) (cons v acc)) '()))

    (define (hash-table->alist t)
      (hash-table-fold t (lambda (k v acc) (cons (cons k v) acc)) '()))

    ;; Earlier entries win, per SRFI 69.
    (define (alist->hash-table alist . rest)
      (let ((t (apply make-hash-table rest)))
        (for-each (lambda (p)
                    (unless (hash-table-exists? t (car p))
                      (hash-table-set! t (car p) (cdr p))))
                  alist)
        t))

    (define (hash-table-update! t key proc . rest)
      (let ((current
             (if (pair? rest)
                 (hash-table-ref t key (car rest))
                 (hash-table-ref t key))))
        (hash-table-set! t key (proc current))))

    (define (hash-table-update!/default t key proc default)
      (hash-table-set! t key (proc (hash-table-ref/default t key default))))

    (define (hash-table-copy t)
      (let ((out (vector %ht-tag
                         (make-vector (vector-length (%buckets t)) '())
                         0 (%equiv t) (%hashfn t))))
        (hash-table-walk t (lambda (k v) (hash-table-set! out k v)))
        out))

    (define (hash-table-clear! t)
      (%set-buckets! t (make-vector %initial-buckets '()))
      (%set-count! t 0))))
