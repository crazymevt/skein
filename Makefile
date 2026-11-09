# Phase 0 build commands. See CLAUDE.md §8.

SBCL ?= sbcl
SBCL_BATCH = $(SBCL) --noinform --no-userinit --non-interactive

.PHONY: test repl bench

test:
	$(SBCL_BATCH) --load host/tools/run-tests.lisp

repl:
	$(SBCL) --load host/tools/repl.lisp

bench:
	$(SBCL_BATCH) --load bench/collections.lisp
	$(SBCL_BATCH) --load bench/nbody/compare.lisp
