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

import Foundation

#if os(macOS)
import Virtualization
#endif

/// Error surfaced by the FreeBSD boot-only runtime spike.
struct FreeBSDRuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// On-disk configuration for the boot-only FreeBSD VM spike.
///
/// Read from a single JSON file in the runtime root (`freebsd-vm.json`).
/// Required fields: `bootDisk`, `efiVariableStore`, `bootLog`.
/// Optional fields: `cpus` (default 2), `memoryBytes` (default 2 GiB),
/// `network` (default "none").
struct FreeBSDBootConfig: Sendable {
    /// Default name of the config file inside the runtime root.
    static let fileName = "freebsd-vm.json"

    var bootDisk: String
    var efiVariableStore: String
    var bootLog: String
    var cpus: Int
    var memoryBytes: UInt64
    var network: String
    /// Opt-in: attach a second virtio-console port for the guest agent handshake
    /// (Milestone 2). When false, the VM is boot-only and unchanged.
    var agent: Bool
}

extension FreeBSDBootConfig: Decodable {
    enum CodingKeys: String, CodingKey {
        case bootDisk, efiVariableStore, bootLog, cpus, memoryBytes, network, agent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bootDisk = try c.decode(String.self, forKey: .bootDisk)
        efiVariableStore = try c.decode(String.self, forKey: .efiVariableStore)
        bootLog = try c.decode(String.self, forKey: .bootLog)
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 2
        memoryBytes = try c.decodeIfPresent(UInt64.self, forKey: .memoryBytes) ?? (2 << 30)
        network = try c.decodeIfPresent(String.self, forKey: .network) ?? "none"
        agent = try c.decodeIfPresent(Bool.self, forKey: .agent) ?? false
    }
}

extension FreeBSDBootConfig {
    /// Load and decode the config file from a runtime root directory.
    static func load(fromRoot root: URL) throws -> FreeBSDBootConfig {
        let url = root.appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: url) else {
            throw FreeBSDRuntimeError("could not read config at \(url.path)")
        }
        do {
            return try JSONDecoder().decode(FreeBSDBootConfig.self, from: data)
        } catch {
            throw FreeBSDRuntimeError("invalid config \(url.path): \(error)")
        }
    }

    /// Validate paths and ensure parent directories exist.
    ///
    /// - paths must be absolute
    /// - the boot disk must exist
    /// - parent directories for the EFI store and boot log are created if missing
    func validate() throws {
        for (name, path) in [("bootDisk", bootDisk), ("efiVariableStore", efiVariableStore), ("bootLog", bootLog)] {
            guard path.hasPrefix("/") else {
                throw FreeBSDRuntimeError("\(name) must be an absolute path: \(path)")
            }
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: bootDisk, isDirectory: &isDir), !isDir.boolValue else {
            throw FreeBSDRuntimeError("bootDisk does not exist or is a directory: \(bootDisk)")
        }

        for path in [efiVariableStore, bootLog] {
            let parent = (path as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: parent) {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
        }

        guard cpus > 0 else {
            throw FreeBSDRuntimeError("cpus must be positive: \(cpus)")
        }
        guard memoryBytes > 0 else {
            throw FreeBSDRuntimeError("memoryBytes must be positive: \(memoryBytes)")
        }
    }
}

#if os(macOS)
extension FreeBSDBootConfig {
    /// CPU count clamped to the range Virtualization.framework allows.
    var resolvedCPUCount: Int {
        let lower = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let upper = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        return min(max(cpus, lower), upper)
    }

    /// Memory rounded up to a 1 MiB boundary and clamped to the VZ range.
    var resolvedMemoryBytes: UInt64 {
        let mib: UInt64 = 1 << 20
        let aligned = (memoryBytes + mib - 1) & ~(mib - 1)
        let lower = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let upper = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        return min(max(aligned, lower), upper)
    }
}
#endif
