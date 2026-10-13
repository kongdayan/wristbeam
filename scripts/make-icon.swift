import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let variants: [(String, Int)] = [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)]
for (name, size) in variants {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
    let background = NSBezierPath(roundedRect: NSRect(x: 38, y: 38, width: 948, height: 948), xRadius: 220, yRadius: 220)
    NSColor(calibratedRed: 0.075, green: 0.1, blue: 0.12, alpha: 1).setFill(); background.fill()
    let ring = NSBezierPath(ovalIn: NSRect(x: 205, y: 205, width: 614, height: 614))
    NSColor(calibratedRed: 0.54, green: 0.94, blue: 0.75, alpha: 0.13).setStroke(); ring.lineWidth = 26; ring.stroke()
    let line = NSBezierPath(); line.move(to: NSPoint(x: 188, y: 495)); line.line(to: NSPoint(x: 337, y: 495))
    line.line(to: NSPoint(x: 417, y: 650)); line.line(to: NSPoint(x: 499, y: 333))
    line.line(to: NSPoint(x: 586, y: 548)); line.line(to: NSPoint(x: 644, y: 495)); line.line(to: NSPoint(x: 834, y: 495))
    line.lineWidth = 39; line.lineCapStyle = .round; line.lineJoinStyle = .round
    NSColor(calibratedRed: 0.54, green: 0.94, blue: 0.75, alpha: 1).setStroke(); line.stroke()
    image.unlockFocus()
    let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = representation.representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent(name + ".png"))
}
