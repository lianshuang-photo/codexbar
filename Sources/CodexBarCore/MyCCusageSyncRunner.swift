import Foundation

public struct MyCCusageSyncCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
}

public struct MyCCusageSyncStatus: Equatable, Sendable {
    public let binaryURL: URL?
    public let version: String?
    public let installCommand: String

    public var isInstalled: Bool {
        self.binaryURL != nil
    }

    public static let missing = MyCCusageSyncStatus(
        binaryURL: nil,
        version: nil,
        installCommand: MyCCusageSyncRunner.installCommand)
}

public struct MyCCusageSyncResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String

    public var succeeded: Bool {
        self.exitCode == 0
    }
}

public struct MyCCusageSyncRunner: Sendable {
    public static let binaryName = "ccusage-cherry-collector"
    public static let installCommand = "npm install -g ccusage-cherry-collector@latest"

    public let binaryURL: URL?

    public init(binaryURL: URL? = nil) {
        self.binaryURL = binaryURL
    }

    public static func syncCommand(binaryURL: URL) -> MyCCusageSyncCommand {
        MyCCusageSyncCommand(executableURL: binaryURL, arguments: ["sync"])
    }

    public static func normalizedVersion(_ raw: String) -> String? {
        let pattern = #"[0-9]+(?:\.[0-9]+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let swiftRange = Range(match.range, in: raw)
        else { return nil }
        return String(raw[swiftRange])
    }

    public func installedStatus(environment: [String: String] = ProcessInfo.processInfo
        .environment) -> MyCCusageSyncStatus
    {
        guard let binary = self.binaryURL ?? Self.findBinary(environment: environment) else {
            return .missing
        }
        let versionOutput = Self.runAndCapture(
            executableURL: binary,
            arguments: ["--version"],
            timeout: 5)
        return MyCCusageSyncStatus(
            binaryURL: binary,
            version: versionOutput.flatMap(Self.normalizedVersion),
            installCommand: Self.installCommand)
    }

    public func sync(environment: [String: String] = ProcessInfo.processInfo.environment) -> MyCCusageSyncResult {
        guard let binary = self.binaryURL ?? Self.findBinary(environment: environment) else {
            return MyCCusageSyncResult(exitCode: 127, output: "ccusage-cherry-collector is not installed.")
        }
        return Self.run(
            executableURL: binary,
            arguments: Self.syncCommand(binaryURL: binary).arguments,
            timeout: 60 * 10)
    }

    private static func findBinary(environment: [String: String]) -> URL? {
        let path = environment["PATH"] ?? ""
        for directory in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(Self.binaryName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func runAndCapture(executableURL: URL, arguments: [String], timeout: TimeInterval) -> String? {
        let result = Self.run(executableURL: executableURL, arguments: arguments, timeout: timeout)
        guard result.succeeded else { return nil }
        return result.output
    }

    private static func run(executableURL: URL, arguments: [String], timeout: TimeInterval) -> MyCCusageSyncResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return MyCCusageSyncResult(exitCode: 126, output: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return MyCCusageSyncResult(exitCode: 124, output: "ccusage-cherry-collector timed out.")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return MyCCusageSyncResult(exitCode: process.terminationStatus, output: output)
    }
}
