import fs from "node:fs";

const source = fs.readFileSync(
  new URL("../Sources/BroadcastExtension/BrowserStreamServer.swift", import.meta.url),
  "utf8",
);
const sampleHandler = fs.readFileSync(
  new URL("../Sources/BroadcastExtension/SampleHandler.swift", import.meta.url),
  "utf8",
);
const match = source.match(/<script>\s*([\s\S]*?)\s*<\/script>/);

if (!match) {
  throw new Error("Browser viewer script was not found.");
}

const script = match[1]
  .replaceAll("\\(accessKey)", "TESTACCESSKEY")
  .replaceAll("\\(framingMode)", "fill");

// Parse the embedded page as JavaScript so CI catches accidental syntax errors.
new Function(script);

if (script.includes("height=u32(v,4);orientation=u32(v,8)")) {
  throw new Error("Orientation metadata is shadowing the persistent renderer state.");
}
if (!script.includes("encodedOrientation=normalizedOrientation") ||
    !script.includes("decodedOrientations.push({timestamp:timestamp,orientation:encodedOrientation})") ||
    !script.includes("orientation=nextOrientation")) {
  throw new Error("Browser orientation metadata is not committed with its decoded frame.");
}
if (!script.includes("function syncSourceOrientation()") ||
    !script.includes("screen.orientation.lock(target)") ||
    !script.includes("const target=landscape?'landscape':'portrait'") ||
    !script.includes("if(nativeFullscreen||!(fullscreenActive()||installedViewer))return")) {
  throw new Error("Fullscreen does not follow the sender's frame orientation when Safari supports locking.");
}
if (script.includes("addEventListener('change',syncSourceOrientation")) {
  throw new Error("Receiver rotation events must not feed back into the sender-driven orientation lock.");
}
if (!source.includes("#sound{display:none}")) {
  throw new Error("The browser viewer exposes the fullscreen/audio gesture overlay.");
}
if (!script.includes("stage.addEventListener('click',event=>") ||
    !script.includes("if(fullscreenLocked||fullscreenActive()){") ||
    !script.includes("event.preventDefault();event.stopPropagation();return")) {
  throw new Error("The browser viewer does not provide an unobtrusive activation gesture.");
}
if (!source.includes('id="expand"') || !script.includes("expand.addEventListener('click'")) {
  throw new Error("The browser viewer does not provide an explicit fullscreen button.");
}
if (!source.includes('<div id="stage">\n            <canvas id="video"></canvas><img id="fallback" alt="Live Screen Share">\n            <div id="lockIndicator"') ||
    !script.includes("lockHideTimer=setTimeout(hideLockIndicator,2400)") ||
    !script.includes("cornerHoldTimer=setTimeout(exitImmersive,1400)") ||
    !script.includes("fullscreenLocked=fullscreenActive()") ||
    !script.includes("stage.addEventListener('touchcancel'")) {
  throw new Error("Fullscreen does not auto-lock cleanly with a deliberate corner-hold escape.");
}
if (!script.includes("pinchStartScale*touchDistance")) {
  throw new Error("The browser viewer does not provide pinch zoom controls.");
}
if (!script.includes("const framingMode='fill'") ||
    !script.includes("framingMode==='stretch'?canvas.width/dw:uniform") ||
    !script.includes("framingMode==='fill'?fill:fit") ||
    script.includes("fitMarker")) {
  throw new Error("The browser viewer does not apply the persisted Fit/Fill/Stretch policy.");
}
if (!script.includes("if(!nativeFullscreen)releaseStreams()")) {
  throw new Error("Safari backgrounding does not restart a suspended DOM-fullscreen stream.");
}
if (!script.includes("const restartStreams=(allowHidden=false,force=false)=>") ||
    !script.includes("if(document.hidden&&!allowHidden)return false") ||
    !script.includes("if(!force&&now-lastRestartAt<500)return false") ||
    !script.includes("function recoverForeground(allowHidden=false,force=false,refreshNative=nativeFullscreen,coalesce=true)") ||
    !script.includes("coalesce&&streamsActive&&now-lastForegroundRecoveryAt<800") ||
    !script.includes("addEventListener('pageshow'") ||
    !script.includes("addEventListener('online',()=>{recoverForeground(nativeFullscreen,true,nativeFullscreen)")) {
  throw new Error("A resumed or restored browser page does not force a fresh live connection.");
}
if (!script.includes("function rebuildLiveCanvas(force=false)") ||
    !script.includes("if(nativeFullscreen&&!force){") ||
    !script.includes("needsRedraw=true;resize();drawDisplayed();return") ||
    !script.includes("const previousCanvas=canvas,previousFallback=fallback") ||
    !script.includes("drawDisplayed();\n              previousFallback.onload=null") ||
    !script.includes("previousCanvas.replaceWith(replacement)") ||
    !script.includes("previousFallback.replaceWith(replacementFallback)")) {
  throw new Error("A resumed fullscreen viewer can replace WebKit's active compositor surface.");
}
if (script.includes("if(fullscreenActive()){\n                needsRedraw=true;resize();drawDisplayed();return")) {
  throw new Error("DOM fullscreen still preserves WebKit's stale child canvas after foregrounding.");
}
if (!script.includes("sessionStorage.getItem(resumeMarker)") ||
    !script.includes("(!cachedWidth&&!quietReconnect)?'grid':'none'")) {
  throw new Error("Background recovery can expose the reconnect text over a blank frame.");
}
if (script.includes("location.reload()")) {
  throw new Error("The browser viewer reloads and loses its orientation state after foregrounding.");
}
if (!script.includes("function hardRecoverPage()") ||
    !script.includes("location.replace(location.href)") ||
    !script.includes("Date.now()-lastReload<15000")) {
  throw new Error("The browser viewer lacks a bounded reload-equivalent recovery for a poisoned WebKit pipeline.");
}
if (!script.includes("navigator.standalone===true")) {
  throw new Error("The browser viewer does not identify installed web-app mode.");
}
if (!source.includes('<video id="nativeVideo"') ||
    !script.includes("canvas.captureStream(60)") ||
    !script.includes("nativeVideo.webkitEnterFullscreen")) {
  throw new Error("Legacy iPhone fullscreen is not backed by a live native video element.");
}
if (!script.includes("function resumeNativePlayback(resetAttempts=false,allowHidden=false)") ||
    !script.includes("const delays=[0,120,350,800,1600,3000]") ||
    !script.includes("(!allowHidden&&document.hidden)") ||
    !script.includes("if(nativeVideo.srcObject!==nativeStream)nativeVideo.srcObject=nativeStream") ||
    !script.includes("try{result=nativeVideo.play()}catch(_)") ||
    !script.includes("nativeVideo.addEventListener('pause'") ||
    !script.includes("addEventListener('pageshow'") ||
    !script.includes("recoverForeground(nativeFullscreen,true,nativeFullscreen)")) {
  throw new Error("Native Safari fullscreen does not resume autoplay after foregrounding.");
}
if (!script.includes("function rebuildNativeMedia(replaceCanvas=false)") ||
    !script.includes("oldCanvasStream.getVideoTracks()") ||
    !script.includes("nativeVideo.srcObject=freshNativeStream") ||
    !script.includes("nativeMediaRebuilding=false;") ||
    !script.includes("}finally{") ||
    !script.includes("rebuildNativeMedia(true)") ||
    !script.includes("function watchForegroundRecovery(refreshNative)")) {
  throw new Error("Safari recovery does not replace a poisoned canvas-capture MediaStream graph.");
}
const watchdog = script.slice(
  script.indexOf("function watchForegroundRecovery(refreshNative)"),
  script.indexOf("function recoverForeground(", script.indexOf("function watchForegroundRecovery(refreshNative)")),
);
if (watchdog.includes("rebuildNativeMedia(")) {
  throw new Error("Native media is rebuilt while AVKit fullscreen may still own the source.");
}
if (!script.includes("function handleH264Failure(generation)") ||
    !script.includes("restartStreams(nativeFullscreen,true)") ||
    !script.includes("h264RetryCount<3||nativeFullscreen") ||
    !script.includes("fallbackFrameSequence++") ||
    !script.includes("generation===streamGeneration&&usingFallback") ||
    !script.includes("if(usingFallback&&'VideoDecoder' in window") ||
    !sampleHandler.includes("if browserServer.hasMJPEGClients, let browserEncoder")) {
  throw new Error("H.264 failure can still strand native fullscreen on a stale canvas.");
}
if (!script.includes("function cancelForegroundRecovery()") ||
    !script.includes("cancelForegroundRecovery();\n                lastForegroundRecoveryAt=-10000;\n                backgrounded=true") ||
    !script.includes("function exitBrokenNativeFullscreen()") ||
    !script.includes("nativeFullscreenEpoch===epoch") ||
    !script.includes("nativeCounterTrusted") ||
    !script.includes("nativePresentedFrames()")) {
  throw new Error("Foreground recovery lacks cancellation or a safe native-fullscreen escape path.");
}
const stageFullscreenIndex = script.indexOf("stageFullscreenRequest.call(stage)");
const legacyFullscreenIndex = script.indexOf("nativeRequest.call(nativeVideo)");
if (stageFullscreenIndex < 0 ||
    legacyFullscreenIndex < 0 ||
    stageFullscreenIndex >= legacyFullscreenIndex) {
  throw new Error("The live stage must be preferred over the freeze-prone legacy video fullscreen path.");
}
if (!script.includes("if(!stageFullscreenRequest){") ||
    !script.includes("nativeTrack.requestFrame()")) {
  throw new Error("Canvas capture is not isolated to the legacy fullscreen fallback.");
}
if (!script.includes("output:presentFrame") ||
    !script.includes("function presentFrame(frame)") ||
    !script.includes("ctx.drawImage(displayed")) {
  throw new Error("Decoded frames do not directly update the live fullscreen canvas.");
}
if (script.includes("frameCache")) {
  throw new Error("The viewer is still copying every decoded frame through an extra cache canvas.");
}
if (!script.includes("orientation===6)ctx.rotate(Math.PI/2)") ||
    !script.includes("orientation===8)ctx.rotate(-Math.PI/2)")) {
  throw new Error("ReplayKit EXIF landscape rotations are not mapped correctly.");
}
if (!script.includes("audioContext.createMediaStreamDestination()") ||
    !script.includes("source.connect(audioDestination)") ||
    !script.includes("audioDestination.stream.getAudioTracks()") ||
    !script.includes("if(stageFullscreenRequest||!audioDestination)source.connect(audioContext.destination)")) {
  throw new Error("Captured app audio is not routed through both fullscreen playback paths.");
}
if (!script.includes("function silenceBackgroundAudio()") ||
    !script.includes("if(audioAbort){audioAbort.abort();audioAbort=null}") ||
    !script.includes("nativeVideo.muted=true") ||
    !script.includes("audioContext.suspend()") ||
    !script.includes("function restoreForegroundAudio()") ||
    !script.includes("nativeVideo.muted=!audioUnlocked") ||
    !script.includes("restoreForegroundAudio();")) {
  throw new Error("Receiver audio is not muted in the background and restored on foreground return.");
}
if (!script.includes("Math.min(devicePixelRatio||1,1.25)")) {
  throw new Error("The browser viewer is rendering into an oversized Retina canvas.");
}
if (script.includes("waitingForRecoveryKeyframe") ||
    script.includes("resetDecoderAtKeyframe()") ||
    script.includes("decoder.decodeQueueSize")) {
  throw new Error("The browser decoder still contains freeze-inducing queue resets.");
}
if (!source.includes("canEncodeNextH264Frame") ||
    !source.includes("return h264ClientCount > h264BackpressuredClients.count") ||
    !source.includes("if h264Backpressured, frame.configuration == nil") ||
    !source.includes("outstanding >= 2")) {
  throw new Error("Browser backpressure is not applied before H.264 encoding.");
}
if (!script.includes("if(!freshFrameReady){showFullscreenHelp();return}") ||
    source.includes("            ensureNativeMedia();\n            startStreams();")) {
  throw new Error("Native fullscreen can still start from a stale canvas frame.");
}
if (!script.includes("decoderSignature===signature") || !script.includes("decoderSignature=signature")) {
  throw new Error("Orientation-only configuration packets unnecessarily reset the video decoder.");
}

console.log("Embedded browser viewer JavaScript is valid.");
