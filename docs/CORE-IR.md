# Skein Core IR

**Status:** Draft, written in M0.3. The expander (`skein.expander`) produces Core IR; backends (`skein.backend.cl` in Phase 0, the C backend in Phase 1) consume it. The node structs live in `host/src/ir/ir.lisp` (package `skein.ir`).

Core IR is the small language left after macro expansion: only the special forms of DESIGN §5.1, with every name resolved.

- **Every node carries a source location** (`node-location`), copied from the syntax object it came from, so later passes and the runtime can report `file:line:col`.
- **Locals are alpha-renamed.** Each binding creates a fresh `local` object, and every reference points at that object. Two locals that share a name never share an object, so passes never need to think about shadowing.
- **Globals are resolved.** A reference to a global is a `var-ref` holding the runtime var itself, not a name.
- **Phase 0 Core IR is a tree, not ANF** (D-030). Arguments may be arbitrary nodes. An ANF pass that names every intermediate value is added before the C backend in Phase 1, where it pays for itself.

## Locals

| Struct | Fields | Notes |
|---|---|---|
| `local` | `name`, `id`, `mutable-p` | `name` is the source name, for messages and debugging. `id` is unique within the image. `mutable-p` is true for bindings declared `^:mutable`, the only locals `set!` may assign. |
| `block-tag` | `name`, `id` | The target of `return-from*`. Block tags live in their own namespace, separate from locals. |

## Nodes

All nodes include `location`. "Body" fields hold one node; a multi-form body becomes a `do` node.

| Node | Fields | Source form | Meaning |
|---|---|---|---|
| `const-node` | `value` | literals, `(quote x)`, `()` | a constant value. Quoting a collection builds it at compile time (metadata is dropped). A vector, map or set literal whose elements are all constants is built at compile time too; otherwise it becomes a `call-node` to `skein.core/vector`, `%map-literal` or `%set-literal` |
| `local-ref-node` | `local` | `x` | read a local |
| `var-ref-node` | `var` | `x`, `ns/x` | read a var's current value; an error if it is unbound |
| `if-node` | `test`, `then`, `else` | `(if test then else?)` | `else` defaults to a `nil` constant. Only `nil` and `false` are falsy |
| `do-node` | `forms` | `(do e1 e2 ...)` | evaluate in order, return the last. `(do)` becomes a `nil` constant |
| `def-node` | `var`, `init` | `(def name value?)` | set the var's root value to `init` (if present) and return the var. The var is interned when the form is expanded, so the body can refer to it |
| `fn-node` | `name`, `self`, `arities` | `(fn name? ...)` | a closure. `self` is the local bound to the function itself when the form has a name, else `nil` |
| `arity` | `params`, `rest`, `body`, `recur-p` | one `([params] body...)` | `params` is a list of locals; `rest` is the local after `&`, or `nil`. `recur-p` is true if some `recur` targets this arity |
| `let-node` | `bindings`, `body` | `(let* [x 1 y 2] ...)` | sequential binding; `bindings` is a list of `(local . init-node)` |
| `letfn-node` | `bindings`, `body` | `(letfn* [(f [..] ..)] ...)` | every local is in scope in every function; `bindings` is a list of `(local . fn-node)` |
| `loop-node` | `bindings`, `body`, `recur-p` | `(loop* [x 0] ...)` | like `let-node`, and a target for `recur` |
| `recur-node` | `target`, `args` | `(recur ...)` | jump to the innermost `loop-node` or `arity`, rebinding its locals. Always in tail position. For a variadic arity, the last argument is the rest value itself |
| `set-node` | `local`, `value` | `(set! x v)` | assign a `^:mutable` local |
| `call-node` | `fn`, `args` | `(f a b)` | evaluate `fn`, then `args` left to right, then call. Functions are called directly; keywords look themselves up in their argument; anything else is an error |
| `unwind-protect-node` | `body`, `cleanup` | `(unwind-protect body cleanup...)` | run `cleanup` however `body` exits |
| `block-node` | `tag`, `body` | `(block* tag body...)` | establish a lexical exit point |
| `return-from-node` | `tag`, `value` | `(return-from* tag v)` | leave the block with `value` |
| `values-node` | `args` | `(values a b ...)` | return multiple values |
| `let-values-node` | `bindings`, `body` | `(let-values* [[a b] expr] ...)` | `bindings` is a list of `(locals . init-node)`; missing values are `nil`, extra ones are dropped |
| `the-node` | `type`, `expr` | `(the type expr)` | a type assertion. `type` is the type's syntax. Phase 0 evaluates `expr` and does not check yet (M0.8) |

## Not in the IR yet

| Form | Milestone |
|---|---|
| `(declare ...)` | Accepted at the start of bodies and ignored until M0.8 adds declarations. |
| `throw-condition`, `handler-bind*`, `restart-bind*` | M0.6 (conditions and restarts) |
| `%ffi-call` | M0.10 (FFI) |
| `set!` of a dynamic var binding or an `:unsynchronized` cell | Dynamic binding (M0.5 or later) and `defclass` cells (M0.7) |

The expander reports a compile error with the source location if one of these forms is used before its milestone.

## Rules the expander enforces

- `recur` must be in tail position of the innermost `loop*` or `fn` arity, with exactly as many arguments as that target binds. Tail position does not extend into `unwind-protect`, binding initializers, call arguments or a nested `fn`.
- A `fn` may have at most one variadic arity, no two fixed arities with the same number of parameters, and no fixed arity with more parameters than the variadic one.
- A special-form name in operator position always means the special form, even if a local has the same name (as in Clojure).
- An unresolvable symbol is a compile error, not a runtime error.
