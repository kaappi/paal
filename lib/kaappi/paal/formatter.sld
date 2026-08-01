;;; (kaappi paal formatter) — canonical source formatter
;;;
;;; `paal fmt` reprints Scheme source with 2-space indentation.  It cannot use
;;; paal-read: the reader discards comments, and a formatter that drops them is
;;; worse than none.  So this has its own scanner producing a tree that keeps
;;; comments and blank lines as nodes alongside the code.
;;;
;;; Node shapes, all vectors tagged with an interned symbol:
;;;
;;;   #(atom text)        a token printed verbatim — symbol, number, string,
;;;                       character, #t/#f, #u8( … ) contents, quote marks
;;;   #(list open items)  a parenthesised form; `open` is "(" or "#(" so
;;;                       vectors survive
;;;   #(comment text)     a ; comment, printed on its own line
;;;   #(trailing text)    a ; comment that followed code on the same line
;;;   #(block text)       a #| … |# comment, printed verbatim
;;;   #(blank)            one or more blank lines, collapsed to one
;;;
;;; Strings and characters are scanned as single atoms and never reflowed, so
;;; no escape or embedded newline can be corrupted by indentation.
;;;
;;; The invariant that matters is that formatting never changes what the reader
;;; sees.  `paal fmt --check` reports files that are not already formatted;
;;; the test suite additionally asserts, for every case, that reading the
;;; formatted text yields data equal? to reading the original.

