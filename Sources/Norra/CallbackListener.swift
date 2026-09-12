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
//  The listener is open for the length of one sign-in and then closed. It
//  binds to 127.0.0.1, so nothing off this machine can reach it.
//

import Foundation
import Network
import NorraShared

/// A one-shot HTTP listener on 127.0.0.1 that resolves with the first
/// request line it receives.
final class CallbackListener {

    /// The port registered with the Volvo application. It has to match the
    /// redirect URI exactly, so it is fixed rather than chosen at runtime —
    /// a free-port scheme would need a new callback registered every launch.
    static let defaultPort: UInt16 = 9631

    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var connections: [NWConnection] = []
    private let redirectPath: String

    enum ListenerError: Error, LocalizedError {
        case cannotBind(UInt16)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotBind(let port):
                return String(format: L("Port %d is in use — close whatever is using it and try again"), Int(port))
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
    /// URL. Cancels itself after `timeout` so an abandoned sign-in doesn't
    /// leave a socket open for the life of the app.
    func waitForCallback(port: UInt16 = defaultPort,
                         timeout: TimeInterval = 300) async throws -> URL {
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                try start(on: port)
            } catch {
                self.continuation = nil
                continuation.resume(throwing: ListenerError.cannotBind(port))
            }
        }
        return url
    }

    private func start(on port: UInt16) throws {
        let parameters = NWParameters.tcp
        // Loopback only. Without this the socket would accept connections
        // from the local network, which has no business seeing an OAuth code.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: .init(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .init(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.finish(.failure(ListenerError.cannotBind(port)))
            }
        }
        listener.start(queue: .main)

        // Nothing arrives if the user closes the browser tab; don't hold the
        // port forever waiting for a redirect that isn't coming.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.finish(.failure(ListenerError.timedOut))
        }
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data, let request = String(data: data, encoding: .utf8),
                  let target = Self.requestTarget(in: request) else {
                self.respond(on: connection, body: Self.errorPage, then: nil)
                return
            }

            // The browser asks for /favicon.ico on its way to rendering the
            // page. Answering that as if it were the callback would resolve
            // the sign-in with no code in it.
            guard target.hasPrefix(self.redirectPath) else {
                self.respond(on: connection, status: "404 Not Found", body: "", then: nil)
                return
            }

            guard let url = URL(string: "http://127.0.0.1\(target)") else {
                self.respond(on: connection, body: Self.errorPage, then: nil)
                return
            }

            let failed = VolvoAPI.queryValue("error", from: url) != nil
            self.respond(on: connection,
                         body: failed ? Self.errorPage : Self.successPage) {
                self.finish(.success(url))
            }
        }
    }

    /// Writes a small HTML page so the browser shows something other than a
    /// connection error, then closes.
    private func respond(on connection: NWConnection,
                         status: String = "200 OK",
                         body: String,
                         then completion: (() -> Void)?) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        stop()
        continuation.resume(with: result)
    }

    func cancel() {
        finish(.failure(ListenerError.cancelled))
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    deinit {
        listener?.cancel()
        connections.forEach { $0.cancel() }
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
