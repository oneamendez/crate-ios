// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CrateEngine
import Foundation
import Observation

/// State shared with crate's C log callback. virglrenderer can emit hundreds
/// of thousands of lines after ANGLE reports a lost GPU context; suppressing
/// everything after the first fatal line keeps that failure from turning into
/// an I/O and main-thread starvation loop while MachineRunner stops the VM.
private final class EngineLogContext: @unchecked Sendable {
    struct Decision {
        let shouldLog: Bool
        let stopForLostGPU: Bool
    }

    weak var runner: MachineRunner?
    private let lock = NSLock()
    private var gpuContextIsLost = false

    func reset() {
        lock.withLock { gpuContextIsLost = false }
    }

    func decision(for message: String) -> Decision {
        lock.withLock {
            if gpuContextIsLost { return Decision(shouldLog: false, stopForLostGPU: false) }
            let lost = message.contains("EGL error 0x300e")
                || message.contains("GL error reported (1287)")
                || message.contains("Failed to create fence sync object")
            if lost {
                gpuContextIsLost = true
                return Decision(shouldLog: true, stopForLostGPU: true)
            }
            return Decision(shouldLog: true, stopForLostGPU: false)
        }
    }
}

/// The VM that's running, on crate (Frameworks/Crate.xcframework, built from
/// the crate repository by Scripts/build-crate.sh).
///
/// crate runs one machine per process, so crate has one of these. The guest's
/// code runs from the region JITSession claimed at launch: crate never asks a
/// debugger for memory itself. The console is the serial port (ttyAMA0), which
/// shows the kernel from its first line; ConsoleBridge carries it to the
/// screen. The display is a virtio GPU the guest draws on in software (2D), with
/// a virtio keyboard and tablet; DisplayBridge carries frames out and input in.
/// The network is user-mode, through libslirp (Scripts/build-slirp.sh): the
/// guest gets 10.0.2.15 by DHCP and reaches the internet through crate.
@MainActor @Observable
final class MachineRunner {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopped(String)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    /// The VM this runner is running, or last ran.
    private(set) var machineID: Machine.ID?
    let console = ConsoleBridge()
    let credentialConsole: CredentialConsoleBridge
    /// Retained for the app's lifetime because the transport deliberately
    /// holds its delegate weakly. One controller follows Crate's one VM.
    let securityKey: SecurityKeyController
    let display = DisplayBridge()
    let audio = AudioBridge()
    private var machine: OpaquePointer?
    private var credentialSession: CredentialConsoleBridge.Session?
    private let engineLogContext = EngineLogContext()
    private var forcedStopMessage: String?
    /// crate's memory in the log while the VM runs.
    private let memoryLog = MemoryLog()
    #if DEBUG
    private let debugHooks = DebugHooks()
    #endif

    init() {
        let credentialConsole = CredentialConsoleBridge()
        self.credentialConsole = credentialConsole
        securityKey = SecurityKeyController(
            bridge: credentialConsole,
            backend: SecurityKeyBackendRouter()
        )
        engineLogContext.runner = self
        let context = Unmanaged.passUnretained(engineLogContext).toOpaque()
        crate_set_log_callback({ context, level, message in
            guard let context, let message else { return }
            let logContext = Unmanaged<EngineLogContext>.fromOpaque(context).takeUnretainedValue()
            let text = String(cString: message)
            let decision = logContext.decision(for: text)
            guard decision.shouldLog else { return }
            let tag = level == CRATE_LOG_ERROR ? "crate error: " : level == CRATE_LOG_WARN ? "crate warning: " : "crate: "
            AppLog.write(tag + text)
            if decision.stopForLostGPU {
                Task { @MainActor in logContext.runner?.stopForLostGPU() }
            }
        }, context, Self.logLevel)
    }

    var isRunning: Bool {
        phase == .starting || phase == .running
    }

    /// What crate logs: its debug lines too, in debug builds launched with
    /// CRATE_LOG=debug (virglrenderer's VREND_DEBUG output is among them).
    private static var logLevel: crate_log_level {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CRATE_LOG"] == "debug" { return CRATE_LOG_DEBUG }
        #endif
        return CRATE_LOG_INFO
    }

