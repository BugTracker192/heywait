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
if (!script.includes("screen.orientation.lock(remoteLandscape()?'landscape':'portrait')")) {
  throw new Error("Browser fullscreen does not synchronize with the sender orientation.");
}
if (!script.includes("if(document.hidden)releaseStreams();else location.reload()")) {
  throw new Error("A backgrounded browser viewer does not release its stream connections.");
}

console.log("Embedded browser viewer JavaScript is valid.");
