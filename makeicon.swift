// Рисует иконку MicToggle (скруглённый квадрат с градиентом + SF Symbol микрофона) в iconset.
// Вызывается из build.sh: swift makeicon.swift <каталог.iconset>
import AppKit

let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // Поле как у системных иконок macOS: квадрат 824/1024 по центру, радиус ~185/1024.
    let box = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = NSBezierPath(roundedRect: box, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(starting: NSColor(srgbRed: 1.00, green: 0.42, blue: 0.36, alpha: 1),
               ending: NSColor(srgbRed: 0.85, green: 0.13, blue: 0.33, alpha: 1))!.draw(in: shape, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let m = mic.size
        mic.draw(in: NSRect(x: (s - m.width) / 2, y: (s - m.height) / 2, width: m.width, height: m.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}
