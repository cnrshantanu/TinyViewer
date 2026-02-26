import Foundation
import Network

// MARK: - HTML templates

private let pinPageTemplate = """
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Tiny Viewer</title>
  <style>
    *{box-sizing:border-box}
    body{margin:0;background:#111;display:flex;justify-content:center;align-items:center;min-height:100vh;font-family:-apple-system,sans-serif}
    .card{background:#1c1c1e;border-radius:16px;padding:2rem;width:300px;display:flex;flex-direction:column;gap:1rem}
    h2{color:#fff;margin:0;text-align:center;font-size:1.1rem}
    input{padding:.75rem;border-radius:10px;border:1px solid #3a3a3c;background:#2c2c2e;color:#fff;font-size:1.4rem;letter-spacing:.3rem;text-align:center;outline:none;width:100%}
    input:focus{border-color:#0a84ff}
    button{padding:.75rem;border-radius:10px;border:none;background:#0a84ff;color:#fff;font-size:1rem;font-weight:600;cursor:pointer;width:100%}
    .err{color:#ff453a;text-align:center;font-size:.85rem}
  </style>
</head>
<body>
  <div class="card">
    <h2>&#x1F5A5; Tiny Viewer</h2>
    <form method="POST" action="/auth">
      <input type="password" name="pin" placeholder="PIN" autofocus autocomplete="off" maxlength="16">
      <button type="submit">Connect</button>
    </form>
    %%ERROR%%
  </div>
</body>
</html>
"""

private let viewerHTML = """
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Tiny Viewer</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    html,body{width:100%;height:100%;background:#000;overflow:hidden;cursor:none}
    img{width:100vw;height:100vh;object-fit:cover;display:block;user-select:none;-webkit-user-drag:none}
  </style>
</head>
<body>
  <img id="s" src="/stream" draggable="false">
  <script>
    const img = document.getElementById('s');

    // Normalise client coords → 0-1, accounting for object-fit:cover scaling
    function norm(cx, cy) {
      const r  = img.getBoundingClientRect();
      const iw = img.naturalWidth  || r.width;
      const ih = img.naturalHeight || r.height;
      const sc = Math.max(r.width / iw, r.height / ih); // max = cover
      const dw = iw * sc, dh = ih * sc;
      const ox = (r.width  - dw) / 2;
      const oy = (r.height - dh) / 2;
      const x  = Math.max(0, Math.min(1, (cx - r.left - ox) / dw));
      const y  = Math.max(0, Math.min(1, (cy - r.top  - oy) / dh));
      return {x, y};
    }

    // ── Event batching — all events queued and flushed every 16 ms ──────────
    let eventBatch = [];
    let flushHandle = null;

    function flushBatch() {
      flushHandle = null;
      if (!eventBatch.length) return;
      const batch = eventBatch.splice(0);
      fetch('/event', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(batch)
      }).catch(() => {});
    }

    function send(data) {
      eventBatch.push(data);
      if (!flushHandle) flushHandle = setTimeout(flushBatch, 16);
    }

    // Mouse move — throttled to 10/s to reduce POST volume
    let lastMove = 0;
    img.addEventListener('mousemove', e => {
      const now = Date.now();
      if (now - lastMove < 100) return;
      lastMove = now;
      const {x, y} = norm(e.clientX, e.clientY);
      send({type: 'mousemove', x, y});
    });

    img.addEventListener('mousedown', e => {
      e.preventDefault();
      const {x, y} = norm(e.clientX, e.clientY);
      send({type: 'mousedown', x, y, button: e.button});
    });

    img.addEventListener('mouseup', e => {
      const {x, y} = norm(e.clientX, e.clientY);
      send({type: 'mouseup', x, y, button: e.button});
    });

    img.addEventListener('contextmenu', e => e.preventDefault());
    img.addEventListener('dragstart',   e => e.preventDefault());

    // Scroll
    img.addEventListener('wheel', e => {
      e.preventDefault();
      send({type: 'wheel', dx: e.deltaX, dy: e.deltaY});
    }, {passive: false});

    // Keyboard — batched so fast typing arrives as one POST per 16 ms window
    document.addEventListener('click', () => document.body.focus());
    document.addEventListener('keydown', e => {
      e.preventDefault();
      send({type: 'keydown', key: e.key, code: e.code,
            shift: e.shiftKey, meta: e.metaKey, alt: e.altKey, ctrl: e.ctrlKey});
    });
    document.addEventListener('keyup', e => {
      send({type: 'keyup', key: e.key, code: e.code,
            shift: e.shiftKey, meta: e.metaKey, alt: e.altKey, ctrl: e.ctrlKey});
    });
  </script>
</body>
</html>
"""

