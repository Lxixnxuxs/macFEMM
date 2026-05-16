// FemmSolver.swift — Runs mesh + solver via the C ABI on a background queue,
// streaming log lines back to SwiftUI.

import Foundation
import FemmCore

@MainActor
final class SolverRun: ObservableObject {
    @Published var log: String = ""
    @Published var running: Bool = false
    @Published var lastError: String?

    // DispatchQueue keeps all solver runs serial and off-main.
    private let queue = DispatchQueue(label: "femm.solver")

    func run(doc: FemmDocument, tempPath: String) {
        guard !running, let handle = doc.raw else { return }
        running = true
        lastError = nil
        log = ""

        // The callback needs a context pointer; we retain `self` via an
        // Unmanaged and release it at the end of the run.
        let owner = Unmanaged.passRetained(self).toOpaque()
        let h = handle
        let path = tempPath
        queue.async {
            let mesh = path.withCString { femm_doc_create_mesh(h, $0) }
            if mesh != FEMM_OK {
                let errmsg = String(cString: femm_last_error_message())
                DispatchQueue.main.async {
                    let me = Unmanaged<SolverRun>.fromOpaque(owner).takeRetainedValue()
                    me.lastError = errmsg
                    me.running = false
                }
                return
            }
            let analyze = path.withCString {
                femm_doc_analyze(h, $0, femmSolverProgressCB, owner)
            }
            let errmsg = (analyze != FEMM_OK) ? String(cString: femm_last_error_message()) : nil
            let resultPath: String? = (analyze == FEMM_OK) ? (path + doc.snapshot.physics.resultExt) : nil
            DispatchQueue.main.async {
                let me = Unmanaged<SolverRun>.fromOpaque(owner).takeRetainedValue()
                if let e = errmsg { me.lastError = e }
                if let rp = resultPath { doc.loadSolution(at: rp) }
                me.running = false
            }
        }
    }

    fileprivate func append(_ line: String) {
        log += line
        if !line.hasSuffix("\n") { log += "\n" }
    }
}

// Trampoline out of C; dispatches back to MainActor. Marked @convention(c) so
// it can be passed as femm_progress_cb.
private func femmSolverProgressCB(_ pct: Int32,
                                  _ msg: UnsafePointer<CChar>?,
                                  _ user: UnsafeMutableRawPointer?) {
    guard let user = user, let msg = msg else { return }
    let line = String(cString: msg)
    DispatchQueue.main.async {
        // We don't retain here — `run` is holding the Unmanaged reference
        // for the full lifetime of the analysis.
        let me = Unmanaged<SolverRun>.fromOpaque(user).takeUnretainedValue()
        me.append(line)
    }
}
