import CoreGraphics
import SwiftUI

/// The app's mark: a screen with a play sign and two caption lines along the bottom. It is the app
/// icon's drawing, and `Tools/make_icon.swift` holds a copy of `path(in:)`; keep the two the same.
///
/// The shape is meant to be filled with the even-odd rule (`FillStyle(eoFill: true)`), which cuts the
/// screen's inside out of its frame and fills the play sign and the lines inside it.
struct LogoMark: Shape {
    /// Width over height of the mark.
    static let aspectRatio: CGFloat = 1.25

    func path(in rect: CGRect) -> Path {
        Path(Self.path(in: rect))
    }

    /// The parts as shares of the mark's width (`w`) and height (`h`), with y going down.
    nonisolated static func path(in rect: CGRect) -> CGPath {
        let w = rect.width, h = rect.height
        let path = CGMutablePath()
        // The screen: a frame 0.075 w thick.
        let frame = rect
        let frameRadius = w * 0.17
        let thickness = w * 0.075
        path.addRoundedRect(in: frame, cornerWidth: frameRadius, cornerHeight: frameRadius)
        let inside = frame.insetBy(dx: thickness, dy: thickness)
        path.addRoundedRect(in: inside, cornerWidth: frameRadius - thickness, cornerHeight: frameRadius - thickness)
        // The play sign, centred in the top part of the screen.
        let triangleHeight = h * 0.3
        let triangleWidth = triangleHeight * 0.9
        let center = CGPoint(x: rect.midX + triangleWidth * 0.08, y: rect.minY + h * 0.36)
        path.move(to: CGPoint(x: center.x - triangleWidth / 2, y: center.y - triangleHeight / 2))
        path.addLine(to: CGPoint(x: center.x + triangleWidth / 2, y: center.y))
        path.addLine(to: CGPoint(x: center.x - triangleWidth / 2, y: center.y + triangleHeight / 2))
        path.closeSubpath()
        // Two caption lines, centred: a long one over a short one.
        for (width, y) in [(0.56, 0.63), (0.36, 0.78)] as [(CGFloat, CGFloat)] {
            let line = CGRect(x: rect.midX - w * width / 2, y: rect.minY + h * y, width: w * width, height: h * 0.095)
            path.addRoundedRect(in: line, cornerWidth: line.height / 2, cornerHeight: line.height / 2)
        }
        return path
    }
}

#Preview {
    LogoMark()
        .fill(.tint, style: FillStyle(eoFill: true))
        .aspectRatio(LogoMark.aspectRatio, contentMode: .fit)
        .frame(width: 200)
        .padding()
}
