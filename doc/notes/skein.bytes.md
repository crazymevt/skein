Require it with an alias:

```skein
(ns my.app
  (:require [skein.bytes :as b]))

(b/hex (b/sha256 (slurp "asset.png")))
```

Bytes are `u8` arrays. Wherever bytes are taken, a string stands for its UTF-8 and a byte view (`view`, `as-bytes`) works too. Native only.

## utf8
### Arguments and values
- `s`: a string.
- Returns its UTF-8, a `u8` array.

See also: utf8-string, hex

## utf8-string
### Arguments and values
- `a`: a `u8` array or byte view.
- Returns the string whose UTF-8 it is; an error if it isn't UTF-8.

See also: utf8, unbase64

## base64
### Arguments and values
- `x`: bytes: a `u8` array or byte view, or a string, which stands for its UTF-8.
- Returns its standard base64 (RFC 4648), padded with `=`.

See also: unbase64, hex

## unbase64
### Arguments and values
- `s`: base64 text.
- Returns the bytes, a `u8` array; an error if `s` isn't base64.

See also: base64, utf8-string

## hex
### Arguments and values
- `x`: bytes: a `u8` array or byte view, or a string, which stands for its UTF-8.
- Returns it as lowercase hex, two digits a byte.

See also: unhex, sha256

## unhex
### Arguments and values
- `s`: hex text, in either case, two digits a byte.
- Returns the bytes; an error if `s` isn't hex.

See also: hex

## sha256
### Arguments and values
- `x`: bytes: a `u8` array or byte view, or a string, which stands for its UTF-8.
- Returns its SHA-256 digest, 32 bytes.

See also: sha1, md5, hex

## sha1
### Arguments and values
- `x`: bytes: a `u8` array or byte view, or a string, which stands for its UTF-8.
- Returns its SHA-1 digest, 20 bytes.

See also: sha256, hex

## md5
### Arguments and values
- `x`: bytes: a `u8` array or byte view, or a string, which stands for its UTF-8.
- Returns its MD5 digest, 16 bytes.

### Notes
MD5 is broken for security; use it only for checksums and cache keys, and SHA-256 where it matters.

See also: sha256, hex

