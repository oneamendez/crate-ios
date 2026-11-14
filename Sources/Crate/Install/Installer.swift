// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Compression
import CryptoKit
import Foundation
import Observation
import UIKit

/// Installs a catalog image as a new VM: downloads its kernel, initrd and
/// disk, checks each against the catalog's SHA-256, unpacks the disk as its
/// parts arrive, grows it to the VM's size, and writes the owner's settings
/// for the first boot (SeedDisk).
///
/// The download runs while crate is open, with the screen kept awake; leaving
/// crate stops it, and its files go at the next launch (MachineStore).
@MainActor
@Observable
final class Installer {
    enum Phase: Equatable, Sendable {
        case idle
        /// Bytes downloaded so far of all there is to download.
        case downloading(done: Int64, total: Int64)
        /// Bytes of the disk unpacked so far, of its whole size.
        case unpacking(done: Int64, total: Int64)
        case finishing
        case done(Machine)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var image: CatalogImage?
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .downloading, .unpacking, .finishing: true
        default: false
        }
    }

    func install(_ image: CatalogImage, memoryGB: Int, diskGB: Int, cpuCount: Int = 4,
                 owner: SeedDisk, into store: MachineStore) {
        guard !isBusy else { return }
        self.image = image
        let machine = image.machine(memoryGB: memoryGB, diskGB: diskGB, cpuCount: cpuCount)
        let files = GuestFiles(for: machine)
        phase = .downloading(done: 0, total: image.downloadBytes)
        AppLog.write("install: \(image.id) \(image.version) as \(machine.id), "
                     + "footprint \(MemoryReport().footprint >> 20) MiB")
        let reporter = Reporter { [weak self] phase in self?.phase = phase }
        // Locking the screen would suspend crate and end the install.
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                try await Self.run(image, files: files, diskBytes: Int64(diskGB) << 30, owner: owner,
                                   instance: machine.id, reporter: reporter)
                store.add(machine)
                AppLog.write("install: \(image.id) done")
                phase = .done(machine)
            } catch {
                files.remove()
                if Task.isCancelled {
                    AppLog.write("install: \(image.id) cancelled")
                    phase = .idle
                } else {
                    AppLog.write("install: \(image.id) failed: \(error)")
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func reset() {
        guard !isBusy else { return }
        phase = .idle
    }

    // MARK: - The work, off the main actor

    private nonisolated static func run(_ image: CatalogImage, files: GuestFiles, diskBytes: Int64,
                                        owner: SeedDisk, instance: UUID, reporter: Reporter) async throws {
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let downloader = Downloader()
        let total = image.downloadBytes
        var downloaded: Int64 = 0
        func fetch(_ file: CatalogImage.File, to url: URL) async throws {
            let before = downloaded
            try await downloader.download(file, to: url) { bytes in
                reporter.send(.downloading(done: before + bytes, total: total))
            }
            downloaded += file.size
        }

        try await fetch(image.kernel, to: files.kernel)
        try await fetch(image.initrd, to: files.initrd)

        guard image.disk.compression == "xz" else { throw InstallError.unsupported(image.disk.compression) }
        var logged: Int64 = 0
        let unpacker = try DiskUnpacker(to: files.disk) { written in
            reporter.send(.unpacking(done: written, total: image.disk.size))
            if written - logged >= 1 << 30 {
                logged = written
                let memory = MemoryReport()
                AppLog.write("install: unpacked \(written >> 20) MiB, footprint \(memory.footprint >> 20) MiB")
            }
        }
        let temporary = files.directory.appendingPathComponent("part.download")
        for part in image.disk.parts {
            try await fetch(part, to: temporary)
            AppLog.write("install: downloaded \(part.url.lastPathComponent), unpacking; "
                         + "footprint \(MemoryReport().footprint >> 20) MiB")
            try unpacker.unpack(part: temporary)
            try FileManager.default.removeItem(at: temporary)
        }
        reporter.send(.finishing, now: true)
        let (written, digest) = try unpacker.finish()
        guard written == image.disk.size, digest == image.disk.sha256 else {
            throw InstallError.corrupt("the disk")
        }
        // Grown sparsely: the guest's filesystem grows into it on the first boot.
        try unpacker.extend(to: diskBytes)
        try owner.write(to: files.seed, instance: instance)
    }
}

enum InstallError: LocalizedError {
    case download(Int)
    case corrupt(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .download(let status): L10n.format("install.error.download", "\(status)")
        case .corrupt(let what): L10n.format("install.error.corrupt", what)
        case .unsupported(let kind): L10n.format("install.error.unsupported", kind)
        }
    }
}

/// Hands the main actor where an install has got to, a few times a second at
/// most.
private final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let report: @MainActor (Installer.Phase) -> Void

    init(report: @escaping @MainActor (Installer.Phase) -> Void) {
        self.report = report
    }

    func send(_ phase: Installer.Phase, now: Bool = false) {
        let due = lock.withLock { () -> Bool in
            guard now || Date.now.timeIntervalSince(last) > 0.25 else { return false }
            last = .now
            return true
        }
        if due { Task { @MainActor in report(phase) } }
    }
}

/// Downloads with a session of its own, whose delegate hears each file's
/// progress (the async URLSession calls don't pass it on), and checks each
/// file's size and SHA-256.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<Void, Error>
        let progress: (Int64) -> Void
        let destination: URL
        var moved: Error?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    deinit {
        session.invalidateAndCancel()
    }

    func download(_ file: CatalogImage.File, to url: URL, progress: @escaping (Int64) -> Void) async throws {
        let task = session.downloadTask(with: file.url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(continuation: continuation, progress: progress,
                                                           destination: url)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        guard try Self.sha256(of: url) == file.sha256 else {
            throw InstallError.corrupt(file.url.lastPathComponent)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = lock.withLock { pending[downloadTask.taskIdentifier]?.progress }
        progress?(totalBytesWritten)
    }

    /// The file is gone once this returns, so it's moved into place here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination = lock.withLock({ pending[downloadTask.taskIdentifier]?.destination }) else { return }
        var failure: Error?
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = InstallError.download(http.statusCode)
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }
        lock.withLock { pending[downloadTask.taskIdentifier]?.moved = failure }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let done = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = error ?? done.moved {
            done.continuation.resume(throwing: failure)
        } else {
            done.continuation.resume()
        }
    }

    /// A chunk at a time, each let go before the next: FileHandle's reads
    /// are autoreleased, and the pool this thread drains at some later point
    /// would otherwise hold a whole disk part, gigabytes over crate's limit.
    private static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
