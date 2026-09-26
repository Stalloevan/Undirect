import Foundation
import Network
import WebKit
import UIKit

/// Runs a real Tor client inside the app (no VPN profile).
///
/// Tor tabs use their own non-persistent WKWebsiteDataStore whose traffic is
/// sent through Tor's local SOCKS5 port via `proxyConfigurations` (iOS 17+).
/// Normal tabs are unaffected.
///
/// Surviving the background:
/// iOS "defuncts" an app's network sockets once it's suspended. For embedded
/// Tor that means its connections to relays, its SOCKS listener and its TCP
/// control port can all be dead on return, even though Tor itself still
/// believes everything is fine — which is why Tor tabs used to need an app
/// relaunch. This manager handles it in three layers:
///
///  1. A pre-authenticated *owning* control channel (a Unix socketpair from
///     tor_main_configuration_setup_control_socket) — not a network socket,
///     so it isn't torn down by suspension, and closing it is a guaranteed
///     way to stop Tor even when every TCP port is gone.
///  2. On backgrounding, Tor is put to sleep cleanly (DisableNetwork=1)
///     shortly before iOS would suspend the app; on return it's woken
///     (DisableNetwork=0 + SIGNAL ACTIVE), which reopens fresh listeners and
///     builds new circuits. Quick app switches skip this entirely.
///  3. If waking doesn't produce a working SOCKS listener and circuit in
///     time, the embedded instance is fully restarted in-process.
///
/// Tor tabs that failed while it was down reload themselves once it's back
/// (see `didRefresh`).
final class TorManager {

    static let shared = TorManager()
    static let stateDidChange = Notification.Name("UndirectTorStateDidChange")
    /// Posted (on main) whenever Tor has come back after a sleep / network
    /// change / restart and is verified usable again.
    static let didRefresh = Notification.Name("UndirectTorDidRefresh")

    enum State: Equatable {
        case off
        case starting(Int)
        case reconnecting
        case ready
        case failed(String)

        var description: String {
            switch self {
            case .off: return "Not running"
            case .starting(let p): return "Connecting… \(p)%"
            case .reconnecting: return "Reconnecting…"
            case .ready: return "Connected"
            case .failed(let why): return "Failed: \(why)"
            }
        }
    }

    // MARK: State (thread-safe)