    /// Builds the machine from `vm` and its guest files and starts it, in the
    /// code region JIT claimed. Creating it loads the kernel and maps the
    /// guest's memory, so it happens off the main thread.
    func start(_ vm: Machine, region: crate_code_region) {
        guard !isRunning else { return }
        if let old = machine {
            if let credentialSession {
                credentialConsole.detach(credentialSession)
                self.credentialSession = nil
            }
            audio.detach()
            crate_machine_free(old)
            machine = nil
        }
        let files = GuestFiles(for: vm)
        if !files.missing.isEmpty {
            phase = .failed("\(vm.name)'s files aren't on this iPhone yet (\(files.missing.joined(separator: ", "))).")
            return
        }
        // The guest writes to its disk; a copy crate can't write is useless to it.
        if !FileManager.default.isWritableFile(atPath: files.disk.path) {
            phase = .failed("crate can't write to \(vm.name)'s disk, so the VM can't use it. It needs to be put on this iPhone again.")
            AppLog.write("vm: \(files.disk.path) isn't writable")
            return
        }
        phase = .starting
        machineID = vm.id
        forcedStopMessage = nil
        engineLogContext.reset()
        GuestToolServer.shared.start()
        console.reset()
        display.reset()
        let credentialConsole = self.credentialConsole
        let credentialSession = credentialConsole.reset()
        let settings = Settings(vm: vm, files: files, display: display)
        AppLog.write("vm: starting \(vm.name): \(settings.cpus) CPUs, \(settings.memoryMiB) MiB, "
                     + "code \(region.size >> 20) MiB; \(settings.commandLine)")
        let console = self.console
        let display = self.display
        let audio = self.audio
        let context = Unmanaged.passUnretained(self).toOpaque()
        Task.detached(priority: .userInitiated) {
            let started = Date.now
            let result = Self.create(settings, region: region, console: console, display: display,
                                     audio: audio, credentialConsole: credentialConsole,
                                     credentialSession: credentialSession, context: context)
            await MainActor.run {
                switch result {
                case .success(let made):
                    guard credentialConsole.attach(machine: made, in: credentialSession) else {
                        credentialConsole.detach(credentialSession)
                        crate_machine_free(made)
                        GuestToolServer.shared.stop()
                        self.phase = .failed("crate couldn't attach the credential console to the VM.")
                        return
                    }
                    self.machine = made
                    self.credentialSession = credentialSession
                    console.attach(machine: made)
                    display.attach(machine: made)
                    audio.attach(machine: made)
                    if crate_machine_start(made) == CRATE_OK {
                        AppLog.write(String(format: "vm: running, created in %.2f s", Date.now.timeIntervalSince(started)))
                        self.phase = .running
                        self.memoryLog.start()
                        #if DEBUG
                        self.debugHooks.start(console: console, display: display)
                        #endif
                    } else {
                        credentialConsole.detach(credentialSession)
                        self.credentialSession = nil
                        audio.detach()
                        GuestToolServer.shared.stop()
                        self.phase = .failed("crate couldn't start the VM: \(String(cString: crate_last_error())).")
                    }
                case .failure(let message):
                    AppLog.write("vm: \(message)")
                    GuestToolServer.shared.stop()
                    self.phase = .failed(message)
                }
            }
        }
    }

    /// Stops the VM at once, as pulling the plug does: crate's virt board has
    /// no power button yet to ask the guest to shut down.
    func stop() {
        guard let machine, isRunning else { return }
        // Stop accepting authenticator work before crate asks its vCPUs to
        // stop. A backend response arriving during shutdown is then stale.
        if let credentialSession {
            credentialConsole.detach(credentialSession)
            self.credentialSession = nil
        }
        crate_machine_kill(machine)
    }

    // MARK: - Building the machine

