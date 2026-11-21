import CoreGraphics
import Seeing
import Testing
@testable import Pixels
@testable import Turns
import ScreenSpace

/// Two recognitions in flight crash the process inside Vision, so each one waits for the
/// process's one Vision turn.
@Suite(.timeLimit(.minutes(1))) struct VisionTurnTests {
    /// A blank image the size of `region`, which Vision reads as no text.
    private static func blank(_ region: ScreenRect) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: Int(region.width), height: Int(region.height), bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func aRecognitionWaitsForAHeldVisionTurn() async throws {
        let region = try ScreenRect(x: 0, y: 0, width: 64, height: 64)
        let image = try Self.blank(region)
        let recognised = try await PixelReader.vision.take(waited: {}) {
            let recognition = Task { try await PixelReader.recognise(image, of: region, in: region) }
            // Queued behind the turn this test holds, and still there.
            while await PixelReader.vision.queued == 0 { await Task.yield() }
            #expect(await PixelReader.vision.queued == 1)
            return recognition
        }
        #expect(try await recognised.value.isEmpty)
    }
}
