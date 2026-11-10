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


// The input through miniaudio, AAudio on Android. iOS and Android have one input, the system routes it:
// built-in mic, headset or a USB interface. In a browser see web.odin.
#+build !js
package audio

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

import ma "vendor:miniaudio"
import sdl "vendor:sdl3"

import "../core"

// Building for iOS, see platform/ios/build-sim.sh
IOS :: #config(IOS, false)

MACOS :: ODIN_OS == .Darwin && !IOS
ANDROID :: ODIN_PLATFORM_SUBTARGET == .Android

// The picked channel of a device with more is copied here in pieces this long, see write_channel_to_nodes
CHANNEL_CHUNK :: 2048


Capture :: struct {
    ctx:                ma.context_type,
    ctx_ready:          bool,
    device:             ma.device,
    device_open:        bool,
    capture_infos:      []ma.device_info, // owned by ctx, valid until the next enumeration
    active_device:      i32, // index into capture_infos, or SYSTEM_DEFAULT or NOT_LISTED
    nodes:              [dynamic]^core.AudioCaptureNode,

    // What the nodes get, the device's own rate or a fast one decimated, see set_input_rate
    device_rate:        f32,
    sample_rate:        f32,
    decimator:          core.Decimator,
    decimate_chunk:     [DECIMATE_CHUNK]f32,

    // The device's channels as it opened, a phone's one, and the one measured or MIX_CHANNELS. Set from the
    // main loop and read on miniaudio's thread, see write_channel_to_nodes.
    channels:           int,
    channel:            int,
    channel_chunk:      [CHANNEL_CHUNK]f32,

    // Set from miniaudio's thread when an iOS audio interruption (a call, Siri, an alarm) is over.
    // miniaudio stops the device when one begins but doesn't start it again.
    interruption_ended: bool,

    // Set from miniaudio's thread when the system default moved to another device, or the open one stopped
    // without being closed, e.g. unplugged. The list is made again and an input opened again from the main
    // loop. Not while it's closed here, see close_device. On iOS any route change, the input is opened again
    // only when the hardware's rate moved, see devices_changed.
    devices_changed:    bool,
    closing:            bool,
}

device_count :: proc(self: ^Capture) -> i32 {
    return i32(len(self.capture_infos))
}

// SYSTEM_DEFAULT is named after the device it is now, "" when none is. Without the spaces some have around.
device_name :: proc(self: ^Capture, device_index: i32) -> string {
    index := default_device(self) if device_index == SYSTEM_DEFAULT else device_index
    if index < 0 || index >= device_count(self) do return ""

    return strings.trim_space(strings.truncate_to_byte(string(self.capture_infos[index].name[:]), 0))
}

// The system's default input in the list, -1 when none is marked
default_device :: proc(self: ^Capture) -> i32 {
    for &info, index in self.capture_infos {
        if info.isDefault do return i32(index)
    }
    return -1
}

// The first device of the name in the list, SYSTEM_DEFAULT for "" or one that isn't there
find_device :: proc(self: ^Capture, name: string) -> i32 {
    if name == "" do return SYSTEM_DEFAULT

    for index in 0 ..< device_count(self) {
        if device_name(self, index) == name do return index
    }
    return SYSTEM_DEFAULT
}

// The system's inputs as they are now. The open one keeps its place by its name, one gone from the list is
// NOT_LISTED, still open until another one is.
refresh_devices :: proc(self: ^Capture) {
    if !self.ctx_ready do return

    // iOS lists the route's inputs only while the session is active, and a call leaves it inactive. Still
    // inactive, the list stays as it was, opening the input fails and the strobe area offers to try again.
    when IOS {
        if !activate_audio_session() do return
    }

    // Copied, the names go with the list
    open_name: [ma.MAX_DEVICE_NAME_LENGTH + 1]u8
    if self.active_device >= 0 {
        open_name = self.capture_infos[self.active_device].name
    }

    infos: [^]ma.device_info
    count: u32
    when ANDROID {
        // miniaudio lists AAudio's default only when it can open it, not before the microphone is allowed
        copy(microphone_info.name[:], "Microphone")
        microphone_info.isDefault = true
        infos, count = &microphone_info, 1
    } else {
        if failed(ma.context_get_devices(&self.ctx, nil, nil, &infos, &count)) {
            count = 0
        }
    }

    self.capture_infos = infos[:count]

    if self.active_device >= 0 {
        // Trimmed like device_name
        name := strings.trim_space(strings.truncate_to_byte(string(open_name[:]), 0))
        found := find_device(self, name)
        self.active_device = found if found != SYSTEM_DEFAULT else NOT_LISTED
    }
}

