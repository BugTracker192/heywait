# Distinguishing AVKit Fullscreen from Safari Backgrounding on iOS

**Verified:** 2026-08-05

## Conclusion

There is **no dedicated API property that explains why a page became hidden**.

However, on current iOS Safari, native AVKit fullscreen and actual page backgrounding can normally be distinguished using two independent signals:

- Native AVKit fullscreen: `video.webkitPresentationMode === "fullscreen"` or `video.webkitDisplayingFullscreen === true`
- Page backgrounding or obscuring: `document.visibilityState === "hidden"`

Entering native AVKit fullscreen should **not itself make the document hidden** on modern Safari. Safari 17.2 fixed an earlier bug where entering fullscreen briefly changed `document.visibilityState` to `"hidden"`.

Source: [WebKit Features in Safari 17.2](https://webkit.org/blog/14787/webkit-features-in-safari-17-2/)

Therefore:

```js
document.hidden === true
```

should generally be treated as actual page visibility loss, not merely AVKit fullscreen.

If both of these are true at the same time:

```js
document.visibilityState === "hidden"
video.webkitPresentationMode === "fullscreen"
```

the safest interpretation is:

- Safari was backgrounded while AVKit was fullscreen;
- a fullscreen-to-Picture-in-Picture or fullscreen-to-inline transition is still settling;
- or the device is running an older Safari version with the historical visibility bug.

There is no documented field that exposes the exact cause of the hidden state.

---

## Event Behaviour

| Event | AVKit video enters fullscreen | Safari is backgrounded |
|---|---|---|
| `visibilitychange` | On modern Safari, entering AVKit fullscreen alone should not produce a hidden transition. Safari 17.2 fixed the earlier brief change to `hidden`. Normally, no `visibilitychange` occurs solely because native video fullscreen begins or ends. | Normally fires with `document.visibilityState === "hidden"` when Safari becomes obscured, another tab or application is selected, or the device is locked. It may not fire if Safari or its web-content process is abruptly terminated. |
| `pagehide` | Does not normally fire. Entering AVKit fullscreen is not a navigation, unload, history traversal, or BFCache transition. | Does not normally fire merely because Safari is backgrounded. It is associated with navigation, document replacement, history traversal, or BFCache entry. It may also be skipped if iOS terminates Safari. |
| `window.blur` | Not documented as a reliable AVKit-fullscreen signal. It may vary depending on Safari and native UI focus behaviour. | May fire when the user leaves Safari, but it is not a dependable background signal. It can also fire when focus moves to browser chrome, such as the address bar. Its ordering relative to `visibilitychange` is not guaranteed. |
| `webkitpresentationmodechanged` | Fires when the video's native presentation mode changes. Read `video.webkitPresentationMode`, which normally becomes `"fullscreen"` on entry and `"inline"` on exit. | Backgrounding alone should not fire it. It fires only if backgrounding also causes a media presentation transition, such as fullscreen to Picture-in-Picture or fullscreen to inline. |

---

## Relevant APIs

### AVKit presentation state

```js
const avkitFullscreen =
  video.webkitPresentationMode === "fullscreen" ||
  video.webkitDisplayingFullscreen === true;
```

Possible values of `video.webkitPresentationMode` commonly include:

```text
inline
fullscreen
picture-in-picture
```

Listen for native video presentation changes:

```js
video.addEventListener("webkitpresentationmodechanged", () => {
  console.log(video.webkitPresentationMode);
});
```

### Page visibility state

```js
const pageHidden =
  document.visibilityState === "hidden";
```

Listen for page visibility changes:

```js
document.addEventListener("visibilitychange", () => {
  console.log(document.visibilityState);
});
```

---

## Recommended State Classifier

```js
function getIOSPresentationState(video) {
  const presentationMode =
    typeof video.webkitPresentationMode === "string"
      ? video.webkitPresentationMode
      : null;

  const avkitFullscreen =
    presentationMode === "fullscreen" ||
    video.webkitDisplayingFullscreen === true;

  const pageHidden =
    document.visibilityState === "hidden";

  if (pageHidden && avkitFullscreen) {
    // Do not interpret this as "hidden because of fullscreen".
    // It means the page is hidden while AVKit is still considered
    // fullscreen, or a presentation transition has not settled yet.
    return "backgrounded-while-avkit-fullscreen";
  }

  if (pageHidden) {
    return "backgrounded";
  }

  if (avkitFullscreen) {
    return "avkit-fullscreen";
  }

  if (presentationMode === "picture-in-picture") {
    return "picture-in-picture";
  }

  return "foreground-inline";
}
```

Register both relevant events:

```js
video.addEventListener("webkitpresentationmodechanged", () => {
  console.log(getIOSPresentationState(video));
});

document.addEventListener("visibilitychange", () => {
  console.log(getIOSPresentationState(video));
});
```

---

## Recommended Production Logic

Treat the two signals independently:

```js
const safariActuallyBackgrounded =
  document.visibilityState === "hidden";

const avkitIsFullscreen =
  video.webkitPresentationMode === "fullscreen" ||
  video.webkitDisplayingFullscreen === true;
```

Do not use either of these as the primary discriminator:

```js
window.blur
pagehide
```

They describe different lifecycle or focus conditions and are not reliable indicators of AVKit fullscreen versus application backgrounding.

The practical model is:

- `webkitpresentationmodechanged` tells you what the native video presentation system is doing.
- `visibilitychange` tells you whether the web document is visible.
- Neither event alone explains every race or transition.
- Their combined state is the best available classifier.

---

## Sources

- [WebKit Features in Safari 17.2](https://webkit.org/blog/14787/webkit-features-in-safari-17-2/)
- [Apple — HTMLVideoElement `webkitPresentationMode`](https://developer.apple.com/documentation/webkitjs/htmlvideoelement/1631913-webkitpresentationmode)
- [WHATWG HTML — Page Visibility](https://html.spec.whatwg.org/multipage/interaction.html)
- [WHATWG HTML — `pagehide` and navigation lifecycle](https://html.spec.whatwg.org/multipage/nav-history-apis.html)
- [WebKit Bug 219472 — Focus and blur behaviour](https://bugs.webkit.org/show_bug.cgi?id=219472)
