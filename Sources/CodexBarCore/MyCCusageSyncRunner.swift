import Foundation

public struct MyCCusageSyncCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
}

public struct MyCCusageSyncStatus: Equatable, Sendable {
    public let binaryURL: URL?
    public let version: String?
    public let installCommand: String

    public init(binaryURL: URL?, version: String?, installCommand: String) {
        self.binaryURL = binaryURL
        self.version = version
        self.installCommand = installCommand
    }

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
    public static let pm2BinaryName = "pm2"
    public static let pm2ProcessName = "ccusage-cherry-collector"
    public static let installCommand =
        "npm install -g ccusage-cherry-collector@latest pm2 && " +
        "CHROME_PATH=/bin/false PUPPETEER_EXECUTABLE_PATH=/bin/false ccusage-cherry-collector start --daemon"

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
        let syncEnvironment = Self.syncEnvironment(environment)
        if self.binaryURL == nil {
            if let pm2 = Self.findBinary(Self.pm2BinaryName, environment: environment),
               Self.isCollectorDaemonAvailable(pm2URL: pm2, environment: syncEnvironment)
            {
                let result = Self.run(
                    executableURL: pm2,
                    arguments: ["restart", Self.pm2ProcessName, "--update-env"],
                    environment: syncEnvironment,
                    timeout: 60)
                guard result.succeeded else { return result }
                let output = result.output.isEmpty ? "Triggered ccusage-cherry-collector daemon sync." : result.output
                return MyCCusageSyncResult(exitCode: result.exitCode, output: output)
            }

            return MyCCusageSyncResult(
                exitCode: 127,
                output: "ccusage-cherry-collector background daemon is not running. Run: \(Self.installCommand)")
        }

        guard let binary = self.binaryURL else {
            return MyCCusageSyncResult(exitCode: 127, output: "ccusage-cherry-collector is not installed.")
        }
        return Self.run(
            executableURL: binary,
            arguments: Self.syncCommand(binaryURL: binary).arguments,
            environment: syncEnvironment,
            timeout: 60 * 10)
    }

    public static func syncEnvironment(_ environment: [String: String]) -> [String: String] {
        var resolved = environment
        #if os(macOS)
        resolved["CHROME_PATH"] = "/bin/false"
        resolved["PUPPETEER_EXECUTABLE_PATH"] = "/bin/false"
        #endif
        return resolved
    }

    private static func findBinary(environment: [String: String]) -> URL? {
        self.findBinary(self.binaryName, environment: environment)
    }

    private static func findBinary(_ name: String, environment: [String: String]) -> URL? {
        let path = environment["PATH"] ?? ""
        for directory in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        if let shellHit = ShellCommandLocator.commandV(
            name,
            environment["SHELL"],
            2.0,
            .default)
        {
            return URL(fileURLWithPath: shellHit)
        }
        return nil
    }

    private static func isCollectorDaemonAvailable(pm2URL: URL, environment: [String: String]) -> Bool {
        let result = Self.run(executableURL: pm2URL, arguments: ["jlist"], environment: environment, timeout: 5)
        guard result.succeeded, let data = result.output.data(using: .utf8) else { return false }
        guard let processes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return processes.contains { process in
            guard process["name"] as? String == Self.pm2ProcessName else { return false }
            let environment = process["pm2_env"] as? [String: Any]
            let status = environment?["status"] as? String
            return status == nil || status == "online" || status == "stopped"
        }
    }

    private static func runAndCapture(executableURL: URL, arguments: [String], timeout: TimeInterval) -> String? {
        let result = Self.run(executableURL: executableURL, arguments: arguments, environment: nil, timeout: timeout)
        guard result.succeeded else { return nil }
        return result.output
    }

    private static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval) -> MyCCusageSyncResult
    {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

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
