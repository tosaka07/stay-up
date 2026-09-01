import AppKit

/// メニューバーに出すアイコンを描く。
///
/// macOS はメニューバーの画像をテンプレートとして扱うと単色に潰す。
/// 抑止中を色で示したいので、下地を塗った画像を自前で描き、
/// `isTemplate = false` のまま渡して色を保たせる。
///
/// 待機中は逆にテンプレートのままにして、システムの見た目（濃淡や反転）に従わせる。
enum MenuBarIcon {
    /// 下地の高さ。メニューバーの標準的な項目に収まる寸法。
    private static let badgeHeight: CGFloat = 17
    private static let horizontalPadding: CGFloat = 5

    static func make(symbol: String, background: NSColor?) -> NSImage {
        guard let background else {
            return templateGlyph(symbol: symbol)
        }
        return badge(symbol: symbol, background: background)
    }

    /// 待機中。システムに色を委ねる。
    private static func templateGlyph(symbol: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
            ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// 抑止中。塗りつぶした角丸の中にグリフを白で置く。
    private static func badge(symbol: String, background: NSColor) -> NSImage {
        // パレット指定で白のグリフを直接作る。
        // テンプレートを後から白く塗ると、下地まで巻き込んでしまう。
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else {
            return templateGlyph(symbol: symbol)
        }

        let size = NSSize(
            width: glyph.size.width + horizontalPadding * 2,
            height: badgeHeight
        )

        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: rect.height / 2,
                yRadius: rect.height / 2
            )
            background.setFill()
            path.fill()

            let origin = NSPoint(
                x: (rect.width - glyph.size.width) / 2,
                y: (rect.height - glyph.size.height) / 2
            )
            glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }

        // ここを true にすると macOS が単色に潰す。色を残すために false のままにする。
        image.isTemplate = false
        return image
    }
}
