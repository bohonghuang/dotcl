# Issue M1: SUBSEQ: not a sequence — binstruct tests fail on dotcl

## Summary

`asdf:test-system :binstruct` fails on dotcl with `SUBSEQ: not a sequence`
on 9/26 tests in `BINSTRUCT.TEST::SUITE`, while passing on SBCL, CCL, and other CL
implementations.

## Root Cause

The root cause is a **cross-package variable name collision** in dotcl's
free-variable detection and local lookup.

### Background: The `&aux` pattern in parsonic/binstruct

The parsonic library uses a pattern where a `defconstant` defines an input-type
constant whose VALUE is a symbol that becomes the name of an `&aux` variable in a
compiled parser:

```lisp
;; parsonic/src/compile/input.lisp
(defconstant +input-type-simple-array-unsigned-byte-8+
  (intern (princ-to-string '(simple-array (unsigned-byte 8) (*))) #.*package*))
;; Value: PARSONIC::|(SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*))|

;; parsonic/src/compile/macro.lisp — parser/compile macro
(lambda (arg &aux (,(intern (princ-to-string input) #.*package*) arg))
  ;; The &aux variable is named |(SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*))|
  ;; and holds the input array
  ...)

;; binstruct/src/type/array/reader-optimize.lisp
(defconstant +input-type-simple-array-unsigned-byte-8+
  (intern (princ-to-string '(simple-array (unsigned-byte 8) (*)))))
;; Value: BINSTRUCT::|(SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*))|

(defmethod input-read-sequence/compile
    ((input (eql +input-type-simple-array-unsigned-byte-8+)) length)
  `(locally (declare (type (simple-array ...) ,input))
     (let ((index 0) (length (length ,input)))
       (subseq ,input ,*input-index* ,index) ...)))
  ;; ,input = PARSONIC::|(SIMPLE-ARRAY...)| (the array, from &aux)
  ;; length = BINSTRUCT::|(SIMPLE-ARRAY...)| (the let binding)
```

### The bug

Three symbols with the same printed name `|(SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*))|`
exist in different packages:
- `PARSONIC::|(SIMPLE-ARRAY...)|` — the `&aux` variable (the input array)
- `BINSTRUCT::|(SIMPLE-ARRAY...)|` — the `let` binding (the array length)
- `DOTCL.CIL-COMPILER::|(SIMPLE-ARRAY...)|` — interned free var (closure env-local)

The compiler's `var-name` function returns the bare `symbol-name` for all interned
symbols, so all three have the same `var-name` string. This caused three collision
points:

1. **`bnd` member checks** (`find-free-vars-expr`): The `let` binding
   `BINSTRUCT::|(SIMPLE-ARRAY...)|` was added to `inner-bound` as a `var-name`
   string. When `PARSONIC::|(SIMPLE-ARRAY...)|` was referenced inside the `let`
   body, the `member` check with `string=` matched the `BINSTRUCT` entry, treating
   the `PARSONIC` var as bound by the `let` (it wasn't — different variable).

2. **`local-bound-p`**: The non-package-aware `var-name` fallback matched
   `PARSONIC::|(SIMPLE-ARRAY...)|` against `BINSTRUCT::|(SIMPLE-ARRAY...)|` in
   `*locals*`, suppressing free-var detection. The var was not captured in the
   closure environment.

3. **`lookup-local`**: At runtime, the non-package-aware `var-name` fallback
   matched `PARSONIC::|(SIMPLE-ARRAY...)|` against `BINSTRUCT::|(SIMPLE-ARRAY...)|`
   in `*locals*`, returning the length (Fixnum) instead of the array. `subseq`
   received a Fixnum → "SUBSEQ: not a sequence".

## Fix

Made the compiler's variable lookup and free-var detection package-aware:

### `compiler/cil-compiler.lisp`

1. **`same-var-package-p`** (new helper): Returns `(var-name k)` if `k`'s package is
   compatible for lookup matching: same package, `DOTCL.CIL-COMPILER` (closure
   env-locals), or uninterned (gensyms). nil otherwise.

2. **`lookup-local`** (package-aware): The `var-name` fallback now uses
   `same-var-package-p`, only matching entries from compatible packages.

3. **`local-bound-p`** (package-aware): Same `same-var-package-p` logic in its
   `var-name` fallback. Prevents a `PARSONIC` reference from matching a `BINSTRUCT`
   binding with the same printed name.

4. **`bnd-member-p`** (new helper): Checks `bnd` (the free-var bound-names list)
   using `eq` for symbol entries (package-aware) and `string=` for string entries.
   This lets the `let`/`let*` handler store binding symbols instead of `var-name`
   strings.

### `compiler/cil-analysis.lisp`

5. **`let`/`let*` handler**: Stores the binding SYMBOL (not `var-name` string) in
   `inner-bound`, enabling `eq`-based package-aware matching via `bnd-member-p`.

6. **`member` checks**: Lines 92, 99, 171 now use `bnd-member-p` instead of
   `(member (var-name e) bnd :test #'string=)`.

7. **`free-ht` values store symbols**: `%compute-free-candidates` returns symbols
   (the `free-ht` values) instead of `var-name` strings (the keys). This gives the
   free-var candidate merge access to the actual symbol for package-aware
   `local-bound-p`.

8. **Free-var candidate merge**: Uses `local-bound-p` with the symbol (package-aware)
   instead of `local-bound-name-p` with a name string.

## Verification

### binstruct test suite

- **Before fix**: 84 passed, 20 failed (19 SUBSEQ errors + 1 FLOAT)
- **After fix**: 103 passed, 1 failed (pre-existing FLOAT "Implementation not
  supported" — unrelated to this fix)

All SUBSEQ errors eliminated. The single remaining failure is a pre-existing
single-float/double-float support issue in binstruct's FLOAT test.

## Files Changed

- `compiler/cil-compiler.lisp`:
  - Added `same-var-package-p` helper (~10 lines)
  - Made `lookup-local` package-aware (~6 lines changed)
  - Made `local-bound-p` package-aware (~8 lines changed)
  - Added `bnd-member-p` helper (~12 lines)

- `compiler/cil-analysis.lisp`:
  - `let`/`let*` handler stores symbols in `inner-bound` (2 lines changed)
  - `member` checks use `bnd-member-p` (3 lines changed)
  - `free-ht` values store symbols instead of `t` (7 lines changed)
  - Free-var candidate merge uses `local-bound-p` with symbol (4 lines changed)

## Key Insights

1. **`var-name` returns bare `symbol-name`** — this is correct for most cases but
   loses package information, causing collisions for symbols with the same printed
   name in different packages.

2. **The collision only affects symbols with special-character names** like
   `|(SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*))|` — these are created by `intern` with
   `princ-to-string` of type specifiers. Regular symbols rarely collide across
   packages because they're typically short and unique.

3. **`DOTCL.CIL-COMPILER` is always compatible** — closure env-locals are interned
   in `DOTCL.CIL-COMPILER`, so `same-var-package-p` always matches them. This is
   correct: the closure env captures the free var regardless of the original
   package.

4. **Uninterned symbols (gensyms) are always compatible** — they have no package,
   so `same-var-package-p` matches them. This is correct: gensyms are unique by
   identity (`eq`), so the `var-name` fallback is safe.

5. **`*ffv-assume-bound*` disables `local-bound-p`** — under `*ffv-assume-bound* = t`,
   `local-bound-p` returns true for everything. The real filtering happens in the
   free-var candidate merge, which re-applies `local-bound-p` with
   `*ffv-assume-bound* = nil`.
