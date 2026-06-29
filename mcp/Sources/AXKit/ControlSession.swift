//
//  ControlSession.swift
//  AXKit
//
//  Orchestration over the persisted control_app tree: incremental expand (reuse already-loaded
//  nodes verbatim, fetch only the frontier from live AX). refresh and parent-climb live in
//  ElementRegistry + the tools; this is the one piece that needs both the stored tree and AX.
//

import Foundation
import MacControlMCPCore

enum ControlSession {
    /// Incremental expand (§ expand): reuse loaded nodes as-is; recurse to find frontier nodes
    /// (`[N hidden]`/`[more hidden]`) and load those from live AX, bounded by `deadline`. A
    /// loaded node whose element has since died is reused as-is (refresh is the way to catch that).
    static func incrementalExpand(_ stored: ControlNode, registry: ElementRegistry, deadline: Date) -> ControlNode {
        switch stored.hidden {
        case .none:
            if stored.children.isEmpty { return stored }
            return stored.withChildren(stored.children.map {
                incrementalExpand($0, registry: registry, deadline: deadline)
            })
        case .known, .unknown:
            guard Date() < deadline,
                  let element = registry.element(for: stored.ref), element.isAlive else { return stored }
            return ControlWalker.build(root: element, registry: registry, pid: element.pid, deadline: deadline)
        }
    }
}
