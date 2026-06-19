import AppKit
import CoreGraphics

/// Injects text and files into the focused app: stash the pasteboard, write the
/// content, post a synthetic ⌘V, wait for paste completion, then restore the original pasteboard.
/// This uses the hidSystemState and cghidEventTap to ensure maximum compatibility.
final class TextInjector {
    private static let vKeyCode: CGKeyCode = 9
    private static let returnKeyCode: CGKeyCode = 36

    /// Injects text and optional file sequentially, restoring the pasteboard afterwards.
    func inject(_ text: String, fileURL: URL?, targetPID: pid_t? = nil) async {
        if !text.isEmpty {
            if SettingsController.isDirectInsert {
                if injectDirect(text) {
                    print("[INJECT] Direct text insertion succeeded")
                    if let fileURL = fileURL {
                        await injectFileOnly(fileURL, targetPID: targetPID)
                    }
                    return
                }
                print("[INJECT] Direct text insertion failed, falling back to pasteboard")
            } else {
                print("[INJECT] Direct text insertion disabled by settings, using pasteboard")
            }
        }

        let pasteboard = NSPasteboard.general

        // 1. Deep-copy current contents to restore later
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        // 2. Paste text if not empty
        if !text.isEmpty {
            print("[INJECT] Setting text on pasteboard: '\(text)'")
            pasteboard.clearContents()
            let wrote = pasteboard.setString(text, forType: .string)
            let landed = pasteboard.string(forType: .string) == text
            if !wrote || !landed {
                print("[INJECT] ⚠️ Pasteboard write failed (setString=\(wrote), readback matches=\(landed), changeCount=\(pasteboard.changeCount)). Paste may not work.")
            }

            // Let pasteboard register the change
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

            print("[INJECT] Posting Cmd+V for text")
            await self.postKeystroke(Self.vKeyCode, flags: .maskCommand, targetPID: targetPID)

            // Wait for target app to process text paste before we do anything else
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1000ms
        }

        // 3. Paste file if present
        if let fileURL = fileURL {
            print("[INJECT] Setting file URL on pasteboard: \(fileURL.path)")
            pasteboard.clearContents()
            pasteboard.writeObjects([fileURL as NSURL])

            // Let pasteboard register the change
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

            print("[INJECT] Posting Cmd+V for file")
            await self.postKeystroke(Self.vKeyCode, flags: .maskCommand, targetPID: targetPID)

            // Wait for target app to process file paste (files can take longer)
            try? await Task.sleep(nanoseconds: 1_200_000_000) // 1200ms
        }

        // 4. Restore original pasteboard contents
        print("[INJECT] Restoring original pasteboard")
        pasteboard.clearContents()
        if !saved.isEmpty {
            pasteboard.writeObjects(saved)
        }
    }

    private func injectDirect(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement as! AXUIElement? else {
            return false
        }
        
        let nsText = text as CFString
        let setAttrResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, nsText)
        return setAttrResult == .success
    }

    private func injectFileOnly(_ url: URL, targetPID: pid_t? = nil) async {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        print("[INJECT] Setting file URL on pasteboard: \(url.path)")
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])

        try? await Task.sleep(nanoseconds: 150_000_000)

        print("[INJECT] Posting Cmd+V for file (direct insert fallback)")
        await self.postKeystroke(Self.vKeyCode, flags: .maskCommand, targetPID: targetPID)

        try? await Task.sleep(nanoseconds: 1_200_000_000)

        print("[INJECT] Restoring original pasteboard (direct insert fallback)")
        pasteboard.clearContents()
        if !saved.isEmpty {
            pasteboard.writeObjects(saved)
        }
    }

    func pressReturn(targetPID: pid_t? = nil) async {
        await postKeystroke(Self.returnKeyCode, flags: [], targetPID: targetPID)
    }

    func pressSearchShortcut(_ type: SearchShortcutType, targetPID: pid_t? = nil) async {
        let fKeyCode: CGKeyCode = 3
        let lKeyCode: CGKeyCode = 37

        switch type {
        case .find:
            print("[INJECT] Posting Cmd+F shortcut")
            await postKeystroke(fKeyCode, flags: .maskCommand, targetPID: targetPID)
        case .location:
            print("[INJECT] Posting Cmd+L shortcut")
            await postKeystroke(lKeyCode, flags: .maskCommand, targetPID: targetPID)
        }
    }

    func grabActiveSelection(targetPID: pid_t? = nil) async -> String? {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // 1. Try native AXUIElement selection grab (extremely fast, no clipboard pollution)
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        if result == .success, let element = focusedElement as! AXUIElement? {
            var selectedTextValue: AnyObject?
            let selectedTextResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextValue)
            if selectedTextResult == .success, let selection = selectedTextValue as? String, !selection.isEmpty {
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                print("[BENCHMARK] Active selection grabbed natively via AXUIElement in \(String(format: "%.2f", duration * 1000))ms")
                return selection
            }
        }
        
        // 2. Fall back to simulated Cmd+C keyboard event & clipboard monitoring
        print("[INJECT] AXUIElement selection grab failed or empty; falling back to simulated Cmd+C")
        let pasteboard = NSPasteboard.general

        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pasteboard.clearContents()

        let cKeyCode: CGKeyCode = 8 // 'C' key code
        await postKeystroke(cKeyCode, flags: .maskCommand, targetPID: targetPID)

        // Wait up to 300ms for pasteboard update
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            if pasteboard.string(forType: .string) != nil {
                break
            }
        }

        let selectedText = pasteboard.string(forType: .string)

        // Restore pasteboard
        pasteboard.clearContents()
        if !saved.isEmpty {
            pasteboard.writeObjects(saved)
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        print("[BENCHMARK] Active selection grabbed via clipboard fallback in \(String(format: "%.2f", duration * 1000))ms")
        return selectedText
    }

    private func postKeystroke(_ keyCode: CGKeyCode, flags: CGEventFlags, targetPID: pid_t? = nil) async {
        // Use a PRIVATE event-state table, NOT .hidSystemState. Apple documents
        // .hidSystemState as reflecting "the combined state of all hardware event
        // sources from the HID system" — i.e. it merges modifier keys the user is
        // physically holding. In a push-to-talk app the hotkey (e.g. ⌘⇧K / ⌘⇧J) is
        // often still held when we inject, so the synthetic ⌘V inherits ⇧ and becomes
        // ⌘⇧V (paste-and-match-style) or a no-op — the classic reason paste "silently
        // fails". .privateState is an independent table unaffected by physical keys.
        let source = CGEventSource(stateID: .privateState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags // Command flag must match on up event to be a valid keystroke combination

        // Deliver the synthetic keystroke directly to the intended app when we know its
        // PID. Posting to the global HID tap (the old behaviour) races app re-activation:
        // if focus hasn't fully shifted back yet, ⌘V lands nowhere and the paste silently
        // fails — the classic "text shows in the menu but never pastes" bug. postToPid
        // targets the app regardless of the focus race.
        if let pid = targetPID {
            down.postToPid(pid)
            try? await Task.sleep(nanoseconds: 25_000_000) // 25ms delay for event registration
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 25_000_000) // 25ms delay for event registration
            up.post(tap: .cghidEventTap)
        }
    }
}
