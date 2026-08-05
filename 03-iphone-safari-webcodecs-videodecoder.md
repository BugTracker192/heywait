# WebCodecs `VideoDecoder` on iPhone Safari

**Verified:** 2026-08-05  
**Current stable baseline checked:** iOS 26.6 / Safari 26.6

## Conclusion

WebCodecs video support, including the `VideoDecoder` path, **did ship on iPhone with Safari/iOS 16.4**.

The README's Safari 16.4 baseline is therefore substantially correct. iPhone did not receive the video-decoding API later than iPadOS in a way that would make MJPEG the normal fallback on current iPhones.

On iOS 16.4 or newer, MJPEG should not be selected merely because the device is an iPhone. It should be used only when:

- `VideoDecoder` is absent, such as on iOS versions before 16.4;
- the requested codec/configuration is unsupported;
- decoder creation or configuration fails;
- the application deliberately chooses MJPEG for another compatibility reason.

## Current Apple/WebKit evidence

### 1. Apple's Safari 16.4 release notes cover iOS 16.4

Apple states that Safari 16.4 is available for iOS 16.4 and records:

> “Added video-only support for Web Codecs.”

Source: [Safari 16.4 Release Notes](https://developer.apple.com/documentation/safari-release-notes/safari-16_4-release-notes)

### 2. WebKit explicitly identifies iOS and iPadOS 16.4

WebKit's iOS/iPadOS 16.4 announcement lists:

> “Web Codecs API video support”

among the new APIs for web apps on those operating systems.

Source: [Web Push for Web Apps on iOS and iPadOS — New Web API](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/#new-web-api-for-web-apps)

### 3. WebKit's main Safari 16.4 announcement confirms video WebCodecs

WebKit states:

> “Safari 16.4 adds support for the video portion of Web Codecs API.”

Source: [WebKit Features in Safari 16.4](https://webkit.org/blog/13966/webkit-features-in-safari-16-4/#media)

### 4. Later WebKit releases describe 16.4 as the original ship point

The Safari 17.2 announcement says WebKit originally shipped video WebCodecs in Safari 16.4.

Source: [WebKit Features in Safari 17.2](https://webkit.org/blog/14787/webkit-features-in-safari-17-2/)

Safari 26.0 then expanded WebCodecs with `AudioEncoder` and `AudioDecoder`, showing that video support was already established.

Source: [WebKit Features in Safari 26.0 — Media](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/#media)

### 5. Current Safari continues to maintain `VideoDecoder`

Safari 26.4 fixed H.264 frame ordering in WebCodecs `VideoDecoder`, and Safari 27 beta contains another `VideoDecoder` ordering fix. These current fixes confirm that the interface remains an active supported implementation.

Sources:

- [WebKit Features for Safari 26.4](https://webkit.org/blog/17862/webkit-features-for-safari-26-4/)
- [Safari 26.4 Release Notes](https://developer.apple.com/documentation/safari-release-notes/safari-26_4-release-notes)
- [News from WWDC26: WebKit in Safari 27 beta](https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/)

## Important distinction: API support versus codec support

The presence of `VideoDecoder` does not guarantee that every codec string, profile, level, bit depth, chroma format, or resolution is supported.

Always test the actual decoder configuration:

```js
async function supportsVideoDecoderConfig(config) {
  if (typeof VideoDecoder !== "function") {
    return false;
  }

  try {
    const result = await VideoDecoder.isConfigSupported(config);
    return result.supported === true;
  } catch {
    return false;
  }
}
```

Then treat decoder construction and `configure()` as fallible:

```js
function createDecoder(config, onFrame, onError) {
  const decoder = new VideoDecoder({
    output: onFrame,
    error: onError,
  });

  try {
    decoder.configure(config);
    return decoder;
  } catch (error) {
    decoder.close();
    throw error;
  }
}
```

For example, H.264 support does not mean every H.264 profile/level combination is guaranteed. HEVC WebCodecs support was added later in Safari 17.4, while AV1 availability can depend on device hardware.

Source: [WebKit Features in Safari 17.4](https://webkit.org/blog/15063/webkit-features-in-safari-17-4/)

## Engineering impact

### Assumption verdict

> `VideoDecoder` may be missing on most current iPhones, making MJPEG the common path.

**False for iPhones running iOS 16.4 or newer.**

### Correct priority conclusion

- The JPEG encoder and `CIContext` memory cost still matter for old iOS devices and genuine decoder/configuration failures.
- They should not be prioritized on the premise that modern iPhone Safari generally lacks WebCodecs.
- Instrument the selected transport/decoder path in production so you can measure actual fallback frequency rather than infer it from the device class.

Suggested telemetry fields:

```js
{
  platform: "ios",
  safariVersion: "...",
  hasVideoDecoder: typeof VideoDecoder === "function",
  configSupported: true,
  selectedPath: "webcodecs", // or "mjpeg"
  fallbackReason: null
}
```

## Suggested documentation wording

> Safari on iPhone and iPad supports WebCodecs video decoding beginning with Safari 16.4. Actual codec configurations are feature-tested with `VideoDecoder.isConfigSupported()`, with MJPEG retained for older systems and unsupported or failed decoder configurations.
