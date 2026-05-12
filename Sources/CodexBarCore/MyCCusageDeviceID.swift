import CryptoKit
import Darwin
import Foundation

/// Mirrors the device-identification logic in upstream
/// `ccusage-cherry-collector/src/utils/device-info.ts` so the Swift uploader
/// posts to the leaderboard endpoint with the **same** deviceId as the
/// legacy npm collector. Two rules to keep in mind:
///
/// 1. The collector's `getDeviceInfo` consults `~/.ccusage-collector/config.json`
///    first and only regenerates when the file has no `deviceId`. That means
///    99% of existing installs have a stable historical ID written at first
///    install — possibly with hostname / MACs that no longer match today.
///    We therefore call `resolve(persisted:)` and prefer the saved value.
/// 2. When we *do* regenerate (true first-time install via codexbar alone),
///    we mirror the upstream algorithm exactly: sha256 of
///    `"<hostname>:<comma-joined-sorted-non-loopback-MACs>"`, hex-encoded,
///    truncated to 32 chars. Duplicates from interfaces with multiple
///    addresses are **kept**, matching Node's `os.networkInterfaces()` output.
public enum MyCCusageDeviceID {
    /// Resolves the device identifier, preferring the value already stored
    /// in the collector config to stay consistent with the daemon path.
    public static func resolve(persisted: MyCCusageConfig?) -> String {
        if let cached = persisted?.deviceId, !cached.isEmpty {
            return cached
        }
        return Self.generate()
    }

    /// Pure function form for testing. Callers pass an explicit hostname +
    /// MAC list; the production wrapper above pulls them from the system.
    public static func generate(
        hostname: String = Self.systemHostname(),
        macAddresses: [String] = Self.activeMACAddresses()) -> String
    {
        let sorted = macAddresses.sorted()
        let deviceString = "\(hostname):\(sorted.joined(separator: ","))"
        let digest = SHA256.hash(data: Data(deviceString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    /// Equivalent of Node `os.hostname()` — POSIX `gethostname()`.
    public static func systemHostname() -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        if gethostname(&buffer, buffer.count) == 0 {
            return String(cString: buffer)
        }
        return ProcessInfo.processInfo.hostName
    }

    /// All non-loopback link-layer addresses formatted as colon-separated
    /// lowercase hex, in interface-enumeration order (no de-duplication —
    /// Node's `os.networkInterfaces()` yields one entry per IP per interface,
    /// so the same MAC can repeat).
    public static func activeMACAddresses() -> [String] {
        var addresses: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee
            guard let sa = value.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK),
                  (value.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else { continue }
            let dl = UnsafeRawPointer(sa)
                .assumingMemoryBound(to: sockaddr_dl.self)
                .pointee
            guard dl.sdl_alen == 6 else { continue }
            guard let mac = Self.macString(from: dl), mac != "00:00:00:00:00:00" else { continue }
            addresses.append(mac)
        }
        return addresses
    }

    private static func macString(from dl: sockaddr_dl) -> String? {
        let nameLen = Int(dl.sdl_nlen)
        let macLen = Int(dl.sdl_alen)
        guard macLen == 6 else { return nil }
        var dlCopy = dl
        return withUnsafePointer(to: &dlCopy.sdl_data) { tuplePtr -> String in
            let base = UnsafeRawPointer(tuplePtr).assumingMemoryBound(to: UInt8.self)
            let bytes = UnsafeBufferPointer(start: base.advanced(by: nameLen), count: macLen)
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }
}
