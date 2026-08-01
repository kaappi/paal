;;; (kaappi paal reader) — Self-hosted S-expression reader
;;;
;;; Stage 1 of the Paal compilation pipeline.
;;; Converts source text into a list of S-expressions.
;;;
;;; Supported token types:
;;;   ( )                — list structure
;;;   .                  — dotted pair separator (or symbol prefix)
;;;   ' ` , ,@           — reader abbreviations
;;;   #t #f #true #false — booleans
;;;   #\<char>           — characters (named, hex, single)
;;;   #( )               — vectors
;;;   #| ... |#          — block comments (nested)
;;;   #;                 — datum comments
;;;   " ... "            — strings with \n \t \r \a \b \" \\ \xHH; escapes
;;;   ; ...              — line comments
;;;   123 3.14 +inf.0    — numbers (via string->number)
;;;   identifier         — symbols
;;;
;;;   #u8( )             — bytevectors
;;;   #b #o #d #x        — radix prefixes
;;;   #e #i              — exactness prefixes
;;;   |...|              — bar-quoted symbols
;;;   #N= #N#            — datum labels (shared and circular structure)
;;;
;;; Not yet supported: bignum/rational/complex literals beyond what the host's
;;; string->number accepts.

(define-library (kaappi paal reader)
  (import (scheme base) (scheme char) (scheme file))
  (export paal-read paal-read-string paal-read-all paal-read-file)
  (begin

    ;; ---------------------------------------------------------------
    ;; Character classification
    ;; ---------------------------------------------------------------

    (define (delimiter? ch)
      (or (eof-object? ch)
          (char-whitespace? ch)
          (memv ch '(#\( #\) #\[ #\] #\{ #\} #\" #\; #\|))))

    (define (initial? ch)
      (or (char-alphabetic? ch)
          (memv ch '(#\! #\$ #\% #\& #\* #\/ #\: #\< #\= #\> #\? #\^ #\_ #\~))))

    (define (subsequent? ch)
      (or (initial? ch)
          (char-numeric? ch)
          (memv ch '(#\+ #\- #\. #\@))))

    ;; ---------------------------------------------------------------
    ;; Whitespace and comment skipping
    ;; ---------------------------------------------------------------

    (define (skip-whitespace! port)
      (let ((ch (peek-char port)))
        (cond
          ((eof-object? ch) #f)
          ((char-whitespace? ch) (read-char port) (skip-whitespace! port))
          ((char=? ch #\;)      (skip-line! port)  (skip-whitespace! port))
          (else #f))))

    (define (skip-line! port)
      (let ((ch (read-char port)))
        (if (or (eof-object? ch) (char=? ch #\newline))
            #f
            (skip-line! port))))

    (define (skip-block-comment! port depth)
      (let ((ch (read-char port)))
        (cond
          ((eof-object? ch)
           (error "paal-read: unterminated block comment"))
          ((char=? ch #\|)
           (if (char=? (peek-char port) #\#)
               (begin
                 (read-char port)
                 (if (= depth 0) #f (skip-block-comment! port (- depth 1))))
               (skip-block-comment! port depth)))
          ((char=? ch #\#)
           (if (char=? (peek-char port) #\|)
               (begin
                 (read-char port)
                 (skip-block-comment! port (+ depth 1)))
               (skip-block-comment! port depth)))
          (else
           (skip-block-comment! port depth)))))

    ;; ---------------------------------------------------------------
    ;; Collecting characters until a delimiter
    ;; ---------------------------------------------------------------

    (define (read-until-delimiter port)
      (let loop ((acc '()))
        (let ((ch (peek-char port)))
          (if (delimiter? ch)
              (reverse acc)
              (begin (read-char port) (loop (cons ch acc)))))))

    ;; ---------------------------------------------------------------
    ;; Atom reader: numbers and symbols
    ;; ---------------------------------------------------------------

    ;; #!fold-case / #!no-fold-case.  R7RS 2.1 scopes the directive to the rest
    ;; of the file it appears in, so this is reset per file rather than per
    ;; datum — see paal-read-all, and note that paal-read is deliberately not a
    ;; reset point.
    (define %fold-case? #f)

    (define (read-atom port first-ch)
      (let* ((rest (read-until-delimiter port))
             (chars (cons first-ch rest))
             (s    (list->string chars))
             (n    (string->number s)))
        ;; Fold the symbol branch only.  Numbers are unaffected by case beyond
        ;; what string->number already handles, and folding before the numeric
        ;; test would turn #xFF into a different token.
        (or n (string->symbol (if %fold-case? (string-foldcase s) s)))))

    ;; ---------------------------------------------------------------
    ;; String reader
    ;; ---------------------------------------------------------------

    (define (read-string-body port)
      (let loop ((acc '()))
        (let ((ch (read-char port)))
          (cond
            ((eof-object? ch)
             (error "paal-read: unterminated string"))
            ((char=? ch #\")
             (list->string (reverse acc)))
            ((char=? ch #\\)
             (let ((esc (read-char port)))
               (case esc
                 ((#\") (loop (cons #\" acc)))
                 ((#\\) (loop (cons #\\ acc)))
                 ((#\n) (loop (cons #\newline acc)))
                 ((#\r) (loop (cons #\return  acc)))
                 ((#\t) (loop (cons #\tab     acc)))
                 ((#\a) (loop (cons #\alarm   acc)))
                 ((#\b) (loop (cons #\backspace acc)))
                 ((#\0) (loop (cons #\null    acc)))
                 ((#\x)
                  (let hex-loop ((hacc '()))
                    (let ((c (read-char port)))
                      (if (char=? c #\;)
                          (let ((n (string->number
                                     (list->string (reverse hacc)) 16)))
                            (if n
                                (loop (cons (integer->char n) acc))
                                (error "paal-read: invalid \\x escape")))
                          (hex-loop (cons c hacc))))))
                 (else (error "paal-read: unknown escape" esc)))))
            (else (loop (cons ch acc)))))))

    ;; ---------------------------------------------------------------
    ;; Character literal reader (#\ already consumed)
    ;; ---------------------------------------------------------------

    (define (read-character port)
      (let ((ch (read-char port)))
        (cond
          ((eof-object? ch)
           (error "paal-read: EOF in character literal"))
          ((delimiter? (peek-char port))
           ch)                              ; single char: #\a #\(
          (else
           (let* ((rest (read-until-delimiter port))
                  (name (list->string (cons ch rest)))
                  ;; Under #!fold-case the character *name* folds, so #\NEWLINE
                  ;; reads.  A single-character literal does not — #\A stays
                  ;; #\A — which is why only this branch consults it; the
                  ;; single-char case above returns ch untouched.  The hex
                  ;; escape stays keyed on the unfolded ch and rest.
                  (name (if %fold-case? (string-foldcase name) name)))
             (cond
               ((string=? name "space")      #\space)
               ((string=? name "newline")    #\newline)
               ((string=? name "tab")        #\tab)
               ((string=? name "return")     #\return)
               ((string=? name "null")       #\null)
               ((string=? name "alarm")      #\alarm)
               ((string=? name "backspace")  #\backspace)
               ((string=? name "delete")     #\delete)
               ((string=? name "escape")     #\escape)
               ((string=? name "altmode")    #\escape)
               ((and (char=? ch #\x)
                     (not (null? rest)))
                (let ((n (string->number (list->string rest) 16)))
                  (if n (integer->char n)
                      (error "paal-read: bad hex char" name))))
               (else
                (error "paal-read: unknown character name" name))))))))

    ;; ---------------------------------------------------------------
    ;; Hash dispatch (#  already consumed)
    ;; ---------------------------------------------------------------

    ;; ---------------------------------------------------------------
    ;; Datum labels: #N= <datum> defines, #N# refers
    ;; ---------------------------------------------------------------
    ;;
    ;; R7RS 7.1.2 scopes a label to the outermost datum being read, so the
    ;; table is cleared by paal-read and every nested read goes through
    ;; read-datum, which does not clear it.
    ;;
    ;; A reference inside the datum it names cannot be resolved when it is read
    ;; — the datum does not exist yet.  #N= therefore registers a placeholder
    ;; first, reads the datum, and then walks it replacing the placeholder with
    ;; the finished datum.  That is what makes '#0=(a b . #0#) a real circular
    ;; list rather than a list containing a marker.
    ;;
    ;; A reference that appears *after* the definition is resolved on the spot,
    ;; so #0=5 followed by #0# needs no patching — which is why only pairs and
    ;; vectors are walked.  An unresolved reference is necessarily an element of
    ;; one or the other.

    (define %labels '())          ; alist: label -> #(resolved? value)

    (define (label-entry label)
      (let ((hit (assv label %labels)))
        (and hit (cdr hit))))

    ;; The structure is already circular by the time this runs, so `seen`
    ;; keeps the walk finite.  Threaded rather than mutated so the traversal
    ;; stays a plain recursion.
    (define (label-patch! obj placeholder value seen)
      (cond
        ((pair? obj)
         (if (memq obj seen)
             seen
             (let* ((seen (cons obj seen))
                    (seen (if (eq? (car obj) placeholder)
                              (begin (set-car! obj value) seen)
                              (label-patch! (car obj) placeholder value seen))))
               (if (eq? (cdr obj) placeholder)
                   (begin (set-cdr! obj value) seen)
                   (label-patch! (cdr obj) placeholder value seen)))))
        ((vector? obj)
         (if (memq obj seen)
             seen
             (let loop ((i 0) (seen (cons obj seen)))
               (if (= i (vector-length obj))
                   seen
                   (loop (+ i 1)
                         (if (eq? (vector-ref obj i) placeholder)
                             (begin (vector-set! obj i value) seen)
                             (label-patch! (vector-ref obj i)
                                           placeholder value seen)))))))
        (else seen)))

    ;; #N= or #N# — the leading digit has been consumed into `first-digit`.
    (define (read-label port first-digit)
      (let loop ((digits (list first-digit)))
        (let ((c (peek-char port)))
          (if (and (char? c) (char-numeric? c))
              (begin (read-char port) (loop (cons c digits)))
              (let ((label (string->number (list->string (reverse digits))))
                    (next  (read-char port)))
                (cond
                  ((eqv? next #\=)
                   ; Redefining a label within one datum is undefined in R7RS.
                   ; The fresh entry is consed on front, so assv finds it and
                   ; the later definition wins — which is what kaappi does, and
                   ; being stricter would reject programs kaappi accepts.
                   (let ((slot (vector #f (vector 'paal-datum-label label))))
                     (set! %labels (cons (cons label slot) %labels))
                     (let ((datum (read-datum port)))
                       (if (eq? datum (vector-ref slot 1))
                           (error "paal-read: datum label defined as itself"
                                  label)
                           (begin
                             (label-patch! datum (vector-ref slot 1) datum '())
                             (vector-set! slot 0 #t)
                             (vector-set! slot 1 datum)
                             datum)))))
                  ((eqv? next #\#)
                   (let ((slot (label-entry label)))
                     (if slot
                         (vector-ref slot 1)   ; placeholder if still unresolved
                         (error "paal-read: undefined datum label" label))))
                  (else
                   (error "paal-read: expected = or # after datum label"
                          label))))))))

    (define (read-hash port)
      (let ((ch (read-char port)))
        (cond
          ((eof-object? ch)
           (error "paal-read: unexpected EOF after #"))

          ;; Booleans
          ((char=? ch #\t)
           (if (delimiter? (peek-char port))
               #t
               (begin (read-until-delimiter port) #t)))
          ((char=? ch #\f)
           (if (delimiter? (peek-char port))
               #f
               (begin (read-until-delimiter port) #f)))

          ;; Character: #\...
          ((char=? ch #\\)
           (read-character port))

          ;; Vector: #( ...
          ((char=? ch #\()
           (list->vector (read-list port)))

          ;; Bytevector: #u8( ...
          ;; Filled element by element rather than via (apply bytevector elts):
          ;; self-hosted `apply` caps out at 8 arguments, and literals are longer.
          ((char=? ch #\u)
           (let ((eight (read-char port))
                 (open  (read-char port)))
             (if (not (and (eqv? eight #\8) (eqv? open #\()))
                 (error "paal-read: malformed bytevector, expected #u8(")
                 (let* ((elts (read-list port))
                        (bv   (make-bytevector (length elts) 0)))
                   (let loop ((i 0) (es elts))
                     (if (null? es)
                         bv
                         (let ((b (car es)))
                           (if (not (and (integer? b) (exact? b) (<= 0 b 255)))
                               (error "paal-read: bytevector element out of range" b)
                               (begin
                                 (bytevector-u8-set! bv i b)
                                 (loop (+ i 1) (cdr es)))))))))))

          ;; Directives: #!fold-case / #!no-fold-case.  Not data — they set
          ;; reader state and yield whatever comes next, the same shape as the
          ;; comment branches below.
          ((char=? ch #\!)
           (let ((name (list->string (read-until-delimiter port))))
             (cond
               ((string=? name "fold-case")    (set! %fold-case? #t))
               ((string=? name "no-fold-case") (set! %fold-case? #f))
               (else (error "paal-read: unknown directive" (string-append "#!" name))))
             (read-datum port)))

          ;; Block comment: #| ... |#
          ((char=? ch #\|)
           (skip-block-comment! port 0)
           (read-datum port))            ; tail call: read next datum

          ;; Datum comment: #; <datum>
          ((char=? ch #\;)
           (read-datum port)             ; read and discard
           (read-datum port))            ; return next datum

          ;; Radix prefixes: #b #o #d #x
          ((char=? ch #\b)
           (let ((n (string->number (list->string (read-until-delimiter port)) 2)))
             (or n (error "paal-read: invalid binary literal"))))
          ((char=? ch #\o)
           (let ((n (string->number (list->string (read-until-delimiter port)) 8)))
             (or n (error "paal-read: invalid octal literal"))))
          ((char=? ch #\d)
           (let ((n (string->number (list->string (read-until-delimiter port)) 10)))
             (or n (error "paal-read: invalid decimal literal"))))
          ((char=? ch #\x)
           (let ((n (string->number (list->string (read-until-delimiter port)) 16)))
             (or n (error "paal-read: invalid hex literal"))))

          ;; Datum label: #N= <datum> or #N#
          ;; Checked after the radix and exactness prefixes so #b1 etc. are
          ;; still prefixes, not labels — no prefix letter is a digit.
          ((char-numeric? ch)
           (read-label port ch))

          ;; Exactness prefixes: #e #i — read number that follows
          ((char=? ch #\e)
           (let ((s (list->string (read-until-delimiter port))))
             (or (string->number (string-append "#e" s))
                 (error "paal-read: invalid #e literal"))))
          ((char=? ch #\i)
           (let ((s (list->string (read-until-delimiter port))))
             (or (string->number (string-append "#i" s))
                 (error "paal-read: invalid #i literal"))))

          (else
           (error "paal-read: unknown # syntax" ch)))))

    ;; ---------------------------------------------------------------
    ;; List reader ( already consumed
    ;; ---------------------------------------------------------------

    (define (read-list port)
      (skip-whitespace! port)
      (let ((ch (peek-char port)))
        (cond
          ((eof-object? ch)
           (error "paal-read: unterminated list"))
          ((char=? ch #\))
           (read-char port)
           '())
          ((char=? ch #\.)
           (read-char port)
           (let ((ch2 (peek-char port)))
             (if (delimiter? ch2)
                 ; dotted pair tail: (car . cdr)
                 (let ((tail (read-datum port)))
                   (skip-whitespace! port)
                   (if (char=? (peek-char port) #\))
                       (begin (read-char port) tail)
                       (error "paal-read: expected ) after dotted pair")))
                 ; symbol beginning with .  e.g. ...
                 (let ((sym (read-atom port #\.)))
                   (cons sym (read-list port))))))
          (else
           (let ((elem (read-datum port)))
             (cons elem (read-list port)))))))

    ;; ---------------------------------------------------------------
    ;; Bar-quoted symbol reader (| already consumed)
    ;; ---------------------------------------------------------------

    (define (read-bar-symbol port)
      ; Read characters until closing |, with \ escape support. Returns a symbol.
      (let loop ((acc '()))
        (let ((ch (read-char port)))
          (cond
            ((eof-object? ch)
             (error "paal-read: unterminated bar-quoted symbol"))
            ((char=? ch #\|)
             (string->symbol (list->string (reverse acc))))
            ((char=? ch #\\)
             (loop (cons (read-char port) acc)))
            (else
             (loop (cons ch acc)))))))

    ;; ---------------------------------------------------------------
    ;; Main reader
    ;; ---------------------------------------------------------------

    ;; The recursive worker.  Every nested read goes through this, so a datum
    ;; label stays in scope for the whole of the datum that defines it.
    (define (read-datum port)
      (skip-whitespace! port)
      (let ((ch (peek-char port)))
        (cond
          ((eof-object? ch) ch)

          ((char=? ch #\()
           (read-char port)
           (read-list port))

          ((char=? ch #\))
           (error "paal-read: unexpected )"))

          ((char=? ch #\#)
           (read-char port)
           (read-hash port))

          ((char=? ch #\")
           (read-char port)
           (read-string-body port))

          ((char=? ch #\')
           (read-char port)
           (list 'quote (read-datum port)))

          ((char=? ch #\`)
           (read-char port)
           (list 'quasiquote (read-datum port)))

          ((char=? ch #\,)
           (read-char port)
           (if (char=? (peek-char port) #\@)
               (begin (read-char port)
                      (list 'unquote-splicing (read-datum port)))
               (list 'unquote (read-datum port))))

          ((char=? ch #\|)
           (read-char port)
           (read-bar-symbol port))

          ;; Numbers and symbols: read until delimiter, try string->number
          (else
           (read-char port)
           (read-atom port ch)))))

    ;; ---------------------------------------------------------------
    ;; Public API
    ;; ---------------------------------------------------------------

    ;; Read one datum.  R7RS scopes datum labels to the outermost datum, which
    ;; is exactly this call, so the table is cleared here and nowhere else.
    (define (paal-read port)
      (set! %labels '())
      (read-datum port))

    ;; The fold-case directive is scoped to the rest of the file, so it is reset
    ;; here and NOT in paal-read: paal-read is one datum, and resetting there
    ;; would make the directive apply to nothing but itself.
    (define (paal-read-all port)
      (set! %fold-case? #f)
      (let loop ((acc '()))
        (skip-whitespace! port)
        (let ((datum (paal-read port)))
          (if (eof-object? datum)
              (reverse acc)
              (loop (cons datum acc))))))

    (define (paal-read-string src)
      (paal-read-all (open-input-string src)))

    (define (paal-read-file path)
      (let* ((port  (open-input-file path))
             (forms (paal-read-all port)))
        (close-input-port port)
        forms))))
