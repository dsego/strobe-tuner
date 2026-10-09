# Sandbox

Experiments and the tools that measure the tuner, each folder a program of its own. Nothing here ships.

Kept up with the app, the justfile runs them:

- `accuracy`, `just accuracy`: generated tones through the tuner, checks the note and the readout.
- `recordings`, `just recordings`: your recordings shifted by known cents through the tuner. They go in `sandbox/samples`, which isn't in the repo.

Still build against the app's core, run with `odin run sandbox/<folder>`:

- `replay`: a recording through the pitch detection, what it makes of it over time.
- `hmm`: a hidden Markov model over the NSDF peaks next to the tuner's rules, scored on a recording.
- `lamp_jitter`: the tracks turned by the lock-in against the ones turned by the lamp, on a recording.
- `interpolate`, `perf`, `recursive_dft`, `sweep`, `pattern`, and the loose `ewma.odin`, `fir_filter.odin` and `moving_avg.odin`: smaller experiments from along the way.

Archived from the 2024 raylib prototype, they no longer build: `ac`, `autogain`, `fft_filter`, `framerate`, `pitch`, `resonator`, `single_dft` and the `helpers` they share are written for an older Odin and for the libraries where they used to be. `pitchy` is a web page from the same time.
