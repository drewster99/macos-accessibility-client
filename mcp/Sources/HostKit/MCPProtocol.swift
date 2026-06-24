//
//  MCPProtocol.swift
//  HostKit
//
//  The XPC contract between the stdio relay and the privileged host (§2). The relay
//  forwards each JSON-RPC line; the host runs the MCPServer and replies. Identity is
//  pinned both ways to our Developer ID team (the host enforces it on its listener).
//

import Foundation

public let mcpMachServiceName = "P8MA38JTXY.com.nuclearcyborg.maccontrol.host"

/// What the host accepts from a connecting caller — our team AND specifically the signed
/// relay or registrar/GUI (not just any same-team binary). Pins identifier, closing the
/// confused-deputy hole.
public let mcpCallerRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"P8MA38JTXY\" and (identifier \"com.nuclearcyborg.maccontrol.relay\" or identifier \"com.nuclearcyborg.maccontrol\")"

/// What the relay requires of the host it connects to (mutual auth).
public let mcpHostRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"P8MA38JTXY\" and identifier \"com.nuclearcyborg.maccontrol.host\""

@objc(MCPHostProtocol)
public protocol MCPHostProtocol {
    /// Forward one JSON-RPC line; reply is the response string, or nil for notifications.
    func handle(line: String, withReply reply: @escaping (String?) -> Void)

    /// The host's own TCC grant status as JSON `{accessibility, screenRecording}` — used by
    /// the GUI to show the *host's* grants (not the GUI's). Triggering the prompt is separate.
    func permissions(withReply reply: @escaping (String) -> Void)
}