open_stream_on_active_device :: proc(self: ^Capture) -> bool {
    if device_count(self) == 0 do return false

    when ANDROID {
        if !microphone_allowed() do return false
    }

    config := ma.device_config_init(.capture)
    config.capture.format = .f32

    // Every channel the desktop's device has, one is picked or they're averaged, see write_channel_to_nodes.
    // Asked for one, miniaudio's conversion to mono averages them, a guitar in an interface's first input
    // 6 dB quieter with the second one's hiss. A phone's one input is the system's to route.
    config.capture.channels = 1 when IOS || ANDROID else 0

    // The device's own rate. Asked for another, miniaudio interpolates between the samples, and the images
    // that leaves of a note land near its partials and light the strobe's tracks for them.
    config.sampleRate = 0
    config.performanceProfile = .low_latency
    config.noFixedSizedCallback = true // the nodes' ring buffers take chunks of any size
    config.dataCallback = stream_callback
    config.notificationCallback = notification_callback
    config.pUserData = self

    // The system deactivates the session for an interruption, miniaudio only activates it once in
    // context_init. It also leaves the mode at the default, with the system's input processing. A session
    // that can't be activated, a call or another app holds the microphone, would open a silent input: it
    // fails instead and the strobe area offers to try again.
    when IOS {
        if !activate_audio_session() do return false
    }

    // A picked device by its ID. The system default without one, miniaudio follows it to another device and
    // says so, see notification_callback. iOS has just the default.
    when !IOS {
        if self.active_device >= 0 {
            config.capture.pDeviceID = &self.capture_infos[self.active_device].id
        }
    }

    // Unprocessed has no automatic gain or noise suppression, not every phone has it. Voice recognition is the
    // next least processed.
    when ANDROID {
        config.aaudio.inputPreset = .unprocessed
        if failed(ma.device_init(&self.ctx, &config, &self.device)) {
            config.aaudio.inputPreset = .voice_recognition
            if failed(ma.device_init(&self.ctx, &config, &self.device)) do return false
        }
    } else {
        if failed(ma.device_init(&self.ctx, &config, &self.device)) do return false
    }

    set_input_rate(self, f32(self.device.capture.internalSampleRate))
    self.channels = int(self.device.capture.channels)
    self.device_open = true

    fmt.println("Opened input stream")

    return true
}


