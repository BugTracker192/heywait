# `screen.orientation.lock()` on iOS Safari

**Verified:** 2026-08-05  
**Current stable baseline checked:** iOS 26.6 / Safari 26.6

## Conclusion

`screen.orientation.lock()` is **not supported as a normal production web API in Safari on iPhone**.

Safari supports the read-only/event portion of the Screen Orientation API—such as `screen.orientation.type`, `angle`, and the `change` event—but the `lock()` and `unlock()` methods have not shipped for ordinary Safari use.

A `typeof screen.orientation.lock === "function"` guard is still correct defensive code, but on standard iPhone Safari it will not provide sender-driven orientation following. The guarded branch is effectively inert.

A README claim that the receiver automatically locks its physical screen orientation to match the sender is therefore inaccurate for iPhone Safari.

## Current Apple/WebKit evidence

### 1. WebKit shipped only orientation observation in Safari 16.4

WebKit lists these supported parts:

- `ScreenOrientation.prototype.type`
- `ScreenOrientation.prototype.angle`
- `ScreenOrientation.prototype.onchange`

For `lock()` and `unlock()`, WebKit stated:

> “remain experimental features”

The announcement required manually enabling an Experimental Features flag.

Source: [WebKit Features in Safari 16.4 — Screen Orientation API](https://webkit.org/blog/13966/webkit-features-in-safari-16-4/#screen-orientation-api)

Apple release notes: [Safari 16.4 Release Notes](https://developer.apple.com/documentation/safari-release-notes/safari-16_4-release-notes)

### 2. WebKit's implementation discussion confirms the practical blockers

WebKit bug **257695** records that the method was implemented for mobile behind an experimental feature. The discussion also documents two important constraints:

- Orientation locking requires an eligible fullscreen context.
- iPhone lacks arbitrary-element fullscreen, so the normal iPhone web-page path cannot satisfy that requirement.

A later comment reports that the experimental flag remained disabled by default.

Source: [WebKit Bug 257695 — ScreenOrientation lock API support](https://bugs.webkit.org/show_bug.cgi?id=257695)

Related fullscreen issue: [WebKit Bug 206854](https://bugs.webkit.org/show_bug.cgi?id=206854)

### 3. No shipping change appears through Safari 26.6

Neither the Safari 26.0 feature announcement nor the Safari 26.6 release announcement adds production support for `ScreenOrientation.lock()`.

Sources:

- [WebKit Features in Safari 26.0](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/)
- [WebKit Features for Safari 26.6](https://webkit.org/blog/18178/webkit-features-for-safari-26-6/)
- [Safari 26.6 Release Notes](https://developer.apple.com/documentation/safari-release-notes/safari-26_6-release-notes)

### 4. Current compatibility data agrees

Current MDN/Can I Use compatibility data marks `ScreenOrientation.lock()` as unsupported in Safari and Safari on iOS through the current releases.

Supporting references:

- [MDN — `ScreenOrientation.lock()`](https://developer.mozilla.org/en-US/docs/Web/API/ScreenOrientation/lock)
- [Can I Use — Screen orientation lock](https://caniuse.com/wf-screen-orientation-lock)

## Engineering impact

### Assumption verdict

> The receiver can call `screen.orientation.lock()` on iPhone Safari to follow the sender's orientation.

**False for the default production Safari environment.**

### What still works

The receiver can observe orientation and update its layout:

```js
const orientation = screen.orientation;

function applyOrientationLayout() {
  const type = orientation?.type ?? "";
  const landscape = type.startsWith("landscape");

  document.documentElement.dataset.orientation =
    landscape ? "landscape" : "portrait";
}

orientation?.addEventListener("change", applyOrientationLayout);
applyOrientationLayout();
```

That changes the page's layout; it does not force the physical device orientation.

### Safe lock attempt

Retaining a guarded best-effort call is reasonable for future compatibility:

```js
async function tryLockOrientation(target) {
  const lock = screen.orientation?.lock;

  if (typeof lock !== "function") {
    return false;
  }

  try {
    await lock.call(screen.orientation, target);
    return true;
  } catch {
    return false;
  }
}
```

Do not treat a `false` result as exceptional on iPhone.

## Suggested documentation wording

> The receiver follows the sender's portrait/landscape layout when orientation changes. On browsers that expose and permit the Screen Orientation locking API, it also attempts to lock the device orientation. Safari on iPhone does not currently support that lock, so users may need to rotate the device manually.

## README line 53 verdict

If line 53 currently promises automatic orientation locking on iPhone Safari, it should be changed. A defensible claim is **layout synchronization**, not guaranteed physical orientation locking.
