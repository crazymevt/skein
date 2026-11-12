Require it with an alias, as Clojure's clojure.edn:

```skein
(ns my.app
  (:require [skein.edn :as edn]))

(edn/read-string (slurp "settings.edn"))
```

Write EDN with `pr-str` (or `prn`); `skein.edn` reads it back.

## read-string
### Arguments and values
- `opts`: a map, first when given. `:readers`, tag symbols to functions of the tagged value; `:default`, a function of the tag and value for other tags (else a tag is an error); `:eof`, the value at the end of the input.
- `s`: EDN text.
- Returns its first form, as data; `:eof` (nil) if it holds none.

### Notes
EDN is Skein's (and Clojure's) data syntax: maps, vectors, lists, sets, keywords, symbols, strings, characters and numbers. It is read as data and never evaluated, so it is safe for settings and messages, and it works in every build, where `skein.core/read-string` needs `--eval`.

See also: read, skein.core/read-string, pr-str, skein.json/read-str

## read
### Arguments and values
- `opts`: a map, first when given. `:readers`, tag symbols to functions of the tagged value; `:default`, a function of the tag and value for other tags (else a tag is an error); `:eof`, the value at the end of the input.
- `r`: a `skein.io` reader.
- Returns the next form, read a line at a time until the lines hold a whole form; at the end of the stream, `:eof` if given, else an error.

See also: read-string, skein.io/open-reader

