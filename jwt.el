;;; jwt.el --- Interact with JSON Web Tokens -*- lexical-binding: t -*-

;; Author: Josh Bax
;; Maintainer: Josh Bax
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Homepage: https://github.com/joshbax189/jwt-el
;; Keywords: tools convenience


;; This file is not part of GNU Emacs

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


;;; Commentary:

;; Never paste your tokens into jwt.io again!

;;; Code:

;; TODO can we display eldoc for defined claims?

(require 'json)
(require 'cl-lib)
(require 'hmac-def)

(defun jwt--hex-string-to-bytes (hex &optional left-align)
  "Convert a hex string HEX to a byte string.

When LEFT-ALIGN is true, interpret odd length strings greedily
E.g. CCC becomes [204, 12] not [12 204]."
  ;; ambiguous when odd length string
  ;; e.g. CCC is either [12 204], or [204, 12]
  ;; but CCCC is always [204, 204]
  (unless (cl-evenp (length hex))
    (warn "Possibly ambiguous hex string")
    (unless left-align
      (setq hex (concat "0" hex))))
  (let ((res (mapcar (lambda (x)
                       (string-to-number x 16))
                     (seq-partition hex 2))))
    (apply #'vector res)))

(defun jwt--byte-string-to-hex (bytes)
  "Convert a byte string BYTES to a hex string."
  (let (res)
    (dolist (x (seq--into-list bytes))
      ;; should always produce a len 2 string
      (push (format "%02x" x) res))
    (apply #'concat (reverse res))))

(defun jwt--i2osp (x x-len)
  "Encode number X as an X-LEN long list of bytes."
  (when (> x (expt 256 x-len))
    (error "Integer too large"))
  (let (res
        (rem 0)
        (idx (1- x-len)))
    (while (and (> x 0) (>= idx 0))
      (setq rem (% x (expt 256 idx)))
      (push (/ (- x rem) (expt 256 idx)) res)
      (setq x rem)
      (setq idx (1- idx)))
    (reverse res)))

(defun jwt-sha256 (str)
  "Apply SHA256 interpreting STR as a binary string and returning a binary string."
  (secure-hash 'sha256 (apply 'unibyte-string (string-to-list str)) nil nil 't))

(defun jwt-sha384 (str)
  "Apply SHA384 interpreting STR as a binary string and returning a binary string."
  (secure-hash 'sha384 (apply 'unibyte-string (string-to-list str)) nil nil 't))

(defun jwt-sha512 (str)
  "Apply SHA512 interpreting STR as a binary string and returning a binary string."
  (secure-hash 'sha512 (apply 'unibyte-string (string-to-list str)) nil nil 't))

(define-hmac-function jwt-hs256 jwt-sha256 64 32)

(define-hmac-function jwt-hs384 jwt-sha384 128 48)

(define-hmac-function jwt-hs512 jwt-sha512 128 64)

;; TODO which signing methods are supported?
;; rest use asymmetric PKI
;; this is the recommended one
;; RSASHA256
;; RS256
;; RS384
;; RS512

;; so sha the JSON, then sign, perhaps with epg?
;; probably only if you want to sign your own?
;; more flexible if you just take a public key string?

;; (let ((context (epg-make-context 'OpenPGP)))
;;   (decode-coding-string
;;    (epg-decrypt-string context (string-as-unibyte (base64-decode-string "Eci61G6w4zh_u9oOCk_v1M_sKcgk0svOmW4ZsL-rt4ojGUH2QY110bQTYNwbEVlowW7phCg7vluX_MCKVwJkxJT6tMk2Ij3Plad96Jf2G2mMsKbxkC-prvjvQkBFYWrYnKWClPBRCyIcG0dVfBvqZ8Mro3t5bX59IKwQ3WZ7AtGBYz5BSiBlrKkp6J1UmP_bFV3eEzIHEFgzRa3pbr4ol4TK6SnAoF88rLr2NhEz9vpdHglUMlOBQiqcZwqrI-Z4XDyDzvnrpujIToiepq9bCimPgVkP54VoZzy-mMSGbthYpLqsL_4MQXaI1Uf_wKFAUuAtzVn4-ebgsKOpvKNzVA" 't)))
;;     'utf-8))

(defun read-forward-bytes (x)
  (if (> x ?\x80)
      (- x ?\x80)
    x))

(defun byte-to-num (x)
  "Concat a list of bytes X and convert to number."
  (string-to-number (apply 'concat (--map (format "%02x" it) x)) 16))

;; see https://en.wikipedia.org/wiki/X.690#DER_encoding
(defun jwt-parse-spki-rsa (spki-string)
  "foo"
  (setq spki-string (string-remove-prefix "-----BEGIN PUBLIC KEY-----"
                                          (string-remove-suffix "-----END PUBLIC KEY-----"
                                                                (string-trim spki-string))))
  (let* ((spki-bin-string (string-to-list (base64-decode-string spki-string)))
         ;; drop first 24 bytes
         (spki-bin-string (seq-drop spki-bin-string 24))
         result-n
         result-e)
    ;; SEQ LEN L
    (unless (equal (seq-first spki-bin-string)
                   ?\x30)
      (error "Unexpected prefix, not SEQ"))
    (setq spki-bin-string (cdr spki-bin-string))
    (let ((fwd (read-forward-bytes (car spki-bin-string))))
      (setq spki-bin-string (seq-drop spki-bin-string (1+ fwd))))
    ;; INT LEN L
    (unless (equal (seq-first spki-bin-string)
                   ?\x02)
      (error "Unexpected prefix %s, not INT 1" (seq-first spki-bin-string)))
    (setq spki-bin-string (cdr spki-bin-string))
    (let* ((der-byte (car spki-bin-string))
           (_ (setq spki-bin-string (cdr spki-bin-string)))
           len)
      (if (> ?\x80 der-byte)
          (setq len der-byte)
        (let ((fwd (- der-byte ?\x80)))
         (setq len (byte-to-num (seq-take spki-bin-string fwd)))
         (setq spki-bin-string (seq-drop spki-bin-string fwd))))
      ;; next len bytes are the actual number
      (setq result-n (seq-drop-while (lambda (x) (= 0 x)) (seq-take spki-bin-string len)))
      (setq spki-bin-string (seq-drop spki-bin-string len)))
    ;; INT LEN L
    (unless (equal (seq-first spki-bin-string)
                   ?\x02)
      (error "Unexpected prefix %s, not INT 2" (seq-first spki-bin-string)))
    (setq spki-bin-string (cdr spki-bin-string))
    (let* ((der-byte (car spki-bin-string))
           (_ (setq spki-bin-string (cdr spki-bin-string)))
           len)
      (if (> ?\x80 der-byte)
          (setq len der-byte)
        (let ((fwd (- der-byte ?\x80)))
         (setq len (byte-to-num (seq-take spki-bin-string fwd)))
         (setq spki-bin-string (seq-drop spki-bin-string fwd))))
      ;; next len bytes are the actual number
      (setq result-e (seq-take spki-bin-string len))
      (setq spki-bin-string (seq-drop spki-bin-string len)))
    ;; get e
    `(:n ,(jwt--byte-string-to-hex result-n) :e ,(jwt--byte-string-to-hex result-e))))

(defun read-ignore (n str)
  (let ((x (pop str)))
    (unless (= x n)
      (error "Expected %s got %s in %s" n x str)))
  str)

(defun read-len-take (str)
  (let ((len (pop str)))
    (cons (seq-take str len) (seq-drop str len))))

(defun jwt--extract-digest-from-pkcs1-hash (input)
  "Return hash digest (as hex) from INPUT (hex)."
  (let* ((input (string-remove-prefix "0001" input))
         (input (seq--into-list (jwt--hex-string-to-bytes input)))
         (input (seq-drop-while (lambda (x) (= ?\xFF x)) input))
         (input (seq-drop-while (lambda (x) (= ?\x0 x)) input))
         ;; encoded digest begins
         (input (read-ignore ?\x30 input))
         (input-and-rest (read-len-take input))
         (_ (unless (not (cdr input-and-rest)) (error "Expected rest to be empty")))
         (input (car input-and-rest))
         ;; identifier
         (input (read-ignore ?\x30 input))
         (input-and-rest (read-len-take input))
         (input (cdr input-and-rest))
         ;; ;; null - this is included above
         ;; (input (read-ignore ?\x05 input))
         ;; ;; 00
         ;; (input (cdr input))
         (input (read-ignore ?\x04 input))
         (input-and-rest (read-len-take input)))
    (jwt--byte-string-to-hex (car input-and-rest))))

(defun jwt-emsa-pkcs1-hash (algorithm message em-len)
  "hash and encode"
  (let* ((hash (secure-hash algorithm message))
         (t nil)
         ;; 30 31
         ;;       30 0d ;; sequence 13
         ;;             06 09 ;; oid 9
         ;;                   60 86 48 01 65 03 04 02 01 ???
         ;;             05 00 ;; null
         ;;       04 20 ;; octet
         ;; DigestInfo ::= SEQUENCE {
         ;;   digestAlgorithm AlgorithmIdentifier,
         ;;   digest OCTET STRING
         ;; }
         (ps (make-string (- em-len (length t) 3) ?\xFF))
         (encoded (concat '(0 0) '(0 1) ps '(0 0) t)))
    encoded))

;; see https://datatracker.ietf.org/doc/html/rfc3447#section-8.2.2
(defun jwt-rsa-verify (public-key hash-algorithm object sig)
  "Check SIG of OBJECT using RSA PUBLIC-KEY and HASH-ALGORITHM.

PUBLIC-KEY must be a plist (:n modulus :e exponent).
HASH-ALGORITHM must be one of `sha256, `sha384, or `sha512.
OBJECT is a string, assumed to be encoded.
SIG is a base64url encoded string."
  (unless (seq-contains-p '(sha256 sha384 sha512)
                          hash-algorithm)
    (error "Unsupported hash algorithm %s" hash-algorithm))
  (let* ((sig-bytes (base64-decode-string sig 't))
         (sig (string-to-number (jwt--byte-string-to-hex sig-bytes) 16))
         (_ (unless (= (string-bytes sig-bytes) (/ (length (plist-get public-key :n)) 2))
              (error "Signature length does not match key length")))
         (n (string-to-number (plist-get public-key :n) 16))
         (e (string-to-number (plist-get public-key :e) 16))
         (hash (secure-hash hash-algorithm object)))

    (let* ((calc-display-working-message nil)
           (message-representative (math-pow-mod sig e n)) ;; this is EMSA-PKCS1 !!
           ;; FIXME probably don't need to convert from bytes here
           ;; TODO explain why this is always 256.. I think it's because the block length of SHA512 is less?
           (encoded-message (jwt--byte-string-to-hex (jwt--i2osp message-representative 256)))
           (_ (message "EM=%s" encoded-message))
           (digest (jwt--extract-digest-from-pkcs1-hash encoded-message)))
      ;; see https://datatracker.ietf.org/doc/html/rfc3447#section-9.2
      (equal digest hash))))

;; ECDSASHA256
;; ES256
;; ES384
;; ES512

;; also mentioned by Auth0h
;; RSAPSSSHA256
;; PS256
;; PS384
;; PS512

(cl-defstruct jwt-token-json
  "A JWT decoded into JSON strings."
  header
  payload
  signature)

(defun jwt-to-token-json (token)
  "Decode TOKEN as a `jwt-token-json' struct."
  (cl-destructuring-bind (jwt-header jwt-payload jwt-signature) (string-split token "\\.")
    (make-jwt-token-json
     :header (decode-coding-string (base64-decode-string jwt-header 't) 'utf-8)
     :payload (decode-coding-string (base64-decode-string jwt-payload 't) 'utf-8)
     :signature jwt-signature)))

(defun jwt--random-bytes (n)
  "Generate random byte string of N chars.

The result is a plain unibyte string, it is not base64 encoded."
  (let (chars)
    (dotimes (_ n)
      (push (cl-random 256) chars))
    (apply #'unibyte-string chars)))

(defun jwt-create (payload alg key &optional extra-headers)
  "Create a JWT with the given PAYLOAD."
  (let* ((jose-header `((alg . ,alg)
                        (typ . "JWT")
                        ,@extra-headers))
         (jose-header (encode-coding-string (json-serialize jose-header) 'utf-8))
         ;; TODO add claims?
         (jwt-payload (encode-coding-string (json-serialize payload) 'utf-8))
         (content (concat (base64url-encode-string jose-header 't) "." (base64url-encode-string jwt-payload 't)))
         (signature (jwt-hs256 content key))
         (signature (base64url-encode-string signature 't)))
    (concat content "." signature)))

(defun jwt-verify-signature (token key)
  "Check the signature in TOKEN using KEY."
  (let* ((token-json (jwt-to-token-json token))
         (parsed-header (json-parse-string (jwt-token-json-header token-json)))
         (alg (map-elt parsed-header "alg"))
         ;; TODO possibly a JWK in header
         ;; TODO retrieve key if x5c or x5u is given
         (token-parts (string-split token "\\."))
         (encoded-content (string-join (seq-take token-parts 2) "."))
         (sig (seq-elt token-parts 2)))
    (pcase alg
     ;; HMAC
     ("HS256"
      (equal
       sig
       (base64url-encode-string (jwt-hs256 encoded-content key) 't)))
     ("HS384"
      (equal
       sig
       (base64url-encode-string (jwt-hs384 encoded-content key) 't)))
     ("HS512"
      (equal
       sig
       (base64url-encode-string (jwt-hs512 encoded-content key) 't)))
     ;; RSA
     ("RS256"
      (jwt-rsa-verify (jwt-parse-spki-rsa key) 'sha256 encoded-content sig))
     ("RS384"
      (jwt-rsa-verify (jwt-parse-spki-rsa key) 'sha384 encoded-content sig))
     ("RS512"
      (jwt-rsa-verify (jwt-parse-spki-rsa key) 'sha512 encoded-content sig))
     (_ (error "Unkown JWT algorithm %s" alg)))))

(defun jwt-decode (token)
  "Decode TOKEN and display results in a buffer."
  (interactive "MToken: ")
  (cl-assert (stringp token) 't)
  (with-current-buffer (generate-new-buffer "*JWT contents*")
    (let ((token-json (jwt-to-token-json token)))
      (insert (format "{ \"_header\": %s, \"_payload\": %s, \"_signature\": \"%s\" }"
                      (jwt-token-json-header token-json)
                      (jwt-token-json-payload token-json)
                      (jwt-token-json-signature token-json)))
      (jsonc-mode) ;; TODO perhaps not included?
      (json-pretty-print-buffer)
      (pop-to-buffer (current-buffer)))))

(defun jwt-decode-at-point ()
  "Decode token at point and display results in a buffer."
  (interactive)
  (let* ((maybe-token (sexp-at-point))
         (maybe-token (if (symbolp maybe-token)
                          (symbol-name maybe-token)
                        (if (stringp maybe-token)
                            maybe-token
                          (error "Token must be a string"))))
         (maybe-token (string-trim maybe-token "\"" "\""))
         (maybe-token (string-trim maybe-token "'" "'")))
    (unless maybe-token
      (message "No token selected"))
    (jwt-decode maybe-token)))

(provide 'jwt)

;;; jwt.el ends here
