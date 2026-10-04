import Foundation
import Input
import System

/// Where every invocation's record leaves the process: to an OpenTelemetry collector over
/// OTLP/HTTP when one is configured, and appended as a line of JSON to a file when none is,
/// or when the one configured could not take it.
///
/// [LAW:single-enforcer] The one export edge. A record written to the file because the
/// collector failed says so on itself, in `sink_error`: a CLI invocation emits one record
/// and exits, so there is no later moment to report what was not delivered.
/// [LAW:nothing-unseen]
struct EventExport: Sendable {
    let collector: Collector?
    let file: URL
    let deliver: @Sendable (URLRequest) async throws -> Void

    /// The environment's collector, and `~/Library/Logs/vhid/events.jsonl`.
    static func configured(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> EventExport {
        EventExport(collector: Collector(environment),
                    file: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/vhid/events.jsonl"),
                    deliver: post)
    }

    /// An OpenTelemetry collector's logs endpoint and the headers it is sent, as the OTLP
    /// exporter environment variables name them: the logs-only variable over the general
    /// one, and an empty variable as unset, as the specification reads every one of them.
    /// Kept as written, and read when a record is sent, so that a variable that cannot be
    /// read is said on that record's `sink_error`.
    struct Collector: Sendable, Equatable {
        enum Endpoint: Sendable, Equatable {
            /// `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`: the logs URL itself.
            case logs(String)
            /// `OTEL_EXPORTER_OTLP_ENDPOINT`: the base URL the logs path `v1/logs` goes under.
            case base(String)
        }

        let endpoint: Endpoint
        /// `key=value` pairs, comma separated, each value percent-encoded.
        let headers: String?

        init(endpoint: Endpoint, headers: String? = nil) {
            (self.endpoint, self.headers) = (endpoint, headers)
        }

        init?(_ environment: [String: String]) {
            func set(_ name: String) -> String? { environment["OTEL_EXPORTER_OTLP_\(name)"].flatMap { $0.isEmpty ? nil : $0 } }
            guard let endpoint = set("LOGS_ENDPOINT").map(Endpoint.logs) ?? set("ENDPOINT").map(Endpoint.base) else { return nil }
            self.init(endpoint: endpoint, headers: set("LOGS_HEADERS") ?? set("HEADERS"))
        }

        var url: URL {
            get throws {
                let (variable, written) = switch endpoint {
                case .logs(let url): ("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", url)
                case .base(let url): ("OTEL_EXPORTER_OTLP_ENDPOINT", url)
                }
                guard let url = URL(string: written), ["http", "https"].contains(url.scheme) else {
                    throw Refused(description: "\(variable) \(written.debugDescription) is not an http or https URL")
                }
                return if case .base = endpoint { url.appending(path: "v1/logs") } else { url }
            }
        }

        var fields: [(name: String, value: String)] {
            get throws {
                try (headers ?? "").split(separator: ",").map { pair in
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2, let value = String(parts[1]).trimmingCharacters(in: .whitespaces).removingPercentEncoding else {
                        throw Refused(description: "OTLP headers \(String(pair).debugDescription) is not a key=value pair")
                    }
                    return (String(parts[0]).trimmingCharacters(in: .whitespaces), value)
                }
            }
        }
    }

    func export(_ record: InvocationRecord) async {
        let sink: InvocationRecord.Sink
        if let collector {
            do {
                return try await deliver(try Self.request(record, to: collector))
            } catch {
                sink = .fileAfter(collectorFailure: error.reported)
            }
        } else {
            sink = .file
        }
        // A record that cannot be written does not fail the verb it records, which did
        // what it did; it is said on stderr, where the verb's own diagnostics go.
        // [LAW:no-silent-failure]
        do {
            try append(try JSON.object(record.fields(sink: sink)).line)
        } catch {
            FileHandle.standardError.write(Data("vhid: the record of this \(record.event) was not written to \(file.path): \(error.reported)\n".utf8))
        }
    }

    /// One `write` with `O_APPEND`, so lines from processes appending at once do not
    /// interleave.
    private func append(_ line: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = try FileDescriptor.open(FilePath(file.path), .writeOnly, options: [.append, .create],
                                                 permissions: [.ownerReadWrite, .groupRead, .otherRead])
        try descriptor.closeAfter { _ = try descriptor.writeAll(line) }
    }

    struct Refused: Error, CustomStringConvertible {
        let description: String
    }

    /// An OTLP/HTTP JSON logs export of `record`, to the logs path under `collector`.
    ///
    /// The command line waits on this before it exits, so it is given two seconds: a
    /// collector that has not answered by then has not taken this record, and the file has.
    static func request(_ record: InvocationRecord, to collector: Collector) throws -> URLRequest {
        var request = URLRequest(url: try collector.url, timeoutInterval: 2)
        request.httpMethod = "POST"
        for (name, value) in try collector.fields { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try logs(record).line
        return request
    }

    /// `record` as OTLP's `ExportLogsServiceRequest`, in its JSON encoding: one log record
    /// whose attributes are the record's fields.
    static func logs(_ record: InvocationRecord) -> JSON {
        let nanoseconds = Int(record.startedAt.timeIntervalSince1970 * 1e9)
        let attributes = record.fields(sink: .otlp).sorted { $0.key < $1.key }.map { keyValue($0.key, $0.value) }
        let log: JSON = .object([
            "timeUnixNano": .string(String(nanoseconds)),
            "traceId": .string(record.traceID),
            "eventName": .string(record.event),
            "body": anyValue(.string(record.event)),
            "attributes": .array(attributes),
        ])
        return .object(["resourceLogs": .array([.object([
            "resource": .object(["attributes": .array([keyValue("service.name", .string(InvocationRecord.service))])]),
            "scopeLogs": .array([.object(["scope": .object(["name": .string(InvocationRecord.service)]), "logRecords": .array([log])])]),
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

    /// Sends `request`, and throws unless the collector answered 2xx.
    static let post: @Sendable (URLRequest) async throws -> Void = { request in
        let at = request.url?.absoluteString ?? ""
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Refused(description: "\(at): \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Refused(description: "\(at) answered HTTP \(status)")
        }
    }
}
