import fs from "node:fs";

const source = fs.readFileSync(
  new URL("../Sources/BroadcastExtension/BrowserStreamServer.swift", import.meta.url),
  "utf8",
);
const match = source.match(/<script>\s*([\s\S]*?)\s*<\/script>/);

if (!match) {
  throw new Error("Browser viewer script was not found.");
}

const script = match[1].replaceAll("\\(accessKey)", "TESTACCESSKEY");

// Parse the embedded page as JavaScript so CI catches accidental syntax errors.
new Function(script);

if (script.includes("height=u32(v,4);orientation=u32(v,8)")) {
  throw new Error("Orientation metadata is shadowing the persistent renderer state.");
}
if (!script.includes("orientation=(nextOrientation>=1&&nextOrientation<=8)?nextOrientation:1")) {
  throw new Error("Browser orientation packets are not updating the renderer state.");
}
if (script.includes("screen.orientation.lock(")) {
  throw new Error("The viewer must not force a landscape side and create an orientation feedback loop.");
}
if (!source.includes("#sound{display:none}")) {
  throw new Error("The browser viewer exposes the fullscreen/audio gesture overlay.");
}
if (!script.includes("stage.addEventListener('click',()=>")) {
  throw new Error("The browser viewer does not provide an unobtrusive activation gesture.");
}
if (!source.includes('id="expand"') || !script.includes("expand.addEventListener('click'")) {
  throw new Error("The browser viewer does not provide an explicit fullscreen button.");
}
if (!script.includes("toggleFit()") || !script.includes("pinchStartScale*touchDistance")) {
  throw new Error("The browser viewer does not provide fill and pinch zoom controls.");
}
if (!script.includes("if(document.hidden)releaseStreams();else startStreams()")) {
  throw new Error("A backgrounded browser viewer does not release its stream connections.");
}
if (script.includes("location.reload()")) {
  throw new Error("The browser viewer reloads and loses its orientation state after foregrounding.");
}
if (!script.includes("navigator.standalone===true")) {
  throw new Error("The browser viewer does not identify installed web-app mode.");
}
if (!source.includes('<video id="nativeVideo"') ||
    !script.includes("canvas.captureStream(60)") ||
    !script.includes("nativeVideo.webkitEnterFullscreen")) {
  throw new Error("iPhone fullscreen is not backed by a live native video element.");
}
if (!script.includes("displayed=latest;latest=null") || !script.includes("ctx.drawImage(displayed")) {
  throw new Error("The viewer does not preserve its last frame across canvas resizes.");
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
    !script.includes("audioDestination.stream.getAudioTracks()")) {
  throw new Error("Captured app audio is not attached to the native fullscreen video.");
}
if (!script.includes("Math.min(devicePixelRatio||1,1.25)")) {
  throw new Error("The browser viewer is rendering into an oversized Retina canvas.");
}
if (!script.includes("waitingForRecoveryKeyframe") ||
    !script.includes("resetDecoderAtKeyframe()") ||
    script.includes("decoder.decodeQueueSize<8")) {
  throw new Error("Decoder overload can still drop dependent H.264 frames.");
}
if (!script.includes("decoderSignature===signature") || !script.includes("decoderSignature=signature")) {
  throw new Error("Orientation-only configuration packets unnecessarily reset the video decoder.");
}

console.log("Embedded browser viewer JavaScript is valid.");
