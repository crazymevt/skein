Require it with an alias, as Clojure's clojure.data.json:

```skein
(ns my.app
  (:require [skein.json :as json]))

(json/read-str (slurp "settings.json") :key-fn keyword)
```

Native only. For Skein's own data format, EDN, use `skein.edn`.

## read-str
### Arguments and values
- `s`: JSON text.
- `:key-fn`: called with each object key, a string; `keyword` makes keywords.
- `:value-fn`: called with each key (as `:key-fn` made it) and value; its result is the value, and returning the function itself leaves the entry out.
- Options come as keyword arguments or one map.
- Returns the data: objects as maps, arrays as vectors, numbers as integers or f64s, `null` as nil.

### Notes
Text that isn't JSON, or more than one value, signals `json-error` with the line and column.

See also: read, write-str, json-error, skein.edn/read-string

## read
### Arguments and values
- `r`: a `skein.io` reader.
- `:eof-error?`: true (the default) signals `json-error` at the end of the stream; false returns `:eof-value` (nil).
- Options as `read-str`'s.
- Returns the next value, read a line at a time until the lines hold a whole value.

### Notes
One value a line is JSON Lines, as Claude Code's stream-json gives it from a process's `:out`; a value may also span lines, but a line holds at most one.

See also: read-str, skein.io/open-reader, skein.process/process

## write-str
### Arguments and values
- `x`: nil, booleans, numbers, strings, keywords, symbols and characters (as strings), maps (as objects) and other collections (as arrays).
- `:pretty`: indent by two spaces.
- `:escape-unicode`: write characters past ASCII as `\u` escapes.
- `:key-fn`: gives each key's string; by default a keyword's or symbol's name, without its namespace.
- `:value-fn`: as `read-str`'s.
- Returns JSON text.

See also: write, reformat, read-str

## write
### Arguments and values
- `x`: as `write-str`'s.
- `w`: a `skein.io` writer.
- Options as `write-str`'s.
- Returns nil.

See also: write-str, read

## reformat
### Arguments and values
- `s`: JSON text.
- `opts`: `{:indent n}`, the spaces a level (2); 0 for one line.
- Returns the text re-indented, with its keys in their order and its strings and numbers as written.

### Notes
Unlike reading and writing it again, this keeps a large object's key order (maps keep it only up to 8 keys) and numbers such as `1.50`.

See also: write-str

## json-error
### Arguments and values
- The error type signaled for text that isn't JSON.

See also: json-error-message, json-error-line, read-str

## json-error-message
### Arguments and values
- `c`: a `json-error`.
- Returns its message.

See also: json-error

## json-error-line
### Arguments and values
- `c`: a `json-error`.
- Returns the line where the text went wrong, from 1, or nil when it ended too soon.

See also: json-error-column

## json-error-column
### Arguments and values
- `c`: a `json-error`.
- Returns the column, from 1, or nil.

See also: json-error-line

