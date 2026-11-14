// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A system image crate can install: one entry in the catalog the images
/// repository publishes with each release (catalog.json), built and attested
/// by its GitHub workflow.
struct CatalogImage: Identifiable, Hashable, Decodable {
    /// "debian-kde": the distribution, then the desktop.
    let id: String
    /// "Debian".
    let name: String
    /// "13", "26.04 LTS", or the date it was built.
    let version: String
    /// "KDE Plasma".
    let desktop: String
    /// The kernel command line the image boots with.
    let cmdline: String
    let kernel: File
    let initrd: File
    let disk: Disk
    /// cloud-init vendor-data for the image, `{{user}}` standing for the
    /// owner's name: what its desktop needs for them, such as autologin.
    let vendorData: String?

    /// A file in the release, checked against its SHA-256.
    struct File: Hashable, Decodable {
        let url: URL
        let size: Int64
        let sha256: String
    }

    /// The raw disk, compressed and cut into parts.
    struct Disk: Hashable, Decodable {
        /// Bytes, raw: the filesystem the image ships with.
        let size: Int64
        /// Of the raw disk.
        let sha256: String
        /// "xz".
        let compression: String
        let parts: [File]
    }

    /// What its first word names: "debian" for "debian-kde".
    var distributionID: String {
        String(id.prefix { $0 != "-" })
    }

    var distribution: Distribution { .named(distributionID) }

    /// Everything downloaded.
    var downloadBytes: Int64 {
        kernel.size + initrd.size + disk.parts.reduce(0) { $0 + $1.size }
    }

    /// The disk as installed, before the guest writes to it, with the kernel
    /// and initrd beside it.
    var installedBytes: Int64 {
        disk.size + kernel.size + initrd.size
    }

    /// The VM this image becomes once installed.
    func machine(memoryGB: Int, diskGB: Int, cpuCount: Int = 4) -> Machine {
        Machine(distributionID: distributionID, version: version, codename: nil,
                cpuCount: cpuCount, memoryGB: memoryGB, diskGB: diskGB,
                diskUsedGB: Double(disk.size) / 1e9,
                desktop: desktop, display: "1280 × 800",
                imageID: id, cmdline: cmdline)
    }
}

/// The images crate can install, as the latest release lists them.
struct Catalog: Decodable {
    let release: String
    let images: [CatalogImage]

    /// The latest release's catalog.
    static let url = URL(string: "https://github.com/oneamendez/arm64-desktop-images/releases/latest/download/catalog.json")!

    static func fetch() async throws -> Catalog {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CatalogError.unavailable(http.statusCode)
        }
        return try JSONDecoder().decode(Catalog.self, from: data)
    }
}

enum CatalogError: LocalizedError {
    case unavailable(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable(let status): L10n.format("catalog.error.unavailable", "\(status)")
        }
    }
}
