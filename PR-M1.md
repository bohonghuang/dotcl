# PR-M1: Fix cross-package variable name collision in free-var detection

## Problem

`asdf:test-system :binstruct` fails on dotcl with `SUBSEQ: not a sequence` on 19/26 tests, while passing on SBCL and CCL.

## Root Cause

dotcl's compiler uses `var-name` (bare `symbol-name`) as the matching key for variable lookup and free-var detection. When two packages intern symbols with the same printed name — e.g. `PARSONIC::|(SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*))|` (the input array, an `&aux` var) and `BINSTRUCT::|(SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*))|` (the array length, a `let` binding) — the compiler cannot distinguish them. A reference to the `PARSONIC` symbol inside the `let` body matches the `BINSTRUCT` binding, returning the length (a `Fixnum`) instead of the array. `subseq` receives a `Fixnum` → "not a sequence".

Three collision points:
1. **`lookup-local`** — `var-name` string fallback matched cross-package, returning the wrong local at runtime.
2. **`local-bound-p`** — `var-name` string fallback matched cross-package, suppressing free-var capture.
3. **`bnd` member checks** in `find-free-vars-expr` — `let` bindings stored as `var-name` strings; `string=` matched across packages, suppressing free-var detection.

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

## Fix — Justification for Each Change

### Why not just use `eq` for symbol identity comparison?

The `*locals*` alist keys are symbols, but they are NOT always the same `eq` identity as the source-code reference symbol:

1. **Closure env-locals** (`compile-closure-body` line 3054): when a free var is captured, the env-local is interned in `DOTCL.CIL-COMPILER` — `(intern fv :dotcl.cil-compiler)` — but the reference inside the closure body uses the ORIGINAL source symbol (e.g. `PARSONIC::|...|`). These are `eq`-unequal but have the same `var-name`.
2. **Uninterned gensyms**: source code may use `#:G123`, while `*locals*` holds an interned version with the same effective name. Pure `eq` fails here too.

**Verified empirically**: removing the string fallback entirely (pure `eq` in `lookup-local`/`local-bound-p`) breaks the build with `Unbound variable: #:PTR536` — an uninterned gensym that relies on the string fallback.

So the string fallback MUST stay, but it must not match across user packages. The fix restricts the fallback to "compatible" packages only.

### `compiler/cil-compiler.lisp`

**1. `same-var-package-p` (new helper)** — Returns `(var-name k)` if `k`'s package is compatible for lookup matching: same package as the reference, `DOTCL.CIL-COMPILER` (closure env-locals), or uninterned (gensyms). nil otherwise.

*Why*: This is the predicate that distinguishes "same variable, different symbol identity" (env-local, gensym — should match) from "different variable, same printed name" (cross-package collision — should NOT match). The three cases are exactly the ones the original string fallback was intended to serve; cross-package user symbols were an unintended false positive.

**2. `lookup-local` (package-aware fallback)** — The `var-name` string fallback now uses `same-var-package-p` as the `:key`, so it only matches entries from compatible packages.

*Why*: At runtime, a `PARSONIC::|...|` reference inside a closure must match the env-local `DOTCL.CIL-COMPILER::|...|` (compatible), but must NOT match a `BINSTRUCT::|...|` binding in `*locals*` (incompatible). Without this, `subseq` receives the length Fixnum instead of the array.

**3. `local-bound-p` (package-aware fallback)** — Same `same-var-package-p` logic in its `var-name` fallback.

*Why*: During free-var detection, a `PARSONIC::|...|` reference must be recognized as NOT bound by a `BINSTRUCT::|...|` `let` binding, so it gets captured as a free var. Without this, the var is suppressed and never enters the closure env.

**4. `bnd-member-p` (new helper)** — Checks `bnd` (the free-var bound-names list) using `eq` for symbol entries and `string=` for string entries only.

*Why*: `bnd` is hybrid — `extract-param-names` returns `var-name` strings (lambda params), but the `let`/`let*` handler now stores binding SYMBOLS (see below). A cross-package `eq` check on symbols prevents `BINSTRUCT::|...|` from matching `PARSONIC::|...|`; the `string=` fallback is kept for the string entries from `extract-param-names` (lambda params don't have the cross-package collision because they're the lambda's own params, same package as the reference).

### `compiler/cil-analysis.lisp`

**5. `let`/`let*` handler stores binding SYMBOLS in `inner-bound`** — Changed `(var-name (if (consp b) (car b) b))` to `(if (consp b) (car b) b)`.

*Why*: `inner-bound` feeds into `bnd` for nested forms. Storing the symbol (not the `var-name` string) lets `bnd-member-p` use `eq` to distinguish `BINSTRUCT::|...|` from `PARSONIC::|...|`. Storing strings would make them indistinguishable.

**6. `member` checks at lines 92, 99, 171 use `bnd-member-p`** — Replaced `(member (var-name e) bnd :test #'string=)`.

*Why*: The old `string=` check matched `PARSONIC::|...|` against the `BINSTRUCT::|...|` entry in `bnd`, treating the free var as bound by the `let` (it isn't — different variable). `bnd-member-p`'s `eq` check on the symbol entries prevents this.

**7. `free-ht` values store SYMBOLS instead of `t`** — Lines 102, 174, 203, 218, 227, 252, 264, 452 store the symbol `e`/`sym` or `(intern name :dotcl.cil-compiler)` as the value.

*Why*: `%compute-free-candidates` (line 525) returns the VALUES of `free-ht` — `(push v keys)`. These become the `sym` argument to the free-var candidate merge at line 170, which calls `(var-name sym)` and `(local-bound-p sym)`. Both require a SYMBOL, not `t`. If values are `t`, the merge calls `(var-name t)` which breaks. **Verified**: reverting values to `t` breaks the build with `Undefined function: COMPILE-TOPLEVEL-EVAL`.

**8. Free-var candidate merge uses `local-bound-p` with the symbol** — Line 170-174: `(dolist (sym (%lambda-free-candidates e)) ... (local-bound-p sym))` instead of `(dolist (name ...) ... (local-bound-name-p name))`.

*Why*: `%lambda-free-candidates` now returns symbols (change #7). The merge must re-check `local-bound-p` against the enclosing `*locals*` package-awarely — only `local-bound-p` (with a symbol) can do this; `local-bound-name-p` (with a string) cannot distinguish packages.

## Verification

### Minimal repro
- Before: `SUBSEQ: not a sequence`
- After: `PASS: subseq returned #(1)`

### binstruct test suite
- Before: **84 passed, 20 failed** (19 SUBSEQ + 1 FLOAT)
- After: **103 passed, 1 failed** (pre-existing FLOAT "Implementation not supported" — unrelated)

### Necessity of each change (empirically verified)
- Removing the string fallback entirely (pure `eq`): **build breaks** (`Unbound variable: #:PTR536`).
- Reverting `free-ht` values to `t`: **build breaks** (`Undefined function: COMPILE-TOPLEVEL-EVAL`).
- Keeping all changes: **build succeeds, repro passes, binstruct 103/1**.

## Files Changed

- `compiler/cil-compiler.lisp` (+43 lines): `same-var-package-p`, package-aware `lookup-local`/`local-bound-p`, `bnd-member-p`
- `compiler/cil-analysis.lisp` (+17/-17 lines): symbol-storing `let`/`let*` bindings, `bnd-member-p` checks, symbol-valued `free-ht`, symbol-based free-var merge
