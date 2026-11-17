// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AudioToolbox
import AVFAudio
import CrateEngine
import Foundation

/// The guest's virtio-snd output on iOS's current playback route.
///
/// crate owns the PCM ring. RemoteIO's real-time callback pulls from it; an
/// underrun is already filled with silence by crate. iOS then converts the
/// guest's format to the physical route and follows speaker, USB-C and AirPlay
/// changes itself.
final class AudioBridge: @unchecked Sendable {
    private struct Format: Equatable {
        enum Sample: Equatable { case signed16, signed32, float32 }
        let channels: UInt32
        let rate: UInt32
        let sample: Sample

        var bytes: UInt32 { sample == .signed16 ? 2 : 4 }
    }

    /// Serializes start, stop and detach; the render callback never takes it.
    private let lifecycle = NSLock()
    /// The tiny state the render callback reads.
    private let state = NSLock()
    private var machine: OpaquePointer?
    private var sound: UInt32 = 0
    private var unit: AudioComponentInstance?
    private var current: Format?
    private var running = false

    /// For crate_config_add_sound; `self` outlives the machine.
    var callbacks: crate_audio_callbacks {
        crate_audio_callbacks(
            size: MemoryLayout<crate_audio_callbacks>.size,
            context: Unmanaged.passUnretained(self).toOpaque(),
            start: { context, sound, format in
                guard let context, let format else { return false }
                return Unmanaged<AudioBridge>.fromOpaque(context)
                    .takeUnretainedValue().start(sound: sound, format: format.pointee)
            },
            stop: { context, sound in
                guard let context else { return }
                Unmanaged<AudioBridge>.fromOpaque(context)
                    .takeUnretainedValue().stop(sound: sound)
            })
    }

    func attach(machine: OpaquePointer) {
        state.withLock { self.machine = machine }
    }

    /// Stops every callback before the machine can be freed.
    func detach() {
        lifecycle.withLock {
            state.withLock { machine = nil }
            disposeUnit()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func format(_ c: crate_audio_format) -> Format? {
        let sample: Format.Sample
        switch c.sample_format {
        case CRATE_AUDIO_S16: sample = .signed16
        case CRATE_AUDIO_S32: sample = .signed32
        case CRATE_AUDIO_F32: sample = .float32
        default: return nil
        }
        guard (1...2).contains(c.channels), c.sample_rate == 44_100 || c.sample_rate == 48_000 else {
            return nil
        }
        return Format(channels: c.channels, rate: c.sample_rate, sample: sample)
    }

    private func start(sound: UInt32, format c: crate_audio_format) -> Bool {
        lifecycle.withLock {
            guard let format = format(c) else {
                AppLog.write("audio: crate asked for an unsupported format")
                return false
            }
            if state.withLock({ current != format }) {
                disposeUnit()
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                // Preferences may be refused by a USB or AirPlay route; Core
                // Audio converts for whatever that route actually accepts.
                try? session.setPreferredSampleRate(Double(format.rate))
                try? session.setPreferredIOBufferDuration(0.01)
                try session.setActive(true)
            } catch {
                AppLog.write("audio: iOS refused the playback session: \(error.localizedDescription)")
                return false
            }
            if state.withLock({ unit == nil }) && !makeUnit(format) {
                return false
            }
            let output = state.withLock { () -> AudioComponentInstance? in
                self.sound = sound
                return unit
            }
            guard let output else { return false }
            let status = AudioOutputUnitStart(output)
            guard status == noErr else {
                AppLog.write("audio: RemoteIO would not start (\(status))")
                return false
            }
            state.withLock { running = true }
            let route = AVAudioSession.sharedInstance().currentRoute.outputs
                .map(\.portName).joined(separator: ", ")
            AppLog.write("audio: \(format.channels) ch, \(format.rate) Hz on \(route.isEmpty ? "the current route" : route)")
            return true
        }
    }

    private func stop(sound: UInt32) {
        lifecycle.withLock {
            let output = state.withLock { () -> AudioComponentInstance? in
                guard self.sound == sound, running else { return nil }
                running = false
                return unit
            }
            if let output {
                AudioOutputUnitStop(output)
                AppLog.write("audio: stopped")
            }
        }
    }

    private func makeUnit(_ format: Format) -> Bool {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            AppLog.write("audio: iOS has no RemoteIO component")
            return false
        }
        var made: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &made) == noErr, let made else {
            AppLog.write("audio: RemoteIO could not be created")
            return false
        }

        var stream = AudioStreamBasicDescription(
            mSampleRate: Double(format.rate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: (format.sample == .float32 ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: format.bytes * format.channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: format.bytes * format.channels,
            mChannelsPerFrame: format.channels,
            mBitsPerChannel: format.bytes * 8,
            mReserved: 0)
        var render = AURenderCallbackStruct(
            inputProc: { context, _, _, _, _, buffers in
                guard let buffers else { return noErr }
                return Unmanaged<AudioBridge>.fromOpaque(context)
                    .takeUnretainedValue().render(buffers)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let streamStatus = AudioUnitSetProperty(
            made, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &stream, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        let callbackStatus = AudioUnitSetProperty(
            made, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &render, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        let initializeStatus = streamStatus == noErr && callbackStatus == noErr
            ? AudioUnitInitialize(made) : -1
        guard streamStatus == noErr, callbackStatus == noErr, initializeStatus == noErr else {
            AppLog.write("audio: RemoteIO refused the guest format (\(streamStatus), \(callbackStatus), \(initializeStatus))")
            AudioComponentInstanceDispose(made)
            return false
        }
        state.withLock {
            unit = made
            current = format
            running = false
        }
        return true
    }

    private func render(_ buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let source = state.withLock { (machine, sound) }
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let bytes = buffer.mData else { continue }
            if let machine = source.0 {
                _ = crate_audio_read(machine, source.1,
                                     bytes.assumingMemoryBound(to: UInt8.self),
                                     Int(buffer.mDataByteSize))
            } else {
                memset(bytes, 0, Int(buffer.mDataByteSize))
            }
        }
        return noErr
    }

    /// Called only with lifecycle held. RemoteIO is stopped outside `state`,
    /// because stopping waits for a render callback which briefly takes it.
    private func disposeUnit() {
        let old = state.withLock { () -> AudioComponentInstance? in
            let old = unit
            unit = nil
            current = nil
            running = false
            return old
        }
        guard let old else { return }
        AudioOutputUnitStop(old)
        AudioUnitUninitialize(old)
        AudioComponentInstanceDispose(old)
    }
}
