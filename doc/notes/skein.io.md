Require it with an alias:

```skein
(ns my.app
  (:require [skein.io :as io]))
```

Paths are strings. The functions accept `/` and `\` as separators and join paths with
`/`, which every OS accepts, so the same code runs on macOS, Linux and Windows. Text is
UTF-8. A failure signals `io-error`, with the path it concerns. Streams are closed with
`close`, usually through `with-open`; `slurp` and `spit` in `skein.core` are shorthands
for `read-file` and `write-file`.

## read-file
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Returns its contents, decoded as UTF-8.

See also: write-file, read-bytes, open-reader, slurp

## write-file
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- `string`: the new contents, written as UTF-8.
- Returns nil.

### Notes
The file is replaced, and made if it's missing; the directory it's in must exist (`make-dirs`).

See also: read-file, append-file, write-bytes, spit

## append-file
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- `string`: added at the end; the file is made if it's missing.
- Returns nil.

See also: write-file, open-writer

## read-bytes
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Returns its bytes, a `u8` array.

See also: write-bytes, open-input, read-file

## write-bytes
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- `data`: a `u8` array, a byte view or a string (its UTF-8 bytes).
- Returns nil.

See also: read-bytes, open-output, write-file

## file-exists?
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Returns true if a file or directory is there.

See also: file?, directory?

## file?
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Returns true if a file (not a directory) is there.

See also: directory?, file-exists?

## directory?
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Returns true if a directory is there.

See also: file?, file-exists?

## file-size
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Returns its size in bytes.

See also: modified-time, file?

## modified-time
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Returns when it last changed, in milliseconds since 1970 (UTC).

See also: file-size, skein.time/epoch-millis

## list-dir
### Arguments and values
- `path`: a directory's path.
- Returns a vector of the names in it, sorted, without `.` and `..`.

See also: walk, directory?

## make-dirs
### Arguments and values
- `path`: a directory's path.
- Makes it and any missing directories above it; nothing if it exists.
- Returns nil.

See also: directory?, temp-dir

## delete
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts. A directory must be empty.
- Returns nil.

See also: delete-tree, rename

## delete-tree
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Deletes it, and everything in it if it's a directory.
- Returns nil.

See also: delete

## copy-file
### Arguments and values
- `from`: a file's path.
- `to`: the copy's path, replaced if it exists.
- Returns nil.

See also: rename

## rename
### Arguments and values
- `from`: a file or directory.
- `to`: its new path.
- Returns nil.

See also: copy-file, delete

## path
### Arguments and values
- `part`, `parts`: strings.
- Returns them joined with `/`, without doubling a separator.

See also: parent, file-name

## file-name
### Arguments and values
- `p`: a path.
- Returns its last part.

See also: parent, extension

## parent
### Arguments and values
- `p`: a path.
- Returns the part before the last, or nil.

See also: file-name, path

## extension
### Arguments and values
- `p`: a path.
- Returns the extension of its file name, without the dot, or nil.

See also: file-name

## absolute?
### Arguments and values
- `p`: a path.
- Returns true if it starts with a separator or a drive.

See also: absolute-path

## absolute-path
### Arguments and values
- `p`: the path of something that exists.
- Returns it made absolute, with symbolic links resolved.

See also: absolute?

## open-reader
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Returns a stream to read its text from, a line at a time.

See also: read-line, line-seq, read-text, with-open

## read-line
### Arguments and values
- `r`: a reader: a file's, a socket's or a process's output.
- Returns the next line without its line ending (`\n` or `\r\n`), or nil at the end.

See also: line-seq, open-reader

## line-seq
### Arguments and values
- `r`: a reader.
- Returns a lazy seq of its remaining lines.

### Notes
Realize the seq (with `mapv`, `doall` or `run!`) before `with-open` closes the reader.

See also: read-line, skein.string/split-lines

## read-text
### Arguments and values
- `r`: a reader.
- Returns the rest of its text.

See also: read-line, read-file

## open-writer
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- `opts`: `{:append true}` writes after what the file holds; otherwise it is replaced.
- Returns a stream to write text to.

See also: write, flush, with-open

## write
### Arguments and values
- `w`: a writer.
- `x`: written as `str` writes it.
- Returns nil.

See also: open-writer, flush

## flush
### Arguments and values
- `s`: a writer, output or socket.
- Writes what it has held back.
- Returns nil.

See also: write, close

## open-input
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Returns a stream to read its bytes from.

See also: read-bytes!, open-reader

## read-bytes!
### Arguments and values
- `in`: an input stream.
- `array`: a `u8` array or byte view to fill.
- `start`: where in it; 0 if not given.
- `n`: how many at most; to its end if not given.
- Returns how many were read, or nil at the end.

See also: open-input, read-bytes

## open-output
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- `opts`: `{:append true}` writes after what the file holds.
- Returns a stream to write bytes to.

See also: write-bytes!, open-writer

## write-bytes!
### Arguments and values
- `out`: an output stream or socket.
- `data`: a `u8` array, byte view or string.
- `start`, `end`: the range of its bytes; all if not given.
- Returns nil.

See also: open-output, write-bytes

## stream
### Arguments and values
- The class of open files (`:reader`, `:writer`, `:input`, `:output`) and sockets.

See also: stream-path, close

## stream-path
### Arguments and values
- `s`: a stream.
- Returns the path of its file, or nil for a socket or pipe.

See also: stream

## io-error
### Arguments and values
- The error type signaled when a file can't be read or written, or a program can't be started.

See also: io-error-message, io-error-path, handler-case

## io-error-message
### Arguments and values
- `c`: an `io-error`.
- Returns its message.

See also: io-error, condition-message

## io-error-path
### Arguments and values
- `c`: an `io-error`.
- Returns the path it concerns, or nil.

See also: io-error

## run-process
### Arguments and values
- `argv`: a vector of the program, found on the `PATH`, and its arguments.
- `opts`: `{:dir path}`, the directory to run it in.
- Returns `{:exit code :out text :err text}` once it has ended.

### Notes
No shell is involved, so arguments need no quoting and `*` isn't expanded. To talk to a program while it runs, use `skein.process`.

See also: skein.process/process

## resource-dir
### Arguments and values
- Returns the directory holding the program's assets, ending with `/`.

### Notes
A packaged program finds its `:assets` beside itself (in `Contents/Resources` in a macOS app); run from source, it is the directory of the nearest `project.skn` at or above the main file.

See also: read-file, path

## walk
### Arguments and values
- `root`: a directory's path.
- `opts`: `:gitignore` (true) applies Git's ignore rules; `:hidden` (false) includes names starting with a dot; `:dirs` (true) includes directories.
- Returns a lazy seq of paths, `root` joined with each, by name, a directory before its contents.

### Notes
Symbolic links aren't followed, and `.git` is always skipped.

See also: list-dir, ignore-matcher, watch

## ignore-matcher
### Arguments and values
- `root`: a directory's path.
- Returns a matcher of Git's ignore rules there: every `.gitignore` under it, read as needed, and `.git/info/exclude`.

See also: ignored?, walk

## ignored?
### Arguments and values
- `m`: a matcher.
- `p`: a path, relative to the matcher's root or under it.
- `dir?`: whether it is a directory; the file system is asked if not given.
- Returns true if the rules ignore it or a directory it's in.

See also: ignore-matcher

## watch
### Arguments and values
- `root`: a directory's path.
- `opts`: `:gitignore` (true) drops ignored paths; `:buffer` (1024) the channel's size.
- Returns a watcher, whose `:events` channel gives `{:kind :created|:modified|:deleted :path p}`.

### Notes
Events are hints: they can repeat or merge, and when the system loses some an event says `root` is `:modified`, so look again. Native only.

See also: stop-watch!, walk

## stop-watch!
### Arguments and values
- `w`: a watcher.
- Stops it; its channel closes once the events reported are taken.
- Returns nil.

See also: watch

## temp-file
### Arguments and values
- `prefix`: `"skein"` if not given.
- `suffix`: `""` if not given.
- Returns the path of a new, empty file only you may use (mode 600).

See also: temp-dir, delete

## temp-dir
### Arguments and values
- `prefix`: optional.
- Returns the path of a new, empty directory only you may use (mode 700).

See also: temp-file, delete-tree

## owner-only!
### Arguments and values
- `path`: a file's path; `/` or `\` separate its parts.
- Lets only its owner use it (mode 600, or 700 for a directory); nothing on Windows.
- Returns nil.

See also: temp-file

