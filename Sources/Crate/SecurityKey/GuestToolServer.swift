// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Network

/// Serves Crate's auditable Linux FIDO helper only to the VM-facing host
/// loopback. The guest reaches iOS loopback as 10.0.2.2 through libslirp.
/// Nothing here accepts credentials, reports, uploads, or arbitrary paths.
final class GuestToolServer: @unchecked Sendable {
    static let shared = GuestToolServer()
    static let port: UInt16 = 9432
    static let installCommand = "sudo apt update && sudo apt install -y curl && curl -fsS http://10.0.2.2:\(port)/install | sudo sh"

    private let queue = DispatchQueue(label: "com.amendez.crate.guest-tools", qos: .utility)
    private var listener: NWListener?
    private var archive: Data?
    private var activeConnections = 0

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        guard let url = Bundle.main.url(forResource: "crate-fido-bridge", withExtension: "tar.gz"),
              let archive = try? Data(contentsOf: url), !archive.isEmpty else {
            AppLog.write("guest tools: FIDO helper archive is missing")
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: Self.port)!
        )
        do {
            let listener = try NWListener(using: parameters)
            self.archive = archive
            self.listener = listener
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    AppLog.write("guest tools: installer available to the VM on 10.0.2.2:\(Self.port)")
                case .failed(let error):
                    AppLog.write("guest tools: installer server failed: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            self.archive = nil
            AppLog.write("guest tools: installer server could not start")
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.archive = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self else { connection.cancel(); return }
            guard self.activeConnections < 4 else {
                connection.cancel()
                return
            }
            self.activeConnections += 1
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection, bytes: Data())
        }
    }

    private func receiveRequest(on connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            self.queue.async {
                var request = bytes
                if let data { request.append(data) }
                if request.count > 4096 {
                    self.reply(status: "413 Payload Too Large", body: Data(), type: "text/plain", on: connection)
                } else if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.route(request, on: connection)
                } else if complete || error != nil {
                    self.finish(connection)
                } else {
                    self.receiveRequest(on: connection, bytes: request)
                }
            }
        }
    }

    private func route(_ request: Data, on connection: NWConnection) {
        guard let lineEnd = request.range(of: Data("\r\n".utf8))?.lowerBound,
              let line = String(data: request[..<lineEnd], encoding: .ascii) else {
            reply(status: "400 Bad Request", body: Data(), type: "text/plain", on: connection)
            return
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET",
              parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1" else {
            reply(status: "405 Method Not Allowed", body: Data(), type: "text/plain", on: connection)
            return
        }

        switch parts[1] {
        case "/crate-fido-bridge.tar.gz":
            guard let archive else {
                reply(status: "503 Service Unavailable", body: Data(), type: "text/plain", on: connection)
                return
            }
            reply(status: "200 OK", body: archive, type: "application/gzip", on: connection)
        case "/install":
            reply(status: "200 OK", body: Data(Self.bootstrap.utf8), type: "text/x-shellscript", on: connection)
        default:
            reply(status: "404 Not Found", body: Data(), type: "text/plain", on: connection)
        }
    }

    private func reply(status: String, body: Data, type: String,
                       on connection: NWConnection) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            guard let self else { connection.cancel(); return }
            self.queue.async { self.finish(connection) }
        })
    }

    private func finish(_ connection: NWConnection) {
        connection.cancel()
        activeConnections = max(0, activeConnections - 1)
    }

    private static let bootstrap = """
        #!/bin/sh
        set -eu
        [ "$(uname -s)" = Linux ] || { echo "crate-fido: Linux is required" >&2; exit 1; }
        [ "$(id -u)" -eq 0 ] || { echo "crate-fido: run through sudo" >&2; exit 1; }
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y build-essential kmod ca-certificates curl
        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT HUP INT TERM
        curl -fsS http://10.0.2.2:\(port)/crate-fido-bridge.tar.gz | tar -xz -C "$work"
        "$work/crate-fido-bridge/install.sh"
        """
}
