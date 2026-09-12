//
//  CallbackListener.swift
//  Norra
//
//  Catches the redirect at the end of Volvo's consent flow.
//
//  Polaris never needed this. It POSTs a password to Polestar's login form
//  and reads the code straight out of the response, so no browser is
//  involved. Volvo's flow is the standards-compliant one: the user consents
//  in their own browser, on Volvo's own page, and Volvo hands the
//  authorization code back by redirecting to a URI the application
//  registered. Something has to be listening at that URI.
//
//  A custom scheme (norra://callback) would avoid the socket, but Volvo's
//  portal only accepts http(s) callbacks, and a loopback address is the
//  documented answer for a native app — it is what RFC 8252 §7.3 recommends,
//  and unlike a custom scheme no other app on the machine can register the
//  same one and race us for the code.
//
//  This is a plain BSD socket rather than NWListener. Network.framework was
//  the first choice and had to be abandoned: NWListener fails to bind with
//  EINVAL ("Invalid argument") in this app, on any port including an
//  ephemeral one, while a bind(2) on the very same port in the very same
//  process succeeds. The failure surfaced as a misleading "port is in use"
//  message during the first real sign-in. Sockets are older and less
//  pleasant, but they work, and the job here is ninety lines of HTTP that
//  serves exactly one request.
//
//  The listener is open for the length of one sign-in and then closed. It
//  binds to 127.0.0.1, so nothing off this machine can reach it.
//

import Foundation
import Darwin
import NorraShared

/// A one-shot HTTP listener on 127.0.0.1 that resolves with the callback URL.
final class CallbackListener {

    /// The port registered with the Volvo application. It has to match the
    /// redirect URI exactly, so it is fixed rather than chosen at runtime —
    /// a free-port scheme would need a new callback registered every launch.
    static let defaultPort: UInt16 = 9631

    private let redirectPath: String
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var finished = false
    private var continuation: CheckedContinuation<URL, Error>?

    enum ListenerError: Error, LocalizedError {
        case cannotBind(UInt16, String)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotBind(let port, let reason):
                return String(format: L("Couldn't listen on port %d: %@"), Int(port), reason)
            case .timedOut:
                return L("Timed out waiting for Volvo to redirect back")
            case .cancelled:
                return L("Sign-in cancelled")
            }
        }
    }

    init(redirectPath: String = "/callback") {
        self.redirectPath = redirectPath
    }

    /// Listen until Volvo redirects back, then hand over the full callback
    /// URL. Gives up after `timeout` so an abandoned sign-in doesn't leave a
    /// socket open for the life of the app.
    func waitForCallback(port: UInt16 = defaultPort,
                         timeout: TimeInterval = 300) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            do {
                let fd = try Self.bind(port: port)
                lock.lock(); socketFD = fd; lock.unlock()
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.acceptLoop(on: fd)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(ListenerError.timedOut))
                }
            } catch {
                finish(.failure(error))
            }
        }
    }

    /// Bind and listen, or explain why not. The distinction matters: a port
    /// genuinely taken by another program is the user's to fix, and anything
    /// else is ours.
    private static func bind(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ListenerError.cannotBind(port, String(cString: strerror(errno)))
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let reason = errno == EADDRINUSE
                ? L("another program is using it")
                : String(cString: strerror(errno))
            close(fd)
            throw ListenerError.cannotBind(port, reason)
        }
        guard listen(fd, 4) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ListenerError.cannotBind(port, reason)
        }
        return fd
    }

    /// Serve requests until one of them is the callback.
    ///
    /// It loops rather than taking the first connection because the browser
    /// asks for /favicon.ico on its way to rendering the page, and treating
    /// that as the callback would resolve the sign-in with no code in it.
    private func acceptLoop(on fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                // accept() returns -1 when the socket is closed under us,
                // which is what cancel() and the timeout do. Nothing to
                // report: whoever closed it has already resolved the wait.
                return
            }
            defer { close(client) }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { continue }

            let request = String(decoding: buffer[0..<count], as: UTF8.self)
            guard let target = Self.requestTarget(in: request) else {
                respond(to: client, status: "400 Bad Request", body: Self.errorPage)
                continue
            }

            guard target.hasPrefix(redirectPath) else {
                respond(to: client, status: "404 Not Found", body: "")
                continue
            }

            guard let url = URL(string: "http://127.0.0.1\(target)") else {
                respond(to: client, status: "400 Bad Request", body: Self.errorPage)
                continue
            }

            let declined = VolvoAPI.queryValue("error", from: url) != nil
            respond(to: client, body: declined ? Self.errorPage : Self.successPage)
            finish(.success(url))
            return
        }
    }

    /// Writes a small HTML page so the browser shows something other than a
    /// connection error.
    private func respond(to client: Int32, status: String = "200 OK", body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        _ = response.withCString { send(client, $0, strlen($0), 0) }
    }

    /// Resolve the wait exactly once, whichever of accept, timeout or cancel
    /// gets here first, and close the socket so the others fall through.
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let fd = socketFD
        socketFD = -1
        lock.unlock()

        if fd >= 0 { close(fd) }
        continuation.resume(with: result)
    }

    func cancel() {
        finish(.failure(ListenerError.cancelled))
    }

    deinit {
        lock.lock()
        let fd = socketFD
        socketFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    /// Pulls the path+query out of a request line: "GET /callback?code=… HTTP/1.1".
    static func requestTarget(in request: String) -> String? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1,
                                       omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    // The pages the browser lands on. Deliberately self-contained: the
    // listener is closed by the time they render, so nothing can be fetched.
    private static let successPage = page(
        title: L("Signed in"),
        heading: L("Signed in to Volvo"),
        detail: L("You can close this tab and return to Norra."))

    private static let errorPage = page(
        title: L("Sign-in failed"),
        heading: L("Sign-in failed"),
        detail: L("Norra didn't receive an authorization code. Try again from Settings."))

    private static func page(title: String, heading: String, detail: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px -apple-system, system-ui, sans-serif; margin: 0;
                 display: grid; place-items: center; height: 100vh; }
          .card { text-align: center; padding: 2rem 3rem; }
          h1 { font-size: 1.25rem; margin: 0 0 .5rem; }
          p { margin: 0; opacity: .7; }
        </style></head>
        <body><div class="card"><h1>\(heading)</h1><p>\(detail)</p></div></body></html>
        """
    }
}
