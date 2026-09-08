import CoreGraphics
import Testing
@testable import HelloXCore

struct CaptureServiceTests {
    @Test func alignsFractionalRetinaSelectionToPhysicalPixels() throws {
        let aligned = try #require(ScreenCaptureService.pixelAlignedRegion(
            CGRect(x: 10.2, y: 20.3, width: 100.1, height: 50.2),
            displayFrame: CGRect(x: 0, y: 0, width: 500, height: 400),
            scale: 2
        ))

        #expect(aligned.sourceRect == CGRect(x: 10, y: 20, width: 100.5, height: 50.5))
        #expect(aligned.capturedRect == aligned.sourceRect)
        #expect(aligned.pixelWidth == 201)
        #expect(aligned.pixelHeight == 101)
        #expect(aligned.sourceRect.width * 2 == CGFloat(aligned.pixelWidth))
        #expect(aligned.sourceRect.height * 2 == CGFloat(aligned.pixelHeight))
    }

    @Test func preservesGlobalDisplayOffsetAndClampsToDisplay() throws {
        let display = CGRect(x: -1_280, y: 140, width: 1_280, height: 800)
        let aligned = try #require(ScreenCaptureService.pixelAlignedRegion(
            CGRect(x: -1_281.4, y: 139.6, width: 120.7, height: 80.7),
            displayFrame: display,
            scale: 1
        ))

        #expect(aligned.sourceRect == CGRect(x: 0, y: 0, width: 120, height: 81))
        #expect(aligned.capturedRect == CGRect(x: -1_280, y: 140, width: 120, height: 81))
        #expect(aligned.pixelWidth == 120)
        #expect(aligned.pixelHeight == 81)
    }
}
