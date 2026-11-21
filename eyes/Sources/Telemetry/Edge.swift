import Foundation
import System

/// Where every record leaves the process: to an OpenTelemetry collector over OTLP/HTTP when
/// one is configured, and appended as a line of JSON to a file when none is, or when the one
/// configured could not take it.
///
/// [LAW:single-enforcer] The one export edge, for vhid's invocations and eyes' units alike,
/// so one process reads the OTLP environment once, by one rule, and writes one file. A record
/// written to the file because the collector failed says so on itself, in `sink_error`: a
/// command line emits and exits, so there is no later moment to report what was not
/// delivered. [LAW:nothing-unseen]
public struct Edge: Sendable {
    /// OpenTelemetry's `service.name`: the process's, so every record it sends - a vhid
    /// call's, and a look's inside it - is found under one service.
    public let service: String
    public let collector: Collector?
    public let file: URL
    public let deliver: @Sendable (URLRequest) async throws -> Void

    public init(service: String, collector: Collector?, file: URL, deliver: @escaping @Sendable (URLRequest) async throws -> Void) {
        (self.service, self.collector, self.file, self.deliver) = (service, collector, file, deliver)
    }

    /// The environment's collector, and `~/Library/Logs/<service>/events.jsonl`.
    public static func configured(service: String, _ environment: [String: String] = ProcessInfo.processInfo.environment) -> Edge {
        Edge(service: service, collector: Collector(environment),
             file: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/\(service)/events.jsonl"),
             deliver: post)
    }

    /// This process's edge, named for its executable: `vhid` or `eyes`.
    public static let standard = configured(service: ProcessInfo.processInfo.processName)

    /// An OpenTelemetry collector's logs endpoint and the headers it is sent, as the OTLP
    /// exporter environment variables name them: the logs-only variable over the general
    /// one, and an empty variable as unset, as the specification reads every one of them.
    /// Kept as written, and read when a record is sent, so that a variable that cannot be
    /// read is said on that record's `sink_error`.
    public struct Collector: Sendable, Equatable {
        public enum Endpoint: Sendable, Equatable {
            /// `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`: the logs URL itself.
            case logs(String)
            /// `OTEL_EXPORTER_OTLP_ENDPOINT`: the base URL the logs path `v1/logs` goes under.
            case base(String)
        }

        public let endpoint: Endpoint
        /// `key=value` pairs, comma separated, each value percent-encoded.
        public let headers: String?
        public let `protocol`: String?

        public init(endpoint: Endpoint, headers: String? = nil, protocol: String? = nil) {
            (self.endpoint, self.headers, self.protocol) = (endpoint, headers, `protocol`)
        }

        /// Also read: `OTEL_SDK_DISABLED=true` and `OTEL_LOGS_EXPORTER=none` turn the
        /// collector off, and a `grpc` protocol, which this does not speak, is refused on the
        /// record rather than sent JSON it cannot read.
        public init?(_ environment: [String: String]) {
            func set(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
            func otlp(_ name: String) -> String? { set("OTEL_EXPORTER_OTLP_LOGS_\(name)") ?? set("OTEL_EXPORTER_OTLP_\(name)") }
            guard set("OTEL_SDK_DISABLED")?.lowercased() != "true", set("OTEL_LOGS_EXPORTER") != "none",
                  let endpoint = set("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT").map(Endpoint.logs) ?? set("OTEL_EXPORTER_OTLP_ENDPOINT").map(Endpoint.base)
            else { return nil }
            self.init(endpoint: endpoint, headers: otlp("HEADERS"), protocol: otlp("PROTOCOL"))
        }

        /// Refusals never quote what was written: an endpoint can carry a password, and a
        /// refusal is written to the file.
        public var url: URL {
            get throws {
                guard `protocol` != "grpc" else {
                    throw Refused(description: "OTEL_EXPORTER_OTLP_PROTOCOL is grpc, and this sends OTLP/HTTP JSON")
                }
                let (variable, written) = switch endpoint {
                case .logs(let url): ("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", url)
                case .base(let url): ("OTEL_EXPORTER_OTLP_ENDPOINT", url)
                }
                guard let url = URL(string: written), ["http", "https"].contains(url.scheme) else {
                    throw Refused(description: "\(variable) is not an http or https URL")
                }
                return if case .base = endpoint { url.appending(path: "v1/logs") } else { url }
            }
        }

        var fields: [(name: String, value: String)] {
            get throws {
                try (headers ?? "").split(separator: ",").enumerated().map { index, pair in
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    // By position: a header is where a collector's token goes.
                    guard parts.count == 2, let value = String(parts[1]).trimmingCharacters(in: .whitespaces).removingPercentEncoding else {
                        throw Refused(description: "OTLP header \(index + 1) is not a key=value pair with its value percent-encoded")
                    }
                    return (String(parts[0]).trimmingCharacters(in: .whitespaces), value)
                }
            }
        }
    }

