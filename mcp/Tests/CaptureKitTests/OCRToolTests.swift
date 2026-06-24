import XCTest
import AppKit
@testable import CaptureKit

final class OCRToolTests: XCTestCase {
    func testDescriptorRequiresPath() {
        let schema = OCRTool().descriptor["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["path"])
    }

    func testMissingPath() {
        XCTAssertTrue(OCRTool().call([:]).contains("missing_path"))
    }

    func testCannotLoadMissingFile() {
        XCTAssertTrue(OCRTool().call(["path": "/no/such/file.png"]).contains("cannot_load_image"))
    }

    /// Deterministic, no permission: render known text to a PNG, OCR it, assert it reads back.
    func testRecognizesRenderedText() throws {
        let size = NSSize(width: 600, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 96),
            .foregroundColor: NSColor.black
        ]
        ("HELLO" as NSString).draw(at: NSPoint(x: 30, y: 50), withAttributes: attributes)
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("ocrtest_\(UUID().uuidString).png")
        try png.write(to: URL(fileURLWithPath: path))
        defer {
            do { try FileManager.default.removeItem(atPath: path) } catch { /* best-effort cleanup */ }
        }

        let out = OCRTool().call(["path": path]).uppercased()
        XCTAssertTrue(out.contains("HELLO"), "OCR output did not contain HELLO: \(out)")
    }
}
