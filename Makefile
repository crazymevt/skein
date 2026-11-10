# Phase 0 build commands. See CLAUDE.md §8.

SBCL ?= sbcl
SBCL_BATCH = $(SBCL) --noinform --no-userinit --non-interactive
ZIG ?= zig

.PHONY: test test-host test-runtime test-compiler compiler repl bench sdl3-bindings

# The host (Phase 0, SBCL), the native runtime (Phase 1, Zig 0.17.1) and the native
# compiler.
test: test-host test-runtime test-compiler

test-host:
	$(SBCL_BATCH) --load host/tools/run-tests.lisp

test-runtime:
	@command -v $(ZIG) >/dev/null || { echo "zig not found: install Zig 0.17.1 (see README)"; exit 1; }
	cd runtime && $(ZIG) build test --summary all

repl:
	$(SBCL) --load host/tools/repl.lisp

# The native compiler, skeinc (M1.9, D-063): host/tools/bootstrap.sh builds it (Phase 0
# builds a first compiler, which builds build/skeinc), and test-compiler checks that it
# rebuilds itself to the same C and builds every example correctly. bash runs it, because
# make runs recipes with cmd.exe on Windows.
compiler:
	bash host/tools/bootstrap.sh compiler

test-compiler:
	bash host/tools/bootstrap.sh test

bench:
	$(SBCL_BATCH) --load bench/collections.lisp
	$(SBCL_BATCH) --load bench/nbody/compare.lisp
	$(SBCL_BATCH) --load bench/nbody/native.lisp
	$(SBCL_BATCH) --load bench/nbody/eval.lisp

# Regenerate lib/sdl3/raw.skn from the installed SDL3 headers (needs clang). Set
# SDL3_INCLUDE to the directory that holds SDL3/SDL.h.
SDL3_INCLUDE ?= /opt/homebrew/include
SDL3_HEADERS = init error hints timer rect pixels blendmode surface video render events \
               keyboard keycode scancode mouse
SDL3_BLOCKING = SDL_Init SDL_InitSubSystem SDL_Quit SDL_QuitSubSystem SDL_CreateWindow \
                SDL_CreateRenderer SDL_CreateWindowAndRenderer SDL_DestroyWindow \
                SDL_DestroyRenderer SDL_ShowWindow SDL_HideWindow SDL_SetWindowFullscreen \
                SDL_SyncWindow SDL_PumpEvents SDL_PollEvent SDL_WaitEvent SDL_WaitEventTimeout \
                SDL_Delay SDL_DelayNS SDL_DelayPrecise SDL_RenderPresent SDL_RenderReadPixels

sdl3-bindings:
	./skein bindgen $(foreach h,$(SDL3_HEADERS),$(SDL3_INCLUDE)/SDL3/SDL_$(h).h) \
	  -I $(SDL3_INCLUDE) --prefix SDL_ --ns sdl3.raw --library sdl3 \
	  --lib macos=libSDL3.dylib --lib linux=libSDL3.so.0 --lib windows=SDL3.dll \
	  $(foreach f,$(SDL3_BLOCKING),--blocking $(f)) --out lib/sdl3/raw.skn
