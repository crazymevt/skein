The Swank server SLIME connects to (DESIGN §15). `skein dev` starts it on localhost:4005; in Emacs, `M-x slime-connect` connects. Everything SLIME offers reads the compiler's model of the running program, so it sees the code as it is now, reloads included.

## start-server
### Arguments and values
- `port`: a port on localhost; 0 for any free one.
- Returns the server, or nil if it can't listen there.

### Notes
`skein dev` starts it on port 4005 (`--swank-port N` changes it, `--no-swank` turns it off); connect Emacs with `M-x slime-connect`. SLIME's REPL, debugger (SLDB), inspector, completion, argument lists, documentation and `M-.` work, reading the compiler's model of the program.

See also: skein.dev/run-main, skein.net/port, skein.net/close-server

## protocol-version
### Arguments and values
- The Swank protocol version `connection-info` reports, a string.

See also: start-server

## *thread*
### Arguments and values
- A dynamic var: the Swank thread this fiber is, `{:id n :inbox channel}`, or nil until it needs one.

See also: *sldb*

## *sldb*
### Arguments and values
- A dynamic var: the debugger level this fiber is in, `{:level :condition :restarts :frames}`, or nil.

See also: *thread*, skein.dev/debugger-restarts

## *pending*
### Arguments and values
- A dynamic var: the ids of the requests this fiber is answering, outermost first.

See also: *thread*

