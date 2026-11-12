TCP sockets. Require it with an alias, with `skein.io` to read and write:

```skein
(ns my.server
  (:require [skein.net :as net]
            [skein.io :as io]))
```

A socket is a `skein.io` stream both ways: `read-line`, `line-seq`, `read-text`, `read-bytes!`, `write`, `write-bytes!`, `flush`, `close` and `with-open` take it. Waiting to connect, accept or read parks the fiber, not a thread, so a server can serve many clients each in a fiber of its own. Native only.

## connect
### Arguments and values
- `host`: a name to look up, or an IP address.
- `port`: a port number.
- `opts`: `:timeout`, the seconds to wait for the connection; :read-timeout`: the seconds each read of the socket waits; for ever if not given.
- Returns a socket, a `skein.io` stream both ways; a failure is an `io-error`.

See also: listen, skein.io/read-line, skein.io/write, shutdown

## listen
### Arguments and values
- `port`: a port number, or 0 for any free one (`port` tells which).
- `opts`: `:host`, the address to listen on: `"localhost"` if not given, `"0.0.0.0"` for every interface.
- Returns a server; a failure is an `io-error`.

### Notes
Listening on localhost only is the safe default: other machines can't connect unless `:host` says so.

See also: accept, port, close-server, connect

## accept
### Arguments and values
- `server`: from `listen`.
- `opts`: `:read-timeout`: the seconds each read of the socket waits; for ever if not given.
- Returns the next connection, a socket, waiting for one (parking the fiber); nil once the server is closed.

### Notes
Serve each connection in a fiber of its own (`future`, or `spawn` in a nursery), so the loop goes back to `accept` at once.

See also: listen, close-server

## port
### Arguments and values
- `server`: a server.
- Returns the port it listens on.

See also: listen

## close-server
### Arguments and values
- `server`: a server.
- Stops it listening; an `accept` waiting on it returns nil. `close` and `with-open` do the same.
- Returns nil.

See also: listen, accept

## shutdown
### Arguments and values
- `s`: a socket.
- Ends its connection both ways: a read waiting in another fiber gets the end, and the other side reads the end. Close it afterwards in the fiber that reads.
- Returns nil.

See also: close, connect

## socket?
### Arguments and values
- `x`: any value.
- Returns true if it is a socket.

See also: connect, accept

## server
### Arguments and values
- The class of what `listen` returns.

See also: listen

## net-timeout
### Arguments and values
- The error type a connect or read that runs out of time signals; a kind of `skein.io/io-error`.

See also: connect, accept, skein.io/io-error

