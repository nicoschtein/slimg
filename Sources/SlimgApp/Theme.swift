import SwiftUI

/// Slimg brand tokens and reusable styles.
///
/// Colors are defined in code (sRGB) per `brand/BRAND.md` §8 — the package
/// builds with SwiftPM, so there is no `.xcassets` catalog. All values support
/// both light and dark appearance; system colors are used where they belong.
enum Brand {
    // MARK: - Brand core (BRAND.md §8)

    static let teal400 = Color(red: 0.176, green: 0.831, blue: 0.749) // #2DD4BF
    static let teal500 = Color(red: 0.078, green: 0.722, blue: 0.651) // #14B8A6
    static let teal600 = Color(red: 0.051, green: 0.580, blue: 0.533) // #0D9488
    static let cyan500 = Color(red: 0.024, green: 0.714, blue: 0.831) // #06B6D4
    static let mint300 = Color(red: 0.369, green: 0.918, blue: 0.831) // #5EEAD4

    // MARK: - Semantic

    static let success = Color(red: 0.133, green: 0.773, blue: 0.369) // #22C55E
    static let warning = Color(red: 0.961, green: 0.620, blue: 0.043) // #F59E0B
    static let danger = Color(red: 0.937, green: 0.267, blue: 0.267) // #EF4444

    // MARK: - The Slimg Gradient (signature)

    /// `linear-gradient(135deg, #2DD4BF, #06B6D4)` — topLeading → bottomTrailing.
    static let gradient = LinearGradient(
        colors: [teal400, cyan500],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// A softer, low-alpha gradient for fills/backgrounds (hover, watermark).
    static func gradient(opacity: Double) -> LinearGradient {
        LinearGradient(
            colors: [teal400.opacity(opacity), cyan500.opacity(opacity)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Primary gradient button style

/// The signature CTA: a subtle teal→cyan gradient with white label.
struct BrandPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Brand.gradient,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BrandPrimaryButtonStyle {
    /// Slimg signature gradient call-to-action button.
    static var brandPrimary: BrandPrimaryButtonStyle { BrandPrimaryButtonStyle() }
}

// MARK: - Reusable bits

/// A small format pill (e.g. "JPEG") in brand style.
struct BrandPill: View {
    let text: String
    var tinted: Bool = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.3)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tinted ? AnyShapeStyle(Brand.teal600) : AnyShapeStyle(.secondary))
            .background(
                tinted ? AnyShapeStyle(Brand.teal500.opacity(0.14)) : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
    }
}
