#!/usr/bin/env swift

// Draws the placeholder default avatar of #41 — a round face in ten expressions — and packs it
// as the archive the application ships, until an avatar made with the application replaces it:
//
//   swift Scripts/render-placeholder-avatar.swift \
//     Packages/VibeManagerKit/Sources/VibeAvatar/Resources/DefaultAvatar.zip
//
// The archive has the form of any exported avatar: `manifest.json` and one PNG per expression.

import AppKit
import Foundation

let expressions = [
  "neutral", "mouthHalfOpen", "mouthOpen", "mouthRound", "eyesHalfClosed", "eyesClosed",
  "pleased", "surprised", "thinking", "worried",
]
let side: CGFloat = 512

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: render-placeholder-avatar.swift <archive.zip>\n".utf8))
  exit(64)
}
let archive = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
  "placeholder-avatar-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let ink = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 1)
let face = NSColor(srgbRed: 0.36, green: 0.55, blue: 0.98, alpha: 1)
let cheek = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.72, alpha: 1)

func draw(_ expression: String) -> Data {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else { fatalError("no bitmap") }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  defer { NSGraphicsContext.restoreGraphicsState() }

  // The head.
  let head = NSBezierPath(ovalIn: NSRect(x: 76, y: 60, width: 360, height: 380))
  face.setFill()
  head.fill()
  ink.setStroke()
  head.lineWidth = 14
  head.stroke()

  // The eyes.
  ink.setFill()
  ink.setStroke()
  for x in [196.0, 316.0] {
    let centre = NSPoint(x: x, y: 290)
    switch expression {
    case "eyesHalfClosed":
      NSBezierPath(rect: NSRect(x: centre.x - 26, y: centre.y - 10, width: 52, height: 18)).fill()
    case "eyesClosed":
      let line = NSBezierPath()
      line.move(to: NSPoint(x: centre.x - 28, y: centre.y))
      line.line(to: NSPoint(x: centre.x + 28, y: centre.y))
      line.lineWidth = 12
      line.lineCapStyle = .round
      line.stroke()
    case "surprised":
      NSColor.white.setFill()
      let white = NSBezierPath(ovalIn: NSRect(x: centre.x - 34, y: centre.y - 34, width: 68, height: 68))
      white.fill()
      white.lineWidth = 8
      white.stroke()
      ink.setFill()
      NSBezierPath(ovalIn: NSRect(x: centre.x - 14, y: centre.y - 14, width: 28, height: 28)).fill()
    case "thinking":
      NSBezierPath(ovalIn: NSRect(x: centre.x - 4, y: centre.y + 8, width: 32, height: 32)).fill()
    default:
      NSBezierPath(ovalIn: NSRect(x: centre.x - 22, y: centre.y - 26, width: 44, height: 52)).fill()
    }
  }
  if expression == "worried" {
    for (x, tilt) in [(196.0, 16.0), (316.0, -16.0)] {
      let brow = NSBezierPath()
      brow.move(to: NSPoint(x: x - 30, y: 348 - tilt))
      brow.line(to: NSPoint(x: x + 30, y: 348 + tilt))
      brow.lineWidth = 10
      brow.lineCapStyle = .round
      brow.stroke()
    }
  }

  // The cheeks.
  cheek.setFill()
  for x in [150.0, 362.0] {
    NSBezierPath(ovalIn: NSRect(x: x - 22, y: 210, width: 44, height: 26)).fill()
  }

  // The mouth.
  ink.setFill()
  ink.setStroke()
  let mouth = NSBezierPath()
  mouth.lineWidth = 12
  mouth.lineCapStyle = .round
  switch expression {
  case "mouthHalfOpen":
    NSBezierPath(ovalIn: NSRect(x: 226, y: 150, width: 60, height: 34)).fill()
  case "mouthOpen":
    NSBezierPath(ovalIn: NSRect(x: 216, y: 124, width: 80, height: 70)).fill()
  case "mouthRound", "surprised":
    NSBezierPath(ovalIn: NSRect(x: 234, y: 136, width: 44, height: 50)).fill()
  case "pleased":
    mouth.move(to: NSPoint(x: 196, y: 186))
    mouth.curve(
      to: NSPoint(x: 316, y: 186), controlPoint1: NSPoint(x: 220, y: 120),
      controlPoint2: NSPoint(x: 292, y: 120))
    mouth.stroke()
  case "worried":
    mouth.move(to: NSPoint(x: 206, y: 150))
    mouth.curve(
      to: NSPoint(x: 306, y: 150), controlPoint1: NSPoint(x: 230, y: 190),
      controlPoint2: NSPoint(x: 282, y: 190))
    mouth.stroke()
  case "thinking":
    mouth.move(to: NSPoint(x: 236, y: 164))
    mouth.line(to: NSPoint(x: 286, y: 170))
    mouth.stroke()
  default:
    mouth.move(to: NSPoint(x: 216, y: 176))
    mouth.curve(
      to: NSPoint(x: 296, y: 176), controlPoint1: NSPoint(x: 236, y: 150),
      controlPoint2: NSPoint(x: 276, y: 150))
    mouth.stroke()
  }

  guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("no png") }
  return png
}

for expression in expressions {
  try draw(expression).write(to: folder.appendingPathComponent(expression + ".png"))
}
let manifest: [String: Any] = [
  "format": 1, "name": "Placeholder", "source": "bundled", "expressions": expressions,
]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
  .write(to: folder.appendingPathComponent("manifest.json"))

try? FileManager.default.removeItem(at: archive)
let zip = Process()
zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
zip.currentDirectoryURL = folder
zip.arguments = ["-X", "-q", "-j", archive.path, "manifest.json"] + expressions.map { $0 + ".png" }
try zip.run()
zip.waitUntilExit()
try? FileManager.default.removeItem(at: folder)
exit(zip.terminationStatus)
