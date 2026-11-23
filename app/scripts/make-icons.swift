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

/// A drive seen from the front: a rounded body with a seam, vents, and a status light. `rect` is the body's frame.
func drawDrive(_ context: CGContext, in rect: CGRect, onDark: Bool) {
	let radius = rect.height * 0.22
	let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

	context.saveGState()
	context.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.06), blur: rect.height * 0.16, color: color(0x000000, onDark ? 0.35 : 0.3))
	context.addPath(body)
	context.setFillColor(color(0xFFFFFF))
	context.fillPath()
	context.restoreGState()

	context.saveGState()
	context.addPath(body)
	context.clip()
	linear(context, [color(0xFFFFFF), color(0xDDE3EC)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY))
	// Lower panel below the seam.
	let seam = rect.minY + rect.height * 0.36
	context.setFillColor(color(0xC9D1DD))
	context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: seam - rect.minY))
	context.setFillColor(color(0xFFFFFF, 0.9))
	context.fill(CGRect(x: rect.minX, y: seam, width: rect.width, height: rect.height * 0.018))
	context.restoreGState()
	context.addPath(body)
	context.setStrokeColor(color(0x1E293B, 0.12))
	context.setLineWidth(rect.height * 0.01)
	context.strokePath()

	// Vents on the lower panel.
	let ventHeight = rect.height * 0.07
	let ventWidth = rect.height * 0.05
	for index in 0..<5 {
		let x = rect.minX + rect.height * 0.32 + CGFloat(index) * ventWidth * 2.1
		let vent = CGRect(x: x, y: rect.minY + rect.height * 0.145, width: ventWidth, height: ventHeight)
		context.addPath(CGPath(roundedRect: vent, cornerWidth: ventWidth / 2, cornerHeight: ventWidth / 2, transform: nil))
	}
	context.setFillColor(color(0x8A95A8))
	context.fillPath()

	// Status light.
	let light = rect.height * 0.1
	let lightRect = CGRect(x: rect.maxX - rect.height * 0.32 - light / 2, y: rect.minY + rect.height * 0.18 - light / 2 + ventHeight / 2, width: light, height: light)
	context.saveGState()
	context.setShadow(offset: .zero, blur: light * 0.9, color: color(0x34C759, 0.9))
	context.setFillColor(color(0x34C759))
	context.fillEllipse(in: lightRect)
	context.restoreGState()
}

func render(_ size: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
	let context = CGContext(
		data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
		space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	let scale = CGFloat(size) / 1024
	context.scaleBy(x: scale, y: scale)
	draw(context, scale)
	return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

/// macOS app icon grid: an 824-point rounded square centered on a 1024-point canvas.
func appIcon(_ context: CGContext, _ scale: CGFloat) {
	let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
	let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
	context.saveGState()
	context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.28))
	context.addPath(shape)
	context.setFillColor(color(0x2F6BF2))
	context.fillPath()
	context.restoreGState()

	context.saveGState()
	context.addPath(shape)
	context.clip()
	linear(context, [color(0x4C8DFF), color(0x1D4ED8)], from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
	context.restoreGState()

	drawDrive(context, in: CGRect(x: 232, y: 382, width: 560, height: 260), onDark: true)
}

func volumeIconImage(_ context: CGContext, _ scale: CGFloat) {
	drawDrive(context, in: CGRect(x: 92, y: 300, width: 840, height: 390), onDark: false)
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
