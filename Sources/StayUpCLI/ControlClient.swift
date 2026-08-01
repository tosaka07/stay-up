import Foundation
import StayUpCore

/// アプリのコントロールソケットに 1 往復するクライアント。
struct ControlClient {
    let socketPath: String

    init(socketPath: String = StayUpPaths.socketFile.path(percentEncoded: false)) {
        self.socketPath = socketPath
    }

    /// リクエストを送って応答を待つ。
    ///
    /// アプリが起動していなければ、起動してから最大 5 秒待って再試行する（spec §10）。
    func send(_ request: ControlRequest, autoLaunch: Bool = true) -> Result<ControlResponse, ControlError> {
        if let response = trySend(request) { return .success(response) }

        guard autoLaunch else {
            return .failure(ControlError(
                code: .appUnavailable,
                message: "StayUp に接続できません",
                nonFatal: true
            ))
        }

        guard launchApp() else {
            return .failure(ControlError(
                code: .appUnavailable,
                message: "StayUp.app を起動できませんでした",
                nonFatal: true
            ))
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            usleep(150_000)
            if let response = trySend(request) { return .success(response) }
        }

        return .failure(ControlError(
            code: .appUnavailable,
            message: "StayUp の起動を待ちましたが応答がありません",
            nonFatal: true
        ))
    }

    private func trySend(_ request: ControlRequest) -> ControlResponse? {
        guard let fd = try? UnixSocket.connect(to: socketPath) else { return nil }
        defer { close(fd) }

        guard let payload = try? ControlCoding.encodeLine(request),
              UnixSocket.writeAll(fd, payload),
              let line = UnixSocket.readLine(fd)
        else { return nil }

        return try? ControlCoding.makeDecoder().decode(ControlResponse.self, from: line)
    }

    /// `stay-up` は .app に同梱されるので、自分の位置からアプリ本体を辿れる。
    private func launchApp() -> Bool {
        guard let bundleURL = enclosingAppBundleURL() else { return false }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = [
            "-g",
            "-a", bundleURL.path(percentEncoded: false),
            "--args", "--stay-up-background",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// `StayUp.app/Contents/MacOS/stay-up` から `StayUp.app` を求める。
    private func enclosingAppBundleURL() -> URL? {
        var url = URL(filePath: CommandLine.arguments[0])
        if !url.path.hasPrefix("/") {
            url = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: url.path)
        }
        url = url.resolvingSymlinksInPath()

        // .../StayUp.app/Contents/MacOS/stay-up → .../StayUp.app
        var candidate = url.deletingLastPathComponent()
        for _ in 0..<3 {
            if candidate.pathExtension == "app" { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }

        // 開発時の swift build 直下からは辿れないので、既定の場所を見る
        for path in ["/Applications/StayUp.app", NSHomeDirectory() + "/Applications/StayUp.app"] {
            if FileManager.default.fileExists(atPath: path) {
                return URL(filePath: path)
            }
        }
        return nil
    }
}
