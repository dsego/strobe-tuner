# Ideas

Features and code changes that aren't planned yet. Nothing here is decided.

## Steady rotation far from a locked note

Behind a flag, in locked mode only. Tuning up a new string with the note locked to low E, the string
starts far below the note and wobbles on the way up. The strobe has nothing steady to show there, and
it's hard to tell how far there is to go.

Far out, show a simulated rotation at a steady rate in the right direction, and blend it into the
real strobe as the string comes within about 50 to 100 cents.

- The band's window is 25 cents a bin, so the lock-in hears the string about 20 dB down at 50 cents
  and not at all past 75. The direction and distance out there have to come from the pitch detection,
  like the arrows next to the note.
- The blend could follow the band's SNR, which rises as the string comes into the window.
- A constant rate reads as "keep going", a rate that follows the distance would jump around with the
  wobble it is meant to hide.
- The handover is the hard part, the simulated stripes and the real ones have to meet without a
  jump in phase or speed. May not be worth it if it can't be made seamless.

## In-tune cues

One setting, all optional.

- Green note name within the tolerance, the strobe itself stays unchanged.
- A short beep once the note holds in the window for about 300 ms. The detection ignores the input
  briefly so the mic doesn't read the beep.
- A haptic tap as a quieter alternative to the beep.

## Audible beating mode

A tone or click through headphones whose rate follows the pitch error and stops when in tune. Also the
path to real VoiceOver support later.

## Piano stretch tuning

## SDL only

Drop raylib, SDL3 GPU becomes the one renderer. It also brings what the desktop is missing: text
input, dropped files, open dialogs and a resizable window.

- The shaders are written twice by hand, Metal for macOS and iOS, Vulkan GLSL compiled to SPIR-V
  with `glslc` for Linux. No generator, the two files keep the same structure and point at each other.
- The raylib GLSL isn't Vulkan GLSL, the uniforms move into blocks on SDL's binding slots and the
  sprite shader is new.
- macOS goes first with raylib kept as the Linux fallback, raylib goes once Linux runs on Vulkan on
  real hardware.

## Temperaments

A temperament is how the 12 notes of the octave are spaced, 12 offsets in cents from equal
temperament, one per note name and the same in every octave. It's a layer of its own, not a tuning
and not a preset:

    target = equal temperament note at concert A
           + temperament offset of the note name
           + the preset's offset of the exact note or string

- Loaded from a `.scl` file, nothing to edit. Equal temperament plus a few built in (Pythagorean,
  1/4-comma meantone, Werckmeister III, Vallotti, just).
- Saved with the setup, so a harpsichord preset and a guitar keep their own. On a guitar it tunes
  the open strings, a chromatic setup gets every note.
- The main screen shows the temperament's name, the note's offset under the letter stays the
  preset's own offset only.
- The readout and the strobe measure from the tempered target, 0 is in tune.
- The note names, the ruler and the detection stay on the equal tempered grid in `core/note.odin`,
  the offsets are all under 50 cents so the nearest note is still the right one. The temperament
  is one more term in `tuner_target_freq`, next to `note_offset_cents`.
- Only 12-note scales with a 2/1 octave load, anything else is turned away with a message.
- The file's contents are copied into the config, not its path, iOS doesn't keep access to a file
  and a file on the desktop moves.

Open:

- A `.scl` file has no root and no tie to A. Normalize so A has no offset and concert A stays
  concert A, and pick the root key (which note is the scale's 1/1) on the setup?
- `pitch.odin` measures `err_cents` from the untempered note, check that nothing shown reads it
  once a temperament is set.
