import AppKit

// Ougi (folding fan) outline icon: white strokes on an indigo rounded square.
// Geometry is laid out in a 512×512 y-down "reference" space, then scaled into the icon.

let S = 512.0
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

let bgRect = NSRect(x: 0, y: 0, width: S, height: S).insetBy(dx: 24, dy: 24)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 104, yRadius: 104)
NSGradient(starting: NSColor(red: 0.16, green: 0.20, blue: 0.40, alpha: 1),
           ending: NSColor(red: 0.07, green: 0.09, blue: 0.20, alpha: 1))!.draw(in: bg, angle: -90)

let pivot = (x: 256.0, y: 365.0)
let rOuter = 310.0, rInner = 110.0, rHandle = 76.0
let left = 141.0, right = 39.0 // guard angles, degrees counter-clockwise from +x
let slats = 5, slatWidth = 30.0

func point(_ r: Double, _ deg: Double, offset: Double = 0) -> NSPoint {
    let a = deg * .pi / 180
    // Perpendicular offset keeps slat sides parallel instead of wedge-shaped.
    return NSPoint(x: pivot.x + r * cos(a) - offset * sin(a), y: pivot.y - r * sin(a) - offset * cos(a))
}

let path = NSBezierPath()
func arc(_ r: Double, from a0: Double, to a1: Double) {
    let n = 64
    path.move(to: point(r, a0))
    for i in 1...n { path.line(to: point(r, a0 + (a1 - a0) * Double(i) / Double(n))) }
}

arc(rOuter, from: right, to: left)
arc(rInner, from: right, to: left)
arc(rHandle, from: left - 180, to: right - 180) // below the pivot, through 270°
// Guards cross at the pivot and end at the opposite corner of the handle.
path.move(to: point(rOuter, left)); path.line(to: point(rHandle, left - 180))
path.move(to: point(rOuter, right)); path.line(to: point(rHandle, right + 180))

let step = (left - right) / Double(slats + 1)
for k in 1...slats {
    let a = right + Double(k) * step
    for d in [-slatWidth / 2, slatWidth / 2] {
        let t0 = (rInner * rInner - d * d).squareRoot(), t1 = (rOuter * rOuter - d * d).squareRoot()
        path.move(to: point(t0, a, offset: d))
        path.line(to: point(t1, a, offset: d))
    }
}

// Reference space: bounding box centre (256, 247), y down → icon space, y up.
let scale = 0.74
let t = NSAffineTransform()
t.translateX(by: S / 2, yBy: S / 2)
t.scaleX(by: scale, yBy: -scale)
t.translateX(by: -256, yBy: -247)
path.transform(using: t as AffineTransform)

path.lineWidth = 20 * scale
path.lineCapStyle = .round
path.lineJoinStyle = .round
NSColor.white.setStroke()
path.stroke()

img.unlockFocus()
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
