import SwiftUI

/// The Slimg "squeeze" logomark, drawn natively.
///
/// Two chevrons pressing inward (`>` `<`) toward a central rounded vertical bar
/// — the slimmed image. Geometry is the canonical `0 0 100 100` grid from
/// `brand/logomark.svg` / BRAND.md §6:
///   - central bar: rounded rect x=45.5 y=26 w=9 h=48 rx=4.5
///   - left chevron:  (26,28) → (40,50) → (26,72), stroke width 9, round caps
///   - right chevron: (74,28) → (60,50) → (74,72)
///
/// It scales crisply at any size (used at ~20–22pt in the header, and as a
/// faint watermark in the empty drop zone).
struct BrandMark: View {
    /// Fill style for the mark. Defaults to the signature Slimg gradient.
    var style: AnyShapeStyle = AnyShapeStyle(Brand.gradient)

    /// Convenience: the gradient mark.
    static var gradient: BrandMark { BrandMark(style: AnyShapeStyle(Brand.gradient)) }

    /// Convenience: a monochrome mark in the given style (e.g. `.white`).
    static func mono(_ style: some ShapeStyle) -> BrandMark {
        BrandMark(style: AnyShapeStyle(style))
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 100.0
            // Stroke width 9 on the 100-grid; line caps/joins are round.
            let lineWidth = 9.0 * s
            ZStack {
                BrandChevrons()
                    .stroke(
                        style,
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                BrandBar()
                    .fill(style)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Slimg")
    }
}

/// The two inward-pointing chevrons, drawn on a 100×100 grid scaled to `rect`.
private struct BrandChevrons: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100.0
        let ox = rect.minX + (rect.width - 100 * s) / 2
        let oy = rect.minY + (rect.height - 100 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }

        var path = Path()
        // Left chevron, points right: (26,28) → (40,50) → (26,72)
        path.move(to: p(26, 28))
        path.addLine(to: p(40, 50))
        path.addLine(to: p(26, 72))
        // Right chevron, points left: (74,28) → (60,50) → (74,72)
        path.move(to: p(74, 28))
        path.addLine(to: p(60, 50))
        path.addLine(to: p(74, 72))
        return path
    }
}

/// The central vertical rounded bar — the slimmed image.
private struct BrandBar: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100.0
        let ox = rect.minX + (rect.width - 100 * s) / 2
        let oy = rect.minY + (rect.height - 100 * s) / 2
        let bar = CGRect(x: ox + 45.5 * s, y: oy + 26 * s, width: 9 * s, height: 48 * s)
        return Path(roundedRect: bar, cornerRadius: 4.5 * s, style: .continuous)
    }
}

#if DEBUG
struct BrandMark_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 24) {
            BrandMark.gradient.frame(width: 22, height: 22)
            BrandMark.gradient.frame(width: 64, height: 64)
            BrandMark.mono(.white).frame(width: 64, height: 64).background(.black)
        }
        .padding()
    }
}
#endif
