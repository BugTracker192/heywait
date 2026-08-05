# ReplayKit Broadcast Upload Buffer Resolution on iOS 26

**Research date:** August 5, 2026  
**Question:** Does an iOS 26 ReplayKit broadcast upload extension receive the sender device's native panel resolution, or a buffer that ReplayKit has already downsampled?

## Conclusion

**Apple does not document a guaranteed resolution relationship between a ReplayKit broadcast upload extension's video `CMSampleBuffer` and the device's native panel resolution.**

The public ReplayKit contract says that an `RPBroadcastSampleHandler` receives `CMSampleBuffer` objects captured by ReplayKit, but it does not state that:

- the video buffer must equal `UIScreen.main.nativeBounds`;
- the buffer must equal the physical panel's pixel grid;
- ReplayKit never scales before creating the buffer;
- a particular iPhone model must produce a particular width and height; or
- iOS 26 preserves a resolution behavior from earlier iOS releases.

Therefore, **the actual dimensions reported by the incoming video sample are the authoritative ceiling for that device, iOS build, orientation, and broadcast session.** If ReplayKit supplies a buffer smaller than the panel resolution, no bitrate, codec profile, or encoder output setting can reconstruct the missing source pixels.

## What Apple does document

### 1. The extension receives ReplayKit-captured sample buffers

Apple describes `RPBroadcastSampleHandler` as the class used to handle `CMSampleBuffer` objects "as captured by ReplayKit." Its `processSampleBuffer(_:with:)` callback receives the video and audio samples during the broadcast.

This establishes the API boundary, but **does not define the capture buffer's width or height**.

Sources:

- [RPBroadcastSampleHandler — Apple Developer Documentation](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler)
- [processSampleBuffer(_:with:) — Apple Developer Documentation](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler/processsamplebuffer%28_%3Awith%3A%29)

### 2. ReplayKit transports the video sample's IOSurface to the extension

Apple's Platform Security documentation explains that ReplayKit screen/audio capture occurs in the out-of-process `replayd` daemon. For broadcast extensions, video data is passed by extracting the `IOSurface` from the video sample buffer, transferring it over XPC, and reconstructing it for the third-party extension.

This is useful because it indicates that the upload extension receives the system-produced video surface rather than an already compressed H.264/HEVC stream.

However, this **still does not prove native-panel capture**. ReplayKit could render or scale into that IOSurface before the sample buffer reaches the XPC-transfer stage. The security document describes transport and isolation, not the dimensions at which `replayd` creates the surface.

Source:

