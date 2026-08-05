import fs from "node:fs";

const source = fs.readFileSync(
  new URL("../Sources/BroadcastExtension/BrowserStreamServer.swift", import.meta.url),
  "utf8",
);
const match = source.match(/<script>\s*([\s\S]*?)\s*<\/script>/);
if (!match) throw new Error("Browser viewer script was not found.");

const script = match[1]
  .replaceAll("\\(accessKey)", "TESTACCESSKEY")
  .replaceAll("\\(framingMode)", "fill");

class FakeElement {
  constructor(id = "") {
    this.id = id;
    this.style = {};
    this.hidden = false;
    this.listeners = new Map();
    this.classList = { add() {}, remove() {}, contains() { return false; } };
    this.width = 1;
    this.height = 1;
    this.readyState = 4;
    this.paused = false;
    this.muted = true;
    this.volume = 1;
    this.currentTime = 1;
    this.srcObject = null;
    this.naturalWidth = 0;
    this.naturalHeight = 0;
    this.complete = false;
  }

  addEventListener(name, callback) {
    const listeners = this.listeners.get(name) ?? [];
    listeners.push(callback);
    this.listeners.set(name, listeners);
  }

  dispatch(name, event = {}) {
    for (const callback of this.listeners.get(name) ?? []) callback(event);
  }

  getContext() {
    return {
      setTransform() {}, fillRect() {}, translate() {}, scale() {},
      rotate() {}, drawImage() {}, fillStyle: "",
    };
  }

  captureStream() {
    return { getVideoTracks: () => [{ stop() {}, requestFrame() {} }] };
  }

  play() {
    this.paused = false;
    return Promise.resolve();
  }

  replaceWith() {}
  removeAttribute() {}
  getVideoPlaybackQuality() { return { totalVideoFrames: 10 }; }
}

const elements = Object.fromEntries(
  ["stage", "video", "fallback", "nativeVideo", "status", "sound", "expand", "lockIndicator"]
    .map((id) => [id, new FakeElement(id)]),
);
const documentListeners = new Map();
const windowListeners = new Map();
const addListener = (map, name, callback) => {
  const listeners = map.get(name) ?? [];
  listeners.push(callback);
  map.set(name, listeners);
};

globalThis.document = {
  hidden: false,
  fullscreenElement: null,
  webkitFullscreenElement: null,
  getElementById: (id) => elements[id],
  createElement: () => new FakeElement(),
  addEventListener: (name, callback) => addListener(documentListeners, name, callback),
};
globalThis.window = globalThis;
globalThis.addEventListener = (name, callback) => addListener(windowListeners, name, callback);
globalThis.innerWidth = 390;
globalThis.innerHeight = 844;
globalThis.devicePixelRatio = 2;
globalThis.visualViewport = null;
globalThis.matchMedia = () => ({ matches: false });
Object.defineProperty(globalThis, "navigator", {
  value: { standalone: false }, configurable: true,
});
globalThis.screen = { orientation: { addEventListener() {} } };
globalThis.sessionStorage = { getItem() { return null; }, setItem() {} };
globalThis.requestAnimationFrame = () => 0;
globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
// Capture intervals instead of scheduling them: a real timer would keep Node
// alive forever, and holding the callback lets the audio reconciler be driven
// deterministically below.
const intervals = [];
globalThis.setInterval = (callback) => {
  intervals.push(callback);
  return intervals.length;
};
globalThis.clearInterval = () => {};
const runIntervals = () => {
  for (const callback of intervals) callback();
};

// Minimal Web Audio surface. `state` is writable so an interruption by another
// app (a voice call, Discord) can be simulated. Instances self-register because
// the viewer keeps its context in a closure, not on a global.
const audioContexts = [];
class FakeAudioContext {
  constructor() {
    this.state = "running";
    this.currentTime = 0;
    this.scheduled = [];
    this.listeners = new Map();
    this.resumeCalls = 0;
    audioContexts.push(this);
  }

  addEventListener(name, callback) {
    const listeners = this.listeners.get(name) ?? [];
    listeners.push(callback);
    this.listeners.set(name, listeners);
  }

  dispatch(name) {
    for (const callback of this.listeners.get(name) ?? []) callback();
  }

  createMediaStreamDestination() {
    return { stream: { getAudioTracks: () => [{ stop() {} }] } };
  }

  createBuffer(channels, frames, rate) {
    return {
      numberOfChannels: channels,
      length: frames,
      sampleRate: rate,
      getChannelData: () => new Float32Array(frames),
    };
  }

  createBufferSource() {
    const context = this;
    return {
      buffer: null,
      connect() {},
      start(when) { context.scheduled.push(when); },
    };
  }

  resume() {
    this.resumeCalls += 1;
    this.state = "running";
    return Promise.resolve();
  }

