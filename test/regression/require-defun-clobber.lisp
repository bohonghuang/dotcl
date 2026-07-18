;;; require-mid-compile defun clobber regression.
;;;
;;; When a file does (eval-when (:compile-toplevel :load-toplevel) (require "lib"))
;;; then defuns in its own package, compile-file's ANSI 3.2.3.1 finally strip
;;; must NOT remove the require'd library's function bindings (Mechanism B),
;;; and cross-package call resolution must NOT alias the lib's function onto
;;; the user's same-named symbol (Mechanism A). Both packages' functions must
;;; remain distinct (eq NIL) and bound (fboundp T) after the fasl loads, even
;;; when the load-time require is skipped (module already in *modules*).

(defvar *rdc-dir* "test/regression/.tmp-rdc/")

(defun rdc-build-and-load ()
  (ensure-directories-exist *rdc-dir*)
  (let* ((lib-src (namestring (merge-pathnames "lib.lisp" (truename *rdc-dir*))))
         (usr-src (namestring (merge-pathnames "usr.lisp" (truename *rdc-dir*))))
         (usr-fasl (namestring (merge-pathnames "usr.fasl" (truename *rdc-dir*)))))
    ;; Library: defines rdc-lib:rdc-foo (same name as user's) and rdc-lib:rdc-bar.
    (with-open-file (s lib-src :direction :output
                           :if-exists :supersede :if-does-not-exist :create)
      (write-string
       "(defpackage #:rdc-lib (:use #:cl) (:export #:rdc-foo #:rdc-bar))
        (in-package #:rdc-lib)
        (defun rdc-foo () :lib-foo)
        (defun rdc-bar () :lib-bar)" s))
    ;; User file: require the library at compile-time AND load-time, then defun
    ;; rdc-foo (same name -> Mechanism A) and rdc-quux calling rdc-lib:rdc-bar
    ;; (different name -> Mechanism B).
    (with-open-file (s usr-src :direction :output
                           :if-exists :supersede :if-does-not-exist :create)
      (format s
       "(defpackage #:rdc-user (:use #:cl) (:export #:rdc-foo #:rdc-quux))
        (in-package #:rdc-user)
        (eval-when (:compile-toplevel :load-toplevel)
          (require \"rdc-lib\" #p\"~A\"))
        (defun rdc-foo () :user-foo)
        (defun rdc-quux () (rdc-lib:rdc-bar))" lib-src))
    ;; Compile the user file. The compile-time require loads the library,
    ;; setting rdc-lib function slots. Step 1 (re-snapshot after require)
    ;; preserves them through the finally strip.
    (compile-file usr-src :output-file usr-fasl :verbose nil :print nil)
    ;; Load the fasl. Its load-time require re-loads the library (module was
    ;; un-marked by compile-file's *modules* restore), re-establishing the lib
    ;; functions. Its defuns register the user's functions. We then verify
    ;; Mechanism A: the user's rdc-foo must NOT be aliased onto the lib's
    ;; rdc-foo (Step 2 disabled the cross-package cache), so calling the
    ;; user's rdc-foo returns :USER-FOO (not :LIB-FOO, no infinite recursion)
    ;; and the two function objects are distinct (not eq).
    (load usr-fasl :verbose nil :print nil)
    (let ((usr-foo (intern "RDC-FOO" :rdc-user))
          (lib-foo (intern "RDC-FOO" :rdc-lib))
          (usr-quux (intern "RDC-QUUX" :rdc-user)))
      (list (fboundp lib-foo)                       ; lib rdc-foo bound
            (fboundp (intern "RDC-BAR" :rdc-lib))   ; lib rdc-bar bound
            (fboundp usr-foo)                       ; user rdc-foo bound
            (fboundp usr-quux)                       ; user rdc-quux bound
            (eq (symbol-function usr-foo)
                (symbol-function lib-foo))          ; must be NIL (no aliasing)
            (funcall usr-foo)                        ; must be :USER-FOO
            (funcall usr-quux)))))                   ; must be :LIB-BAR (cross-pkg call)

;;; The core regression: after compile-file, the require'd lib's functions
;;; must NOT be stripped. This checks the strip directly (Step 1's effect).
(defun rdc-compile-strip-check ()
  (ensure-directories-exist *rdc-dir*)
  (let* ((lib-src (namestring (merge-pathnames "lib.lisp" (truename *rdc-dir*))))
         (usr-src (namestring (merge-pathnames "usr.lisp" (truename *rdc-dir*))))
         (usr-fasl (namestring (merge-pathnames "usr2.fasl" (truename *rdc-dir*)))))
    ;; Fresh library + user file (re-compile to get clean state).
    (with-open-file (s lib-src :direction :output
                           :if-exists :supersede :if-does-not-exist :create)
      (write-string
       "(defpackage #:rdc-lib2 (:use #:cl) (:export #:rdc-foo #:rdc-bar))
        (in-package #:rdc-lib2)
        (defun rdc-foo () :lib-foo)
        (defun rdc-bar () :lib-bar)" s))
    (with-open-file (s usr-src :direction :output
                           :if-exists :supersede :if-does-not-exist :create)
      (format s
       "(defpackage #:rdc-user2 (:use #:cl) (:export #:rdc-foo #:rdc-quux))
        (in-package #:rdc-user2)
        (eval-when (:compile-toplevel :load-toplevel)
          (require \"rdc-lib2\" #p\"~A\"))
        (defun rdc-foo () :user-foo)
        (defun rdc-quux () (rdc-lib2:rdc-bar))" lib-src))
    ;; Compile -- the require runs at compile-time, setting rdc-lib2 functions.
    ;; After compile-file returns, check if the strip removed them.
    (compile-file usr-src :output-file usr-fasl :verbose nil :print nil)
    (list (fboundp (intern "RDC-FOO" :rdc-lib2))     ; Step 1: must be T (not stripped)
          (fboundp (intern "RDC-BAR" :rdc-lib2)))))   ; Step 1: must be T (not stripped)

(deftest require-defun-clobber.lib-not-stripped
  ;; After compile-file, the require'd library's functions must survive the
  ;; ANSI 3.2.3.1 strip (Step 1: re-snapshot after require).
  (rdc-compile-strip-check)
  (t t))

(deftest require-defun-clobber.no-cross-package-alias
  ;; After loading the fasl, the user's same-named function must NOT be eq to
  ;; the lib's function (Step 2: no cross-package cache aliasing), and calling
  ;; it must return the user's own value (no infinite recursion). The user's
  ;; rdc-quux must successfully call the lib's rdc-bar (cross-package call
  ;; resolution still works without aliasing).
  (let ((results (rdc-build-and-load)))
    (list (nth 0 results)   ; rdc-lib:rdc-foo bound
          (nth 1 results)   ; rdc-lib:rdc-bar bound
          (nth 2 results)   ; rdc-user:rdc-foo bound
          (nth 3 results)   ; rdc-user:rdc-quux bound
          (nth 4 results)   ; eq usr-foo lib-foo -> NIL (no aliasing)
          (nth 5 results)   ; (rdc-user:rdc-foo) -> :USER-FOO
          (nth 6 results))) ; (rdc-user:rdc-quux) -> :LIB-BAR
  (t t t t nil :user-foo :lib-bar))
