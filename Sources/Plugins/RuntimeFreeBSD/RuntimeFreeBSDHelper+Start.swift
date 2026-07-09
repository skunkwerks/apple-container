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

import ArgumentParser
import Foundation
import Logging

extension RuntimeFreeBSDHelper {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Boot a FreeBSD VM from a runtime root and stream its serial console to a log"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .shortAndLong, help: "VM UUID")
        var uuid: String

        @Option(name: .shortAndLong, help: "Runtime root directory containing \(FreeBSDBootConfig.fileName)")
        var root: String

        func run() async throws {
            #if !os(macOS)
            throw FreeBSDRuntimeError("the FreeBSD runtime helper requires macOS and Virtualization.framework")
            #else
            LoggingSystem.bootstrap { label in
                StreamLogHandler.standardError(label: label)
            }
            var log = Logger(label: "container-runtime-freebsd")
            log.logLevel = debug ? .debug : .info
            log[metadataKey: "uuid"] = "\(uuid)"

            log.info("starting helper")
            defer { log.info("stopping helper") }

            let rootURL = URL(fileURLWithPath: root)
            let config = try FreeBSDBootConfig.load(fromRoot: rootURL)
            try config.validate()
            log.info(
                "loaded config",
                metadata: [
                    "bootDisk": "\(config.bootDisk)",
                    "bootLog": "\(config.bootLog)",
                    "cpus": "\(config.cpus)",
                    "memoryBytes": "\(config.memoryBytes)",
                    "network": "\(config.network)",
                    "agent": "\(config.agent)",
                ])

            let machine = FreeBSDVirtualMachine(config: config, logger: log)

            // Stop the VM on SIGINT/SIGTERM so the helper exits cleanly.
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let signalQueue = DispatchQueue(label: "com.apple.container.runtime.freebsd.signals")
            let sources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
                let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
                src.setEventHandler {
                    log.info("received signal, stopping vm", metadata: ["signal": "\(sig)"])
                    Task { try? await machine.stop() }
                }
                src.resume()
                return src
            }

            try await machine.start()
            log.info("vm running; serial console -> \(config.bootLog). Ctrl-C to stop.")

            // Milestone 2: if the agent channel is enabled, perform the readiness
            // handshake concurrently while the VM keeps running.
            let agentClient: FreeBSDAgentClient? =
                (config.agent ? machine.agentHostHandle.map { FreeBSDAgentClient(handle: $0, logger: log) } : nil)
            if config.agent && agentClient == nil {
                log.warning("agent enabled in config but no agent channel was created")
            }
            if let client = agentClient {
                let agentLog = log
                client.start()
                Task {
                    do {
                        agentLog.info("awaiting guest agent ready handshake (ttyV0.1)")
                        let ready = try await client.waitForReady()
                        agentLog.info(
                            "guest agent ready",
                            metadata: [
                                "version": "\(ready.version ?? "?")",
                                "host": "\(ready.host ?? "?")",
                                "release": "\(ready.release ?? "?")",
                            ])
                        try await client.ping()
                        agentLog.info("guest agent ping -> pong OK")
                        let uname = try await client.uname()
                        agentLog.info("guest agent uname", metadata: ["uname": "\(uname)"])
                        let ip = try await client.waitForIPAddress()
                        agentLog.info("guest agent ip", metadata: ["ip": "\(ip.isEmpty ? "none (timed out)" : ip)"])
                    } catch {
                        agentLog.error("guest agent handshake failed", metadata: ["error": "\(error)"])
                    }
                }
            }

            await machine.waitUntilStopped()
            agentClient?.close()
            withExtendedLifetime(sources) {}
            log.info("vm stopped", metadata: ["finalState": "\(machine.state.rawValue)"])
            #endif
        }
    }
}
