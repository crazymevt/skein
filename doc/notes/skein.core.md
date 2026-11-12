`skein.core` is referred into every namespace: its vars need no `:require`. It holds the
language's macros (`defn`, `let`, `when`, `->`...), the persistent collections and
sequences, numbers, strings, printing, the object system (`defclass`, `defgeneric`),
structs and arrays, atoms, refs and tasks, channels, and conditions and restarts.

The special forms that the compiler understands itself (`if`, `do`, `def`, `fn`, `quote`,
`let*`, `loop*`, `recur`, `set!`, `var` and the rest) aren't vars; the
[language reference](../reference.html#5-special-forms-and-core-macros) describes them.

## *1
### Arguments and values
The value of the last expression evaluated at the REPL.

See also: *2, *3, *e

## *2
### Arguments and values
The value of the expression before the last, at the REPL.

See also: *1, *3

## *3
### Arguments and values
The value of the third expression back, at the REPL.

See also: *1, *2

## *e
### Arguments and values
The last condition signaled at the REPL that reached it unhandled.

See also: *1, condition-message

## *print-length*
### Arguments and values
A dynamic var: nil (the default) or a non-negative integer.

See also: binding, pr-str

## defn
### Arguments and values
- `name`: a symbol, the var to define.
- `docstring`: an optional string.
- `params`: a vector of parameters, which may destructure (DESIGN §5.4); `& rest` takes
  the remaining arguments as a seq.
- `body`: the expressions to evaluate; the last one's value is returned.
- Several arities are written as `([params] body...)` lists.
- Returns the var.

### Notes
The form is `(defn name docstring? [params] body...)`, or with several arities
`(defn name docstring? ([params] body...)...)`. Metadata such as `^:private` goes before
the name.

See also: defn-, fn, defmacro, defonce

## defn-
### Arguments and values
As `defn`'s.

See also: defn

## defmacro
### Arguments and values
- `name`: a symbol.
- `docstring`: optional.
- `params`: a vector; the macro's arguments are its forms, unevaluated.
- `body`: returns the code to evaluate instead of the call, usually built with
  syntax-quote (`` ` ``), `~` and `~@`.

### Notes
Syntax-quote resolves symbols to the namespace the macro is defined in, so a macro's
expansion means the same wherever it is used; `name#` makes a fresh symbol for a local
(DESIGN §11.1).

See also: macroexpand-1, macroexpand, gensym, defn

## defonce
### Arguments and values
- `var-name`: a symbol.
- `expr`: evaluated only if the var has no value.

See also: def, reload

## declaim
### Arguments and values
- `specs`: declarations, such as `(ftype (fn [arg-types] return-type) name...)` and
  `(optimize (speed 3) (safety 0))` (DESIGN §12.2).
- Returns nil.

See also: defn

## ns
### Arguments and values
- `name`: the namespace's name, a symbol; the file's path mirrors it.
- `docstring`: optional.
- `(:require [ns :as alias :refer [names]]...)`: the namespaces this one uses.

See also: in-ns, reload

## in-ns
### Arguments and values
- `name`: a quoted symbol.
- Returns the namespace, now the current one.

See also: ns

## load-file
### Arguments and values
- `path`: a file's path.
- Returns the value of its last form.

See also: eval, reload

## reload
### Arguments and values
- `ns`: a namespace's name, a symbol or string.

See also: load-file, defonce

## eval
### Arguments and values
- `form`: data: a list is a call, a symbol a var or local, and the rest evaluate to
  themselves.
- Returns the form's value.

### Notes
Only in programs built with `--eval` (`./skein run` and `skein dev` build so).

See also: read-string, macroexpand, load-file

## read-string
### Arguments and values
- `s`: a string of Skein source.
- Returns the first form, as data.

### Notes
`skein.edn/read-string` reads data in every build.

See also: eval, skein.edn/read-string, pr-str

## macroexpand-1
### Arguments and values
- `form`: data.
- Returns the form expanded once, or the form itself if it isn't a macro call.

See also: macroexpand, macroexpand-all, defmacro

## macroexpand
### Arguments and values
- `form`: data.
- Returns the form, expanded until its head isn't a macro.

See also: macroexpand-1, macroexpand-all

## macroexpand-all
### Arguments and values
- `form`: data.
- Returns the form with every macro call in it expanded.

See also: macroexpand

## comment
### Arguments and values
- `body`: any forms, which aren't evaluated (they must read).
- Returns nil.

See also: do

## when
### Arguments and values
- `test`: any expression.
- `body`: evaluated if `test` is true.
- Returns the body's last value, or nil.

See also: when-not, if, when-let, cond

## when-not
### Arguments and values
As `when`'s.

See also: when, if-not

## if-not
### Arguments and values
- `test`: any expression.
- `then`: evaluated if `test` is false.
- `else`: evaluated otherwise; nil if not given.

See also: if, when-not

## if-let
### Arguments and values
- `bindings`: a vector of one pattern and a test, `[x test]`.
- `then`: evaluated with the pattern bound, if the test's value is true.
- `else`: evaluated otherwise, without the binding; nil if not given.

See also: when-let, if-some, let

## when-let
### Arguments and values
- `bindings`: `[x test]`.
- `body`: evaluated with `x` bound, if the test's value is true.

See also: if-let, when-some, when-first

## if-some
### Arguments and values
As `if-let`'s; the test passes for any value but nil.

See also: if-let, when-some

## when-some
### Arguments and values
As `when-let`'s; the test passes for any value but nil.

See also: when-let, if-some

## when-first
### Arguments and values
- `[x coll]`: a name and a collection.
- `body`: evaluated with `x` bound to the first element, if `coll` isn't empty.

See also: when-let, first

## cond
### Arguments and values
- `clauses`: test and expression pairs.
- Returns the value of the expression after the first true test, or nil.

See also: condp, case, if, cond->

## condp
### Arguments and values
- `pred`: a function of two arguments.
- `expr`: the value each test is given to `pred` with.
- `clauses`: test and result pairs, or `test :>> f`, which calls `f` with what `pred`
  returned; a final single expression is the default.

See also: cond, case

## case
### Arguments and values
- `e`: the value to compare.
- `clauses`: a constant, or a list of constants, and an expression; the constants aren't
  evaluated.
- A final odd expression is the default.

### Notes
The constants are compared with `=`; a list of them matches any one, so to match a list
itself put it in another.

See also: cond, condp

## and
### Arguments and values
- Any expressions; evaluation stops at the first falsy one.
- Returns that value, the last value, or true with none.

See also: or, every?

## or
### Arguments and values
- Any expressions; evaluation stops at the first truthy one.
- Returns that value, the last value, or nil with none.

See also: and, some

## not
### Arguments and values
- `x`: any value.
- Returns true if `x` is nil or false, else false.

See also: complement, boolean

## let
### Arguments and values
- `bindings`: a vector of patterns and expressions, bound in order, each seeing the ones
  before; patterns destructure vectors (`[a b & more]`) and maps (`{:keys [a b]}`).
- `body`: evaluated with the bindings.

See also: letfn, binding, if-let, destructure

## letfn
### Arguments and values
- `fnspecs`: `[(name [params] body...)...]`, functions that can call each other.
- `body`: evaluated with them bound.

See also: let, fn

## binding
### Arguments and values
- `bindings`: a vector of `^:dynamic` vars and values.
- `body`: evaluated with the vars rebound, in this fiber and the tasks it spawns.

See also: let, def

## destructure
### Arguments and values
- `bindings`: a binding vector, as `let` takes.
- Returns a binding vector of plain symbols, for macros that bind names.

See also: let, defmacro

## loop
### Arguments and values
- `bindings`: as `let`'s; the starting values.
- `body`: in tail position, `(recur new-values...)` starts it again.

See also: recur, dotimes, doseq, reduce

## doseq
### Arguments and values
- `seq-exprs`: `[name coll ...]`, with `:let [...]`, `:when test` and `:while test`.
- `body`: evaluated for each binding, for its effects.
- Returns nil.

See also: for, run!, dotimes

## dotimes
### Arguments and values
- `bindings`: `[name n]`.
- `body`: evaluated with `name` from 0 to n - 1.
- Returns nil.

See also: doseq, pdotimes, loop

## while
### Arguments and values
- `test`: evaluated before each pass.
- `body`: evaluated while `test` is true.
- Returns nil.

See also: loop, doseq

## for
### Arguments and values
- `seq-exprs`: `[name coll ...]`, with `:let`, `:when` and `:while`; later bindings vary
  fastest.
- `body`: the value for each binding.
- Returns a lazy seq.

See also: doseq, map, mapcat

## run!
### Arguments and values
- `f`: a function of one argument.
- `coll`: a collection.
- Returns nil.

See also: doseq, map

## trampoline
### Arguments and values
- `f`: a function, called with `args`.
- Returns the first result that isn't a function.

See also: loop, letfn

## ->
### Arguments and values
- `x`: the starting value.
- `forms`: each a call (the value goes in as its first argument) or a symbol or keyword
  (called with the value).

See also: ->>, as->, some->, cond->, doto

## ->>
### Arguments and values
As `->`'s; the value goes in as each call's last argument.

See also: ->, some->>, cond->>

## as->
### Arguments and values
- `expr`: the starting value.
- `name`: a symbol bound to the value in each form.
- `forms`: the steps; each one's value is the next one's `name`.

See also: ->, ->>

## some->
### Arguments and values
As `->`'s; returns nil as soon as a step gives nil.

See also: ->, some->>, when-let

## some->>
### Arguments and values
As `->>`'s; returns nil as soon as a step gives nil.

See also: ->>, some->

## cond->
### Arguments and values
- `expr`: the starting value.
- `clauses`: test and form pairs; the value goes through each form whose test is true.

See also: cond->>, ->, cond

## cond->>
### Arguments and values
As `cond->`'s, threading as `->>`.

See also: cond->, ->>

## doto
### Arguments and values
- `x`: a value, usually mutable.
- `forms`: calls, each given `x` as the first argument.
- Returns `x`.

See also: ->

## time
### Arguments and values
- `expr`: evaluated once.
- Returns its value; prints the time it took.

See also: skein.time/now

## +
### Arguments and values
- `x`, `y`, `more`: numbers.
- Returns their sum: an integer if all are integers (a bignum if it needs one), else a float.

See also: -, *, inc

## -
### Arguments and values
- `x`, `y`, `more`: numbers.
- Returns `x` negated with one argument, else `x` minus the rest.

See also: +, dec, abs

## *
### Arguments and values
- `x`, `y`, `more`: numbers.
- Returns their product.

See also: +, /

## /
### Arguments and values
- `x`: the dividend, a number.
- `y`: the divisor, a number; zero is an `arithmetic-error`.
- Returns a float.

### Notes
Skein has no ratios: `/` always gives a float, and `quot` divides integers.

See also: quot, rem, mod

## inc
### Arguments and values
- `x`: a number.
- Returns `x` + 1.

See also: dec, +

## dec
### Arguments and values
- `x`: a number.
- Returns `x` - 1.

See also: inc, -

## quot
### Arguments and values
- `n`: the dividend, an integer.
- `d`: the divisor, a non-zero integer.
- Returns the quotient, rounded toward zero.

See also: rem, mod, /

## rem
### Arguments and values
- `n`, `d`: integers, `d` not zero.
- Returns the remainder of `(quot n d)`, with `n`'s sign.

See also: quot, mod

## mod
### Arguments and values
- `n`, `d`: numbers, `d` not zero.
- Returns `n` modulo `d`, with `d`'s sign: from 0 up to `d` for a positive `d`.

See also: rem, quot

## abs
### Arguments and values
- `x`: a number.
- Returns its absolute value, of the same kind.

See also: -, skein.math/sign

## max
### Arguments and values
- `x`, `more`: numbers.
- Returns the largest.

See also: min, max-key

## min
### Arguments and values
- `x`, `more`: numbers.
- Returns the smallest.

See also: max, min-key

## sqrt
### Arguments and values
- `x`: a number.
- Returns its square root, a float (NaN for a negative number).

See also: skein.math/pow

## =
### Arguments and values
- `x`, `y`, `more`: any values.
- Returns true if all are equal.

### Notes
Numbers are equal only to numbers of the same kind, so `(= 1 1.0)` is false; `==` compares them by value. Collections compare by their elements, so a vector and a list with the same elements are equal, and so are maps whatever their order.

See also: ==, not=, identical?, equiv

## ==
### Arguments and values
- `x`, `y`, `more`: numbers.
- Returns true if all are equal by value.

See also: =

## not=
### Arguments and values
- `x`, `y`, `more`: any values.
- Returns true unless all are equal.

See also: =

## <
### Arguments and values
- `x`, `y`, `more`: numbers.
- Returns true if they increase, left to right.

See also: compare, max, min

## <=
### Arguments and values
- `x`, `y`, `more`: numbers.
- Returns true if they never decrease, left to right.

See also: compare, max, min

## >
### Arguments and values
- `x`, `y`, `more`: numbers.
- Returns true if they decrease, left to right.

See also: compare, max, min

## >=
### Arguments and values
- `x`, `y`, `more`: numbers.
- Returns true if they never increase, left to right.

See also: compare, max, min

## compare
### Arguments and values
- `x`, `y`: values of the same kind: numbers, strings, characters, booleans, keywords, symbols or vectors; nil comes before everything.
- Returns -1, 0 or 1.

See also: sort, sort-by, sorted-map

## identical?
### Arguments and values
- `x`, `y`: any values.
- Returns true if they are the same object.

See also: =

## zero?
### Arguments and values
- `x`: a number.
- Returns true if it is zero.

See also: pos?, neg?

## pos?
### Arguments and values
- `x`: a number.
- Returns true if it is greater than zero.

See also: neg?, zero?

## neg?
### Arguments and values
- `x`: a number.
- Returns true if it is less than zero.

See also: pos?, zero?

## even?
### Arguments and values
- `n`: an integer.
- Returns true if it is even.

See also: odd?

## odd?
### Arguments and values
- `n`: an integer.
- Returns true if it is odd.

See also: even?

## number?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a number, else false.

See also: integer?, float?

## integer?
### Arguments and values
- `x`: any value.
- Returns true if `x` is an integer, a fixnum or a bignum, else false.

See also: int?, float?, number?

## int?
### Arguments and values
- `x`: any value.
- Returns true if `x` is an integer that fits in 64 bits, else false.

See also: integer?, pos-int?

## float?
### Arguments and values
- `x`: any value.
- Returns true if `x` is an f32 or an f64, else false.

See also: double?, integer?

## double?
### Arguments and values
- `x`: any value.
- Returns true if `x` is an f64, else false.

See also: float?, f64

## pos-int?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a positive `int?`, else false.

See also: int?, nat-int?

## neg-int?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a negative `int?`, else false.

See also: int?, pos-int?

## nat-int?
### Arguments and values
- `x`: any value.
- Returns true if `x` is zero or a positive `int?`, else false.

See also: int?, pos-int?

## int
### Arguments and values
- `x`: a number or a character.
- Returns an integer: the number truncated toward zero, or the character's code point.

See also: char, f64, skein.math/round

## f32
### Arguments and values
- `x`: a number.
- Returns it as an f32, a 32-bit float, which prints with an `f`.

See also: f64, float?

## f64
### Arguments and values
- `x`: a number.
- Returns it as an f64, a 64-bit float.

See also: f32, double?

## char
### Arguments and values
- `n`: a Unicode code point, an integer.
- Returns the character.

See also: int, char?

## parse-long
### Arguments and values
- `s`: a string.
- Returns the integer it writes, or nil if it writes something else.

See also: parse-double, parse-boolean, read-string

## parse-double
### Arguments and values
- `s`: a string.
- Returns the f64 it writes, or nil.

See also: parse-long

## parse-boolean
### Arguments and values
- `s`: a string.
- Returns true, false or nil.

See also: parse-long

## bit-and
### Arguments and values
- `x`, `y`, `more`: fixnums.
- Returns their bitwise and.

See also: bit-or, bit-xor, bit-not

## bit-or
### Arguments and values
- `x`, `y`, `more`: fixnums.
- Returns their bitwise or.

See also: bit-and, bit-xor, bit-not

## bit-xor
### Arguments and values
- `x`, `y`, `more`: fixnums.
- Returns their bitwise exclusive or.

See also: bit-and, bit-or, bit-not

## bit-not
### Arguments and values
- `x`: a fixnum.
- Returns its complement, `(- -1 x)`.

See also: bit-and, bit-xor

## bit-and-not
### Arguments and values
- `x`, `y`, `more`: fixnums.
- Returns `x` without the bits set in the others.

See also: bit-and, bit-clear

## bit-shift-left
### Arguments and values
- `x`: an integer.
- `n`: how many bits, a non-negative integer.
- Returns `x` times 2 to the `n`, a bignum past the fixnum range.

See also: bit-shift-right

## bit-shift-right
### Arguments and values
- `x`: an integer.
- `n`: how many bits.
- Returns `x` shifted right, the sign kept (an arithmetic shift).

See also: unsigned-bit-shift-right, bit-shift-left

## unsigned-bit-shift-right
### Arguments and values
- `x`: an integer, as 64 bits.
- `n`: how many bits.
- Returns it shifted right with zeros coming in.

See also: bit-shift-right

## bit-test
### Arguments and values
- `x`: an integer.
- `n`: a bit's index, 0 the lowest.
- Returns true if bit `n` is set.

See also: bit-set, bit-clear, bit-flip

## bit-set
### Arguments and values
- `x`: an integer.
- `n`: a bit's index, 0 the lowest.
- Returns `x` with bit `n` set.

See also: bit-test, bit-clear, bit-flip

## bit-clear
### Arguments and values
- `x`: an integer.
- `n`: a bit's index, 0 the lowest.
- Returns `x` with bit `n` cleared.

See also: bit-test, bit-set, bit-flip

## bit-flip
### Arguments and values
- `x`: an integer.
- `n`: a bit's index, 0 the lowest.
- Returns `x` with bit `n` flipped.

See also: bit-test, bit-set, bit-clear

## rand
### Arguments and values
- `n`: the upper bound, a number; 1 if not given.
- Returns a random f64 from 0 up to (not including) `n`.

See also: rand-int, rand-nth, skein.math/rand-range

## rand-int
### Arguments and values
- `n`: a positive integer.
- Returns a random integer from 0 to `n` - 1.

See also: rand, rand-nth

## rand-nth
### Arguments and values
- `coll`: a collection that isn't empty.
- Returns one of its elements at random.

See also: rand-int, shuffle

## shuffle
### Arguments and values
- `coll`: a collection.
- Returns a vector of its elements in a random order.

See also: rand-nth, sort

## random-uuid
### Arguments and values
- Returns a new random UUID as a string of 36 characters.

See also: rand, gensym

## str
### Arguments and values
- `xs`: any values.
- Returns a string: strings and characters as they are, nil as nothing, the rest as `print` writes them.

### Notes
To build a long string in a loop, `skein.string/builder` avoids making each intermediate string.

See also: pr-str, format, skein.string/join

## subs
### Arguments and values
- `s`: a string.
- `start`: an index.
- `end`: an index at or after `start`; the length if not given.
- Returns the characters between them.

See also: skein.string/slice, nth

## format
### Arguments and values
- `fmt`: a string with `%` directives: `%s`, `%d`, `%f`, `%x`, `%c`, `%b`, `%e`, `%%`, with flags, a width and a precision as Java's `String.format` has them.
- `args`: one value for each directive.
- Returns a string.

See also: str, println

## string?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a string, else false.

See also: char?, str

## char?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a character, else false.

See also: string?, char

## index-of
### Arguments and values
- `coll`: a sequential collection.
- `x`: the value to find.
- Returns its first index, or nil.

See also: skein.string/index-of, some

## re-pattern
### Arguments and values
- `s`: a regular expression in Java's syntax, or a pattern.
- Returns a pattern, as `#"..."` makes.

### Notes
In a string, a backslash must itself be escaped: `(re-pattern "\\d+")` is `#"\d+"`. Patterns support classes, groups (named too), alternation, the greedy, lazy and possessive quantifiers, anchors and look-around (D-105).

See also: re-find, re-seq, re-matches

## re-find
### Arguments and values
- `re`: a pattern, or a string, compiled.
- `s`: the string to search.
- `m`: a matcher, instead of both.
- Returns the match: a string if the pattern has no groups, else a vector of the match and each group (nil for a group that didn't take part); nil if none.

See also: re-matches, re-seq, re-matcher, skein.string/replace

## re-matches
### Arguments and values
- `re`: a pattern or string.
- `s`: a string.
- Returns the match (as `re-find` gives it) if the whole string matches, else nil.

See also: re-find

## re-seq
### Arguments and values
- `re`: a pattern or string.
- `s`: a string.
- Returns a lazy seq of the matches, as `re-find` gives them.

See also: re-find, skein.string/split

## re-matcher
### Arguments and values
- `re`: a pattern or string.
- `s`: a string.
- Returns a matcher, which `re-find` advances.

See also: re-find, re-groups

## re-groups
### Arguments and values
- `m`: a matcher that has found a match.
- Returns that match, as `re-find` gave it.

See also: re-matcher, re-find

## name
### Arguments and values
- `x`: a keyword, a symbol or a string.
- Returns its name, a string, without the namespace.

See also: namespace, keyword, symbol

## namespace
### Arguments and values
- `x`: a keyword or a symbol.
- Returns its namespace, a string, or nil.

See also: name

## keyword
### Arguments and values
- `ns`: a namespace's name, a string; none if not given.
- `name`: a string (or a keyword or symbol, whose name is used).
- Returns the keyword.

See also: keyword?, symbol, name

## keyword?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a keyword, else false.

See also: keyword, symbol?

## symbol
### Arguments and values
- `ns`: a namespace's name; none if not given.
- `name`: a string.
- Returns the symbol.

See also: symbol?, keyword, gensym

## symbol?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a symbol, else false.

See also: symbol, keyword?

## gensym
### Arguments and values
- `prefix`: a string; `G__` if not given.
- Returns a new symbol, unlike any other.

See also: defmacro, symbol

## pr
### Arguments and values
- `xs`: any values.
- Prints `xs` readably, as the reader reads them back, with spaces between, to `*out*`.
- Returns nil.

See also: prn, pr-str, print

## prn
### Arguments and values
- `xs`: any values.
- Prints `xs` as `pr` does, then a newline, to `*out*`.
- Returns nil.

See also: pr, println, prn-str

## print
### Arguments and values
- `xs`: any values.
- Prints `xs` for people: strings and characters without quotes, with spaces between, to `*out*`.
- Returns nil.

See also: println, pr, print-str

## println
### Arguments and values
- `xs`: any values.
- Prints `xs` as `print` does, then a newline, to `*out*`.
- Returns nil.

See also: print, prn, println-str

## pr-str
### Arguments and values
- `xs`: any values.
- Returns what `pr` would print, as a string.

See also: pr, with-out-str, str

## prn-str
### Arguments and values
- `xs`: any values.
- Returns what `prn` would print, as a string.

See also: prn, with-out-str, str

## print-str
### Arguments and values
- `xs`: any values.
- Returns what `print` would print, as a string.

See also: print, with-out-str, str

## println-str
### Arguments and values
- `xs`: any values.
- Returns what `println` would print, as a string.

See also: println, with-out-str, str

## with-out-str
### Arguments and values
- `body`: expressions, evaluated.
- Returns what they printed, as a string.

See also: print-str, println

## slurp
### Arguments and values
- `path`: a file's path.
- Returns its text, decoded as UTF-8.

See also: spit, skein.io/read-file, skein.io/line-seq

## spit
### Arguments and values
- `path`: a file's path.
- `x`: written as `str` writes it.
- `:append true`: add to the end instead of replacing the file.
- Returns nil.

See also: slurp, skein.io/write-file, skein.io/append-file

## list
### Arguments and values
- `xs`: any values.
- Returns a list of them.

See also: list*, vector, cons

## list*
### Arguments and values
- `args`: values, the last a collection.
- Returns a seq of the values followed by the collection's elements.

See also: cons, apply, list

## vector
### Arguments and values
- `xs`: any values.
- Returns a vector of them.

See also: vec, list, hash-map

## vec
### Arguments and values
- `coll`: a collection, or nil.
- Returns a vector of its elements.

See also: vector, into, set

## hash-map
### Arguments and values
- `kvs`: keys and values, in pairs.
- Returns a map.

### Notes
A map keeps its keys in the order they were added up to 8 keys, and in hash order beyond.

See also: zipmap, sorted-map, assoc

## hash-set
### Arguments and values
- `xs`: any values.
- Returns a set of them (repeats once).

See also: set, sorted-set, conj

## set
### Arguments and values
- `coll`: a collection, or nil.
- Returns a set of its elements.

See also: hash-set, distinct, vec

## sorted-map
### Arguments and values
- `kvs`: keys and values, in pairs; the keys comparable with `compare`.
- Returns a sorted map.

See also: sorted-map-by, subseq, rseq, hash-map

## sorted-map-by
### Arguments and values
- `comparator`: a function of two keys returning a negative, zero or positive number, or a boolean that is true when the first comes first.
- `kvs`: keys and values.
- Returns a sorted map.

See also: sorted-map, sorted-set-by

## sorted-set
### Arguments and values
- `xs`: values comparable with `compare`.
- Returns a sorted set.

See also: sorted-set-by, subseq, hash-set

## sorted-set-by
### Arguments and values
- `comparator`: as `sorted-map-by`'s.
- `xs`: the elements.
- Returns a sorted set.

See also: sorted-set, sorted-map-by

## zipmap
### Arguments and values
- `ks`: the keys.
- `vs`: the values, paired with the keys in order; the shorter decides.
- Returns a map.

See also: hash-map, interleave

## into
### Arguments and values
- `to`: a collection to add to; `[]` if not given.
- `xform`: an optional transducer.
- `from`: a collection whose elements are added with `conj`.
- Returns the new collection, of `to`'s kind.

See also: conj, vec, transduce

## empty
### Arguments and values
- `coll`: a collection, or nil.
- Returns an empty collection of the same kind, with the same metadata, or nil.

See also: empty?, not-empty

## count
### Arguments and values
- `coll`: a collection, or nil.
- Returns the number of elements: of characters in a string, entries in a map.

See also: empty?, counted?

## get
### Arguments and values
- `coll`: a map, vector, string, set, instance or nil.
- `k`: a key, index, element or slot name.
- `not-found`: returned if there's none; nil if not given.

### Notes
Keywords, maps, sets and vectors are functions too: `(:a m)`, `(m :a)`, `(#{:a} :a)` and `(v 0)` all call `get`.

See also: get-in, contains?, find, nth

## get-in
### Arguments and values
- `m`: nested collections.
- `ks`: a sequence of keys, one per level.
- `not-found`: returned if the path is missing.
- Returns the value at the end of the path.

See also: get, assoc-in, update-in

## contains?
### Arguments and values
- `coll`: a map, set or vector.
- `k`: a key, element or index.
- Returns true if it has it, even with a nil value.

See also: get, some

## find
### Arguments and values
- `m`: a map.
- `k`: a key.
- Returns the entry, `[k v]`, or nil.

See also: get, key, val

## nth
### Arguments and values
- `coll`: a vector, list, seq, string or array.
- `i`: an index.
- `not-found`: returned past the end; without it, an `index-error`.

See also: get, first, last

## peek
### Arguments and values
- `coll`: a vector or list.
- Returns the element `pop` would remove.

See also: pop, conj, first, last

## conj
### Arguments and values
- `coll`: a collection, or nil.
- `xs`: elements to add.
- Returns the collection with them added: at the end of a vector, the front of a list, as entries in a map.

See also: cons, into, assoc, disj

## pop
### Arguments and values
- `coll`: a vector or list that isn't empty.
- Returns it without the element `peek` gives.

See also: peek, rest, butlast

## assoc
### Arguments and values
- `m`: a map, a vector or nil.
- `k`, `v`, `kvs`: keys (indexes of a vector, up to its count) and values.
- Returns the new collection.

See also: dissoc, assoc-in, update, conj

## assoc-in
### Arguments and values
- `m`: nested maps (or vectors).
- `ks`: the path of keys.
- `v`: the value.
- Returns the new structure; missing levels become maps.

See also: get-in, update-in, assoc

## dissoc
### Arguments and values
- `m`: a map.
- `ks`: keys to remove.
- Returns the new map.

See also: assoc, disj, select-keys

## disj
### Arguments and values
- `s`: a set.
- `xs`: elements to remove.
- Returns the new set.

See also: conj, dissoc

## update
### Arguments and values
- `m`: a map or vector.
- `k`: a key.
- `f`: called with the old value (nil if none) and `args`.
- Returns the new collection.

See also: update-in, assoc, fnil

## update-in
### Arguments and values
- `m`: nested collections.
- `ks`: the path of keys.
- `f`, `args`: as `update`'s.
- Returns the new structure.

See also: update, assoc-in, get-in

## merge
### Arguments and values
- `maps`: maps, or nil.
- Returns them merged, the later keys winning.

See also: merge-with, into, assoc

## merge-with
### Arguments and values
- `f`: combines two values of the same key.
- `maps`: maps.
- Returns the merged map.

See also: merge

## select-keys
### Arguments and values
- `m`: a map.
- `ks`: the keys to keep.
- Returns a map of those present.

See also: dissoc, keys

## keys
### Arguments and values
- `m`: a map or instance.
- Returns a seq of its keys, or nil if it is empty.

See also: vals, key, class-slots

## vals
### Arguments and values
- `m`: a map.
- Returns a seq of its values, in the order of `keys`, or nil.

See also: keys, val

## key
### Arguments and values
- `entry`: a map entry, `[k v]`.
- Returns the key.

See also: val, find

## val
### Arguments and values
- `entry`: a map entry.
- Returns the value.

See also: key, find

## update-keys
### Arguments and values
- `m`: a map.
- `f`: a function of a key.
- Returns a map with each key replaced by `(f key)`.

See also: update-vals, zipmap

## update-vals
### Arguments and values
- `m`: a map.
- `f`: a function of a value.
- Returns a map with each value replaced by `(f value)`.

See also: update-keys, update

## subvec
### Arguments and values
- `v`: a vector.
- `start`, `end`: indexes; `end` is the count if not given.
- Returns a vector of the elements between them.

See also: subs, take, drop

## rseq
### Arguments and values
- `v`: a vector, sorted map or sorted set.
- Returns its elements in reverse, in constant time, or nil.

See also: reverse, rsubseq

## subseq
### Arguments and values
- `sc`: a sorted map or set.
- `test`, `k`: one of `<`, `<=`, `>` and `>=`, and a key.
- `start-test`, `start-k`, `end-test`, `end-k`: two bounds.
- Returns a seq of the elements whose keys pass, in order.

See also: rsubseq, sorted-map, filter

## rsubseq
### Arguments and values
- As `subseq`'s.
- Returns the elements in reverse order.

See also: subseq, rseq

## frequencies
### Arguments and values
- `coll`: a collection, or nil.
- Returns a map from each distinct element to its count.

See also: group-by, distinct

## group-by
### Arguments and values
- `f`: a function of an element.
- `coll`: a collection.
- Returns a map from each `(f x)` to a vector of the elements that gave it, in order.

See also: frequencies, partition-by

## coll?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a collection: a list, vector, map, set or seq, else false.

See also: seq?, sequential?

## list?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a list, else false.

See also: seq?, vector?

## vector?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a vector, else false.

See also: list?, sequential?

## map?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a map, else false.

See also: set?, associative?

## set?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a set, else false.

See also: map?

## seq?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a seq: a list, or a lazy or other seq, else false.

See also: sequential?, seq

## sequential?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a list, vector or seq, else false.

See also: coll?, seq?

## associative?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a map or vector, else false.

See also: map?, vector?

## counted?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a collection whose count takes constant time, else false.

See also: count

## sorted?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a sorted map or set, else false.

See also: sorted-map, sorted-set

## nil?
### Arguments and values
- `x`: any value.
- Returns true if `x` is nil, else false.

See also: some?, not

## some?
### Arguments and values
- `x`: any value.
- Returns true if `x` is anything but nil, else false.

See also: nil?, some

## true?
### Arguments and values
- `x`: any value.
- Returns true if `x` is true itself, else false.

See also: false?, boolean

## false?
### Arguments and values
- `x`: any value.
- Returns true if `x` is false itself, else false.

See also: true?, not

## boolean?
### Arguments and values
- `x`: any value.
- Returns true if `x` is true or false, else false.

See also: boolean

## empty?
### Arguments and values
- `coll`: a collection, or nil.
- Returns true if it has no elements.

### Notes
The idiom for "not empty" is `(seq coll)`.

See also: seq, not-empty, count

## not-empty
### Arguments and values
- `coll`: a collection, or nil.
- Returns `coll` if it has elements, else nil.

See also: empty?, seq

## distinct?
### Arguments and values
- `xs`: any values, at least one.
- Returns true if no two are equal.

See also: distinct

## boolean
### Arguments and values
- `x`: any value.
- Returns false for nil and false, else true.

See also: boolean?, not

## transient
### Arguments and values
- `coll`: a vector, map or set.
- Returns a transient copy, in constant time.

### Notes
A transient belongs to the fiber that made it. Use the value each `!` function returns, and call `persistent!` once at the end; after that the transient can't be used.

See also: persistent!, conj!, assoc!

## persistent!
### Arguments and values
- `t`: a transient.
- Returns a persistent collection, in constant time; `t` can't be used after.

See also: transient

## conj!
### Arguments and values
- `t`: a transient collection.
- `x`: an element.
- Returns `t`.

See also: conj, persistent!

## assoc!
### Arguments and values
- `t`: a transient map or vector.
- `k`, `v`: a key and value.
- Returns `t`.

See also: assoc, dissoc!

## dissoc!
### Arguments and values
- `t`: a transient map.
- `k`: a key.
- Returns `t`.

See also: dissoc, assoc!

## disj!
### Arguments and values
- `t`: a transient set.
- `x`: an element.
- Returns `t`.

See also: disj, conj!

## pop!
### Arguments and values
- `t`: a transient vector.
- Returns `t`.

See also: pop, conj!

## meta
### Arguments and values
- `x`: any value.
- Returns its metadata map, or nil.

See also: with-meta, vary-meta

## with-meta
### Arguments and values
- `x`: a collection or symbol.
- `m`: a map, or nil.
- Returns `x` with that metadata; it is equal to `x`.

See also: meta, vary-meta

## vary-meta
### Arguments and values
- `x`: a collection or symbol.
- `f`, `args`: called with its metadata.
- Returns `x` with the new metadata.

See also: with-meta, meta

## hash
### Arguments and values
- `x`: any value.
- Returns its hash, an integer; equal values have equal hashes.

See also: hash-of, =

## hash-of
### Arguments and values
- `x`: any value.
- Returns its hash. A generic function: specialize it with `equiv`.

See also: hash, equiv

## equiv
### Arguments and values
- `a`, `b`: instances.
- Returns true if they are equal. A generic function: specialize it, and `hash-of`, to give a class value equality.

See also: =, hash-of, defmethod

## seq
### Arguments and values
- `coll`: a collection, or nil.
- Returns a seq of its elements, or nil if it is empty: a string's characters, a map's entries.

See also: empty?, sequence, first

## first
### Arguments and values
- `coll`: a collection, or nil.
- Returns the first element, or nil.

See also: second, rest, next, peek

## second
### Arguments and values
- `coll`: a collection, or nil.
- Returns the second element, or nil.

See also: first, nth

## ffirst
### Arguments and values
- `coll`: a collection, or nil.
- Returns `(first (first coll))`.

See also: first

## rest
### Arguments and values
- `coll`: a collection, or nil.
- Returns a seq of the elements after the first; empty, never nil.

See also: next, first, drop

## next
### Arguments and values
- `coll`: a collection, or nil.
- Returns a seq of the elements after the first, or nil if there are none.

See also: rest, nnext

## nnext
### Arguments and values
- `coll`: a collection, or nil.
- Returns `(next (next coll))`.

See also: next

## last
### Arguments and values
- `coll`: a collection, or nil.
- Returns the last element, or nil; it walks the collection unless it is a vector.

See also: peek, butlast, first

## butlast
### Arguments and values
- `coll`: a collection, or nil.
- Returns a seq of every element but the last, or nil.

See also: drop-last, last, pop

## nthrest
### Arguments and values
- `coll`: a collection, or nil.
- `n`: how many to skip.
- Returns the rest after `n` elements (empty, not nil).

See also: nthnext, drop

## nthnext
### Arguments and values
- `coll`: a collection, or nil.
- `n`: how many to skip.
- Returns the seq after `n` elements, or nil.

See also: nthrest, next

## take
### Arguments and values
- `n`: how many.
- `coll`: a collection, which may be infinite.
- Returns a lazy seq of the first `n` elements, or a transducer without `coll`.

See also: drop, take-while, take-last

## take-while
### Arguments and values
- `pred`: a predicate.
- `coll`: a collection.
- Returns a lazy seq of the elements up to the first for which `pred` is false, or a transducer without `coll`.

See also: drop-while, take, split-with

## drop
### Arguments and values
- `n`: how many.
- `coll`: a collection.
- Returns a lazy seq of the elements after the first `n`, or a transducer without `coll`.

See also: take, nthrest, drop-while

## drop-while
### Arguments and values
- `pred`: a predicate.
- `coll`: a collection.
- Returns a lazy seq of the elements from the first for which `pred` is false, or a transducer without `coll`.

See also: take-while, drop

## take-last
### Arguments and values
- `n`: how many.
- `coll`: a finite collection.
- Returns a seq of the last `n`, or nil.

See also: drop-last, take, last

## take-nth
### Arguments and values
- `n`: a positive integer.
- `coll`: a collection.
- Returns a lazy seq of every `n`th element, from the first.

See also: take, partition

## drop-last
### Arguments and values
- `n`: how many; 1 if not given.
- `coll`: a collection.
- Returns a lazy seq without the last `n`.

See also: butlast, take-last

## split-at
### Arguments and values
- `n`: an index.
- `coll`: a collection.
- Returns `[(take n coll) (drop n coll)]`.

See also: split-with, take, drop

## split-with
### Arguments and values
- `pred`: a predicate.
- `coll`: a collection.
- Returns `[(take-while pred coll) (drop-while pred coll)]`.

See also: split-at, partition-by

## map
### Arguments and values
- `f`: a function taking one argument per collection.
- `colls`: collections, walked in step until the shortest ends.
- Returns a lazy seq of the results, or a transducer without `coll`.

See also: mapv, map-indexed, mapcat, keep, for

## mapv
### Arguments and values
- `f`, `colls`: as `map`'s.
- Returns a vector of the results, computed at once.

See also: map, filterv

## map-indexed
### Arguments and values
- `f`: a function of an index and an element.
- `coll`: a collection.
- Returns a lazy seq of the results, or a transducer without `coll`.

See also: map, keep-indexed

## mapcat
### Arguments and values
- `f`: a function returning a collection.
- `colls`: collections.
- Returns a lazy seq of the elements of the results, concatenated, or a transducer without `coll`.

See also: map, concat, for

## filter
### Arguments and values
- `pred`: a predicate.
- `coll`: a collection.
- Returns a lazy seq of the elements for which `pred` is true, or a transducer without `coll`.

See also: remove, filterv, keep

## filterv
### Arguments and values
- `pred`: a predicate.
- `coll`: a collection.
- Returns a vector of the elements for which `pred` is true.

See also: filter, mapv

## remove
### Arguments and values
- `pred`: a predicate.
- `coll`: a collection.
- Returns a lazy seq of the elements for which `pred` is false, or a transducer without `coll`.

See also: filter

## keep
### Arguments and values
- `f`: a function of an element.
- `coll`: a collection.
- Returns a lazy seq of the results of `f` that aren't nil (false is kept), or a transducer without `coll`.

See also: filter, map

## keep-indexed
### Arguments and values
- `f`: a function of an index and an element.
- `coll`: a collection.
- Returns a lazy seq of the results that aren't nil.

See also: keep, map-indexed

## distinct
### Arguments and values
- `coll`: a collection.
- Returns a lazy seq of the elements without repeats, in order, or a transducer without `coll`.

See also: dedupe, set, distinct?

## dedupe
### Arguments and values
- `coll`: a collection.
- Returns a lazy seq of the elements without consecutive repeats, or a transducer without `coll`.

See also: distinct, partition-by

## flatten
### Arguments and values
- `coll`: a collection, or nil.
- Returns a list of the elements that aren't sequential, from any depth.

See also: mapcat, concat, tree-seq

## reverse
### Arguments and values
- `coll`: a collection, or nil.
- Returns a list of its elements in reverse order.

See also: rseq, skein.string/reverse

## sort
### Arguments and values
- `cmp`: a comparator, as `sorted-map-by` takes; `compare` if not given.
- `coll`: a collection.
- Returns a list of the elements, sorted; the sort is stable.

See also: sort-by, compare, sorted-set

## sort-by
### Arguments and values
- `keyfn`: gives the value to sort by.
- `cmp`: a comparator; `compare` if not given.
- `coll`: a collection.
- Returns a sorted list; equal keys keep their order.

See also: sort, group-by, max-key

## partition
### Arguments and values
- `n`: the size of each part.
- `step`: how far apart the parts start; `n` if not given.
- `coll`: a collection.
- Returns a lazy seq of lists; a short last part is dropped.

See also: partition-all, partition-by, split-at

## partition-all
### Arguments and values
- As `partition`'s.
- Returns a lazy seq of lists, keeping a short last one; or a transducer giving vectors.

See also: partition

## partition-by
### Arguments and values
- `f`: a function of an element.
- `coll`: a collection.
- Returns a lazy seq of lists of consecutive elements that give the same `(f x)`.

See also: partition, group-by, dedupe

## interleave
### Arguments and values
- `colls`: collections.
- Returns a lazy seq of their first elements, then their second, until the shortest ends.

See also: interpose, zipmap

## interpose
### Arguments and values
- `sep`: the separator.
- `coll`: a collection.
- Returns a lazy seq of the elements with `sep` between them, or a transducer without `coll`.

See also: interleave, skein.string/join

## concat
### Arguments and values
- `colls`: collections.
- Returns a lazy seq of their elements, one after another.

See also: lazy-cat, mapcat, into

## cons
### Arguments and values
- `x`: any value.
- `coll`: a collection.
- Returns a seq of `x` then the elements of `coll`.

See also: conj, list*

## reductions
### Arguments and values
- `f`: a function of an accumulator and an element.
- `init`: the start; the first element if not given.
- `coll`: a collection.
- Returns a lazy seq of each intermediate result, `init` first.

See also: reduce

## range
### Arguments and values
- `start`: 0 if not given.
- `end`: where to stop, not included; none for an infinite seq.
- `step`: 1 if not given; may be negative.
- Returns a lazy seq of numbers.

See also: repeat, iterate, dotimes

## repeat
### Arguments and values
- `n`: how many; infinite if not given.
- `x`: the value.
- Returns a lazy seq.

See also: repeatedly, cycle

## repeatedly
### Arguments and values
- `n`: how many; infinite if not given.
- `f`: a function of no arguments, called for each element.
- Returns a lazy seq.

See also: repeat, iterate

## iterate
### Arguments and values
- `f`: a function of one argument.
- `x`: the first element.
- Returns an infinite lazy seq.

See also: repeatedly, range, reductions

## cycle
### Arguments and values
- `coll`: a collection, or nil.
- Returns an infinite lazy seq of its elements, over and over.

See also: repeat

## lazy-seq
### Arguments and values
- `body`: returns a seq, a collection or nil; it runs once, when the seq is first used.
- Returns a lazy seq.

### Notes
The usual shape is a function that returns `(lazy-seq (cons x (recursive-call ...)))`; it can be infinite, since each element is computed only when it is reached.

See also: lazy-cat, cons, iterate

## lazy-cat
### Arguments and values
- `colls`: expressions giving collections, each evaluated when reached.
- Returns a lazy seq.

See also: concat, lazy-seq

## tree-seq
### Arguments and values
- `branch?`: true for a node with children.
- `children`: gives a node's children.
- `root`: the tree.
- Returns a lazy seq of every node, depth first.

See also: flatten

## sequence
### Arguments and values
- `xform`: a transducer, optional.
- `coll`: a collection.
- Returns a seq, `()` rather than nil when empty.

See also: seq, eduction

## reduce
### Arguments and values
- `f`: a function of an accumulator and an element.
- `init`: the start; without it the first element, and `(f)` for an empty collection.
- `coll`: a collection.
- Returns the final accumulator.

See also: reduce-kv, reductions, reduced, transduce

## reduce-kv
### Arguments and values
- `f`: a function of an accumulator, a key (or index) and a value.
- `init`: the start.
- `coll`: a map or vector.

See also: reduce

## reduced
### Arguments and values
- `x`: any value.
- Returns it wrapped, so that `reduce` stops and returns `x`.

See also: reduced?, unreduced, ensure-reduced

## reduced?
### Arguments and values
- `x`: any value.
- Returns true if `x` is wrapped by `reduced`, else false.

See also: reduced

## unreduced
### Arguments and values
- `x`: any value.
- Returns it without `reduced`'s wrapper.

See also: reduced

## ensure-reduced
### Arguments and values
- `x`: any value.
- Returns it wrapped by `reduced`, once.

See also: reduced

## some
### Arguments and values
- `pred`: a function.
- `coll`: a collection.
- Returns the first truthy result of `pred`, or nil.

### Notes
A set makes a handy predicate: `(some #{:a :b} coll)` finds the first of them in `coll`.

See also: every?, not-any?, filter

## every?
### Arguments and values
- `pred`: a predicate.
- `coll`: a collection.
- Returns true if `pred` is true of every element (true for none).

See also: some, not-every?

## not-every?
### Arguments and values
- `pred`, `coll`: as `every?`'s.
- Returns `(not (every? pred coll))`.

See also: every?

## not-any?
### Arguments and values
- `pred`, `coll`: as `some`'s.
- Returns `(not (some pred coll))`.

See also: some

## max-key
### Arguments and values
- `k`: a function giving a number.
- `x`, `more`: the candidates.
- Returns the one with the greatest `(k x)`.

See also: min-key, max, sort-by

## min-key
### Arguments and values
- `k`, `x`, `more`: as `max-key`'s.
- Returns the one with the least `(k x)`.

See also: max-key, min

## doall
### Arguments and values
- `coll`: a collection, or nil.
- Realizes every element, so its effects happen now.
- Returns `coll`.

See also: dorun, run!

## dorun
### Arguments and values
- `coll`: a collection, or nil.
- Realizes every element.
- Returns nil.

See also: doall, run!

## realized?
### Arguments and values
- `x`: a lazy seq, promise or delay.
- Returns true if its value has been computed.

See also: lazy-seq, delay, promise

## transduce
### Arguments and values
- `xform`: a transducer, from `map`, `filter` and the others without their collection, combined with `comp`.
- `f`: a reducing function.
- `init`: the start; `(f)` if not given.
- `coll`: a collection.

See also: into, eduction, completing, reduce

## eduction
### Arguments and values
- `xforms-and-coll`: transducers, then a collection.
- Returns a reducible, seqable view that applies them each time it is used.

See also: sequence, transduce

## cat
### Arguments and values
- `rf`: a reducing function.
- A transducer: each element passing through is a collection, whose elements go on.

See also: mapcat, transduce

## completing
### Arguments and values
- `f`: a reducing function of two arguments (and none, for `init`).
- `cf`: the completion, applied to the result; `identity` if not given.
- Returns a reducing function for `transduce`.

See also: transduce

## pmap
### Arguments and values
- `f`: a function, which should take long enough to be worth a thread.
- `coll`: a finite collection.
- Returns a list of the results, in order.

See also: map, preduce, pdotimes

## preduce
### Arguments and values
- `f`: an associative function of two arguments.
- `init`: its identity value.
- `coll`: a collection.
- Returns the reduction, computed in parallel chunks.

See also: reduce, pmap

## pdotimes
### Arguments and values
- `bindings`: `[name n]`.
- `body`: run for each index, on worker threads; the order isn't defined.
- Returns nil.

See also: dotimes, pmap

## apply
### Arguments and values
- `f`: a function.
- `x`, `more`: arguments; the last is a collection whose elements are passed one by one.
- Returns `f`'s result.

See also: partial, list*

## fn?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a function, else false.

See also: ifn?

## ifn?
### Arguments and values
- `x`: any value.
- Returns true if `x` is callable: a function, keyword, map, set or vector, else false.

See also: fn?

## identity
### Arguments and values
- `x`: any value.
- Returns `x`.

See also: constantly

## constantly
### Arguments and values
- `x`: any value.
- Returns a function of any arguments that returns `x`.

See also: identity

## comp
### Arguments and values
- `fns`: functions; the last may take any arguments, the rest one.
- Returns their composition: `((comp f g) x)` is `(f (g x))`; `identity` for none.

### Notes
Transducers compose with `comp` too, and apply in the order written: `(comp (filter odd?) (map inc))` filters first.

See also: partial, ->, juxt

## partial
### Arguments and values
- `f`: a function.
- `bound`: its first arguments.
- Returns a function taking the rest.

See also: comp, apply

## complement
### Arguments and values
- `f`: a function.
- Returns a function giving `(not (f args...))`.

See also: not, remove

## juxt
### Arguments and values
- `fns`: functions.
- Returns a function giving a vector of each one's result.

See also: comp, map

## fnil
### Arguments and values
- `f`: a function.
- `default`: replaces a nil first argument.
- Returns the new function.

See also: update, or

## every-pred
### Arguments and values
- `preds`: predicates.
- Returns a predicate true if all are true of all its arguments.

See also: some-fn, every?

## some-fn
### Arguments and values
- `preds`: functions.
- Returns a function giving the first truthy result of any of them on any argument, or nil.

See also: every-pred, some

## memoize
### Arguments and values
- `f`: a function without side effects.
- Returns a function that computes each result once per arguments and keeps it.

See also: delay

## defclass
### Arguments and values
- `class-name`: a symbol.
- `supers`: a vector of superclasses; several are allowed.
- `specs`: an optional docstring, then slots: `(name :init expr :reader f :cell :atom :type t :doc "...")`.
- Defines the class and a var holding it.

### Notes
Slots are immutable unless they have `:cell`: `:atom` (changed atomically), `:ref` (in transactions) or `:unsynchronized` (one fiber). Redefining a class updates its instances (DESIGN §8.4). The class precedence list is C3's.

See also: make, defgeneric, defmethod, defstruct

## make
### Arguments and values
- `class`: a class or its name.
- `initargs`: slot names (keywords) and values; the others take their `:init`.
- Returns a new instance, after calling `initialize` on it.

See also: defclass, with, initialize

## initialize
### Arguments and values
- `instance`: a new instance, its slots set.
- A generic function, for `:after` methods that set up more.

See also: make, defmethod

## with
### Arguments and values
- `x`: an instance or struct.
- `kvs`: slots or fields and their new values; `:fresh-cells true` gives the copy new cells.
- Returns the copy.

### Notes
Cell slots are shared with the original unless `:fresh-cells true` is given.

See also: make, assoc, set-slot!

## slot
### Arguments and values
- `x`: an instance.
- `name`: a slot's keyword.
- `not-found`: returned for a slot it hasn't; without it, an error.
- Returns the value, or a cell slot's current value.

See also: set-slot!, update-slot!, get, cell

## set-slot!
### Arguments and values
- `x`: an instance.
- `name`: a cell or `:unsynchronized` slot.
- `value`: its new value.
- Returns `value`.

See also: update-slot!, slot

## update-slot!
### Arguments and values
- `x`: an instance.
- `name`: a cell or `:unsynchronized` slot.
- `f`, `args`: called with the old value.
- Returns the new value.

See also: set-slot!, swap!

## cell
### Arguments and values
- `x`: an instance.
- `name`: a cell slot.
- Returns the atom or ref behind it.

See also: slot, add-watch

## instance?
### Arguments and values
- `class`: a class or its name.
- `x`: any value.
- Returns true if `x` is an instance of the class or one below it.

See also: class-of, make

## class-of
### Arguments and values
- `x`: any value; every value has a class.
- Returns its class.

See also: class-name, instance?

## class-name
### Arguments and values
- `class`: a class.
- Returns its name, a symbol.

See also: class-of

## class-slots
### Arguments and values
- `class`: a class.
- Returns a vector of its slot names, inherited ones too.

See also: class-precedence-list, keys

## class-precedence-list
### Arguments and values
- `class`: a class.
- Returns a seq of it and its superclasses, most specific first, ending in `object` and `any`.

See also: class-slots, defclass

## update-instance-for-redefined-class
### Arguments and values
- `instance`: an instance of the redefined class.
- `added`, `discarded`: the slot names added and removed.
- `old-values`: a map of the removed slots' values.
- A generic function: `:after` methods can fill new slots.

See also: defclass

## defgeneric
### Arguments and values
- `gf-name`: a symbol.
- `params`: the required parameters (and `& rest`), which methods must match.
- `doc`: an optional docstring.

See also: defmethod, generic-methods

## defmethod
### Arguments and values
- `gf-name`: the generic function, created if there's none.
- `qualifier`: optional, `:before`, `:after` or `:around`.
- `params`: `(p class)` specializes on a class, `(p (= value))` on a value, a plain `p` on anything.
- `body`: in it, `(call-next-method)` and `(next-method?)`.

### Notes
Dispatch is on the classes of every required argument (multiple dispatch). Built-in values have classes: `integer`, `float`, `string`, `keyword`, `vector`, `hash-map`, `nil-class` and others (DESIGN §8.3).

See also: defgeneric, defclass

## generic-methods
### Arguments and values
- `f`: a generic function.
- Returns its methods.

See also: defmethod

## deref-object
### Arguments and values
- `x`: an instance.
- `timeout`, `timeout-value`: as `deref`'s, or nil.
- A generic function: a method makes `@x` work for a class.

See also: deref

## close
### Arguments and values
- `x`: a resource: a stream, socket or an instance of a class with a method.
- A generic function, which `with-open` calls.

See also: with-open

## defstruct
### Arguments and values
- `struct-name`: a symbol.
- `:value`: optional; makes an immutable, unboxed value struct whose fields are primitive types or value structs.
- `specs`: an optional docstring, then fields: `(name type)`.
- Defines a constructor (positional, or with keywords), `name?`, and `name-field` accessors.

### Notes
Without `:value` it is a plain record: a heap object with immutable fields. Both compare by their fields, and `(:field s)` reads one.

See also: defsoa, make-array, with, struct?

## struct?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a struct value, else false.

See also: defstruct

## defsoa
### Arguments and values
- `soa-name`: a symbol.
- `fields`: `(name type)`.
- Defines `make-name` (taking a length) and a function `(field coll i)` per field.

See also: defstruct, update!, make-array

## make-array
### Arguments and values
- `type`: a primitive type (`f32`, `f64`, `i32`, `u8`...), a value struct, or `any`.
- `n`: the length.
- Returns a mutable array, every element zero (or nil).

See also: aget, aset!, update!, view

## aget
### Arguments and values
- `array`: an array.
- `i`: an index.
- Returns the element.

See also: aset!, nth

## aset!
### Arguments and values
- `array`: an array.
- `i`: an index.
- `value`: of the element type.
- Returns `value`.

See also: aget, update!

## update!
### Arguments and values
- `array`: an array, or a `defsoa` collection.
- `i`: an index.
- `field`: for an array of structs, the field to change.
- `f`, `args`: called with the old value.

See also: aset!, update

## array?
### Arguments and values
- `x`: any value.
- Returns true if `x` is an array or a view of one, else false.

See also: make-array

## view
### Arguments and values
- `array`: a primitive array.
- `start`, `end`: indexes; the end if not given.
- Returns a view sharing its memory.

See also: make-array, as-bytes, subvec

## as-bytes
### Arguments and values
- `array`: a numeric array.
- Returns a `u8` view of its memory.

See also: view, skein.ffi/pin

## atom
### Arguments and values
- `x`: the starting value.
- `:validator f`: optional; refuses a value for which `f` is false.
- Returns the atom.

### Notes
Atoms change one value at a time without locks, and every fiber sees the change; to change several values together use refs.

See also: swap!, reset!, deref, ref

## atom?
### Arguments and values
- `x`: any value.
- Returns true if `x` is an atom, else false.

See also: atom

## deref
### Arguments and values
- `ref`: an atom, ref, volatile, promise, delay, task or an instance with `deref-object`.
- `seconds`, `timeout-value`: wait at most this long for a promise or task, then return `timeout-value`.
- Returns the value; `@x` is short for it.

See also: atom, promise, future, deref-object

## reset!
### Arguments and values
- `a`: an atom.
- `x`: the new value.
- Returns `x`.

See also: swap!, reset-vals!

## reset-vals!
### Arguments and values
- `a`: an atom.
- `x`: the new value.
- Returns `[old new]`.

See also: reset!, swap-vals!

## swap!
### Arguments and values
- `a`: an atom.
- `f`, `args`: called with the old value; may run more than once, so it must have no side effects.
- Returns the new value.

See also: reset!, swap-vals!, compare-and-set!

## swap-vals!
### Arguments and values
- As `swap!`'s.
- Returns `[old new]`.

See also: swap!

## compare-and-set!
### Arguments and values
- `a`: an atom.
- `old`: the value it must hold (by identity).
- `new`: its new value.
- Returns true if it was set.

See also: swap!

## add-watch
### Arguments and values
- `reference`: an atom or ref.
- `key`: names the watch.
- `f`: called as `(f key reference old new)` after each change.
- Returns `reference`.

See also: remove-watch, cell

## remove-watch
### Arguments and values
- `reference`: an atom or ref.
- `key`: the watch's key.

See also: add-watch

## set-validator!
### Arguments and values
- `reference`: an atom or ref.
- `f`: a predicate each new value must pass; nil removes it.

See also: get-validator, atom

## get-validator
### Arguments and values
- `reference`: an atom or ref.
- Returns its validator, or nil.

See also: set-validator!

## ref
### Arguments and values
- `x`: the starting value.
- `:validator f`: optional.
- Returns a ref, changed only inside `dosync`.

See also: dosync, alter, atom

## ref?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a ref, else false.

See also: ref

## dosync
### Arguments and values
- `body`: evaluated in a transaction, which runs again if another one conflicts; keep side effects out of it.
- Returns the body's value.

See also: ref, alter, commute, io!

## ref-set
### Arguments and values
- `r`: a ref.
- `x`: its new value.
- Returns `x`.

See also: alter, dosync

## alter
### Arguments and values
- `r`: a ref.
- `f`, `args`: called with its value.
- Returns the new value.

See also: commute, ref-set

## commute
### Arguments and values
- As `alter`'s; `f` must be commutative (as `+`).
- Returns the new value.

See also: alter

## ensure
### Arguments and values
- `r`: a ref.
- Returns its value, protected from other transactions until this one commits.

See also: dosync

## io!
### Arguments and values
- `body`: side effects.
- Returns its value outside a transaction; inside one, an error.

See also: dosync

## volatile!
### Arguments and values
- `x`: the starting value.
- Returns a volatile: a mutable box for one fiber, without synchronization.

See also: vswap!, vreset!, atom

## volatile?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a volatile, else false.

See also: volatile!

## vreset!
### Arguments and values
- `v`: a volatile.
- `x`: its new value.
- Returns `x`.

See also: vswap!

## vswap!
### Arguments and values
- `v`: a volatile.
- `f`, `args`: called with its value.
- Returns the new value.

See also: vreset!, swap!

## delay
### Arguments and values
- `body`: evaluated at the first `deref` or `force`, once.
- Returns a delay.

See also: force, delay?, promise, memoize

## delay?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a delay, else false.

See also: delay

## force
### Arguments and values
- `x`: a delay, or any value.
- Returns the delay's value, or `x`.

See also: delay, deref

## promise
### Arguments and values
- Returns an empty promise, which `deliver` fills once.

See also: deliver, deref, future

## deliver
### Arguments and values
- `p`: a promise.
- `x`: its value; a second delivery is ignored.
- Returns `p`, or nil if it already had a value.

See also: promise

## future
### Arguments and values
- `body`: run as a detached task on the scheduler.
- Returns the task; `@f` waits for its value, or re-signals its error.

### Notes
Tasks are fibers: cheap enough to start thousands, scheduled on worker threads, parked rather than blocking a thread while they wait (DESIGN §13).

See also: spawn, with-nursery, promise, deref

## with-nursery
### Arguments and values
- `[name opts]`: the nursery's name, and an optional option map: `:on-error` is `:cancel-siblings` (the default), `:ignore`, `:crash` or `:restart-fiber`.
- `body`: spawns tasks with `(spawn name ...)`.
- Returns the body's value, after every task has ended.

### Notes
This is structured concurrency: no task outlives its nursery. By default the first failure cancels the other tasks and is signaled where the nursery waits.

See also: spawn, future, cancel!

## spawn
### Arguments and values
- `nursery`: from `with-nursery`.
- `body`: run as a task.
- Returns the task.

See also: with-nursery, future

## task?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a task, else false.

See also: future, spawn

## done?
### Arguments and values
- `task`: a task.
- Returns true if it has ended, however.

See also: cancelled?, deref

## cancel!
### Arguments and values
- `task`: a task.
- Asks it to stop: it signals `cancelled` at its next cancellation point.

See also: cancelled?, check-cancelled, with-timeout

## cancelled?
### Arguments and values
- `task`: a task.
- Returns true if it was cancelled.

See also: cancel!, done?

## cancelled
### Arguments and values
- The condition type a cancelled task signals inside itself at a cancellation point. It isn't an error.

See also: cancel!, task-cancelled-error, check-cancelled

## check-cancelled
### Arguments and values
- Returns nil, or signals `cancelled` (or `timeout`) if this task should stop.

### Notes
Channel operations, `sleep`, `deref` of a task and nursery joins are cancellation points too; a long computation calls `check-cancelled` now and then.

See also: cancel!, with-timeout, sleep

## with-timeout
### Arguments and values
- `seconds`: the time limit.
- `body`: evaluated; at its first cancellation point past the limit it signals `timeout`.
- Returns the body's value.

See also: timeout, check-cancelled, timeout-chan

## timeout
### Arguments and values
- The error type `with-timeout` signals.

See also: with-timeout

## sleep
### Arguments and values
- `seconds`: a number.
- Parks the fiber, not its thread. A cancellation point.
- Returns nil.

See also: timeout-chan, skein.time/now

## cpu-count
### Arguments and values
- Returns the number of worker threads the parallel functions use.

See also: pmap, pdotimes

## chan
### Arguments and values
- `n`: the buffer's size; unbuffered if not given.
- Returns a channel.

### Notes
Taking and putting park the fiber until the other side is ready; an unbuffered channel hands a value straight from one fiber to another.

See also: <!, >!, alts!, close!

## chan?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a channel, else false.

See also: chan

## <!
### Arguments and values
- `ch`: a channel.
- Returns the next value, waiting for one, or nil once it is closed and empty.

See also: >!, alts!, close!

## >!
### Arguments and values
- `ch`: a channel.
- `x`: any value but nil.
- Returns true when it was put (waiting for room), or false if the channel is closed.

See also: <!, alts!

## alts!
### Arguments and values
- `ops`: channels to take from, and `[channel value]` pairs to put.
- Returns `[value channel]` for the first that completes.

See also: <!, >!, timeout-chan

## close!
### Arguments and values
- `ch`: a channel.
- Returns nil.

See also: chan, <!

## timeout-chan
### Arguments and values
- `seconds`: a number.
- Returns a channel that closes after that time, for `alts!`.

See also: alts!, with-timeout

## on-main-thread
### Arguments and values
- `body`: run on the main thread, which a UI toolkit may need.
- Returns its value, waiting for it.

See also: spawn-pinned, drain-main-thread!

## spawn-pinned
### Arguments and values
- `where`: `:main`, the only place supported.
- `body`: queued as a task for that thread.
- Returns the task.

See also: on-main-thread, drain-main-thread!

## drain-main-thread!
### Arguments and values
- Runs the work queued for the main thread; called from the main thread's loop.
- Returns nil.

See also: on-main-thread, spawn-pinned

## error
### Arguments and values
- `x`: a condition, a condition type (then `args` are keyword initargs), or a message.
- `args`: the rest of the message, joined as `println` joins them.
- Doesn't return normally: unhandled, it enters the debugger (in `skein dev`) or fails the fiber.

See also: signal, warn, ex-info, handler-case, try

## warn
### Arguments and values
- As `error`'s.
- Signals a warning; unhandled, it is printed and `warn` returns nil.

See also: error, signal

## signal
### Arguments and values
- As `error`'s.
- Signals a condition; returns nil if no handler unwinds.

See also: error, warn, handler-bind

## ex-info
### Arguments and values
- `message`: a string.
- `data`: a map.
- `cause`: an optional condition.
- Returns an error, which `error` signals.

See also: ex-data, ex-message, ex-cause, error

## ex-data
### Arguments and values
- `x`: a condition.
- Returns its data map, or nil.

See also: ex-info

## ex-message
### Arguments and values
- `x`: a condition.
- Returns its message, or nil.

See also: condition-message, ex-info

## ex-cause
### Arguments and values
- `x`: a condition.
- Returns its cause, or nil.

See also: ex-info

## try
### Arguments and values
- `forms`: the body, then `(catch type e body...)` clauses and an optional `(finally body...)`.
- Returns the body's value, or the matching clause's.

### Notes
`catch` unwinds as `handler-case` does. `cancelled` isn't an error, so `(catch error e ...)` lets cancellation through.

See also: handler-case, with-open

## handler-case
### Arguments and values
- `expr`: evaluated.
- `clauses`: `(type [c] body...)`; the first whose type matches the signaled condition handles it, after unwinding.
- Returns `expr`'s value, or the clause's.

See also: try, handler-bind, restart-case

## handler-bind
### Arguments and values
- `bindings`: `[type handler ...]`, a handler a function of the condition.
- `body`: evaluated with the handlers.
- A handler runs before unwinding: it may invoke a restart, or return to decline.

See also: handler-case, restart-case, invoke-restart

## restart-case
### Arguments and values
- `expr`: evaluated with the restarts.
- `clauses`: `(name [params] :report "text"? body...)`.
- Returns `expr`'s value, or that of the restart invoked.

### Notes
A restart is a way to continue that the code which knows how offers, and a handler further out chooses, as in Common Lisp (DESIGN §10).

See also: invoke-restart, handler-bind, find-restart

## invoke-restart
### Arguments and values
- `restart`: a restart or its name, a symbol.
- `args`: passed to it.
- Doesn't return: control goes to the restart.

See also: restart-case, find-restart

## find-restart
### Arguments and values
- `name`: a symbol.
- `condition`: optional.
- Returns the innermost active restart with that name, or nil.

See also: compute-restarts, invoke-restart

## compute-restarts
### Arguments and values
- `condition`: optional.
- Returns the active restarts, innermost first.

See also: find-restart, restart-name

## restart-name
### Arguments and values
- `restart`: a restart.
- Returns its name, a symbol.

See also: restart-report

## restart-report
### Arguments and values
- `restart`: a restart.
- Returns its description, a string.

See also: restart-name

## make-condition
### Arguments and values
- `type`: a condition type.
- `initargs`: slot keywords and values.
- Returns the condition, not signaled.

See also: error, defcondition

## defcondition
### Arguments and values
- `type-name`: a symbol.
- `parents`: a vector of condition types; `[condition]` if empty.
- `specs`: an optional docstring, slots `(name :reader f :initform expr)`, and `(:report f)`.

See also: error, handler-case, make-condition

## condition?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a condition, else false.

See also: error?

## error?
### Arguments and values
- `x`: any value.
- Returns true if `x` is a condition of the type `error` or one below it, else false.

See also: condition?

## condition-message
### Arguments and values
- `c`: a condition.
- Returns its message, as its report writes it.

See also: ex-message

## condition-type
### Arguments and values
- `c`: a condition.
- Returns its type.

See also: condition-type-name

## condition-type-name
### Arguments and values
- `type`: a condition type.
- Returns its qualified name, a symbol.

See also: condition-type

## with-open
### Arguments and values
- `bindings`: `[name init ...]`.
- `body`: evaluated with them bound.
- Calls `close` on each, the last first, however the body ends; returns the body's value.

See also: close, try

## arithmetic-error
### Arguments and values
- The error type signaled when an arithmetic operation can't be done, as integer division by zero.

See also: handler-case, error?

## arity-error
### Arguments and values
- The error type signaled when a function is called with the wrong number of arguments.

See also: handler-case, error?

## index-error
### Arguments and values
- The error type signaled when an index is out of bounds.

See also: handler-case, error?

## type-error
### Arguments and values
- The error type signaled when a value has the wrong type for an operation.

See also: handler-case, error?

## unbound-var-error
### Arguments and values
- The error type signaled when a var with no value is used.

See also: handler-case, error?

## namespace-error
### Arguments and values
- The error type signaled when a namespace can't be found or loaded.

See also: handler-case, error?

## not-callable-error
### Arguments and values
- The error type signaled when a value that isn't a function is called.

See also: handler-case, error?

## stack-overflow
### Arguments and values
- The error type signaled when a computation recurses too deeply.

See also: handler-case, error?

## task-cancelled-error
### Arguments and values
- The error type signaled when `deref` is called on a cancelled task.

See also: handler-case, error?

## transient-error
### Arguments and values
- The error type signaled when a transient is used after `persistent!` or from another fiber.

See also: handler-case, error?

## unsupported-operation-error
### Arguments and values
- The error type signaled when a value doesn't support an operation.

See also: handler-case, error?
