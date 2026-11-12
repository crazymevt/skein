Require it with an alias:

```skein
(ns my.game
  (:require [skein.time :as time]))
```

Two kinds of clock: `now` and `now-ns` are monotonic, for durations and frame times; `epoch-millis` is the wall clock, for timestamps. Calendar times are maps, which `format-iso8601` and `parse-iso8601` write and read as ISO 8601 text. `sleep` is in `skein.core`.

## now
### Arguments and values
- Returns seconds since the program started, an f64, from a monotonic clock.

### Notes
Use it to measure durations and frame times: it never jumps when the system's clock is set, unlike `epoch-millis`.

See also: now-ns, epoch-millis, sleep, time

## now-ns
### Arguments and values
- Returns the monotonic time in nanoseconds, an integer.

See also: now

## epoch-millis
### Arguments and values
- Returns the wall-clock time, milliseconds since 1970-01-01 UTC, an integer.

See also: utc-time, now, skein.io/modified-time

## utc-offset
### Arguments and values
- `millis`: milliseconds since 1970 (UTC); now if not given.
- Returns the local time zone's offset from UTC then, in seconds east.

See also: local-time

## utc-time
### Arguments and values
- `millis`: milliseconds since 1970 (UTC); now if not given.
- Returns a calendar time: `{:year :month :day :hour :minute :second :millis :weekday :offset}`, months from 1 to 12, weekdays from 1 (Monday) to 7, the offset in seconds east of UTC (0 here).

See also: local-time, format-iso8601

## local-time
### Arguments and values
- `millis`: milliseconds since 1970 (UTC); now if not given.
- Returns a calendar time: `{:year :month :day :hour :minute :second :millis :weekday :offset}`, months from 1 to 12, weekdays from 1 (Monday) to 7, the offset in seconds east of UTC, in the local time zone.

See also: utc-time, utc-offset

## format-iso8601
### Arguments and values
- `t`: milliseconds since 1970 (written in UTC, with `Z`), or a calendar time, written with its `:offset`.
- Returns ISO 8601 text, as `2026-11-12T09:30:00.000-05:00`.

See also: parse-iso8601, utc-time

## parse-iso8601
### Arguments and values
- `s`: ISO 8601 text: a date, or a date and time (`T` or a space between) with optional seconds and fraction, and an offset (`Z`, `+05:30`, `+0530`, `+05`; none means the local zone).
- Returns a calendar time, as `utc-time` gives it; an error for text that isn't one, or a date that doesn't exist.

See also: format-iso8601

