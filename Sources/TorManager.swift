import Foundation
import Network
import WebKit

/// Runs a real Tor client inside the app (no VPN profile).
///
/// Tor tabs use their own non-persistent WKWebsiteDataStore whose traffic is
/// sent through Tor's local SOCKS5 port via `proxyConfigurations` (iOS 17+).
/// Normal tabs are unaffected. Tor can only be started once per app process,
/// so turning Tor off for a tab just stops routing that tab through it.
final class TorManager {

    static let shared = TorManager()
    static let stateDidChange = Notification.Name("UndirectTorStateDidChange")

    enum State: Equatable {
        case off
        case starting(Int)
        case ready
        case failed(String)

        var description: String {
            switch self {
            case .off: return "Not running"
            case .starting(let p): return "Connecting… \(p)%"
            case .ready: return "Connected"
            case .failed(let why): return "Failed: \(why)"
            }
        }
    }

    private(set) var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            let s = state
            AppLog.shared.log("Tor state -> \(s.description)", category: "tor")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.stateDidChange, object: nil, userInfo: ["state": s])
            }
        }
    }

    var isReady: Bool { state == .ready }

    let socksPort: UInt16 = 39050
    let controlPort: UInt16 = 39051

    private var torThread: Thread?
    private var control: TorControlSocket?
    private let controlQueue = DispatchQueue(label: "undirect.tor.control")

    private init() {}

    /// Shared, in-memory data store for all Tor tabs. Nothing is written to disk
    /// and it is separate from normal browsing cookies.
    lazy var dataStore: WKWebsiteDataStore = {
        let store = WKWebsiteDataStore.nonPersistent()
        if let port = NWEndpoint.Port(rawValue: socksPort) {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)
            store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
        }
        return store
    }()

    private var dataDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("tor", isDirectory: true)
    }

    func start() {
        guard torThread == nil else { return }
        state = .starting(0)

        let dir = dataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("control_auth_cookie"))

        let args = [
            "tor",
            "--SocksPort", "127.0.0.1:\(socksPort)",
            "--ControlPort", "127.0.0.1:\(controlPort)",
            "--CookieAuthentication", "1",
            "--DataDirectory", dir.path,
            "--ClientOnly", "1",
            "--AvoidDiskWrites", "1",
            "--DisableDebuggerAttachment", "0",
            "--Log", "notice stdout"
        ]

        let thread = Thread {
            TorManager.runTor(arguments: args)
            TorManager.shared.state = .failed("Tor stopped")
        }
        thread.name = "tor"
        thread.stackSize = 8 * 1024 * 1024
        torThread = thread
        thread.start()

        controlQueue.async { self.monitorBootstrap() }
    }

    private static func runTor(arguments: [String]) {
        guard let cfg = tor_main_configuration_new() else { return }
        // Tor keeps a pointer to argv for its whole lifetime, so it is never freed.
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
        for (i, arg) in arguments.enumerated() { argv[i] = strdup(arg) }
        argv[arguments.count] = nil
        guard tor_main_configuration_set_command_line(cfg, Int32(arguments.count), argv) == 0 else { return }
        _ = tor_run_main(cfg)
    }

    private func monitorBootstrap() {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if case .failed = state { return }
            if control == nil { control = connectControl() }
            if let control, let reply = control.send("GETINFO status/bootstrap-phase") {
                if let range = reply.range(of: "PROGRESS=[0-9]+", options: .regularExpression),
                   let value = Int(reply[range].dropFirst("PROGRESS=".count)) {
                    if value >= 100 { state = .ready; return }
                    state = .starting(value)
                }
            } else {
                control?.close()
                control = nil
            }
            Thread.sleep(forTimeInterval: 0.75)
        }
        state = .failed("timed out")
    }

    private func connectControl() -> TorControlSocket? {
        let cookieFile = dataDirectory.appendingPathComponent("control_auth_cookie")
        guard let cookie = try? Data(contentsOf: cookieFile), !cookie.isEmpty else { return nil }
        let socket = TorControlSocket()
        guard socket.connect(port: controlPort) else { return nil }
        let hex = cookie.map { String(format: "%02X", $0) }.joined()
        guard let reply = socket.send("AUTHENTICATE \(hex)"), reply.hasPrefix("250") else {
            socket.close()
            return nil
        }
        return socket
    }

    /// Asks Tor for fresh circuits (new exit IP for new connections).
    func newIdentity(completion: @escaping (Bool) -> Void) {
        controlQueue.async {
            let ok = self.control?.send("SIGNAL NEWNYM")?.hasPrefix("250") ?? false
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

/// Minimal blocking client for Tor's control protocol.
final class TorControlSocket {
    private var fd: Int32 = -1

    func connect(port: UInt16) -> Bool {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(); return false }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return true
    }

    func send(_ command: String) -> String? {
        guard fd >= 0 else { return nil }
        let bytes = Array((command + "\r\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard written == bytes.count else { return nil }

        var response = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            response += String(decoding: buffer[0..<n], as: UTF8.self)
            guard response.hasSuffix("\r\n") else { continue }
            let lines = response.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            if let last = lines.last, last.count >= 4,
               last[last.index(last.startIndex, offsetBy: 3)] == " " {
                return response
            }
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    deinit { close() }
}
