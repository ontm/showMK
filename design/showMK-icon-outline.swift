import AppKit
import Foundation

let size = 1024
let canvas = NSSize(width: size, height: size)
let image = NSImage(size: canvas)
image.lockFocus()

let context = NSGraphicsContext.current!.cgContext
context.setFillColor(NSColor(calibratedRed: 0.985, green: 0.979, blue: 0.957, alpha: 1).cgColor)
let plate = NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 1008, height: 1008), xRadius: 220, yRadius: 220)
plate.fill()

let blue = NSColor(calibratedRed: 0.055, green: 0.19, blue: 0.69, alpha: 1)
let path = NSBezierPath()
path.lineCapStyle = .round
path.lineJoinStyle = .round
path.lineWidth = 52

// The M ends in the single shared stem; the K only adds two diagonals.
let axis = canvas.width / 2
let span: CGFloat = 290
path.move(to: NSPoint(x: axis - span, y: 350))
path.line(to: NSPoint(x: axis - span, y: 770))
path.line(to: NSPoint(x: axis - span / 2, y: 468))
path.line(to: NSPoint(x: axis, y: 770))
path.line(to: NSPoint(x: axis, y: 350))
path.move(to: NSPoint(x: axis + span, y: 770))
path.line(to: NSPoint(x: axis, y: 560))
path.line(to: NSPoint(x: axis + span, y: 350))
blue.setStroke()
path.stroke()

func drawSymbol(_ name: String, rect: NSRect, pointSize: CGFloat) {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        fatalError("Missing SF Symbol: \(name)")
    }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
    let styled = symbol.withSymbolConfiguration(config)!
    let tinted = NSImage(size: styled.size)
    tinted.lockFocus()
    let symbolRect = NSRect(origin: .zero, size: styled.size)
    styled.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current!.cgContext.setBlendMode(.sourceAtop)
    blue.setFill()
    NSBezierPath(rect: symbolRect).fill()
    NSGraphicsContext.current!.cgContext.setBlendMode(.normal)
    tinted.unlockFocus()
    tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

// Place each device on its own side of the shared stem's extension.
// Equal inner margins keep the axis between the symbols despite their different widths.
let axisMargin: CGFloat = 20
let mouseWidth: CGFloat = 70
let keyboardWidth: CGFloat = 194
drawSymbol("computermouse", rect: NSRect(x: axis - axisMargin - mouseWidth, y: 184, width: mouseWidth, height: 78), pointSize: 72)
drawSymbol("keyboard", rect: NSRect(x: axis + axisMargin, y: 184, width: keyboardWidth, height: 78), pointSize: 72)

image.unlockFocus()
let tiff = image.tiffRepresentation!
let bitmap = NSBitmapImageRep(data: tiff)!
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try png.write(to: output)
print("Wrote \(output.path), \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
