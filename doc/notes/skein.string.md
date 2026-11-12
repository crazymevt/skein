Require it with an alias, as Clojure's `clojure.string` usually is:

```skein
(ns my.app
  (:require [skein.string :as str]))
```

Strings are immutable UTF-8 text (DESIGN §6.5). `count` and `nth` on a string count
characters, so `nth` takes O(n) time where the text isn't ASCII; cursors walk a string in
O(1) a step. The functions that search (`index-of`, `split`, `replace`) take strings or
characters, and `split`, `replace` and `replace-first` also take regular expressions
(`#"..."`, D-105), which `re-find`, `re-seq` and `re-matches` in `skein.core` use too.

## append!
### Arguments and values
- `b`: a builder, from `builder`.
- `xs`: any values; each is added as `str` prints it, so `nil` adds nothing.
- Returns `b`, so calls can be chained with `->`.

See also: builder, build

## blank?
### Arguments and values
- `s`: a string, or nil.
- Returns true or false.

### Notes
Whitespace is spaces, tabs, newlines and carriage returns.

See also: trim, empty?

## build
### Arguments and values
- `b`: a builder.
- Returns a new string. The builder can go on taking text afterwards.

See also: builder, append!, str

## builder
### Arguments and values
- Returns a new, empty string builder.

### Notes
A builder is mutable: use it inside one function, as a loop's accumulator, rather than
sharing it. For a few pieces `str` is simpler; a builder is worth it when a loop would
otherwise build a new string each time round.

See also: append!, build, join

## capitalize
### Arguments and values
- `s`: a string.
- Returns a string.

See also: upper-case, lower-case

## char-at
### Arguments and values
- `s`: a string.
- `c`: a cursor of `s`.
- Returns a character, or nil if `c` is at the end.

See also: cursor, next, nth

## cursor
### Arguments and values
- `s`: a string.
- `i`: an index, from 0 to `(count s)`.
- Returns a cursor: with no index the one at the start of `s`.

### Notes
Cursors are opaque: compare them with `=`, and only use a cursor with the string it came
from. Natively a cursor is a byte offset, so `(cursor s i)` takes O(i) time where the
text isn't ASCII; walking with `next` is O(1) a step.

See also: end, next, char-at, slice, cursor->index

## cursor->index
### Arguments and values
- `s`: a string.
- `c`: a cursor of `s`.
- Returns the index of the character at `c`, an integer.

See also: cursor

## end
### Arguments and values
- `s`: a string.
- Returns the cursor after the last character of `s`.

See also: end?, cursor, slice

## end?
### Arguments and values
- `s`: a string.
- `c`: a cursor of `s`.
- Returns true or false.

See also: end, next

## ends-with?
### Arguments and values
- `s`: a string.
- `suffix`: a string.
- Returns true or false.

See also: starts-with?, includes?

## escape
### Arguments and values
- `s`: a string.
- `cmap`: a map (or any function of a character) from characters to what replaces them;
  the replacement is added as `str` prints it.
- Returns a string.

See also: replace

## includes?
### Arguments and values
- `s`: a string.
- `part`: a string or a character.
- Returns true or false.

See also: index-of, starts-with?, ends-with?, re-find

## index-of
### Arguments and values
- `s`: a string.
- `part`: a string or a character.
- `from`: an index to search from; 0 if not given.
- Returns an index, or nil if `part` isn't in `s`.

See also: last-index-of, includes?, re-find

## join
### Arguments and values
- `separator`: put between the elements, as `str` prints it; none if not given.
- `coll`: a collection, whose elements are added as `str` prints them.
- Returns a string.

See also: split, interpose, str

## last-index-of
### Arguments and values
- `s`: a string.
- `part`: a string or a character.
- Returns an index, or nil.

See also: index-of

## lower-case
### Arguments and values
- `s`: a string.
- Returns a string.

### Notes
Only the ASCII letters A to Z change; other letters stay as they are.

See also: upper-case, capitalize

## next
### Arguments and values
- `s`: a string.
- `c`: a cursor of `s`.
- Returns the cursor after the character at `c`, or `c` itself at the end.

See also: cursor, char-at, end?

## replace
### Arguments and values
- `s`: a string.
- `match`: a string, a character or a pattern.
- `replacement`: a string; with a pattern, also a function of the match.
- Returns a string.

### Notes
With a pattern, the replacement string is a template: `$1` is the first group, `${name}`
a named group and `\$` a dollar sign. A function gets the match as `re-find` gives it: a
string when the pattern has no groups, else a vector of the whole match and the groups.

See also: replace-first, escape, re-seq

## replace-first
### Arguments and values
As `replace`'s.

See also: replace

## reverse
### Arguments and values
- `s`: a string.
- Returns a string with its characters (not its bytes) reversed.

See also: skein.core/reverse

## slice
### Arguments and values
- `s`: a string.
- `from`: a cursor of `s`.
- `to`: a cursor of `s`, at or after `from`; the end if not given.
- Returns a string.

### Notes
`subs` takes indexes instead of cursors.

See also: cursor, end, subs

## split
### Arguments and values
- `s`: a string.
- `separator`: a string, a character or a pattern.
- `limit`: the most parts to return, a positive integer.
- Returns a vector of strings.

See also: split-lines, join, re-seq

## split-lines
### Arguments and values
- `s`: a string.
- Returns a vector of strings, without their line endings.

See also: split, skein.io/line-seq

## starts-with?
### Arguments and values
- `s`: a string.
- `prefix`: a string.
- Returns true or false.

See also: ends-with?, includes?

## trim
### Arguments and values
- `s`: a string.
- Returns a string.

See also: triml, trimr, trim-newline, blank?

## trim-newline
### Arguments and values
- `s`: a string.
- Returns a string.

See also: trim, trimr, split-lines

## triml
### Arguments and values
- `s`: a string.
- Returns a string.

See also: trim, trimr

## trimr
### Arguments and values
- `s`: a string.
- Returns a string.

See also: trim, triml, trim-newline

## upper-case
### Arguments and values
- `s`: a string.
- Returns a string.

### Notes
Only the ASCII letters a to z change; other letters stay as they are.

See also: lower-case, capitalize
