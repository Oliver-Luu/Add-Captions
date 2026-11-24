import CoreGraphics
import Testing
@testable import Add_Captions

@Suite("Logo")
struct LogoMarkTests {
    let rect = CGRect(x: 10, y: 20, width: 250, height: 200)

    private func filled(_ point: CGPoint) -> Bool {
        LogoMark.path(in: rect).contains(point, using: .evenOdd)
    }

    @Test func staysInsideItsRect() {
        let box = LogoMark.path(in: rect).boundingBoxOfPath
        #expect(abs(box.minX - rect.minX) < 0.01 && abs(box.minY - rect.minY) < 0.01)
        #expect(abs(box.maxX - rect.maxX) < 0.01 && abs(box.maxY - rect.maxY) < 0.01)
    }

    /// Even-odd filling must leave the screen hollow and fill the frame, play sign and caption lines.
    @Test func screenIsHollowAndItsPartsAreFilled() {
        #expect(filled(CGPoint(x: rect.minX + 5, y: rect.midY)))            // left edge of the frame
        #expect(!filled(CGPoint(x: rect.minX + 40, y: rect.minY + 40)))     // inside the screen, top left
        #expect(filled(CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.36)))   // play sign
        #expect(filled(CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.675)))  // long caption line
        #expect(filled(CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.825)))  // short caption line
        #expect(!filled(CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.75)))  // gap between the lines
    }

    @Test func captionLinesAreCentred() {
        let y = rect.minY + rect.height * 0.675
        let longHalf = rect.width * 0.56 / 2
        #expect(filled(CGPoint(x: rect.midX - longHalf + 6, y: y)))
        #expect(filled(CGPoint(x: rect.midX + longHalf - 6, y: y)))
        #expect(!filled(CGPoint(x: rect.midX - longHalf - 6, y: y)))
        #expect(!filled(CGPoint(x: rect.midX + longHalf + 6, y: y)))
    }
}
