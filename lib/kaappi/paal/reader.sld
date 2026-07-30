;;; (kaappi paal reader) — S-expression reader
;;;
;;; Stage 1 of the Paal compilation pipeline.
;;; Converts source text into a list of S-expressions.
;;;
;;; Currently delegates to the host reader; will be replaced by a
;;; self-hosted reader as the project matures.

(define-library (kaappi paal reader)
  (import (scheme base) (scheme read))
  (export paal-read paal-read-string paal-read-all paal-read-file)
  (begin

    (define (paal-read port)
      (read port))

    (define (paal-read-string src)
      (paal-read-all (open-input-string src)))

    (define (paal-read-all port)
      (let loop ((acc '()))
        (let ((form (read port)))
          (if (eof-object? form)
              (reverse acc)
              (loop (cons form acc))))))

    (define (paal-read-file path)
      (let* ((port  (open-input-file path))
             (forms (paal-read-all port)))
        (close-input-port port)
        forms))))
