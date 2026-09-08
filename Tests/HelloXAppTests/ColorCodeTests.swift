import AppKit
import Testing
@testable import HelloXApp

@Suite("Color Code")
struct ColorCodeTests {
    @Test func formatsOpaqueColorCodes() {
        let code = ColorCode(red: 51, green: 102, blue: 255)

        #expect(code.hex == "#3366FF")
        #expect(code.rgb == "rgb(51, 102, 255)")
        #expect(code.hsl == "hsl(225, 100%, 60%)")
    }

    @Test func includesAlphaWhenColorIsTranslucent() {
        let code = ColorCode(red: 255, green: 0, blue: 128, alpha: 128)

        #expect(code.hex == "#FF008080")
        #expect(code.rgb == "rgba(255, 0, 128, 0.5)")
        #expect(code.hsl == "hsla(330, 100%, 50%, 0.5)")
    }

    @Test func convertsExtendedValuesIntoSRGBBytes() {
        let code = ColorCode(color: NSColor(
            srgbRed: 0.2,
            green: 0.4,
            blue: 1,
            alpha: 1
        ))

        #expect(code == ColorCode(red: 51, green: 102, blue: 255))
    }

    @Test func clampsInvalidComponentValues() {
        let code = ColorCode(red: -10, green: 300, blue: 42, alpha: 999)

        #expect(code == ColorCode(red: 0, green: 255, blue: 42))
    }
}
