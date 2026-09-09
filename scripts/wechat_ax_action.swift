import AppKit
import ApplicationServices
import Foundation

let bundleID = "com.tencent.xinWeChat"

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    fputs("WeChat is not running\n", stderr)
    exit(2)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)

func copyAttr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

func stringAttr(_ element: AXUIElement, _ key: String) -> String {
    guard let value = copyAttr(element, key) else { return "" }
    return String(describing: value).replacingOccurrences(of: "\n", with: "\\n")
}

func childElements(_ element: AXUIElement) -> [AXUIElement] {
    if let value = copyAttr(element, kAXChildrenAttribute as String) as? [AXUIElement] { return value }
    return []
}

func allDescendants(_ root: AXUIElement, limit: Int = 3000) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue = childElements(root)
    while !queue.isEmpty && result.count < limit {
        let element = queue.removeFirst()
        result.append(element)
        queue.append(contentsOf: childElements(element))
    }
    return result
}

func find(role: String? = nil, title: String? = nil, identifier: String? = nil) -> AXUIElement? {
    for element in allDescendants(axApp) {
        if let role, stringAttr(element, kAXRoleAttribute as String) != role { continue }
        if let title, stringAttr(element, kAXTitleAttribute as String) != title { continue }
        if let identifier, stringAttr(element, kAXIdentifierAttribute as String) != identifier { continue }
        return element
    }
    return nil
}

func findWithin(_ root: AXUIElement, role: String? = nil, title: String? = nil, identifier: String? = nil) -> AXUIElement? {
    for element in allDescendants(root) {
        if let role, stringAttr(element, kAXRoleAttribute as String) != role { continue }
        if let title, stringAttr(element, kAXTitleAttribute as String) != title { continue }
        if let identifier, stringAttr(element, kAXIdentifierAttribute as String) != identifier { continue }
        return element
    }
    return nil
}

func key(_ virtualKey: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(60_000)
    up?.post(tap: .cghidEventTap)
    usleep(100_000)
}

