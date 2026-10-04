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
    /// The OTLP base URL, from `OTEL_EXPORTER_OTLP_ENDPOINT`.
    let collector: String?
    let file: URL
    let deliver: @Sendable (URLRequest) async throws -> Void

    /// The environment's collector, and `~/Library/Logs/vhid/events.jsonl`. An empty
    /// `OTEL_EXPORTER_OTLP_ENDPOINT` is unset, as the OpenTelemetry specification reads
    /// every one of its variables.
    static func configured(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> EventExport {
        EventExport(collector: environment["OTEL_EXPORTER_OTLP_ENDPOINT"].flatMap { $0.isEmpty ? nil : $0 },
                    file: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/vhid/events.jsonl"),
                    deliver: post)
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
    static func request(_ record: InvocationRecord, to collector: String) throws -> URLRequest {
        guard let base = URL(string: collector), ["http", "https"].contains(base.scheme) else {
            throw Refused(description: "OTEL_EXPORTER_OTLP_ENDPOINT \(collector.debugDescription) is not an http or https URL")
        }
        var request = URLRequest(url: base.appending(path: "v1/logs"), timeoutInterval: 2)
        request.httpMethod = "POST"
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
