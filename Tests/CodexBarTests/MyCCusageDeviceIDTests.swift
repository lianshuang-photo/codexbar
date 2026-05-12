import CodexBarCore
import Foundation
import Testing

struct MyCCusageDeviceIDTests {
    @Test
    func `generate matches Node SHA256 algorithm against a captured reference`() {
        // Golden values captured by running the upstream
        // ccusage-cherry-collector device-info.ts on a known machine; the
        // duplicates are intentional (one Node entry per interface address,
        // not per interface) so the Swift port must keep them and only sort.
        let hostname = "cherryaideMac-mini.local"
        let macs = [
            "02:52:97:e9:62:3c", "02:52:97:e9:62:3c",
            "1e:f6:4c:36:70:64", "1e:f6:4c:36:70:64", "1e:f6:4c:36:70:64",
            "1e:f6:4c:36:70:65", "1e:f6:4c:36:70:65", "1e:f6:4c:36:70:65",
            "92:e9:d9:9e:6e:c8", "92:e9:d9:9e:6e:c8",
        ]
        let id = MyCCusageDeviceID.generate(hostname: hostname, macAddresses: macs)
        #expect(id == "78269c1332379402f1e4afcd08a800b7")
    }

    @Test
    func `generate sorts MAC addresses before hashing`() {
        let hostname = "host.local"
        let asGiven = ["bb:bb:bb:bb:bb:bb", "aa:aa:aa:aa:aa:aa"]
        let preSorted = ["aa:aa:aa:aa:aa:aa", "bb:bb:bb:bb:bb:bb"]
        #expect(
            MyCCusageDeviceID.generate(hostname: hostname, macAddresses: asGiven)
                == MyCCusageDeviceID.generate(hostname: hostname, macAddresses: preSorted))
    }

    @Test
    func `generate is deterministic for empty MAC list`() {
        let id = MyCCusageDeviceID.generate(hostname: "empty.local", macAddresses: [])
        // sha256("empty.local:")[:32]
        #expect(id == "73b09aaf4d447c0fbfe68e69be6531c6")
    }

    @Test
    func `resolve prefers the deviceId already saved in the collector config`() {
        let config = MyCCusageConfig(
            apiKey: "k",
            endpoint: "https://example.invalid/api/usage-sync",
            deviceId: "historical-id-from-first-install")
        #expect(MyCCusageDeviceID.resolve(persisted: config) == "historical-id-from-first-install")
    }

    @Test
    func `resolve falls back to system-derived id when config has no deviceId`() {
        let config = MyCCusageConfig(
            apiKey: "k",
            endpoint: "https://example.invalid/api/usage-sync")
        let generated = MyCCusageDeviceID.resolve(persisted: config)
        #expect(generated.count == 32)
        let hex = Set("0123456789abcdef")
        #expect(generated.allSatisfy { hex.contains($0) })
    }
}
