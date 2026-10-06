import AppKit
import Combine
import Foundation

struct LauncherApp: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let bundleIdentifier: String

    var icon: NSImage {
        LauncherIconCache.image(for: url)
    }
}

enum LauncherIconCache {
    private static let images = NSCache<NSString, NSImage>()
    private static let lock = NSLock()

    static func removeAll() {
        lock.lock()
        images.removeAllObjects()
        lock.unlock()
    }

    static func image(for url: URL) -> NSImage {
        let path = url.standardizedFileURL.path
        let key = path as NSString
        // Serialize cache misses so concurrent readers receive the same image.
        lock.lock()
        defer { lock.unlock() }
        if let cached = images.object(forKey: key) { return cached }

        let original = NSWorkspace.shared.icon(forFile: path)
        let image = LauncherImageRenderer.rasterize(original, size: NSSize(width: 100, height: 100), pixelScale: 2, fill: false) ?? original
        images.totalCostLimit = 24 * 1024 * 1024
        images.setObject(image, forKey: key, cost: 200 * 200 * 4)
        return image
    }
}

struct LauncherItem: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var appIDs: [String]
    var isFolder: Bool
}

@MainActor
final class LauncherStore: ObservableObject {
    @Published var apps: [LauncherApp] = []
    @Published var items: [LauncherItem] = []
    @Published var isScanning = false
    @Published var errorMessage: String?

    private let layoutURL: URL
    private var searchIndex: [String: String] = [:]
    private var appsByID: [String: LauncherApp] = [:]

