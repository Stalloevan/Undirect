import UIKit

/// A layered onion-bulb glyph, drawn by hand since SF Symbols has nothing
/// like it. Rendered as a template image so it tints exactly like a system
/// symbol wherever it's used.
enum OnionIcon {
    private static var cache: [CGFloat: UIImage] = [:]

    static func image(pointSize: CGFloat = 22) -> UIImage {
        if let cached = cache[pointSize] { return cached }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pointSize, height: pointSize))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor.black.setStroke()
            cg.setLineWidth(max(1.1, pointSize * 0.062))
            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            // A rounded bulb tapering to a point at top, in unit space (0...1),
            // centered on (0.5, 0.58). Reused at a few scales for the "layers".
            let center = CGPoint(x: pointSize * 0.5, y: pointSize * 0.58)
            func point(_ x: CGFloat, _ y: CGFloat, scale: CGFloat) -> CGPoint {
                CGPoint(x: center.x + (x - 0.5) * pointSize * scale,
                        y: center.y + (y - 0.58) * pointSize * scale)
            }
            func bulbPath(scale: CGFloat) -> UIBezierPath {
                let path = UIBezierPath()
                path.move(to: point(0.50, 0.16, scale: scale))
                path.addCurve(to: point(0.19, 0.46, scale: scale),
                              controlPoint1: point(0.31, 0.18, scale: scale),
                              controlPoint2: point(0.19, 0.29, scale: scale))
                path.addCurve(to: point(0.50, 0.96, scale: scale),
                              controlPoint1: point(0.19, 0.68, scale: scale),
                              controlPoint2: point(0.31, 0.93, scale: scale))
                path.addCurve(to: point(0.81, 0.46, scale: scale),
                              controlPoint1: point(0.69, 0.93, scale: scale),
                              controlPoint2: point(0.81, 0.68, scale: scale))
                path.addCurve(to: point(0.50, 0.16, scale: scale),
                              controlPoint1: point(0.81, 0.29, scale: scale),
                              controlPoint2: point(0.69, 0.18, scale: scale))
                path.close()
                return path
            }

            bulbPath(scale: 1.0).stroke()
            bulbPath(scale: 0.60).stroke()
            bulbPath(scale: 0.30).stroke()

            // Sprout at the top of the bulb.
            let tip = point(0.50, 0.16, scale: 1.0)
            cg.move(to: tip)
            cg.addLine(to: CGPoint(x: tip.x, y: tip.y - pointSize * 0.14))
            cg.move(to: tip)
            cg.addLine(to: CGPoint(x: tip.x - pointSize * 0.09, y: tip.y - pointSize * 0.08))
            cg.strokePath()

            // Roots at the bottom.
            let bottom = point(0.50, 0.96, scale: 1.0)
            for dx: CGFloat in [-0.13, 0, 0.13] {
                cg.move(to: CGPoint(x: bottom.x + dx * pointSize, y: bottom.y - pointSize * 0.015))
                cg.addLine(to: CGPoint(x: bottom.x + dx * pointSize * 1.7, y: bottom.y + pointSize * 0.11))
            }
            cg.strokePath()
        }
        let templated = image.withRenderingMode(.alwaysTemplate)
        cache[pointSize] = templated
        return templated
    }
}
