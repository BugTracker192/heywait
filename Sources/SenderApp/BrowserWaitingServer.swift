import Foundation
import Network

final class BrowserWaitingServer {
    private let queue = DispatchQueue(label: "dev.screenshare.browser.waiting")
    private var listener: NWListener?
    private var restartWorkItem: DispatchWorkItem?
    private var clients: [ObjectIdentifier: BrowserWaitingClient] = [:]
    private var accessKey = ""
    private var generation: UInt64 = 0

    func start(accessKey: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let normalizedKey = PairingSecret.normalize(accessKey)
            if self.listener != nil, self.accessKey == normalizedKey {
                return
            }
            self.generation &+= 1
            self.stopInternal()
            self.accessKey = normalizedKey
            guard PairingSecret.isValid(self.accessKey),
                  let port = NWEndpoint.Port(rawValue: AppConstants.browserBootstrapPort) else {
                return
            }
            self.beginListening(on: port, generation: self.generation)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.stopInternal()
        }
    }

    private func beginListening(on port: NWEndpoint.Port, generation: UInt64) {
        guard generation == self.generation else { return }
        restartWorkItem?.cancel()
        restartWorkItem = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true

        do {
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self,
                      let listener,
                      listener === self.listener,
                      generation == self.generation else { return }
                switch state {
                case .ready:
                    self.restartWorkItem?.cancel()
                    self.restartWorkItem = nil
                case .waiting:
                    self.scheduleRestart(on: port, generation: generation, after: 1.5)
                case .failed:
                    self.scheduleRestart(on: port, generation: generation, after: 0.5)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            scheduleRestart(on: port, generation: generation, after: 0.5)
        }
    }

    private func scheduleRestart(
        on port: NWEndpoint.Port,
        generation: UInt64,
        after delay: TimeInterval
    ) {
        guard generation == self.generation else { return }
        restartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.beginListening(on: port, generation: generation)
        }
        restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < AppConstants.maximumBrowserClients else {
            connection.cancel()
            return
        }
        let client = BrowserWaitingClient(
            connection: connection,
            queue: queue,
            accessKey: accessKey
        )
        let identifier = ObjectIdentifier(client)
        clients[identifier] = client
        client.onStop = { [weak self, weak client] in
            guard let self, let client else { return }
            self.clients.removeValue(forKey: ObjectIdentifier(client))
        }
        client.start()
    }

    private func stopInternal() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) {
            client.stop()
        }
        clients.removeAll()
    }
}

private final class BrowserWaitingClient {
    var onStop: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let accessKey: String
    private var request = Data()
    private var stopped = false

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

    func stop() {
        guard !stopped else { return }
        stopped = true
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
                self.respond(status: "431 Request Header Fields Too Large", body: "Request too large")
            } else if self.request.range(of: Data("\r\n\r\n".utf8)) != nil {
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
            respond(status: "400 Bad Request", body: "Bad request")
            return
        }
        let pieces = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard pieces.count == 3,
              pieces[0] == "GET",
              let components = URLComponents(string: "http://screenshare.local\(pieces[1])") else {
            respond(status: "400 Bad Request", body: "Bad request")
            return
        }
        if ["/icon.png", "/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"]
            .contains(components.path) {
            respond(
                status: "200 OK",
                contentType: "image/png",
                data: BrowserWebApp.iconPNG,
                cacheControl: "public, max-age=86400"
            )
            return
        }
        guard components.queryItems?.first(where: { $0.name == "k" })?.value == accessKey else {
            respond(status: "403 Forbidden", body: "Invalid or expired Screen Share link")
            return
        }

        switch components.path {
        case "/":
            respond(
                status: "200 OK",
                contentType: "text/html; charset=utf-8",
                body: waitingPage
            )
        case "/manifest.webmanifest":
            respond(
                status: "200 OK",
                contentType: "application/manifest+json",
                data: BrowserWebApp.manifest(accessKey: accessKey)
            )
        default:
            respond(status: "503 Service Unavailable", body: "Broadcast is not ready")
        }
    }

    private var waitingPage: String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
          <meta name="apple-mobile-web-app-capable" content="yes">
          <meta name="apple-mobile-web-app-title" content="Screen Share">
          <meta name="application-name" content="Screen Share">
          <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
          <meta name="theme-color" content="#000000">
          <link rel="apple-touch-icon" sizes="512x512" href="/apple-touch-icon.png">
          <link rel="apple-touch-icon-precomposed" href="/apple-touch-icon-precomposed.png">
          <link rel="manifest" href="/manifest.webmanifest?k=\(accessKey)">
          <title>Screen Share</title>
          <style>
            html,body{width:100%;height:100%;margin:0;background:#000;color:#fff;font:17px -apple-system,sans-serif}
            body{display:flex;align-items:center;justify-content:center;text-align:center}
            p{margin:0 24px;color:#aaa}strong{display:block;color:#fff;font-size:22px;margin-bottom:10px}
          </style>
        </head>
        <body>
          <p><strong>Waiting for Screen Share...</strong>Start the broadcast on the sender. This page will connect automatically.</p>
          <script>
            const key='\(accessKey)';
            const live='http://'+location.hostname+':\(AppConstants.browserViewerPort)';
            function probe(){
              const image=new Image();
              image.onload=()=>location.replace(live+'/?k='+key);
              image.onerror=()=>setTimeout(probe,500);
              image.src=live+'/ready.png?k='+key+'&t='+Date.now();
            }
            probe();
          </script>
        </body>
        </html>
        """
    }

    private func respond(
        status: String,
        contentType: String = "text/plain; charset=utf-8",
        body: String
    ) {
        respond(status: status, contentType: contentType, data: Data(body.utf8))
    }

    private func respond(
        status: String,
        contentType: String,
        data: Data,
        cacheControl: String = "no-store"
    ) {
        var response = BrowserHTTPWire.headerBlock([
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(data.count)",
            "Cache-Control: \(cacheControl)",
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
