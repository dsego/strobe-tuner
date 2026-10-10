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


// The input through miniaudio. Android has capture_android.odin, Odin's miniaudio bindings lay out
// its structs for desktop Linux there.
#+build !linux:android
package audio

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

import ma "vendor:miniaudio"
import sdl "vendor:sdl3"

import "../core"

// Building for iOS, see platform/ios/build-sim.sh
IOS :: #config(IOS, false)


Capture :: struct {
    ctx:                ma.context_type,
    ctx_ready:          bool,
    device:             ma.device,
    device_open:        bool,
    capture_infos:      []ma.device_info, // owned by ctx, valid until the next enumeration
    active_device:      i32, // index into capture_infos
    nodes:              [dynamic]^core.AudioCaptureNode,

    // What the nodes get, the device's own rate or a fast one decimated, see set_input_rate
    device_rate:        f32,
    sample_rate:        f32,
    decimator:          core.Decimator,
    decimate_chunk:     [DECIMATE_CHUNK]f32,

    // Set from miniaudio's thread when an iOS audio interruption (a call, Siri, an alarm) is over.
    // miniaudio stops the device when one begins but doesn't start it again.
    interruption_ended: bool,
}

device_count :: proc(self: ^Capture) -> i32 {
    return i32(len(self.capture_infos))
}

device_name :: proc(self: ^Capture, device_index: i32) -> string {
    return strings.truncate_to_byte(string(self.capture_infos[device_index].name[:]), 0)
}

open_stream_on_active_device :: proc(self: ^Capture) -> bool {
    if device_count(self) == 0 do return false

    config := ma.device_config_init(.capture)
    config.capture.format = .f32
    config.capture.channels = 1

    // The device's own rate. Asked for another, miniaudio interpolates between the samples, and the images
    // that leaves of a note land near its partials and light the strobe's tracks for them.
    config.sampleRate = 0
    config.performanceProfile = .low_latency
    config.noFixedSizedCallback = true // the nodes' ring buffers take chunks of any size
    config.dataCallback = stream_callback
    config.notificationCallback = notification_callback
    config.pUserData = self

    // The system deactivates the session for an interruption, miniaudio only activates it once in
    // context_init. It also leaves the mode at the default, with the system's input processing.
    when IOS do activate_audio_session()

    // Ask the OS for an unprocessed signal (no AGC / noise suppression)
    config.aaudio.inputPreset = .unprocessed

    // The device by its ID. A nil ID would follow the system default, which may have changed since the list
    // was made, so picking the input that was the default then could open another one. iOS has just the
    // default.
    when !IOS do config.capture.pDeviceID = &self.capture_infos[self.active_device].id

    if failed(ma.device_init(&self.ctx, &config, &self.device)) do return false

    set_input_rate(self, f32(self.device.capture.internalSampleRate))
    self.device_open = true

    fmt.println("Opened input stream")

    return true
}


// Opens the default input. Without one, or when it can't be opened, the input stays closed and the app says
// so, see input_failed.
init :: proc() -> ^Capture {
    self := new(Capture)

    if failed(ma.context_init(nil, 0, nil, &self.ctx)) do return self

    self.ctx_ready = true
    fmt.println("Initialized miniaudio, backend:", self.ctx.backend)

    infos: [^]ma.device_info
    count: u32
    if failed(ma.context_get_devices(&self.ctx, nil, nil, &infos, &count)) || count == 0 {
        fmt.println("No audio input devices found")
        return self
    }
    self.capture_infos = infos[:count]

    for &info, index in self.capture_infos {
        if info.isDefault do self.active_device = i32(index)
    }
    for index in 0 ..< device_count(self) {
        marker := "[‣]" if index == self.active_device else " ‣ "
        fmt.printfln("  %v %s %s", index, marker, device_name(self, index))
    }

    open_stream_on_active_device(self)
    return self
}


start :: proc(self: ^Capture) -> bool {
    if !self.device_open do return false
    if failed(ma.device_start(&self.device)) do return false

    fmt.println("Started input stream")
    return true
}

stop :: proc(self: ^Capture) {
    if !self.device_open do return
    if failed(ma.device_stop(&self.device)) do return

    fmt.println("Stopped input stream")
}

// Whether an interruption ended since the last call, then the device has to be opened again
interruption_ended :: proc(self: ^Capture) -> bool {
    return intrinsics.atomic_exchange(&self.interruption_ended, false)
}

// The input couldn't be opened, the strobe would just stand still
input_failed :: proc(self: ^Capture) -> bool {
    return !self.device_open
}

close_device :: proc(self: ^Capture) {
    if !self.device_open do return

    // Stops the device and waits for any in-flight callback to finish
    ma.device_uninit(&self.device)
    self.device_open = false
    fmt.println("Closed input stream")
}

destroy :: proc(self: ^Capture) {
    close_device(self)
    if self.ctx_ready {
        ma.context_uninit(&self.ctx)
        fmt.println("Terminated miniaudio")
    }

    delete(self.nodes)
    free(self)
}


stream_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
    context = runtime.default_context()
    self := cast(^Capture)device.pUserData
    write_to_nodes(self, slice.from_ptr(cast([^]f32)input, int(frame_count)))
}

notification_callback :: proc "c" (notification: ^ma.device_notification) {
    if notification.type == .interruption_ended {
        self := cast(^Capture)notification.pDevice.pUserData
        intrinsics.atomic_store(&self.interruption_ended, true)
    }
}


// The app's page in the Settings app, where the microphone is turned on again
allow_microphone :: proc() {
    if !sdl.OpenURL("app-settings:") do fmt.println("Couldn't open the app's settings:", sdl.GetError())
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

    // Odin dev-2026-10 crashes on a message to a class with "missing procedure 'objc_lookUpClass'", its checker
    // declares the runtime's class lookup only on seeing objc_find_class. Fixed on master, drop this with the
    // next Odin release (odin-lang/Odin#7793).
    @(init)
    declare_objc_class_lookup :: proc "contextless" () {
        _ = intrinsics.objc_find_class("AVAudioSession")
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

// Prints what went wrong
failed :: proc(result: ma.result) -> bool {
    if result == .SUCCESS do return false

    fmt.println("miniaudio error:", ma.result_description(result))
    return true
}
