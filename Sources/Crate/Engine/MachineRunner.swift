// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CrateEngine
import Foundation
import Observation

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
    let display = DisplayBridge()
    private var machine: OpaquePointer?
    /// crate's memory in the log while the VM runs.
    private let memoryLog = MemoryLog()
    #if DEBUG
    private let debugHooks = DebugHooks()
    #endif

    init() {
        crate_set_log_callback({ _, level, message in
            guard let message else { return }
            let tag = level == CRATE_LOG_ERROR ? "crate error: " : level == CRATE_LOG_WARN ? "crate warning: " : "crate: "
            AppLog.write(tag + String(cString: message))
        }, nil, Self.logLevel)
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
        console.reset()
        display.reset()
        let settings = Settings(vm: vm, files: files, display: display)
        AppLog.write("vm: starting \(vm.name): \(settings.cpus) CPUs, \(settings.memoryMiB) MiB, "
                     + "code \(region.size >> 20) MiB; \(settings.commandLine)")
        let console = self.console
        let display = self.display
        let context = Unmanaged.passUnretained(self).toOpaque()
        Task.detached(priority: .userInitiated) {
            let started = Date.now
            let result = Self.create(settings, region: region, console: console, display: display, context: context)
            await MainActor.run {
                switch result {
                case .success(let made):
                    self.machine = made
                    console.attach(machine: made)
                    display.attach(machine: made)
                    if crate_machine_start(made) == CRATE_OK {
                        AppLog.write(String(format: "vm: running, created in %.2f s", Date.now.timeIntervalSince(started)))
                        self.phase = .running
                        self.memoryLog.start()
                        #if DEBUG
                        self.debugHooks.start(console: console, display: display)
                        #endif
                    } else {
                        self.phase = .failed("crate couldn't start the VM: \(String(cString: crate_last_error())).")
                    }
                case .failure(let message):
                    AppLog.write("vm: \(message)")
                    self.phase = .failed(message)
                }
            }
        }
    }

    /// Stops the VM at once, as pulling the plug does: crate's virt board has
    /// no power button yet to ask the guest to shut down.
    func stop() {
        guard let machine, isRunning else { return }
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
        let portForwards: [PortForward]
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
            portForwards = vm.portForwards ?? []
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
            let headroom = 768
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
                                           context: UnsafeMutableRawPointer) -> Created {
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
                if let failure = check(crate_config_add_network(config, &network), "the network") {
                    return failure
                }
                for rule in settings.portForwards {
                    let status = crate_config_add_port_forward(config, network, CRATE_TCP, "127.0.0.1",
                                                               rule.hostPort, rule.guestPort)
                    if let failure = check(status, "port forward \(rule.hostPort) → \(rule.guestPort)") {
                        return failure
                    }
                }
                return nil
            },
            {
                var callbacks = console.callbacks
                var index: UInt32 = 0
                return check(crate_config_add_console(config, CRATE_CONSOLE_SERIAL, &callbacks, &index), "the console")
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
        return .success(made)
    }

    private func stopped(_ reason: crate_stop_reason, error: String?) {
        let text: String
        switch reason {
        case CRATE_STOP_POWER_OFF: text = "The VM shut down."
        case CRATE_STOP_RESET: text = "The VM asked to restart."
        case CRATE_STOP_KILLED: text = "The VM was stopped."
        default: text = "The VM stopped: \(error ?? "crate gave no reason")."
        }
        AppLog.write("vm: \(text)")
        memoryLog.stop()
        #if DEBUG
        debugHooks.stop()
        #endif
        console.detach()
        display.detach()
        // Its memory goes back now rather than when the next VM starts: the
        // guest's RAM counts against crate's limit, which an install
        // meanwhile needs.
        if let machine {
            crate_machine_free(machine)
            self.machine = nil
            AppLog.write("vm: freed, footprint \(MemoryReport().footprint >> 20) MiB")
        }
        phase = reason == CRATE_STOP_ERROR ? .failed(text) : .stopped(text)
    }
}
