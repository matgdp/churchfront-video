# Harvest Camera Tracker

Automatic person tracking and PTZ camera control for Harvest Community Church livestreams. The standalone app uses Apple Vision to follow a person, RTSP for the camera preview, and VISCA over TCP to move a PTZOptics camera. It tracks on one selected camera at a time and runs independently of ATEM and NDI.

## Download for Intel Mac

The current build requires an **Intel Mac running macOS 14 or later**. The download is an Intel-only, ad hoc signed test build.

1. Sign in to GitHub and open the [Intel build](https://github.com/matgdp/harvest-camera-tracker/actions/runs/45051770893).
2. Under **Artifacts**, download **Camera-Tracker-Intel** and extract the ZIP. If it contains another ZIP, extract that too. The current app bundle is named `Camera Tracker.app`.

## Set up and track

1. Install FFmpeg with `brew install ffmpeg` if Homebrew is installed. The app
   checks `/usr/local/bin/ffmpeg` and `/opt/homebrew/bin/ffmpeg`.
2. Open Camera Tracker, choose **Add Camera**, enter the name and IP you use in Companion,
   then save it and click **Connect**. The default VISCA TCP port is `5678`. The default RTSP address uses
   port `554` and path `/2`, the lower-resolution stream on many PTZOptics models.
   Use the path from your camera's web UI if it differs, for example `/1` or
   `/stream2`. This version supports RTSP streams without authentication.
   Add more cameras the same way. The Camera menu remembers your selection. While connected,
   choosing a different camera stops tracking on the old one and connects the newly selected camera.
3. Wait for both VISCA and RTSP to connect. While the camera is off air, click
   someone in the preview or use **Start Tracking** to follow the person nearest
   the center. **Stop** or Escape stops tracking and continuous manual motion.
   Auto zoom starts off. If the app loses the subject, click the person again.
   Hold a directional control for manual pan or tilt.

## Build from source

On macOS with Swift and the Xcode command-line tools, run `swift test` and
`./build.sh` in this directory. The bundle will be in `dist/Camera Tracker.app`.

## Credits

Camera control, framing, and subject matching were adapted from Churchfront
Video, Copyright 2026 Churchfront LLC. See LICENSE and NOTICE.
