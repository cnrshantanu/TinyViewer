import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Input Controller
// All methods are nonisolated — called from the MJPEG server's background queue.

final class InputController {

    static let shared = InputController()
    private init() {}

    // MARK: - Accessibility

    nonisolated static var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }

    nonisolated static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Event dispatch

    nonisolated func handleEvent(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        switch type {
        case "mousemove":
            guard let x = cgDouble(json["x"]), let y = cgDouble(json["y"]) else { return }
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                         mouseCursorPosition: screenPoint(x, y), mouseButton: .left))

        case "mousedown":
            guard let x = cgDouble(json["x"]), let y = cgDouble(json["y"]) else { return }
            let (type, btn) = mouseTypes(button: json["button"] as? Int ?? 0, down: true)
            post(CGEvent(mouseEventSource: nil, mouseType: type,
                         mouseCursorPosition: screenPoint(x, y), mouseButton: btn))

        case "mouseup":
            guard let x = cgDouble(json["x"]), let y = cgDouble(json["y"]) else { return }
            let (type, btn) = mouseTypes(button: json["button"] as? Int ?? 0, down: false)
            post(CGEvent(mouseEventSource: nil, mouseType: type,
                         mouseCursorPosition: screenPoint(x, y), mouseButton: btn))

        case "wheel":
            let dy = cgDouble(json["dy"]) ?? 0
            let dx = cgDouble(json["dx"]) ?? 0
            // Convert pixel delta → discrete line units; clamp to avoid huge jumps
            let v = Int32(clamping: Int(-dy / 8))
            let h = Int32(clamping: Int(-dx / 8))
            post(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                         wheelCount: 2, wheel1: v, wheel2: h, wheel3: 0))

        case "keydown":
            handleKey(json, keyDown: true)

        case "keyup":
            handleKey(json, keyDown: false)

        default:
            break
        }
    }

    // MARK: - Helpers

    nonisolated private func screenPoint(_ normX: CGFloat, _ normY: CGFloat) -> CGPoint {
        let b = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: b.origin.x + normX * b.width,
                       y: b.origin.y + normY * b.height)
    }

    nonisolated private func mouseTypes(button: Int, down: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case 2:  return down ? (.rightMouseDown, .right)  : (.rightMouseUp, .right)
        case 1:  return down ? (.otherMouseDown, .center) : (.otherMouseUp, .center)
        default: return down ? (.leftMouseDown,  .left)   : (.leftMouseUp,  .left)
        }
    }

    nonisolated private func handleKey(_ json: [String: Any], keyDown: Bool) {
        let key    = json["key"]   as? String ?? ""
        let code   = json["code"]  as? String ?? ""
        let shift  = json["shift"] as? Bool   ?? false
        let meta   = json["meta"]  as? Bool   ?? false
        let alt    = json["alt"]   as? Bool   ?? false
        let ctrl   = json["ctrl"]  as? Bool   ?? false

        var flags: CGEventFlags = []
        if shift { flags.insert(.maskShift) }
        if meta  { flags.insert(.maskCommand) }
        if alt   { flags.insert(.maskAlternate) }
        if ctrl  { flags.insert(.maskControl) }

        // Prefer physical key code (e.code) so Cmd+C/V/Z/A etc. trigger the correct
        // Mac shortcut. Fall back to special-key table, then unicode injection.
        if let keyCode = physicalKeyCode(for: code) ?? specialKeyCode(for: key) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            post(event)
        } else if keyDown, !key.isEmpty, key.count == 1 {
            // Printable character with no known key code → unicode injection
            let chars = Array(key.utf16)
            let dn = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            dn?.flags = flags
            dn?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            post(dn)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.flags = flags
            post(up)
        }
    }

    // Maps browser KeyboardEvent.code → macOS virtual key code (US QWERTY layout).
    // Using physical codes means Cmd+C/V/Z/A always hit the right Mac shortcut
    // regardless of what character that key produces.
    nonisolated private func physicalKeyCode(for code: String) -> CGKeyCode? {
        let table: [String: CGKeyCode] = [
            "KeyA": 0,  "KeyS": 1,  "KeyD": 2,  "KeyF": 3,  "KeyH": 4,
            "KeyG": 5,  "KeyZ": 6,  "KeyX": 7,  "KeyC": 8,  "KeyV": 9,
            "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14, "KeyR": 15,
            "KeyY": 16, "KeyT": 17, "KeyU": 32, "KeyI": 34, "KeyO": 31,
            "KeyP": 35, "KeyL": 37, "KeyJ": 38, "KeyK": 40, "KeyN": 45,
            "KeyM": 46,
            "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit5": 23,
            "Digit6": 22, "Digit7": 26, "Digit8": 28, "Digit9": 25, "Digit0": 29,
            "Minus": 27, "Equal": 24, "BracketLeft": 33, "BracketRight": 30,
            "Backslash": 42, "Semicolon": 41, "Quote": 39, "Comma": 43,
            "Period": 47, "Slash": 44, "Backquote": 50,
        ]
        return table[code]
    }

    /// Releases all mouse buttons and modifier keys — call when a new WebSocket session
    /// connects so any stuck state from the previous session is cleared on the Mac side.
    nonisolated func releaseAll() {
        let b  = CGDisplayBounds(CGMainDisplayID())
        let pt = CGPoint(x: b.midX, y: b.midY)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,  mouseCursorPosition: pt, mouseButton: .left))
        post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: pt, mouseButton: .right))
        post(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: pt, mouseButton: .center))
        for keyCode: CGKeyCode in [56, 59, 58, 55] { // Shift, Control, Alt, Meta
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
            post(event)
        }
    }

    nonisolated private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    nonisolated private func cgDouble(_ v: Any?) -> CGFloat? {
        if let d = v as? Double  { return CGFloat(d) }
        if let i = v as? Int     { return CGFloat(i) }
        return nil
    }

    // MARK: - Key code table

    nonisolated private func specialKeyCode(for key: String) -> CGKeyCode? {
        let table: [String: CGKeyCode] = [
            // Editing
            "Backspace": 51, "Delete": 117,
            "Enter": 36, "Return": 36,
            "Tab": 48, "Escape": 53,
            " ": 49,

            // Navigation
            "ArrowLeft": 123, "ArrowRight": 124,
            "ArrowDown": 125, "ArrowUp": 126,
            "Home": 115, "End": 119,
            "PageUp": 116, "PageDown": 121,

            // Function keys
            "F1": 122, "F2": 120, "F3": 99,  "F4": 118,
            "F5": 96,  "F6": 97,  "F7": 98,  "F8": 100,
            "F9": 101, "F10": 109, "F11": 103, "F12": 111,

            // Modifiers (standalone presses)
            "Shift": 56, "Control": 59, "Alt": 58, "Meta": 55,
            "CapsLock": 57,

            // Number row (US layout) — must use real vk codes or unicode injection
            // is ignored by many apps because vk=0 conflicts with the character
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
            "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,

            // Common punctuation (US layout)
            "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42,
            ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "`": 50,
        ]
        return table[key]
    }
}

// MARK: - Int clamping to Int32

private extension Int32 {
    init(clamping value: Int) {
        self = value < Int(Int32.min) ? .min : value > Int(Int32.max) ? .max : Int32(value)
    }
}
