// Copyright (C) 2026  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


// The input in a browser: the microphone the browser picks, through an AudioWorklet, see
// platform/web/strobie.js. Its samples wait there on the page's thread, take_input brings them in each frame.
// One input, the browser asks for it and says which in its own permission prompt.
#+build js
package audio

import "core:fmt"

import "../core"

// What the page's microphone is doing, the same numbers as INPUT_STATES in strobie.js
InputState :: enum i32 {
    CLOSED,
    OPENING, // the browser's permission prompt is up
    WAITING_FOR_TAP, // open, the browser starts the audio only after a tap or a key
    RUNNING,
    DENIED,
    FAILED,
}

foreign import strobie_audio "strobie_audio"

@(default_calling_convention = "contextless")
foreign strobie_audio {
    // Asks for the microphone, the state follows as the browser answers
    open_input :: proc() ---
    close_input :: proc() ---
    input_state :: proc() -> InputState ---
    // The rate the browser runs the input at, 0 before it's open
    input_rate :: proc() -> f32 ---
    // Moves up to capacity of the waiting samples to buffer, returns how many
    take_samples :: proc(buffer: [^]f32, capacity: int) -> int ---
}

MICROPHONE_NAME :: "Microphone"

Capture :: struct {
    nodes:          [dynamic]^core.AudioCaptureNode,
    active_device:  i32, // the one input or SYSTEM_DEFAULT

    // The browser's rate, a fast one decimated, see set_input_rate
    device_rate:    f32,
    sample_rate:    f32,
    decimator:      core.Decimator,
    decimate_chunk: [DECIMATE_CHUNK]f32,

    // The rate is known once the input opened, the app opens it again then and the measurements follow it
    rate_changed:   bool,
    samples:        [DECIMATE_CHUNK]f32,
}

device_count :: proc(self: ^Capture) -> i32 {
    return 1
}

device_name :: proc(self: ^Capture, device_index: i32) -> string {
    return MICROPHONE_NAME
}

default_device :: proc(self: ^Capture) -> i32 {
    return 0
}

find_device :: proc(self: ^Capture, name: string) -> i32 {
    return 0 if name == MICROPHONE_NAME else SYSTEM_DEFAULT
}

refresh_devices :: proc(self: ^Capture) {}

// The microphone is asked for at once, it runs after the first tap
init :: proc(name: string) -> ^Capture {
    self := new(Capture)
    self.active_device = SYSTEM_DEFAULT
    open_input()
    return self
}

start :: proc(self: ^Capture) -> bool {
    return true
}

stop :: proc(self: ^Capture) {}

interruption_ended :: proc(self: ^Capture) -> bool {
    return false
}

// Once the input opened at its rate, see Capture
devices_changed :: proc(self: ^Capture) -> bool {
    changed := self.rate_changed
    self.rate_changed = false
    return changed
}

input_failed :: proc(self: ^Capture) -> bool {
    return input_state() == .FAILED
}

destroy :: proc(self: ^Capture) {
    close_input()
    delete(self.nodes)
    free(self)
}

// The one input stays open, one that failed or was closed is asked for again
switch_device :: proc(self: ^Capture, device_index: i32) {
    for node in self.nodes do core.flush_audio_capture_ringbuffer(node)

    self.active_device = device_index
    state := input_state()
    if state == .FAILED || state == .CLOSED do open_input()
}

// The samples that came in since the last frame, to every node. From the frame, before it measures.
take_input :: proc(self: ^Capture) {
    rate := input_rate()
    if rate != 0 && rate != self.device_rate {
        set_input_rate(self, rate)
        self.rate_changed = true
    }

    for {
        count := take_samples(raw_data(self.samples[:]), len(self.samples))
        if count == 0 do break

        // Not at the new rate yet, they wait for the measurements to follow it
        if !self.rate_changed do write_to_nodes(self, self.samples[:count])
    }
}

// A tap starts the audio, the browser allows it then
waiting_for_tap :: proc() -> bool {
    return input_state() == .WAITING_FOR_TAP
}

// The browser asks again, unless the page's permission was turned off in its settings
allow_microphone :: proc() {
    fmt.println("Asking for the microphone again")
    open_input()
}

microphone_denied :: proc() -> bool {
    return input_state() == .DENIED
}
