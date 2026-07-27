import Foundation
import Network

final class BrowserStreamServer {
    var onFailure: ((String) -> Void)?

    private let accessKey: String
    private let queue = DispatchQueue(label: "dev.screenshare.browser.http", qos: .userInteractive)
    private let clientCountLock = NSLock()
    private var listener: NWListener?
    private var listenerWaitingFailure: DispatchWorkItem?
    private var clients: [ObjectIdentifier: BrowserHTTPClient] = [:]
    private var streamingClientCount = 0
    private var latestJPEG: Data?

    init(accessKey: String) {
        self.accessKey = PairingSecret.normalize(accessKey)
    }

    var hasStreamingClients: Bool {
        clientCountLock.lock()
        defer { clientCountLock.unlock() }
        return streamingClientCount > 0
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal()

            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.includePeerToPeer = true
            parameters.serviceClass = .interactiveVideo

            do {
                guard let port = NWEndpoint.Port(rawValue: AppConstants.browserViewerPort) else {
                    self.fail("The browser viewer port is invalid.")
                    return
                }
                let listener = try NWListener(using: parameters, on: port)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, listener === self.listener else { return }
                    switch state {
                    case .waiting(let error):
                        // The containing app may still be releasing the waiting
                        // page listener. NWListener can recover from this state,
                        // so allow the port handoff a short grace period.
                        self.listenerWaitingFailure?.cancel()
                        let failure = DispatchWorkItem { [weak self, weak listener] in
                            guard let self, let listener, listener === self.listener else { return }
                            self.fail(
                                "Browser viewer is waiting for the local network: \(error.localizedDescription)"
                            )
                        }
                        self.listenerWaitingFailure = failure
                        self.queue.asyncAfter(deadline: .now() + 4, execute: failure)
                    case .ready:
                        self.listenerWaitingFailure?.cancel()
                        self.listenerWaitingFailure = nil
                    case .failed(let error):
                        self.listenerWaitingFailure?.cancel()
                        self.listenerWaitingFailure = nil
                        self.fail("Browser viewer could not start: \(error.localizedDescription)")
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
            } catch {
                self.fail("Browser viewer could not start: \(error.localizedDescription)")
            }
        }
    }

    func publish(jpeg: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.latestJPEG = jpeg
            for client in self.clients.values where client.isStreaming {
                client.publish(jpeg: jpeg)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < AppConstants.maximumBrowserClients else {
            connection.cancel()
            return
        }

        let client = BrowserHTTPClient(
            connection: connection,
            queue: queue,
            accessKey: accessKey
        )
        let identifier = ObjectIdentifier(client)
        clients[identifier] = client
        client.onStreamingChange = { [weak self] isStreaming in
            guard let self else { return }
            self.clientCountLock.lock()
            self.streamingClientCount += isStreaming ? 1 : -1
            self.streamingClientCount = max(0, self.streamingClientCount)
            self.clientCountLock.unlock()
            if isStreaming, let latestJPEG = self.latestJPEG {
                client.publish(jpeg: latestJPEG)
            }
        }
        client.onStop = { [weak self, weak client] in
            guard let self, let client else { return }
            self.clients.removeValue(forKey: ObjectIdentifier(client))
        }
        client.start()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(message)
        }
    }

    private func stopInternal() {
        listenerWaitingFailure?.cancel()
        listenerWaitingFailure = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) {
            client.stop()
        }
        clients.removeAll()
        latestJPEG = nil
        clientCountLock.lock()
        streamingClientCount = 0
        clientCountLock.unlock()
    }
}

private final class BrowserHTTPClient {
    var onStreamingChange: ((Bool) -> Void)?
    var onStop: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let accessKey: String
    private var request = Data()
    private var stopped = false
    private var sendPending = false
    private(set) var isStreaming = false

