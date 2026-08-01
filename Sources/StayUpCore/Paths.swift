import Foundation

/// アプリ・CLI・ヘルパーが共有する識別子とファイル配置。
///
/// spec §11.2 のファイル構成をここ一箇所で定義する。
public enum StayUpPaths {
    public static let bundleIdentifier = "dev.tosaka.StayUp"
    public static let helperIdentifier = "dev.tosaka.StayUp.Helper"
    public static let helperPlistName = "dev.tosaka.StayUp.Helper.plist"

    /// `~/Library/Application Support/StayUp`
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["STAYUP_SUPPORT_DIR"] {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "StayUp", directoryHint: .isDirectory)
    }

    public static var historyDirectory: URL {
        supportDirectory.appending(path: "history", directoryHint: .isDirectory)
    }

    public static var stateFile: URL {
        supportDirectory.appending(path: "state.json")
    }

    public static var socketFile: URL {
        supportDirectory.appending(path: "control.sock")
    }

    /// 支援ディレクトリを作る。所有者のみアクセス可能にする。
    public static func createSupportDirectories() throws {
        let fm = FileManager.default
        for dir in [supportDirectory, historyDirectory] {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    /// `sockaddr_un.sun_path` は 104 バイトしかないため、実際に bind できるか事前に確かめる。
    public static func socketPathFitsInSockaddr(_ path: String) -> Bool {
        // sun_path は終端の NUL を含めて 104 バイト。
        path.utf8.count < 104
    }
}
