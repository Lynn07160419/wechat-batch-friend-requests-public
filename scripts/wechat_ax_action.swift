import AppKit
import ApplicationServices
import Foundation

// macOS 微信 Accessibility 辅助程序。
// 只读界面树 + 元素相对坐标点击；不使用截图，因此窗口移动、缩放、无法截屏都不影响。
// 编译：swiftc wechat_ax_action.swift -o /tmp/wechat_ax_action

let bundleID = "com.tencent.xinWeChat"

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    fputs("WeChat is not running\n", stderr)
    exit(2)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)

// MARK: - 读取无障碍树

func copyAttr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func stringAttr(_ element: AXUIElement, _ name: String) -> String {
    guard let value = copyAttr(element, name) else { return "" }
    return String(describing: value).replacingOccurrences(of: "\n", with: "\\n")
}

func childElements(_ element: AXUIElement) -> [AXUIElement] {
    (copyAttr(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
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

/// 微信重排界面时会短暂读空整棵树。读空时重试，读到了但没匹配就立即返回，避免拖慢轮询。
func find(_ root: AXUIElement? = nil, role: String? = nil, title: String? = nil, identifier: String? = nil) -> AXUIElement? {
    let start = root ?? axApp
    for attempt in 0..<3 {
        let elements = allDescendants(start)
        for element in elements {
            if let role, stringAttr(element, kAXRoleAttribute as String) != role { continue }
            if let title, stringAttr(element, kAXTitleAttribute as String) != title { continue }
            if let identifier, stringAttr(element, kAXIdentifierAttribute as String) != identifier { continue }
            return element
        }
        if !elements.isEmpty { return nil }
        if attempt < 2 { Thread.sleep(forTimeInterval: 0.15) }
    }
    return nil
}

func waitFor(_ root: AXUIElement? = nil, role: String? = nil, title: String? = nil, identifier: String? = nil, timeout: TimeInterval = 6.0) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let element = find(root, role: role, title: title, identifier: identifier) { return element }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    return nil
}

func pointAttr(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let raw = copyAttr(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &point) ? point : nil
}

func sizeAttr(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let raw = copyAttr(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &size) ? size : nil
}

func focusedElement() -> AXUIElement? {
    guard let raw = copyAttr(axApp, kAXFocusedUIElementAttribute as String),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(raw, to: AXUIElement.self)
}

func elementSummary(_ element: AXUIElement) -> String {
    let p = pointAttr(element, kAXPositionAttribute as String) ?? .zero
    let s = sizeAttr(element, kAXSizeAttribute as String) ?? .zero
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    let actions = (names as? [String]) ?? []
    return "role=\(stringAttr(element, kAXRoleAttribute as String)) title=\(stringAttr(element, kAXTitleAttribute as String)) value=\(stringAttr(element, kAXValueAttribute as String)) id=\(stringAttr(element, kAXIdentifierAttribute as String)) pos=\(Int(p.x)),\(Int(p.y)) size=\(Int(s.width))x\(Int(s.height)) actions=\(actions.joined(separator: ","))"
}

// MARK: - 窗口定位
// 不按尺寸或位置认窗口：窗口可以移动、缩放、并存，只要能读到聊天控件就是主窗口。

func axWindows() -> [AXUIElement] {
    for _ in 0..<3 {
        if let list = copyAttr(axApp, kAXWindowsAttribute as String) as? [AXUIElement], !list.isEmpty {
            return list
        }
        Thread.sleep(forTimeInterval: 0.15)
    }
    return []
}

func hasChatControls(_ window: AXUIElement) -> Bool {
    allDescendants(window, limit: 900).contains {
        stringAttr($0, kAXIdentifierAttribute as String) == "chat_input_field"
    }
}

/// 微信的窗口标题会变成「微信 (窗口)」「微信 (2)」，不能只认死一个字符串。
func isWeChatTitle(_ title: String) -> Bool {
    title == "微信" || title.hasPrefix("微信 (") || title.hasPrefix("微信(")
}

func pickMain(_ windows: [AXUIElement]) -> AXUIElement? {
    if let titled = windows.first(where: {
        isWeChatTitle(stringAttr($0, kAXTitleAttribute as String)) && hasChatControls($0)
    }) { return titled }
    if let chat = windows.first(where: hasChatControls) { return chat }
    // 最后的兜底只用于报错信息；此时界面不可用，调用方会拿到 117/71。
    return windows.first(where: { isWeChatTitle(stringAttr($0, kAXTitleAttribute as String)) })
}

/// 主窗口被最小化或关闭时先自愈：还原 → 激活 → 必要时重新打开应用。
func mainWindow() -> AXUIElement? {
    var windows = axWindows()
    if let main = pickMain(windows), hasChatControls(main) { return main }

    for window in windows {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    app.activate(options: [.activateAllWindows])
    for window in windows { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
    Thread.sleep(forTimeInterval: 1.2)
    windows = axWindows()
    if let main = pickMain(windows), hasChatControls(main) { return main }

    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-a", "WeChat"]
    try? open.run()
    open.waitUntilExit()
    Thread.sleep(forTimeInterval: 2.0)
    guard let reopened = pickMain(axWindows()), hasChatControls(reopened) else { return nil }
    return reopened
}

/// 窄窗口会把搜索框折叠成入口，点开后再找文本框。
func searchTextArea(in window: AXUIElement) -> AXUIElement? {
    if let field = find(window, role: kAXTextAreaRole as String, title: "搜索") { return field }
    if let entry = find(window, title: "搜索") {
        _ = click(entry)
        Thread.sleep(forTimeInterval: 0.6)
        return find(window, role: kAXTextAreaRole as String, title: "搜索")
    }
    return nil
}

func searchFieldHasFocus() -> Bool {
    guard let focused = focusedElement() else { return false }
    return stringAttr(focused, kAXRoleAttribute as String) == (kAXTextAreaRole as String) &&
        stringAttr(focused, kAXTitleAttribute as String) == "搜索" &&
        stringAttr(focused, kAXIdentifierAttribute as String) != "chat_input_field"
}

func isFrontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
}

/// 点击和按键只会送到最前面的应用。被其他窗口挡住时必须先把微信拉到前台，否则会点空。
@discardableResult
func ensureFrontmost(timeout: TimeInterval = 2.0) -> Bool {
    if isFrontmost() { return true }
    app.unhide()
    app.activate(options: [.activateAllWindows])
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if isFrontmost() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return isFrontmost()
}

// MARK: - 输入

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

func click(_ element: AXUIElement) -> Bool {
    clickAt(element, xFraction: 0.5, yFraction: 0.5)
}

/// 按元素的相对位置点击：窗口移动或缩放后仍然落在同一控件上。
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

/// 写入后回读，只有完全一致才算成功。
@discardableResult
func paste(_ text: String, into element: AXUIElement) -> Bool {
    guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
        return false
    }
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

func enterSearch(_ text: String) -> AXUIElement? {
    guard let window = mainWindow(), let field = searchTextArea(in: window) else {
        fputs("Main search box not found\n", stderr)
        return nil
    }
    guard ensureFrontmost() else {
        fputs("WeChat is not frontmost; refusing to type into the search box\n", stderr)
        return nil
    }
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    guard click(field) else {
        fputs("Search box click failed\n", stderr)
        return nil
    }
    Thread.sleep(forTimeInterval: 0.3)
    guard searchFieldHasFocus() else {
        let focused = focusedElement()
        fputs("Search focus verification failed; focused role=\(focused.map { stringAttr($0, kAXRoleAttribute as String) } ?? "none") title=\(focused.map { stringAttr($0, kAXTitleAttribute as String) } ?? "") id=\(focused.map { stringAttr($0, kAXIdentifierAttribute as String) } ?? "")\n", stderr)
        return nil
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    key(0x00, flags: .maskCommand)
    key(0x33) // 先删掉上一次的查询，否则同样的关键词不会重新触发搜索
    key(0x09, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 2.5)
    return field
}

// MARK: - 判定

func localContactSearchResults() -> [AXUIElement]? {
    guard let list = find(identifier: "search_list") else { return nil }
    let elements = allDescendants(list)
    let contactHeaderTitles: Set<String> = ["联系人", "最常使用"]
    let sectionTitles: Set<String> = ["群聊", "聊天记录", "公众号", "小程序", "搜索网络结果"]
    let headers = elements.filter {
        stringAttr($0, kAXRoleAttribute as String) == (kAXStaticTextRole as String) &&
            stringAttr($0, kAXIdentifierAttribute as String).isEmpty
    }
    guard let header = headers.first(where: {
        contactHeaderTitles.contains(stringAttr($0, kAXTitleAttribute as String))
    }) else {
        // 没有本地联系人时，微信仍会显示可识别的结果分区。
        return headers.contains {
            sectionTitles.contains(stringAttr($0, kAXTitleAttribute as String))
        } ? [] : nil
    }
    guard let headerPosition = pointAttr(header, kAXPositionAttribute as String) else { return nil }
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

func frequencyWarning() -> String? {
    let needles = ["操作太频繁", "操作频繁", "过于频繁", "频率过快", "请稍后再试"]
    for element in allDescendants(axApp) {
        let text = [
            stringAttr(element, kAXTitleAttribute as String),
            stringAttr(element, kAXValueAttribute as String),
            stringAttr(element, kAXDescriptionAttribute as String),
        ].joined(separator: " ")
        if needles.contains(where: { text.contains($0) }) { return text }
    }
    return nil
}

func greetingPresent(in window: AXUIElement, _ greeting: String) -> Bool {
    allDescendants(window).contains {
        stringAttr($0, kAXTitleAttribute as String) == greeting ||
        stringAttr($0, kAXValueAttribute as String) == greeting
    }
}

// MARK: - 发消息（唯一实现）
// 所有发问候的入口都走这里：校验收件人 → 去重 → 保护草稿 → 聚焦校验 → 回读 → 限频检查 → 发送 → 复核。

enum GreetResult {
    case sent
    case alreadyPresent
    case draftNotEmpty
    case dryRun
    case rateLimited(String, afterSend: Bool)
    case failed(Int32, String)
}

func sendGreeting(in window: AXUIElement, expected: String, greeting: String) -> GreetResult {
    guard let currentName = find(window, identifier: "current_chat_name_label"),
          stringAttr(currentName, kAXValueAttribute as String) == expected,
          let input = find(window, role: kAXTextAreaRole as String, identifier: "chat_input_field"),
          let sendButton = find(window, role: kAXButtonRole as String, title: "发送") else {
        return .failed(117, "Exact chat not ready")
    }
    if greetingPresent(in: window, greeting) { return .alreadyPresent }
    guard stringAttr(input, kAXValueAttribute as String).isEmpty else { return .draftNotEmpty }

    guard ensureFrontmost() else {
        return .failed(125, "WeChat is not frontmost; no greeting entered")
    }
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.25)
    if focusedElement().map({ stringAttr($0, kAXIdentifierAttribute as String) }) != "chat_input_field" {
        guard clickAt(input, xFraction: 0.08) else {
            return .failed(118, "Chat input click failed")
        }
        Thread.sleep(forTimeInterval: 0.35)
    }
    guard let focused = focusedElement(),
          stringAttr(focused, kAXIdentifierAttribute as String) == "chat_input_field" else {
        let detail = focusedElement().map { elementSummary($0) } ?? "none"
        return .failed(119, "Chat-input focus verification failed; focused=\(detail); no greeting entered")
    }
    guard stringAttr(currentName, kAXValueAttribute as String) == expected else {
        return .failed(119, "Chat title changed while focusing; no greeting entered")
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(greeting, forType: .string)
    key(0x00, flags: .maskCommand)
    key(0x33)
    key(0x09, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 0.5)
    guard stringAttr(input, kAXValueAttribute as String) == greeting,
          stringAttr(currentName, kAXValueAttribute as String) == expected else {
        return .failed(120, "Greeting readback mismatch; not sending")
    }
    if let warning = frequencyWarning() { return .rateLimited(warning, afterSend: false) }

    // WECHAT_AX_DRY_RUN=1：只验证「输入→回读」，随后撤掉草稿，不点发送。
    if ProcessInfo.processInfo.environment["WECHAT_AX_DRY_RUN"] == "1" {
        key(0x00, flags: .maskCommand)
        key(0x33)
        Thread.sleep(forTimeInterval: 0.4)
        guard stringAttr(input, kAXValueAttribute as String).isEmpty else {
            return .failed(124, "Dry-run cleanup failed; draft left in chat input")
        }
        return .dryRun
    }

    guard click(sendButton) else { return .failed(121, "Send button click failed") }
    Thread.sleep(forTimeInterval: 1.0)
    if let warning = frequencyWarning() { return .rateLimited(warning, afterSend: true) }

    let inputCleared = stringAttr(input, kAXValueAttribute as String).isEmpty
    guard inputCleared || greetingPresent(in: window, greeting) else {
        return .failed(122, "Greeting send outcome unconfirmed")
    }
    return .sent
}

func finish(_ result: GreetResult, sent: String, already: String, suffix: String = "") -> Never {
    switch result {
    case .sent:
        print("RESULT=\(sent)\(suffix)")
        exit(0)
    case .alreadyPresent:
        print("RESULT=\(already)\(suffix)")
        exit(0)
    case .draftNotEmpty:
        print("RESULT=CHAT_DRAFT_NOT_EMPTY\(suffix)")
        exit(0)
    case .dryRun:
        print("RESULT=DRY_RUN_OK\(suffix)")
        exit(0)
    case .rateLimited(let warning, let afterSend):
        print("RESULT=\(afterSend ? "RATE_LIMIT_AFTER_SEND" : "RATE_LIMIT") WARNING=\(warning)")
        exit(70)
    case .failed(let code, let message):
        fputs("\(message)\n", stderr)
        exit(code)
    }
}

// MARK: - 改备注（唯一实现）

/// 返回 0 表示已保存；其他值是要抛给调用方的退出码。
func updateRemark(_ newRemark: String, openEditor: Bool) -> Int32 {
    if openEditor {
        guard let remarkView = find(identifier: "value_remark_view"), click(remarkView) else {
            fputs("Remark control not found\n", stderr)
            return 105
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    func nonEmptyTextFields() -> [AXUIElement] {
        allDescendants(axApp).filter {
            stringAttr($0, kAXRoleAttribute as String) == (kAXTextFieldRole as String) &&
            !stringAttr($0, kAXValueAttribute as String).isEmpty
        }
    }
    var fields = nonEmptyTextFields()
    if fields.isEmpty, let addRemark = find(role: kAXButtonRole as String, title: "添加备注名") {
        _ = click(addRemark)
        Thread.sleep(forTimeInterval: 0.4)
        fields = nonEmptyTextFields()
    }
    guard fields.count == 1 else {
        fputs("Expected one remark editor; found \(fields.count)\n", stderr)
        return 106
    }
    let field = fields[0]
    guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, newRemark as CFString) == .success,
          stringAttr(field, kAXValueAttribute as String) == newRemark,
          click(field) else {
        fputs("Remark editor update failed\n", stderr)
        return 107
    }
    Thread.sleep(forTimeInterval: 0.25)
    guard let focused = focusedElement(),
          stringAttr(focused, kAXRoleAttribute as String) == (kAXTextFieldRole as String),
          stringAttr(focused, kAXValueAttribute as String) == newRemark else {
        fputs("Remark editor focus verification failed; not submitting\n", stderr)
        return 108
    }
    key(0x24) // Return 提交行内备注编辑
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
    if !saved {
        fputs("Remark save outcome unconfirmed\n", stderr)
        return 109
    }
    return 0
}

// MARK: - 命令分发

guard CommandLine.arguments.count >= 2 else {
    fputs("""
    commands:
      check-friend QUERY                         只读：返回本地联系人命中数（JSON）
      search TEXT                                只读：输入主搜索并回读
      click-title TITLE | click-id IDENTIFIER    点击标题/标识符命中的元素
      press-title TITLE | press-id IDENTIFIER    对元素发送 AXPress
      process-one CONTACT REQUEST REMARK         添加朋友并提交申请
      process-existing-friend CONTACT REMARK GREETING [ACCOUNT] [NAME]
                                                 已有好友：验身份 → 改备注 → 发问候
      save-open-profile-remark ACCOUNT REMARK    在已打开的资料页改备注
      main-search-and-greet REMARK GREETING      主搜索精确定位会话后发问候
      greet-current-chat REMARK GREETING         在当前会话发问候（须标题完全匹配）
      remove-chat-draft-prefix TEXT              仅移除本次注入的草稿前缀

    env WECHAT_AX_DRY_RUN=1  发问候前演练：输入并回读，随后撤掉草稿，不点发送。

    """, stderr)
    exit(2)
}

let command = CommandLine.arguments[1]

switch command {
case "check-friend":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let query = CommandLine.arguments[2]
    if let warning = frequencyWarning() {
        print("{\"result\":\"rate_limit\",\"warning\":\"\(warning)\"}")
        exit(70)
    }
    guard let field = enterSearch(query),
          stringAttr(field, kAXValueAttribute as String) == query else {
        print("{\"result\":\"search_error\",\"reason\":\"focus_or_readback\"}")
        exit(123)
    }
    if let warning = frequencyWarning() {
        print("{\"result\":\"rate_limit\",\"warning\":\"\(warning)\"}")
        exit(70)
    }
    guard let contacts = localContactSearchResults() else {
        print("{\"result\":\"search_error\",\"reason\":\"results_unavailable\"}")
        exit(123)
    }
    let titles = contacts.map { stringAttr($0, kAXTitleAttribute as String) }
    let payload: [String: Any] = ["result": "friend_check", "localCount": titles.count, "titles": titles]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    print(String(data: data, encoding: .utf8)!)

case "search":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    guard let field = enterSearch(CommandLine.arguments[2]) else {
        fputs("Search field not found\n", stderr)
        exit(3)
    }
    print("SEARCH_VALUE=" + stringAttr(field, kAXValueAttribute as String))

case "press-title", "press-id", "click-title", "click-id":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let needle = CommandLine.arguments[2]
    let byTitle = command == "press-title" || command == "click-title"
    guard let element = byTitle ? find(title: needle) : find(identifier: needle) else {
        fputs("Element not found: \(needle)\n", stderr)
        exit(4)
    }
    if command == "click-title" || command == "click-id" {
        print("CLICKED=\(click(element))")
    } else {
        print("PRESS_ERROR=\(AXUIElementPerformAction(element, kAXPressAction as CFString).rawValue)")
    }

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
          let searchField = find(addWindow, role: kAXTextAreaRole as String, title: "搜索"),
          let searchButton = find(addWindow, role: kAXButtonRole as String, title: "搜索") else {
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
    guard let addButton = find(addWindow, role: kAXButtonRole as String, identifier: "add_friend_button") else {
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
    guard let form = waitFor(role: kAXWindowRole as String, title: "申请添加朋友"),
          let requestField = find(form, role: kAXTextAreaRole as String, title: "发送添加朋友申请"),
          let remarkField = find(form, role: kAXTextFieldRole as String, title: "修改备注") else {
        fputs("Request form did not open\n", stderr)
        exit(25)
    }
    AXUIElementPerformAction(form, kAXRaiseAction as CFString)
    guard paste(requestText, into: requestField), paste(remarkText, into: remarkField) else {
        fputs("Request-form readback mismatch\n", stderr)
        exit(26)
    }
    guard let confirm = find(form, role: kAXButtonRole as String, title: "确定"), click(confirm) else {
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
            stringAttr($0, kAXTitleAttribute as String) == "已发送" ||
            stringAttr($0, kAXValueAttribute as String) == "已发送"
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
    print("RESULT=SENT CONTACT=\(contact)")

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
    guard let contacts = localContactSearchResults() else {
        fputs("Main search results unavailable\n", stderr)
        exit(123)
    }
    guard contacts.count == 1 else {
        print("RESULT=NOT_EXISTING_FRIEND LOCAL_MATCHES=\(contacts.count)")
        exit(0)
    }
    let currentTitle = stringAttr(contacts[0], kAXTitleAttribute as String)
    guard click(contacts[0]) else { exit(101) }

    let chatDeadline = Date().addingTimeInterval(6.0)
    var opened = false
    repeat {
        if let current = find(identifier: "current_chat_name_label") {
            let value = stringAttr(current, kAXValueAttribute as String)
            opened = value == currentTitle || value == expectedRemark
        }
        if opened { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < chatDeadline
    guard opened else {
        fputs("Existing-friend chat did not open\n", stderr)
        exit(102)
    }

    var member: AXUIElement?
    let panelDeadline = Date().addingTimeInterval(1.0)
    repeat {
        if let candidate = find(identifier: "single_chat_member_cell") {
            let title = stringAttr(candidate, kAXTitleAttribute as String)
            if title == currentTitle || title == expectedRemark { member = candidate }
        }
        if member != nil { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < panelDeadline
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
        let code = updateRemark(expectedRemark, openEditor: true)
        guard code == 0 else { exit(code) }
        remarkWasChanged = true
    }

    guard let window = mainWindow() else { exit(110) }
    finish(sendGreeting(in: window, expected: expectedRemark, greeting: greeting),
           sent: "EXISTING_FRIEND_COMPLETED",
           already: "EXISTING_FRIEND_ALREADY_GREETED",
           suffix: " REMARK_CHANGED=\(remarkWasChanged)")

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
    let code = updateRemark(newRemark, openEditor: false)
    guard code == 0 else { exit(code) }
    print("RESULT=REMARK_SAVED")

case "main-search-and-greet":
    guard CommandLine.arguments.count >= 4 else { exit(2) }
    let expectedRemark = CommandLine.arguments[2]
    let greeting = CommandLine.arguments[3]
    if let warning = frequencyWarning() {
        print("RESULT=RATE_LIMIT WARNING=\(warning)")
        exit(70)
    }
    guard let window = mainWindow(), searchTextArea(in: window) != nil else {
        fputs("WeChat main search is not ready\n", stderr)
        exit(71)
    }
    guard let field = enterSearch(expectedRemark),
          stringAttr(field, kAXValueAttribute as String) == expectedRemark else {
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
        stringAttr($0, kAXIdentifierAttribute as String).hasPrefix("search_item_")
    }
    guard exactResults.count == 1 else {
        print("RESULT=NOT_IN_MAIN_SEARCH MATCHES=\(exactResults.count)")
        exit(0)
    }
    guard click(exactResults[0]) else {
        fputs("Exact main-search result could not be clicked\n", stderr)
        exit(73)
    }
    let chatDeadline = Date().addingTimeInterval(6.0)
    var chatOpened = false
    repeat {
        if let current = find(identifier: "current_chat_name_label") {
            chatOpened = stringAttr(current, kAXValueAttribute as String) == expectedRemark
        }
        if chatOpened { break }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < chatDeadline
    guard chatOpened else {
        fputs("Exact main-search chat did not open\n", stderr)
        exit(74)
    }
    let chatWindow = mainWindow() ?? window
    finish(sendGreeting(in: chatWindow, expected: expectedRemark, greeting: greeting),
           sent: "GREETING_SENT",
           already: "GREETING_ALREADY_PRESENT")

case "greet-current-chat":
    guard CommandLine.arguments.count >= 4 else { exit(2) }
    let expectedRemark = CommandLine.arguments[2]
    let greeting = CommandLine.arguments[3]
    guard let window = mainWindow() else {
        fputs("Exact current chat not ready\n", stderr)
        exit(117)
    }
    finish(sendGreeting(in: window, expected: expectedRemark, greeting: greeting),
           sent: "GREETING_SENT",
           already: "GREETING_ALREADY_PRESENT")

case "remove-chat-draft-prefix":
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    let injectedPrefix = CommandLine.arguments[2]
    guard let window = mainWindow(),
          let input = find(window, role: kAXTextAreaRole as String, identifier: "chat_input_field") else {
        fputs("Chat input not found\n", stderr)
        exit(80)
    }
    let current = stringAttr(input, kAXValueAttribute as String)
    guard current.hasPrefix(injectedPrefix) else {
        fputs("Chat draft does not start with the injected text; left unchanged\n", stderr)
        exit(81)
    }
    let remainder = String(current.dropFirst(injectedPrefix.count))
    guard AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, remainder as CFString) == .success,
          stringAttr(input, kAXValueAttribute as String) == remainder else {
        fputs("Could not restore chat draft\n", stderr)
        exit(82)
    }
    print("RESULT=DRAFT_RESTORED REMAINING_LENGTH=\(remainder.count)")

default:
    fputs("Unknown command\n", stderr)
    exit(2)
}
