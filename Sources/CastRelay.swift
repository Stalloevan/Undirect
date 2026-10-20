import Foundation
import Network
import WebKit
import Security

/// A tiny private HTTP server on the phone that lets an AirPlay TV play
/// videos it couldn't fetch on its own.
///
/// When you AirPlay a web video, the TV downloads it itself. Many sites only
/// serve video to the browser that loaded the page (they check its cookies,
/// Referer, or a link signed for its IP address), and Tor tabs load over a
/// different network address than the TV uses — so the TV shows the title and
/// length, then spins forever.
///
/// With the relay, the TV asks the phone instead: each request is fetched
/// from the site with the tab's own cookies, user agent and Referer (through
/// Tor for Tor tabs) and streamed back. HLS playlists are rewritten so every
/// segment and key goes through the relay too.
///
/// Only runs while something is being cast. Every URL carries a random
/// secret, so nothing else on the network can use it as a proxy, and it only
/// serves addresses it handed out itself.
final class CastRelay {
    static let shared = CastRelay()

    struct Context {
        var cookies: [HTTPCookie]
        var userAgent: String
        var referer: URL?
        var isTor: Bool
        var acceptLanguage: String?
        /// Fetches through the page itself (preferred): the site sees the
        /// browser's exact request — cookies, Origin, Referer, Sec-Fetch
        /// headers, Tor — because it *is* the browser's request.
        var pageFetcher: PageFetcher?
    }

    enum RelayError: LocalizedError {
        case noWiFi, couldNotStart
        var errorDescription: String? {
            switch self {
            case .noWiFi: return "Connect to the same Wi-Fi network as your TV to cast this video."
            case .couldNotStart: return "Couldn't start streaming to the TV."
            }
        }
    }

    private let queue = DispatchQueue(label: "undirect.castrelay")
    private var listener: NWListener?
    private var session: URLSession?
    private var context: Context?
    private var token = ""
    private var host = ""
    private var port: UInt16 = 0
    private var routes: [String: URL] = [:]
    private var routeIDs: [String: String] = [:]
    private var activeTasks: [ObjectIdentifier: RelayTask] = [:]
    private var loggedFailure = false
    private var loggedPageSuccess = false
    private var loggedRequest = false
    private var loggedDirect = false
    private var loggedErrorBody = false
    private var pageFetchBroken = false

    private init() {}

    var isRunning: Bool { queue.sync { listener != nil } }

    // MARK: Lifecycle

