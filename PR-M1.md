# PR-M1: Fix cross-package variable name collision in free-var detection

## Problem

`asdf:test-system :binstruct` fails on dotcl with `SUBSEQ: not a sequence` on 19/26 tests, while passing on SBCL and CCL.

## Root Cause

dotcl's compiler uses `var-name` (bare `symbol-name`) for variable lookup and free-var detection. When two packages intern symbols with the same printed name — e.g. `PARSONIC::|(SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*))|` (the input array, an `&aux` var) and `BINSTRUCT::|(SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*))|` (the array length, a `let` binding) — the compiler cannot distinguish them. A reference to the `PARSONIC` symbol inside the `let` body matches the `BINSTRUCT` binding in `*locals*`, returning the length (a `Fixnum`) instead of the array. `subseq` receives a `Fixnum` → "not a sequence".

Three collision points:
1. **`bnd` member checks** — `let` bindings stored as `var-name` strings; `string=` matched across packages, suppressing free-var capture.
2. **`local-bound-p`** — `var-name` fallback matched cross-package, suppressing free-var capture.
3. **`lookup-local`** — `var-name` fallback matched cross-package, returning the wrong local at runtime.

## Minimal Reproduction

```lisp
;; Two packages intern a symbol with the same symbol-name.
;; A lambda uses one as &aux, a nested lambda's let binds the other.
;; The nested lambda references the &aux var — it should capture
;; the &aux value (the array), not the let value (the length).

(defpackage :pkg-a (:use))
(defpackage :pkg-b (:use))

(defvar *sym-a* (intern "COLLIDE" :pkg-a))   ; PKG-A::COLLIDE
(defvar *sym-b* (intern "COLLIDE" :pkg-b))   ; PKG-B::COLLIDE

(let ((arg (gensym "ARG"))
      (dummy (gensym "DUMMY")))
  (let ((form
          `(lambda (,arg &aux (,*sym-a* ,arg))
             (let ((length (length ,*sym-a*)))
               (funcall
                (lambda (,dummy)
                  (let ((,*sym-b* length))
                    (subseq ,*sym-a* 0 1)))
                0)))))
    (let ((fn (compile nil form)))
      (let ((result (funcall fn #(1 2 3 4 5))))
        (if (equalp result #(1))
            (format t "PASS: subseq returned ~A~%" result)
            (format t "FAIL: subseq returned ~A (expected #(1))~%" result))))))
```

### Results

| Implementation | Output |
|---|---|
| SBCL | `PASS: subseq returned #(1)` |
| dotcl (before fix) | `SUBSEQ: not a sequence` |
| dotcl (after fix) | `PASS: subseq returned #(1)` |

## Fix

Made variable lookup and free-var detection package-aware in two files:

**`compiler/cil-compiler.lisp`**:
- `same-var-package-p` — new helper: returns `(var-name k)` if `k`'s package is compatible (same package, `DOTCL.CIL-COMPILER` for closure env-locals, or uninterned/gensym).
- `lookup-local` — `var-name` fallback now uses `same-var-package-p`.
- `local-bound-p` — same package-aware fallback.
- `bnd-member-p` — new helper: `eq` for symbol entries, `string=` for string entries only.

**`compiler/cil-analysis.lisp`**:
- `let`/`let*` handler stores binding symbols (not `var-name` strings) in `inner-bound`.
- `member` checks use `bnd-member-p` instead of `string=`.
- `free-ht` values store symbols; `%compute-free-candidates` returns symbols.
- Free-var candidate merge uses `local-bound-p` with the symbol (package-aware).

## Verification

### Minimal repro
- Before: `SUBSEQ: not a sequence`
- After: `PASS: subseq returned #(1)`

### binstruct test suite
- Before: **84 passed, 20 failed** (19 SUBSEQ + 1 FLOAT)
- After: **103 passed, 1 failed** (pre-existing FLOAT "Implementation not supported" — unrelated)

## Files Changed

- `compiler/cil-compiler.lisp` (+43 lines)
- `compiler/cil-analysis.lisp` (+17/-17 lines)
