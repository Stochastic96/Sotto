import Foundation
import AppKit
import ApplicationServices

public class ScreenParser {
    // AX-tree parsing only ever happens synchronously on the main thread (UI
    // automation), never concurrently — same assumption the code already made.
    nonisolated(unsafe) private static var elementCache: [Int: AXUIElement] = [:]
    nonisolated(unsafe) private static var nextId = 1

    /// Non-standard convenience attribute synthesized from position + size below.
    private static let frameAttr = "AXFrame"

    /// Reads an AX attribute, synthesizing the (non-standard) "AXFrame" rect from the
    /// element's separate position + size attributes. Scoped to ScreenParser so it does
    /// NOT shadow the system `AXUIElementCopyAttributeValue` for the rest of the target.
    private static func copyAttr(_ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<AnyObject?>) -> AXError {
        guard (attribute as String) == frameAttr else {
            return AXUIElementCopyAttributeValue(element, attribute, value)
        }
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        var position = CGPoint.zero
        var size = CGSize.zero

        let posStatus = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        let sizeStatus = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        if posStatus == .success, let posVal = posValue {
            AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        }
        if sizeStatus == .success, let sizeVal = sizeValue {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }

        var rect = CGRect(origin: position, size: size)
        if let rectValue = AXValueCreate(.cgRect, &rect) {
            value.pointee = rectValue as AnyObject
            return .success
        }
        return .failure
    }

    public static func clearCache() {
        elementCache.removeAll()
        nextId = 1
    }

    public static func captureActiveWindowTree() -> String {
        clearCache()
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "No active application found."
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedWindow: AnyObject?
        let status = copyAttr(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        let windowElement: AXUIElement
        if status == .success, let win = focusedWindow {
            windowElement = win as! AXUIElement
        } else {
            var windowsValue: AnyObject?
            if copyAttr(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let windows = windowsValue as? [AXUIElement], let first = windows.first {
                windowElement = first
            } else {
                return "No active window found for \(app.localizedName ?? "app")."
            }
        }

        var markup = "Active Window of \(app.localizedName ?? "App"):\n"
        traverse(element: windowElement, depth: 0, maxDepth: 8, markup: &markup)
        return markup
    }

    private static func traverse(element: AXUIElement, depth: Int, maxDepth: Int, markup: inout String) {
        guard depth <= maxDepth else { return }

        var roleValue: AnyObject?
        _ = copyAttr(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? "Unknown"

        var titleValue: AnyObject?
        _ = copyAttr(element, kAXTitleAttribute as CFString, &titleValue)
        let title = titleValue as? String

        var valValue: AnyObject?
        _ = copyAttr(element, kAXValueAttribute as CFString, &valValue)
        let value = valValue as? String

        var frameValue: AnyObject?
        var frame = CGRect.zero
        if copyAttr(element, frameAttr as CFString, &frameValue) == .success,
           let frameVal = frameValue {
            AXValueGetValue(frameVal as! AXValue, .cgRect, &frame)
        }

        let isInteractive = isInteractiveRole(role) || (role == "AXStaticText" && !(title ?? "").isEmpty)

        if isInteractive {
            let id = nextId
            elementCache[id] = element
            nextId += 1

            let label = title ?? ""
            let valStr = value != nil ? " Value: \"\(value!)\"" : ""
            markup += "[\(id)] \(role.replacingOccurrences(of: "AX", with: "")): \"\(label)\"\(valStr) [x: \(frame.origin.x), y: \(frame.origin.y), w: \(frame.size.width), h: \(frame.size.height)]\n"
        }

        var childrenValue: AnyObject?
        if copyAttr(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                traverse(element: child, depth: depth + 1, maxDepth: maxDepth, markup: &markup)
            }
        }
    }

    private static func isInteractiveRole(_ role: String) -> Bool {
        let roles = ["AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXComboBox"]
        return roles.contains(role)
    }

    public static func performClick(id: Int) -> Bool {
        guard let element = elementCache[id] else { return false }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return result == .success
    }

    public static func performSetValue(id: Int, value: String) -> Bool {
        guard let element = elementCache[id] else { return false }
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        return result == .success
    }
}
