// Copyright (C) 2025  Davorin Šego

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


// The part of the input every platform shares, AudioCapture and the stream are in audio_capture.odin
// (miniaudio) and audio_capture_android.odin (AAudio)
package app

import "core:fmt"

import "../core"


register_audio_node :: proc(self: ^AudioCapture, node: ^core.AudioCaptureNode) {
    append(&self.nodes, node)
}

// The input as it is to every node, the pitch detection filters its own. From the audio thread.
write_to_audio_nodes :: proc(self: ^AudioCapture, samples: []f32) {
    for node in self.nodes do core.audio_capture_write(node, samples)
}

switch_audio_device :: proc(self: ^AudioCapture, device_index: i32) {
    close_device(self)

    // Flush ring buffers to discard stale samples from the previous device
    for node in self.nodes {
        core.flush_audio_capture_ringbuffer(node)
    }

    self.active_device = device_index

    fmt.println("Switching audio device to: ", audio_device_name(self, device_index), device_index)

    if open_stream_on_active_device(self) {
        start_audio_capture(self)
    }
}