// MARK: - Parsed HTTP Request

private struct HTTPRequest {
    let method: String
    let cleanPath: String       // path without query string
    let connectToken: String?   // ?token= param for one-time auth
    let sessionToken: String?
    let body: String
}

private func parse(_ data: Data) -> HTTPRequest {
    let text  = String(bytes: data, encoding: .utf8) ?? ""
    let lines = text.components(separatedBy: "\r\n")

    let firstParts = (lines.first ?? "").components(separatedBy: " ")
    let method  = firstParts.count > 0 ? firstParts[0] : "GET"
    let rawPath = firstParts.count > 1 ? firstParts[1] : "/"

    // Split path and query string
    let pathParts   = rawPath.components(separatedBy: "?")
    let cleanPath   = pathParts[0]
    let queryString = pathParts.count > 1 ? pathParts[1] : ""

    // Extract ?token= from query string
    let connectToken: String? = queryString
        .components(separatedBy: "&")
        .compactMap { item -> String? in
            let kv = item.components(separatedBy: "=")
            guard kv.count == 2, kv[0] == "token", !kv[1].isEmpty else { return nil }
            return kv[1].removingPercentEncoding ?? kv[1]
        }
        .first

    var sessionToken: String? = nil
    for line in lines {
        guard line.lowercased().hasPrefix("cookie:") else { continue }
        let cookieStr = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        for pair in cookieStr.components(separatedBy: ";") {
            let kv = pair.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
            if kv.count == 2, kv[0] == "session" { sessionToken = kv[1] }
        }
    }

    var body = ""
    if let range = text.range(of: "\r\n\r\n") {
        body = String(text[range.upperBound...])
    }

    return HTTPRequest(method: method, cleanPath: cleanPath,
                       connectToken: connectToken, sessionToken: sessionToken, body: body)
}

// MARK: - MJPEG Server

class MJPEGServer {

    /// Set before calling start(). Empty string = no auth required.
    var pin: String = ""

    /// One-time connect token validator. When set, direct URL access without a valid token returns 403.
    nonisolated(unsafe) var tokenValidator: ((String) async -> Bool)?

    private var listener: NWListener?

    nonisolated(unsafe) private var streamConnections: [NWConnection] = []
    nonisolated(unsafe) private var validSessions:     Set<String>    = []
    nonisolated let queue = DispatchQueue(label: "com.tinyviewer.mjpeg", qos: .userInitiated)

    nonisolated(unsafe) var onClientCountChanged: ((Int) -> Void)?

    // MARK: - Lifecycle

