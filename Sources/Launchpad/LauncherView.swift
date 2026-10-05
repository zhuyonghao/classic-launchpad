import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let launcherItemType = UTType(exportedAs: "com.local.ClassicLaunchpad.item", conformingTo: .data)

struct LauncherView: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject var session: LauncherSession
    @FocusState private var searchFocused: Bool

    private var allItems: [LauncherItem] { session.allItems(store) }
    private var pageCount: Int { max(1, Int(ceil(Double(allItems.count) / Double(session.pageSize)))) }
    private var visibleItems: [LauncherItem] {
        Array(allItems.dropFirst(min(session.page, pageCount - 1) * session.pageSize).prefix(session.pageSize))
    }
    private var openedFolder: LauncherItem? { store.items.first { $0.id == session.folderID } }
    private var pageAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    var body: some View {
        GeometryReader { geometry in
            let iconSize = min(100.0, max(56.0, (geometry.size.height - 225) / CGFloat(session.rows) - 33))
            let gridWidth = min(1340.0, geometry.size.width - 110)
            let cellWidth = gridWidth / CGFloat(session.columns)
            let rowHeight = max(iconSize + 35, (geometry.size.height - 225) / CGFloat(session.rows))
            ZStack {
                wallpaper(size: geometry.size)
                    .contentShape(Rectangle())
                    .onTapGesture { if session.folderID != nil { session.escape() } else { session.dismiss() } }
                    .onDrop(of: [launcherItemType], delegate: BackgroundDrop(store: store, session: session))

                VStack(spacing: 0) {
                    searchBar
                        .padding(.top, max(38, geometry.safeAreaInsets.top + 10))
                        .opacity(session.folderID == nil ? 1 : 0)
                        .allowsHitTesting(session.folderID == nil)
                    Spacer(minLength: 28)
                    if let folder = openedFolder {
                        folderPanel(folder, iconSize: iconSize, gridWidth: gridWidth, rowHeight: rowHeight)
                    } else if visibleItems.isEmpty {
                        emptyState
                            .frame(width: gridWidth, height: rowHeight * CGFloat(session.rows))
                    } else {
                        appGrid(iconSize: iconSize, cellWidth: cellWidth, rowHeight: rowHeight)
                            .frame(width: gridWidth, height: rowHeight * CGFloat(session.rows), alignment: .top)
                    }
                    Spacer(minLength: 18)
                    pageDots
                    Text(session.showsHint ? "左右轻扫或按 ⌘ ← → 翻页" : " ")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 13)
                        .padding(.bottom, 49)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let message = store.errorMessage {
                    VStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.circle")
                            Text(message).font(.system(size: 13)).lineLimit(3)
                            Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("关闭提示")
                        }
                        .padding(14)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 600)
                        .padding(.bottom, 100)
                    }
                }
            }
            .overlay(alignment: .leading) {
                edgeTarget(-1).frame(width: 36).allowsHitTesting(session.draggingID != nil)
            }
            .overlay(alignment: .trailing) {
                edgeTarget(1).frame(width: 36).allowsHitTesting(session.draggingID != nil)
            }
            .preferredColorScheme(.dark)
            .animation(pageAnimation, value: session.page)
            .animation(pageAnimation, value: session.folderID)
            .onAppear { configureGrid(geometry.size); searchFocused = true }
            .onChange(of: geometry.size) { _, size in configureGrid(size) }
        }
        .onChange(of: session.query) { _, _ in session.page = 0; session.selectedID = nil }
        .onChange(of: session.activationID) { _, _ in searchFocused = true }
        .onChange(of: session.folderID) { _, id in
            searchFocused = id == nil
        }
        .onChange(of: store.items) { _, items in
            if let id = session.folderID, !items.contains(where: { $0.id == id }) {
                session.folderID = nil
                session.page = 0
            }
            session.page = min(session.page, pageCount - 1)
        }
        .task {
            try? await Task.sleep(for: .seconds(10))
            withAnimation { session.showsHint = false }
        }
    }

    private func configureGrid(_ size: CGSize) {
        let columns = size.width < 900 ? 5 : 7
        let rows = size.height < 680 ? 4 : 5
        guard columns != session.columns || rows != session.rows else { return }
        let firstVisibleIndex = session.page * session.pageSize
        session.columns = columns
        session.rows = rows
        session.page = min(firstVisibleIndex / session.pageSize, pageCount - 1)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            TextField("搜索", text: $session.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .accessibilityLabel("搜索应用")
            if !session.query.isEmpty {
                Button { session.query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                }.buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 250, height: 30)
        .background(.black.opacity(0.19), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(searchFocused ? 0.48 : 0.27), lineWidth: 1))
    }

    @ViewBuilder private func wallpaper(size: CGSize) -> some View {
        ZStack {
            if let image = session.wallpaper {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: size.width + 80, height: size.height + 80)
                    .blur(radius: 30, opaque: true)
            } else {
                LinearGradient(colors: [Color(red: 0.13, green: 0.23, blue: 0.45),
                                        Color(red: 0.36, green: 0.40, blue: 0.59),
                                        Color(red: 0.64, green: 0.40, blue: 0.39)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse().fill(Color(red: 0.23, green: 0.53, blue: 0.61).opacity(0.7))
                    .frame(width: size.width * 0.95, height: size.height * 1.2)
                    .rotationEffect(.degrees(-35)).offset(x: -size.width * 0.3, y: size.height * 0.2)
                    .blur(radius: 100)
            }
            Color.black.opacity(session.folderID == nil ? 0.24 : 0.44)
            Rectangle().fill(.ultraThinMaterial).opacity(0.12)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .ignoresSafeArea()
    }

    private func appGrid(iconSize: CGFloat, cellWidth: CGFloat, rowHeight: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: 0), count: session.columns), spacing: 0) {
            ForEach(visibleItems) { item in
                appTile(item, iconSize: iconSize)
                    .frame(width: cellWidth, height: rowHeight, alignment: .top)
            }
        }
    }

    private func appTile(_ item: LauncherItem, iconSize: CGFloat) -> some View {
        let selected = session.selectedID == item.id
        return VStack(spacing: 5) {
            Group {
                if item.isFolder {
                    folderIcon(item, size: iconSize)
                } else if let app = store.app(for: item.appIDs.first ?? item.id) {
                    Image(nsImage: app.icon).resizable().interpolation(.high)
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 4)
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 19).fill(.white.opacity(selected ? 0.19 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(selected ? 0.45 : 0), lineWidth: 1))
            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 4)
        }
        .frame(width: iconSize + 45)
        .contentShape(Rectangle())
        .overlay {
            LauncherIconInteraction(
                id: item.id,
                name: item.name,
                image: item.isFolder ? NSImage(named: NSImage.folderName)! : (store.app(for: item.id)?.icon ?? NSImage()),
                sourceFolderID: session.folderID,
                onActivate: { session.activate(item, store: store) },
                onDragStarted: { payload in
                    session.draggingID = payload.itemID
                    session.dragFolderID = payload.folderID
                },
                onDragEnded: {
                    session.draggingID = nil
                    session.dragFolderID = nil
                    session.selectedID = nil
                },
                canDrop: { payload in
                    payload.itemID != item.id && (session.query.isEmpty || session.folderID != nil)
                },
                onDrop: { payload, fraction in
                    LauncherDropActions.onIcon(payload, target: item, horizontalFraction: fraction, store: store, session: session)
                },
                onTargetChanged: { targeted in
                    if targeted { session.selectedID = item.id }
                    else if session.selectedID == item.id { session.selectedID = nil }
                }
            )
        }
        .contextMenu {
            if item.isFolder {
                Button("打开文件夹") { session.activate(item, store: store) }
                Button("重命名…") { renameFolder(item) }
            } else if let app = store.app(for: item.appIDs.first ?? item.id) {
                Button("打开") { store.launch(app) }
                Button("在访达中显示") {
                    session.dismiss()
                    NSWorkspace.shared.activateFileViewerSelecting([app.url])
                }
                if let folderID = session.folderID {
                    Divider()
                    Button("移出文件夹") { store.moveAppOutOfFolder(appID: app.id, folderID: folderID) }
                } else {
                    let folders = store.items.filter { $0.isFolder }
                    if !folders.isEmpty {
                        Menu("移到文件夹") {
                            ForEach(folders) { folder in
                                Button(folder.name) { store.moveApp(app.id, toFolder: folder.id) }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.isFolder ? "文件夹，\(item.appIDs.count) 个应用" : "应用")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { session.activate(item, store: store) }
    }

    private func folderIcon(_ item: LauncherItem, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23)
                .fill(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.20)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.23).strokeBorder(.white.opacity(0.25)))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 3)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(size * 0.22), spacing: size * 0.015), count: 3), spacing: size * 0.015) {
                ForEach(Array(item.appIDs.prefix(9)), id: \.self) { id in
                    if let app = store.app(for: id) {
                        Image(nsImage: app.icon).resizable().frame(width: size * 0.22, height: size * 0.22)
                    }
                }
            }.frame(width: size * 0.78, height: size * 0.78, alignment: .top).padding(.top, size * 0.025)
        }.frame(width: size * 0.88, height: size * 0.88).frame(width: size, height: size)
    }

    private func folderPanel(_ folder: LauncherItem, iconSize: CGFloat, gridWidth: CGFloat, rowHeight: CGFloat) -> some View {
        let visibleRows = max(1, min(session.rows, Int(ceil(Double(visibleItems.count) / Double(session.columns)))))
        let availableHeight = rowHeight * CGFloat(session.rows)
        // The title, spacing, and panel padding also occupy the fixed grid area.
        let folderRowHeight = min(rowHeight, (availableHeight - 92) / CGFloat(visibleRows))
        let folderIconSize = min(iconSize, max(24, folderRowHeight - 35))
        return VStack(spacing: 22) {
            Button { renameFolder(folder) } label: {
                Text(folder.name).font(.system(size: 28, weight: .regular)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail)
            }.buttonStyle(.plain).help("点按以重命名文件夹")
            appGrid(iconSize: folderIconSize, cellWidth: (gridWidth - 40) / CGFloat(session.columns), rowHeight: folderRowHeight)
                .frame(width: gridWidth - 40, height: CGFloat(visibleRows) * folderRowHeight, alignment: .top)
        }
        .padding(.horizontal, 20)
        .padding(.top, 25).padding(.bottom, 10)
        .frame(width: gridWidth)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.18)))
        .frame(height: availableHeight, alignment: .center)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if store.isScanning {
                ProgressView().controlSize(.small)
                Text("正在查找应用…").font(.system(size: 15))
            } else {
                Image(systemName: session.query.isEmpty ? "square.grid.3x3" : "magnifyingglass")
                    .font(.system(size: 36, weight: .ultraLight)).padding(.bottom, 5)
                Text(session.query.isEmpty ? "暂未找到应用" : "没有找到“\(session.query)”")
                    .font(.system(size: 19, weight: .medium))
                Text(session.query.isEmpty ? "将应用放入“应用程序”文件夹后刷新。" : "试试其他名称、英文名称或拼音。")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                if session.query.isEmpty { Button("刷新应用") { store.refresh() }.padding(.top, 8) }
            }
        }.foregroundStyle(.white.opacity(0.9))
    }

    private var pageDots: some View {
        HStack(spacing: 13) {
            ForEach(0..<pageCount, id: \.self) { index in
                Button { session.page = index; session.selectedID = nil } label: {
                    Circle().fill(.white.opacity(index == session.page ? 0.95 : 0.32))
                        .frame(width: 7, height: 7)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(index + 1) 页，共 \(pageCount) 页")
                .accessibilityValue(index == session.page ? "当前页" : "")
            }
        }.frame(height: 21)
    }

    private func edgeTarget(_ direction: Int) -> some View {
        Rectangle().fill(.white.opacity(0.001))
            .onDrop(of: [launcherItemType], delegate: PageEdgeDrop(direction: direction, store: store, session: session))
    }

    private func renameFolder(_ folder: LauncherItem) {
        let alert = NSAlert()
        alert.messageText = "重命名文件夹"
        alert.addButton(withTitle: "完成")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: folder.name)
        field.identifier = NSUserInterfaceItemIdentifier("folderName")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            store.renameFolder(folder.id, name: field.stringValue)
        }
    }
}

