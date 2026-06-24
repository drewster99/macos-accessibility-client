//
//  main.swift
//  MacControlMCP
//
//  Stdio entry point: newline-delimited JSON-RPC in, responses out. Uses the same
//  HostKit.makeFullServer() the XPC host uses, so the tool set never drifts between the
//  two transports.
//

import Foundation
import HostKit

let server = makeFullServer()
let stdout = FileHandle.standardOutput

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let response = server.handleLine(line) else { continue }
    stdout.write(response)
    stdout.write(Data("\n".utf8))
}
