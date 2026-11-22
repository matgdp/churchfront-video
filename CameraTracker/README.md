# Camera Tracker

A single-camera macOS app adapted from Churchfront Video. Camera Tracker uses
Apple Vision for person tracking, RTSP for the preview, and VISCA over TCP for
PTZOptics movement. It runs independently of the ATEM and NDI. The app has its
own preferences and bundle identifier.

## Run on the Intel Mac

1. Install FFmpeg with `brew install ffmpeg` if Homebrew is installed. The app
   checks `/usr/local/bin/ffmpeg` and `/opt/homebrew/bin/ffmpeg`.
2. Open Camera Tracker, enter the same camera IP you use in Companion, and click
   **Connect**. The default VISCA TCP port is `5678`. The default RTSP address uses
   port `554` and path `/2`, the lower-resolution stream on many PTZOptics models.
   Use the path from your camera's web UI if it differs, for example `/1` or
   `/stream2`. This version supports RTSP streams without authentication.
3. Wait for both VISCA and RTSP to connect. While the camera is off air, click
   someone in the preview or use **Start Tracking** to follow the person nearest
   the center. **Stop** or Escape stops tracking and continuous manual motion.
   Auto zoom starts off. If the app loses the subject, click the person again.
   Hold a directional control for manual pan or tilt.

The app runs on macOS 14 or later. The downloadable test build is ad hoc signed.

## Build from source

On macOS with Swift and the Xcode command-line tools, run `swift test` and
`./build.sh` in this directory. The bundle will be in `dist/Camera Tracker.app`.

## Credits

Camera control, framing, and subject matching were adapted from Churchfront
Video, Copyright 2026 Churchfront LLC. See LICENSE and NOTICE.
