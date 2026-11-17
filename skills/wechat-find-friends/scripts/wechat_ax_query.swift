import AppKit
import ApplicationServices
import Foundation

// The same pure snapshot classifier serves live reads and offline regression tests.
typealias UIRow = [String: Any]
func text(_ row: UIRow, _ key: String) -> String { row[key] as? String ?? "" }
func inside(_ path: String, _ parent: String) -> Bool { path.hasPrefix(parent + ".") }
func frame(_ row: UIRow) -> [Double]? {
    guard let f = row["frame"] as? [Double], f.count == 4,
          f.allSatisfy({ $0.isFinite }), f[2] > 0, f[3] > 0 else { return nil }
    return f
}
func mainWindowPaths(_ rows: [UIRow]) -> [String] {
    rows.filter { text($0,"AXRole") == "AXWindow" }.compactMap { window in
        let path = text(window,"path")
        let content = rows.filter { inside(text($0,"path"),path) }
        // Titles vary with macOS/WeChat versions; inspect controls instead.
        let hasChat = content.contains { text($0,"AXIdentifier") == "chat_input_field" }
        let hasSearch = content.contains { text($0,"AXIdentifier") == "search_list" }
        let isHistory = text(window,"AXTitle") == "搜索聊天记录"
        return hasChat || (hasSearch && !isHistory) ? path : nil
    }
}
func rateLimited(_ rows: [UIRow]) -> Bool {
    let excluded = rows.filter {
        ["chat_message_list", "search_list", "chat_input_field"].contains(text($0,"AXIdentifier"))
    }.map { text($0,"path") }
    return rows.contains { row in
        guard text(row,"AXRole") == "AXStaticText",
              !excluded.contains(where: { text(row,"path") == $0 || inside(text(row,"path"),$0) }) else { return false }
        let value = ["AXTitle", "AXValue", "AXDescription"].map { text(row,$0) }.joined(separator:" ")
        return ["操作太频繁", "操作频繁", "过于频繁", "频率过快", "请稍后再试"].contains { value.contains($0) }
    }
}
func inspectSearch(_ rows: [UIRow]) -> UIRow {
    func unavailable(_ reason: String) -> UIRow { ["result":"search_error", "reason":reason] }
    if rateLimited(rows) { return ["result":"rate_limit"] }
    let windows = mainWindowPaths(rows)
    guard windows.count == 1 else { return unavailable("main_window_not_unique") }
    let lists = rows.filter { text($0,"AXIdentifier") == "search_list" && inside(text($0,"path"),windows[0]) }
    guard lists.count == 1 else { return unavailable("results_unavailable") }
    let content = rows.filter { inside(text($0,"path"),text(lists[0],"path")) }
    let rawItems = content.filter { text($0,"AXIdentifier").hasPrefix("search_item_") }
    // A wrapper and its child may expose the same identifier; count the outer row once.
    let items = rawItems.filter { row in !rawItems.contains { inside(text(row,"path"),text($0,"path")) } }
    let headers = content.filter { row in
        text(row,"AXRole") == "AXStaticText" && text(row,"AXIdentifier").isEmpty &&
        !text(row,"AXTitle").isEmpty && !items.contains { inside(text(row,"path"),text($0,"path")) }
    }
    let local: Set<String> = ["联系人", "最常使用"]
    let known = local.union(["群聊", "聊天记录", "公众号", "小程序", "搜索网络结果"])
    guard headers.contains(where:{ known.contains(text($0,"AXTitle")) }) else { return unavailable("sections_unrecognized") }
    guard headers.allSatisfy({ frame($0) != nil }), items.allSatisfy({ frame($0) != nil }) else {
        return unavailable("result_geometry_unavailable")
    }
    let sorted = headers.sorted { frame($0)![1] < frame($1)![1] }
    var matches: [UIRow] = []
    for row in items {
        guard let section = sorted.last(where:{ frame($0)![1] < frame(row)![1] }) else {
            return unavailable("result_section_unrecognized")
        }
        guard known.contains(text(section,"AXTitle")) else { return unavailable("result_section_unrecognized") }
        if local.contains(text(section,"AXTitle")) {
            matches.append(["path":text(row,"path"), "title":text(row,"AXTitle"),
                            "identifier":text(row,"AXIdentifier"), "section":text(section,"AXTitle")])
        }
    }
    return ["result":"friend_check", "scope":"visible_results", "localCount":matches.count,
            "matches":matches, "main_window_path":windows[0]]
}
func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted])
    print(String(data:data,encoding:.utf8)!)
}
func emitInspection(_ rows: [UIRow]) -> Never {
    let result = inspectSearch(rows)
    emit(result)
    exit(text(result,"result") == "rate_limit" ? 70 : text(result,"result") == "search_error" ? 123 : 0)
}

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "dump"
if cmd == "--help" {
    print("""
    dump
    inspect-snapshot FILE       Classify a saved dump offline; never accesses WeChat
    check-friend TEXT           Search, then classify visible local-contact results
    search TEXT                 Main window search only
    search-history TEXT         Open history-search window only
    search-member TEXT          Open group-member search only
    click|double KIND VALUE      Unique, recently observed viewing target
    scroll KIND VALUE LINES
    close-window TITLE          Close a viewing window opened for this task
    KIND is AXIdentifier, AXTitle, or path. No message/remark submission command.
    """)
    exit(0)
}
if cmd == "inspect-snapshot" {
    guard args.count == 3, let data = try? Data(contentsOf:URL(fileURLWithPath:args[2])),
          let rows = (try? JSONSerialization.jsonObject(with:data)) as? [UIRow],
          rows.allSatisfy({ !text($0,"path").isEmpty }) else {
        fputs("Expected a saved JSON snapshot array\n",stderr);exit(3)
    }
    emitInspection(rows)
}
guard ["dump", "check-friend", "search", "search-history", "search-member", "click", "double", "scroll", "close-window"].contains(cmd) else {
    fputs("Unsupported command; use --help\n", stderr); exit(3)
}
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat")
guard apps.count == 1, let app = apps.first else { fputs("Expected one running WeChat instance\n", stderr); exit(2) }
guard AXIsProcessTrusted() else { fputs("Accessibility access unavailable\n", stderr); exit(2) }
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ n: String) -> String { attr(e,n).map { String(describing:$0) } ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e,"AXChildren") as? [AXUIElement] ?? [] }
func activate() {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, let url=app.bundleURL {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/open");p.arguments=[url.path];try? p.run();p.waitUntilExit()
    }
    app.activate(options:[])
    RunLoop.current.run(until:Date().addingTimeInterval(0.35))
}
func pos(_ e: AXUIElement) -> CGPoint? {
    guard let v = attr(e,"AXPosition"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(unsafeBitCast(v,to:AXValue.self),.cgPoint,&p) ? p : nil
}
func size(_ e: AXUIElement) -> CGSize? {
    guard let v = attr(e,"AXSize"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(unsafeBitCast(v,to:AXValue.self),.cgSize,&s) ? s : nil
}
var items: [(String,AXUIElement)] = []
var treeTruncated = false
var cachedRows: [UIRow]?
func walk(_ e: AXUIElement, _ path: String, _ depth: Int) {
    guard depth < 32, items.count < 15000 else { treeTruncated = true; return }
    items.append((path,e))
    for (i,c) in children(e).enumerated() { walk(c,path+".\(i)",depth+1) }
}
func refresh() {
    items.removeAll(); treeTruncated = false; cachedRows = nil
    walk(root,"0",0)
    guard !treeTruncated else {
        fputs("Accessibility tree exceeded traversal limits; stopping\n",stderr);exit(10)
    }
}
refresh()
func snapshotRows() -> [UIRow] {
    if let cachedRows { return cachedRows }
    var rows: [[String:Any]] = []
    let windowPaths=items.filter {str($0.1,"AXRole")=="AXWindow"}.map {$0.0}
    for (path,e) in items {
        if path != "0" && !windowPaths.contains(where:{path == $0 || path.hasPrefix($0+".")}) { continue }
        var row: [String:Any] = ["path":path]
        for n in ["AXRole","AXTitle","AXValue","AXDescription","AXIdentifier","AXEnabled","AXFocused","AXSelected"] {
            let v = str(e,n)
            if !v.isEmpty { row[n] = v }
        }
        if let p=pos(e), let s=size(e) { row["frame"]=[p.x,p.y,s.width,s.height] }
        var a: CFArray?
        AXUIElementCopyActionNames(e,&a)
        if let a=a as? [String], !a.isEmpty { row["actions"] = a }
        rows.append(row)
    }
    cachedRows = rows
    return rows
}
if cmd == "dump" { emit(snapshotRows()); exit(0) }
if rateLimited(snapshotRows()) { emit(["result":"rate_limit"]);exit(70) }
if cmd == "close-window" {
    guard args.count>=3 else {exit(3)}
    guard ["搜索聊天记录", "图片和视频"].contains(args[2]) else {fputs("Only search/media viewing windows can be closed\n",stderr);exit(4)}
    let windows=items.filter {str($0.1,"AXRole")=="AXWindow" && str($0.1,"AXTitle")==args[2]}
    guard windows.count==1,let b=attr(windows[0].1,"AXCloseButton"),CFGetTypeID(b)==AXUIElementGetTypeID() else {exit(4)}
    let button=unsafeBitCast(b,to:AXUIElement.self)
    print(AXUIElementPerformAction(button,"AXPress" as CFString).rawValue)
    exit(0)
}
if ["search", "check-friend", "search-member", "search-history"].contains(cmd) {
    guard args.count >= 3 else { exit(3) }
    if cmd != "search-history" && mainWindowPaths(snapshotRows()).isEmpty {
        let minimized = items.filter {
            let title = str($0.1,"AXTitle")
            return str($0.1,"AXRole") == "AXWindow" && str($0.1,"AXMinimized") == "1" &&
                (title == "微信" || title.hasPrefix("微信 (") || title.hasPrefix("微信("))
        }
        // Restore only a uniquely identified main window; never restart the app.
        if minimized.count == 1 {
            activate()
            AXUIElementSetAttributeValue(minimized[0].1,"AXMinimized" as CFString,kCFBooleanFalse)
            Thread.sleep(forTimeInterval:0.4);refresh()
        }
    }
    let histories=items.filter {str($0.1,"AXRole")=="AXWindow" && str($0.1,"AXTitle")=="搜索聊天记录"}
    let mainPaths=Set(mainWindowPaths(snapshotRows()))
    let mains=items.filter {mainPaths.contains($0.0)}
    let windows=cmd == "search-history" ? histories : mains
    guard windows.count == 1 else { fputs("Expected one target search window\n",stderr);exit(4) }
    let targetWindow=windows[0]
    let memberList=items.first {str($0.1,"AXIdentifier")=="chat_member_list" && $0.0.hasPrefix(targetWindow.0+".")}
    let chatEditor=items.first {str($0.1,"AXIdentifier")=="chat_input_field" && $0.0.hasPrefix(targetWindow.0+".")}
    let chatParent=chatEditor.map { $0.0.split(separator:".").dropLast(2).joined(separator:".")+"." }
    let memberParent=memberList.map { $0.0.split(separator:".").dropLast().joined(separator:".")+"." } ?? chatParent
    if cmd == "search-member" && memberParent == nil { exit(4) }
    func inSearchScope(_ item: (String, AXUIElement)) -> Bool {
        str(item.1,"AXTitle") == "搜索" && item.0.hasPrefix(targetWindow.0+".") &&
        (cmd == "search-member" ? item.0.hasPrefix(memberParent!) : (cmd == "search-history" || chatParent == nil || !item.0.hasPrefix(chatParent!)))
    }
    let fields=items.filter { str($0.1,"AXRole")=="AXTextArea" && inSearchScope($0) }
    if fields.isEmpty && (cmd == "search" || cmd == "check-friend") {
        let entries=items.filter { str($0.1,"AXRole")=="AXButton" && inSearchScope($0) }
        if entries.count == 1 {
            activate()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { exit(5) }
            AXUIElementPerformAction(entries[0].1,"AXPress" as CFString)
            Thread.sleep(forTimeInterval:0.3);refresh()
            // Layout paths can change after expanding a collapsed search entry.
            fputs("Search entry expanded; rerun once against the refreshed layout\n",stderr);exit(4)
        }
    }
    guard fields.count == 1 else { fputs("Search field is not unique\n",stderr); exit(4) }
    let e=fields[0].1
    activate()
    AXUIElementPerformAction(targetWindow.1,"AXRaise" as CFString)
    if let window=items.first(where:{str($0.1,"AXRole")=="AXWindow" && fields[0].0.hasPrefix($0.0+".")}) {
        AXUIElementPerformAction(window.1,"AXRaise" as CFString)
    }
    Thread.sleep(forTimeInterval:0.3)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,let p=pos(e),let s=size(e),s.width>0,s.height>0 else { exit(5) }
    let at=CGPoint(x:p.x+s.width/2,y:p.y+s.height/2)
    CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:at,mouseButton:.left)?.post(tap:.cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:at,mouseButton:.left)?.post(tap:.cghidEventTap)
    Thread.sleep(forTimeInterval:0.2)
    CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:at,mouseButton:.left)?.post(tap:.cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:at,mouseButton:.left)?.post(tap:.cghidEventTap)
    Thread.sleep(forTimeInterval:0.2)
    guard let f=attr(root,"AXFocusedUIElement"),CFGetTypeID(f)==AXUIElementGetTypeID() else { exit(6) }
    let focused=unsafeBitCast(f,to:AXUIElement.self)
    guard CFEqual(focused,e),str(focused,"AXRole")=="AXTextArea",str(focused,"AXTitle")=="搜索",str(focused,"AXIdentifier") != "chat_input_field" else { exit(7) }
    let pasteboard=NSPasteboard.general
    let saved=(pasteboard.pasteboardItems ?? []).map { old -> NSPasteboardItem in
        let item=NSPasteboardItem()
        for type in old.types { if let data=old.data(forType:type) {item.setData(data,forType:type)} }
        return item
    }
    pasteboard.clearContents();pasteboard.setString(args[2],forType:.string)
    let ourClipboardVersion=pasteboard.changeCount
    func restoreClipboard() {
        if pasteboard.changeCount == ourClipboardVersion {
            pasteboard.clearContents();if !saved.isEmpty {pasteboard.writeObjects(saved)}
        }
    }
    for (code,flags):(CGKeyCode,CGEventFlags) in [(0x00,.maskCommand),(0x33,[]),(0x09,.maskCommand)] {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let current=attr(root,"AXFocusedUIElement"), CFEqual(current,e) else { restoreClipboard();exit(8) }
        let down=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true),up=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:false)
        down?.flags=flags;up?.flags=flags;down?.post(tap:.cghidEventTap);usleep(60_000);up?.post(tap:.cghidEventTap);usleep(120_000)
    }
    Thread.sleep(forTimeInterval:1.8)
    guard str(e,"AXValue")==args[2] else { restoreClipboard();fputs("Search readback failed\n",stderr);exit(9) }
    restoreClipboard()
    refresh()
    if rateLimited(snapshotRows()) { emit(["result":"rate_limit"]);exit(70) }
    if cmd == "check-friend" { emitInspection(snapshotRows()) }
    print("search_verified");exit(0)
}
guard args.count >= 4 else { exit(3) }
let kind=args[2], value=args[3]
guard ["path","AXIdentifier","AXTitle"].contains(kind) else {exit(3)}
let matches = items.filter { kind == "path" ? $0.0 == value : str($0.1,kind) == value }
guard matches.count == 1 else { fputs("Expected unique element; found \(matches.count)\n",stderr); exit(4) }
let e=matches[0].1
let forbiddenIDs=Set(["chat_input_field","value_remark_view"])
let forbiddenTitles=Set(["发送","清空聊天记录","删除聊天记录","删除联系人","添加到通讯录"])
let lineage=items.filter {matches[0].0 == $0.0 || matches[0].0.hasPrefix($0.0+".")}
guard !lineage.contains(where:{forbiddenIDs.contains(str($0.1,"AXIdentifier")) || forbiddenTitles.contains(str($0.1,"AXTitle")) || forbiddenTitles.contains(str($0.1,"AXValue"))}) else {
    fputs("Mutation/input control is outside this query helper\n",stderr);exit(4)
}
activate()
for _ in 0..<20 {
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.tencent.xinWeChat" { break }
    RunLoop.current.run(until:Date().addingTimeInterval(0.1))
}
guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.tencent.xinWeChat" else { exit(5) }
if let window=items.first(where:{ str($0.1,"AXRole")=="AXWindow" && matches[0].0.hasPrefix($0.0+".") }) {
    AXUIElementPerformAction(window.1,"AXRaise" as CFString)
    Thread.sleep(forTimeInterval:0.2)
}
if cmd == "click" || cmd == "double" {
    guard let p=pos(e), let s=size(e), s.width>0,s.height>0 else { exit(6) }
    guard let x = args.count > 4 ? Double(args[4]) : 0.5,
          let y = args.count > 5 ? Double(args[5]) : 0.5,
          x.isFinite,y.isFinite,(0...1).contains(x),(0...1).contains(y),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { exit(6) }
    let at=CGPoint(x:p.x+s.width*x,y:p.y+s.height*y)
    let source=CGEventSource(stateID:.hidSystemState)
    for i in 1...(cmd == "double" ? 2 : 1) {
        let down=CGEvent(mouseEventSource:source,mouseType:.leftMouseDown,mouseCursorPosition:at,mouseButton:.left)
        let up=CGEvent(mouseEventSource:source,mouseType:.leftMouseUp,mouseCursorPosition:at,mouseButton:.left)
        down?.setIntegerValueField(.mouseEventClickState,value:Int64(i))
        up?.setIntegerValueField(.mouseEventClickState,value:Int64(i))
        down?.post(tap:.cghidEventTap); usleep(60_000); up?.post(tap:.cghidEventTap); usleep(90_000)
    }
    print("clicked")
} else if cmd == "scroll" {
    guard let p=pos(e),let s=size(e),s.width>0,s.height>0,args.count>4,let dy=Int32(args[4]),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { exit(7) }
    let at=CGPoint(x:p.x+s.width/2,y:p.y+s.height/2)
    CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:at,mouseButton:.left)?.post(tap:.cghidEventTap)
    usleep(100_000)
    let scroll=CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:dy,wheel2:0,wheel3:0)
    scroll?.location=at; scroll?.post(tap:.cghidEventTap)
    print("scrolled")
} else { exit(8) }
