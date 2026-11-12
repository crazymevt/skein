Require it with an alias:

```skein
(ns my.game
  (:require [skein.system :as system]))

(system/config-dir "my-game")
```

The directories follow each platform's conventions (D-107), so a program keeps its files where users and backup tools expect them.

## os
### Arguments and values
- Returns `:macos`, `:linux` or `:windows`, the keys `deflibrary` takes.

See also: arch, skein.ffi/deflibrary

## arch
### Arguments and values
- Returns `:aarch64` or `:x86_64`, as Zig names them in target triples.

See also: os

## getenv
### Arguments and values
- `name`: a variable's name.
- Returns its value, a string, or nil if it isn't set.

See also: home-dir, skein.process/process

## home-dir
### Arguments and values
- Returns the user's home directory: `HOME`, or `USERPROFILE` on Windows.

See also: config-dir, getenv

## config-dir
### Arguments and values
- `app`: the application's name, a directory name.
- Returns where it keeps its settings: `~/Library/Application Support/app` on macOS, `%APPDATA%\app` on Windows, `$XDG_CONFIG_HOME/app` (`~/.config/app`) on Linux.

### Notes
The directory may not exist yet; make it with `skein.io/make-dirs` before writing. On macOS settings and data share a directory, as the platform's convention has it.

See also: data-dir, cache-dir, skein.io/make-dirs

## data-dir
### Arguments and values
- `app`: the application's name, a directory name.
- Returns where it keeps its data: as `config-dir` on macOS and Windows, `$XDG_DATA_HOME/app` (`~/.local/share/app`) on Linux.

See also: config-dir, cache-dir

## cache-dir
### Arguments and values
- `app`: the application's name, a directory name.
- Returns where it keeps caches, which may be deleted: `~/Library/Caches/app` on macOS, `%LOCALAPPDATA%\app` on Windows, `$XDG_CACHE_HOME/app` (`~/.cache/app`) on Linux.

See also: data-dir

## open!
### Arguments and values
- `target`: a file's path, or a URL (`http:`, `mailto:` and the like).
- Opens it in its default application without waiting for it: `open` on macOS, `xdg-open` on Linux, ShellExecute on Windows.
- Returns nil; a missing file, or an opener that can't start, is an error.

See also: skein.process/process