    /// Where a record went: to the collector, or to the file - because no collector is
    /// configured, or because the one configured could not take it.
    enum Sink: Sendable, Equatable {
        case otlp
        case file
        case fileAfter(collectorFailure: String)
    }

    public func send(_ record: Record) async {
        let sink: Sink
        if let collector {
            do {
                return try await deliver(try request(record, to: collector))
            } catch {
                sink = .fileAfter(collectorFailure: "\(error)")
            }
        } else {
            sink = .file
        }
        // A record that cannot be written does not fail the work it records, which did what
        // it did; it is said on stderr, the last place left to say it. [LAW:no-silent-failure]
        do {
            try append(try JSON.object(fields(record, sink: sink)).line)
        } catch {
            FileHandle.standardError.write(Data("\(service): the record of this \(record.event) was not written to \(file.path): \(error)\n".utf8))
        }
    }

    /// The record as named fields, the one rendering both the file's line and the
    /// collector's attributes are made from. [LAW:one-source-of-truth]
    func fields(_ record: Record, sink: Sink) -> [String: JSON] {
        var fields = record.fields.merging([
            "event": .string(record.event),
            "trace_id": .string(record.traceID),
            "service": .string(service),
            "started_at": .string(record.startedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
        ]) { $1 }
        switch sink {
        case .otlp: fields["sink"] = .string("otlp")
        case .file: fields["sink"] = .string("file")
        case .fileAfter(let failure): (fields["sink"], fields["sink_error"]) = (.string("file"), .string(failure))
        }
        return fields
    }

    /// One `write` with `O_APPEND`, so lines from processes appending at once do not
    /// interleave. Readable by its owner alone: it is a record of what this person had
    /// their keyboard and mouse do and what their screen showed.
    private func append(_ line: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = try FileDescriptor.open(FilePath(file.path), .writeOnly, options: [.append, .create],
                                                 permissions: .ownerReadWrite)
        try descriptor.closeAfter { _ = try descriptor.writeAll(line) }
    }

    public struct Refused: Error, CustomStringConvertible {
        public let description: String
    }

    /// An OTLP/HTTP JSON logs export of `record`, to the logs path under `collector`.
    ///
    /// A command line waits on this before it exits, so it is given two seconds: a collector
    /// that has not answered by then has not taken this record, and the file has.
    func request(_ record: Record, to collector: Collector) throws -> URLRequest {
        var request = URLRequest(url: try collector.url, timeoutInterval: 2)
        request.httpMethod = "POST"
        for (name, value) in try collector.fields { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try logs(record).line
        return request
    }

    /// `record` as OTLP's `ExportLogsServiceRequest`, in its JSON encoding: one log record
    /// whose attributes are the record's fields.
    func logs(_ record: Record) -> JSON {
        let nanoseconds = Int(record.startedAt.timeIntervalSince1970 * 1e9)
        let attributes = fields(record, sink: .otlp).sorted { $0.key < $1.key }.map { Self.keyValue($0.key, $0.value) }
        let log: JSON = .object([
            "timeUnixNano": .string(String(nanoseconds)),
            "traceId": .string(record.traceID),
            "eventName": .string(record.event),
            "body": Self.anyValue(.string(record.event)),
            "attributes": .array(attributes),
        ])
        return .object(["resourceLogs": .array([.object([
            "resource": .object(["attributes": .array([Self.keyValue("service.name", .string(service))])]),
            "scopeLogs": .array([.object(["scope": .object(["name": .string(service)]), "logRecords": .array([log])])]),
        ])])])
    }

    private static func keyValue(_ key: String, _ value: JSON) -> JSON {
        .object(["key": .string(key), "value": anyValue(value)])
    }

    /// OTLP's `AnyValue`. An int64 is a decimal string in OTLP's JSON encoding.
    private static func anyValue(_ value: JSON) -> JSON {
        switch value {
        case .string(let string): .object(["stringValue": .string(string)])
        case .int(let int): .object(["intValue": .string(String(int))])
        case .double(let double): .object(["doubleValue": .double(double)])
        case .array(let values): .object(["arrayValue": .object(["values": .array(values.map(anyValue))])])
        case .object(let fields): .object(["kvlistValue": .object(["values": .array(fields.sorted { $0.key < $1.key }.map { keyValue($0.key, $0.value) })])])
        }
    }

    /// A request's `timeoutInterval` bounds only the silence between packets; this bounds
    /// the whole exchange, which is what the two seconds a command line waits on are.
    private static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 2
        return configuration
    }())

    /// Sends `request`, and throws unless the collector answered 2xx.
    public static let post: @Sendable (URLRequest) async throws -> Void = { request in
        // Without the URL's user and password, which a refusal must not carry into the file.
        let at = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            .map { var bare = $0; (bare.user, bare.password) = (nil, nil); return bare.string ?? "" } ?? ""
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw Refused(description: "\(at): \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Refused(description: "\(at) answered HTTP \(status)")
        }
    }
}