@MainActor
enum LauncherDropActions {
    /// The native destination supplies the decoded payload; published UI state is
    /// only used to draw feedback, never to identify the item being moved.
    static func onIcon(_ payload: LauncherDragPayload, target: LauncherItem,
                       horizontalFraction: CGFloat, store: LauncherStore,
                       session: LauncherSession) -> Bool {
        let source = payload.itemID
        guard source != target.id, session.query.isEmpty || session.folderID != nil else { return false }
        if let sourceFolder = payload.folderID {
            guard store.items.contains(where: { $0.id == sourceFolder && $0.isFolder && $0.appIDs.contains(source) }) else { return false }
            if sourceFolder == session.folderID {
                store.reorderAppInFolder(sourceID: source, before: target.id, folderID: sourceFolder)
                return true
            }
            store.moveAppOutOfFolder(appID: source, folderID: sourceFolder)
        } else {
            guard store.items.contains(where: { $0.id == source }) else { return false }
        }
        if let folderID = session.folderID {
            store.moveApp(source, toFolder: folderID)
        } else if horizontalFraction < 0.25 {
            store.moveItem(source, before: target.id)
        } else if horizontalFraction > 0.75 {
            store.moveItem(source, after: target.id)
        } else {
            store.createFolder(sourceID: source, targetID: target.id)
        }
        return true
    }
}

