# Phase 0 build commands. See CLAUDE.md §8.

SBCL ?= sbcl
SBCL_BATCH = $(SBCL) --noinform --no-userinit --non-interactive
ZIG ?= zig

.PHONY: test test-host test-runtime test-compiler compiler repl bench sdl3-bindings

# On Windows, make would run recipes with cmd.exe; use bash (Git for Windows) there too.
ifeq ($(OS),Windows_NT)
SHELL := bash
endif

EXE := $(if $(filter Windows_NT,$(OS)),.exe,)
SKEINC = build/skeinc$(EXE)
COMPILER_SOURCES = $(wildcard lib/skein/*.skn lib/skein/*/*.skn) runtime/include/skein.h \
                   $(wildcard runtime/src/*.zig runtime/src/*.c)

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

# The native compiler, skeinc (M1.9, D-063): Phase 0 builds a first compiler, which builds
# skeinc. (The first compiler's output differs from skeinc's only in the numbers of
# gensyms baked into skein.core's macros, D-062.)
compiler: $(SKEINC)

$(SKEINC): $(COMPILER_SOURCES)
	@mkdir -p build
	./skein build lib/skein/compiler/main.skn -o build/skeinc-stage1$(EXE)
	build/skeinc-stage1$(EXE) build lib/skein/compiler/main.skn -o $(SKEINC)

# skeinc rebuilds itself twice and the two builds' C must be identical; then it builds
# every example with an .expected file, and each must print exactly that.
test-compiler: $(SKEINC)
	$(SKEINC) build lib/skein/compiler/main.skn -o build/skeinc-a$(EXE) --keep-c
	build/skeinc-a$(EXE) build lib/skein/compiler/main.skn -o build/skeinc-b$(EXE) --keep-c
	cmp build/skeinc-a.c build/skeinc-b.c
	@mkdir -p build/examples
	@for expected in examples/*.expected; do \
	  name=$$(basename $$expected .expected); \
	  $(SKEINC) build examples/$$name.skn -o build/examples/$$name$(EXE) > /dev/null || exit 1; \
	  build/examples/$$name$(EXE) > build/examples/$$name.out || exit 1; \
	  diff --strip-trailing-cr $$expected build/examples/$$name.out > /dev/null \
	    || { echo "skeinc: $$name differs from $$expected"; exit 1; }; \
	  echo "skeinc: $$name ok"; \
	done

bench:
	$(SBCL_BATCH) --load bench/collections.lisp
	$(SBCL_BATCH) --load bench/nbody/compare.lisp
	$(SBCL_BATCH) --load bench/nbody/native.lisp

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
