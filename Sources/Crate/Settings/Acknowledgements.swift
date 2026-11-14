// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// One license text and who it covers: crate itself, or the components of
/// THIRD_PARTY_NOTICES.md that share it word for word.
struct Acknowledgement: Identifiable {
    let id: Int
    let names: [String]
    let text: String

    /// crate's own license, then every text from the notices, both bundled
    /// with the app (Scripts/third-party-notices.py writes the notices).
    static let all: [Acknowledgement] = {
        var entries: [Acknowledgement] = []
        if let license = bundled("LICENSE", ext: nil) {
            entries.append(Acknowledgement(id: 0, names: ["crate (MPL-2.0)"], text: license))
        }
        guard let notices = bundled("THIRD_PARTY_NOTICES", ext: "md"),
              let start = notices.range(of: "\n## License texts\n") else { return entries }
        // Each text is a "### names" heading (separated by "; "), then the text
        // in a ```` fence; headings inside a fence belong to the text.
        var names: [String] = []
        var lines: [Substring] = []
        var inText = false
        for line in notices[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            if inText {
                if line == "````" {
                    inText = false
                    entries.append(Acknowledgement(id: entries.count, names: names,
                                                   text: lines.joined(separator: "\n")))
                    lines = []
                } else {
                    lines.append(line)
                }
            } else if line.hasPrefix("### ") {
                names = line.dropFirst(4).components(separatedBy: "; ")
            } else if line.hasPrefix("````") {
                inText = true
            }
        }
        return entries
    }()

    private static func bundled(_ name: String, ext: String?) -> String? {
        Bundle.main.url(forResource: name, withExtension: ext)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// Settings > Acknowledgements: the licenses of crate and of everything it
/// carries from other projects.
struct AcknowledgementsScreen: View {
    @State private var search = ""

    private var shown: [Acknowledgement] {
        guard !search.isEmpty else { return Acknowledgement.all }
        return Acknowledgement.all.filter { entry in
            entry.names.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            List {
                Section {
                    ForEach(shown) { entry in
                        NavigationLink {
                            LicenseText(entry: entry)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(AuroraPalette.violet.opacity(0.14))
                                        .frame(width: 34, height: 34)
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AuroraPalette.violet)
                                }
                                Text(entry.names.joined(separator: "; "))
                                    .font(AuroraType.subheadline)
                                    .foregroundStyle(AuroraPalette.textPrimary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 3)
                        }
                        .listRowBackground(AuroraPalette.surface.opacity(0.75))
                    }
                } footer: {
                    if search.isEmpty {
                        Text(l10n: "licenses.footer")
                            .foregroundStyle(AuroraPalette.textTertiary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(L10n.string("licenses.title"))
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $search, prompt: L10n.string("licenses.search"))
    }
}

private struct LicenseText: View {
    let entry: Acknowledgement

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if entry.names.count > 1 {
                        Text(entry.names.joined(separator: "; "))
                            .font(AuroraType.subheadline)
                            .foregroundStyle(AuroraPalette.textSecondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    Text(entry.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(AuroraPalette.textSecondary)
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AuroraSpace.lg)
            }
        }
        .navigationTitle(entry.names.count > 1
                         ? L10n.format("licenses.more", entry.names[0], "\(entry.names.count - 1)")
                         : entry.names[0])
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
