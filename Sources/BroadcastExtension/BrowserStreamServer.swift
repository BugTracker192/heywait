import Foundation
import Network

private enum BrowserStreamKind {
    case mjpeg
    case h264
}

final class BrowserStreamServer {
    var onFailure: ((String) -> Void)?
    var onH264ClientReady: (() -> Void)?

    private let accessKey: String
    private let queue = DispatchQueue(label: "dev.screenshare.browser.http", qos: .userInteractive)
    private let clientCountLock = NSLock()
    private var listener: NWListener?
    private var listenerWaitingFailure: DispatchWorkItem?
    private var clients: [ObjectIdentifier: BrowserHTTPClient] = [:]
    private var streamingClientCount = 0
    private var h264ClientCount = 0
    private var mjpegClientCount = 0
    private var latestJPEG: Data?

    init(accessKey: String) {
        self.accessKey = PairingSecret.normalize(accessKey)
    }

    var hasStreamingClients: Bool {
        clientCountLock.lock()
        defer { clientCountLock.unlock() }
        return streamingClientCount > 0
    }

    var hasH264Clients: Bool {
        clientCountLock.lock()
        defer { clientCountLock.unlock() }
        return h264ClientCount > 0
    }

    var hasMJPEGClients: Bool {
        clientCountLock.lock()
        defer { clientCountLock.unlock() }
        return mjpegClientCount > 0
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
            for client in self.clients.values where client.streamKind == .mjpeg {
                client.publish(jpeg: jpeg)
            }
        }
    }

    func publish(h264 frame: H264Encoder.EncodedFrame) {
        queue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values where client.streamKind == .h264 {
                client.publish(h264: frame)
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
        client.onStreamingChange = { [weak self] previous, current in
            guard let self else { return }
            self.clientCountLock.lock()
            if let previous {
                self.streamingClientCount -= 1
                if previous == .h264 {
                    self.h264ClientCount -= 1
                } else {
                    self.mjpegClientCount -= 1
                }
            }
            if let current {
                self.streamingClientCount += 1
                if current == .h264 {
                    self.h264ClientCount += 1
                } else {
                    self.mjpegClientCount += 1
                }
            }
            self.streamingClientCount = max(0, self.streamingClientCount)
            self.h264ClientCount = max(0, self.h264ClientCount)
            self.mjpegClientCount = max(0, self.mjpegClientCount)
            self.clientCountLock.unlock()
            if current == .mjpeg, let latestJPEG = self.latestJPEG {
                client.publish(jpeg: latestJPEG)
            }
            if current == .h264 {
                self.onH264ClientReady?()
            }
        }
        client.onNeedsH264KeyFrame = { [weak self] in
            self?.onH264ClientReady?()
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
        h264ClientCount = 0
        mjpegClientCount = 0
        clientCountLock.unlock()
    }
}

private final class BrowserHTTPClient {
    var onStreamingChange: ((BrowserStreamKind?, BrowserStreamKind?) -> Void)?
    var onNeedsH264KeyFrame: (() -> Void)?
    var onStop: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let accessKey: String
    private var request = Data()
    private var stopped = false
    private var sendPending = false
    private var h264SendQueue: [Data] = []
    private var h264SendPending = false
    private var isAwaitingH264KeyFrame = true
    private(set) var streamKind: BrowserStreamKind?

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
        guard streamKind == .mjpeg, !sendPending, !stopped else { return }
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

    func publish(h264 frame: H264Encoder.EncodedFrame) {
        guard streamKind == .h264, !stopped else { return }

        var payload = Data()
        if let configuration = frame.configuration {
            payload.append(BrowserH264Wire.configurationPacket(configuration))
            isAwaitingH264KeyFrame = false
        } else if isAwaitingH264KeyFrame {
            return
        }
        payload.append(BrowserH264Wire.framePacket(frame))

        guard h264SendQueue.count < 10 else {
            h264SendQueue.removeAll(keepingCapacity: true)
            isAwaitingH264KeyFrame = true
            onNeedsH264KeyFrame?()
            return
        }
        h264SendQueue.append(BrowserH264Wire.chunk(payload))
        sendNextH264Chunk()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let streamKind {
            self.streamKind = nil
            onStreamingChange?(streamKind, nil)
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        onStop?()
    }

    private func sendNextH264Chunk() {
        guard streamKind == .h264,
              !h264SendPending,
              !h264SendQueue.isEmpty,
              !stopped else {
            return
        }
        h264SendPending = true
        let chunk = h264SendQueue.removeFirst()
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.h264SendPending = false
            if error != nil {
                self.stop()
            } else {
                self.sendNextH264Chunk()
            }
        })
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
            startMJPEGStream()
        case "/h264":
            startH264Stream()
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
          <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
          <meta name="apple-mobile-web-app-capable" content="yes">
          <meta name="apple-mobile-web-app-title" content="Screen Share">
          <meta name="application-name" content="Screen Share">
          <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
          <meta name="theme-color" content="#000000">
          <link rel="apple-touch-icon" sizes="512x512" href="/apple-touch-icon.png?k=\(accessKey)">
          <link rel="manifest" href="/manifest.webmanifest?k=\(accessKey)">
          <title>Screen Share</title>
          <style>
            *{box-sizing:border-box;-webkit-user-select:none;user-select:none}
            html,body{position:fixed;inset:0;width:100%;height:100%;margin:0;background:#000;overflow:hidden;overscroll-behavior:none}
            #stage{position:fixed;inset:0;background:#000;touch-action:none}
            canvas,img{position:absolute;inset:0;width:100dvw;height:100dvh;background:#000}
            img{display:none;object-fit:contain}
            #status{position:fixed;inset:0;display:grid;place-items:center;color:#aaa;font:17px -apple-system,sans-serif;text-align:center;pointer-events:none}
          </style>
        </head>
        <body>
          <div id="stage"><canvas id="video"></canvas><img id="fallback" alt="Live Screen Share"></div>
          <div id="status">Connecting to live screen...</div>
          <script>
            const key='\(accessKey)',stage=document.getElementById('stage');
            const canvas=document.getElementById('video'),ctx=canvas.getContext('2d',{alpha:false});
            const fallback=document.getElementById('fallback'),status=document.getElementById('status');
            let decoder=null,latest=null,orientation=1,usingFallback=false,h264Abort=new AbortController();

            function resize(){
              const d=Math.min(devicePixelRatio||1,2),w=Math.max(1,Math.round(innerWidth*d)),h=Math.max(1,Math.round(innerHeight*d));
              if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h}
            }
            function render(){
              resize();
              if(latest){
                const w=latest.displayWidth||latest.codedWidth,h=latest.displayHeight||latest.codedHeight;
                const quarter=[5,6,7,8].includes(orientation),dw=quarter?h:w,dh=quarter?w:h;
                const scale=Math.min(canvas.width/dw,canvas.height/dh);
                ctx.setTransform(1,0,0,1,0,0);ctx.fillStyle='#000';ctx.fillRect(0,0,canvas.width,canvas.height);
                ctx.translate(canvas.width/2,canvas.height/2);ctx.scale(scale,scale);
                if(orientation===2)ctx.scale(-1,1);
                else if(orientation===3)ctx.rotate(Math.PI);
                else if(orientation===4)ctx.scale(1,-1);
                else if(orientation===5){ctx.rotate(Math.PI/2);ctx.scale(1,-1)}
                else if(orientation===6)ctx.rotate(Math.PI/2);
                else if(orientation===7){ctx.rotate(-Math.PI/2);ctx.scale(1,-1)}
                else if(orientation===8)ctx.rotate(-Math.PI/2);
                ctx.drawImage(latest,-w/2,-h/2,w,h);
                latest.close();latest=null;status.style.display='none';
              }
              requestAnimationFrame(render);
            }
            requestAnimationFrame(render);

            function u32(v,o){return new DataView(v.buffer,v.byteOffset,v.byteLength).getUint32(o)}
            function u64(v,o){const d=new DataView(v.buffer,v.byteOffset,v.byteLength);return d.getUint32(o)*4294967296+d.getUint32(o+4)}
            function avcConfig(sps,pps,nal){
              const out=new Uint8Array(11+sps.length+pps.length),d=new DataView(out.buffer);let p=0;
              out[p++]=1;out[p++]=sps[1];out[p++]=sps[2];out[p++]=sps[3];out[p++]=0xfc|((nal-1)&3);out[p++]=0xe1;
              d.setUint16(p,sps.length);p+=2;out.set(sps,p);p+=sps.length;out[p++]=1;d.setUint16(p,pps.length);p+=2;out.set(pps,p);
              return out;
            }
            function configure(v){
              const width=u32(v,0),height=u32(v,4);orientation=u32(v,8);const nal=v[12],slen=u32(v,13);
              const sps=v.slice(17,17+slen),po=17+slen,plen=u32(v,po),pps=v.slice(po+4,po+4+plen);
              const codec='avc1.'+[sps[1],sps[2],sps[3]].map(x=>x.toString(16).padStart(2,'0')).join('');
              if(decoder)decoder.close();
              decoder=new VideoDecoder({
                output:f=>{if(latest)latest.close();latest=f},
                error:()=>startMJPEG()
              });
              decoder.configure({codec:codec,description:avcConfig(sps,pps,nal),codedWidth:width,codedHeight:height,optimizeForLatency:true,hardwareAcceleration:'prefer-hardware'});
            }
            async function startH264(){
              const response=await fetch('/h264?k='+key+'&t='+Date.now(),{cache:'no-store',signal:h264Abort.signal});
              if(!response.ok||!response.body)throw new Error('H264 stream unavailable');
              const reader=response.body.getReader();let data=new Uint8Array(0);
              while(true){
                const item=await reader.read();if(item.done)throw new Error('H264 stream ended');
                const joined=new Uint8Array(data.length+item.value.length);joined.set(data);joined.set(item.value,data.length);data=joined;
                let offset=0;
                while(data.length-offset>=13){
                  const view=data.subarray(offset),length=u32(view,9);if(view.length<13+length)break;
                  const type=view[0],timestamp=u64(view,1),payload=view.slice(13,13+length);offset+=13+length;
                  if(type===0)configure(payload);
                  else if(decoder&&decoder.state==='configured'&&decoder.decodeQueueSize<8){
                    decoder.decode(new EncodedVideoChunk({type:type===1?'key':'delta',timestamp:timestamp,data:payload}));
                  }
                }
                if(offset)data=data.slice(offset);
              }
            }
            function startMJPEG(){
              if(usingFallback)return;usingFallback=true;
              h264Abort.abort();
              if(decoder&&decoder.state!=='closed')decoder.close();
              canvas.style.display='none';fallback.style.display='block';status.style.display='grid';
              const connect=()=>{fallback.src='/stream?k='+key+'&t='+Date.now()};
              fallback.onload=()=>{status.style.display='none'};
              fallback.onerror=()=>{status.style.display='grid';setTimeout(connect,700)};
              connect();
            }
            stage.addEventListener('click',()=>{
              const request=stage.requestFullscreen||stage.webkitRequestFullscreen;
              if(request)Promise.resolve(request.call(stage)).catch(()=>{});
            });
            if('wakeLock' in navigator)navigator.wakeLock.request('screen').catch(()=>{});
            if('VideoDecoder' in window&&'EncodedVideoChunk' in window)startH264().catch(()=>startMJPEG());else startMJPEG();
          </script>
        </body>
        </html>
        """
        sendData(Data(page.utf8), status: "200 OK", contentType: "text/html; charset=utf-8")
    }

    private func startMJPEGStream() {
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
            let previous = self.streamKind
            self.streamKind = .mjpeg
            self.onStreamingChange?(previous, .mjpeg)
        })
    }

    private func startH264Stream() {
        let headers = BrowserHTTPWire.headerBlock([
            "HTTP/1.1 200 OK",
            "Content-Type: application/x-screen-share-h264",
            "Transfer-Encoding: chunked",
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
            self.isAwaitingH264KeyFrame = true
            let previous = self.streamKind
            self.streamKind = .h264
            self.onStreamingChange?(previous, .h264)
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