    init(automaticallyRefresh: Bool = true) {
        let environment = ProcessInfo.processInfo.environment
        let directory: URL
        if let override = environment["CLASSIC_LAUNCHPAD_DATA_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            directory = support.appendingPathComponent("com.local.ClassicLaunchpad", isDirectory: true)
        }
        layoutURL = directory.appendingPathComponent("layout.json")
        if FileManager.default.fileExists(atPath: layoutURL.path) {
            do {
                let saved = try JSONDecoder().decode(PersistedLayout.self, from: Data(contentsOf: layoutURL))
                if saved.version == 1 {
                    items = saved.items
                } else {
                    errorMessage = "此布局来自较新的启动台版本，将使用默认布局。"
                }
            } catch {
                errorMessage = "无法读取已保存的布局，将使用默认布局。"
            }
        }
        if automaticallyRefresh { refresh() }
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = AppCatalogScanner.scan()
            // Decode and rasterize every page's icons before publishing the
            // catalog, rather than doing file/icon work during a page animation.
            for app in result.apps { autoreleasepool { _ = app.icon } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apps = result.apps
                self.appsByID = Dictionary(uniqueKeysWithValues: result.apps.map { ($0.id, $0) })
                self.searchIndex = Dictionary(uniqueKeysWithValues: result.apps.map {
                    ($0.id, AppSearch.index(for: $0))
                })
                if self.items.isEmpty {
                    self.items = self.defaultLayout()
                } else {
                    self.reconcileLayout()
                }
                self.isScanning = false
                if let issue = result.issue { self.errorMessage = issue }
                // A transient scan failure must not erase the user's saved arrangement.
                if !result.apps.isEmpty { self.saveLayout() }
            }
        }
    }

    func app(for id: String) -> LauncherApp? {
        // The fallback also makes direct catalog replacement useful for previews and tests.
        appsByID[id] ?? apps.first { $0.id == id }
    }

    func search(_ query: String) -> [LauncherApp] {
        let terms = AppSearch.normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return apps }
        return apps.filter { app in
            let index = searchIndex[app.id] ?? AppSearch.index(for: app)
            return terms.allSatisfy { index.contains($0) }
        }
    }

    func moveItem(_ sourceID: String, before targetID: String) {
        guard sourceID != targetID,
              let sourceIndex = items.firstIndex(where: { $0.id == sourceID }),
              items.contains(where: { $0.id == targetID }) else { return }
        let moved = items.remove(at: sourceIndex)
        if let targetIndex = items.firstIndex(where: { $0.id == targetID }) {
            items.insert(moved, at: targetIndex)
        }
        saveLayout()
    }

    func moveItem(_ sourceID: String, after targetID: String) {
        guard sourceID != targetID,
              let sourceIndex = items.firstIndex(where: { $0.id == sourceID }),
              items.contains(where: { $0.id == targetID }) else { return }
        let moved = items.remove(at: sourceIndex)
        if let targetIndex = items.firstIndex(where: { $0.id == targetID }) {
            items.insert(moved, at: targetIndex + 1)
        }
        saveLayout()
    }

    func reorderAppInFolder(sourceID: String, before targetID: String, folderID: String, after: Bool = false) {
        guard sourceID != targetID,
              let folderIndex = items.firstIndex(where: { $0.id == folderID && $0.isFolder }),
              let sourceIndex = items[folderIndex].appIDs.firstIndex(of: sourceID),
              items[folderIndex].appIDs.contains(targetID) else { return }
        items[folderIndex].appIDs.remove(at: sourceIndex)
        if let targetIndex = items[folderIndex].appIDs.firstIndex(of: targetID) {
            items[folderIndex].appIDs.insert(sourceID, at: targetIndex + (after ? 1 : 0))
        }
        saveLayout()
    }

    @discardableResult
    func moveFolderMember(_ appID: String, to index: Int, folderID: String) -> Bool {
        guard let folderIndex = items.firstIndex(where: { $0.id == folderID && $0.isFolder }),
              let sourceIndex = items[folderIndex].appIDs.firstIndex(of: appID) else { return false }
        items[folderIndex].appIDs.remove(at: sourceIndex)
        items[folderIndex].appIDs.insert(appID, at: min(max(0, index), items[folderIndex].appIDs.count))
        saveLayout()
        return true
    }

    func moveItemToEnd(_ sourceID: String) {
        guard let index = items.firstIndex(where: { $0.id == sourceID }), index != items.count - 1 else { return }
        items.append(items.remove(at: index))
        saveLayout()
    }

    func createFolder(sourceID: String, targetID: String) {
        guard sourceID != targetID,
              let source = items.first(where: { $0.id == sourceID }),
              let target = items.first(where: { $0.id == targetID }) else { return }
        let merged = Self.unique(target.appIDs + source.appIDs)
        guard merged.count > 1 else { return }
        let folder = LauncherItem(
            id: target.isFolder ? target.id : UUID().uuidString,
            name: target.isFolder ? target.name : "文件夹",
            appIDs: merged,
            isFolder: true
        )
        items = items.compactMap { item in
            if item.id == sourceID { return nil }
            return item.id == targetID ? folder : item
        }
        saveLayout()
    }

    func renameFolder(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = items.firstIndex(where: { $0.id == id && $0.isFolder }) else { return }
        items[index].name = String(trimmed.prefix(80))
        saveLayout()
    }

    func moveAppOutOfFolder(appID: String, folderID: String) {
        guard let folderIndex = items.firstIndex(where: { $0.id == folderID && $0.isFolder }),
              items[folderIndex].appIDs.contains(appID), let app = app(for: appID) else { return }
        items[folderIndex].appIDs.removeAll { $0 == appID }
        let newItem = Self.item(for: app)
        if items[folderIndex].appIDs.isEmpty {
            items[folderIndex] = newItem
        } else {
            items.insert(newItem, at: folderIndex + 1)
        }
        saveLayout()
    }

    func moveApp(_ appID: String, toFolder folderID: String) {
        guard app(for: appID) != nil,
              let target = items.first(where: { $0.id == folderID && $0.isFolder }),
              !target.appIDs.contains(appID) else { return }
        items = items.compactMap { item in
            var updated = item
            if item.id == folderID {
                updated.appIDs.append(appID)
            } else {
                updated.appIDs.removeAll { $0 == appID }
            }
            return updated.appIDs.isEmpty ? nil : updated
        }
        saveLayout()
    }

    func resetLayout() {
        items = defaultLayout()
        saveLayout()
    }

    func launch(_ app: LauncherApp) {
        guard FileManager.default.fileExists(atPath: app.url.path) else {
            errorMessage = "找不到“\(app.name)”。请刷新应用列表后重试。"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.errorMessage = "无法打开“\(app.name)”：\(error.localizedDescription)"
                } else {
                    NSApplication.shared.hide(nil)
                }
            }
        }
    }

    private func reconcileLayout() {
        // Keep the loaded layout if no application directory could be read.
        guard !apps.isEmpty else { return }
        let validIDs = Set(apps.map(\.id))
        var seen = Set<String>()
        var folderIDs = Set<String>()
        items = items.compactMap { item in
            let appIDs = item.appIDs.filter { validIDs.contains($0) && seen.insert($0).inserted }
            guard !appIDs.isEmpty else { return nil }
            if item.isFolder {
                let folderID = validIDs.contains(item.id) || !folderIDs.insert(item.id).inserted
                    ? UUID().uuidString : item.id
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return LauncherItem(id: folderID, name: name.isEmpty ? "文件夹" : name, appIDs: appIDs, isFolder: true)
            }
            guard let app = app(for: appIDs[0]) else { return nil }
            // Ignore malformed extra IDs without making those applications disappear.
            for extraID in appIDs.dropFirst() { seen.remove(extraID) }
            return Self.item(for: app)
        }
        items.append(contentsOf: apps.filter { !seen.contains($0.id) }.map(Self.item(for:)))
    }

    private func defaultLayout() -> [LauncherItem] {
        let utilities = apps.filter { $0.url.path.hasPrefix("/System/Applications/Utilities/") }
        let utilityIDs = Set(utilities.map(\.id))
        var result = apps.filter { !utilityIDs.contains($0.id) }.map(Self.item(for:))
        if !utilities.isEmpty {
            let folder = LauncherItem(id: UUID().uuidString, name: "其他", appIDs: utilities.map(\.id), isFolder: true)
            let position = min(result.count, 20)
            result.insert(folder, at: position)
        }
        return result
    }

    private static func item(for app: LauncherApp) -> LauncherItem {
        LauncherItem(id: app.id, name: app.name, appIDs: [app.id], isFolder: false)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func saveLayout() {
        do {
            try FileManager.default.createDirectory(at: layoutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(PersistedLayout(version: 1, items: items))
            try data.write(to: layoutURL, options: .atomic)
        } catch {
            errorMessage = "无法保存启动台布局：\(error.localizedDescription)"
        }
    }
}

private struct PersistedLayout: Codable {
    let version: Int
    let items: [LauncherItem]
}

enum AppCatalogScanner {
    struct Result {
        var apps: [LauncherApp]
        var issue: String?
    }

    static func scan(roots customRoots: [URL]? = nil) -> Result {
        let fileManager = FileManager.default
        // Earlier roots win if an application is installed in more than one location.
        let roots = customRoots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true)
        ]
        var result: [LauncherApp] = []
        var seenPaths = Set<String>()
        var seenBundles = Set<String>()
        var readableRoots = 0

        func addApplication(at url: URL) {
            let standardized = url.standardizedFileURL
            guard !seenPaths.contains(standardized.path), let bundle = Bundle(url: standardized) else { return }
            let info = bundle.infoDictionary ?? [:]
            // Installed standalone apps can set both LSBackgroundOnly and
            // LSUIElement (BetterDisplay). Package boundaries exclude embedded
            // helpers; these flags must not hide launchable menu-bar utilities.
            // Launchpad itself is a launcher, rather than an application to launch inside it.
            let identifier = bundle.bundleIdentifier ?? standardized.path
            guard identifier != "com.local.ClassicLaunchpad", identifier != "com.apple.launchpad.launcher",
                  !seenBundles.contains(identifier) else { return }
            let localized = bundle.localizedInfoDictionary ?? [:]
            let candidates = [localized["CFBundleDisplayName"], localized["CFBundleName"], info["CFBundleDisplayName"]]
            let preferred = candidates.compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var name = preferred ?? fileManager.displayName(atPath: standardized.path)
            if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
            seenPaths.insert(standardized.path)
            seenBundles.insert(identifier)
            result.append(LauncherApp(id: standardized.path, name: name, url: standardized, bundleIdentifier: identifier))
        }

        func walk(_ directory: URL, depth: Int) {
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            if depth == 0 { readableRoots += 1 }
            for child in children.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                if child.pathExtension.lowercased() == "app" {
                    addApplication(at: child)
                    continue
                }
                guard depth < 16,
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                      values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { continue }
                walk(child, depth: depth + 1)
            }
        }

        for root in roots { walk(root, depth: 0) }
        if customRoots == nil && !seenBundles.contains("com.apple.Safari") {
            addApplication(at: URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications/Safari.app"))
        }
        let preferredOrder = [
            "com.apple.Safari", "com.apple.mail", "com.apple.AddressBook", "com.apple.iCal",
            "com.apple.reminders", "com.apple.Notes", "com.apple.Maps", "com.apple.Photos",
            "com.apple.FaceTime", "com.apple.MobileSMS", "com.apple.Music", "com.apple.TV",
            "com.apple.podcasts", "com.apple.news", "com.apple.iBooksX", "com.apple.AppStore",
            "com.apple.systempreferences", "com.apple.Passwords", "com.apple.freeform",
            "com.apple.iWork.Keynote", "com.apple.iWork.Numbers", "com.apple.iWork.Pages"
        ]
        let rank = Dictionary(uniqueKeysWithValues: preferredOrder.enumerated().map { ($1, $0) })
        result.sort {
            let left = rank[$0.bundleIdentifier] ?? Int.max
            let right = rank[$1.bundleIdentifier] ?? Int.max
            if left != right { return left < right }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Result(apps: result, issue: readableRoots == 0 ? "无法读取应用程序文件夹。请检查文件夹权限后重试。" : nil)
    }


}

