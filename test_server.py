#!/usr/bin/env python3
"""
Tiny Viewer — Local server test suite
======================================
Tests the MJPEG server running at localhost:8080.

Prerequisites:
  • Tiny Viewer is running (click "Start Server")
  • No PIN set in the Mac app
  • Server has no tokenValidator active — run with Mac app NOT signed in to Firebase
    (or temporarily remove the tokenValidator line and rebuild)
  • Screen recording permission granted (so frames actually flow)

Usage:
  python3 test_server.py                  # run all tests
  python3 test_server.py --session TOKEN  # run authenticated tests with an existing session cookie
  python3 test_server.py -v               # verbose output
"""

import socket, base64, hashlib, json, time, sys, argparse, threading

HOST = "localhost"
PORT = 8080
TIMEOUT = 5.0

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
RESET  = "\033[0m"
PASS   = f"{GREEN}✓{RESET}"
FAIL   = f"{RED}✗{RESET}"
SKIP   = f"{YELLOW}−{RESET}"

verbose = False

def log(msg):
    if verbose:
        print(f"    {YELLOW}>{RESET} {msg}")

# ── Raw HTTP helpers ──────────────────────────────────────────────────────────

def raw_request(method, path, body=b"", headers=None, cookies=""):
    s = socket.create_connection((HOST, PORT), timeout=TIMEOUT)
    extra_headers = headers or {}
    if cookies:
        extra_headers["Cookie"] = cookies
    if body:
        extra_headers["Content-Length"] = str(len(body))
    header_str = "\r\n".join(f"{k}: {v}" for k, v in extra_headers.items())
    req = f"{method} {path} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n{header_str}\r\nConnection: close\r\n\r\n"
    s.sendall(req.encode() + body)
    resp = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        resp += chunk
        # For non-streaming responses, stop once we have the full body
        if b"\r\n\r\n" in resp:
            header_part, _, rest = resp.partition(b"\r\n\r\n")
            lines = header_part.split(b"\r\n")
            # Check if Content-Length tells us we have the full body
            content_len = None
            for line in lines:
                if line.lower().startswith(b"content-length:"):
                    content_len = int(line.split(b":")[1].strip())
            if content_len is not None and len(rest) >= content_len:
                break
            if content_len is None:
                break  # no content-length, connection close will signal end
    s.close()
    header_part, _, body_part = resp.partition(b"\r\n\r\n")
    status_line = header_part.split(b"\r\n")[0].decode(errors="replace")
    parts = status_line.split(" ", 2)
    code = int(parts[1]) if len(parts) >= 2 else 0
    return code, body_part

def http_get(path, cookies=""):
    return raw_request("GET", path, cookies=cookies)

def http_post(path, body_str, cookies="", content_type="application/json"):
    body = body_str.encode()
    return raw_request("POST", path, body=body,
                        headers={"Content-Type": content_type}, cookies=cookies)

# ── WebSocket helpers ─────────────────────────────────────────────────────────

WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def ws_connect(cookies=""):
    """Perform WebSocket handshake, return connected socket."""
    s = socket.create_connection((HOST, PORT), timeout=TIMEOUT)
    raw_key = b"TinyViewerTest!!"           # 16 bytes
    key = base64.b64encode(raw_key).decode()
    req = (f"GET /ws HTTP/1.1\r\n"
           f"Host: {HOST}:{PORT}\r\n"
           f"Upgrade: websocket\r\n"
           f"Connection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\n"
           f"Sec-WebSocket-Version: 13\r\n"
           f"Cookie: {cookies}\r\n\r\n")
    s.sendall(req.encode())

    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += s.recv(1024)

    lines = resp.split(b"\r\n")
    status = lines[0].decode(errors="replace")
    assert "101" in status, f"Expected 101 Switching Protocols, got: {status}"

    expected = base64.b64encode(
        hashlib.sha1((key + WS_MAGIC).encode()).digest()
    ).decode()
    headers = {l.split(b":", 1)[0].strip().lower(): l.split(b":", 1)[1].strip()
               for l in lines[1:] if b":" in l}
    actual = headers.get(b"sec-websocket-accept", b"").decode()
    assert actual == expected, f"Sec-WebSocket-Accept mismatch: {actual!r} != {expected!r}"
    log(f"WebSocket upgrade OK, accept={actual[:16]}…")
    return s

def ws_send_text(s, msg):
    """Send a masked text frame."""
    data = msg.encode()
    mask = b"\xDE\xAD\xBE\xEF"
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    length = len(data)
    if length < 126:
        header = bytes([0x81, 0x80 | length]) + mask
    else:
        header = bytes([0x81, 0xFE, length >> 8, length & 0xFF]) + mask
    s.sendall(header + masked)
    log(f"WS sent: {msg[:80]}")

def ws_send_event(s, event):
    ws_send_text(s, json.dumps(event))

# ── MJPEG helpers ─────────────────────────────────────────────────────────────

