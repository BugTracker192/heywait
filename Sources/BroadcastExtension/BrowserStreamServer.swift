import Foundation
import Network

private enum BrowserStreamKind {
    case mjpeg
    case h264
    case audio
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

            self.startListener()
        }
    }

    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo

        do {
            guard let port = NWEndpoint.Port(rawValue: AppConstants.browserViewerPort) else {
                fail("The browser viewer port is invalid.")
                return
            }
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self,
                      let listener,
                      listener === self.listener else {
                    return
                }
                switch state {
                case .waiting(let error):
                    self.listenerWaitingFailure?.cancel()
                    let failure = DispatchWorkItem { [weak self, weak listener] in
                        guard let self,
                              let listener,
                              listener === self.listener else {
                            return
                        }
                        self.fail(
                            "Browser viewer port \(AppConstants.browserViewerPort) is waiting: \(error.localizedDescription)"
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
                    self.fail(
                        "Browser viewer port \(AppConstants.browserViewerPort) failed: \(error.localizedDescription)"
                    )
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            fail(
                "Browser viewer port \(AppConstants.browserViewerPort) could not start: \(error.localizedDescription)"
            )
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

    func publish(audio frame: AudioPCMFrame) {
        queue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values where client.streamKind == .audio {
                client.publish(audio: frame)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < AppConstants.maximumBrowserConnections else {
            connection.cancel()
            return
        }

        let client = BrowserHTTPClient(
            connection: connection,
            queue: queue,
            isAuthorized: { [weak self] candidate in
                guard let self else { return false }
                if candidate == self.accessKey {
                    return true
                }
                let current = PairingSecret.normalize(
                    SenderConfigurationStore.shared.load().browserAccessKey
                )
                return candidate == current
            }
        )
        let identifier = ObjectIdentifier(client)
        clients[identifier] = client
        client.onStreamingChange = { [weak self] previous, current in
            guard let self else { return }
            self.clientCountLock.lock()
            if let previous {
                if previous == .h264 {
                    self.streamingClientCount -= 1
                    self.h264ClientCount -= 1
                } else if previous == .mjpeg {
                    self.streamingClientCount -= 1
                    self.mjpegClientCount -= 1
                }
            }
            if let current {
                if current == .h264 {
                    self.streamingClientCount += 1
                    self.h264ClientCount += 1
                } else if current == .mjpeg {
                    self.streamingClientCount += 1
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
    private let isAuthorized: (String) -> Bool
    private var request = Data()
    private var stopped = false
    private var sendPending = false
    private var h264SendQueue: [Data] = []
    private var h264SendPending = false
    private var audioSendQueue: [Data] = []
    private var audioSendPending = false
    private var isAwaitingH264KeyFrame = true
    private(set) var streamKind: BrowserStreamKind?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        isAuthorized: @escaping (String) -> Bool
    ) {
        self.connection = connection
        self.queue = queue
        self.isAuthorized = isAuthorized
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
            // A suspended/background browser cannot drain a real-time video
            // queue. Release it instead of letting a stale tab permanently
            // consume one of the extension's bounded connections.
            queue.async { [weak self] in
                self?.stop()
            }
            return
        }
        h264SendQueue.append(BrowserH264Wire.chunk(payload))
        sendNextH264Chunk()
    }

    func publish(audio frame: AudioPCMFrame) {
        guard streamKind == .audio, !stopped else { return }
        if audioSendQueue.count >= AppConstants.maximumPendingAudioFrames {
            audioSendQueue.removeFirst()
        }
        audioSendQueue.append(BrowserH264Wire.chunk(frame.encoded))
        sendNextAudioChunk()
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

    private func sendNextAudioChunk() {
        guard streamKind == .audio,
              !audioSendPending,
              !audioSendQueue.isEmpty,
              !stopped else {
            return
        }
        audioSendPending = true
        let chunk = audioSendQueue.removeFirst()
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.audioSendPending = false
            if error != nil {
                self.stop()
            } else {
                self.sendNextAudioChunk()
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

    private func monitorDisconnect() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1
        ) { [weak self] _, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if isComplete || error != nil {
                self.stop()
            } else {
                self.monitorDisconnect()
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
              let components = URLComponents(string: "http://screenshare.local\(pieces[1])") else {
            sendStatus(400, reason: "Bad Request")
            return
        }
        if ["/icon.png", "/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"]
            .contains(components.path) {
            sendData(
                BrowserWebApp.iconPNG,
                status: "200 OK",
                contentType: "image/png",
                cacheControl: "public, max-age=86400"
            )
            return
        }
        let suppliedKey = PairingSecret.normalize(
            components.queryItems?.first(where: { $0.name == "k" })?.value ?? ""
        )
        guard PairingSecret.isValid(suppliedKey), isAuthorized(suppliedKey) else {
            sendAuthorizationFailure()
            return
        }

        switch components.path {
        case "/":
            sendHTML(accessKey: suppliedKey)
        case "/stream":
            startMJPEGStream()
        case "/h264":
            startH264Stream()
        case "/audio":
            startAudioStream()
        case "/manifest.webmanifest":
            sendData(
                BrowserWebApp.manifest(accessKey: suppliedKey),
                status: "200 OK",
                contentType: "application/manifest+json"
            )
        case "/health":
            sendData(
                Data(#"{"status":"ok"}"#.utf8),
                status: "200 OK",
                contentType: "application/json"
            )
        case "/ready.png":
            sendData(
                BrowserWebApp.iconPNG,
                status: "200 OK",
                contentType: "image/png"
            )
        default:
            sendStatus(404, reason: "Not Found")
        }
    }

    private func sendHTML(accessKey: String) {
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
          <link rel="apple-touch-icon" sizes="512x512" href="/apple-touch-icon.png">
          <link rel="apple-touch-icon-precomposed" href="/apple-touch-icon-precomposed.png">
          <link rel="manifest" href="/manifest.webmanifest?k=\(accessKey)">
          <title>Screen Share</title>
          <style>
            *{box-sizing:border-box;-webkit-user-select:none;user-select:none}
            html,body{position:fixed;inset:0;width:100%;height:100%;margin:0;background:#000;overflow:hidden;overscroll-behavior:none}
            #stage{position:fixed;inset:0;width:100%;height:100%;background:#000;touch-action:none}
            canvas,img{position:absolute;inset:0;width:100%;height:100%;background:#000}
            img{display:none;object-fit:contain}
            #nativeVideo{position:fixed;left:0;top:0;width:2px;height:2px;opacity:.001;pointer-events:none;background:#000}
            #status{position:fixed;inset:0;display:grid;place-items:center;color:#aaa;font:17px -apple-system,sans-serif;text-align:center;pointer-events:none}
            #sound{display:none}
            #expand{position:fixed;z-index:4;top:max(10px,env(safe-area-inset-top));left:max(10px,env(safe-area-inset-left));width:46px;height:46px;border:0;border-radius:23px;background:#111b;color:#fff;display:grid;place-items:center;-webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px)}
            #expand[hidden],:fullscreen #expand,:-webkit-full-screen #expand{display:none}
            #expand svg{width:23px;height:23px;fill:none;stroke:currentColor;stroke-width:2.2;stroke-linecap:round;stroke-linejoin:round}
            :fullscreen #stage,:fullscreen canvas,:fullscreen img{width:100%;height:100%}
            :-webkit-full-screen #stage,:-webkit-full-screen canvas,:-webkit-full-screen img{width:100%;height:100%}
          </style>
        </head>
        <body>
          <div id="stage"><canvas id="video"></canvas><img id="fallback" alt="Live Screen Share"></div>
          <video id="nativeVideo" autoplay muted playsinline></video>
          <div id="status">Connecting to live screen...</div>
          <div id="sound">Tap once for fullscreen + sound</div>
          <button id="expand" type="button" aria-label="Enter fullscreen">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 3H3v5M16 3h5v5M8 21H3v-5M16 21h5v-5"/></svg>
          </button>
          <script>
            const key='\(accessKey)',stage=document.getElementById('stage');
            const canvas=document.getElementById('video'),ctx=canvas.getContext('2d',{alpha:false,desynchronized:true});
            const fallback=document.getElementById('fallback'),nativeVideo=document.getElementById('nativeVideo'),status=document.getElementById('status'),sound=document.getElementById('sound'),expand=document.getElementById('expand');
            const installedViewer=navigator.standalone===true
              ||matchMedia('(display-mode: fullscreen)').matches
              ||matchMedia('(display-mode: standalone)').matches;
            expand.hidden=installedViewer;
            let decoder=null,decoderSignature='',decoderConfiguration=null,waitingForRecoveryKeyframe=false,latest=null,displayed=null,orientation=1,usingFallback=false;
            let cachedWidth=0,cachedHeight=0,needsRedraw=false,streamGeneration=0,streamsActive=false,h264Abort=null;
            const AudioContextClass=window.AudioContext||window.webkitAudioContext;
            let audioContext=AudioContextClass?new AudioContextClass({latencyHint:'interactive'}):null;
            let audioDestination=audioContext?audioContext.createMediaStreamDestination():null;
            let canvasStream=null,nativeStream=null,nativeFullscreen=false;
            let audioUnlocked=false,audioEnabled=false,audioLoopGeneration=0,audioAt=0,audioAbort=null,audioFramesReceived=0;
            let viewScale=1,pinchStartDistance=0,pinchStartScale=1,lastStageTap=0;

            function resize(){
              const viewport=window.visualViewport;
              const cssWidth=Math.max(1,Math.round(viewport?viewport.width:innerWidth));
              const cssHeight=Math.max(1,Math.round(viewport?viewport.height:innerHeight));
              // The encoded Balanced stream tops out at 960 px. Rendering it
              // into a 2x Retina canvas only creates extra scaling/copy work
              // before canvas.captureStream hands it to the native player.
              const d=Math.min(devicePixelRatio||1,1.25),w=Math.max(1,Math.round(cssWidth*d)),h=Math.max(1,Math.round(cssHeight*d));
              if(canvas.width!==w||canvas.height!==h){
                canvas.width=w;canvas.height=h;needsRedraw=true;
              }
            }
            function showFullscreenHelp(){
              status.textContent='The live video is still starting. Wait one second, then tap fullscreen again.';
              status.style.display='grid';
              setTimeout(()=>{
                status.textContent='Connecting to live screen...';
                status.style.display=cachedWidth?'none':'grid';
              },3200);
            }
            function ensureNativeMedia(){
              if(!canvasStream&&typeof canvas.captureStream==='function'){
                canvasStream=canvas.captureStream(60);
                const tracks=[...canvasStream.getVideoTracks()];
                if(audioDestination)tracks.push(...audioDestination.stream.getAudioTracks());
                nativeStream=new MediaStream(tracks);
                nativeVideo.srcObject=nativeStream;
                nativeVideo.play().catch(()=>{});
              }
              return !!nativeStream;
            }
            function enterImmersive(){
              ensureNativeMedia();
              const nativeRequest=nativeVideo.webkitEnterFullscreen||nativeVideo.webkitEnterFullScreen;
              if(nativeRequest&&nativeVideo.readyState>0){
                try{
                  nativeVideo.muted=false;
                  nativeVideo.volume=1;
                  nativeRequest.call(nativeVideo);
                  return;
                }catch(_){}
              }
              let target=stage,request=target.requestFullscreen||target.webkitRequestFullscreen;
              if(request&&!document.fullscreenElement&&!document.webkitFullscreenElement){
                try{
                  const result=request.call(target);
                  if(result&&typeof result.catch==='function')result.catch(showFullscreenHelp);
                  return;
                }catch(_){}
              }
              showFullscreenHelp();
              resize();
            }
            function fullscreenActive(){
              return !!(document.fullscreenElement||document.webkitFullscreenElement);
            }
            function updateExpandButton(){
              expand.hidden=installedViewer||fullscreenActive();
            }
            function fitScaleForMode(fill){
              if(!cachedWidth||!cachedHeight)return 1;
              const quarter=[5,6,7,8].includes(orientation);
              const width=quarter?cachedHeight:cachedWidth,height=quarter?cachedWidth:cachedHeight;
              const fit=Math.min(canvas.width/width,canvas.height/height);
              const cover=Math.max(canvas.width/width,canvas.height/height);
              return fill?Math.min(3,Math.max(1,cover/fit)):1;
            }
            function toggleFit(){
              viewScale=viewScale>1.01?1:fitScaleForMode(true);
              needsRedraw=true;
            }
            function activateViewer(){
              ensureNativeMedia();
              if(audioContext){
                audioContext.resume().then(()=>{
                  audioUnlocked=true;audioEnabled=true;sound.style.display='none';runAudio(streamGeneration);
                }).catch(()=>{});
                nativeVideo.muted=false;
                nativeVideo.volume=1;
                nativeVideo.play().catch(()=>{});
              }else{
                sound.textContent='Audio is unavailable in this browser';
              }
              enterImmersive();
              updateExpandButton();
            }
            function render(){
              resize();
              if(latest){
                if(displayed)displayed.close();
                displayed=latest;latest=null;
                cachedWidth=displayed.displayWidth||displayed.codedWidth;
                cachedHeight=displayed.displayHeight||displayed.codedHeight;
                needsRedraw=true;status.style.display='none';
              }
              if(needsRedraw&&displayed&&cachedWidth&&cachedHeight){
                const w=cachedWidth,h=cachedHeight;
                const quarter=[5,6,7,8].includes(orientation),dw=quarter?h:w,dh=quarter?w:h;
                const scale=Math.min(canvas.width/dw,canvas.height/dh)*viewScale;
                ctx.setTransform(1,0,0,1,0,0);ctx.fillStyle='#000';ctx.fillRect(0,0,canvas.width,canvas.height);
                ctx.translate(canvas.width/2,canvas.height/2);ctx.scale(scale,scale);
                if(orientation===2)ctx.scale(-1,1);
                else if(orientation===3)ctx.rotate(Math.PI);
                else if(orientation===4)ctx.scale(1,-1);
                else if(orientation===5){ctx.rotate(Math.PI/2);ctx.scale(1,-1)}
                else if(orientation===6)ctx.rotate(Math.PI/2);
                else if(orientation===7){ctx.rotate(-Math.PI/2);ctx.scale(1,-1)}
                else if(orientation===8)ctx.rotate(-Math.PI/2);
                ctx.drawImage(displayed,-w/2,-h/2,w,h);
                ensureNativeMedia();
                needsRedraw=false;
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
              const width=u32(v,0),height=u32(v,4),nextOrientation=u32(v,8);const nal=v[12],slen=u32(v,13);
              const sps=v.slice(17,17+slen),po=17+slen,plen=u32(v,po),pps=v.slice(po+4,po+4+plen);
              const codec='avc1.'+[sps[1],sps[2],sps[3]].map(x=>x.toString(16).padStart(2,'0')).join('');
              if(orientation!==nextOrientation)viewScale=1;
              orientation=(nextOrientation>=1&&nextOrientation<=8)?nextOrientation:1;
              needsRedraw=true;
              const signature=codec+':'+width+'x'+height+':'+Array.from(sps)+':'+Array.from(pps);
              if(decoder&&decoder.state==='configured'&&decoderSignature===signature)return;
              if(decoder&&decoder.state!=='closed')decoder.close();
              decoder=new VideoDecoder({
                output:f=>{if(latest)latest.close();latest=f},
                error:()=>startMJPEG(streamGeneration)
              });
              decoderConfiguration={codec:codec,description:avcConfig(sps,pps,nal),codedWidth:width,codedHeight:height,optimizeForLatency:true,hardwareAcceleration:'prefer-hardware'};
              decoder.configure(decoderConfiguration);
              waitingForRecoveryKeyframe=false;
              decoderSignature=signature;
            }
            function resetDecoderAtKeyframe(){
              if(!decoder||!decoderConfiguration)return false;
              try{
                decoder.reset();
                decoder.configure(decoderConfiguration);
                waitingForRecoveryKeyframe=false;
                return true;
              }catch(_){
                startMJPEG(streamGeneration);
                return false;
              }
            }
            async function startH264(generation){
              const response=await fetch('/h264?k='+key+'&t='+Date.now(),{cache:'no-store',signal:h264Abort.signal});
              if(!response.ok||!response.body)throw new Error('H264 stream unavailable');
              const reader=response.body.getReader();let data=new Uint8Array(0);
              while(true){
                if(generation!==streamGeneration)throw new Error('H264 stream replaced');
                const item=await reader.read();if(item.done)throw new Error('H264 stream ended');
                const joined=new Uint8Array(data.length+item.value.length);joined.set(data);joined.set(item.value,data.length);data=joined;
                let offset=0;
                while(data.length-offset>=13){
                  const view=data.subarray(offset),length=u32(view,9);if(view.length<13+length)break;
                  const type=view[0],timestamp=u64(view,1),payload=view.slice(13,13+length);offset+=13+length;
                  if(type===0)configure(payload);
                  else if(decoder&&decoder.state==='configured'){
                    if(waitingForRecoveryKeyframe&&type!==1)continue;
                    if(type===1&&(waitingForRecoveryKeyframe||decoder.decodeQueueSize>=6)){
                      if(!resetDecoderAtKeyframe())continue;
                    }else if(type!==1&&decoder.decodeQueueSize>=6){
                      // Never discard a random H.264 reference frame and then
                      // feed its dependent deltas to the decoder. Hold the last
                      // displayed frame and resume cleanly at the next keyframe.
                      waitingForRecoveryKeyframe=true;
                      continue;
                    }
                    decoder.decode(new EncodedVideoChunk({type:type===1?'key':'delta',timestamp:timestamp,data:payload}));
                  }
                }
                if(offset)data=data.slice(offset);
              }
            }
            function startMJPEG(generation){
              if(generation!==streamGeneration||usingFallback)return;usingFallback=true;
              if(h264Abort)h264Abort.abort();
              if(decoder&&decoder.state!=='closed')decoder.close();
              decoder=null;decoderConfiguration=null;decoderSignature='';waitingForRecoveryKeyframe=false;
              canvas.style.display='block';fallback.style.display='none';
              status.style.display=cachedWidth?'none':'grid';
              const connect=()=>{fallback.src='/stream?k='+key+'&t='+Date.now()};
              fallback.onload=()=>{
                if(generation!==streamGeneration)return;
                canvas.style.display='none';fallback.style.display='block';status.style.display='none';
              };
              fallback.onerror=()=>{
                if(generation!==streamGeneration)return;
                status.style.display=cachedWidth?'none':'grid';setTimeout(connect,700);
              };
              connect();
            }
            function playAudio(v){
              if(!audioContext||audioContext.state!=='running'||v.length<24||v[0]!==1)return;
              const format=v[1],interleaved=(v[2]&1)===1,channels=v[3],rate=u32(v,4),frames=u32(v,8),length=u32(v,20);
              const bytes=format===2?2:4;
              if(channels<1||channels>2||rate<8000||rate>192000||!frames||length!==frames*channels*bytes||v.length!==24+length)return;
              const output=audioContext.createBuffer(channels,frames,rate);
              const data=new DataView(v.buffer,v.byteOffset+24,length);
              const readSample=o=>format===1?data.getFloat32(o,true):(format===2?data.getInt16(o,true)/32768:data.getInt32(o,true)/2147483648);
              for(let channel=0;channel<channels;channel++){
                const destination=output.getChannelData(channel);
                for(let frame=0;frame<frames;frame++){
                  const sampleIndex=interleaved?frame*channels+channel:channel*frames+frame;
                  destination[frame]=readSample(sampleIndex*bytes);
                }
              }
              const now=audioContext.currentTime;
              if(audioAt<now+.025||audioAt>now+.30)audioAt=now+.055;
              const source=audioContext.createBufferSource();
              source.buffer=output;
              if(audioDestination)source.connect(audioDestination);
              else source.connect(audioContext.destination);
              source.start(audioAt);
              audioFramesReceived++;
              audioAt+=frames/rate;
            }
            async function runAudio(generation){
              if(audioLoopGeneration===generation)return;audioLoopGeneration=generation;
              try{
                const response=await fetch('/audio?k='+key+'&t='+Date.now(),{cache:'no-store',signal:audioAbort.signal});
                if(!response.ok||!response.body)throw new Error('Audio stream unavailable');
                const reader=response.body.getReader();let data=new Uint8Array(0);
                while(audioEnabled&&generation===streamGeneration){
                  const item=await reader.read();if(item.done)throw new Error('Audio stream ended');
                  const joined=new Uint8Array(data.length+item.value.length);joined.set(data);joined.set(item.value,data.length);data=joined;
                  let offset=0;
                  while(data.length-offset>=24){
                    const view=data.subarray(offset),length=u32(view,20);
                    if(length>524288){offset=data.length;break}
                    if(view.length<24+length)break;
                    playAudio(view.slice(0,24+length));offset+=24+length;
                  }
                  if(offset)data=data.slice(offset);
                }
              }catch(_){}
              if(audioLoopGeneration===generation)audioLoopGeneration=0;
              if(audioEnabled&&generation===streamGeneration)setTimeout(()=>runAudio(generation),700);
            }
            stage.addEventListener('click',()=>{
              const now=performance.now();
              if(now-lastStageTap<320)toggleFit();
              lastStageTap=now;
              activateViewer();
            });
            expand.addEventListener('click',event=>{
              event.preventDefault();event.stopPropagation();
              activateViewer();
            });
            const touchDistance=touches=>Math.hypot(
              touches[0].clientX-touches[1].clientX,
              touches[0].clientY-touches[1].clientY
            );
            stage.addEventListener('touchstart',event=>{
              if(event.touches.length!==2)return;
              pinchStartDistance=Math.max(1,touchDistance(event.touches));
              pinchStartScale=viewScale;event.preventDefault();
            },{passive:false});
            stage.addEventListener('touchmove',event=>{
              if(event.touches.length!==2||!pinchStartDistance)return;
              viewScale=Math.min(3,Math.max(1,pinchStartScale*touchDistance(event.touches)/pinchStartDistance));
              needsRedraw=true;event.preventDefault();
            },{passive:false});
            stage.addEventListener('touchend',event=>{
              if(event.touches.length<2)pinchStartDistance=0;
            },{passive:true});
            addEventListener('resize',resize,{passive:true});
            if(window.visualViewport)window.visualViewport.addEventListener('resize',resize,{passive:true});
            if(screen.orientation&&typeof screen.orientation.addEventListener==='function')screen.orientation.addEventListener('change',()=>{needsRedraw=true;resize()});
            document.addEventListener('fullscreenchange',()=>{needsRedraw=true;updateExpandButton();resize()});
            document.addEventListener('webkitfullscreenchange',()=>{needsRedraw=true;updateExpandButton();resize()});
            nativeVideo.addEventListener('webkitbeginfullscreen',()=>{nativeFullscreen=true;expand.hidden=true});
            nativeVideo.addEventListener('webkitendfullscreen',()=>{nativeFullscreen=false;updateExpandButton();needsRedraw=true;resize()});
            const releaseStreams=()=>{
              streamsActive=false;streamGeneration++;
              audioEnabled=false;
              if(h264Abort)h264Abort.abort();
              if(audioAbort)audioAbort.abort();
              fallback.removeAttribute('src');
              if(latest){latest.close();latest=null}
              if(decoder&&decoder.state!=='closed')decoder.close();
              decoder=null;decoderConfiguration=null;decoderSignature='';waitingForRecoveryKeyframe=false;
            };
            const startStreams=()=>{
              if(streamsActive)return;
              streamsActive=true;const generation=++streamGeneration;
              h264Abort=new AbortController();audioAbort=new AbortController();
              usingFallback=false;canvas.style.display='block';fallback.style.display='none';
              if(!cachedWidth)status.style.display='grid';
              if(audioUnlocked&&audioContext){
                audioContext.resume().then(()=>{
                  if(generation!==streamGeneration)return;
                  audioEnabled=true;runAudio(generation);
                }).catch(()=>{});
              }
              if('VideoDecoder' in window&&'EncodedVideoChunk' in window){
                startH264(generation).catch(()=>{
                  if(generation===streamGeneration)startMJPEG(generation);
                });
              }else{
                startMJPEG(generation);
              }
            };
            document.addEventListener('visibilitychange',()=>{
              if(document.hidden)releaseStreams();else startStreams();
            });
            addEventListener('pagehide',releaseStreams);
            if('wakeLock' in navigator)navigator.wakeLock.request('screen').catch(()=>{});
            ensureNativeMedia();
            startStreams();
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
            self.monitorDisconnect()
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
            self.monitorDisconnect()
        })
    }

    private func startAudioStream() {
        let headers = BrowserHTTPWire.headerBlock([
            "HTTP/1.1 200 OK",
            "Content-Type: application/x-screen-share-pcm",
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
            let previous = self.streamKind
            self.streamKind = .audio
            self.onStreamingChange?(previous, .audio)
            self.monitorDisconnect()
        })
    }

    private func sendStatus(_ code: Int, reason: String) {
        sendData(
            Data("\(code) \(reason)".utf8),
            status: "\(code) \(reason)",
            contentType: "text/plain; charset=utf-8"
        )
    }

    private func sendAuthorizationFailure() {
        let page = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <meta name="theme-color" content="#08131d">
          <title>Screen Share link expired</title>
          <style>
            html,body{height:100%;margin:0;background:#08131d;color:#fff;font:17px -apple-system,sans-serif}
            body{display:grid;place-items:center;text-align:center;padding:28px;box-sizing:border-box}
            strong{display:block;font-size:24px;margin-bottom:12px}
            p{max-width:420px;color:#b7c5cf;line-height:1.45}
          </style>
        </head>
        <body><div><strong>Screen Share link expired</strong><p>Return to Screen Share Sender, open Browser mode, save it, and scan the current QR again.</p></div></body>
        </html>
        """
        sendData(
            Data(page.utf8),
            status: "403 Forbidden",
            contentType: "text/html; charset=utf-8"
        )
    }

    private func sendData(
        _ data: Data,
        status: String,
        contentType: String,
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
