import CoreText
import SwiftUI

enum GaugeZBrandTypography {
    static let fontName = "ASTRA"
    static let zColor = Color(red: 23.0 / 255.0, green: 200.0 / 255.0, blue: 227.0 / 255.0)

    private static let registration: Void = {
        guard let fontURL = Bundle.main.url(forResource: "zdivefnt", withExtension: "otf") else { return }
        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }()

    static func register() {
        _ = registration
    }
}

struct GaugeZWordmark: View {
    let size: CGFloat
    let primaryColor: Color

    init(size: CGFloat, primaryColor: Color = .white) {
        GaugeZBrandTypography.register()
        self.size = size
        self.primaryColor = primaryColor
    }

    var body: some View {
        Text("Gauge\(Text("Z").foregroundColor(GaugeZBrandTypography.zColor))")
            .font(.custom(GaugeZBrandTypography.fontName, size: size))
            .foregroundColor(primaryColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}
