Require it with an alias:

```skein
(ns my.game
  (:require [skein.log :as log]))

(log/info "loaded" (count levels) "levels")
```

The levels, lowest first, are `:trace`, `:debug`, `:info`, `:warn` and `:error`; `:info` is the starting level. The logging functions are macros, so an entry below the level costs nothing: its arguments aren't evaluated. Each entry records the namespace it came from.

## trace
### Arguments and values
- `xs`: any values, joined with spaces: strings and characters as they are, the rest as `pr` prints them; evaluated only if the level is enabled.
- Logs them at `:trace`. Returns nil.

See also: debug, set-level!

## debug
### Arguments and values
- `xs`: any values, joined with spaces: strings and characters as they are, the rest as `pr` prints them; evaluated only if the level is enabled.
- Logs them at `:debug`. Returns nil.

See also: trace, info, set-level!

## info
### Arguments and values
- `xs`: any values, joined with spaces: strings and characters as they are, the rest as `pr` prints them; evaluated only if the level is enabled.
- Logs them at `:info`. Returns nil.

See also: warn, debug, log

## warn
### Arguments and values
- `xs`: any values, joined with spaces: strings and characters as they are, the rest as `pr` prints them; evaluated only if the level is enabled.
- Logs them at `:warn`. Returns nil.

See also: error, info

## error
### Arguments and values
- `xs`: any values, joined with spaces: strings and characters as they are, the rest as `pr` prints them; evaluated only if the level is enabled.
- Logs them at `:error`. Returns nil.

See also: warn, skein.core/error

## log
### Arguments and values
- `level`: `:trace`, `:debug`, `:info`, `:warn` or `:error`, evaluated.
- `xs`: any values, joined with spaces: strings and characters as they are, the rest as `pr` prints them; evaluated only if the level is enabled.
- Returns nil.

See also: info, log*

## log*
### Arguments and values
- `level`: a level.
- `ns-name`: the namespace's name, a string.
- `xs`: a sequence of values.
- Logs the entry if the level is enabled. Returns nil.

See also: log

## set-level!
### Arguments and values
- `level`: the lowest level to log.
- Returns nil.

See also: level, enabled?

## level
### Arguments and values
- Returns the current level, `:info` at first.

See also: set-level!

## enabled?
### Arguments and values
- `level`: a level.
- Returns true if an entry at it would be logged.

See also: set-level!

## set-handler!
### Arguments and values
- `f`: a function of an entry, `{:level :time :ns :message}` (`:time` in milliseconds since 1970); nil restores the default, which writes a line to stderr.
- Returns nil.

### Notes
A handler can write to a file, keep the last entries for a console, or send them elsewhere; `format-entry` gives the default's line.

See also: format-entry, info

## format-entry
### Arguments and values
- `entry`: `{:level :time :ns :message}`.
- Returns the line the default handler writes, without its newline.

See also: set-handler!, format-time

## format-time
### Arguments and values
- `t`: milliseconds since 1970.
- Returns it as UTC in ISO 8601, with milliseconds.

See also: skein.time/format-iso8601