private struct BackgroundDrop: DropDelegate {
    let store: LauncherStore
    let session: LauncherSession
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [launcherItemType]) && session.draggingID != nil
            && (session.query.isEmpty || session.folderID != nil)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let source = session.draggingID else { return false }
        if let folderID = session.dragFolderID {
            store.moveAppOutOfFolder(appID: source, folderID: folderID)
            session.folderID = nil
            session.page = 0
        } else if session.query.isEmpty {
            // A blank-space drop sends the item to the end of the current page.
            let remaining = store.items.filter { $0.id != source }
            let insertionIndex = min(remaining.count, (session.page + 1) * session.pageSize - 1)
            if insertionIndex < remaining.count {
                store.moveItem(source, before: remaining[insertionIndex].id)
            } else {
                store.moveItemToEnd(source)
            }
        }
        session.draggingID = nil
        session.dragFolderID = nil
        session.selectedID = nil
        return true
    }
}

private struct PageEdgeDrop: DropDelegate {
    let direction: Int
    let store: LauncherStore
    let session: LauncherSession
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [launcherItemType]) && session.draggingID != nil
            && (session.query.isEmpty || session.folderID != nil)
    }
    func dropEntered(info: DropInfo) { session.turnPage(direction, store: store) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { BackgroundDrop(store: store, session: session).performDrop(info: info) }
}
