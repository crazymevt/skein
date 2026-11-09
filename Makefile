# Phase 0 build commands. See CLAUDE.md §8.

SBCL ?= sbcl
SBCL_BATCH = $(SBCL) --noinform --no-userinit --non-interactive

.PHONY: test repl bench sdl3-bindings

test:
	$(SBCL_BATCH) --load host/tools/run-tests.lisp

repl:
	$(SBCL) --load host/tools/repl.lisp

bench:
	$(SBCL_BATCH) --load bench/collections.lisp
	$(SBCL_BATCH) --load bench/nbody/compare.lisp

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
