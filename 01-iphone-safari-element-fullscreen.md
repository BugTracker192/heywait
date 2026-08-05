# Element Fullscreen on iPhone Safari

**Verified:** 2026-08-05  
**Current stable baseline checked:** iOS 26.6 / Safari 26.6

## Conclusion

General DOM-element fullscreen is **still not supported by Safari on iPhone**.

Calling `Element.requestFullscreen()` on an arbitrary stage, container, canvas, or other non-video element cannot be treated as a working iPhone path. iPhone Safari still provides its separate native fullscreen presentation for `<video>`, but that is not equivalent to the standards-based Fullscreen API for an arbitrary element.

Therefore, a design that “prefers the live stage” through `stage.requestFullscreen()` will not use that path on ordinary iPhones. The video/AVKit path is not an unusual fallback there; it is effectively the main fullscreen route.

If that native-video route has no audio, the issue should be treated as an **iPhone-wide fullscreen audio failure**, not merely a low-priority fallback defect.

## Current Apple/WebKit evidence

### 1. WebKit's Safari 16.4 announcement deliberately excludes iPhone

WebKit stated that the unprefixed Fullscreen API was added on:

> “macOS and iPadOS”

It did **not** list iOS or iPhone.

Source: [WebKit Features in Safari 16.4 — Fullscreen API](https://webkit.org/blog/13966/webkit-features-in-safari-16-4/#fullscreen-api)

### 2. WebKit's tracking issue remains open in 2026

WebKit bug **206854**, “Add Fullscreen API to iOS,” is still:

- Status: `NEW`
- Resolution: none
- Priority: P2
- Last modified: 2026-06-08

The current issue discussion explicitly distinguishes iPhone's native `<video>` fullscreen from missing arbitrary-element fullscreen.

Source: [WebKit Bug 206854 — Add Fullscreen API to iOS](https://bugs.webkit.org/show_bug.cgi?id=206854)

### 3. No support was added in the latest stable release

Safari 26.6 was released on 2026-07-27. Its WebKit release announcement contains only a WebAssembly refinement and eight unrelated fixes. It does not announce element fullscreen for iPhone.

Source: [WebKit Features for Safari 26.6](https://webkit.org/blog/18178/webkit-features-for-safari-26-6/)

Apple release notes: [Safari 26.6 Release Notes](https://developer.apple.com/documentation/safari-release-notes/safari-26_6-release-notes)

### 4. Safari 27 beta still does not announce it

The Safari 27 beta announcement contains fullscreen-related fixes, but no addition of arbitrary-element Fullscreen API support on iPhone. WebKit bug 206854 therefore remains the relevant open tracking issue.

Source: [News from WWDC26: WebKit in Safari 27 beta](https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/)

## Engineering impact

### Assumption verdict

> `Element.requestFullscreen()` exists and works for the live stage on iPhone Safari in iOS 26.

**False for normal iPhone Safari.**

### Priority effect

1. Fix audio in the native `<video>`/AVKit fullscreen path first.
2. Treat arbitrary stage fullscreen as an iPadOS, macOS, and non-iPhone browser path.
3. Do not describe native video fullscreen as a rare legacy fallback on iPhone.
4. Keep a non-fullscreen inline-stage mode for custom overlays and controls.

## Recommended capability handling

Do not infer support only from a browser version or an iOS user-agent string. Use capability detection, attempt the operation only from a user gesture, and handle rejection:

```js
async function tryElementFullscreen(element) {
  if (
    !element ||
    typeof element.requestFullscreen !== "function" ||
    document.fullscreenEnabled !== true
  ) {
    return false;
  }

  try {
    await element.requestFullscreen();
    return document.fullscreenElement === element;
  } catch {
    return false;
  }
}
```

Even with this guard, design the iPhone path under the assumption that arbitrary-element fullscreen is unavailable.

For native iPhone video fullscreen, feature-detect the video-specific WebKit API separately rather than treating it as the same capability:

```js
const canUseNativeVideoFullscreen =
  typeof video.webkitEnterFullscreen === "function";
```

## Suggested documentation wording

> On iPhone Safari, arbitrary DOM elements cannot enter standards-based fullscreen. Fullscreen playback therefore uses the native video presentation path. iPadOS, macOS, and compatible browsers may fullscreen the complete live stage.
