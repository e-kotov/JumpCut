import Foundation

/// Redacted machine-info block for CSV headers and video captions.
///
/// PRIVACY INVARIANT: this struct must never expose a serial number, hardware
/// UUID, hostname, user name, or any other identifier that ties a measurement
/// to a specific machine or person. We deliberately read only:
///   - `hw.model`        marketing-adjacent model identifier (e.g. "Mac15,3")
///   - CPU brand/core counts via `sysctlbyname`
///   - physical memory via `hw.memsize`
///   - the macOS product version via `ProcessInfo`
/// and nothing from `IOPlatformSerialNumber` / `IOPlatformUUID` / `gethostname`.
struct MachineInfo: Sendable {
    let model: String
    let chip: String
    let coreSummary: String
    let memoryGB: Int
    let osVersion: String

    static func current() -> MachineInfo {
        MachineInfo(
            model: sysctlString("hw.model") ?? "unknown model",
            chip: sysctlString("machdep.cpu.brand_string")
                ?? sysctlString("hw.model")
                ?? "unknown chip",
            coreSummary: coreSummary(),
            memoryGB: memoryGB(),
            osVersion: osVersionString()
        )
    }

    /// One-line caption form, safe to burn into a video. No identifiers.
    var captionLine: String {
        "\(chip) · \(coreSummary) · \(memoryGB) GB · macOS \(osVersion)"
    }

    /// Multi-line block for the CSV / stdout header.
    var block: String {
        """
        machine: \(model)
        chip:    \(chip)
        cores:   \(coreSummary)
        memory:  \(memoryGB) GB
        macOS:   \(osVersion)
        """
    }

    // MARK: - sysctl helpers (allocation-light, no shelling out)

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // Trim the trailing NUL(s) sysctl includes, then decode as UTF-8.
        if let nul = buffer.firstIndex(of: 0) { buffer.removeSubrange(nul...) }
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func memoryGB() -> Int {
        guard let bytes = sysctlInt("hw.memsize") else { return 0 }
        // Round to nearest GiB; Apple reports e.g. 17179869184 for "16 GB".
        return Int((Double(bytes) / 1_073_741_824.0).rounded())
    }

    private static func coreSummary() -> String {
        // Apple Silicon exposes performance/efficiency core counts. Fall back to
        // the logical CPU count when those keys are absent (Intel).
        if let perf = sysctlInt("hw.perflevel0.logicalcpu"),
           let eff = sysctlInt("hw.perflevel1.logicalcpu") {
            return "\(perf)P + \(eff)E cores"
        }
        if let total = sysctlInt("hw.logicalcpu") {
            return "\(total) cores"
        }
        return "unknown cores"
    }

    private static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
