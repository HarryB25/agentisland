import Foundation
import Network
import AgentIslandCore

/// Minimal HTTP/1.1 server that accepts OTLP/JSON log payloads on /v1/logs.
///
/// Why hand-rolled: avoiding SwiftNIO/Vapor keeps the dependency footprint
/// zero — we ship just two SPM targets. The protocol surface we need is
/// tiny: POST /v1/logs with a JSON body, return 200 OK.
///
/// Bind: 127.0.0.1:4318 (OTLP/HTTP default). If the port is occupied
/// (e.g. user also runs AgentNotch), failure is logged to stderr and the
/// receiver stays silent; the rest of AgentIsland keeps working.
final class OTLPReceiver {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentisland.otlp", qos: .utility)
    private let onEvent: (OTLPLogEnvelope) -> Void

    init(port: UInt16 = 4318, onEvent: @escaping (OTLPLogEnvelope) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 4318
        self.onEvent = onEvent
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: port)
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    FileHandle.standardError.write(Data("[AgentIsland] OTLP listening on 127.0.0.1:\(self.port.rawValue)/v1/logs\n".utf8))
                case .failed(let err):
                    FileHandle.standardError.write(Data("[AgentIsland] OTLP bind failed: \(err.localizedDescription)\n[AgentIsland] If port \(self.port.rawValue) is in use, Codex telemetry from this app will not work.\n".utf8))
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(connection: conn)
            }
            l.start(queue: queue)
            self.listener = l
        } catch {
            FileHandle.standardError.write(Data("[AgentIsland] OTLP listener init failed: \(error)\n".utf8))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        let parser = HTTPRequestParser()
        receiveLoop(connection: connection, parser: parser)
    }

    private func receiveLoop(connection: NWConnection, parser: HTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                parser.feed(data)
            }
            if let req = parser.takeIfReady() {
                self.respond(to: req, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveLoop(connection: connection, parser: parser)
        }
    }

    private func respond(to req: HTTPRequest, on connection: NWConnection) {
        let status: Int
        let bodyText: String
        if req.method == "POST", req.path == "/v1/logs" {
            do {
                let envelope = try OTLPLogEnvelope(json: req.body)
                onEvent(envelope)
                status = 200
                // OTLP success response per spec is an empty ExportLogsServiceResponse {}
                bodyText = "{}"
            } catch {
                status = 400
                bodyText = "{\"error\":\"\(error.localizedDescription)\"}"
            }
        } else if req.method == "POST", req.path == "/v1/metrics" || req.path == "/v1/traces" {
            // Accept silently to avoid noisy errors from clients sending all signals.
            status = 200
            bodyText = "{}"
        } else if req.method == "GET", req.path == "/healthz" {
            status = 200
            bodyText = "ok"
        } else {
            status = 404
            bodyText = "not found"
        }

        let bodyData = Data(bodyText.utf8)
        let response =
            "HTTP/1.1 \(status) \(statusText(status))\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n\r\n"
        var out = Data(response.utf8)
        out.append(bodyData)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default:  return "Status"
        }
    }
}

// MARK: - Minimal HTTP/1.1 request parser

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private final class HTTPRequestParser {
    private var buffer = Data()
    private var ready: HTTPRequest?
    private let headerSeparator = Data([0x0d, 0x0a, 0x0d, 0x0a])  // \r\n\r\n

    func feed(_ data: Data) {
        guard ready == nil else { return }
        buffer.append(data)
        tryParse()
    }

    func takeIfReady() -> HTTPRequest? {
        defer { ready = nil }
        return ready
    }

    private func tryParse() {
        guard let sepRange = buffer.range(of: headerSeparator) else { return }
        let headerData = buffer.subdata(in: 0..<sepRange.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return }

        var lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return }
        let method = parts[0]
        let pathWithQuery = parts[1]
        let path = pathWithQuery.split(separator: "?").first.map(String.init) ?? pathWithQuery

        var headers: [String: String] = [:]
        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sepRange.upperBound
        let bodyAvailable = buffer.count - bodyStart
        guard bodyAvailable >= contentLength else { return }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        ready = HTTPRequest(method: method, path: path, headers: headers, body: body)
        // Consume what we used (we don't pipeline)
        buffer.removeAll(keepingCapacity: false)
    }
}