    func start() {
        validSessions.removeAll()
        do {
            listener = try NWListener(using: .tcp, on: 8080)
            listener?.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:         print("[MJPEGServer] Listening on :8080")
                case .failed(let e): print("[MJPEGServer] Listener failed: \(e)")
                default: break
                }
            }
            listener?.start(queue: queue)
        } catch {
            print("[MJPEGServer] Cannot create listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            self?.streamConnections.forEach { $0.cancel() }
            self?.streamConnections.removeAll()
            self?.validSessions.removeAll()
            self?.onClientCountChanged?(0)
        }
    }

    // MARK: - Accept & Route

    nonisolated private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 4, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { connection.cancel(); return }

            let req = parse(data)

            switch (req.method, req.cleanPath) {

            case ("GET", _) where req.cleanPath.hasPrefix("/stream"):
                if self.isAuthorized(req.sessionToken) {
                    self.handleStream(connection)
                } else {
                    self.redirectToRoot(connection)
                }

            case ("POST", "/auth"):
                self.handleAuth(connection, body: req.body)

            case ("POST", "/event"):
                if self.isAuthorized(req.sessionToken) {
                    self.handleInputEvent(connection, body: req.body)
                } else {
                    self.send401(connection)
                }

            case ("GET", _) where req.cleanPath.hasPrefix("/"):
                if let tok = req.connectToken {
                    self.handleTokenAuth(connection, token: tok)
                } else if self.isAuthorized(req.sessionToken) {
                    self.send200(connection, html: viewerHTML)
                } else if self.tokenValidator != nil {
                    // Token validation enabled — reject direct access without token
                    self.send403(connection)
                } else {
                    self.send200(connection, html: pinPageTemplate.replacingOccurrences(of: "%%ERROR%%", with: ""))
                }

            default:
                self.handle404(connection)
            }
        }
    }

    // MARK: - Auth

    nonisolated private func isAuthorized(_ token: String?) -> Bool {
        guard !pin.isEmpty else { return true }
        guard let token else { return false }
        return validSessions.contains(token)
    }

    nonisolated private func handleAuth(_ conn: NWConnection, body: String) {
        let submitted = body
            .components(separatedBy: "&")
            .compactMap { part -> String? in
                let kv = part.components(separatedBy: "=")
                guard kv.count == 2, kv[0] == "pin" else { return nil }
                return kv[1].removingPercentEncoding ?? kv[1]
            }
            .first ?? ""

        if pin.isEmpty || submitted == pin {
            let token = UUID().uuidString
            validSessions.insert(token)
            let response = [
                "HTTP/1.1 302 Found",
                "Location: /",
                "Set-Cookie: session=\(token); Path=/; HttpOnly",
                "Content-Length: 0",
                "Connection: close",
                "", ""
            ].joined(separator: "\r\n")
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        } else {
            let errDiv = "<p class=\"err\">Incorrect PIN. Try again.</p>"
            send200(conn, html: pinPageTemplate.replacingOccurrences(of: "%%ERROR%%", with: errDiv))
        }
    }

    // MARK: - Token Auth

    nonisolated private func handleTokenAuth(_ conn: NWConnection, token: String) {
        guard let validator = tokenValidator else {
            // No validator configured — fall back to normal flow
            send200(conn, html: pinPageTemplate.replacingOccurrences(of: "%%ERROR%%", with: ""))
            return
        }
        Task {
            let valid = await validator(token)
            if valid {
                let sessionTok = UUID().uuidString
                self.queue.async { self.validSessions.insert(sessionTok) }
                let response = [
                    "HTTP/1.1 302 Found",
                    "Location: /",
                    "Set-Cookie: session=\(sessionTok); Path=/; HttpOnly",
                    "Content-Length: 0",
                    "Connection: close",
                    "", ""
                ].joined(separator: "\r\n")
                conn.send(content: response.data(using: .utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            } else {
                self.send403(conn)
            }
        }
    }

    // MARK: - Input Events

    nonisolated private func handleInputEvent(_ conn: NWConnection, body: String) {
        if let data = body.data(using: .utf8) {
            // Accept both a single event object and a batched array of events
            if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                array.forEach { InputController.shared.handleEvent($0) }
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                InputController.shared.handleEvent(json)
            }
        }
        let response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - MJPEG Stream

    nonisolated private func handleStream(_ conn: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache\r\nPragma: no-cache\r\nConnection: keep-alive\r\n\r\n"
        conn.send(content: headers.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { conn.cancel(); return }
            self.queue.async {
                self.streamConnections.append(conn)
                self.onClientCountChanged?(self.streamConnections.count)
            }
        })
    }

    // MARK: - Response Helpers

    nonisolated private func send200(_ conn: NWConnection, html: String) {
        let body    = html.data(using: .utf8)!
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = headers.data(using: .utf8)!
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func redirectToRoot(_ conn: NWConnection) {
        let r = "HTTP/1.1 302 Found\r\nLocation: /\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func send401(_ conn: NWConnection) {
        let r = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func handle404(_ conn: NWConnection) {
        let r = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func send403(_ conn: NWConnection) {
        let r = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Broadcast

    nonisolated func broadcastFrame(_ jpeg: Data) {
        var frame = Data()
        frame.append("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".data(using: .utf8)!)
        frame.append(jpeg)
        frame.append("\r\n".data(using: .utf8)!)

        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.streamConnections {
                conn.send(content: frame, completion: .contentProcessed { [weak self] error in
                    if let error {
                        print("[MJPEGServer] Client dropped: \(error)")
                        self?.queue.async {
                            self?.streamConnections.removeAll { $0 === conn }
                            self?.onClientCountChanged?(self?.streamConnections.count ?? 0)
                        }
                    }
                })
            }
        }
    }
}