- [ReplayKit security in iOS and iPadOS — Apple Platform Security](https://support.apple.com/guide/security/replaykit-security-seca5fc039dd/web)

### 3. Apple provides APIs to inspect the delivered dimensions

For a video sample, the extension can obtain its image buffer and read:

- `CVPixelBufferGetWidth`
- `CVPixelBufferGetHeight`
- `CMVideoFormatDescriptionGetDimensions`
- `CMVideoFormatDescriptionGetPresentationDimensions`

Apple defines the first pair as returning the pixel buffer's width and height in pixels. `CMVideoFormatDescriptionGetDimensions` returns encoded-pixel dimensions, while presentation dimensions can additionally account for pixel aspect ratio and clean aperture.

Sources:

- [CVPixelBufferGetWidth — Apple Developer Documentation](https://developer.apple.com/documentation/corevideo/cvpixelbuffergetwidth%28_%3A%29)
- [CVPixelBufferGetHeight — Apple Developer Documentation](https://developer.apple.com/documentation/corevideo/cvpixelbuffergetheight%28_%3A%29)
- [CMVideoFormatDescriptionGetDimensions — Apple Developer Documentation](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptiongetdimensions%28_%3A%29)
- [CMVideoFormatDescriptionGetPresentationDimensions — Apple Developer Documentation](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptiongetpresentationdimensions%28_%3Ausepixelaspectratio%3Ausecleanaperture%3A%29)

### 4. Orientation is metadata separate from raw buffer dimensions

ReplayKit historically exposed `RPVideoSampleOrientationKey` as the sample attachment describing video orientation. Consequently, width and height should not be interpreted without also considering orientation. A portrait scene may arrive in a storage orientation that needs rotation before encoding or display.

The current Apple documentation marks this ReplayKit symbol deprecated, but it remains relevant when diagnosing an existing ReplayKit broadcast path on iOS 26.

Source:

- [RPVideoSampleOrientationKey — Apple Developer Documentation](https://developer.apple.com/documentation/replaykit/rpvideosampleorientationkey)

## What Apple does not document

I found no Apple API reference, ReplayKit overview, Apple Platform Security description, WWDC ReplayKit transcript, or iOS 26 release-note statement that promises any of the following:

1. A broadcast upload extension receives the exact physical panel resolution.
2. A broadcast upload extension receives `UIScreen.main.nativeBounds` dimensions.
3. ReplayKit always downscales to a fixed maximum such as 720p, 1080p, or 1920 pixels on the long edge.
4. ReplayKit never changes video dimensions during a session.
5. An upload extension can request a preferred ReplayKit capture resolution.
6. Encoder width, height, bitrate, or profile settings can influence the dimensions of the source buffer supplied by ReplayKit.

Apple's description of ReplayKit as providing "HD quality" is a qualitative product statement, not a resolution contract.

## Direct answer for the `1170x2532 -> ...` diagnostic

The log line should distinguish the stages explicitly:

```text
ReplayKit input: 1170x2532, pixelFormat=..., orientation=...
Encoder input/adaptor: 1170x2532
Encoded output: 1170x2532   # or a smaller configured output
```

Interpretation:

| Observation | Meaning |
|---|---|
| ReplayKit input is `1170x2532` | ReplayKit delivered the device's full `1170x2532` pixel surface for that test. Any later reduction is in your conversion/encoder pipeline. |
| ReplayKit input is smaller than `1170x2532` | The source was already reduced before your encoder. Raising encoder resolution or bitrate cannot recover the omitted pixels. |
| Pixel-buffer dimensions are full-size but presentation dimensions are smaller | Inspect clean aperture, pixel aspect ratio, and orientation before concluding that image content was downsampled. |
| Dimensions change during the broadcast | Rebuild or reconfigure any pixel-buffer pool, scaler, encoder session, or `AVAssetWriterInput` that assumed a fixed source format. |
| Input stays full-size while encoded output is smaller | The scaling ceiling is under application control, assuming the encoder supports the requested dimensions and resource cost. |

**Important:** One successful full-resolution observation is empirical evidence for that specific hardware and iOS build; it is not an Apple-guaranteed behavior for all iOS 26 devices or future updates.

## Recommended diagnostic code

Log whenever the delivered source format changes, rather than only on the first frame:

```swift
import CoreMedia
import CoreVideo
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var lastVideoSignature: String?

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        var encodedDimensions = "unknown"
        var presentationDimensions = "unknown"

        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let encoded = CMVideoFormatDescriptionGetDimensions(format)
            encodedDimensions = "\(encoded.width)x\(encoded.height)"

            let presentation = CMVideoFormatDescriptionGetPresentationDimensions(
                format,
                usePixelAspectRatio: true,
                useCleanAperture: true
            )
            presentationDimensions =
                "\(Int(presentation.width))x\(Int(presentation.height))"
        }

        let signature = [
            "pixelBuffer=\(bufferWidth)x\(bufferHeight)",
            "format=\(encodedDimensions)",
            "presentation=\(presentationDimensions)",
            String(format: "pixelFormat=0x%08X", pixelFormat)
        ].joined(separator: " ")

        if signature != lastVideoSignature {
            lastVideoSignature = signature
            NSLog("ReplayKit video format changed: %@", signature)
        }

        // Continue with the existing conversion/encoding path.
    }
}
```

Also log the following outside the upload extension, where available:

```swift
let screen = UIScreen.main
print("bounds points: \(screen.bounds.size)")
print("scale: \(screen.scale)")
print("nativeScale: \(screen.nativeScale)")
print("nativeBounds pixels: \(screen.nativeBounds.size)")
```

Do not use `UIScreen.main.nativeBounds` as the encoder's assumed input format. Use it only as a comparison value. The actual ReplayKit pixel buffer is the source of truth.

## Strongest defensible statement

> On iOS 26, Apple does not publicly guarantee that ReplayKit broadcast-upload video buffers equal the sender's native panel resolution, nor does it document a fixed pre-delivery downsampling rule. The upload extension receives the system-produced video `CMSampleBuffer`; its pixel-buffer and format-description dimensions must be measured at runtime. Those incoming dimensions are the maximum real source resolution available to the application's encoder for that session.

## Practical next action

Capture and retain one format-change log from each relevant combination:

- device model;
- exact iOS 26 build;
- portrait and landscape;
- broadcast started from the target app and from another app;
- low-power and thermal-pressure conditions, where practical;
- before and after an app switch or orientation change.

The most valuable single line is:

```text
ReplayKit pixelBuffer=<W>x<H> format=<W>x<H> presentation=<W>x<H> -> encoder=<W>x<H> -> output=<W>x<H>
```

That line establishes exactly where any resolution loss occurs.
