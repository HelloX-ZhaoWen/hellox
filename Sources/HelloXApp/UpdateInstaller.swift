import AppKit
import Foundation
import HelloXCore

enum UpdateInstallationError: LocalizedError {
    case notInstalled
    case invalidBundle
    case invalidVersion
    case unsupportedArchitecture
    case stagingExists
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "请先将 HelloX 安装到“应用程序”后再更新"
        case .invalidBundle: "更新包中的应用身份无效"
        case .invalidVersion: "更新包版本与发布版本不一致"
        case .unsupportedArchitecture: "更新包不是 Intel 和 Apple Silicon 通用版本"
        case .stagingExists: "检测到未完成的更新，请重启后重试"
        case .commandFailed(let message): message
        }
    }
}

struct UpdateInstaller {
    static let installedApplicationURL = URL(fileURLWithPath: "/Applications/HelloX.app", isDirectory: true)

    @MainActor
    func install(update: AppUpdate, dmgURL: URL) throws {
        let runningApplicationURL = Bundle.main.bundleURL.standardizedFileURL
        guard runningApplicationURL == Self.installedApplicationURL else {
            throw UpdateInstallationError.notInstalled
        }

        let fileManager = FileManager.default
        let updateRoot = fileManager.temporaryDirectory.appendingPathComponent("HelloX-update-\(UUID().uuidString)", isDirectory: true)
        let mountPoint = updateRoot.appendingPathComponent("mount", isDirectory: true)
        let stagedApplicationURL = URL(fileURLWithPath: "/Applications/HelloX.app.new", isDirectory: true)
        let backupApplicationURL = URL(fileURLWithPath: "/Applications/HelloX.app.backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: updateRoot) }

        try run(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", dmgURL.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        )
        defer { _ = try? run(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"]) }

        let hiddenCandidateURL = mountPoint
            .appendingPathComponent(".update", isDirectory: true)
            .appendingPathComponent("HelloX.app", isDirectory: true)
        let rootCandidateURL = mountPoint.appendingPathComponent("HelloX.app", isDirectory: true)
        let candidateURL = [hiddenCandidateURL, rootCandidateURL]
            .first(where: { fileManager.fileExists(atPath: $0.path) }) ?? hiddenCandidateURL
        guard fileManager.fileExists(atPath: candidateURL.path) else { throw UpdateInstallationError.invalidBundle }
        try validate(candidateURL, expectedVersion: update.version)

        guard !fileManager.fileExists(atPath: stagedApplicationURL.path) else {
            throw UpdateInstallationError.stagingExists
        }
        try run(executable: "/usr/bin/ditto", arguments: [candidateURL.path, stagedApplicationURL.path])
        try validate(stagedApplicationURL, expectedVersion: update.version)

        let helperURL = try writeReplacementHelper(
            source: runningApplicationURL,
            target: Self.installedApplicationURL,
            staged: stagedApplicationURL,
            backup: backupApplicationURL
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    private func validate(_ applicationURL: URL, expectedVersion: SemanticVersion) throws {
        guard let bundle = Bundle(url: applicationURL),
              bundle.bundleIdentifier == "com.hellox.app" else {
            throw UpdateInstallationError.invalidBundle
        }
        guard let versionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              SemanticVersion(versionString) == expectedVersion else {
            throw UpdateInstallationError.invalidVersion
        }
        let executableURL = applicationURL.appendingPathComponent("Contents/MacOS/HelloX")
        let architectures = try run(executable: "/usr/bin/lipo", arguments: ["-archs", executableURL.path])
        guard architectures.split(whereSeparator: { $0.isWhitespace }).contains("arm64"),
              architectures.split(whereSeparator: { $0.isWhitespace }).contains("x86_64") else {
            throw UpdateInstallationError.unsupportedArchitecture
        }
        try run(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", "--verbose=2", applicationURL.path])
        try run(executable: "/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", "--verbose=2", applicationURL.path])
    }

    private func writeReplacementHelper(source: URL, target: URL, staged: URL, backup: URL) throws -> URL {
        let helperURL = FileManager.default.temporaryDirectory.appendingPathComponent("HelloX-replace-\(UUID().uuidString).zsh")
        let trashDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        let script = """
        #!/bin/zsh
        set -eu
        pid="$1"
        source='\(source.path)'
        target='\(target.path)'
        staged='\(staged.path)'
        backup='\(backup.path)'
        trash='\(trashDirectory.path)/HelloX-backup-\(UUID().uuidString).app'
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        /bin/mv "$source" "$backup"
        [[ "$source" == "$target" ]] || /bin/rm -rf "$target"
        if /bin/mv "$staged" "$target"; then
          /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" >/dev/null 2>&1 || true
          /usr/bin/open -n "$target"
          /bin/mv "$backup" "$trash"
          /bin/rm -f "$0"
          exit 0
        fi
        /bin/mv "$backup" "$target"
        exit 1
        """
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        return helperURL
    }

    @discardableResult
    private func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateInstallationError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return message
    }
}
