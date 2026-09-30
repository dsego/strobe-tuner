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


package app

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

import ma "vendor:miniaudio"

import "../core"


// Max samples filtered in one go, larger callbacks are processed in chunks
FILTER_CHUNK_SIZE :: 4096

AudioCapture :: struct {
    ctx:                ma.context_type,
    device:             ma.device,
    device_open:        bool,
    capture_infos:      []ma.device_info, // owned by ctx, valid until the next enumeration
    active_device:      i32, // index into capture_infos
    nodes:              [dynamic]^core.AudioCaptureNode,
    samplerate:         u32,
    highpass_cutoff_hz: f32,
    highpass:           core.Biquad,
    filtered:           []f32, // high-passed copy of the input, shared by all nodes

    // Set from miniaudio's thread when an iOS audio interruption (a call, Siri, an alarm) is over.
    // miniaudio stops the device when one begins but doesn't start it again.
    interruption_ended: bool,
}

audio_device_count :: proc(self: ^AudioCapture) -> i32 {
    return i32(len(self.capture_infos))
}

audio_device_name :: proc(self: ^AudioCapture, device_index: i32) -> string {
    return strings.truncate_to_byte(string(self.capture_infos[device_index].name[:]), 0)
}

switch_audio_device :: proc(self: ^AudioCapture, device_index: i32) {
    close_device(self)

    // Flush ring buffers to discard stale samples from the previous device
    for node in self.nodes {
        core.flush_audio_capture_ringbuffer(node)
    }

    // Reset the filter state, the previous device's signal is unrelated
    self.highpass = core.init_highpass(self.highpass_cutoff_hz, f32(self.samplerate))

    self.active_device = device_index

    fmt.println("Switching audio device to: ", audio_device_name(self, device_index), device_index)

    if open_stream_on_active_device(self) {
        start_audio_capture(self)
    }
}

open_stream_on_active_device :: proc(self: ^AudioCapture) -> bool {
    config := ma.device_config_init(.capture)
    config.capture.format = .f32
    config.capture.channels = 1
    config.sampleRate = self.samplerate
    config.performanceProfile = .low_latency
    config.noFixedSizedCallback = true // callback chunks are handled in stream_callback
    config.dataCallback = stream_callback
    config.notificationCallback = notification_callback
    config.pUserData = self

    // The system deactivates the session for an interruption, miniaudio only activates it once in
    // context_init. It also leaves the mode at the default, with the system's input processing.
    when IOS do activate_audio_session()

    // Ask the OS for an unprocessed signal (no AGC / noise suppression)
    config.aaudio.inputPreset = .unprocessed

    // A nil ID lets miniaudio follow the system default device when it changes
    info := &self.capture_infos[self.active_device]
    if !info.isDefault {
        config.capture.pDeviceID = &info.id
    }

    if check(ma.device_init(&self.ctx, &config, &self.device)) do return false
    self.device_open = true

    fmt.println("Opened input stream")

    return true
}


init_audio_capture :: proc(samplerate: u32, highpass_cutoff_hz: f32) -> (bool, ^AudioCapture) {
    self := new(AudioCapture)
    self.samplerate = samplerate
    self.highpass_cutoff_hz = highpass_cutoff_hz
    self.highpass = core.init_highpass(highpass_cutoff_hz, f32(samplerate))
    self.filtered = make([]f32, FILTER_CHUNK_SIZE)

    if check(ma.context_init(nil, 0, nil, &self.ctx)) do return false, self

    fmt.println("Initialized miniaudio, backend:", self.ctx.backend)

    infos: [^]ma.device_info
    count: u32
    if check(ma.context_get_devices(&self.ctx, nil, nil, &infos, &count)) do return false, self
    if count == 0 {
        fmt.println("No audio input devices found")
        return false, self
    }
    self.capture_infos = infos[:count]

    for &info, i in self.capture_infos {
        if info.isDefault do self.active_device = i32(i)
    }

    for i in 0 ..< audio_device_count(self) {
        str := "  %v  ‣  %s\n"
        if i == self.active_device {
            str = "  %v [‣] %s\n"
        }
        fmt.printf(str, i, audio_device_name(self, i))
    }

    ok := open_stream_on_active_device(self)

    return ok, self
}