    /// Starts (or restarts) the relay for one cast and returns the relay
    /// address for `upstream`. Calls back on the main queue.
    func start(upstream: URL, context: Context, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            self.stopLocked()
            guard let address = Self.wifiAddress() else {
                DispatchQueue.main.async { completion(.failure(RelayError.noWiFi)) }
                return
            }
            self.host = address
            self.context = context
            self.token = Self.randomHex(16)
            self.loggedFailure = false
            self.loggedPageSuccess = false
            self.loggedRequest = false
            self.loggedDirect = false
            self.loggedErrorBody = false
            self.pageFetchBroken = false
            self.traceCount = 0

            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.timeoutIntervalForRequest = 30
            config.httpMaximumConnectionsPerHost = 8
            if context.isTor, let torPort = NWEndpoint.Port(rawValue: TorManager.shared.socksPort) {
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: torPort)
                config.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
            }
            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = self.queue
            delegateQueue.maxConcurrentOperationCount = 1
            self.session = URLSession(configuration: config, delegate: nil, delegateQueue: delegateQueue)

            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params)
                self.listener = listener
                var finished = false
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, !finished else { return }
                    switch state {
                    case .ready:
                        finished = true
                        self.port = listener.port?.rawValue ?? 0
                        let url = self.register(upstream)
                        AppLog.shared.log("Cast relay ready on \(self.host):\(self.port)\(context.isTor ? " (via Tor)" : "")", category: "media")
                        DispatchQueue.main.async { completion(.success(url)) }
                    case .failed(let error):
                        finished = true
                        AppLog.shared.log("Cast relay failed to start: \(error)", category: "media")
                        self.stopLocked()
                        DispatchQueue.main.async { completion(.failure(RelayError.couldNotStart)) }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
            } catch {
                self.stopLocked()
                DispatchQueue.main.async { completion(.failure(RelayError.couldNotStart)) }
            }
        }
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    private func stopLocked() {
        guard listener != nil || session != nil else { return }
        listener?.cancel()
        listener = nil
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()
        session?.invalidateAndCancel()
        session = nil
        routes.removeAll()
        routeIDs.removeAll()
        context = nil
        AppLog.shared.log("Cast relay stopped", category: "media")
    }

    // MARK: Routes

    /// A relay address for an upstream URL (same upstream, same address).
    private func register(_ upstream: URL) -> URL {
        let key = upstream.absoluteString
        let id: String
        if let existing = routeIDs[key] {
            id = existing
        } else {
            id = Self.randomHex(8)
            routeIDs[key] = id
            routes[id] = upstream
        }
        // Keep the extension so the player can tell a playlist from a segment.
        var ext = upstream.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 {
            ext = key.lowercased().contains("m3u8") ? "m3u8" : "bin"
        }
        return URL(string: "http://\(host):\(port)/\(token)/\(id).\(ext)")!
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if isComplete || error != nil || buffer.count > 32_768 {
                connection.cancel()
            } else {
                self.readRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return Self.sendStatus(400, on: connection) }
        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else { return Self.sendStatus(405, on: connection) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count == 2, comps[0] == token, let context,
              let id = comps[1].split(separator: ".").first.map(String.init),
              let upstream = routes[id], let session else {
            return Self.sendStatus(404, on: connection)
        }

        trace("TV \(method) \(upstream.lastPathComponent.suffix(28)) range \(headers["range"] ?? "none")")

        // Whole files and playlist/segment requests go through the page.
        // Byte-range requests (large single files) stream over URLSession so
        // the phone never holds a whole movie in memory.
        if headers["range"] == nil, !pageFetchBroken, let fetcher = context.pageFetcher {
            fetcher.fetch(upstream) { [weak self] result in
                self?.queue.async {
                    guard let self else { return }
                    switch result {
                    case .success(let response):
                        self.sendPageResponse(response, for: upstream, isHead: method == "HEAD", on: connection)
                    case .failure(let error):
                        // Cross-origin media usually can't be read by the page
                        // (no CORS headers); don't keep trying for every segment.
                        self.pageFetchBroken = true
                        self.logUpstreamFailure("page fetch failed (\(error.localizedDescription)); trying directly")
                        self.startSessionTask(upstream: upstream, method: method, range: nil, context: context,
                                              session: session, on: connection)
                    }
                }
            }
            return
        }
        startSessionTask(upstream: upstream, method: method, range: headers["range"], context: context,
                         session: session, on: connection)
    }

    private func sendPageResponse(_ response: PageFetcher.Response, for upstream: URL, isHead: Bool,
                                  on connection: NWConnection) {
        if response.status >= 400 {
            logUpstreamFailure("site answered \(response.status) to the page for \(upstream.host ?? "?")")
        } else if !loggedPageSuccess {
            loggedPageSuccess = true
            AppLog.shared.log("Cast relay: fetching through the page works (\(upstream.host ?? "?"))", category: "media")
        }
        var body = response.body
        var type = response.contentType
        let looksLikePlaylist = type.lowercased().contains("mpegurl")
            || upstream.path.lowercased().hasSuffix(".m3u8")
            || body.starts(with: Data("#EXTM3U".utf8))
        if looksLikePlaylist {
            let text = String(decoding: body, as: UTF8.self)
            body = Data(rewritePlaylist(text, base: response.finalURL ?? upstream).utf8)
            type = "application/vnd.apple.mpegurl"
        }
        var head = "HTTP/1.1 \(response.status) OK\r\n"
        if !type.isEmpty { head += "Content-Type: \(type)\r\n" }
        head += "Content-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        if !isHead { out.append(body) }
        connection.send(content: out, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func startSessionTask(upstream: URL, method: String, range: String?, context: Context,
                                  session: URLSession, on connection: NWConnection) {
        var request = URLRequest(url: upstream)
        request.httpMethod = method
        // As close to the browser's own media request as URLSession allows.
        request.setValue(context.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let lang = context.acceptLanguage { request.setValue(lang, forHTTPHeaderField: "Accept-Language") }
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        if let referer = context.referer, let scheme = referer.scheme, let refHost = referer.host {
            let origin = "\(scheme)://\(refHost)" + (referer.port.map { ":\($0)" } ?? "")
            let sameOrigin = refHost.lowercased() == upstream.host?.lowercased() && scheme == upstream.scheme
            let sameSite = DomainUtil.sameSite(refHost, upstream.host ?? "")
            request.setValue(sameOrigin ? "same-origin" : (sameSite ? "same-site" : "cross-site"),
                             forHTTPHeaderField: "Sec-Fetch-Site")
            // Browsers send only the origin as Referer to other sites
            // (strict-origin-when-cross-origin), plus an Origin header.
            request.setValue(sameOrigin ? referer.absoluteString : origin + "/", forHTTPHeaderField: "Referer")
            if !sameOrigin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let cookies = Self.cookies(context.cookies, for: upstream)
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let task = session.dataTask(with: request)
        let relayTask = RelayTask(task: task, connection: connection, isHead: method == "HEAD", relay: self)
        task.delegate = relayTask
        activeTasks[ObjectIdentifier(relayTask)] = relayTask
        connection.stateUpdateHandler = { [weak relayTask] state in
            switch state {
            case .failed, .cancelled: relayTask?.cancel()
            default: break
            }
        }
        task.resume()
    }

    fileprivate func finished(_ task: RelayTask) {
        activeTasks.removeValue(forKey: ObjectIdentifier(task))
    }

    private var traceCount = 0
    /// A short log line per relayed request (first 80 per cast), so a stalled
    /// cast shows exactly which request the TV made last and how it ended.
    fileprivate func trace(_ message: String) {
        queue.async {
            guard self.traceCount < 80 else { return }
            self.traceCount += 1
            AppLog.shared.log("Cast relay: \(message)", category: "media")
        }
    }

    /// One line about the first direct (non-page) answer: status, type, size
    /// and who answered — enough to tell a blocked request from a working one.
    fileprivate func logDirect(_ http: HTTPURLResponse) {
        guard !loggedDirect else { return }
        loggedDirect = true
        let server = http.value(forHTTPHeaderField: "Server") ?? "-"
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? "-"
        let ray = http.value(forHTTPHeaderField: "cf-ray") != nil ? ", Cloudflare" : ""
        AppLog.shared.log("Cast relay: direct fetch answered \(http.statusCode), \(type), \(http.expectedContentLength) bytes, server \(server)\(ray)", category: "media")
    }

    fileprivate func logErrorBody(_ data: Data) {
        queue.async {
            guard !self.loggedErrorBody else { return }
            self.loggedErrorBody = true
            let text = String(decoding: data.prefix(160), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            AppLog.shared.log("Cast relay: error body: \(text)", category: "media")
        }
    }

    fileprivate func logUpstreamFailure(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        AppLog.shared.log("Cast relay: \(message)", category: "media")
    }

    /// Rewrites every URI in an HLS playlist (variants, segments, keys,
    /// subtitle/audio renditions) to go through the relay.
    fileprivate func rewritePlaylist(_ text: String, base: URL) -> String {
        let uriAttribute = try? NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(line)
            } else if trimmed.hasPrefix("#") {
                guard let regex = uriAttribute else { out.append(line); continue }
                let ns = line as NSString
                var result = line
                for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let raw = ns.substring(with: match.range(at: 1))
                    guard let absolute = URL(string: raw, relativeTo: base)?.absoluteURL,
                          ["http", "https"].contains(absolute.scheme?.lowercased() ?? "") else { continue }
                    let relayed = register(absolute).absoluteString
                    result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: relayed)
                }
                out.append(result)
            } else if let absolute = URL(string: trimmed, relativeTo: base)?.absoluteURL,
                      ["http", "https"].contains(absolute.scheme?.lowercased() ?? "") {
                out.append(register(absolute).absoluteString)
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Helpers

    static func sendStatus(_ code: Int, on connection: NWConnection) {
        let head = "HTTP/1.1 \(code) \(HTTPURLResponse.localizedString(forStatusCode: code).capitalized)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func cookies(_ all: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let secure = url.scheme?.lowercased() == "https"
        let path = url.path.isEmpty ? "/" : url.path
        return all.filter { cookie in
            if cookie.isSecure && !secure { return false }
            if let expires = cookie.expiresDate, expires < Date() { return false }
            var domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") { domain.removeFirst() }
            guard host == domain || host.hasSuffix("." + domain) else { return false }
            return path.hasPrefix(cookie.path)
        }
    }

    private static func randomHex(_ bytes: Int) -> String {
        var data = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &data)
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// The phone's Wi-Fi IPv4 address — what the TV connects to.
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (iface.ifa_flags & UInt32(IFF_UP)) != 0, (iface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: name)
            let ifName = String(cString: iface.ifa_name)
            if ifName == "en0" { return ip }
            // Personal Hotspot / other wired-style interfaces.
            if ifName.hasPrefix("en") || ifName.hasPrefix("bridge") { fallback = fallback ?? ip }
        }
        return fallback
    }
}

/// One relayed request: streams the site's response back to the TV, with
/// back-pressure so a slow TV doesn't make the phone buffer the whole video.
private final class RelayTask: NSObject, URLSessionDataDelegate {
    private let task: URLSessionDataTask
    private let connection: NWConnection
    private let isHead: Bool
    private weak var relay: CastRelay?
    private var isPlaylist = false
    private var playlistData = Data()
    private var headersSent = false
    private var pendingBytes = 0
    private var suspended = false
    private var done = false
    private var status = 0
    private var totalSent = 0
    private let label: String

    init(task: URLSessionDataTask, connection: NWConnection, isHead: Bool, relay: CastRelay) {
        self.label = String((task.originalRequest?.url?.lastPathComponent ?? "?").suffix(28))
        self.task = task
        self.connection = connection
        self.isHead = isHead
        self.relay = relay
    }

    func cancel() {
        guard !done else { return }
        done = true
        relay?.trace("TV closed \(label) after \(totalSent) bytes (status \(status))")
        task.cancel()
        connection.cancel()
        relay?.finished(self)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        status = http.statusCode
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let path = (http.url?.path ?? "").lowercased()
        isPlaylist = type.contains("mpegurl") || path.hasSuffix(".m3u8")
        relay?.logDirect(http)
        if http.statusCode >= 400 {
            relay?.logUpstreamFailure("site answered \(http.statusCode) for \(http.url?.host ?? "?")")
        }
        if !isPlaylist {
            var head = "HTTP/1.1 \(http.statusCode) OK\r\n"
            if !type.isEmpty { head += "Content-Type: \(type)\r\n" }
            // URLSession decodes compressed bodies, so the original length
            // only holds when the body wasn't encoded.
            if http.value(forHTTPHeaderField: "Content-Encoding") == nil, http.expectedContentLength >= 0 {
                head += "Content-Length: \(http.expectedContentLength)\r\n"
            }
            if let range = http.value(forHTTPHeaderField: "Content-Range") { head += "Content-Range: \(range)\r\n" }
            head += "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            send(Data(head.utf8))
            headersSent = true
            if isHead { completionHandler(.cancel); finish(); return }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let http = dataTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            relay?.logErrorBody(data)
        }
        if isPlaylist {
            playlistData.append(data)
            return
        }
        send(data)
        if pendingBytes > 4_000_000 && !suspended {
            suspended = true
            task.suspend()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !done else { return }
        if let error, !headersSent {
            relay?.trace("failed \(label): \(error.localizedDescription)")
            relay?.logUpstreamFailure("couldn't reach the site: \(error.localizedDescription)")
            CastRelay.sendStatus(502, on: connection)
            done = true
            relay?.finished(self)
            return
        }
        if isPlaylist, !headersSent {
            let base = task.response?.url ?? task.originalRequest?.url ?? URL(string: "about:blank")!
            let text = String(decoding: playlistData, as: UTF8.self)
            let body = Data((relay?.rewritePlaylist(text, base: base) ?? text).utf8)
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 200
            let head = "HTTP/1.1 \(status) OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            send(Data(head.utf8))
            headersSent = true
            if !isHead { send(body) }
        }
        finish()
    }

    private func send(_ data: Data) {
        totalSent += data.count
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.pendingBytes -= data.count
            if self.suspended && self.pendingBytes < 1_000_000 && !self.done {
                self.suspended = false
                self.task.resume()
            }
        })
    }

    private func finish() {
        guard !done else { return }
        done = true
        relay?.trace("sent \(label): \(status), \(totalSent) bytes")
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [connection] _ in connection.cancel() })
        relay?.finished(self)
    }
}

