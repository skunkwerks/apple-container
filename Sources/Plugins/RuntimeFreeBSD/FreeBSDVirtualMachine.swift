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
import Virtualization

/// Minimal lifecycle states for the boot-only FreeBSD VM.
enum FreeBSDVMState: String, Sendable {
    case created
    case booting
    case running
    case stopping
    case stopped
    case failed
}

/// A boot-only FreeBSD virtual machine built directly on Virtualization.framework.
///
/// This intentionally does not conform to `VirtualMachineInstance`; for the boot
/// milestone there is no guest agent, no vsock dialing, no mounts, and no hotplug.
/// "Booted" is established by VZ reporting `running` plus serial-log evidence.
final class FreeBSDVirtualMachine: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let config: FreeBSDBootConfig
    private let logger: Logger
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var _state: FreeBSDVMState = .created
    private var stopContinuation: CheckedContinuation<Void, Never>?
    // Accessed only on `queue` after creation.
    private nonisolated(unsafe) var vm: VZVirtualMachine?

    /// Host end of the agent console channel (socketpair fd[0]) when `config.agent`
    /// is enabled. The VZ side holds fd[1] as a second virtio-console port. Created
    /// in `buildConfiguration()`; read/written by `FreeBSDAgentClient`.
    private nonisolated(unsafe) var _agentHostHandle: FileHandle?
    var agentHostHandle: FileHandle? { lock.withLock { _agentHostHandle } }

    init(config: FreeBSDBootConfig, logger: Logger) {
        self.config = config
        self.logger = logger
        self.queue = DispatchQueue(label: "com.apple.container.runtime.freebsd.\(UUID().uuidString)")
        super.init()
    }

    var state: FreeBSDVMState {
        lock.withLock { _state }
    }

    private func setState(_ newState: FreeBSDVMState) {
        lock.withLock { _state = newState }
        logger.info("vm state", metadata: ["state": "\(newState.rawValue)"])
    }

    // MARK: - Configuration

    private func buildConfiguration() throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = config.resolvedCPUCount
        vz.memorySize = config.resolvedMemoryBytes
        vz.platform = VZGenericPlatformConfiguration()
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // EFI boot loader with a persistent variable store. FreeBSD boots from
        // its own EFI loader on the disk, not from a host-supplied kernel.
        let bootLoader = VZEFIBootLoader()
        let efiURL = URL(fileURLWithPath: config.efiVariableStore)
        if FileManager.default.fileExists(atPath: efiURL.path) {
            bootLoader.variableStore = VZEFIVariableStore(url: efiURL)
        } else {
            bootLoader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: efiURL)
        }
        vz.bootLoader = bootLoader

        // Serial console -> boot log file, so boot progress is observable.
        // This stays port 0 (guest `ttyV0.0`) — boot-only behavior is unchanged.
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = try VZFileSerialPortAttachment(
            url: URL(fileURLWithPath: config.bootLog),
            append: true
        )
        var serialPorts = [serial]

        // Optional second console port (guest `ttyV0.1`) for the agent handshake.
        // Backed by a duplex AF_UNIX socketpair: VZ holds fd[1], the host keeps
        // fd[0]. The guest agent writes its "ready" frame and reads requests here.
        if config.agent {
            serialPorts.append(try makeAgentSerialPort())
        }
        vz.serialPorts = serialPorts

        // Single virtio block device for the FreeBSD boot/root disk.
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: config.bootDisk),
            readOnly: false
        )
        vz.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // Optional NAT network for the simplest outbound connectivity.
        if config.network == "nat" {
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            vz.networkDevices = [net]
        } else if config.network != "none" {
            throw FreeBSDRuntimeError("unsupported network mode: \(config.network) (use \"none\" or \"nat\")")
        }

        try vz.validate()
        return vz
    }

    /// Create the agent console port and stash the host end of its socketpair.
    private func makeAgentSerialPort() throws -> VZVirtioConsoleDeviceSerialPortConfiguration {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw FreeBSDRuntimeError("failed to create agent socketpair: errno \(errno)")
        }
        // fd[0]: host side (agent client). fd[1]: VZ side (the guest's ttyV0.1).
        let hostHandle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let vzHandle = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        lock.withLock { _agentHostHandle = hostHandle }

        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        // The socketpair is full-duplex, so the same handle serves both directions.
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: vzHandle,
            fileHandleForWriting: vzHandle
        )
        logger.info("agent console channel enabled (guest ttyV0.1)")
        return port
    }

    // MARK: - Lifecycle

    func start() async throws {
        setState(.booting)
        do {
            let vzConfig = try buildConfiguration()
            let machine = VZVirtualMachine(configuration: vzConfig, queue: queue)
            queue.sync { machine.delegate = self }
            self.vm = machine

            try await machine.startVM(queue: queue)
            setState(.running)
        } catch {
            setState(.failed)
            throw error
        }
    }

    /// Force-stop the VM (power off). Safe to call more than once.
    func stop() async throws {
        let shouldStop: Bool = lock.withLock {
            guard _state == .running || _state == .booting else { return false }
            _state = .stopping
            return true
        }
        guard shouldStop, let machine = vm else { return }
        logger.info("stopping vm")
        try await machine.stopVM(queue: queue)
        transitionStopped()
    }

    /// Suspend until the VM has stopped, whether guest-initiated or via `stop()`.
    func waitUntilStopped() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if _state == .stopped || _state == .failed {
                    return true
                }
                stopContinuation = cont
                return false
            }
            if resumeNow { cont.resume() }
        }
    }

    private func transitionStopped() {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            _state = .stopped
            defer { stopContinuation = nil }
            return stopContinuation
        }
        cont?.resume()
    }

    // MARK: - VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        logger.info("guest stopped")
        transitionStopped()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        logger.error("vm stopped with error", metadata: ["error": "\(error)"])
        transitionStopped()
    }
}

/// Local async wrappers around VZ's queue-based completion handlers.
///
/// Duplicated from `containerization`'s `VZVirtualMachine+Helpers` to keep the
/// boot-only spike self-contained (see PLAN.md: duplicating a few async wrappers
/// locally is acceptable for the spike).
extension VZVirtualMachine {
    func startVM(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.start { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func stopVM(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.stop { error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }
}
#endif