    private let lock = NSLock()
    private var _state: State = .off
    private(set) var state: State {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set {
            lock.lock()
            let old = _state
            _state = newValue
            lock.unlock()
            guard newValue != old else { return }
            AppLog.shared.log("Tor state -> \(newValue.description)", category: "tor")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.stateDidChange, object: nil, userInfo: ["state": newValue])
            }
        }
    }

    var isReady: Bool { state == .ready }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return threadRunning }

    let socksPort: UInt16 = 39050
    let controlPort: UInt16 = 39051

    // Guarded by `lock`.
    private var threadRunning = false
    private var threadExited = true
    private var restarting = false

    /// Main-thread only.
    private var torThread: Thread?

    /// All control-protocol I/O is serialized here.
    private let commandQueue = DispatchQueue(label: "undirect.tor.command")
    /// Bootstrap monitoring, wake/sleep orchestration and restarts.
    private let workQueue = DispatchQueue(label: "undirect.tor.work")
    // commandQueue-only.
    private var owningControl: TorControlSocket?
    private var tcpControl: TorControlSocket?

    // workQueue-only.
    private var refreshInFlight = false
    private var refreshQueued: Bool? // queued forceCycle flag

    // Main-thread only.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pendingSleep: DispatchWorkItem?
    private var enteredBackgroundAt: Date?
    private var isAsleep = false

    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        pathMonitor.pathUpdateHandler = { [weak self] path in self?.networkPathChanged(path) }
        pathMonitor.start(queue: workQueue)
    }

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

    // MARK: Start

    /// Starts Tor if it isn't running, and repairs it if it's running but
    /// stuck in a failed state (e.g. a bootstrap that timed out) — what a Tor
    /// tab calls whenever it needs Tor, so nothing stays stuck until relaunch.
    func ensureRunning() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.ensureRunning() }; return }
        if torThread == nil { start(); return }
        if case .failed = state { refresh(reason: "recovering from failure", forceCycle: true) }
    }

    func start() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.start() }; return }
        guard torThread == nil else { return }

        lock.lock()
        threadRunning = true
        threadExited = false
        lock.unlock()
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

        guard let cfg = tor_main_configuration_new() else {
            markThreadExited()
            state = .failed("couldn't configure Tor")
            return
        }
        // Tor keeps a pointer to argv for its whole lifetime, so it is never freed.
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: args.count + 1)
        for (i, arg) in args.enumerated() { argv[i] = strdup(arg) }
        argv[args.count] = nil
        guard tor_main_configuration_set_command_line(cfg, Int32(args.count), argv) == 0 else {
            tor_main_configuration_free(cfg)
            markThreadExited()
            state = .failed("couldn't configure Tor")
            return
        }
        let owningFD = tor_main_configuration_setup_control_socket(cfg)
        commandQueue.sync {
            owningControl?.close()
            owningControl = owningFD >= 0 ? TorControlSocket(fd: owningFD) : nil
            tcpControl?.close()
            tcpControl = nil
        }

        let thread = Thread { [weak self] in
            _ = tor_run_main(cfg)
            tor_main_configuration_free(cfg)
            guard let self else { return }
            let wasRestart = self.markThreadExited()
            // A restart in progress handles its own state transitions; only
            // report a bare failure for an *unrequested* stop.
            if !wasRestart { self.state = .failed("Tor stopped") }
            DispatchQueue.main.async {
                if !wasRestart { self.torThread = nil }
            }
        }
        thread.name = "tor"
        thread.stackSize = 8 * 1024 * 1024
        torThread = thread
        thread.start()

        workQueue.async { self.monitorBootstrap() }
    }

    /// Returns whether a restart was in progress.
    @discardableResult
    private func markThreadExited() -> Bool {
        lock.lock(); defer { lock.unlock() }
        threadRunning = false
        threadExited = true
        return restarting
    }

    private func monitorBootstrap() {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if case .failed = state { return }
            if !isRunning { return }
            if let progress = bootstrapProgress() {
                if progress >= 100, circuitEstablished() == true {
                    state = .ready
                    return
                }
                state = .starting(min(progress, 99))
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        state = .failed("timed out")
    }

    // MARK: Control channel

    /// Runs a control command, preferring the owning socketpair (survives
    /// suspension, pre-authenticated) and falling back to the TCP port.
    @discardableResult
    private func send(_ command: String) -> String? {
        commandQueue.sync {
            if let owning = owningControl {
                if let reply = owning.send(command) {
                    if reply.hasPrefix("514"), authenticate(owning), let retry = owning.send(command) {
                        return retry
                    }
                    return reply
                }
                owning.close()
                owningControl = nil
            }
            if tcpControl == nil { tcpControl = connectTCPControl() }
            if let reply = tcpControl?.send(command) { return reply }
            tcpControl?.close()
            tcpControl = connectTCPControl()
            return tcpControl?.send(command)
        }
    }

    private func connectTCPControl() -> TorControlSocket? {
        let socket = TorControlSocket()
        guard socket.connect(port: controlPort), authenticate(socket) else { socket.close(); return nil }
        return socket
    }

    private func authenticate(_ socket: TorControlSocket) -> Bool {
        let cookieFile = dataDirectory.appendingPathComponent("control_auth_cookie")
        guard let cookie = try? Data(contentsOf: cookieFile), !cookie.isEmpty else { return false }
        let hex = cookie.map { String(format: "%02X", $0) }.joined()
        return socket.send("AUTHENTICATE \(hex)")?.hasPrefix("250") ?? false
    }

    private func bootstrapProgress() -> Int? {
        guard let reply = send("GETINFO status/bootstrap-phase"),
              let range = reply.range(of: "PROGRESS=[0-9]+", options: .regularExpression) else { return nil }
        return Int(reply[range].dropFirst("PROGRESS=".count))
    }

    private func circuitEstablished() -> Bool? {
        guard let reply = send("GETINFO status/circuit-established") else { return nil }
        return reply.contains("circuit-established=1")
    }

    /// A real SOCKS5 greeting, not just a TCP connect: proves Tor's event
    /// loop is actually servicing the listener.
    private func socksResponds() -> Bool {
        let socket = TorControlSocket()
        defer { socket.close() }
        guard socket.connect(port: socksPort, timeout: 3) else { return false }
        guard socket.writeRaw([0x05, 0x01, 0x00]) else { return false }
        return socket.readRaw(count: 2) == [0x05, 0x00]
    }

    private func isHealthy() -> Bool {
        guard isRunning, circuitEstablished() == true else { return false }
        return socksResponds()
    }

    // MARK: Background / foreground

    @objc private func appDidEnterBackground() {
        guard isRunning else { return }
        enteredBackgroundAt = Date()
        // Keep Tor fully alive through quick app switches; only put it to
        // sleep shortly before iOS would suspend us anyway.
        let app = UIApplication.shared
        endBackgroundTask()
        backgroundTask = app.beginBackgroundTask(withName: "undirect.tor.sleep") { [weak self] in
            self?.sleepNow()
            self?.endBackgroundTask()
        }
        let item = DispatchWorkItem { [weak self] in self?.sleepNow() }
        pendingSleep = item
        let delay = min(12, max(1, app.backgroundTimeRemaining - 6))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func sleepNow() {
        pendingSleep?.cancel()
        pendingSleep = nil
        guard !isAsleep, isRunning else { endBackgroundTask(); return }
        isAsleep = true
        workQueue.async {
            // Closes relay connections and the SOCKS listener cleanly while
            // we still can, so nothing is left half-dead during suspension.
            let ok = self.send("SETCONF DisableNetwork=1")?.hasPrefix("250") ?? false
            AppLog.shared.log(ok ? "Tor asleep for background" : "Couldn't put Tor to sleep (will restart on return if needed)", category: "tor")
            DispatchQueue.main.async { self.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    @objc private func appWillEnterForeground() {
        pendingSleep?.cancel()
        pendingSleep = nil
        endBackgroundTask()
        let away = enteredBackgroundAt.map { Date().timeIntervalSince($0) } ?? 0
        enteredBackgroundAt = nil
        let slept = isAsleep
        isAsleep = false

        guard torThread != nil else {
            // Tor died while we were away (or failed earlier): bring it back
            // if anything actually uses it.
            if case .failed = state { start() }
            return
        }
        // Asleep, or away long enough that iOS has likely defuncted our
        // sockets: always cycle. A short trip just gets a health check.
        let forceCycle = slept || away > 8
        refresh(reason: slept ? "waking after background" : "returning to foreground", forceCycle: forceCycle)
    }

    private func networkPathChanged(_ path: NWPath) {
        // workQueue
        let signature = "\(path.status)-" + path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",")
        defer { lastPathSignature = signature }
        guard let last = lastPathSignature, last != signature,
              path.status == .satisfied, state == .ready else { return }
        // Wi-Fi <-> cellular hand-offs strand existing relay connections.
        refresh(reason: "network changed", forceCycle: true)
    }

    // MARK: Refresh / restart

    /// Verifies Tor is usable and repairs it if not. Safe to call often; calls
    /// made while a refresh is running are coalesced into one follow-up.
    func refresh(reason: String, forceCycle: Bool = true) {
        workQueue.async { self.performRefresh(reason: reason, forceCycle: forceCycle) }
    }

    private func performRefresh(reason: String, forceCycle: Bool) {
        guard !refreshInFlight else {
            refreshQueued = (refreshQueued ?? false) || forceCycle
            return
        }
        guard isRunning else {
            DispatchQueue.main.async { self.start() }
            return
        }
        refreshInFlight = true
        defer {
            refreshInFlight = false
            if let queued = refreshQueued {
                refreshQueued = nil
                // Only worth another pass if it's still not healthy.
                if !isHealthy() { performRefresh(reason: "follow-up", forceCycle: queued) }
            }
        }

        if !forceCycle {
            if isHealthy() {
                if state != .ready { state = .ready }
                return
            }
        }
        AppLog.shared.log("Refreshing Tor (\(reason))", category: "tor")
        state = .reconnecting

        guard send("GETINFO version")?.hasPrefix("250") == true else {
            restartInProcess(reason: "control channel unreachable")
            return
        }
        send("SETCONF DisableNetwork=1")
        send("SETCONF DisableNetwork=0")
        send("SIGNAL ACTIVE")

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if !isRunning { break }
            if isHealthy() {
                state = .ready
                AppLog.shared.log("Tor refreshed", category: "tor")
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didRefresh, object: nil) }
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        restartInProcess(reason: "no working circuit after wake")
    }

    /// Stops the embedded Tor (asking it via the control channel, then
    /// closing the owning socket, which Tor treats as a mandatory shutdown)
    /// and starts a fresh instance on the same ports and data directory.
    /// workQueue only.
    private func restartInProcess(reason: String) {
        AppLog.shared.log("Restarting Tor in-process (\(reason))", category: "tor")
        lock.lock(); restarting = true; lock.unlock()
        state = .reconnecting

        _ = send("SIGNAL SHUTDOWN")
        commandQueue.sync {
            owningControl?.close()
            owningControl = nil
            tcpControl?.close()
            tcpControl = nil
        }

        let deadline = Date().addingTimeInterval(10)
        while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }

        lock.lock()
        let exited = threadExited
        restarting = false
        lock.unlock()

        guard exited else {
            state = .failed("Tor didn't stop — restart the app")
            return
        }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.main.async {
            self.torThread = nil
            self.start()
            group.leave()
        }
        group.wait()
        // Wait for the new instance, then let tabs retry.
        let readyBy = Date().addingTimeInterval(45)
        while Date() < readyBy {
            if state == .ready {
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didRefresh, object: nil) }
                return
            }
            if case .failed = state { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    func newIdentity(completion: @escaping (Bool) -> Void) {
        workQueue.async {
            let ok = self.send("SIGNAL NEWNYM")?.hasPrefix("250") ?? false
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

/// Minimal blocking client for Tor's control protocol (and a raw SOCKS probe).
final class TorControlSocket {
    private var fd: Int32 = -1

    init() {}

    /// Wraps an already-connected descriptor (the owning socketpair end).
    init(fd: Int32) {
        self.fd = fd
        configure(timeout: 5)
    }

    func connect(port: UInt16, timeout: Int = 5) -> Bool {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        configure(timeout: timeout)
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
        return true
    }

    private func configure(timeout: Int) {
        guard fd >= 0 else { return }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // Writing to a socket Tor already closed must never SIGPIPE the app.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ command: String) -> String? {
        guard fd >= 0, writeRaw(Array((command + "\r\n").utf8)) else { return nil }
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

    func writeRaw(_ bytes: [UInt8]) -> Bool {
        guard fd >= 0 else { return false }
        let written = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        return written == bytes.count
    }

    func readRaw(count: Int) -> [UInt8]? {
        guard fd >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            guard n > 0 else { return nil }
            got += n
        }
        return buffer
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    deinit { close() }
}