  suspend() {
    this.state = "suspended";
    return Promise.resolve();
  }
}
globalThis.AudioContext = FakeAudioContext;
globalThis.MediaStream = class { constructor(tracks) { this.tracks = tracks; } };
globalThis.VideoDecoder = class {
  constructor() { this.state = "configured"; }
  configure() {}
  close() { this.state = "closed"; }
  decode() {}
};
globalThis.EncodedVideoChunk = class {};
globalThis.location = { href: "http://viewer.test", replace() {} };

let videoFetches = 0;
globalThis.fetch = (url) => {
  if (String(url).startsWith("/h264")) videoFetches += 1;
  return new Promise(() => {});
};

new Function(script)();
if (videoFetches !== 1) {
  throw new Error(`Expected one initial H.264 connection, received ${videoFetches}.`);
}

elements.nativeVideo.dispatch("webkitbeginfullscreen");
elements.nativeVideo.muted = false;
elements.nativeVideo.volume = 1;
document.hidden = true;
for (const callback of documentListeners.get("visibilitychange") ?? []) callback();
// Backgrounding Safari while AVKit is fullscreen must silence the stream.
// Safari 17.2 fixed the visibility bug this case used to be exempted for, so a
// hidden document now means the page really lost visibility. Skipping the mute
// here is what let game audio keep playing over the iOS Home Screen.
if (!elements.nativeVideo.muted || elements.nativeVideo.volume !== 0) {
  throw new Error(
    "Backgrounding while AVKit is fullscreen must mute audio, not leak it to the Home Screen.",
  );
}
for (const callback of windowListeners.get("pageshow") ?? []) callback({ persisted: false });
for (const callback of windowListeners.get("focus") ?? []) callback();

if (videoFetches !== 2) {
  throw new Error(
    `Clustered pageshow/focus events must create one recovery connection; received ${videoFetches - 1}.`,
  );
}

elements.nativeVideo.dispatch("webkitendfullscreen");
const afterFullscreenExit = videoFetches;
elements.nativeVideo.muted = false;
elements.nativeVideo.volume = 1;
document.hidden = true;
for (const callback of documentListeners.get("visibilitychange") ?? []) callback();
if (!elements.nativeVideo.muted || elements.nativeVideo.volume !== 0) {
  throw new Error("Backgrounding the DOM viewer did not mute its media audio immediately.");
}
document.hidden = false;
for (const callback of documentListeners.get("visibilitychange") ?? []) callback();
if (elements.nativeVideo.volume !== 1) {
  throw new Error("Foregrounding the viewer did not restore its media volume.");
}

if (videoFetches !== afterFullscreenExit + 1) {
  throw new Error("A rapid visible-page return must not be swallowed by recovery coalescing.");
}

elements.nativeVideo.dispatch("webkitbeginfullscreen");
elements.nativeVideo.muted = false;
elements.nativeVideo.volume = 1;
for (const callback of windowListeners.get("pagehide") ?? []) callback();
if (!elements.nativeVideo.muted || elements.nativeVideo.volume !== 0) {
  throw new Error("Leaving a legacy native fullscreen viewer did not mute background audio.");
}

// An interrupted AudioContext must recover on its own. Another app taking an
// audio session (a voice call, Discord) suspends it, and every resume() call
// used to hang off a user gesture or a visibility/focus/pageshow/online event —
// none of which fire on an audio interruption. Audio stayed dead until reload.
elements.nativeVideo.dispatch("webkitendfullscreen");
document.hidden = false;
for (const callback of documentListeners.get("visibilitychange") ?? []) callback();

if (audioContexts.length !== 1) {
  throw new Error(`Expected exactly one AudioContext, saw ${audioContexts.length}.`);
}
const audio = audioContexts[0];

if (intervals.length === 0) {
  throw new Error("The viewer must register a periodic audio reconciler.");
}

// Unlock audio the way a user tap does.
elements.stage.dispatch("click", { preventDefault() {}, stopPropagation() {} });
await Promise.resolve();
await Promise.resolve();

// Simulate another app interrupting the session.
audio.state = "interrupted";
const resumesBeforeStateChange = audio.resumeCalls;
audio.dispatch("statechange");
if (audio.resumeCalls <= resumesBeforeStateChange) {
  throw new Error(
    "An interrupted AudioContext must be resumed from its statechange handler, not left dead until reload.",
  );
}

// And the interval must be a backstop for interruptions that emit no event.
await Promise.resolve();
audio.state = "suspended";
const resumesBeforeInterval = audio.resumeCalls;
runIntervals();
if (audio.resumeCalls <= resumesBeforeInterval) {
  throw new Error("The periodic reconciler must resume a suspended AudioContext.");
}

console.log("Browser lifecycle recovery smoke test passed.");
