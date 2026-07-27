import AppKit
import Foundation

enum DiffPalette {
    static let changedLine = dynamic(light: "#e5e5e5", dark: "#2a2d2e")
    static let insertedText = dynamic(light: "#aceebb80", dark: "#2ea04340")
    static let deletedText = dynamic(light: "#ffcecb80", dark: "#f8514940")
    static let deletionMarker = dynamic(light: "#cf222e99", dark: "#f8514980")
    static let lineNumber = dynamic(light: "#6e7781", dark: "#8b949e")
    static let caretMarker = dynamic(light: "#24292f", dark: "#c9d1d9")
    static let divider = dynamic(light: "#8c959f", dark: "#484f58")
    static let insertionPoint = dynamic(light: "#24292f", dark: "#f0f6fc")

    private static func dynamic(light: String, dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
            return NSColor(hex: best == .darkAqua ? dark : light)
        }
    }
}

private extension NSColor {
    convenience init(hex: String) {
        var raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if raw.count == 6 { raw += "ff" }
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        let red = CGFloat((value >> 24) & 0xff) / 255
        let green = CGFloat((value >> 16) & 0xff) / 255
        let blue = CGFloat((value >> 8) & 0xff) / 255
        let alpha = CGFloat(value & 0xff) / 255
        self.init(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}