start_audio_capture :: proc(self: ^AudioCapture) -> bool {
    if !self.device_open do return false
    if check(ma.device_start(&self.device)) do return false

    fmt.println("Started input stream")
    return true
}

stop_audio_capture :: proc(self: ^AudioCapture) {
    if !self.device_open do return
    if check(ma.device_stop(&self.device)) do return

    fmt.println("Stopped input stream")
}

// Whether an interruption ended since the last call, then the device has to be opened again
audio_interruption_ended :: proc(self: ^AudioCapture) -> bool {
    return intrinsics.atomic_exchange(&self.interruption_ended, false)
}

register_audio_node :: proc(self: ^AudioCapture, node: ^core.AudioCaptureNode) {
    append(&self.nodes, node)
}


// TODO: remove node?

close_device :: proc(self: ^AudioCapture) {
    if !self.device_open do return
    // Stops the device and waits for any in-flight callback to finish
    ma.device_uninit(&self.device)
    self.device_open = false
    fmt.println("Closed input stream")
}

destroy_audio_capture :: proc(self: ^AudioCapture) {
    close_device(self)
    ma.context_uninit(&self.ctx)
    fmt.println("Terminated miniaudio")

    delete(self.nodes)
    delete(self.filtered)
    free(self)
}


stream_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
    context = runtime.default_context()

    input_slice: []f32 = slice.from_ptr(cast([^]f32)input, int(frame_count))

    self := cast(^AudioCapture)device.pUserData

    // High-pass once for all nodes to strip DC and low frequency rumble from the mic, except the ones that
    // want the input as it is
    for len(input_slice) > 0 {
        count := min(len(input_slice), len(self.filtered))
        raw := input_slice[:count]
        chunk := self.filtered[:count]
        core.biquad_process(&self.highpass, raw, chunk)
        input_slice = input_slice[count:]

        // process all nodes
        for node in self.nodes {
            if node.stream_callback != nil {
                node.stream_callback(node, raw if node.unfiltered else chunk)
            }
        }
    }
}

notification_callback :: proc "c" (notification: ^ma.device_notification) {
    if notification.type == .interruption_ended {
        self := cast(^AudioCapture)notification.pDevice.pUserData
        intrinsics.atomic_store(&self.interruption_ended, true)
    }
}


// iOS gives a denied microphone a silent input, nothing fails
microphone_denied :: proc() -> bool {
    when IOS {
        // AVAudioSessionRecordPermissionDenied, 'deny'
        DENIED :: 0x64656e79
        session := intrinsics.objc_send(^AVAudioSession, AVAudioSession, "sharedInstance")
        return intrinsics.objc_send(uint, session, "recordPermission") == DENIED
    } else {
        return false
    }
}

when IOS {
    @(objc_class = "AVAudioSession")
    AVAudioSession :: struct {
        using _: intrinsics.objc_object,
    }

    foreign import av_foundation "system:AVFoundation.framework"

    foreign av_foundation {
        // NSString, the mode with the least input processing, no automatic gain or equalization
        AVAudioSessionModeMeasurement: rawptr
    }

    activate_audio_session :: proc() {
        session := intrinsics.objc_send(^AVAudioSession, AVAudioSession, "sharedInstance")
        if !intrinsics.objc_send(bool, session, "setMode:error:", AVAudioSessionModeMeasurement, rawptr(nil)) {
            fmt.println("Couldn't set the audio session to the measurement mode")
        }
        if !intrinsics.objc_send(bool, session, "setActive:error:", bool(true), rawptr(nil)) {
            fmt.println("Couldn't activate the audio session")
        }
    }
}

check :: proc(res: ma.result) -> bool {
    if res != .SUCCESS {
        fmt.println("miniaudio error: ", ma.result_description(res))
        return true
    }
    return false
}
