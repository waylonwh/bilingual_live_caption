import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift scripts/check-app-icon.swift app-path output-png")
}
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let bundle = Bundle(url: app),
      bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon",
      bundle.url(forResource: "Assets", withExtension: "car") != nil else {
    fatalError("Compiled icon resources or bundle metadata are missing.")
}
let icon = NSWorkspace.shared.icon(forFile: app.path)
icon.size = NSSize(width: 256, height: 256)
guard let tiff = icon.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("The system could not provide a file icon.")
}
try png.write(to: output)
print("Saved the system file-icon lookup to \(output.path)")