    /// What the machine is given: the VM's settings, held to what this iPhone
    /// can spare.
    nonisolated private struct Settings: Sendable {
        let cpus: Int
        let memoryMiB: Int
        let kernel: String
        let initrd: String
        let disk: String
        /// The first-boot settings, when the VM was installed with them.
        let seed: String?
        let commandLine: String
        let displayModes: [crate_display_mode]

        init(vm: Machine, files: GuestFiles, display: DisplayBridge) {
            // A core left for the app and iOS.
            cpus = max(1, min(vm.cpuCount, ProcessInfo.processInfo.activeProcessorCount - 1))
            memoryMiB = Self.memory(askedGB: vm.memoryGB)
            kernel = files.kernel.path
            initrd = files.initrd.path
            disk = files.disk.path
            seed = FileManager.default.fileExists(atPath: files.seed.path) ? files.seed.path : nil
            commandLine = vm.cmdline ?? Self.commandLine
            displayModes = display.modes(after: Self.modes(preferring: vm.display))
        }

        /// The VM's own display size first ("1280 × 800"), then a few others
        /// the guest can change to: what it's offered after the size that fits
        /// the screen (DisplayBridge.fit), or instead of it before the screen
        /// has been laid out. Not 800 × 600, which aTerm's guest image asks
        /// for at every start: offered, it would win over the screen's size.
        static func modes(preferring display: String) -> [crate_display_mode] {
            let numbers = display.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            var sizes = [(1280, 800), (1024, 768), (1920, 1200)]
            if numbers.count == 2 {
                let preferred = (numbers[0], numbers[1])
                sizes.removeAll { $0 == preferred }
                sizes.insert(preferred, at: 0)
            }
            return sizes.map { crate_display_mode(width: UInt32($0.0), height: UInt32($0.1)) }
        }

        /// What the VM asked for, unless that wouldn't fit beside the app in
        /// what iOS lets crate have: the code region is already in the app's
        /// footprint, and the guest's memory counts as it touches it.
        static func memory(askedGB: Int) -> Int {
            let asked = askedGB * 1024
            let available = Int(os_proc_available_memory() >> 20)
            guard available > 0 else { return asked }
            // The JIT region is already in the footprint reflected by
            // `available`, but virgl, ANGLE, frame buffers and the rest of the
            // VM grow well beyond guest RAM under a heavy desktop workload.
            // With a 1920x1080 KDE desktop, Chromium and Electron, a 1792 MiB
            // reserve still let the process reach 5.75 of its 6 GiB limit;
            // iOS warned at 4.9 GiB, then ANGLE lost its GPU context. Keep
            // 2688 MiB beyond guest RAM so the GPU and iOS retain about 1.3
            // GiB during that measured workload instead of a few hundred MiB.
            let headroom = 2688
            let fits = max(1024, (available - headroom) / 2 * 2)
            return min(asked, fits)
        }

        /// For a VM put on the iPhone by hand from aTerm's image, which has no
        /// command line of its own: serial console, the disk as the root, and
        /// the desktop pulled in at boot (the image doesn't enable it).
        /// multi-user rather than the image's graphical target, which starts
        /// nothing the desktop service doesn't; no getty on tty1, which the
        /// desktop takes. An installed VM boots with its image's.
        static let commandLine = ([
            "console=ttyAMA0", "root=/dev/vda", "rw", "net.ifnames=0",
            "vt.global_cursor_default=0", "systemd.unit=multi-user.target",
            "systemd.wants=aterm-desktop.service",
        ] + [
            "systemd-timesyncd.service", "e2scrub_reap.service", "apt-daily.timer",
            "apt-daily-upgrade.timer", "man-db.timer",
            "getty@tty1.service", "getty@tty2.service", "getty@tty3.service",
            "getty@tty4.service", "getty@tty5.service", "getty@tty6.service",
        ].map { "systemd.mask=\($0)" }).joined(separator: " ")

        /// 3D on an iPhone, where the app embeds virglrenderer, ANGLE and
        /// MoltenVK (Scripts/build-virgl.sh and the rest); crate falls back to
        /// 2D, saying so in the log, if they don't load. The Simulator has none
        /// of them.
        #if targetEnvironment(simulator)
        static let gpu = CRATE_GPU_2D
        #else
        static let gpu = CRATE_GPU_VIRGL
        #endif
    }

    private enum Created {
        case success(OpaquePointer)
        case failure(String)
    }

