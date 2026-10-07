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


// The part of the input every platform shares, Capture and the stream are in capture.odin
// (miniaudio) and capture_android.odin (AAudio)
package audio

import "core:fmt"

import "../core"


// A fast input's samples are copied here in pieces this long and decimated in place, see write_to_nodes
DECIMATE_CHUNK :: 2048

register_node :: proc(self: ^Capture, node: ^core.AudioCaptureNode) {
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

switch_device :: proc(self: ^Capture, device_index: i32) {
    close_device(self)

    // Flush ring buffers to discard stale samples from the previous device
    for node in self.nodes {
        core.flush_audio_capture_ringbuffer(node)
    }

    self.active_device = device_index

    fmt.println("Switching audio device to: ", device_name(self, device_index), device_index)

    if open_stream_on_active_device(self) {
        start(self)
    }
}
