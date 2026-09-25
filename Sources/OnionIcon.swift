import UIKit

/// A simple concentric-rings onion glyph, drawn by hand since SF Symbols has
/// nothing like it, and rotated 180° from the first draft so the small
/// radiating lines point up from the top of the rings — closer to Tor
/// Project's own mark. Rendered as a template image so it tints exactly like
/// a system symbol wherever it's used.
enum OnionIcon {
    private static var cache: [CGFloat: UIImage] = [:]

    static func image(pointSize: CGFloat = 22) -> UIImage {
        if let cached = cache[pointSize] { return cached }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pointSize, height: pointSize))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            // Rotate 180° about the icon's center, then draw the original
            // (rings-with-roots-below) design — the rotation is what flips
            // the radiating lines to the top.
            cg.translateBy(x: pointSize / 2, y: pointSize / 2)
            cg.rotate(by: .pi)
            cg.translateBy(x: -pointSize / 2, y: -pointSize / 2)

            UIColor.black.setStroke()
            let center = CGPoint(x: pointSize / 2, y: pointSize * 0.44)
            let radii: [CGFloat] = [0.42, 0.28, 0.145].map { $0 * pointSize }
            cg.setLineWidth(max(1.2, pointSize * 0.075))
            cg.setLineCap(.round)
            for r in radii {
                cg.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
            let rootY = center.y + radii[0]
            let rootLen = pointSize * 0.16
            for dx: CGFloat in [-0.22, 0, 0.22] {
                cg.move(to: CGPoint(x: center.x + dx * pointSize, y: rootY - pointSize * 0.02))
                cg.addLine(to: CGPoint(x: center.x + dx * pointSize * 1.7, y: rootY + rootLen))
            }
            cg.strokePath()
        }
        let templated = image.withRenderingMode(.alwaysTemplate)
        cache[pointSize] = templated
        return templated
    }
}