    nonisolated private static func create(_ settings: Settings, region: crate_code_region,
                                           console: ConsoleBridge, display: DisplayBridge,
                                           audio: AudioBridge,
                                           credentialConsole: CredentialConsoleBridge,
                                           credentialSession: CredentialConsoleBridge.Session,
                                           context: UnsafeMutableRawPointer) -> Created {
        var keepCredentialSession = false
        defer {
            if !keepCredentialSession { credentialConsole.detach(credentialSession) }
        }
        guard let config = crate_config_new("virt") else { return .failure("crate doesn't know the virt board.") }
        defer { crate_config_free(config) }
        func check(_ status: crate_status, _ what: String) -> String? {
            status == CRATE_OK ? nil : "crate refused \(what): \(String(cString: crate_last_error()))."
        }
        let steps: [() -> String?] = [
            { check(crate_config_set_cpu_backend(config, CRATE_CPU_JIT), "the CPU backend") },
            { check(crate_config_set_cpus(config, UInt32(settings.cpus)), "\(settings.cpus) CPUs") },
            { check(crate_config_set_memory(config, UInt64(settings.memoryMiB) << 20), "\(settings.memoryMiB) MiB of memory") },
            { check(crate_config_set_jit_region(config, region.executable, region.writable, region.size), "the code region") },
            { check(crate_config_set_kernel(config, settings.kernel), "the kernel") },
            { check(crate_config_set_initrd(config, settings.initrd), "the initrd") },
            { check(crate_config_set_cmdline(config, settings.commandLine), "the kernel command line") },
            { check(crate_config_add_disk(config, settings.disk, 0), "the disk") },
            {
                guard let seed = settings.seed else { return nil }
                return check(crate_config_add_disk(config, seed, CRATE_DISK_READ_ONLY), "the first-boot settings")
            },
            {
                var network: UInt32 = 0
                return check(crate_config_add_network(config, &network), "the network")
            },
            {
                var callbacks = console.callbacks
                var index: UInt32 = 0
                return check(crate_config_add_console(config, CRATE_CONSOLE_SERIAL, &callbacks, &index), "the console")
            },
            {
                var callbacks = credentialConsole.callbacks
                var index: UInt32 = 0
                if let failure = check(crate_config_add_console(config, CRATE_CONSOLE_VIRTIO, &callbacks, &index),
                                       "the credential console") {
                    return failure
                }
                guard credentialConsole.configure(index: index, in: credentialSession) else {
                    return "the credential console session changed while crate was building the VM."
                }
                return nil
            },
            {
                var callbacks = display.callbacks
                var index: UInt32 = 0
                if let failure = check(crate_config_add_display(config, Settings.gpu, &callbacks, &index), "the display") {
                    return failure
                }
                let modes = settings.displayModes
                return check(crate_config_set_display_modes(config, index, modes, modes.count), "the display's sizes")
            },
            {
                var callbacks = audio.callbacks
                var index: UInt32 = 0
                return check(crate_config_add_sound(config, &callbacks, &index), "the sound card")
            },
            { check(crate_config_add_input(config, CRATE_INPUT_KEYBOARD | CRATE_INPUT_TABLET), "the keyboard and tablet") },
            {
                check(crate_config_set_state_callback(config, { context, state, reason in
                    guard let context, state == CRATE_STATE_STOPPED else { return }
                    let runner = Unmanaged<MachineRunner>.fromOpaque(context).takeUnretainedValue()
                    let error = reason == CRATE_STOP_ERROR ? String(cString: crate_last_error()) : nil
                    Task { @MainActor in runner.stopped(reason, error: error) }
                }, context), "the state callback")
            },
        ]
        for step in steps {
            if let failure = step() { return .failure(failure) }
        }
        var made: OpaquePointer?
        if let failure = check(crate_machine_create(config, &made), "to create the VM") { return .failure(failure) }
        guard let made else { return .failure("crate made no VM.") }
        keepCredentialSession = true
        return .success(made)
    }

    private func stopped(_ reason: crate_stop_reason, error: String?) {
        let text: String
        let forced = forcedStopMessage
        forcedStopMessage = nil
        if let forced {
            text = forced
        } else {
            switch reason {
            case CRATE_STOP_POWER_OFF: text = "The VM shut down."
            case CRATE_STOP_RESET: text = "The VM asked to restart."
            case CRATE_STOP_KILLED: text = "The VM was stopped."
            default: text = "The VM stopped: \(error ?? "crate gave no reason")."
            }
        }
        AppLog.write("vm: \(text)")
        memoryLog.stop()
        #if DEBUG
        debugHooks.stop()
        #endif
        if let credentialSession {
            credentialConsole.detach(credentialSession)
            self.credentialSession = nil
        }
        console.detach()
        display.detach()
        audio.detach()
        GuestToolServer.shared.stop()
        // Its memory goes back now rather than when the next VM starts: the
        // guest's RAM counts against crate's limit, which an install
        // meanwhile needs.
        if let machine {
            crate_machine_free(machine)
            self.machine = nil
            AppLog.write("vm: freed, footprint \(MemoryReport().footprint >> 20) MiB")
        }
        phase = forced != nil || reason == CRATE_STOP_ERROR ? .failed(text) : .stopped(text)
    }

    /// A lost ANGLE/Metal context cannot recover in-place. Stop promptly: if
    /// the guest keeps submitting commands, virglrenderer's failed fences can
    /// otherwise consume every CPU with logging and make Crate appear frozen.
    private func stopForLostGPU() {
        guard let machine, isRunning, forcedStopMessage == nil else { return }
        forcedStopMessage = "The VM stopped because iOS reset its GPU under memory pressure. Restart it; Crate reserved more GPU headroom for the next run."
        AppLog.write("vm: stopping after the GPU context was lost")
        crate_machine_kill(machine)
    }
}
