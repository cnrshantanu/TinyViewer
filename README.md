# Tiny Viewer

Stream your Mac screen to any browser — free, self-hosted, no subscriptions.

**[tiny-viewer.web.app](https://tiny-viewer.web.app)**

[![Release](https://github.com/cnrshantanu/TinyViewer/actions/workflows/release.yml/badge.svg)](https://github.com/cnrshantanu/TinyViewer/actions/workflows/release.yml)
[![Latest Release](https://img.shields.io/github/v/release/cnrshantanu/TinyViewer)](https://github.com/cnrshantanu/TinyViewer/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-13%2B-blue)](https://github.com/cnrshantanu/TinyViewer/releases/latest)
[![License](https://img.shields.io/github/license/cnrshantanu/TinyViewer)](LICENSE)

---

## Quick start (using the hosted web app)

If you just want to use Tiny Viewer without running your own server:

1. [Download the Mac app](https://github.com/cnrshantanu/TinyViewer/releases/latest)
2. Open it, sign in with Google, and click **Start Server**
3. Go to [tiny-viewer.web.app](https://tiny-viewer.web.app) from any browser and click **Access My Mac**

That's it — no configuration needed.

---

## Self-hosting your own deployment

Fork the repo and run everything on your own Firebase project and GitHub account.
You'll need:

- An [Apple Developer account](https://developer.apple.com) (free tier works for local builds)
- A [Firebase project](https://console.firebase.google.com) (free Spark plan is enough)
- A [Google Cloud OAuth 2.0 client](https://console.cloud.google.com) for the Mac app sign-in
- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) on the Mac: `brew install cloudflared`
- Xcode 15+, macOS 13+

### Step 1 — Firebase project

1. Create a project at [console.firebase.google.com](https://console.firebase.google.com)
2. **Authentication → Sign-in method** → enable **Google**
3. **Firestore Database** → create a database (start in production mode)
4. **Project Settings → Your apps** → add a **Web app** → copy the `firebaseConfig` object
5. **Authentication → Settings → Authorized domains** → add your Firebase Hosting domain (e.g. `your-project.web.app`)

### Step 2 — Google OAuth client for the Mac app

1. [Google Cloud Console](https://console.cloud.google.com) → APIs & Services → Credentials
2. **Create Credentials → OAuth 2.0 Client ID**
   - Application type: **Desktop app**
   - Name: e.g. "Tiny Viewer Mac"
3. Copy the **Client ID** and **Client Secret**
4. Under the same credential, add `http://localhost` to **Authorized redirect URIs**

### Step 3 — Configure the Mac app

```bash
cp "mac-app/Tiny Viewer/FirebaseConfig.swift.example" "mac-app/Tiny Viewer/FirebaseConfig.swift"
```

Edit `FirebaseConfig.swift` and fill in your values:

```swift
enum FirebaseConfig {
    static let projectID          = "your-firebase-project-id"
    static let webAPIKey          = "AIzaSy..."          // Firebase → Project Settings → Web API Key
    static let googleClientID     = "123....apps.googleusercontent.com"
    static let googleClientSecret = "GOCSPX-..."
}
```

> **`FirebaseConfig.swift` is gitignored** — your credentials will never be committed.

### Step 4 — Configure the web app

Replace the `firebaseConfig` block in **both** `web-app/index.html` and `web-app/app.html` with your own project's values (from Step 1):

```js
const firebaseConfig = {
  apiKey:            "YOUR_API_KEY",
  authDomain:        "YOUR_PROJECT.firebaseapp.com",
  projectId:         "YOUR_PROJECT_ID",
  storageBucket:     "YOUR_PROJECT.firebasestorage.app",
  messagingSenderId: "YOUR_SENDER_ID",
  appId:             "YOUR_APP_ID"
};
```

Also update the download links in `index.html` to point to your own GitHub repo.

> **Note:** Firebase web API keys are safe to commit and expose publicly — they identify your project but do not grant privileged access. Security is enforced entirely by Firestore rules and Firebase Auth.

### Step 5 — Deploy the web app

```bash
cd web-app
npm install -g firebase-tools   # if not already installed
firebase login
firebase use --add              # select your project
firebase deploy --only hosting,firestore:rules
```

Your site will be live at `https://YOUR_PROJECT.web.app`.

### Step 6 — Build and run the Mac app

Open `mac-app/Tiny Viewer.xcodeproj` in Xcode:

1. Select the **Tiny Viewer** target → **Signing & Capabilities**
2. Set your **Team** and change **Bundle Identifier** to something unique (e.g. `com.yourname.tinyviewer`)
3. Press **⌘R** to build and run

Grant permissions when prompted:
- **Screen Recording** (System Settings → Privacy & Security)
- **Accessibility** (System Settings → Privacy & Security)

### Step 7 — Firestore security rules

The included `web-app/firestore.rules` restricts each user to reading/writing only their own `tunnels/{uid}` document. Deploy them with:

```bash
cd web-app && firebase deploy --only firestore:rules
```

---

## How it works

```
Mac app  ──ScreenCaptureKit──▶  JPEG frames
         ──MJPEGServer──▶  HTTP + WebSocket on :8080
         ──cloudflared──▶  Cloudflare tunnel (public HTTPS URL)

Browser  ──Firebase Auth──▶  Google sign-in
         ──Firestore──▶  reads tunnels/{uid} to find Mac URL
         ──one-time token──▶  Mac validates via Firebase identitytoolkit
         ──session cookie──▶  authorized for viewer + terminal
```

## Architecture

| File | Role |
|------|------|
| `ContentView.swift` | App state, SwiftUI UI |
| `MJPEGServer.swift` | HTTP + WebSocket server, viewer HTML, terminal routes |
| `ScreenCapturer.swift` | ScreenCaptureKit → JPEG frames |
| `VideoEncoder.swift` | H.264/VideoToolbox encoder (compiled; not in release UI yet) |
| `TerminalSession.swift` | PTY shell ↔ WebSocket bridge |
| `InputController.swift` | Mouse & keyboard injection via CGEvent |
| `TunnelManager.swift` | cloudflared process wrapper |
| `FirebaseClient.swift` | Auth, Firestore presence, heartbeat |

## Distribution

The app **cannot** be on the Mac App Store — it uses `cloudflared` (external binary) and spawns PTY shell processes, both of which violate the App Store sandbox. Distribute as a **Developer ID notarized `.dmg`**.

## License

MIT — see [LICENSE](LICENSE)
