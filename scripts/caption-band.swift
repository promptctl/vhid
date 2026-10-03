// Renders film-demo's caption band: `swift caption-band.swift <width> <height> <dir>` reads
// `<second>\t<kind>\t<line>` rows on stdin and writes <dir>/band-<n>.png, the band as it
// stands once n rows have been added - its last three lines, the newest at the bottom, like
// a terminal. band-0 is the band before the first row: empty, in the band's own colour. The kind is who produced the line: narration reads dimmer than what was
// typed, and what a command printed is green. A line wider than the band ends in an
// ellipsis.
import AppKit

enum Kind: String {
    case narration, typed, printed

    var color: NSColor {
        switch self {
        case .narration: NSColor(white: 0.55, alpha: 1)
        case .typed: NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        case .printed: NSColor(srgbRed: 0.55, green: 0.85, blue: 0.6, alpha: 1)
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 4, let width = Int(arguments[1]), let height = Int(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: caption-band.swift <width> <height> <dir> < band.tsv\n".utf8))
    exit(64)
}
let directory = URL(fileURLWithPath: arguments[3])
let lines = AnyIterator { readLine() }.map { row -> (kind: Kind, text: String) in
    let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
    guard fields.count == 3, let kind = Kind(rawValue: String(fields[1])) else {
        FileHandle.standardError.write(Data("caption-band: not <second>\\t<narration|typed|printed>\\t<line>: \(row)\n".utf8))
        exit(65)
    }
    return (kind, String(fields[2]))
}

let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)
let background = NSColor(srgbRed: 0x16 / 255, green: 0x18 / 255, blue: 0x1d / 255, alpha: 1)
let leading: CGFloat = 38
let margin: CGFloat = 24
let truncated = NSMutableParagraphStyle()
truncated.lineBreakMode = .byTruncatingTail
for n in 0...lines.count {
    let shown = lines[max(0, n - 3)..<n]
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    background.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    // Bottom-up, newest line lowest.
    for (k, line) in shown.reversed().enumerated() {
        let row = NSRect(x: margin, y: 18 + CGFloat(k) * leading, width: CGFloat(width) - 2 * margin, height: leading)
        line.text.draw(in: row, withAttributes: [.font: font, .foregroundColor: line.kind.color, .paragraphStyle: truncated])
    }
    NSGraphicsContext.restoreGraphicsState()
    try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("band-\(n).png"))
}
