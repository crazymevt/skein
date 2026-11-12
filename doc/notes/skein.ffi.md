Calling C (DESIGN §14). Require it with an alias, and describe the library declaratively:

```skein
(ns sdl3.raw
  (:require [skein.ffi :as ffi]))

(ffi/deflibrary sdl3
  {:macos "libSDL3.dylib" :linux ["libSDL3.so.0"] :windows "SDL3.dll"})

(ffi/defcfun init "SDL_Init" bool [flags u32])
```

The memory functions (`alloc`, `get`, `put!`, `field`...) work anywhere; declaring C functions and callbacks needs the program compiled by `skeinc`, so the examples that call C are shown here without being run. `./skein bindgen` writes the declarations from C headers.

## deflibrary
### Arguments and values
- `lib-name`: a symbol, bound to the file that loaded.
- `spec`: a map from `:macos`, `:linux` and `:windows` to a file name, or a vector of names to try in order.

### Notes
Libraries are found next to the program, then in `SKEIN_LIBRARY_PATH`, then where the system looks. `skein package` copies a project's own libraries beside the program.

See also: load-library, defcfun

## load-library
### Arguments and values
- `spec`: a map from `:macos`, `:linux` and `:windows` to a file name, or a vector of names to try in order.
- Returns the name that loaded.

See also: deflibrary

## defcfun
### Arguments and values
- `fn-name`: the Skein name, a symbol; `^:blocking` for a call that may wait, so its thread is handed back to the scheduler.
- `c-name`: the C function's name, a string.
- `return-type`: a foreign type; `^:owned (ptr T)` when C hands over memory Skein must free.
- `params`: `[name type ...]`; `&` before the arguments of a variadic function's `...`, one shape of call.

### Notes
A program that declares C functions is compiled by `skeinc`; the evaluator can't define one at run time. `./skein bindgen` writes these forms from C headers.

See also: defcallback, defcfun-ptr, deflibrary

## defcfun-ptr
### Arguments and values
- `fn-name`: a symbol.
- `return-type`, `params`: as `defcfun`'s.
- Defines a function whose first argument is the C function pointer to call.

See also: defcfun

## defcallback
### Arguments and values
- `cb-name`: a symbol, bound to a C function pointer.
- `return-type`: a foreign type.
- `params`: `[name type ...]`.
- `body`: the Skein code C calls.

### Notes
An error in a callback can't unwind through C: it warns and the callback returns zero. A callback from a C thread runs as a fiber while that thread waits.

See also: defcfun

## defcstruct
### Arguments and values
- `struct-name`: a symbol.
- `fields`: `(name type)`; a type may be another struct (stored inline) or `(array T n)`.
- Lays it out as C does.

See also: field, put-field!, alloc, sizeof, defcunion

## defcunion
### Arguments and values
- `union-name`: a symbol.
- `fields`: as `defcstruct`'s, all at the same address.

See also: defcstruct

## defcenum
### Arguments and values
- `enum-name`: a symbol.
- `specs`: an optional base type (`i32` by default), then `(:key value)` pairs.
- As a parameter type, it takes a key, a collection of keys ORed together, or an integer.

See also: enum-value

## enum-value
### Arguments and values
- `enum`: an enum.
- `x`: a key, a collection of keys, or an integer.
- Returns the integer.

See also: defcenum

## alloc
### Arguments and values
- `type`: a foreign type: a primitive (`u8`, `i32`, `f32`, `f64`...), `ptr`, `(ptr T)`, `c-string`, or a struct, union or enum described here.
- `n`: how many; 1 if not given.
- Returns a pointer to zeroed C memory.

See also: free, with-foreign, own, get

## free
### Arguments and values
- `p`: a pointer. from `alloc` or C's allocator, freed now.
- Returns nil.

See also: alloc, own, with-foreign

## own
### Arguments and values
- `p`: a pointer.
- Returns it, to be freed when the collector finds it unreachable (unless freed first).

See also: free, alloc

## with-foreign
### Arguments and values
- `[ptr-name init]`: a name and C memory from `alloc`.
- `body`: evaluated with it bound; the memory is freed when it ends.
- Returns the body's value.

See also: alloc, free, with-open

## get
### Arguments and values
- `p`: a pointer.
- `type`: a foreign type: a primitive (`u8`, `i32`, `f32`, `f64`...), `ptr`, `(ptr T)`, `c-string`, or a struct, union or enum described here.
- `index`: the element to read, 0 if not given.
- Returns the value.

See also: put!, field

## put!
### Arguments and values
- `p`: a pointer.
- `type`: a foreign type: a primitive (`u8`, `i32`, `f32`, `f64`...), `ptr`, `(ptr T)`, `c-string`, or a struct, union or enum described here.
- `value`: written as the type.
- `index`: the element, 0 if not given.

See also: get, put-field!

## field
### Arguments and values
- `p`: a pointer. to a struct or union.
- `type`: its description.
- `key`: the field's keyword.
- Returns the field's value, or the address of a field that is itself a struct or array.

See also: put-field!, defcstruct

## put-field!
### Arguments and values
- `p`: a pointer. to a struct or union.
- `type`: its description.
- `key`: the field.
- `value`: its new value.

See also: field

## sizeof
### Arguments and values
- `type`: a foreign type: a primitive (`u8`, `i32`, `f32`, `f64`...), `ptr`, `(ptr T)`, `c-string`, or a struct, union or enum described here.
- Returns its size in bytes, as C lays it out.

See also: alloc

## ptr+
### Arguments and values
- `p`: a pointer.
- `n`: a number of bytes, positive or negative.
- Returns the moved pointer.

See also: address, get

## address
### Arguments and values
- `p`: a pointer.
- Returns its address, an integer.

See also: ptr+

## ptr?
### Arguments and values
- `x`: any value.
- Returns true if it is a C pointer.

See also: null?

## null
### Arguments and values
- Returns the C null pointer.

See also: null?

## null?
### Arguments and values
- `p`: a pointer or nil.
- Returns true for the null pointer and nil (C's NULL arrives as nil).

See also: null, ptr?

## c-string
### Arguments and values
- `p`: a pointer. to NUL-terminated UTF-8.
- Returns the string.

See also: defcfun

## pin
### Arguments and values
- `[ptr-name arr]`: a name and a Skein array (or view).
- `body`: evaluated with the name bound to the array's address, the array kept in place.
- Returns the body's value.

### Notes
Passing an array straight to a C function pins it for the call; `pin` is for when C keeps the address longer.

See also: as-bytes, view

## handle
### Arguments and values
- `x`: any Skein value.
- Returns a stable integer token for it, which C can hold and give back; the value stays alive until `free-handle`.

### Notes
Give C a handle, not a pointer to a Skein object, since the collector may move or free objects.

See also: handle-value, free-handle

## handle-value
### Arguments and values
- `h`: a handle.
- Returns the value it stands for.

See also: handle

## free-handle
### Arguments and values
- `h`: a handle.
- Releases it, so its value can be collected. Returns nil.

See also: handle