func pointAttr(_ element: AXUIElement, _ key: String) -> CGPoint? {
    guard let raw = copyAttr(element, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = unsafeBitCast(raw, to: AXValue.self)
    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

func sizeAttr(_ element: AXUIElement, _ key: String) -> CGSize? {
    guard let raw = copyAttr(element, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = unsafeBitCast(raw, to: AXValue.self)
    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}

func focusedElement() -> AXUIElement? {
    return copyAttr(axApp, kAXFocusedUIElementAttribute as String) as! AXUIElement?
}

func searchFieldHasFocus() -> Bool {
    guard let focused = focusedElement() else { return false }
    return stringAttr(focused, kAXRoleAttribute as String) == (kAXTextAreaRole as String) &&
        stringAttr(focused, kAXTitleAttribute as String) == "搜索" &&
        stringAttr(focused, kAXIdentifierAttribute as String) != "chat_input_field"
}

func parentElement(_ element: AXUIElement) -> AXUIElement? {
    return copyAttr(element, kAXParentAttribute as String) as! AXUIElement?
}

func elementSummary(_ element: AXUIElement) -> String {
    let p = pointAttr(element, kAXPositionAttribute as String) ?? .zero
    let s = sizeAttr(element, kAXSizeAttribute as String) ?? .zero
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    let actions = (names as? [String]) ?? []
    return "role=\(stringAttr(element, kAXRoleAttribute as String)) title=\(stringAttr(element, kAXTitleAttribute as String)) value=\(stringAttr(element, kAXValueAttribute as String)) id=\(stringAttr(element, kAXIdentifierAttribute as String)) pos=\(Int(p.x)),\(Int(p.y)) size=\(Int(s.width))x\(Int(s.height)) actions=\(actions.joined(separator: ","))"
}

func localContactSearchResults() -> [AXUIElement] {
    guard let list = find(identifier: "search_list") else { return [] }
    let elements = allDescendants(list)
    let contactHeaderTitles: Set<String> = ["联系人", "最常使用"]
    guard let header = elements.first(where: {
        stringAttr($0, kAXRoleAttribute as String) == (kAXStaticTextRole as String) &&
        contactHeaderTitles.contains(stringAttr($0, kAXTitleAttribute as String))
    }), let headerPosition = pointAttr(header, kAXPositionAttribute as String) else { return [] }
    let sectionTitles: Set<String> = ["群聊", "聊天记录", "公众号", "小程序", "搜索网络结果"]
    let nextSectionY = elements.compactMap { element -> CGFloat? in
        let title = stringAttr(element, kAXTitleAttribute as String)
        guard sectionTitles.contains(title),
              let p = pointAttr(element, kAXPositionAttribute as String),
              p.y > headerPosition.y else { return nil }
        return p.y
    }.min() ?? .greatestFiniteMagnitude
    return elements.filter {
        let identifier = stringAttr($0, kAXIdentifierAttribute as String)
        guard identifier.hasPrefix("search_item_"),
              let p = pointAttr($0, kAXPositionAttribute as String) else { return false }
        return p.y > headerPosition.y && p.y < nextSectionY
    }
}

func click(_ element: AXUIElement) -> Bool {
    guard let position = pointAttr(element, kAXPositionAttribute as String),
          let size = sizeAttr(element, kAXSizeAttribute as String) else { return false }
    let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    usleep(80_000)
    up?.post(tap: .cghidEventTap)
    return true
}

func clickAt(_ element: AXUIElement, xFraction: CGFloat, yFraction: CGFloat = 0.5) -> Bool {
    guard let position = pointAttr(element, kAXPositionAttribute as String),
          let size = sizeAttr(element, kAXSizeAttribute as String) else { return false }
    let point = CGPoint(
        x: position.x + size.width * xFraction,
        y: position.y + size.height * yFraction
    )
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    usleep(80_000)
    up?.post(tap: .cghidEventTap)
    return true
}

func enterSearch(_ text: String) -> AXUIElement? {
    guard let window = find(role: kAXWindowRole as String, title: "微信"),
          let field = findWithin(window, role: kAXTextAreaRole as String, title: "搜索") else { return nil }
    app.activate(options: [.activateAllWindows])
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    guard click(field) else { return nil }
    Thread.sleep(forTimeInterval: 0.3)
    guard searchFieldHasFocus() else { return nil }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    key(0x00, flags: .maskCommand) // Command-A
    key(0x33) // Delete the previous query so an identical search retriggers.
    key(0x09, flags: .maskCommand) // Command-V
    Thread.sleep(forTimeInterval: 2.5)
    return field
}

func waitFor(role: String? = nil, title: String? = nil, identifier: String? = nil, timeout: TimeInterval = 6.0) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let element = find(role: role, title: title, identifier: identifier) { return element }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    return nil
}

func frequencyWarning() -> String? {
    let needles = ["操作太频繁", "操作频繁", "过于频繁", "频率过快", "请稍后再试"]
    for element in allDescendants(axApp) {
        let text = [
            stringAttr(element, kAXTitleAttribute as String),
            stringAttr(element, kAXValueAttribute as String),
            stringAttr(element, kAXDescriptionAttribute as String),
        ].joined(separator: " ")
        if needles.contains(where: { text.contains($0) }) {
            return text
        }
    }
    return nil
}

@discardableResult
func paste(_ text: String, into element: AXUIElement) -> Bool {
    let focusError = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard focusError == .success else { return false }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    key(0x00, flags: .maskCommand)
    key(0x09, flags: .maskCommand)
    let deadline = Date().addingTimeInterval(1.8)
    repeat {
        if stringAttr(element, kAXValueAttribute as String) == text { return true }
        Thread.sleep(forTimeInterval: 0.15)
    } while Date() < deadline
    return false
}

guard CommandLine.arguments.count >= 2 else {
    fputs("commands: search TEXT | press-title TITLE | press-id IDENTIFIER | read-matches TEXT | actions-title TITLE\n", stderr)
    exit(2)
}

let command = CommandLine.arguments[1]

switch command {
case "check-friend":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let query = CommandLine.arguments[2]
    if let warning = frequencyWarning() {
        let payload: [String: Any] = ["result": "rate_limit", "warning": warning]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        print(String(data: data, encoding: .utf8)!)
        exit(70)
    }
    guard let field = enterSearch(query),
          stringAttr(field, kAXValueAttribute as String) == query else {
        let payload: [String: Any] = ["result": "search_error", "reason": "focus_or_readback"]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        print(String(data: data, encoding: .utf8)!)
        exit(123)
    }
    if let warning = frequencyWarning() {
        let payload: [String: Any] = ["result": "rate_limit", "warning": warning]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        print(String(data: data, encoding: .utf8)!)
        exit(70)
    }
    let titles = localContactSearchResults().map {
        stringAttr($0, kAXTitleAttribute as String)
    }
    let payload: [String: Any] = [
        "result": "friend_check",
        "localCount": titles.count,
        "titles": titles,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    print(String(data: data, encoding: .utf8)!)

case "greet-current-chat":
    guard CommandLine.arguments.count >= 4 else { exit(2) }
    let expectedRemark = CommandLine.arguments[2]
    let greeting = CommandLine.arguments[3]
    guard let mainWindow = find(role: kAXWindowRole as String, title: "微信"),
          let currentName = findWithin(mainWindow, identifier: "current_chat_name_label"),
          stringAttr(currentName, kAXValueAttribute as String) == expectedRemark,
          let input = findWithin(mainWindow, role: kAXTextAreaRole as String, identifier: "chat_input_field"),
          let sendButton = findWithin(mainWindow, role: kAXButtonRole as String, title: "发送") else {
        fputs("Exact current chat not ready\n", stderr)
        exit(117)
    }
    let alreadyGreeted = allDescendants(mainWindow).contains {
        stringAttr($0, kAXTitleAttribute as String) == greeting ||
        stringAttr($0, kAXValueAttribute as String) == greeting
    }
    if alreadyGreeted {
        print("RESULT=GREETING_ALREADY_PRESENT REMARK=\(expectedRemark)")
        exit(0)
    }
    guard stringAttr(input, kAXValueAttribute as String).isEmpty else {
        print("RESULT=CHAT_DRAFT_NOT_EMPTY")
        exit(0)
    }
    app.activate(options: [.activateAllWindows])
    AXUIElementPerformAction(mainWindow, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.25)
    if focusedElement().map({ stringAttr($0, kAXIdentifierAttribute as String) }) != "chat_input_field" {
        guard clickAt(input, xFraction: 0.08) else { exit(118) }
        Thread.sleep(forTimeInterval: 0.35)
    }
    guard let focused = focusedElement(),
          stringAttr(focused, kAXIdentifierAttribute as String) == "chat_input_field",
          stringAttr(currentName, kAXValueAttribute as String) == expectedRemark else {
        let detail = focusedElement().map { elementSummary($0) } ?? "none"
        fputs("Chat-input focus verification failed; focused=\(detail); no greeting entered\n", stderr)
        exit(119)
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(greeting, forType: .string)
    key(0x00, flags: .maskCommand)
    key(0x33)
    key(0x09, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 0.5)
    guard stringAttr(input, kAXValueAttribute as String) == greeting,
          stringAttr(currentName, kAXValueAttribute as String) == expectedRemark else {
        fputs("Greeting readback mismatch; not sending\n", stderr)
        exit(120)
    }
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT WARNING=\(warning)")
        exit(70)
    }
    guard click(sendButton) else { exit(121) }
    Thread.sleep(forTimeInterval: 1.0)
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT_AFTER_SEND WARNING=\(warning)")
        exit(70)
    }
    let bubbleFound = allDescendants(mainWindow).contains {
        stringAttr($0, kAXTitleAttribute as String) == greeting ||
        stringAttr($0, kAXValueAttribute as String) == greeting
    }
    guard stringAttr(input, kAXValueAttribute as String).isEmpty || bubbleFound else {
        fputs("Greeting send outcome unconfirmed\n", stderr)
        exit(122)
    }
    print("RESULT=GREETING_SENT REMARK=\(expectedRemark)")

case "process-existing-friend":
    guard CommandLine.arguments.count >= 5 else { exit(2) }
    let contact = CommandLine.arguments[2]
    let expectedRemark = CommandLine.arguments[3]
    let greeting = CommandLine.arguments[4]
    let expectedAccount = CommandLine.arguments.count >= 6 ? CommandLine.arguments[5] : contact
    let expectedName = CommandLine.arguments.count >= 7 ? CommandLine.arguments[6] : ""
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT WARNING=\(warning)")
        exit(70)
    }
    guard enterSearch(contact) != nil else {
        fputs("Verified main search failed\n", stderr)
        exit(100)
    }
    let contacts = localContactSearchResults()
    guard contacts.count == 1 else {
        print("RESULT=NOT_EXISTING_FRIEND LOCAL_MATCHES=\(contacts.count)")
        exit(0)
    }
    let currentTitle = stringAttr(contacts[0], kAXTitleAttribute as String)
    guard click(contacts[0]) else { exit(101) }
    let chatOpenDeadline = Date().addingTimeInterval(6.0)
    var opened = false
    repeat {
        if let current = find(identifier: "current_chat_name_label") {
            let value = stringAttr(current, kAXValueAttribute as String)
            opened = value == currentTitle || value == expectedRemark
        }
        if opened { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < chatOpenDeadline
    guard opened else {
        fputs("Existing-friend chat did not open\n", stderr)
        exit(102)
    }
    var member: AXUIElement?
    let existingPanelDeadline = Date().addingTimeInterval(1.0)
    repeat {
        if let candidate = find(identifier: "single_chat_member_cell") {
            let title = stringAttr(candidate, kAXTitleAttribute as String)
            if title == currentTitle || title == expectedRemark { member = candidate }
        }
        if member != nil { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < existingPanelDeadline
    if member == nil {
        guard let more = find(identifier: "more_button"), click(more) else {
            fputs("Chat-info button did not open\n", stderr)
            exit(102)
        }
        let memberDeadline = Date().addingTimeInterval(4.0)
        repeat {
            if let candidate = find(identifier: "single_chat_member_cell") {
                let title = stringAttr(candidate, kAXTitleAttribute as String)
                if title == currentTitle || title == expectedRemark { member = candidate }
            }
            if member != nil { break }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < memberDeadline
    }
    guard let member, click(member) else {
        fputs("Existing-friend profile entry did not open\n", stderr)
        exit(103)
    }
    let profileDeadline = Date().addingTimeInterval(6.0)
    var identityMatched = false
    repeat {
        identityMatched = allDescendants(axApp).contains {
            stringAttr($0, kAXIdentifierAttribute as String) == "ProfileTextView" &&
            stringAttr($0, kAXValueAttribute as String) == expectedAccount
        }
        if identityMatched { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < profileDeadline
    let profileNameMatched = !expectedName.isEmpty && currentTitle.contains(expectedName) && allDescendants(axApp).contains {
        stringAttr($0, kAXIdentifierAttribute as String) == "display_name_text" &&
        stringAttr($0, kAXValueAttribute as String).contains(expectedName)
    }
    guard identityMatched || profileNameMatched else {
        fputs("Existing-friend profile identity mismatch; no change made\n", stderr)
        exit(104)
    }

    var remarkWasChanged = false
    let alreadyRemarked = allDescendants(axApp).contains {
        stringAttr($0, kAXIdentifierAttribute as String) == "display_name_text" &&
        stringAttr($0, kAXValueAttribute as String) == expectedRemark
    }
    if !alreadyRemarked {
        guard let remarkView = find(identifier: "value_remark_view"), click(remarkView) else {
            fputs("Remark control not found\n", stderr)
            exit(105)
        }
        Thread.sleep(forTimeInterval: 0.5)
        var fields = allDescendants(axApp).filter {
            stringAttr($0, kAXRoleAttribute as String) == (kAXTextFieldRole as String) &&
            !stringAttr($0, kAXValueAttribute as String).isEmpty
        }
        if fields.isEmpty, let addRemark = find(role: kAXButtonRole as String, title: "添加备注名") {
            _ = click(addRemark)
            Thread.sleep(forTimeInterval: 0.4)
            fields = allDescendants(axApp).filter {
                stringAttr($0, kAXRoleAttribute as String) == (kAXTextFieldRole as String) &&
                !stringAttr($0, kAXValueAttribute as String).isEmpty
            }
        }
        guard fields.count == 1 else {
            fputs("Expected one remark editor; found \(fields.count)\n", stderr)
            exit(106)
        }
        let field = fields[0]
        let setError = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, expectedRemark as CFString)
        guard setError == .success,
              stringAttr(field, kAXValueAttribute as String) == expectedRemark,
              click(field) else {
            fputs("Remark editor update failed\n", stderr)
            exit(107)
        }
        Thread.sleep(forTimeInterval: 0.25)
        guard let focused = focusedElement(),
              stringAttr(focused, kAXRoleAttribute as String) == (kAXTextFieldRole as String),
              stringAttr(focused, kAXValueAttribute as String) == expectedRemark else {
            fputs("Remark editor focus verification failed; not submitting\n", stderr)
            exit(108)
        }
        key(0x24)
        Thread.sleep(forTimeInterval: 1.0)
        let saved = allDescendants(axApp).contains {
            (stringAttr($0, kAXIdentifierAttribute as String) == "display_name_text" &&
             stringAttr($0, kAXValueAttribute as String) == expectedRemark) ||
            (stringAttr($0, kAXIdentifierAttribute as String) == "current_chat_name_label" &&
             stringAttr($0, kAXValueAttribute as String) == expectedRemark)
        }
        guard saved else {
            fputs("Remark save outcome unconfirmed\n", stderr)
            exit(109)
        }
        remarkWasChanged = true
    }

    guard let mainWindow = find(role: kAXWindowRole as String, title: "微信") else { exit(110) }
    app.activate(options: [.activateAllWindows])
    AXUIElementPerformAction(mainWindow, kAXRaiseAction as CFString)
    Thread.sleep(forTimeInterval: 0.5)
    guard let currentName = find(identifier: "current_chat_name_label"),
          stringAttr(currentName, kAXValueAttribute as String) == expectedRemark,
          let input = findWithin(mainWindow, role: kAXTextAreaRole as String, identifier: "chat_input_field"),
          let sendButton = findWithin(mainWindow, role: kAXButtonRole as String, title: "发送") else {
        fputs("Renamed chat was not ready for greeting\n", stderr)
        exit(111)
    }
    let alreadyGreeted = allDescendants(mainWindow).contains {
        stringAttr($0, kAXTitleAttribute as String) == greeting ||
        stringAttr($0, kAXValueAttribute as String) == greeting
    }
    if alreadyGreeted {
        print("RESULT=EXISTING_FRIEND_ALREADY_GREETED REMARK_CHANGED=\(remarkWasChanged)")
        exit(0)
    }
    guard stringAttr(input, kAXValueAttribute as String).isEmpty else {
        print("RESULT=CHAT_DRAFT_NOT_EMPTY REMARK_CHANGED=\(remarkWasChanged)")
        exit(0)
    }
    AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.25)
    if focusedElement().map({ stringAttr($0, kAXIdentifierAttribute as String) }) != "chat_input_field" {
        guard clickAt(input, xFraction: 0.08) else { exit(112) }
        Thread.sleep(forTimeInterval: 0.35)
    }
    guard let focused = focusedElement(),
          stringAttr(focused, kAXIdentifierAttribute as String) == "chat_input_field",
          stringAttr(focused, kAXTitleAttribute as String) == expectedRemark else {
        let detail = focusedElement().map { elementSummary($0) } ?? "none"
        fputs("Chat-input focus verification failed; focused=\(detail); no greeting entered\n", stderr)
        exit(113)
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(greeting, forType: .string)
    key(0x00, flags: .maskCommand)
    key(0x33)
    key(0x09, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 0.5)
    guard stringAttr(input, kAXValueAttribute as String) == greeting,
          stringAttr(currentName, kAXValueAttribute as String) == expectedRemark else {
        fputs("Greeting readback mismatch; not sending\n", stderr)
        exit(114)
    }
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT WARNING=\(warning)")
        exit(70)
    }
    guard click(sendButton) else { exit(115) }
    Thread.sleep(forTimeInterval: 1.0)
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT_AFTER_SEND WARNING=\(warning)")
        exit(70)
    }
    let bubbleFound = allDescendants(mainWindow).contains {
        stringAttr($0, kAXTitleAttribute as String) == greeting ||
        stringAttr($0, kAXValueAttribute as String) == greeting
    }
    guard stringAttr(input, kAXValueAttribute as String).isEmpty || bubbleFound else {
        fputs("Greeting send outcome unconfirmed\n", stderr)
        exit(116)
    }
    print("RESULT=EXISTING_FRIEND_COMPLETED REMARK_CHANGED=\(remarkWasChanged)")

case "save-open-profile-remark":
    guard CommandLine.arguments.count >= 4 else { exit(2) }
    let expectedAccount = CommandLine.arguments[2]
    let newRemark = CommandLine.arguments[3]
    guard allDescendants(axApp).contains(where: {
        stringAttr($0, kAXIdentifierAttribute as String) == "ProfileTextView" &&
        stringAttr($0, kAXValueAttribute as String) == expectedAccount
    }) else {
        fputs("Open profile account does not match; no change made\n", stderr)
        exit(91)
    }
    let fields = allDescendants(axApp).filter {
        stringAttr($0, kAXRoleAttribute as String) == (kAXTextFieldRole as String) &&
        !stringAttr($0, kAXValueAttribute as String).isEmpty
    }
    guard fields.count == 1 else {
        fputs("Expected one open remark editor; found \(fields.count)\n", stderr)
        exit(92)
    }
    let field = fields[0]
    let setError = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, newRemark as CFString)
    guard setError == .success,
          stringAttr(field, kAXValueAttribute as String) == newRemark else {
        fputs("Remark field update failed\n", stderr)
        exit(93)
    }
    guard click(field) else { exit(94) }
    Thread.sleep(forTimeInterval: 0.25)
    guard let focused = focusedElement(),
          stringAttr(focused, kAXRoleAttribute as String) == (kAXTextFieldRole as String),
          stringAttr(focused, kAXValueAttribute as String) == newRemark else {
        fputs("Remark editor focus verification failed; not submitting\n", stderr)
        exit(95)
    }
    key(0x24) // Return commits the inline remark editor.
    Thread.sleep(forTimeInterval: 1.2)
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT WARNING=\(warning)")
        exit(70)
    }
    let saved = allDescendants(axApp).contains {
        (stringAttr($0, kAXIdentifierAttribute as String) == "display_name_text" &&
         stringAttr($0, kAXValueAttribute as String) == newRemark) ||
        (stringAttr($0, kAXIdentifierAttribute as String) == "value_remark_view" &&
         stringAttr($0, kAXTitleAttribute as String) == newRemark) ||
        (stringAttr($0, kAXIdentifierAttribute as String) == "current_chat_name_label" &&
         stringAttr($0, kAXValueAttribute as String) == newRemark)
    }
    guard saved else {
        fputs("Remark save outcome unconfirmed\n", stderr)
        exit(96)
    }
    print("RESULT=REMARK_SAVED REMARK=\(newRemark)")

case "main-search-open-contact-inspect":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let contact = CommandLine.arguments[2]
    guard enterSearch(contact) != nil else {
        fputs("Verified main search failed\n", stderr)
        exit(89)
    }
    let contacts = localContactSearchResults()
    print("LOCAL_CONTACT_COUNT=\(contacts.count)")
    for item in contacts { print("LOCAL \(elementSummary(item))") }
    guard contacts.count == 1, click(contacts[0]) else {
        print("RESULT=NO_UNIQUE_LOCAL_CONTACT")
        exit(0)
    }
    let currentTitle = stringAttr(contacts[0], kAXTitleAttribute as String)
    let deadline = Date().addingTimeInterval(6.0)
    repeat {
        if let current = find(identifier: "current_chat_name_label"),
           stringAttr(current, kAXValueAttribute as String) == currentTitle { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    print("OPENED_CHAT=\(currentTitle)")
    guard let more = find(identifier: "more_button"), click(more) else {
        fputs("Chat-info button not found\n", stderr)
        exit(90)
    }
    Thread.sleep(forTimeInterval: 1.2)
    for element in allDescendants(axApp) {
        let title = stringAttr(element, kAXTitleAttribute as String)
        let value = stringAttr(element, kAXValueAttribute as String)
        let identifier = stringAttr(element, kAXIdentifierAttribute as String)
        if !title.isEmpty || !value.isEmpty || !identifier.isEmpty {
            if let p = pointAttr(element, kAXPositionAttribute as String), p.x >= 300 {
                print("INFO \(elementSummary(element))")
            }
        }
    }

case "main-search-inspect":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let text = CommandLine.arguments[2]
    guard enterSearch(text) != nil else {
        fputs("Verified main search failed\n", stderr)
        exit(88)
    }
    let exactResults = allDescendants(axApp).filter {
        stringAttr($0, kAXRoleAttribute as String) == (kAXStaticTextRole as String) &&
        stringAttr($0, kAXTitleAttribute as String) == text
    }
    print("EXACT_COUNT=\(exactResults.count)")
    for (index, exact) in exactResults.enumerated() {
        print("EXACT[\(index)] \(elementSummary(exact))")
        var current: AXUIElement? = exact
        for depth in 1...6 {
            guard let element = current, let parent = parentElement(element) else { break }
            print("PARENT[\(index),\(depth)] \(elementSummary(parent))")
            current = parent
        }
    }
    for element in allDescendants(axApp) {
        guard let p = pointAttr(element, kAXPositionAttribute as String),
              p.x >= 55, p.x <= 620, p.y >= 30, p.y <= 850 else { continue }
        let title = stringAttr(element, kAXTitleAttribute as String)
        let value = stringAttr(element, kAXValueAttribute as String)
        let identifier = stringAttr(element, kAXIdentifierAttribute as String)
        if !title.isEmpty || !value.isEmpty || !identifier.isEmpty {
            print("AREA \(elementSummary(element))")
        }
    }

case "focus-main-search-check":
    guard let mainWindow = find(role: kAXWindowRole as String, title: "微信"),
          let searchField = findWithin(mainWindow, role: kAXTextAreaRole as String, title: "搜索") else {
        fputs("WeChat main search is not ready\n", stderr)
        exit(85)
    }
    app.activate(options: [.activateAllWindows])
    AXUIElementPerformAction(mainWindow, kAXRaiseAction as CFString)
    guard click(searchField) else { exit(86) }
    Thread.sleep(forTimeInterval: 0.3)
    guard searchFieldHasFocus() else {
        let focused = focusedElement()
        fputs("Search focus verification failed; role=\(focused.map { stringAttr($0, kAXRoleAttribute as String) } ?? "") title=\(focused.map { stringAttr($0, kAXTitleAttribute as String) } ?? "") id=\(focused.map { stringAttr($0, kAXIdentifierAttribute as String) } ?? "")\n", stderr)
        exit(87)
    }
    print("RESULT=SEARCH_FOCUSED")

case "set-main-search-direct":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let text = CommandLine.arguments[2]
    guard let mainWindow = find(role: kAXWindowRole as String, title: "微信"),
          let searchField = findWithin(mainWindow, role: kAXTextAreaRole as String, title: "搜索") else {
        fputs("WeChat main search is not ready\n", stderr)
        exit(83)
    }
    let setError = AXUIElementSetAttributeValue(searchField, kAXValueAttribute as CFString, text as CFString)
    guard setError == .success,
          stringAttr(searchField, kAXValueAttribute as String) == text else {
        fputs("Direct search-field update failed\n", stderr)
        exit(84)
    }
    Thread.sleep(forTimeInterval: 2.2)
    let exactCount = allDescendants(axApp).filter {
        stringAttr($0, kAXRoleAttribute as String) == (kAXStaticTextRole as String) &&
        stringAttr($0, kAXTitleAttribute as String) == text
    }.count
    print("RESULT=SEARCH_SET_DIRECT MATCHES=\(exactCount)")

case "remove-chat-draft-prefix":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let injectedPrefix = CommandLine.arguments[2]
    guard let mainWindow = find(role: kAXWindowRole as String, title: "微信"),
          let input = findWithin(mainWindow, role: kAXTextAreaRole as String, identifier: "chat_input_field") else {
        fputs("Chat input not found\n", stderr)
        exit(80)
    }
    let current = stringAttr(input, kAXValueAttribute as String)
    guard current.hasPrefix(injectedPrefix) else {
        fputs("Chat draft does not start with the injected text; left unchanged\n", stderr)
        exit(81)
    }
    let remainder = String(current.dropFirst(injectedPrefix.count))
    let setError = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, remainder as CFString)
    guard setError == .success,
          stringAttr(input, kAXValueAttribute as String) == remainder else {
        fputs("Could not restore chat draft\n", stderr)
        exit(82)
    }
    print("RESULT=DRAFT_RESTORED REMAINING_LENGTH=\(remainder.count)")

case "search":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let text = CommandLine.arguments[2]
    guard let field = enterSearch(text) else {
        fputs("Search field not found\n", stderr)
        exit(3)
    }
    print("SEARCH_VALUE=" + stringAttr(field, kAXValueAttribute as String))

case "search-actions":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let text = CommandLine.arguments[2]
    guard let field = enterSearch(text) else {
        fputs("Search field not found\n", stderr)
        exit(3)
    }
    print("SEARCH_VALUE=" + stringAttr(field, kAXValueAttribute as String))
    var count = 0
    for element in allDescendants(axApp) where stringAttr(element, kAXTitleAttribute as String) == text {
        count += 1
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        let actionNames = (names as? [String]) ?? []
        print("EXACT role=\(stringAttr(element, kAXRoleAttribute as String)) actions=\(actionNames.joined(separator: ","))")
    }
    print("EXACT_COUNT=\(count)")

case "search-open":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let text = CommandLine.arguments[2]
    guard enterSearch(text) != nil else {
        fputs("Search field not found\n", stderr)
        exit(3)
    }
    let exact = allDescendants(axApp).filter {
        stringAttr($0, kAXRoleAttribute as String) == (kAXStaticTextRole as String) &&
        stringAttr($0, kAXTitleAttribute as String) == text
    }
    guard exact.count == 1, click(exact[0]) else {
        fputs("Expected exactly one clickable exact result; found \(exact.count)\n", stderr)
        exit(5)
    }
    Thread.sleep(forTimeInterval: 3.0)
    print("OPENED_EXACT=\(text)")
    for element in allDescendants(axApp, limit: 1200) {
        let role = stringAttr(element, kAXRoleAttribute as String)
        let title = stringAttr(element, kAXTitleAttribute as String)
        let desc = stringAttr(element, kAXDescriptionAttribute as String)
        let value = stringAttr(element, kAXValueAttribute as String)
        let identifier = stringAttr(element, kAXIdentifierAttribute as String)
        if !title.isEmpty || !desc.isEmpty || !value.isEmpty || !identifier.isEmpty {
            print("UI role=\(role) title=\(title) desc=\(desc) value=\(value) id=\(identifier)")
        }
    }

case "search-open-user":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let text = CommandLine.arguments[2]
    guard enterSearch(text) != nil else {
        fputs("Search field not found\n", stderr)
        exit(3)
    }
    let userLookup = allDescendants(axApp).filter {
        stringAttr($0, kAXTitleAttribute as String) == "网络查找微信号："
    }
    guard userLookup.count == 1, click(userLookup[0]) else {
        fputs("Expected one user-lookup row; found \(userLookup.count)\n", stderr)
        exit(6)
    }
    Thread.sleep(forTimeInterval: 4.0)
    print("OPENED_USER_LOOKUP=\(text)")
    for element in allDescendants(axApp, limit: 1200) {
        let role = stringAttr(element, kAXRoleAttribute as String)
        let title = stringAttr(element, kAXTitleAttribute as String)
        let desc = stringAttr(element, kAXDescriptionAttribute as String)
        let value = stringAttr(element, kAXValueAttribute as String)
        let identifier = stringAttr(element, kAXIdentifierAttribute as String)
        if !title.isEmpty || !desc.isEmpty || !value.isEmpty || !identifier.isEmpty {
            print("UI role=\(role) title=\(title) desc=\(desc) value=\(value) id=\(identifier)")
        }
    }

case "open-add-inspect":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let text = CommandLine.arguments[2]
    guard enterSearch(text) != nil else {
        fputs("Search field not found\n", stderr)
        exit(3)
    }

case "fill-request-form":
    guard CommandLine.arguments.count >= 4 else { exit(2) }
    let requestText = CommandLine.arguments[2]
    let remarkText = CommandLine.arguments[3]
    guard let form = find(role: kAXWindowRole as String, title: "申请添加朋友") else {
        fputs("Request form not found\n", stderr)
        exit(9)
    }
    guard let requestField = findWithin(form, role: kAXTextAreaRole as String, title: "发送添加朋友申请"),
          let remarkField = findWithin(form, role: kAXTextFieldRole as String, title: "修改备注") else {
        fputs("Request or remark field not found\n", stderr)
        exit(10)
    }
    app.activate(options: [.activateAllWindows])
    AXUIElementPerformAction(form, kAXRaiseAction as CFString)

    AXUIElementSetAttributeValue(requestField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(requestText, forType: .string)
    key(0x00, flags: .maskCommand)
    key(0x09, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 0.4)

    AXUIElementSetAttributeValue(remarkField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(remarkText, forType: .string)
    key(0x00, flags: .maskCommand)
    key(0x09, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 0.5)

    print("REQUEST_VALUE=" + stringAttr(requestField, kAXValueAttribute as String))
    print("REQUEST_DESC=" + stringAttr(requestField, kAXDescriptionAttribute as String))
    print("REMARK_VALUE=" + stringAttr(remarkField, kAXValueAttribute as String))
    print("REMARK_DESC=" + stringAttr(remarkField, kAXDescriptionAttribute as String))
    let confirms = allDescendants(form).filter {
        stringAttr($0, kAXRoleAttribute as String) == (kAXButtonRole as String) &&
        stringAttr($0, kAXTitleAttribute as String) == "确定"
    }
    print("CONFIRM_BUTTONS=\(confirms.count)")

case "process-one":
    guard CommandLine.arguments.count >= 5 else { exit(2) }
    let contact = CommandLine.arguments[2]
    let requestText = CommandLine.arguments[3]
    let remarkText = CommandLine.arguments[4]
    if let warning = frequencyWarning() {
        fputs("RATE_LIMIT=\(warning)\n", stderr)
        exit(70)
    }
    guard let addWindow = find(role: kAXWindowRole as String, title: "添加朋友"),
          let searchField = findWithin(addWindow, role: kAXTextAreaRole as String, title: "搜索"),
          let searchButton = findWithin(addWindow, role: kAXButtonRole as String, title: "搜索") else {
        fputs("Dedicated add-friend search window not ready\n", stderr)
        exit(20)
    }
    app.activate(options: [.activateAllWindows])
    AXUIElementPerformAction(addWindow, kAXRaiseAction as CFString)
    guard paste(contact, into: searchField) else {
        fputs("Search value verification failed\n", stderr)
        exit(21)
    }
    guard click(searchButton) else {
        fputs("Search button click failed\n", stderr)
        exit(22)
    }
    Thread.sleep(forTimeInterval: 2.5)
    if let warning = frequencyWarning() {
        fputs("RATE_LIMIT=\(warning)\n", stderr)
        exit(70)
    }
    guard let addButton = findWithin(addWindow, role: kAXButtonRole as String, identifier: "add_friend_button") else {
        fputs("RESULT=NOT_FOUND_OR_UNAVAILABLE CONTACT=\(contact)\n", stderr)
        exit(23)
    }
    let resultState = stringAttr(addButton, kAXTitleAttribute as String)
    if resultState == "等待验证" {
        print("RESULT=ALREADY_PENDING CONTACT=\(contact)")
        exit(0)
    }
    if resultState != "添加到通讯录" {
        print("RESULT=NON_ADDABLE STATE=\(resultState) CONTACT=\(contact)")
        exit(0)
    }
    guard click(addButton) else {
        fputs("Add button click failed\n", stderr)
        exit(24)
    }
    guard let form = waitFor(role: kAXWindowRole as String, title: "申请添加朋友", timeout: 6.0),
          let requestField = findWithin(form, role: kAXTextAreaRole as String, title: "发送添加朋友申请"),
          let remarkField = findWithin(form, role: kAXTextFieldRole as String, title: "修改备注") else {
        fputs("Request form did not open\n", stderr)
        exit(25)
    }
    AXUIElementPerformAction(form, kAXRaiseAction as CFString)
    guard paste(requestText, into: requestField), paste(remarkText, into: remarkField) else {
        fputs("Request-form readback mismatch\n", stderr)
        exit(26)
    }
    guard let confirm = findWithin(form, role: kAXButtonRole as String, title: "确定"), click(confirm) else {
        fputs("Confirm click failed\n", stderr)
        exit(27)
    }
    Thread.sleep(forTimeInterval: 0.5)
    if let warning = frequencyWarning() {
        fputs("RATE_LIMIT=\(warning)\n", stderr)
        exit(70)
    }
    let deadline = Date().addingTimeInterval(5.0)
    var sent = false
    repeat {
        sent = allDescendants(axApp).contains {
            stringAttr($0, kAXStaticTextRole as String) == "" &&
            (stringAttr($0, kAXTitleAttribute as String) == "已发送" || stringAttr($0, kAXValueAttribute as String) == "已发送")
        }
        if sent { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    let postState = stringAttr(addButton, kAXTitleAttribute as String)
    if let warning = frequencyWarning() {
        fputs("RATE_LIMIT=\(warning)\n", stderr)
        exit(70)
    }
    guard sent || postState == "等待验证" else {
        fputs("Submit outcome not confirmed; state=\(postState)\n", stderr)
        exit(28)
    }
    print("RESULT=SENT CONTACT=\(contact) REMARK=\(remarkText)")

case "greet-current":
    guard CommandLine.arguments.count >= 4 else { exit(2) }
    let expectedRemark = CommandLine.arguments[2]
    let greeting = CommandLine.arguments[3]
    guard let profileWindow = find(role: kAXWindowRole as String, title: "添加朋友"),
          let profileName = findWithin(profileWindow, identifier: "display_name_text"),
          stringAttr(profileName, kAXValueAttribute as String) == expectedRemark,
          let chatButton = findWithin(profileWindow, role: kAXButtonRole as String, identifier: "chat_img_button") else {
        fputs("Accepted profile or exact remark not found\n", stderr)
        exit(30)
    }
    app.activate(options: [.activateAllWindows])
    AXUIElementPerformAction(profileWindow, kAXRaiseAction as CFString)
    guard click(chatButton) else { exit(31) }
    let chatDeadline = Date().addingTimeInterval(6.0)
    var chatName: AXUIElement?
    repeat {
        chatName = find(identifier: "current_chat_name_label")
        if let chatName, stringAttr(chatName, kAXValueAttribute as String) == expectedRemark { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < chatDeadline
    guard let chatName, stringAttr(chatName, kAXValueAttribute as String) == expectedRemark,
          let mainWindow = find(role: kAXWindowRole as String, title: "微信"),
          let input = findWithin(mainWindow, role: kAXTextAreaRole as String, identifier: "chat_input_field"),
          let sendButton = findWithin(mainWindow, role: kAXButtonRole as String, title: "发送") else {
        fputs("Exact chat did not open\n", stderr)
        exit(32)
    }
    guard paste(greeting, into: input) else {
        fputs("Greeting readback mismatch\n", stderr)
        exit(33)
    }
    guard click(sendButton) else { exit(34) }
    Thread.sleep(forTimeInterval: 1.0)
    let inputAfter = stringAttr(input, kAXValueAttribute as String)
    let bubbleFound = allDescendants(mainWindow).contains {
        stringAttr($0, kAXTitleAttribute as String) == greeting ||
        stringAttr($0, kAXValueAttribute as String) == greeting
    }
    guard inputAfter.isEmpty || bubbleFound else {
        fputs("Greeting send outcome unconfirmed\n", stderr)
        exit(35)
    }
    print("RESULT=GREETING_SENT REMARK=\(expectedRemark)")

case "main-search-and-greet":
    guard CommandLine.arguments.count >= 4 else { exit(2) }
    let expectedRemark = CommandLine.arguments[2]
    let greeting = CommandLine.arguments[3]
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT WARNING=\(warning)")
        exit(70)
    }
    guard let mainWindow = find(role: kAXWindowRole as String, title: "微信"),
          findWithin(mainWindow, role: kAXTextAreaRole as String, title: "搜索") != nil else {
        fputs("WeChat main search is not ready\n", stderr)
        exit(71)
    }
    app.activate(options: [.activateAllWindows])
    AXUIElementPerformAction(mainWindow, kAXRaiseAction as CFString)
    guard let enteredField = enterSearch(expectedRemark),
          stringAttr(enteredField, kAXValueAttribute as String) == expectedRemark else {
        fputs("Main-search readback mismatch\n", stderr)
        exit(72)
    }
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT WARNING=\(warning)")
        exit(70)
    }
    let exactResults = allDescendants(axApp).filter {
        stringAttr($0, kAXRoleAttribute as String) == (kAXStaticTextRole as String) &&
        stringAttr($0, kAXTitleAttribute as String) == expectedRemark &&
        stringAttr($0, kAXIdentifierAttribute as String) == "search_item_\(expectedRemark)"
    }
    guard exactResults.count == 1 else {
        print("RESULT=NOT_IN_MAIN_SEARCH MATCHES=\(exactResults.count) REMARK=\(expectedRemark)")
        exit(0)
    }
    guard click(exactResults[0]) else {
        fputs("Exact main-search result could not be clicked\n", stderr)
        exit(73)
    }
    let chatDeadline = Date().addingTimeInterval(6.0)
    var currentName: AXUIElement?
    repeat {
        currentName = find(identifier: "current_chat_name_label")
        if let currentName, stringAttr(currentName, kAXValueAttribute as String) == expectedRemark { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < chatDeadline
    guard let currentName, stringAttr(currentName, kAXValueAttribute as String) == expectedRemark,
          let input = findWithin(mainWindow, role: kAXTextAreaRole as String, identifier: "chat_input_field"),
          let sendButton = findWithin(mainWindow, role: kAXButtonRole as String, title: "发送") else {
        fputs("Exact main-search chat did not open\n", stderr)
        exit(74)
    }
    let alreadyPresent = allDescendants(mainWindow).contains {
        stringAttr($0, kAXTitleAttribute as String) == greeting ||
        stringAttr($0, kAXValueAttribute as String) == greeting
    }
    if alreadyPresent {
        print("RESULT=GREETING_ALREADY_PRESENT REMARK=\(expectedRemark)")
        exit(0)
    }
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT WARNING=\(warning)")
        exit(70)
    }
    guard paste(greeting, into: input), click(sendButton) else {
        fputs("Exact main-search chat could not be greeted\n", stderr)
        exit(75)
    }
    Thread.sleep(forTimeInterval: 1.0)
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT_AFTER_SEND WARNING=\(warning)")
        exit(70)
    }
    let bubbleFound = allDescendants(mainWindow).contains {
        stringAttr($0, kAXTitleAttribute as String) == greeting ||
        stringAttr($0, kAXValueAttribute as String) == greeting
    }
    guard stringAttr(input, kAXValueAttribute as String).isEmpty || bubbleFound else {
        fputs("Greeting send outcome unconfirmed\n", stderr)
        exit(76)
    }
    print("RESULT=GREETING_SENT REMARK=\(expectedRemark)")

case "check-and-greet":
    guard CommandLine.arguments.count >= 5 else { exit(2) }
    let contact = CommandLine.arguments[2]
    let expectedRemark = CommandLine.arguments[3]
    let greeting = CommandLine.arguments[4]
    guard let addWindow = find(role: kAXWindowRole as String, title: "添加朋友"),
          let searchField = findWithin(addWindow, role: kAXTextAreaRole as String, title: "搜索"),
          let searchButton = findWithin(addWindow, role: kAXButtonRole as String, title: "搜索") else {
        fputs("Dedicated add-friend window not ready\n", stderr)
        exit(40)
    }
    app.activate(options: [.activateAllWindows])
    AXUIElementPerformAction(addWindow, kAXRaiseAction as CFString)
    if let clearButton = findWithin(addWindow, role: kAXButtonRole as String, title: "清空") {
        _ = click(clearButton)
        Thread.sleep(forTimeInterval: 0.4)
    }
    guard paste(contact, into: searchField), click(searchButton) else {
        fputs("Accepted-state search failed\n", stderr)
        exit(41)
    }
    Thread.sleep(forTimeInterval: 2.2)
    if let profileName = findWithin(addWindow, identifier: "display_name_text"),
       stringAttr(profileName, kAXValueAttribute as String) == expectedRemark,
       let chatButton = findWithin(addWindow, role: kAXButtonRole as String, identifier: "chat_img_button") {
        guard click(chatButton) else { exit(42) }
        let chatDeadline = Date().addingTimeInterval(6.0)
        var currentName: AXUIElement?
        repeat {
            currentName = find(identifier: "current_chat_name_label")
            if let currentName, stringAttr(currentName, kAXValueAttribute as String) == expectedRemark { break }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < chatDeadline
        guard let currentName, stringAttr(currentName, kAXValueAttribute as String) == expectedRemark,
              let mainWindow = find(role: kAXWindowRole as String, title: "微信"),
              let input = findWithin(mainWindow, role: kAXTextAreaRole as String, identifier: "chat_input_field"),
              let sendButton = findWithin(mainWindow, role: kAXButtonRole as String, title: "发送") else {
            fputs("Exact accepted chat could not be greeted\n", stderr)
            exit(43)
        }
        let alreadyPresent = allDescendants(mainWindow).contains {
            stringAttr($0, kAXTitleAttribute as String) == greeting ||
            stringAttr($0, kAXValueAttribute as String) == greeting
        }
        if alreadyPresent {
            print("RESULT=GREETING_ALREADY_PRESENT REMARK=\(expectedRemark)")
            exit(0)
        }
        guard paste(greeting, into: input), click(sendButton) else {
            fputs("Exact accepted chat could not be greeted\n", stderr)
            exit(43)
        }
        Thread.sleep(forTimeInterval: 0.8)
        guard stringAttr(input, kAXValueAttribute as String).isEmpty else {
            fputs("Greeting send outcome unconfirmed\n", stderr)
            exit(44)
        }
        print("RESULT=GREETING_SENT REMARK=\(expectedRemark)")
        exit(0)
    }
    if let addButton = findWithin(addWindow, role: kAXButtonRole as String, identifier: "add_friend_button") {
        let state = stringAttr(addButton, kAXTitleAttribute as String)
        print("RESULT=NOT_ACCEPTED STATE=\(state)")
        exit(0)
    }
    print("RESULT=NO_MATCHING_ACCEPTED_PROFILE")
case "press-title", "press-id", "click-title", "click-id":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let needle = CommandLine.arguments[2]
    let byTitle = command == "press-title" || command == "click-title"
    let element = byTitle ? find(title: needle) : find(identifier: needle)
    guard let element else {
        fputs("Element not found: \(needle)\n", stderr)
        exit(4)
    }
    if command == "click-title" || command == "click-id" {
        print("CLICKED=\(click(element))")
    } else {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        print("PRESS_ERROR=\(error.rawValue)")
    }

case "read-matches":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let needle = CommandLine.arguments[2]
    var count = 0
    for element in allDescendants(axApp) {
        let role = stringAttr(element, kAXRoleAttribute as String)
        let title = stringAttr(element, kAXTitleAttribute as String)
        let desc = stringAttr(element, kAXDescriptionAttribute as String)
        let value = stringAttr(element, kAXValueAttribute as String)
        let identifier = stringAttr(element, kAXIdentifierAttribute as String)
        let combined = [title, desc, value, identifier].joined(separator: " ")
        if combined.localizedCaseInsensitiveContains(needle) {
            count += 1
            print("MATCH role=\(role) title=\(title) desc=\(desc) value=\(value) id=\(identifier)")
        }
    }
    print("MATCH_COUNT=\(count)")

case "actions-title":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let needle = CommandLine.arguments[2]
    var count = 0
    for element in allDescendants(axApp) where stringAttr(element, kAXTitleAttribute as String) == needle {
        count += 1
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        let actionNames = (names as? [String]) ?? []
        var settableValue = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settableValue)
        print("ACTIONS role=\(stringAttr(element, kAXRoleAttribute as String)) names=\(actionNames) valueSettable=\(settableValue.boolValue) error=\(error.rawValue)")
    }
    print("ACTION_MATCH_COUNT=\(count)")

case "actions-value":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let needle = CommandLine.arguments[2]
    var count = 0
    for element in allDescendants(axApp) where stringAttr(element, kAXValueAttribute as String) == needle {
        count += 1
        print("ACTIONS_VALUE \(elementSummary(element))")
    }
    print("ACTION_VALUE_MATCH_COUNT=\(count)")

case "describe-id":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let needle = CommandLine.arguments[2]
    let matches = allDescendants(axApp).filter {
        stringAttr($0, kAXIdentifierAttribute as String) == needle
    }
    for element in matches { print("DESCRIBE \(elementSummary(element))") }
    print("DESCRIBE_COUNT=\(matches.count)")

default:
    fputs("Unknown command\n", stderr)
    exit(2)
}
