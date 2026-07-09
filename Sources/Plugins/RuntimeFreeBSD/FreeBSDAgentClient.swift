//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)
import Foundation
import Logging

/// A frame exchanged with the FreeBSD guest agent over the virtio-console channel.
///
/// The spike protocol is newline-delimited JSON (JSONL). The guest pushes events
/// (`ready`, `pong`, `uname`); the host sends requests (`{"op":"ping"}`). Only
/// `event` is required; other fields are populated per event type.
struct AgentFrame: Decodable, Sendable {
    let event: String
    let version: String?
    let host: String?
    let release: String?
    let data: String?
}

/// Minimal host-side client for the FreeBSD guest agent (Milestone 2).
///
/// Reads JSONL frames from the host end of the agent socketpair and lets callers
/// await a specific frame (e.g. the boot-time `ready` handshake, or a `pong`).
/// Deliberately tiny: this proves the bidirectional virtio-console channel, not a
/// full RPC surface.
final class FreeBSDAgentClient: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let predicate: @Sendable (AgentFrame) -> Bool
        let cont: CheckedContinuation<AgentFrame, Error>
    }

    private let handle: FileHandle
    private let logger: Logger
    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [Waiter] = []
    private var closed = false

    init(handle: FileHandle, logger: Logger) {
        self.handle = handle
        self.logger = logger
    }

    /// Begin reading frames from the channel.
    func start() {
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { return }
            if chunk.isEmpty {
                self.handleEOF()
                return
            }
            self.ingest(chunk)
        }
    }

    /// Stop reading and fail any outstanding waiters.
    func close() {
        handle.readabilityHandler = nil
        failAllWaiters(FreeBSDRuntimeError("agent channel closed"))
        lock.withLock { closed = true }
    }

    // MARK: - Requests

    /// Await the guest agent's boot-time `ready` handshake.
    func waitForReady(timeoutSeconds: Double = 120) async throws -> AgentFrame {
        try await expect(timeoutSeconds: timeoutSeconds) { $0.event == "ready" }
    }

    /// Round-trip a `ping` and await the `pong`.
    func ping(timeoutSeconds: Double = 10) async throws {
        try send(["op": "ping"])
        _ = try await expect(timeoutSeconds: timeoutSeconds) { $0.event == "pong" }
    }

    /// Ask the guest for `uname -a`.
    func uname(timeoutSeconds: Double = 10) async throws -> String {
        try send(["op": "uname"])
        let frame = try await expect(timeoutSeconds: timeoutSeconds) { $0.event == "uname" }
        return frame.data ?? ""
    }

    // MARK: - Internals

    private func send(_ object: [String: String]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)  // newline-delimited
        try handle.write(contentsOf: data)
    }

    private func expect(
        timeoutSeconds: Double,
        where predicate: @escaping @Sendable (AgentFrame) -> Bool
    ) async throws -> AgentFrame {
        try await withThrowingTaskGroup(of: AgentFrame.self) { group in
            group.addTask { try await self.awaitFrame(where: predicate) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw FreeBSDRuntimeError("timed out after \(timeoutSeconds)s waiting for agent frame")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func awaitFrame(
        where predicate: @escaping @Sendable (AgentFrame) -> Bool
    ) async throws -> AgentFrame {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AgentFrame, Error>) in
                let alreadyClosed: Bool = lock.withLock {
                    if closed { return true }
                    waiters.append(Waiter(id: id, predicate: predicate, cont: cont))
                    return false
                }
                if alreadyClosed {
                    cont.resume(throwing: FreeBSDRuntimeError("agent channel closed"))
                }
            }
        } onCancel: {
            let cont: CheckedContinuation<AgentFrame, Error>? = lock.withLock {
                guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: idx).cont
            }
            cont?.resume(throwing: CancellationError())
        }
    }

    private func ingest(_ chunk: Data) {
        var frames: [AgentFrame] = []
        lock.withLock {
            buffer.append(chunk)
            while let nl = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<nl.upperBound)
                guard !lineData.isEmpty else { continue }
                if let frame = try? JSONDecoder().decode(AgentFrame.self, from: lineData) {
                    frames.append(frame)
                } else if let raw = String(data: lineData, encoding: .utf8) {
                    logger.debug("agent non-json line", metadata: ["line": "\(raw)"])
                }
            }
        }
        for frame in frames { dispatch(frame) }
    }

    private func dispatch(_ frame: AgentFrame) {
        let cont: CheckedContinuation<AgentFrame, Error>? = lock.withLock {
            guard let idx = waiters.firstIndex(where: { $0.predicate(frame) }) else { return nil }
            return waiters.remove(at: idx).cont
        }
        if let cont {
            cont.resume(returning: frame)
        } else {
            logger.debug("agent frame with no waiter", metadata: ["event": "\(frame.event)"])
        }
    }

    private func handleEOF() {
        handle.readabilityHandler = nil
        logger.debug("agent channel reached EOF")
        failAllWaiters(FreeBSDRuntimeError("agent channel reached EOF"))
    }

    private func failAllWaiters(_ error: Error) {
        let pending: [Waiter] = lock.withLock {
            let copy = waiters
            waiters.removeAll()
            return copy
        }
        for waiter in pending { waiter.cont.resume(throwing: error) }
    }
}
#endif