/// Fetches cast media from inside the page (the frame the video plays in),
/// in Undirect's isolated script world so the page can't interfere. The
/// request is the browser's own, so it passes whatever checks the site
/// applies to its player — and goes through Tor in Tor tabs.
final class PageFetcher {
    struct Response {
        let status: Int
        let contentType: String
        let finalURL: URL?
        let body: Data
    }

    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private weak var webView: WKWebView?
    private let frame: WKFrameInfo?

    init(webView: WKWebView, frame: WKFrameInfo?) {
        self.webView = webView
        self.frame = frame
    }

    private static let js = """
        try {
          const r = await fetch(url, { credentials: 'include', cache: 'no-store' });
          const blob = await r.blob();
          const dataURL = await new Promise(function (resolve, reject) {
            const fr = new FileReader();
            fr.onload = function () { resolve(fr.result); };
            fr.onerror = function () { reject(fr.error); };
            fr.readAsDataURL(blob);
          });
          const comma = dataURL.indexOf(',');
          return { status: r.status, type: r.headers.get('content-type') || '', url: r.url || '',
                   data: comma >= 0 ? dataURL.slice(comma + 1) : '' };
        } catch (e) {
          return { error: String((e && e.message) || e) + ' [' + (new URL(url)).host + ' from ' + location.host + ']' };
        }
        """

