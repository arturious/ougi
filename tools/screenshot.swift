import AppKit

// Raycast Store screenshot: captures Raycast's main window after a delay and centres it on a fixed
// background at 2000×1250. Usage: screenshot <output.png> [delay seconds]
// (Stands in for Raycast's Window Capture, which newer Raycast versions no longer offer.)

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: screenshot <output.png> [delay | --recompose]"); exit(1) }
let output = args[1]
let raw = NSTemporaryDirectory() + "ougi-window.png"
// --recompose rebuilds the output from the last raw capture without taking a new one.
let recompose = args.count > 2 && args[2] == "--recompose"
let delay = recompose ? 0 : args.count > 2 ? UInt32(args[2]) ?? 5 : 5

for i in stride(from: Int(delay), to: 0, by: -1) {
    print("capturing in \(i)…")
    sleep(1)
}

func captureRaycast() {
    // Raycast's launcher is an on-screen window named "Main Window"; pick the largest one.
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let raycast = windows.filter {
        ($0[kCGWindowOwnerName as String] as? String) == "Raycast" && ($0[kCGWindowName as String] as? String) == "Main Window"
    }.max { a, b in
        let area = { (w: [String: Any]) -> Double in
            let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
            return (b["Width"] ?? 0) * (b["Height"] ?? 0)
        }
        return area(a) < area(b)
    }
    guard let raycast, let id = raycast[kCGWindowNumber as String] as? Int else {
        print("Raycast window is not open"); exit(1)
    }

    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(id), raw] // -o: no window shadow, we draw our own
    try? capture.run()
    capture.waitUntilExit()
}

if !recompose { captureRaycast() }

// The capture can carry transparent margins (e.g. while the action panel is open); crop to the opaque window.
func trimmed(_ path: String) -> NSBitmapImageRep? {
    guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data),
          let cg = rep.cgImage else { return nil }
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, let crop = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    else { return nil }
    return NSBitmapImageRep(cgImage: crop)
}

guard let windowRep = trimmed(raw) else { print("capture failed"); exit(1) }
let window = NSImage(size: NSSize(width: windowRep.pixelsWide, height: windowRep.pixelsHigh))
window.addRepresentation(windowRep)

let W = 2000, H = 1250
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Same indigo as the icon, lightened so the window stands out.
NSGradient(colors: [NSColor(red: 0.36, green: 0.42, blue: 0.70, alpha: 1),
                    NSColor(red: 0.20, green: 0.24, blue: 0.48, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)

// Window pixels at their native (Retina) size, scaled down only if they would not fit.
var size = NSSize(width: windowRep.pixelsWide, height: windowRep.pixelsHigh)
let fit = min(1.0, 1800 / size.width, 1100 / size.height)
size = NSSize(width: size.width * fit, height: size.height * fit)
let rect = NSRect(x: (Double(W) - size.width) / 2, y: (Double(H) - size.height) / 2, width: size.width, height: size.height)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 60
shadow.shadowOffset = NSSize(width: 0, height: -20)
shadow.set()
window.draw(in: rect)

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("saved \(output) (\(W)×\(H))")