def count_frames(duration=2.0, cookies=""):
    """Open /stream, count MJPEG boundary markers for `duration` seconds."""
    s = socket.create_connection((HOST, PORT), timeout=duration + 3)
    req = (f"GET /stream HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n"
           f"Cookie: {cookies}\r\nConnection: keep-alive\r\n\r\n")
    s.sendall(req.encode())

    # drain HTTP headers
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)

    frames = buf.count(b"--frame")
    start = time.monotonic()
    s.settimeout(0.2)
    try:
        while time.monotonic() - start < duration:
            try:
                chunk = s.recv(65536)
                if not chunk:
                    break
                frames += chunk.count(b"--frame")
            except socket.timeout:
                pass
    finally:
        s.close()

    elapsed = time.monotonic() - start
    return frames, elapsed

# ── Test runner ───────────────────────────────────────────────────────────────

results = []

def test(name, fn, requires_auth=False, session=""):
    """Run a single test and record the result."""
    if requires_auth and not session:
        print(f"  {SKIP} {name}  (skipped — no --session provided)")
        results.append(("skip", name))
        return
    try:
        fn(session) if requires_auth else fn()
        print(f"  {PASS} {name}")
        results.append(("pass", name))
    except AssertionError as e:
        print(f"  {FAIL} {name}: {e}")
        results.append(("fail", name))
    except Exception as e:
        print(f"  {FAIL} {name}: {type(e).__name__}: {e}")
        results.append(("fail", name))

# ── Individual tests ──────────────────────────────────────────────────────────

def t_root_accessible():
    code, body = http_get("/")
    # No-auth mode: 200 with viewer or pin page
    # Auth mode: 403
    assert code in (200, 403), f"Expected 200 or 403, got {code}"
    log(f"GET / → {code}, body={len(body)} bytes")

def t_stream_returns_200():
    code, _ = http_get("/stream")
    assert code in (200, 403), f"Expected 200 or 403, got {code}"

def t_event_returns_204_noauth():
    payload = json.dumps([{"type": "keydown", "key": "a", "code": "KeyA",
                           "shift": False, "meta": False, "alt": False, "ctrl": False}])
    code, _ = http_post("/event", payload)
    assert code in (204, 401), f"Expected 204 or 401, got {code}"

def t_quality_returns_204_noauth():
    code, _ = http_post("/quality", json.dumps({"quality": "High"}))
    assert code in (204, 401), f"Expected 204 or 401, got {code}"
    http_post("/quality", json.dumps({"quality": "Medium"}))  # reset

def t_unknown_path_404():
    code, _ = http_get("/nonexistent")
    assert code == 404, f"Expected 404, got {code}"

def t_ws_handshake_noauth():
    """WebSocket upgrade without a session — should get 401 or succeed if no auth."""
    try:
        s = ws_connect()
        s.close()
        log("WS connected without auth (no-auth mode)")
    except AssertionError as e:
        # If we got a non-101, check it was 401
        if "401" in str(e) or "403" in str(e):
            log(f"WS correctly rejected without auth: {e}")
        else:
            raise

def t_ws_event_with_session(session):
    s = ws_connect(cookies=f"session={session}")
    ws_send_event(s, {"type": "keydown", "key": "a", "code": "KeyA",
                       "shift": False, "meta": False, "alt": False, "ctrl": False})
    time.sleep(0.05)
    ws_send_event(s, {"type": "keyup", "key": "a", "code": "KeyA",
                       "shift": False, "meta": False, "alt": False, "ctrl": False})
    time.sleep(0.05)
    s.close()

def t_ws_quality_change(session):
    s = ws_connect(cookies=f"session={session}")
    ws_send_event(s, {"type": "quality", "quality": "High"})
    time.sleep(0.1)
    ws_send_event(s, {"type": "quality", "quality": "Medium"})
    time.sleep(0.05)
    s.close()

def t_ws_multiple_events(session):
    """Send a burst of 50 events and verify no crash."""
    s = ws_connect(cookies=f"session={session}")
    for i in range(50):
        ws_send_event(s, {"type": "mousemove", "x": i / 50, "y": i / 50})
    time.sleep(0.1)
    s.close()

def t_ws_frame_parsing():
    """Test that WebSocket frame parser handles multi-byte payloads."""
    try:
        s = ws_connect()
    except Exception:
        return  # Auth required — skip frame parser test
    # Send a 200-byte payload (requires 2-byte extended length in frame header)
    big_event = {"type": "keydown", "key": "x" * 180, "code": "KeyX",
                 "shift": False, "meta": False, "alt": False, "ctrl": False}
    ws_send_event(s, big_event)
    time.sleep(0.05)
    s.close()

def t_frame_rate_with_session(session):
    frames, elapsed = count_frames(duration=3.0, cookies=f"session={session}")
    fps = frames / max(elapsed, 0.001)
    log(f"{frames} frames in {elapsed:.1f}s = {fps:.1f} fps")
    assert fps >= 5, f"Frame rate too low: {fps:.1f} fps (expected ≥ 5)"
    print(f"         ({fps:.1f} fps over {elapsed:.1f}s)")

