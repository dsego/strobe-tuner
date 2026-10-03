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


// The input through miniaudio. Android has audio_capture_android.odin, Odin's miniaudio bindings lay out
// its structs for desktop Linux there.
#+build !linux:android
package app

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

import ma "vendor:miniaudio"

import "../core"


AudioCapture :: struct {
    ctx:                ma.context_type,
    device:             ma.device,
    device_open:        bool,
    capture_infos:      []ma.device_info, // owned by ctx, valid until the next enumeration
    active_device:      i32, // index into capture_infos
    nodes:              [dynamic]^core.AudioCaptureNode,
    samplerate:         u32,

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

open_stream_on_active_device :: proc(self: ^AudioCapture) -> bool {
    config := ma.device_config_init(.capture)
    config.capture.format = .f32
    config.capture.channels = 1
    config.sampleRate = self.samplerate
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
    self.device_open = true

    fmt.println("Opened input stream")

    return true
}


// Opens the default input, nil when there's none or it can't be opened
init_audio_capture :: proc(samplerate: u32) -> (self: ^AudioCapture, ok: bool) {
    self = new(AudioCapture)
    self.samplerate = samplerate

    if failed(ma.context_init(nil, 0, nil, &self.ctx)) {
        free(self)
        return nil, false
    }
    fmt.println("Initialized miniaudio, backend:", self.ctx.backend)

    infos: [^]ma.device_info
    count: u32
    if failed(ma.context_get_devices(&self.ctx, nil, nil, &infos, &count)) || count == 0 {
        fmt.println("No audio input devices found")
        destroy_audio_capture(self)
        return nil, false
    }
    self.capture_infos = infos[:count]

    for &info, index in self.capture_infos {
        if info.isDefault do self.active_device = i32(index)
    }
    for index in 0 ..< audio_device_count(self) {
        marker := "[‣]" if index == self.active_device else " ‣ "
        fmt.printfln("  %v %s %s", index, marker, audio_device_name(self, index))
    }

    if !open_stream_on_active_device(self) {
        destroy_audio_capture(self)
        return nil, false
    }
    return self, true
}


start_audio_capture :: proc(self: ^AudioCapture) -> bool {
    if !self.device_open do return false
    if failed(ma.device_start(&self.device)) do return false

    fmt.println("Started input stream")
    return true
}

stop_audio_capture :: proc(self: ^AudioCapture) {
    if !self.device_open do return
    if failed(ma.device_stop(&self.device)) do return

    fmt.println("Stopped input stream")
}

// Whether an interruption ended since the last call, then the device has to be opened again
audio_interruption_ended :: proc(self: ^AudioCapture) -> bool {
    return intrinsics.atomic_exchange(&self.interruption_ended, false)
}

// The input couldn't be opened, the strobe would just stand still
audio_input_failed :: proc(self: ^AudioCapture) -> bool {
    return !self.device_open
}

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
    free(self)
}


stream_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
    context = runtime.default_context()
    self := cast(^AudioCapture)device.pUserData
    write_to_audio_nodes(self, slice.from_ptr(cast([^]f32)input, int(frame_count)))
}

notification_callback :: proc "c" (notification: ^ma.device_notification) {
    if notification.type == .interruption_ended {
        self := cast(^AudioCapture)notification.pDevice.pUserData
        intrinsics.atomic_store(&self.interruption_ended, true)
    }
}


// The app's page in the Settings app, where the microphone is turned on again
allow_microphone :: proc() {
    gfx_open_url("app-settings:")
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

// Prints what went wrong
failed :: proc(result: ma.result) -> bool {
    if result == .SUCCESS do return false
    fmt.println("miniaudio error:", ma.result_description(result))
    return true
}
