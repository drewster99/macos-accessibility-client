//
//  main.swift
//  MacControlMCP
//
//  Stdio entry point: newline-delimited JSON-RPC in, responses out. Uses the same
//  HostKit.makeFullServer() the XPC host uses, so the tool set never drifts between the
//  two transports.
//
//  The JSON-RPC loop runs on a BACKGROUND thread so the main thread is free to run an AppKit
//  run loop. That run loop is what keeps NSWorkspace.runningApplications (used by list_apps)
//  live: a process that just blocks in readLine() on the main thread never pumps the run loop,
//  so NSWorkspace never services its launch/terminate Mach source and the app list freezes at
//  launch time (stale pids). This mirrors the XPC host (server off the main thread, run loop
//  on it). EOF on stdin ends the process.
//

import AppKit
import Foundation
import HostKit

// Touch NSWorkspace on the main thread so its observers attach to the main run loop we run below.
_ = NSWorkspace.shared

Thread.detachNewThread {
    let server = makeFullServer()
    let stdout = FileHandle.standardOutput
    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        guard let response = server.handleLine(line) else { continue }
        stdout.write(response)
        stdout.write(Data("\n".utf8))
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
