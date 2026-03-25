# Tiny Viewer

Stream your Mac screen to any browser — free, self-hosted, no subscriptions.

**[tiny-viewer.web.app](https://tiny-viewer.web.app)**

## Features

- **Relay mode** — one-click Cloudflare tunnel, works from anywhere in the world
- **Direct mode** — H.264 over WebSocket for sub-100ms LAN streaming
- **Full control** — mouse, keyboard, scroll, modifier keys
- **Built-in terminal** — interactive PTY shell in the browser
- **Secure** — Firebase auth + one-time session tokens + HTTPS only
- **Menu bar app** — lives quietly in the status bar, no Dock icon

## Requirements

- macOS 13 Ventura or later
- Xcode 15+
- A Firebase project (free tier is fine)
- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) for Relay mode: `brew install cloudflared`

## Setup

### 1. Firebase project

1. Create a project at [console.firebase.google.com](https://console.firebase.google.com)
2. Enable **Authentication → Google** sign-in
3. Create a **Firestore** database
4. In Google Cloud Console → APIs & Services → Credentials, create an **OAuth 2.0 Desktop client**
   - Add `http://localhost` as an Authorized Redirect URI

### 2. Mac app credentials

```bash
cp "mac-app/Tiny Viewer/FirebaseConfig.swift.example" "mac-app/Tiny Viewer/FirebaseConfig.swift"
# Edit FirebaseConfig.swift with your project ID, API key, and OAuth credentials
```

Open `mac-app/Tiny Viewer.xcodeproj` in Xcode, set your Team and Bundle ID, then run.

Grant permissions when prompted:
- **Screen Recording** — for display capture
- **Accessibility** — for mouse & keyboard injection

### 3. Web app

Replace the `firebaseConfig` values in `web-app/index.html` and `web-app/app.html`, then:

```bash
cd web-app
firebase deploy --only hosting
firebase deploy --only firestore:rules
```

## How it works

```
Mac app → ScreenCaptureKit → JPEG/H.264 frames
        → MJPEGServer (HTTP + WebSocket on :8080)
        → cloudflared tunnel (Relay) or local IP (Direct)
        → Browser viewer (HTML served by the Mac app)

Firebase → Google auth → one-time token → session cookie → authorized
         → Firestore presence (tunnels/{uid}) → web app detects Mac online
```

## Architecture

| File | Role |
|------|------|
| `ContentView.swift` | App state, SwiftUI UI |
| `MJPEGServer.swift` | HTTP + WebSocket server, viewer HTML |
| `ScreenCapturer.swift` | ScreenCaptureKit → JPEG frames |
| `VideoEncoder.swift` | H.264/VideoToolbox encoder (Direct mode) |
| `TerminalSession.swift` | PTY shell ↔ WebSocket bridge |
| `InputController.swift` | Mouse & keyboard injection via CGEvent |
| `TunnelManager.swift` | cloudflared process wrapper |
| `FirebaseClient.swift` | Auth, Firestore presence, heartbeat |

## Distribution

The app cannot be on the Mac App Store (uses `cloudflared` and PTY — incompatible with the sandbox). Distribute via **Developer ID** notarized `.dmg`.

## License

MIT — see [LICENSE](LICENSE)
