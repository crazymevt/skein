Game-loop helpers. `run-loop` runs a fixed-timestep loop, and every frame runs with restarts, so an error in a frame can be fixed while the game is paused in `skein dev`'s debugger (DESIGN §10, §15).

```skein
(ns my.game
  (:require [skein.game :as game]))
```

## run-loop
### Arguments and values
- `:frame`: `(fn [])`, called first each frame, as for input events.
- `:update`: `(fn [dt])`, called at a fixed rate, `dt` being `:step` seconds.
- `:render`: `(fn [alpha])`, called once a frame after the updates; `alpha`, from 0 to 1, is how far the clock is into the next step, for interpolating positions.
- `:step`: the fixed timestep, 1/60 by default.
- `:max-steps`: the most updates in one frame, 5 by default, so a slow frame or a pause in the debugger doesn't make the game race to catch up.
- `:running?`: `(fn [])`; the loop goes on while it is true.
- `:paused`: `(fn [])`, called about 60 times a second while a frame waits in `skein dev`'s debugger, to keep the window alive.
- Returns nil when the loop ends.

### Notes
Each call of `:frame`, `:update` and `:render` runs with the `retry-frame` and `skip-frame` restarts, so in `skein dev` an error pauses the game in the debugger, where you can fix the code, reload it and run the frame again.

See also: with-frame-restarts, skein.time/now

## with-frame-restarts
### Arguments and values
- `body`: one frame's work.
- Runs it with two restarts: `retry-frame`, which runs it again from the start, and `skip-frame`, which gives up on it.
- Returns the body's value, or nil if the frame was skipped.

See also: run-loop, restart-case, invoke-restart

