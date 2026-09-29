import AppKit

/// **Readings in the menu bar**, for the accounts the user picked: each one's mark, what is
/// left of its headline window, and how long until that window resets.
///
/// Drawn as one template image rather than an attributed title, so the menu bar tints the
/// marks and the figures alike, light or dark, and while the menu is open.
enum MenuBarReadings {
    struct Reading: Equatable {
        let provider: ProviderID
        let text: String
    }

    @MainActor static func readings(for providers: [ProviderID], store: UsageStore, now: Date = .now) -> [Reading] {
        providers.map { provider in
            let snapshot = store.snapshot(for: provider)
            var text = snapshot.remainingPercent.map { "\(PercentCopy.text($0))%" } ?? "—"
            if snapshot.remainingPercent != nil, let reset = snapshot.headlineWindow?.resetsAt, reset > now {
                text += " " + countdown(reset.timeIntervalSince(now))
            }
            return Reading(provider: provider, text: text)
        }
    }

    /// The time to a reset in the fewest characters that still say it: minutes within the
    /// hour, hours within the day, days beyond.
    static func countdown(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return hours < 10 && rest > 0 ? "\(hours)h\(rest)m" : "\(hours)h"
        }
        return "\(hours / 24)d"
    }

    static func image(for readings: [Reading]) -> NSImage? {
        guard !readings.isEmpty else { return nil }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let logo: CGFloat = 13
        let logoGap: CGFloat = 3
        let itemGap: CGFloat = 9
        let height: CGFloat = 18
        let parts = readings.map { reading -> (NSImage?, NSAttributedString) in
            (logoImage(for: reading.provider, size: logo), NSAttributedString(string: reading.text, attributes: attributes))
        }
        let width = parts.reduce(CGFloat(0)) { sum, part in
            sum + logo + logoGap + ceil(part.1.size().width)
        } + itemGap * CGFloat(parts.count - 1)
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (mark, text) in parts {
                mark?.draw(in: NSRect(x: x, y: (height - logo) / 2, width: logo, height: logo))
                x += logo + logoGap
                let size = text.size()
                text.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                x += ceil(size.width) + itemGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func logoImage(for provider: ProviderID, size: CGFloat) -> NSImage? {
        let base: NSImage?
        if provider.usesSymbolLogo {
            base = NSImage(systemSymbolName: provider.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size - 2, weight: .semibold))
        } else {
            base = NSImage(named: provider.logoAssetName)
        }
        guard let base else { return nil }
        // Only the alpha matters to a template; filled black keeps it from vanishing.
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect)
            NSColor.black.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