    /// Completion runs on the main queue. Times out after 25 s (e.g. if iOS
    /// has paused the page while Undirect is in the background).
    func fetch(_ url: URL, completion: @escaping (Result<Response, Error>) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let webView = self.webView else {
                completion(.failure(FetchError(message: "the page is gone")))
                return
            }
            var finished = false
            let finish: (Result<Response, Error>) -> Void = { result in
                guard !finished else { return }
                finished = true
                completion(result)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                finish(.failure(FetchError(message: "the page didn't respond")))
            }
            webView.callAsyncJavaScript(Self.js, arguments: ["url": url.absoluteString], in: self.frame,
                                        in: .defaultClient) { result in
                switch result {
                case .failure(let error):
                    finish(.failure(error))
                case .success(let value):
                    if let dict = value as? [String: Any], let message = dict["error"] as? String {
                        finish(.failure(FetchError(message: message)))
                        return
                    }
                    guard let dict = value as? [String: Any],
                          let status = (dict["status"] as? NSNumber)?.intValue else {
                        finish(.failure(FetchError(message: "unexpected response")))
                        return
                    }
                    let body = (dict["data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                    finish(.success(Response(status: status,
                                             contentType: (dict["type"] as? String) ?? "",
                                             finalURL: (dict["url"] as? String).flatMap(URL.init(string:)),
                                             body: body)))
                }
            }
        }
    }
}