private enum AppSearch {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    static func index(for app: LauncherApp) -> String {
        let name = normalized(app.name)
        let latin = normalized(app.name.applyingTransform(.toLatin, reverse: false) ?? app.name)
        let initials = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap(\.first).map(String.init).joined()
        let aliases = aliasesByBundle[app.bundleIdentifier] ?? ""
        let filename = app.url.deletingPathExtension().lastPathComponent
        return normalized([name, latin, latin.filter { !$0.isWhitespace }, initials, filename, app.bundleIdentifier, aliases].joined(separator: " "))
    }

    private static let aliasesByBundle: [String: String] = [
        "com.apple.Safari": "Safari 浏览器 苹果浏览器 网页 liulanqi",
        "com.apple.mail": "Mail 邮件 邮箱 youjian youxiang",
        "com.apple.AddressBook": "Contacts 通讯录 联系人 tongxunlu lianxiren",
        "com.apple.iCal": "Calendar 日历 rili",
        "com.apple.reminders": "Reminders 提醒事项 tixing shixiang",
        "com.apple.Notes": "Notes 备忘录 笔记 beiwanglu biji",
        "com.apple.Maps": "Maps 地图 ditu",
        "com.apple.Photos": "Photos 照片 相册 zhaopian xiangce",
        "com.apple.FaceTime": "FaceTime 通话 视频 tonghua shipin",
        "com.apple.MobileSMS": "Messages 信息 短信 xinxi duanxin",
        "com.apple.Music": "Music 音乐 yinyue",
        "com.apple.TV": "TV 电视 视频 dianshi shipin",
        "com.apple.podcasts": "Podcasts 播客 boke",
        "com.apple.news": "News 新闻 xinwen",
        "com.apple.iBooksX": "Books 图书 书籍 tushu shuji",
        "com.apple.AppStore": "App Store 商店 应用商店 shangdian yingyong",
        "com.apple.systempreferences": "System Settings Preferences 系统设置 偏好设置 xitong shezhi pianhao",
        "com.apple.Passwords": "Passwords 密码 mima",
        "com.apple.freeform": "Freeform 无边记 wubianji",
        "com.apple.calculator": "Calculator 计算器 jisuanqi",
        "com.apple.Preview": "Preview 预览 PDF yulan",
        "com.apple.TextEdit": "TextEdit 文本编辑 wenben bianji",
        "com.apple.QuickTimePlayerX": "QuickTime Player 播放器 视频 bofangqi shipin",
        "com.apple.Terminal": "Terminal 终端 命令行 zhongduan minglinghang",
        "com.apple.ActivityMonitor": "Activity Monitor 活动监视器 任务管理器 huodong jianshiqi renwu",
        "com.apple.DiskUtility": "Disk Utility 磁盘工具 cipan gongju",
        "com.apple.ScreenSharing": "Screen Sharing 屏幕共享 pingmu gongxiang",
        "com.apple.VoiceMemos": "Voice Memos 语音备忘录 录音 yuyin luyin",
        "com.apple.findmy": "Find My 查找 chazhao",
        "com.apple.Home": "Home 家庭 jiating",
        "com.apple.shortcuts": "Shortcuts 快捷指令 kuaijie zhiling",
        "com.apple.weather": "Weather 天气 tianqi",
        "com.apple.clock": "Clock 时钟 闹钟 shizhong naozhong",
        "com.apple.stocks": "Stocks 股市 gushi",
        "com.apple.iWork.Keynote": "Keynote 讲演 演示 jiangyan yanshi",
        "com.apple.iWork.Numbers": "Numbers 表格 电子表格 biaoge",
        "com.apple.iWork.Pages": "Pages 文稿 文档 wengao wendang",
        "com.tencent.xinWeChat": "WeChat 微信 weixin",
        "com.tencent.qq": "QQ 腾讯 tengxun",
        "com.google.Chrome": "Google Chrome 谷歌 浏览器 guge liulanqi",
        "com.microsoft.edgemac": "Microsoft Edge 微软 浏览器 weiruan liulanqi",
        "com.microsoft.VSCode": "Visual Studio Code VSCode 编辑器 bianjiqi"
    ]
}
