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

(require 'json)
(require 'cl-lib)
(require 'hmac-def)
(require 'calc-arith)

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
  "Encode number X as an X-LEN long list of bytes.

I2OSP = Int to Octal String Primitive.
See: https://datatracker.ietf.org/doc/html/rfc3447#section-4.1"
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
  (secure-hash 'sha256 (apply #'unibyte-string (string-to-list str)) nil nil 't))

(defun jwt-sha384 (str)
  "Apply SHA384 interpreting STR as a binary string and returning a binary string."
  (secure-hash 'sha384 (apply #'unibyte-string (string-to-list str)) nil nil 't))

(defun jwt-sha512 (str)
  "Apply SHA512 interpreting STR as a binary string and returning a binary string."
  (secure-hash 'sha512 (apply #'unibyte-string (string-to-list str)) nil nil 't))

(define-hmac-function jwt-hs256 jwt-sha256 64 32)

(define-hmac-function jwt-hs384 jwt-sha384 128 48)

(define-hmac-function jwt-hs512 jwt-sha512 128 64)

(defun jwt--os2ip (x)
  "Concat a list of bytes X and convert to number.

OS2IP = Octal String to Int Primitive.
See: https://datatracker.ietf.org/doc/html/rfc3447#section-4.1"
  (string-to-number
   (seq-mapcat (apply-partially #'format "%02x") x 'string)
   16))

(defun jwt-parse-rsa-key (rsa-key-string)
  "Extract RSA modulus and exponent from RSA-KEY-STRING.

This may be either SPKI formatted with prefix BEGIN PUBLIC KEY,
or RSA formatted with prefix BEGIN RSA PUBLIC KEY.

Result is a plist (:n modulus :e exponent)."
  (setq rsa-key-string (string-remove-prefix "-----BEGIN RSA PUBLIC KEY-----"
                                             (string-remove-suffix "-----END RSA PUBLIC KEY-----"
                                                                   (string-trim rsa-key-string))))
  (let* ((is-spki (string-prefix-p "-----BEGIN PUBLIC KEY-----" rsa-key-string))
         (rsa-key-string (string-trim rsa-key-string "-----BEGIN \\(RSA \\)?PUBLIC KEY-----" "-----END \\(RSA \\)?PUBLIC KEY-----"))
         (rsa-key-string (string-trim rsa-key-string))
         (bin-string (string-to-list (base64-decode-string rsa-key-string)))
         ;; drop 24 byte preamble if SPKI format
         (bin-string (if is-spki (seq-drop bin-string 24) bin-string))
         result-n
         result-e)
    ;; see https://en.wikipedia.org/wiki/X.690#DER_encoding
    ;; FIXME: rewrite in the style of extract-digest-from-...
    ;; SEQ LEN L
    (unless (equal (seq-first bin-string)
                   ?\x30)
      (error "Unexpected prefix, not SEQ"))
    (setq bin-string (cdr bin-string))
    ;; The len byte either literally codes the length of sequence or uses the next n bytes for the length
    (let* ((len-byte (car bin-string))
           (read-forward-bytes (if (> len-byte ?\x80) (- len-byte ?\x80) len-byte)))
      (setq bin-string (seq-drop bin-string (1+ read-forward-bytes))))
    ;; INT LEN L
    (unless (equal (seq-first bin-string)
                   ?\x02)
      (error "Unexpected prefix %s, not INT 1" (seq-first bin-string)))
    (setq bin-string (cdr bin-string))
    (let* ((der-byte (car bin-string))
           (_ (setq bin-string (cdr bin-string)))
           len)
      (if (> ?\x80 der-byte)
          (setq len der-byte)
        (let ((fwd (- der-byte ?\x80)))
         (setq len (jwt--os2ip (seq-take bin-string fwd)))
         (setq bin-string (seq-drop bin-string fwd))))
      ;; next len bytes are the actual number
      (setq result-n (seq-drop-while (lambda (x) (= 0 x)) (seq-take bin-string len)))
      (setq bin-string (seq-drop bin-string len)))
    ;; INT LEN L
    (unless (equal (seq-first bin-string)
                   ?\x02)
      (error "Unexpected prefix %s, not INT 2" (seq-first bin-string)))
    (setq bin-string (cdr bin-string))
    (let* ((der-byte (car bin-string))
           (_ (setq bin-string (cdr bin-string)))
           len)
      (if (> ?\x80 der-byte)
          (setq len der-byte)
        (let ((fwd (- der-byte ?\x80)))
         (setq len (jwt--os2ip (seq-take bin-string fwd)))
         (setq bin-string (seq-drop bin-string fwd))))
      ;; next len bytes are the actual number
      (setq result-e (seq-take bin-string len))
      (setq bin-string (seq-drop bin-string len)))
    ;; get e
    `(:n ,(jwt--byte-string-to-hex result-n) :e ,(jwt--byte-string-to-hex result-e))))

(defun jwt--asn-read-ignore (n str)
  "Helper for processing ASN byte string STR.

Skip the first byte of STR which should be N."
  (let ((x (pop str)))
    (unless (= x n)
      (error "Expected %s got %s in %s" n x str)))
  str)

(defun jwt--asn-read-len-take (str)
  "Helper for processing ASN byte string STR.

Read the first byte of STR and drop that many bytes from STR."
  (let ((len (pop str)))
    (cons (seq-take str len) (seq-drop str len))))

(defun jwt--extract-digest-from-pkcs1-hash (input)
  "Return hash digest (as hex) from INPUT (list of bytes)."
  (let* ((input (seq-drop input 2)) ;; always 00 01
         (input (seq-drop-while (lambda (x) (= ?\xFF x)) input))
         (input (seq-drop-while (lambda (x) (= ?\x0 x)) input))
         ;; encoded digest begins
         (input (jwt--asn-read-ignore ?\x30 input))
         (input-and-rest (jwt--asn-read-len-take input))
         (_ (unless (not (cdr input-and-rest)) (error "Expected rest to be empty")))
         (input (car input-and-rest))
         ;; identifier
         (input (jwt--asn-read-ignore ?\x30 input))
         (input-and-rest (jwt--asn-read-len-take input))
         (input (cdr input-and-rest))
         ;; ;; null - this is included above
         ;; (input (jwt--asn-read-ignore ?\x05 input))
         ;; ;; 00
         ;; (input (cdr input))
         (input (jwt--asn-read-ignore ?\x04 input))
         (input-and-rest (jwt--asn-read-len-take input)))
    (jwt--byte-string-to-hex (car input-and-rest))))

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
           ;; this is EMSA-PKCS1, so it has extra metadata wrapping the hash
           (message-representative (math-pow-mod sig e n))
           (encoded-message (jwt--i2osp message-representative 256))
           (digest (jwt--extract-digest-from-pkcs1-hash encoded-message)))
      ;; see https://datatracker.ietf.org/doc/html/rfc3447#section-9.2
      (equal digest hash))))

(cl-defstruct jwt-token-json
  "A JWT decoded into JSON strings."
  header
  payload
  signature)

(defun jwt-token-json-header-parsed (token)
  "Get the header slot of TOKEN as a Lisp object."
  (json-parse-string (jwt-token-json-header token)))

(defun jwt-token-json-payload-parsed (token)
  "Get the payload slot of TOKEN as a Lisp object."
  (json-parse-string (jwt-token-json-payload token)))

(defun jwt-to-token-json (token)
  "Decode TOKEN as a `jwt-token-json' struct."
  (condition-case err
   (cl-destructuring-bind (jwt-header jwt-payload jwt-signature) (string-split token "\\.")
     (make-jwt-token-json
      :header (decode-coding-string (base64-decode-string jwt-header 't) 'utf-8)
      :payload (decode-coding-string (base64-decode-string jwt-payload 't) 'utf-8)
      :signature jwt-signature))
   (wrong-number-of-arguments
    (error (format "Invalid JWT: %s\nexpected 3 parts" token)))
   (error
    (error (format "Invalid JWT: %s\nreason: %s" token (cdr err))))))

(defun jwt--random-bytes (n)
  "Generate random byte string of N chars.

The result is a plain unibyte string, it is not base64 encoded."
  (let (chars)
    (dotimes (_ n)
      (push (cl-random 256) chars))
    (apply #'unibyte-string chars)))

(defun jwt--normalize-string-or-token (string-or-token)
  "Given STRING-OR-TOKEN return as a `jwt-token-json struct."
  (if (jwt-token-json-p string-or-token)
      string-or-token
    (jwt-to-token-json string-or-token)))

(defun jwt-token-time-until-expiry (token &optional lifetime-seconds)
  "Seconds remaining before TOKEN expires.

Result is negative if TOKEN is already expired, positive if still valid,
and nil if expiry time could not be determined.

LIFETIME-SECONDS can be used if token lifetime is specified elsewhere."
  (let* ((token (jwt--normalize-string-or-token token))
         (jwt-payload (jwt-token-json-payload-parsed token))
         (jwt-iat (map-elt jwt-payload "iat"))
         (jwt-exp (map-elt jwt-payload "exp"))
         (time-seconds (time-convert (current-time) 'integer)))
    (cond
     (jwt-exp
      (- jwt-exp time-seconds))
     ((and jwt-iat lifetime-seconds)
      (- (+ jwt-iat lifetime-seconds) time-seconds)))))

(defun jwt-create (payload alg key &optional extra-headers set-iat)
  "Create a JWT with the given PAYLOAD.

Currently only supports signing with HMAC.

ALG must be a string, one of HS256, HS384, HS512.
KEY byte string for HMAC.
EXTRA-HEADERS optional alist of headers to append to the JOSE header.
SET-IAT if non-nil add an iat claim to the payload with current time."
  (let* ((jose-header `((alg . ,alg)
                        (typ . "JWT")
                        ,@extra-headers))
         (jose-header (encode-coding-string (json-serialize jose-header) 'utf-8))
         (payload (if set-iat
                      (cons `(iat . ,(time-convert (current-time) 'integer)) payload)
                    payload))
         (jwt-payload (encode-coding-string (json-serialize payload) 'utf-8))
         (content (concat (base64url-encode-string jose-header 't) "." (base64url-encode-string jwt-payload 't)))
         (signing-fn (pcase (upcase alg)
                       ("HS256" #'jwt-hs256)
                       ("HS384" #'jwt-hs384)
                       ("HS512" #'jwt-hs512)
                       (_ (error "JWT signing with %s is not supported" alg))))
         (signature (funcall signing-fn content key))
         (signature (base64url-encode-string signature 't)))
    (concat content "." signature)))

(defun jwt-verify-signature (token key)
  "Check the signature in TOKEN using KEY."
  (let* ((token-json (jwt--normalize-string-or-token token))
         (parsed-header (jwt-token-json-header-parsed token-json))
         (alg (upcase (map-elt parsed-header "alg")))
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
      (jwt-rsa-verify (jwt-parse-rsa-key key) 'sha256 encoded-content sig))
     ("RS384"
      (jwt-rsa-verify (jwt-parse-rsa-key key) 'sha384 encoded-content sig))
     ("RS512"
      (jwt-rsa-verify (jwt-parse-rsa-key key) 'sha512 encoded-content sig))
     (_ (error "Unkown JWT algorithm %s" alg)))))

(defun jwt-encoded-token-p (test-string)
  "True if TEST-STRING decodes to a JWT-like object.

Specifically it should have
- three base64url encoded parts
- a JOSE header
- a JSON payload with JWT claims
- a signature."
  (condition-case nil
      (progn
        (let* ((maybe-token (jwt-to-token-json test-string))
               (jose-header (jwt-token-json-header-parsed maybe-token))
               (payload (jwt-token-json-payload-parsed maybe-token)))
          (and
           ;; JOSE
           (or
            (equal (map-elt jose-header "typ") "JWT")
            (map-contains-key jose-header "alg"))
           ;; payload
           (or
            (map-contains-key payload "iat")
            (map-contains-key payload "exp")
            (map-contains-key payload "iss"))
           ;; signature
           (jwt-token-json-signature maybe-token))
          't))
    (error
     nil)))

(defvar jwt-local-token nil "Buffer token string when in a JWT buffer.")
(make-variable-buffer-local 'jwt-local-token)

;;;###autoload
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
      ;; (jsonc-mode) ;; not included -- is it worth including?
      (js-json-mode)
      (json-pretty-print-buffer)
      (setq jwt-local-token token
            buffer-read-only 't)
      (jwt-minor-mode)
      (pop-to-buffer (current-buffer)))))

;;;###autoload
(defun jwt-decode-at-point ()
  "Decode token at point and display results in a buffer."
  (interactive)
  ;; FIXME: depending on the mode sexp-at-point may miss parts of the token
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

(defun jwt-verify-current-token (key)
  "Verfiy the currently displayed token using KEY."
  (interactive "Mkey: ")
  (unless jwt-local-token
    (error "No token found to verify"))
  (unless (string-prefix-p "-----" key)
    (message "Assuming base64 encoded HMAC key")
    (setq key (base64-decode-string key)))
  (if (jwt-verify-signature jwt-local-token key)
      (message "Token signature OK")
    (message "Token signature INVALID")))

(defvar jwt--defined-claims-alist
  '(;; registered claim names
    (iss "Issuer" "Identifies principal that issued the JWT.")
    (sub "Subject" "Identifies the subject of the JWT.")
    (aud "Audience" "Identifies the recipients that the JWT is intended for. Each principal intended to process the JWT must identify itself with a value in the audience claim. If the principal processing the claim does not identify itself with a value in the aud claim when this claim is present, then the JWT must be rejected.")
    (exp "Expiration Time" "Identifies the expiration time on and after which the JWT must not be accepted for processing. The value must be a NumericDate: either an integer or decimal, representing seconds past 1970-01-01 00:00:00Z.")
    (nbf "Not Before" "Identifies the time on which the JWT will start to be accepted for processing. The value must be a NumericDate.")
    (iat "Issued at" "Identifies the time at which the JWT was issued. The value must be a NumericDate.")
    (jti "JWT ID" "Case-sensitive unique identifier of the token even among different issuers.")
    ;; header names
    (typ "Token type"	"If present, it must be set to a registered IANA Media Type.")
    (cty "Content type" "If nested signing or encryption is employed, it is recommended to set this to JWT; otherwise, omit this field.")
    (alg "Message authentication code algorithm" "The issuer can freely set an algorithm to verify the signature on the token.")
    (kid "Key ID" "A hint indicating which key the client used to generate the token signature. The server will match this value to a key on file in order to verify that the signature is valid and the token is authentic.")
    (x5c "x.509 Certificate Chain" "A certificate chain in RFC4945 format corresponding to the private key used to generate the token signature. The server will use this information to verify that the signature is valid and the token is authentic.")
    (x5u "x.509 Certificate Chain URL" "A URL where the server can retrieve a certificate chain corresponding to the private key used to generate the token signature. The server will retrieve and use this information to verify that the signature is authentic.")
    (crit "Critical" "A list of headers that must be understood by the server in order to accept the token as valid"))
  "Documentation strings for ElDoc.")

(defun jwt--eldoc (callback &rest _ignored)
  "Document defined claims with ElDoc CALLBACK."
  (when-let* ((maybe-claim (sexp-at-point))
              (maybe-doc (cdr (assoc maybe-claim jwt--defined-claims-alist)))
              (full-name (car maybe-doc))
              (doco (cadr maybe-doc)))
    (funcall callback doco :thing full-name)))

(define-minor-mode jwt-minor-mode
  "Display decoded contents of JWTs."
  :interactive nil
  :keymap (define-keymap
            "C-c C-c" #'jwt-verify-current-token)
  :lighter " JWT-decoded"
  (add-hook 'eldoc-documentation-functions #'jwt--eldoc nil t)
  (eldoc-mode))

(provide 'jwt)

;;; jwt.el ends here