    init(connection: NWConnection, queue: DispatchQueue, accessKey: String) {
        self.connection = connection
        self.queue = queue
        self.accessKey = accessKey
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest()
            case .failed, .cancelled:
                self?.stop()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func publish(jpeg: Data) {
        guard isStreaming, !sendPending, !stopped else { return }
        sendPending = true

        var part = BrowserHTTPWire.headerBlock([
            "--screen-share",
            "Content-Type: image/jpeg",
            "Content-Length: \(jpeg.count)",
            "Cache-Control: no-store"
        ])
        part.append(jpeg)
        part.append(Data("\r\n".utf8))
        connection.send(content: part, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sendPending = false
            if error != nil {
                self.stop()
            }
        })
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if isStreaming {
            isStreaming = false
            onStreamingChange?(false)
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        onStop?()
    }

    private func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data {
                self.request.append(data)
            }
            if self.request.count > 16 * 1024 {
                self.sendStatus(431, reason: "Request Header Fields Too Large")
                return
            }
            if self.request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.handleRequest()
            } else if isComplete || error != nil {
                self.stop()
            } else {
                self.receiveRequest()
            }
        }
    }

    private func handleRequest() {
        guard let text = String(data: request, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first else {
            sendStatus(400, reason: "Bad Request")
            return
        }
        let pieces = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard pieces.count == 3, pieces[0] == "GET",
              let components = URLComponents(string: "http://screenshare.local\(pieces[1])"),
              components.queryItems?.first(where: { $0.name == "k" })?.value == accessKey else {
            sendStatus(403, reason: "Forbidden")
            return
        }

        switch components.path {
        case "/":
            sendHTML()
        case "/stream":
            startStream()
        case "/manifest.webmanifest":
            sendData(
                BrowserWebApp.manifest(accessKey: accessKey),
                status: "200 OK",
                contentType: "application/manifest+json"
            )
        case "/icon.png", "/apple-touch-icon.png":
            sendData(
                BrowserWebApp.iconPNG,
                status: "200 OK",
                contentType: "image/png"
            )
        case "/health":
            sendData(
                Data(#"{"status":"ok"}"#.utf8),
                status: "200 OK",
                contentType: "application/json"
            )
        default:
            sendStatus(404, reason: "Not Found")
        }
    }

    private func sendHTML() {
        let page = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
          <meta name="apple-mobile-web-app-capable" content="yes">
          <meta name="apple-mobile-web-app-title" content="Screen Share">
          <meta name="application-name" content="Screen Share">
          <meta name="apple-mobile-web-app-status-bar-style" content="black">
          <meta name="theme-color" content="#000000">
          <link rel="apple-touch-icon" sizes="512x512" href="/apple-touch-icon.png?k=\(accessKey)">
          <link rel="manifest" href="/manifest.webmanifest?k=\(accessKey)">
          <title>Screen Share</title>
          <style>
            *{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;background:#000;overflow:hidden}
            body{display:flex;align-items:center;justify-content:center}
            img{width:100vw;height:100vh;object-fit:contain;background:#000}
            #status{position:fixed;color:#aaa;font:17px -apple-system,sans-serif;text-align:center}
          </style>
        </head>
        <body>
          <div id="status">Connecting to live screen...</div>
          <img id="video" alt="Live Screen Share">
          <script>
            const v=document.getElementById('video');
            const s=document.getElementById('status');
            function connect(){ v.src='/stream?k=\(accessKey)&t='+Date.now(); }
            v.onload=()=>{s.style.display='none'};
            v.onerror=()=>{s.style.display='block';setTimeout(connect,700)};
            v.addEventListener('click',()=>document.documentElement.requestFullscreen?.());
            connect();
          </script>
        </body>
        </html>
        """
        sendData(Data(page.utf8), status: "200 OK", contentType: "text/html; charset=utf-8")
    }

    private func startStream() {
        let headers = BrowserHTTPWire.headerBlock([
            "HTTP/1.1 200 OK",
            "Content-Type: multipart/x-mixed-replace; boundary=screen-share",
            "Cache-Control: no-store, no-cache, must-revalidate",
            "Pragma: no-cache",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Connection: keep-alive"
        ])
        connection.send(content: headers, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.stop()
                return
            }
            self.isStreaming = true
            self.onStreamingChange?(true)
        })
    }

    private func sendStatus(_ code: Int, reason: String) {
        sendData(
            Data("\(code) \(reason)".utf8),
            status: "\(code) \(reason)",
            contentType: "text/plain; charset=utf-8"
        )
    }

    private func sendData(_ data: Data, status: String, contentType: String) {
        var response = BrowserHTTPWire.headerBlock([
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(data.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Connection: close"
        ])
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.stop()
        })
    }
}
