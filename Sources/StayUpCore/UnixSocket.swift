import Foundation

/// UNIX ドメインソケットの薄いラッパ（spec §12.1）。
///
/// CLI は短命なプロセスなので、依存を増やさず素の POSIX API で組む。
public enum UnixSocket {
    public enum SocketError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case createFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case connectFailed(Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let path):
                "ソケットのパスが長すぎます（104 バイト未満である必要があります）: \(path)"
            case .createFailed(let code):
                "socket() に失敗しました: \(String(cString: strerror(code)))"
            case .bindFailed(let code):
                "bind() に失敗しました: \(String(cString: strerror(code)))"
            case .listenFailed(let code):
                "listen() に失敗しました: \(String(cString: strerror(code)))"
            case .connectFailed(let code):
                "connect() に失敗しました: \(String(cString: strerror(code)))"
            }
        }
    }

    static func makeAddress(path: String) throws -> sockaddr_un {
        guard StayUpPaths.socketPathFitsInSockaddr(path) else {
            throw SocketError.pathTooLong(path)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                path.withCString { source in
                    strncpy(destination, source, capacity - 1)
                }
            }
        }
        return address
    }

    /// 待ち受けソケットを作る。既存の残骸は消してから bind する。
    public static func listen(at path: String, backlog: Int32 = 16) throws -> Int32 {
        var address = try makeAddress(path: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed(errno) }

        // 前回の異常終了で残ったソケットファイルを掃除する
        unlink(path)

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, size)
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketError.bindFailed(code)
        }

        // 所有者以外は触れないようにする
        chmod(path, 0o600)

        guard Foundation.listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            throw SocketError.listenFailed(code)
        }
        return fd
    }

    public static func connect(to path: String) throws -> Int32 {
        var address = try makeAddress(path: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed(errno) }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Foundation.connect(fd, sockaddrPointer, size)
            }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            throw SocketError.connectFailed(code)
        }
        return fd
    }

    /// 接続元の UID を得る。他ユーザーからの操作を弾くために使う。
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return false }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    /// 改行までを 1 メッセージとして読む。EOF なら nil。
    public static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
        var result = Data()
        var byte: UInt8 = 0
        while result.count < limit {
            let count = read(fd, &byte, 1)
            if count == 0 { return result.isEmpty ? nil : result }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if byte == 0x0A { return result }
            result.append(byte)
        }
        return result
    }
}
