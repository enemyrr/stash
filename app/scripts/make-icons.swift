// Draws the app icon and the volume icon with Core Graphics.
// Run from app/: swift scripts/make-icons.swift
import AppKit
import CoreGraphics

let appIconSet = "app/Assets.xcassets/AppIcon.appiconset"
let volumeIcon = "extension/VolumeIcon.icns"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
	CGColor(
		srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
		alpha: alpha)
}

func linear(_ context: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
	let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
	context.drawLinearGradient(gradient, start: from, end: to, options: [])
}

/// The drive's shape: a rounded body split by a seam, with vents and a status light on the lower panel.
/// `pixels` is the output size, so thin details keep at least one device pixel at 16 and 32 px.
struct Drive {
	let rect: CGRect
	let pixels: CGFloat

	init(rect: CGRect, pixels: CGFloat) {
		self.pixels = pixels
		self.rect = pixels <= 64 ? Drive.snap(rect, 1024 / pixels) : rect
	}

	/// Rounds `rect` to whole device pixels, so small sizes render sharp edges instead of gray rows.
	static func snap(_ rect: CGRect, _ unit: CGFloat) -> CGRect {
		let minX = (rect.minX / unit).rounded() * unit, minY = (rect.minY / unit).rounded() * unit
		let maxX = (rect.maxX / unit).rounded() * unit, maxY = (rect.maxY / unit).rounded() * unit
		return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
	}

	var unit: CGFloat { 1024 / pixels }
	var body: CGPath {
		let radius = rect.height * 0.22
		return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
	}
	var seam: CGRect {
		let seam = CGRect(x: rect.minX, y: rect.minY + rect.height * 0.36, width: rect.width, height: max(rect.height * 0.035, unit))
		return pixels <= 64 ? Drive.snap(seam, unit) : seam
	}
	var vents: [CGRect] {
		guard pixels >= 64 else { return [] }
		let width = rect.height * 0.05
		return (0..<5).map { index in
			CGRect(x: rect.minX + rect.height * 0.32 + CGFloat(index) * width * 2.1, y: rect.minY + rect.height * 0.145, width: width, height: rect.height * 0.07)
		}
	}
	var light: CGRect {
		let size = max(rect.height * 0.1, unit)
		let light = CGRect(x: rect.maxX - rect.height * 0.32 - size / 2, y: rect.minY + rect.height * 0.18 - size / 2, width: size, height: size)
		return pixels <= 64 ? Drive.snap(light, unit) : light
	}

	func fillVents(_ context: CGContext) {
		for vent in vents {
			context.addPath(CGPath(roundedRect: vent, cornerWidth: vent.width / 2, cornerHeight: vent.width / 2, transform: nil))
		}
		context.fillPath()
	}
}

/// The app icon's drive: a flat white glyph with the seam, vents, and status light cut out of it.
func drawDriveGlyph(_ context: CGContext, _ drive: Drive) {
	context.beginTransparencyLayer(auxiliaryInfo: nil)
	context.addPath(drive.body)
	context.setFillColor(color(0xFFFFFF))
	context.fillPath()
	context.setBlendMode(.destinationOut)
	context.setFillColor(color(0x000000))
	context.fill(drive.seam)
	drive.fillVents(context)
	context.setFillColor(color(0x000000, 0.75))
	context.fillEllipse(in: drive.light)
	context.endTransparencyLayer()
}

/// The volume icon's drive: a near-black body with light details, in the app icon's palette.
func drawDriveObject(_ context: CGContext, _ drive: Drive) {
	let rect = drive.rect
	context.saveGState()
	context.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.05), blur: rect.height * 0.12, color: color(0x000000, 0.35))
	context.addPath(drive.body)
	context.setFillColor(color(0x1C1C1E))
	context.fillPath()
	context.restoreGState()

	context.saveGState()
	context.addPath(drive.body)
	context.clip()
	linear(context, [color(0x3A3A3C), color(0x2A2A2C)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: drive.seam.maxY))
	context.setFillColor(color(0x1C1C1E))
	context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: drive.seam.minY - rect.minY))
	context.setFillColor(color(0xFFFFFF, 0.26))
	context.fill(drive.seam)
	if drive.pixels >= 64 {
		strokeTopHighlight(context, drive.body, rect, width: drive.unit * 4, alpha: 0.3)
	}
	// An inner rim keeps the body's edge visible on dark backgrounds.
	context.addPath(drive.body)
	context.setStrokeColor(color(0xFFFFFF, drive.pixels >= 64 ? 0.14 : 0.08))
	context.setLineWidth(max(drive.unit, 2) * 2)
	context.strokePath()
	context.restoreGState()

	context.setFillColor(color(0xFFFFFF, 0.45))
	drive.fillVents(context)
	context.setFillColor(color(0xFFFFFF, 0.8))
	context.fillEllipse(in: drive.light)
}

/// Strokes the inside edge of `path`, fading from `alpha` at the top to nothing a third of the way down.
/// Call it inside a clip to `path`, so only the inner half of the line shows.
func strokeTopHighlight(_ context: CGContext, _ path: CGPath, _ rect: CGRect, width: CGFloat, alpha: CGFloat) {
	context.saveGState()
	context.addPath(path)
	context.setLineWidth(width)
	context.replacePathWithStrokedPath()
	context.clip()
	linear(context, [color(0xFFFFFF, alpha), color(0xFFFFFF, 0)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.maxY - rect.height / 3))
	context.restoreGState()
}

func render(_ size: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
	let context = CGContext(
		data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
		space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
	draw(context, CGFloat(size))
	return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

/// macOS app icon grid: an 824-point rounded square centered on a 1024-point canvas.
func appIcon(_ context: CGContext, _ pixels: CGFloat) {
	let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
	let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
	context.saveGState()
	context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.3))
	context.addPath(shape)
	context.setFillColor(color(0x1C1C1E))
	context.fillPath()
	context.restoreGState()

	context.saveGState()
	context.addPath(shape)
	context.clip()
	linear(context, [color(0x2A2A2C), color(0x1C1C1E)], from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
	strokeTopHighlight(context, shape, tile, width: 2 * 1024 / pixels, alpha: 0.18)
	context.restoreGState()

	// At 16 px the standard glyph is 4 px tall, too short for a seam, so it grows to 10 by 5 px.
	let glyph = pixels <= 16 ? CGRect(x: 192, y: 384, width: 640, height: 320) : CGRect(x: 232, y: 382, width: 560, height: 260)
	drawDriveGlyph(context, Drive(rect: glyph, pixels: pixels))
}

func volumeIconImage(_ context: CGContext, _ pixels: CGFloat) {
	drawDriveObject(context, Drive(rect: CGRect(x: 92, y: 300, width: 840, height: 390), pixels: pixels))
}

let files = FileManager.default
try files.createDirectory(atPath: appIconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
	for scale in [1, 2] {
		let name = "icon-\(points)@\(scale)x.png"
		try render(points * scale, appIcon).write(to: URL(fileURLWithPath: "\(appIconSet)/\(name)"))
		images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
	}
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
	.write(to: URL(fileURLWithPath: "\(appIconSet)/Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(toFile: "app/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)

let iconset = NSTemporaryDirectory() + "VolumeIcon.iconset"
try? files.removeItem(atPath: iconset)
try files.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
	try render(points, volumeIconImage).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(points)x\(points).png"))
	try render(points * 2, volumeIconImage).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", volumeIcon]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(appIconSet) and \(volumeIcon)" : "iconutil failed")
