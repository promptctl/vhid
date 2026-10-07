import Eyes
import Testing
@testable import EyesCommand

/// Every rectangle in a printed line, each read back as `--rect` reads it, in order. A
/// field of four comma-separated numbers is a rectangle; one that `--rect` refuses fails the
/// test, and so does any field still in the `x,y WxH` spelling it replaced, so a printer
/// cannot print a rectangle that cannot be pasted into `--rect`.
func printedRects(_ line: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [ScreenRect] {
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    #expect(!fields.contains { $0.wholeMatch(of: /\d+x\d+/) != nil }, "a rectangle in the old spelling: \(line)", sourceLocation: sourceLocation)
    return try fields.filter { $0.wholeMatch(of: /-?[\d.]+(,-?[\d.]+){3}/) != nil }.map { field in
        guard case .region(.rect(let rect)) = try Where.place(display: nil, window: nil, page: nil, rect: field, as: .flag) else {
            Issue.record("\(field) did not read as a rect", sourceLocation: sourceLocation)
            return ScreenRect(x: 0, y: 0, width: 0, height: 0)
        }
        return rect
    }
}