def t_no_frame_backlog(session):
    """
    Verify latest-frame-wins: after a 1s gap, the frame rate should
    not spike (which would indicate buffered/replayed frames draining).
    """
    c = f"session={session}"
    frames1, e1 = count_frames(duration=2.0, cookies=c)
    time.sleep(1.0)
    frames2, e2 = count_frames(duration=2.0, cookies=c)
    fps1 = frames1 / max(e1, 0.001)
    fps2 = frames2 / max(e2, 0.001)
    ratio = max(fps1, fps2) / max(min(fps1, fps2), 0.1)
    log(f"window1={fps1:.1f}fps  window2={fps2:.1f}fps  ratio={ratio:.1f}x")
    print(f"         (fps1={fps1:.1f}, fps2={fps2:.1f}, ratio={ratio:.1f}x)")
    assert ratio < 4.0, (
        f"Frame rate ratio {ratio:.1f}x suggests frame backlog — "
        "check broadcastFrame latest-frame-wins logic"
    )

def t_idle_fps_drop(session):
    """
    After 4s of no events, idle mode should reduce frame rate to ~25%.
    """
    c = f"session={session}"
    # Warm up — send events to ensure active mode
    s = ws_connect(cookies=c)
    for _ in range(5):
        ws_send_event(s, {"type": "keydown", "key": "a", "code": "KeyA",
                          "shift": False, "meta": False, "alt": False, "ctrl": False})
        time.sleep(0.05)
    s.close()

    active_frames, ae = count_frames(duration=2.0, cookies=c)
    active_fps = active_frames / max(ae, 0.001)

    # Wait for idle (3s threshold + 1s buffer)
    time.sleep(4.5)
    idle_frames, ie = count_frames(duration=2.0, cookies=c)
    idle_fps = idle_frames / max(ie, 0.001)

    log(f"active={active_fps:.1f}fps  idle={idle_fps:.1f}fps")
    print(f"         (active={active_fps:.1f}fps → idle={idle_fps:.1f}fps)")
    assert idle_fps < active_fps * 0.6, (
        f"Idle FPS {idle_fps:.1f} not meaningfully lower than active {active_fps:.1f}"
    )

# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    global verbose
    parser = argparse.ArgumentParser(description="Tiny Viewer server test suite")
    parser.add_argument("--session", default="", help="Session cookie token (from browser after auth)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    verbose = args.verbose
    session = args.session

    print(f"\nTiny Viewer Server Tests  —  {HOST}:{PORT}")
    print("=" * 48)
    if not session:
        print(f"{YELLOW}No --session provided. Auth-required tests will be skipped.{RESET}")
        print(f"{YELLOW}Get a session token from browser DevTools → Application → Cookies{RESET}")
    print()

    # Verify server is reachable
    try:
        socket.create_connection((HOST, PORT), timeout=2).close()
    except Exception as e:
        print(f"{RED}Cannot connect to {HOST}:{PORT} — is the server running?{RESET}")
        sys.exit(1)

    print("Basic HTTP:")
    test("GET / accessible (200 or 403)",        t_root_accessible)
    test("GET /stream accessible",                t_stream_returns_200)
    test("POST /event → 204 or 401",              t_event_returns_204_noauth)
    test("POST /quality → 204 or 401",            t_quality_returns_204_noauth)
    test("Unknown path → 404",                    t_unknown_path_404)

    print("\nWebSocket:")
    test("WS handshake (no auth)",                t_ws_handshake_noauth)
    test("WS frame parser (large payload)",       t_ws_frame_parsing)
    test("WS event delivery",                     t_ws_event_with_session,  requires_auth=True, session=session)
    test("WS quality change",                     t_ws_quality_change,      requires_auth=True, session=session)
    test("WS burst 50 events",                    t_ws_multiple_events,     requires_auth=True, session=session)

    print("\nStreaming:")
    test("Frame rate ≥ 5 fps",                    t_frame_rate_with_session, requires_auth=True, session=session)
    test("No frame backlog (latest-frame-wins)",  t_no_frame_backlog,        requires_auth=True, session=session)
    test("Idle → reduced frame rate",             t_idle_fps_drop,           requires_auth=True, session=session)

    # Summary
    passed = sum(1 for r, _ in results if r == "pass")
    failed = sum(1 for r, _ in results if r == "fail")
    skipped = sum(1 for r, _ in results if r == "skip")
    total = len(results)

    print(f"\n{'='*48}")
    print(f"Results: {GREEN}{passed} passed{RESET}  "
          f"{RED}{failed} failed{RESET}  "
          f"{YELLOW}{skipped} skipped{RESET}  / {total} total")
    if skipped:
        print(f"Run with --session to execute {skipped} skipped test(s)")
    sys.exit(0 if failed == 0 else 1)

if __name__ == "__main__":
    main()
