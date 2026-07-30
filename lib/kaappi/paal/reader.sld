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
;;; Not yet supported: #u8(, datum labels (#N= #N#),
;;; bignum/rational/complex literals (delegated to string->number if supported
;;; by the host), #e/#i exactness prefixes.

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

    (define (read-atom port first-ch)
      (let* ((rest (read-until-delimiter port))
             (chars (cons first-ch rest))
             (s    (list->string chars))
             (n    (string->number s)))
        (or n (string->symbol s))))

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
                  (name (list->string (cons ch rest))))
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

          ;; Block comment: #| ... |#
          ((char=? ch #\|)
           (skip-block-comment! port 0)
           (paal-read port))              ; tail call: read next datum

          ;; Datum comment: #; <datum>
          ((char=? ch #\;)
           (paal-read port)              ; read and discard
           (paal-read port))             ; return next datum

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
                 (let ((tail (paal-read port)))
                   (skip-whitespace! port)
                   (if (char=? (peek-char port) #\))
                       (begin (read-char port) tail)
                       (error "paal-read: expected ) after dotted pair")))
                 ; symbol beginning with .  e.g. ...
                 (let ((sym (read-atom port #\.)))
                   (cons sym (read-list port))))))
          (else
           (let ((elem (paal-read port)))
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

    (define (paal-read port)
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
           (list 'quote (paal-read port)))

          ((char=? ch #\`)
           (read-char port)
           (list 'quasiquote (paal-read port)))

          ((char=? ch #\,)
           (read-char port)
           (if (char=? (peek-char port) #\@)
               (begin (read-char port)
                      (list 'unquote-splicing (paal-read port)))
               (list 'unquote (paal-read port))))

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

    (define (paal-read-all port)
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
