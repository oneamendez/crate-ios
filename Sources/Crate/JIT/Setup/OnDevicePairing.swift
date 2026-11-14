// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import IDevice

/// Pairs this iPhone with crate itself, so Built-in StikJIT needs no computer
/// and no pairing file. iOS 27 lets a device start a pairing with a computer
/// that advertises `_remotepairing-pairable-host._tcp`: crate advertises one,
/// the person picks "Pair with crate" under Settings > Privacy & Security >
/// Developer Mode, and types the 6-digit code crate shows. The result is a
/// RemotePairing record, kept as Built-in StikJIT's pairing file.
///
/// idevice (Frameworks/IDevice.xcframework, MIT) makes the host identity and
/// runs the pairing over a socket crate accepts; crate does the networking:
/// a listening socket, and the Bonjour service that points iOS at it. crate
/// also picks the code, so it can show it before the person leaves for
/// Settings (Scripts/patches/idevice-pairable-host.patch; upstream draws it only
/// once iOS has connected). iOS connects while crate is in the background
/// behind Settings, so the caller keeps crate running meanwhile
/// (PairingCodePictureInPicture).
final class OnDevicePairing: NSObject, @unchecked Sendable {
    enum Event: Equatable {
        /// Advertising; this is the code to type in Settings.
        case ready(code: String)
        /// Settings connected and is asking for the code.
        case connected
        case paired(Data)
        case failed(String)
    }

    /// How long to wait for the person to get to Settings and pick crate.
    static let timeout: TimeInterval = 600

    private let onEvent: @MainActor (Event) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var listener: Int32 = -1
    private var connection: Int32 = -1
    private var service: NetService?

    init(onEvent: @escaping @MainActor (Event) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        Thread.detachNewThread { [self] in
            let event = run()
            stopAdvertising()
            if !isCancelled { send(event) }
        }
    }

    /// Stops waiting, and ends a pairing under way: shutting its socket down
    /// fails idevice's read, so its thread returns.
    func cancel() {
        lock.withLock {
            cancelled = true
            if listener >= 0 { shutdown(listener, SHUT_RDWR) }
            if connection >= 0 { shutdown(connection, SHUT_RDWR) }
        }
        stopAdvertising()
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func send(_ event: Event) {
        Task { @MainActor in onEvent(event) }
    }

    // MARK: - The pairing, on its own thread

    private func run() -> Event {
        Self.startIdeviceLog()
        // A fresh host identity, and the TXT records iOS reads it from.
        var host: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txtBytes: UnsafeMutablePointer<UInt8>?
        var txtLength: UInt = 0
        if let message = consume(pairable_host_prepare("crate", nil, false, &host, &serviceID,
                                                       &txtBytes, &txtLength, nil)) {
            return .failed(L10n.format("pairing.error.prepare", message))
        }
        defer { pairable_host_free(host) }
        let name = serviceID.map { String(cString: $0) } ?? "crate"
        idevice_string_free(serviceID)
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        if let message = consume(pairable_host_set_setup_code(host, code)) {
            return .failed(L10n.format("pairing.error.code", message))
        }
        let txt = txtBytes.map { Data(bytes: $0, count: Int(txtLength)) } ?? Data()
        idevice_data_free(txtBytes, txtLength)
        guard let records = Self.txtRecords(fromPlist: txt) else {
            return .failed(L10n.string("pairing.error.details"))
        }

        // Where iOS connects: any address, a port the system picks.
        let (socket, port) = Self.listen()
        guard socket >= 0 else {
            return .failed(L10n.format("pairing.error.port", String(cString: strerror(errno))))
        }
        lock.withLock { listener = socket }
        defer {
            lock.withLock { listener = -1 }
            close(socket)
        }
        if let problem = advertise(name: name, port: port, txt: records) {
            return .failed(problem)
        }
        send(.ready(code: code))

        // Wait for Settings to connect, a little at a time so cancel() lands.
        let deadline = Date.now.addingTimeInterval(Self.timeout)
        var connection: Int32 = -1
        while connection < 0 {
            if isCancelled { return .failed(L10n.string("pairing.error.cancelled")) }
            if Date.now > deadline {
                return .failed(L10n.format("pairing.error.noConnection", "\(Int(Self.timeout / 60))"))
            }
            var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 500) > 0 else { continue }
            connection = accept(socket, nil, nil)
        }
        lock.withLock { self.connection = connection }
        defer {
            lock.withLock { self.connection = -1 }
            close(connection)
        }
        // Still advertised until the pairing ends (start() stops it): Settings
        // watches the service, and calls the pairing interrupted if crate
        // disappears while it asks for the passcode.
        AppLog.write("jit: pairing: Settings opened a connection")

        // iOS drives the pairing from here and idevice answers. The callback
        // comes when iOS asks for the code: crate's own, shown already.
        var pairingFile: OpaquePointer?
        let context = Unmanaged.passRetained(self)
        defer { context.release() }
        let callback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, context in
            guard let context else { return }
            Unmanaged<OnDevicePairing>.fromOpaque(context).takeUnretainedValue().send(.connected)
        }
        let result = consume(pairable_host_accept_fd(host, connection, callback, context.toOpaque(),
                                                     nil, &pairingFile))
        AppLog.write("jit: pairing: idevice returned \(result ?? "success")")
        if isCancelled { return .failed(L10n.string("pairing.error.cancelled")) }
        if let message = result {
            return .failed(L10n.format("pairing.error.finish", message))
        }
        defer { rp_pairing_file_free(pairingFile) }