// Opens the input of the name, the system default for "" or one that isn't there. Without any, or when it
// can't be opened, the input stays closed and the app says so, see input_failed.
init :: proc(name: string) -> ^Capture {
    self := new(Capture)
    self.active_device = SYSTEM_DEFAULT

    if failed(ma.context_init(nil, 0, nil, &self.ctx)) do return self

    self.ctx_ready = true
    fmt.println("Initialized miniaudio, backend:", self.ctx.backend)

    refresh_devices(self)
    if device_count(self) == 0 {
        fmt.println("No audio input devices found")
        return self
    }

    self.active_device = find_device(self, name)
    opened := default_device(self) if self.active_device == SYSTEM_DEFAULT else self.active_device
    for index in 0 ..< device_count(self) {
        marker := "[‣]" if index == opened else " ‣ "
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

// On the way to the background. On Android the microphone is asked for again on the way back, unless its
// dialog is what sent the app there.
stop :: proc(self: ^Capture) {
    when ANDROID {
        intrinsics.atomic_compare_exchange_strong(&microphone_permission, .GRANTED, .UNKNOWN)
        intrinsics.atomic_compare_exchange_strong(&microphone_permission, .DENIED, .UNKNOWN)
    }

    if !self.device_open do return
    if failed(ma.device_stop(&self.device)) do return

    fmt.println("Stopped input stream")
}

// Whether an interruption ended since the last call, on Android the microphone was allowed, then the device
// has to be opened again
interruption_ended :: proc(self: ^Capture) -> bool {
    ended := intrinsics.atomic_exchange(&self.interruption_ended, false)
    when ANDROID {
        if intrinsics.atomic_exchange(&microphone_granted, false) {
            ended = true
        }
    }
    return ended
}

// Whether the list has to be made again since the last call, see devices_changed in Capture
devices_changed :: proc(self: ^Capture) -> bool {
    changed := intrinsics.atomic_exchange(&self.devices_changed, false)

    // A headset or an interface plugged in keeps the input at the rate it opened at, the system converts to
    // it like miniaudio would. Not every route change, opening the input changes the route too.
    when IOS {
        if changed && self.device_open {
            session := intrinsics.objc_send(^AVAudioSession, AVAudioSession, "sharedInstance")
            changed = f32(intrinsics.objc_send(f64, session, "sampleRate")) != self.device_rate
        }
    }
    return changed
}

// The input couldn't be opened, the strobe would just stand still. While Android asks for the microphone
// nothing has failed yet, a denied one is microphone_denied.
input_failed :: proc(self: ^Capture) -> bool {
    when ANDROID {
        permission := intrinsics.atomic_load(&microphone_permission)
        if permission == .ASKED || permission == .DENIED do return false
    }
    return !self.device_open
}

close_device :: proc(self: ^Capture) {
    if !self.device_open do return

    // Stops the device and waits for any in-flight callback to finish, its stop isn't one to follow
    intrinsics.atomic_store(&self.closing, true)
    ma.device_uninit(&self.device)
    intrinsics.atomic_store(&self.closing, false)
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

// The open input's channels, one without an input
channel_count :: proc(self: ^Capture) -> int {
    return self.channels if self.device_open else 1
}

// The channel measured from here on, counted from 1, or MIX_CHANNELS. One the device doesn't have is averaged
// like MIX_CHANNELS, a pick kept for another device.
set_input_channel :: proc(self: ^Capture, channel: int) {
    intrinsics.atomic_store(&self.channel, channel)
}

input_channel :: proc(self: ^Capture) -> int {
    return intrinsics.atomic_load(&self.channel)
}

stream_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
    context = runtime.default_context()
    self := cast(^Capture)device.pUserData
    channels := int(device.capture.channels)
    frames := slice.from_ptr(cast([^]f32)input, int(frame_count) * channels)
    if channels == 1 {
        write_to_nodes(self, frames)
    } else {
        write_channel_to_nodes(self, frames, channels)
    }
}

// The picked channel of the frames to every node, or the frames' channels averaged, a piece at a time. From
// the audio thread.
write_channel_to_nodes :: proc(self: ^Capture, frames: []f32, channels: int) {
    picked := intrinsics.atomic_load(&self.channel)
    if picked < 1 || picked > channels {
        picked = MIX_CHANNELS
    }

    frame_count := len(frames) / channels
    for start := 0; start < frame_count; start += CHANNEL_CHUNK {
        chunk := self.channel_chunk[:min(CHANNEL_CHUNK, frame_count - start)]
        for &sample, offset in chunk {
            frame := frames[(start + offset) * channels:][:channels]
            sample = math.sum(frame) / f32(channels) if picked == MIX_CHANNELS else frame[picked - 1]
        }
        write_to_nodes(self, chunk)
    }
}

// Following the system default to another device, miniaudio keeps the rate the input opened at and
// resamples to it, so the new one is opened again at its own. iOS stops for an interruption and opens again
// after it, a stop there isn't one to follow.
notification_callback :: proc "c" (notification: ^ma.device_notification) {
    self := cast(^Capture)notification.pDevice.pUserData
    #partial switch notification.type {
    case .interruption_ended:
        intrinsics.atomic_store(&self.interruption_ended, true)
    case .rerouted:
        if !intrinsics.atomic_load(&self.closing) {
            intrinsics.atomic_store(&self.devices_changed, true)
        }
    case .stopped:
        when !IOS {
            if !intrinsics.atomic_load(&self.closing) {
                intrinsics.atomic_store(&self.devices_changed, true)
            }
        }
    }
}


// The app's page in the system's settings, where the microphone is turned on again. After two denials
// Android stops showing its dialog, the settings always work, StrobieActivity opens them there.
allow_microphone :: proc() {
    when ANDROID {
        OPEN_APP_SETTINGS :: 0x8000 // COMMAND_USER in SDLActivity.java
        if !sdl.SendAndroidMessage(OPEN_APP_SETTINGS, 0) {
            fmt.println("Couldn't open the app's settings:", sdl.GetError())
        }
    } else when MACOS {
        // The Mac has no page per app, the Microphone list in Privacy & Security
        MICROPHONE_SETTINGS :: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        if !sdl.OpenURL(MICROPHONE_SETTINGS) {
            fmt.println("Couldn't open the microphone settings:", sdl.GetError())
        }
    } else {
        if !sdl.OpenURL("app-settings:") {
            fmt.println("Couldn't open the app's settings:", sdl.GetError())
        }
    }
}

// iOS and the Mac give a denied microphone a silent input, nothing fails
microphone_denied :: proc() -> bool {
    when IOS {
        // AVAudioSessionRecordPermissionDenied, 'deny'
        DENIED :: 0x64656e79
        session := intrinsics.objc_send(^AVAudioSession, AVAudioSession, "sharedInstance")
        return intrinsics.objc_send(uint, session, "recordPermission") == DENIED
    } else when MACOS {
        // AVAuthorizationStatus, restricted by a parental control or a device profile is as silent
        RESTRICTED :: 1
        DENIED :: 2
        status := intrinsics.objc_send(int, AVCaptureDevice, "authorizationStatusForMediaType:", AVMediaTypeAudio)
        return status == RESTRICTED || status == DENIED
    } else when ANDROID {
        return intrinsics.atomic_load(&microphone_permission) == .DENIED
    } else {
        return false
    }
}

when ANDROID {
    MicrophonePermission :: enum i32 {
        UNKNOWN, // asked when the input is opened
        ASKED, // the system's dialog is up
        GRANTED,
        DENIED,
    }

    // Set from SDL's thread when the permission dialog is answered
    microphone_permission: MicrophonePermission

    // Set with the permission granted, the input is opened then
    microphone_granted: bool

    // The one input in the list, see refresh_devices
    microphone_info: ma.device_info

    // Answered right away when it's allowed, else after the system's dialog, then the input is opened again.
    // It's asked each time the app comes back, it may have been allowed or taken away meanwhile.
    microphone_allowed :: proc() -> bool {
        permission_answered :: proc "c" (userdata: rawptr, permission: cstring, granted: bool) {
            intrinsics.atomic_store(&microphone_permission, MicrophonePermission.GRANTED if granted else .DENIED)
            if granted {
                intrinsics.atomic_store(&microphone_granted, true)
            }
        }

        switch intrinsics.atomic_load(&microphone_permission) {
        case .GRANTED:
            return true
        case .UNKNOWN:
            intrinsics.atomic_store(&microphone_permission, MicrophonePermission.ASKED)

            // Not asked after all, the next try asks again, see input_failed
            if !sdl.RequestAndroidPermission("android.permission.RECORD_AUDIO", permission_answered, nil) {
                fmt.println("Couldn't ask for the microphone:", sdl.GetError())
                intrinsics.atomic_store(&microphone_permission, MicrophonePermission.UNKNOWN)
            }
        case .ASKED, .DENIED:
        }
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

    // Whether it's active, the measurement mode is only nicer to have
    activate_audio_session :: proc() -> bool {
        session := intrinsics.objc_send(^AVAudioSession, AVAudioSession, "sharedInstance")
        if !intrinsics.objc_send(bool, session, "setMode:error:", AVAudioSessionModeMeasurement, rawptr(nil)) {
            fmt.println("Couldn't set the audio session to the measurement mode")
        }
        if !intrinsics.objc_send(bool, session, "setActive:error:", bool(true), rawptr(nil)) {
            fmt.println("Couldn't activate the audio session")
            return false
        }
        return true
    }
}

when MACOS {
    @(objc_class = "AVCaptureDevice")
    AVCaptureDevice :: struct {
        using _: intrinsics.objc_object,
    }

    foreign import av_foundation "system:AVFoundation.framework"

    foreign av_foundation {
        // NSString, the media type whose permission is the microphone's
        AVMediaTypeAudio: rawptr
    }
}

// Prints what went wrong
failed :: proc(result: ma.result) -> bool {
    if result == .SUCCESS do return false

    fmt.println("miniaudio error:", ma.result_description(result))
    return true
}
