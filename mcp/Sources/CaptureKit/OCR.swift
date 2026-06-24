//
//  OCR.swift
//  CaptureKit
//
//  Vision OCR (§5): recognize text in an image file (e.g. a screenshot path) — reads text
//  the AX tree doesn't expose (games/canvas/AX-poor web). Vision operates on a supplied
//  image, so this needs no TCC grant and is fully deterministic to test.
//

import AppKit
import CoreGraphics
import Foundation
import MacControlMCPCore
import Vision

public struct OCRTool: Tool {
    public init() {}

    public let name = "ocr"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Recognize text in an image file (e.g. a screenshot path) via Vision. No permission required.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "Image file to OCR."]],
                "required": ["path"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard let path = arguments["path"] as? String else {
            return OCRSupport.json(["error": "missing_path"])
        }
        guard let image = OCRSupport.loadCGImage(path) else {
            return OCRSupport.json(["error": "cannot_load_image", "path": path])
        }
        let lines = OCRSupport.recognizeText(image)
        return OCRSupport.json(["text": lines.joined(separator: "\n"), "lines": lines])
    }
}

enum OCRSupport {
    static func loadCGImage(_ path: String) -> CGImage? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func recognizeText(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let results = request.results else { return [] }
        return results.compactMap { $0.topCandidates(1).first?.string }
    }

    static func json(_ object: Any) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch { return "null" }
    }
}