        var bytes: UnsafeMutablePointer<UInt8>?
        var length: UInt = 0
        if let message = consume(rp_pairing_file_to_bytes(pairingFile, &bytes, &length)) {
            return .failed(L10n.format("pairing.error.keep", message))
        }
        let record = bytes.map { Data(bytes: $0, count: Int(length)) } ?? Data()
        idevice_data_free(bytes, length)
        return record.isEmpty ? .failed(L10n.string("pairing.error.noRecord")) : .paired(record)
    }

    /// idevice's own log of each pairing message, at Library/Caches/idevice.log,
    /// started once per launch (its logger can't be started twice).
    private static let ideviceLog: Void = {
        let path = URL.cachesDirectory.appendingPathComponent("idevice.log").path
        _ = path.withCString { idevice_init_logger(Disabled, Debug, UnsafeMutablePointer(mutating: $0)) }
    }()

    private static func startIdeviceLog() {
        _ = ideviceLog
    }

    /// idevice's error, as text, freed. Nil when there wasn't one.
    private func consume(_ error: UnsafeMutablePointer<IdeviceFfiError>?) -> String? {
        guard let error else { return nil }
        defer { idevice_error_free(error) }
        let message = error.pointee.message.map { String(cString: $0) } ?? "no message"
        return "\(message), code \(error.pointee.code)"
    }

    /// A listening TCP socket on every address, IPv6 and IPv4, and its port.
    private static func listen() -> (Int32, UInt16) {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return (-1, 0) }
        var off: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        address.sin6_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            close(fd)
            return (-1, 0)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: address.sin6_port))
    }

    /// The TXT records idevice hands over as an XML plist dictionary, as Bonjour wants them.
    private static func txtRecords(fromPlist data: Data) -> [String: Data]? {
        guard let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return dictionary.mapValues { value in
            switch value {
            case let data as Data: data
            case let string as String: Data(string.utf8)
            case let flag as Bool: Data((flag ? "true" : "false").utf8)
            default: Data("\(value)".utf8)
            }
        }
    }

    // MARK: - Bonjour

    /// Publishes the service on the main run loop and waits to hear it worked.
    /// Nil when it did, or what went wrong.
    private func advertise(name: String, port: UInt16, txt: [String: Data]) -> String? {
        let published = DispatchSemaphore(value: 0)
        var problem: String?
        DispatchQueue.main.async { [self] in
            let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.",
                                     name: name, port: Int32(port))
            service.setTXTRecord(NetService.data(fromTXTRecord: txt))
            let watcher = PublishWatcher { error in
                problem = error
                published.signal()
            }
            service.delegate = watcher
            objc_setAssociatedObject(service, &PublishWatcher.key, watcher, .OBJC_ASSOCIATION_RETAIN)
            lock.withLock { self.service = service }
            service.publish()
        }
        if published.wait(timeout: .now() + 10) == .timedOut {
            return L10n.string("pairing.error.advertise")
        }
        return problem
    }

    private func stopAdvertising() {
        let service = lock.withLock { () -> NetService? in
            defer { self.service = nil }
            return self.service
        }
        if let service {
            DispatchQueue.main.async { service.stop() }
        }
    }
}

/// Reports a NetService's publish result once.
private final class PublishWatcher: NSObject, NetServiceDelegate {
    nonisolated(unsafe) static var key = 0
    private var report: ((String?) -> Void)?

    init(report: @escaping (String?) -> Void) {
        self.report = report
    }

    func netServiceDidPublish(_ sender: NetService) {
        report?(nil)
        report = nil
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        // -72008 is "no permission": Local Network is off for crate.
        report?(code == -72008
                ? L10n.string("pairing.error.localNetwork")
                : L10n.format("pairing.error.advertiseCode", "\(code)"))
        report = nil
    }
}
