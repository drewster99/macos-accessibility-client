// P0a spike — shared XPC contract + identity constants.
// Throwaway: validates the load-bearing TCC/XPC assumptions in docs/MCP_DESIGN.md §2/§13.

import Foundation

/// Team-prefixed Mach service name (recommended for cross-process lookup).
let p0aMachServiceName = "P8MA38JTXY.com.nuclearcyborg.p0a.host"

/// Code-signing requirement pinning callers to our Developer ID team.
/// The host enforces this on its listener; a non-team (ad-hoc) caller is rejected
/// by the system before our delegate runs.
let p0aTeamRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"P8MA38JTXY\""

@objc(P0AHostProtocol)
protocol P0AHostProtocol {
    /// Returns a JSON blob describing the *host* process: pid, bundle id, executable,
    /// and whether it is AX-trusted. The whole point of the spike is to read this back
    /// in the relay and confirm the TCC grant attached to the host.
    func probe(withReply reply: @escaping (String) -> Void)
}
