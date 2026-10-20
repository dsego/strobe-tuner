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


// What both inputs share, miniaudio's in capture.odin and the browser's in web.odin: the samples to every
// node, decimated first when the input is fast. Each has its own Capture with these fields.
package audio

import "core:fmt"

import "../core"

// A fast input's samples are copied here in pieces this long and decimated in place, see write_to_nodes
DECIMATE_CHUNK :: 2048

// An active_device that's no device of the list: the system's default input, followed to wherever it moves,
// or one that went from the list and is still open
SYSTEM_DEFAULT :: -1
NOT_LISTED :: -2

register_audio_node :: proc(self: ^Capture, node: ^core.AudioCaptureNode) {
    append(&self.nodes, node)
}

// The input opened at the device's own rate. Never resampled, a fast one is decimated, see
// core.init_decimator. Before the stream starts, the audio thread isn't running yet.
set_input_rate :: proc(self: ^Capture, device_rate: f32) {
    self.device_rate = device_rate
    self.decimator, self.sample_rate = core.init_decimator(device_rate)
    fmt.printfln("Input at %v Hz, measured at %v Hz", device_rate, self.sample_rate)
}

// The input as it is to every node, the pitch detection filters its own. A fast input is decimated first, a
// copy of it, the input's buffer is the system's. From the audio thread.
write_to_nodes :: proc(self: ^Capture, samples: []f32) {
    if self.decimator.halvings == 0 {
        for node in self.nodes do core.audio_capture_write(node, samples)
        return
    }

    for start := 0; start < len(samples); start += DECIMATE_CHUNK {
        chunk := self.decimate_chunk[:copy(self.decimate_chunk[:], samples[start:])]
        count := core.decimate(&self.decimator, chunk)
        for node in self.nodes do core.audio_capture_write(node, chunk[:count])
    }
}
