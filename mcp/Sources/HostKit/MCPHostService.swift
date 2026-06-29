//
//  MCPHostService.swift
//  HostKit
//
//  Builds the full MCPServer (all tool layers) and exposes it over XPC. Requests are
//  serialized onto one queue because MCPServer/ElementRegistry hold mutable state (the real
//  host will be actor-isolated; this is the single-serial scaffold equivalent).
//

import ApplicationServices
import AXKit
import CaptureKit
import CoreGraphics
import Foundation
import InputKit
import MacControlMCPCore

/// The single place that wires every tool layer together — used by both the stdio
/// executable and the XPC host so they never drift.
public func makeFullServer() -> MCPServer {
    let session = ElementRegistry()
    // Wire the coordinate-based input verbs to the same SettleEngine + ElementRegistry the AX verbs
    // use, so a click/type/etc. with observe:"settle" returns a diff in the same ref vocabulary.
    let settle: ActAndSettle = { pid, action in
        let outcome = SettleEngine(session: session).actAndSettle(pid: pid, action: action)
        return (outcome.quiesced, outcome.settledAfterMs, outcome.diff)
    }
    // The control_app `click`/`type` verbs reach the synthetic-input layer (InputKit) via injected
    // closures, so AXKit stays input-free.
    let click: ControlClick = { x, y, count in SyntheticInput.click(x: x, y: y, rightButton: false, clickCount: count) }
    let type: ControlType = { text, paste in paste ? SyntheticInput.paste(text) : SyntheticInput.typeUnicode(text) }
    return MCPServer(
        tools: MCPServer.defaultTools()
            + AXTools.all(session: session, click: click, type: type)
            + [ScreenshotTool(), OCRTool()]
            + InputTools.all(settle: settle)
    )
}

public final class MCPHostService: NSObject, MCPHostProtocol, @unchecked Sendable {
    private let server: MCPServer
    private let lock = NSLock()

    public init(server: MCPServer = makeFullServer()) {
        self.server = server
    }

    public func handle(line: String, withReply reply: @escaping (String?) -> Void) {
        DebugLog.request(line)
        lock.lock()
        let response = server.handleLine(line).map { String(decoding: $0, as: UTF8.self) }
        lock.unlock()
        DebugLog.response(response)
        reply(response)
    }

    public func permissions(withReply reply: @escaping (String) -> Void) {
        reply("{\"accessibility\":\(AXIsProcessTrusted()),\"screenRecording\":\(CGPreflightScreenCaptureAccess())}")
    }
}