(define-library (kaappi paal formatter)
  (import (scheme base) (scheme char) (scheme file) (scheme write))
  (export paal-format-string paal-format-file paal-format-file!
          paal-format-check-file)
  (begin

    (define %atom     '%paal-fmt-atom)
    (define %list     '%paal-fmt-list)
    (define %comment  '%paal-fmt-comment)
    (define %trailing '%paal-fmt-trailing)
    (define %block    '%paal-fmt-block)
    (define %blank    '%paal-fmt-blank)

    (define (node-kind n) (vector-ref n 0))
    (define (node-text n) (vector-ref n 1))

    (define %width 80)

    ;; --- scanner ------------------------------------------------------
    ;;
    ;; Hand-rolled over a string with an index, so a token's exact source text
    ;; can be sliced out verbatim.  `pos` is threaded rather than mutated so a
    ;; sub-scan can report where it stopped.

    (define (at src i) (if (< i (string-length src)) (string-ref src i) #f))

    (define (delim? c)
      (or (not c) (char-whitespace? c)
          (memv c '(#\( #\) #\[ #\] #\" #\;))))

    ;; A string literal, from the opening quote to the closing one, escapes
    ;; included.  Returned whole so nothing inside is ever touched.
    (define (scan-string src i)
      (let loop ((j (+ i 1)))
        (let ((c (at src j)))
          (cond
            ((not c) (error "paal fmt: unterminated string"))
            ((char=? c #\\) (loop (+ j 2)))
            ((char=? c #\") (+ j 1))
            (else (loop (+ j 1)))))))

    ;; #\x, #\space, #\( — the character after #\ is taken literally, then any
    ;; name characters that follow.
    (define (scan-char src i)
      (let loop ((j (+ i 3)))
        (if (delim? (at src j)) j (loop (+ j 1)))))

    (define (scan-block-comment src i)
      (let loop ((j (+ i 2)) (depth 1))
        (cond
          ((not (at src j)) (error "paal fmt: unterminated block comment"))
          ((and (eqv? (at src j) #\|) (eqv? (at src (+ j 1)) #\#))
           (if (= depth 1) (+ j 2) (loop (+ j 2) (- depth 1))))
          ((and (eqv? (at src j) #\#) (eqv? (at src (+ j 1)) #\|))
           (loop (+ j 2) (+ depth 1)))
          (else (loop (+ j 1) depth)))))

    (define (scan-line-comment src i)
      (let loop ((j i))
        (if (or (not (at src j)) (char=? (at src j) #\newline)) j (loop (+ j 1)))))

    (define (scan-atom src i)
      (let loop ((j i))
        (cond
          ((delim? (at src j)) j)
          ((eqv? (at src j) #\|)          ; |bar quoted symbol|
           (let bar ((k (+ j 1)))
             (cond ((not (at src k)) (error "paal fmt: unterminated |symbol|"))
                   ((char=? (at src k) #\|) (loop (+ k 1)))
                   (else (bar (+ k 1))))))
          (else (loop (+ j 1))))))

    ;; Whitespace between tokens.  Returns (cons next-index blank?) where
    ;; blank? is true when two or more newlines were crossed — that is what
    ;; makes a blank line a node rather than something the printer invents.
    (define (skip-space src i)
      (let loop ((j i) (newlines 0))
        (let ((c (at src j)))
          (cond
            ((not c) (cons j (>= newlines 2)))
            ((char=? c #\newline) (loop (+ j 1) (+ newlines 1)))
            ((char-whitespace? c) (loop (+ j 1) newlines))
            (else (cons j (>= newlines 2)))))))

    ;; Was there a newline between i and j?  A comment with code before it on
    ;; the same line is trailing, and must stay there.
    (define (newline-between? src i j)
      (let loop ((k i))
        (cond ((>= k j) #f)
              ((eqv? (at src k) #\newline) #t)
              (else (loop (+ k 1))))))

    ;; Scan one node.  Returns (cons node next-index), or #f at end of input
    ;; or on a closing paren.
    (define (scan-node src i close-ok?)
      (let ((c (at src i)))
        (cond
          ((not c) #f)
          ((or (char=? c #\)) (char=? c #\])) #f)
          ((char=? c #\;)
           (let ((end (scan-line-comment src i)))
             (cons (vector %comment (substring src i end)) end)))
          ((and (char=? c #\#) (eqv? (at src (+ i 1)) #\|))
           (let ((end (scan-block-comment src i)))
             (cons (vector %block (substring src i end)) end)))
          ;; #; discards the next datum; keep both verbatim as one atom so the
          ;; commented-out form survives untouched.
          ((and (char=? c #\#) (eqv? (at src (+ i 1)) #\;))
           (let* ((after (car (skip-space src (+ i 2))))
                  (sub   (scan-node src after #f)))
             (if sub
                 (cons (vector %atom (substring src i (cdr sub))) (cdr sub))
                 (error "paal fmt: #; with no datum"))))
          ((char=? c #\")
           (let ((end (scan-string src i)))
             (cons (vector %atom (substring src i end)) end)))
          ((and (char=? c #\#) (eqv? (at src (+ i 1)) #\\))
           (let ((end (scan-char src i)))
             (cons (vector %atom (substring src i end)) end)))
          ((or (char=? c #\() (char=? c #\[))
           (scan-list src i "("))
          ((and (char=? c #\#) (eqv? (at src (+ i 1)) #\())
           (scan-list src (+ i 1) "#("))
          ((and (char=? c #\#) (eqv? (at src (+ i 1)) #\u)
                (eqv? (at src (+ i 2)) #\8) (eqv? (at src (+ i 3)) #\())
           (scan-list src (+ i 3) "#u8("))
          ;; Reader abbreviations attach to what follows, so they are scanned
          ;; together — otherwise 'x could be split across a line break.
          ((or (char=? c #\') (char=? c #\`)
               (and (char=? c #\,) #t))
           (let* ((n     (if (and (char=? c #\,) (eqv? (at src (+ i 1)) #\@)) 2 1))
                  (after (car (skip-space src (+ i n))))
                  (sub   (scan-node src after #f)))
             (if (not sub)
                 (cons (vector %atom (substring src i (+ i n))) (+ i n))
                 (let ((inner (car sub)))
                   (if (eq? (node-kind inner) %list)
                       ;; keep the abbreviation glued to the list it quotes
                       (cons (vector %list
                                     (string-append (substring src i (+ i n))
                                                    (vector-ref inner 1))
                                     (vector-ref inner 2))
                             (cdr sub))
                       (cons (vector %atom (substring src i (cdr sub)))
                             (cdr sub)))))))
          (else
           (let ((end (scan-atom src i)))
             (if (= end i)
                 (error "paal fmt: cannot scan at" i)
                 (cons (vector %atom (substring src i end)) end)))))))

    (define (scan-list src i open)
      (let loop ((j (+ i 1)) (items '()) (prev-end (+ i 1)))
        (let* ((sk    (skip-space src j))
               (k     (car sk))
               (blank (cdr sk))
               (c     (at src k)))
          (cond
            ((not c) (error "paal fmt: unterminated list"))
            ((or (char=? c #\)) (char=? c #\]))
             (cons (vector %list open (reverse items)) (+ k 1)))
            (else
             (let ((node (scan-node src k #t)))
               (if (not node)
                   (error "paal fmt: unexpected close")
                   (let* ((n (car node))
                          ;; a ; comment with code before it on the same line
                          ;; belongs at the end of that line
                          (n (if (and (eq? (node-kind n) %comment)
                                      (pair? items)
                                      (not (newline-between? src prev-end k)))
                                 (vector %trailing (node-text n))
                                 n))
                          (items (if (and blank (pair? items))
                                     (cons n (cons (vector %blank "") items))
                                     (cons n items))))
                     (loop (cdr node) items (cdr node))))))))))

    (define (scan-top src)
      (let loop ((i 0) (nodes '()) (prev-end 0))
        (let* ((sk    (skip-space src i))
               (k     (car sk))
               (blank (cdr sk)))
          (if (not (at src k))
              (reverse nodes)
              (let ((node (scan-node src k #t)))
                (if (not node)
                    (error "paal fmt: unexpected ) at top level")
                    (let* ((n (car node))
                           (n (if (and (eq? (node-kind n) %comment)
                                       (pair? nodes)
                                       (not (newline-between? src prev-end k)))
                                  (vector %trailing (node-text n))
                                  n))
                           (nodes (if (and blank (pair? nodes))
                                      (cons n (cons (vector %blank "") nodes))
                                      (cons n nodes))))
                      (loop (cdr node) nodes (cdr node)))))))))

    ;; --- indentation rules --------------------------------------------
    ;;
    ;; `special` gives the number of leading sub-forms that stay on the head's
    ;; line; everything after them is body, indented 2 from the open paren.
    ;; A form not listed here aligns its arguments under the first argument,
    ;; which is the usual Scheme convention for procedure calls.

    (define %special
      '((define . 1) (define-values . 1) (define-syntax . 1)
        (define-record-type . 3) (define-library . 1)
        (lambda . 1) (case-lambda . 0) (named-lambda . 1)
        (let . 1) (let* . 1) (letrec . 1) (letrec* . 1)
        (let-values . 1) (let*-values . 1) (let-syntax . 1) (letrec-syntax . 1)
        (parameterize . 1) (guard . 1) (do . 2) (case . 1)
        (when . 1) (unless . 1) (while . 1)
        (begin . 0) (cond . 0) (and . 0) (or . 0) (else . 0)
        (syntax-rules . 1) (with-exception-handler . 0)
        (call-with-values . 0) (dynamic-wind . 0)
        (if . 1) (set! . 1) (delay . 0) (delay-force . 0)
        (import . 0) (export . 0) (include . 0) (cond-expand . 0)
        (test-group . 1) (test-equal . 2) (test-assert . 1)))

    (define (special-arity head)
      (and (string? head)
           (let ((hit (assq (string->symbol head) %special)))
             (and hit (cdr hit)))))

    (define (head-text items)
      (and (pair? items)
           (eq? (node-kind (car items)) %atom)
           (node-text (car items))))

    ;; --- printer ------------------------------------------------------

    (define (spaces n) (make-string n #\space))

    ;; One line, if the node has no comment or blank in it and fits.
    (define (flat n)
      (case (node-kind n)
        ((%paal-fmt-atom) (node-text n))
        ((%paal-fmt-list)
         (let loop ((items (vector-ref n 2)) (parts '()))
           (cond
             ((null? items)
              (string-append (vector-ref n 1)
                             (join (reverse parts) " ")
                             ")"))
             ;; a comment or blank forces the multi-line path
             ((memq (node-kind (car items))
                    (list %comment %trailing %block %blank))
              #f)
             (else
              (let ((f (flat (car items))))
                (and f (loop (cdr items) (cons f parts))))))))
        (else #f)))

    (define (join strings sep)
      (if (null? strings)
          ""
          (let loop ((l (cdr strings)) (acc (car strings)))
            (if (null? l) acc (loop (cdr l) (string-append acc sep (car l)))))))

    (define (emit! out n col)
      (case (node-kind n)
        ((%paal-fmt-atom)    (display (node-text n) out))
        ((%paal-fmt-comment) (display (node-text n) out))
        ((%paal-fmt-block)   (display (node-text n) out))
        ((%paal-fmt-trailing)(display (node-text n) out))
        ((%paal-fmt-blank)   #t)
        ((%paal-fmt-list)    (emit-list! out n col))
        (else (error "paal fmt: unknown node"))))

    (define (emit-list! out n col)
      (let* ((open  (vector-ref n 1))
             (items (vector-ref n 2))
             (one   (flat n)))
        (if (and one (<= (+ col (string-length one)) %width))
            (display one out)
            (let* ((inner (+ col (string-length open)))
                   (head  (head-text items))
                   (arity (special-arity head)))
              (display open out)
              (if (null? items)
                  (display ")" out)
                  (let* ((body-col (if arity (+ col 2) inner))
                         ;; how many items ride on the head's line
                         (inline (if arity (+ 1 arity) 1)))
                    (let loop ((l items) (i 0) (col* inner))
                      (cond
                        ((null? l) (display ")" out))
                        ((eq? (node-kind (car l)) %blank)
                         (newline out)
                         (loop (cdr l) i col*))
                        ((eq? (node-kind (car l)) %trailing)
                         (display " " out)
                         (display (node-text (car l)) out)
                         (loop (cdr l) i col*))
                        ((= i 0)
                         (emit! out (car l) col*)
                         (loop (cdr l) 1 (+ col* (item-width (car l)))))
                        ((< i inline)
                         (display " " out)
                         (emit! out (car l) (+ col* 1))
                         (loop (cdr l) (+ i 1)
                               (+ col* 1 (item-width (car l)))))
                        (else
                         (newline out)
                         (display (spaces body-col) out)
                         (emit! out (car l) body-col)
                         (loop (cdr l) (+ i 1) body-col))))))))))

    ;; Width of a node when printed flat; a multi-line one reports its first
    ;; line's length, which is what the column tracking needs.
    (define (item-width n)
      (let ((f (flat n)))
        (if f (string-length f) 0)))

    (define (paal-format-string src)
      (let ((out   (open-output-string))
            (nodes (scan-top src)))
        (let loop ((l nodes) (first #t))
          (cond
            ((null? l) #t)
            ((eq? (node-kind (car l)) %blank)
             (newline out)
             (loop (cdr l) first))
            ((eq? (node-kind (car l)) %trailing)
             (display " " out)
             (display (node-text (car l)) out)
             (loop (cdr l) first))
            (else
             (unless first (newline out))
             (emit! out (car l) 0)
             (loop (cdr l) #f))))
        (let ((text (get-output-string out)))
          (if (string=? text "") "" (string-append text "\n")))))

    (define (%slurp path)
      (let ((port (open-input-file path)))
        (let loop ((acc ""))
          (let ((chunk (read-string 4096 port)))
            (if (eof-object? chunk)
                (begin (close-input-port port) acc)
                (loop (string-append acc chunk)))))))

    (define (paal-format-file path) (paal-format-string (%slurp path)))

    (define (paal-format-file! path)
      (let ((formatted (paal-format-file path)))
        (let ((port (open-output-file path)))
          (display formatted port)
          (close-output-port port))
        #t))

    ;; #t if the file is already formatted.
    (define (paal-format-check-file path)
      (string=? (%slurp path) (paal-format-file path)))))
