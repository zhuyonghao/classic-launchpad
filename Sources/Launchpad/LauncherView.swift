import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let launcherItemType = UTType(exportedAs: "com.local.ClassicLaunchpad.item", conformingTo: .data)

struct LauncherView: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject var session: LauncherSession
    @FocusState private var searchFocused: Bool
    @State private var folderNameDraft = ""
    @State private var mountedPages = LauncherPageMountState()

    private var allItems: [LauncherItem] { session.allItems(store) }
    private var pageCount: Int { max(1, Int(ceil(Double(allItems.count) / Double(session.pageSize)))) }
    private var currentPage: Int { max(0, min(session.page, pageCount - 1)) }
    private var pageContext: LauncherPageContext { LauncherPageContext(folderID: session.folderID, query: session.query) }
    private var visibleItems: [LauncherItem] {
        Array(allItems.dropFirst(currentPage * session.pageSize).prefix(session.pageSize))
    }
    private var openedFolder: LauncherItem? { store.items.first { $0.id == session.folderID && $0.isFolder } }
    private var mountedFolders: [LauncherItem] {
        var folders = session.dragSourceFolder.map { [$0] } ?? []
        if let openedFolder {
            if let index = folders.firstIndex(where: { $0.id == openedFolder.id }) { folders[index] = openedFolder }
            else { folders.append(openedFolder) }
        }
        return folders
    }
    private var folderAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)
    }
    private var dragHint: String {
        if session.folderID != nil { return "两侧调整顺序 · 停留在面板左右边缘翻页 · 拖到面板外移出" }
        if let id = session.draggingID, store.items.first(where: { $0.id == id })?.isFolder == true {
            return "两侧插入排序 · 中央合并文件夹 · 停留在边缘翻页"
        }
        if !session.query.isEmpty { return "拖到程序坞添加应用" }
        return "两侧插入排序 · 停留在文件夹中央展开 · 拖到程序坞添加应用"
    }
    private var pageAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    var body: some View {
        if session.isPresented {
            presentedLauncher
        } else {
            Color.clear
        }
    }

    private var presentedLauncher: some View {
        let adjacentApps = adjacentIconApps
        return launcherWithContentUpdates
            .task(id: dragPageTaskID) { await turnPagesWhileDragging() }
            .task(id: session.folderHoverTarget(store: store)) {
                if let id = session.folderHoverTarget(store: store) {
                    await session.openFolderAfterHover(id, store: store)
                }
            }
            .task(id: adjacentApps) { await prewarmAdjacentIcons(adjacentApps) }
            .task { await hideUsageHintAfterDelay() }
            .onAppear { recordMountedPage() }
            .onDisappear { mountedPages.clear() }
            .onReceive(session.paging.$isTracking.removeDuplicates()) { tracking in
                if tracking && mountedPages.needsNeighbors(of: currentPage, count: pageCount, in: pageContext) {
                    mountedPages.prepareNeighbors(of: currentPage, count: pageCount, in: pageContext)
                }
            }
            .onChange(of: pageCount) { _, _ in session.paging.cancel() }
    }

    private var launcherWithContentUpdates: some View {
        launcherWithSessionUpdates
            .onChange(of: session.folderID) { _, id in searchFocused = id == nil }
            .onChange(of: store.items) { _, items in updateVisibleItems(items) }
    }

    private var launcherWithSessionUpdates: some View {
        GeometryReader { geometry in
            launcherLayout(in: geometry)
        }
        .onChange(of: session.query) { _, query in
            session.page = query.isEmpty ? session.homePage : 0
            session.selectedID = nil
        }
        .onChange(of: session.page) { _, _ in
            session.rememberPage()
            recordMountedPage()
        }
        .onChange(of: pageContext) { _, _ in recordMountedPage() }
        .onChange(of: session.draggingID) { _, id in
            if id == nil { recordMountedPage() }
        }
        .onChange(of: session.activationID) { _, _ in searchFocused = true }
    }

    private func recordMountedPage() {
        mountedPages.visit(currentPage, in: pageContext, isDragging: session.draggingID != nil)
    }

    private var adjacentIconApps: [LauncherApp] {
        let items = allItems
        let current = currentPage
        let neighbors = [current - 1, current + 1].filter { $0 >= 0 && $0 < pageCount }
        var seen = Set<String>()
        return neighbors.flatMap { page in
            items.dropFirst(page * session.pageSize).prefix(session.pageSize).flatMap { item in
                item.appIDs.prefix(item.isFolder ? 9 : 1).compactMap { store.app(for: $0) }
            }
        }.filter { seen.insert($0.id).inserted }
    }

    @MainActor private func prewarmAdjacentIcons(_ apps: [LauncherApp]) async {
        guard !apps.isEmpty else { return }
        let context = pageContext
        let page = currentPage
        // Let the current page reach the screen before preparing the next swipe.
        do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        guard session.isPresented, !Task.isCancelled else { return }
        let warmup = Task.detached(priority: .utility) {
            for app in apps {
                guard !Task.isCancelled else { return }
                autoreleasepool { _ = app.icon }
            }
        }
        await withTaskCancellationHandler(operation: {
            await warmup.value
        }, onCancel: {
            warmup.cancel()
        })
        guard !Task.isCancelled, session.isPresented, pageContext == context, currentPage == page else { return }
        if mountedPages.needsNeighbors(of: page, count: pageCount, in: context) {
            mountedPages.prepareNeighbors(of: page, count: pageCount, in: context)
        }
    }

    private func launcherLayout(in geometry: GeometryProxy) -> some View {
        let iconSize: CGFloat = min(100, max(56, (geometry.size.height - 225) / CGFloat(session.rows) - 33))
        let gridWidth: CGFloat = min(1340, geometry.size.width - 110)
        let cellWidth: CGFloat = gridWidth / CGFloat(session.columns)
        let rowHeight: CGFloat = max(iconSize + 35, (geometry.size.height - 225) / CGFloat(session.rows))
        return launcherScene(size: geometry.size, topInset: geometry.safeAreaInsets.top,
                             iconSize: iconSize, gridWidth: gridWidth, cellWidth: cellWidth, rowHeight: rowHeight)
            .overlay(alignment: .leading) { pageEdgeOverlay(-1) }
            .overlay(alignment: .trailing) { pageEdgeOverlay(1) }
            .preferredColorScheme(.dark)
            .onAppear { configureGrid(geometry.size); searchFocused = true }
            .onChange(of: geometry.size) { _, size in configureGrid(size) }
    }

    private func launcherScene(size: CGSize, topInset: CGFloat, iconSize: CGFloat,
                               gridWidth: CGFloat, cellWidth: CGFloat, rowHeight: CGFloat) -> some View {
        ZStack {
            wallpaper(size: size)
                .contentShape(Rectangle())
                .onTapGesture { returnFromBlank() }
                .onDrop(of: [launcherItemType], delegate: BackgroundDrop(store: store, session: session))
            launcherContent(topInset: topInset, iconSize: iconSize,
                            gridWidth: gridWidth, cellWidth: cellWidth, rowHeight: rowHeight)
            if let message = store.errorMessage { errorBanner(message) }
        }
        .overlay { LauncherDragDestination(store: store, session: session) }
        .contextMenu {
            if session.folderID == nil && session.query.isEmpty && session.draggingID == nil && !session.isSelectingApps {
                Button {
                    searchFocused = false
                    session.beginAppSelection(store: store)
                } label: {
                    Label("批量整理", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private func launcherContent(topInset: CGFloat, iconSize: CGFloat,
                                 gridWidth: CGFloat, cellWidth: CGFloat, rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            organizerBar
                .padding(.top, max(38, topInset + 10))
                .opacity(session.folderID == nil ? 1 : 0)
                .allowsHitTesting(session.folderID == nil)
            Spacer(minLength: 28)
            launcherItems(iconSize: iconSize, gridWidth: gridWidth, cellWidth: cellWidth, rowHeight: rowHeight)
            Spacer(minLength: 18)
            pageDots
            usageHint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { returnFromBlank() } }
    }

    @ViewBuilder private func launcherItems(iconSize: CGFloat, gridWidth: CGFloat,
                                            cellWidth: CGFloat, rowHeight: CGFloat) -> some View {
        ZStack {
            if session.folderID == nil && visibleItems.isEmpty {
                emptyState.frame(width: gridWidth, height: rowHeight * CGFloat(session.rows))
            } else {
                pagedGrid(iconSize: iconSize, cellWidth: cellWidth, rowHeight: rowHeight)
                    .frame(width: gridWidth, height: rowHeight * CGFloat(session.rows), alignment: .top)
                    .opacity(session.folderID == nil ? 1 : 0)
                    .scaleEffect(session.folderID == nil ? 1 : 0.96)
                    .allowsHitTesting(session.folderID == nil)
                    .accessibilityHidden(session.folderID != nil)
            }
            // Retain the native source until AppKit ends the drag, even after
            // revealing the root grid and even if the drop dissolves the folder.
            ForEach(mountedFolders) { folder in
                folderPanel(folder, iconSize: iconSize, gridWidth: gridWidth, rowHeight: rowHeight)
                    .opacity(session.folderID == folder.id ? 1 : 0)
                    .scaleEffect(session.folderID == folder.id ? 1 : 0.92)
                    .allowsHitTesting(session.folderID == folder.id)
                    .accessibilityHidden(session.folderID != folder.id)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(folderAnimation, value: session.folderID)
    }

    private var usageHint: some View {
        Text(session.isSelectingApps ? "点按应用勾选 · 可跨页选择 · 点空白处退出" :
                (session.draggingID != nil ? dragHint : (session.showsHint ? "四指张开收起 · 左右轻扫或按 ⌘ ← → 翻页" : " ")))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(session.draggingID != nil ? 0.85 : 0.45))
            .padding(.top, 13)
            .padding(.bottom, 49)
            .allowsHitTesting(false)
    }

    private func errorBanner(_ message: String) -> some View {
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

    private func pageEdgeOverlay(_ direction: Int) -> some View {
        edgeTarget(direction)
            .frame(width: 36)
            .allowsHitTesting(session.draggingID != nil && session.editingFolderID == nil && session.folderID == nil)
            .opacity(session.folderID == nil ? 1 : 0)
    }

    private var dragPageTaskID: [String] {
        [session.draggingID ?? "", session.dragPageDirection.map(String.init) ?? ""]
    }

    @MainActor private func turnPagesWhileDragging() async {
        guard let direction = session.dragPageDirection, let dragID = session.draggingID else { return }
        do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
        while !Task.isCancelled && session.draggingID == dragID && session.dragPageDirection == direction {
            session.dropTarget = nil
            session.turnPage(direction, store: store)
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
        }
    }

    @MainActor private func hideUsageHintAfterDelay() async {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        withAnimation { session.showsHint = false }
    }

    private func updateVisibleItems(_ items: [LauncherItem]) {
        session.reconcileAppSelection(store: store)
        if let id = session.editingFolderID, !items.contains(where: { $0.id == id && $0.isFolder }) { finishRenaming() }
        if let id = session.folderID, !items.contains(where: { $0.id == id && $0.isFolder }) {
            session.folderID = nil
            session.page = session.homePage
        }
        session.page = min(session.page, pageCount - 1)
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

    private var organizerBar: some View {
        HStack(spacing: 14) {
            if session.isSelectingApps {
                Text("已选 \(session.selectedAppIDs.count) 个应用")
                    .foregroundStyle(.white).monospacedDigit()
                Button("合并为文件夹") {
                    if let id = session.mergeSelectedApps(store: store),
                       let folder = store.items.first(where: { $0.id == id }) {
                        renameFolder(folder)
                    }
                }
                .disabled(session.selectedAppIDs.count < 2)
                Button("取消") { session.cancelAppSelection(); searchFocused = true }
            } else {
                searchBar
            }
        }
        .font(.system(size: 13))
        .buttonStyle(.bordered)
        .frame(height: 30)
    }

    @ViewBuilder private func wallpaper(size: CGSize) -> some View {
        ZStack {
            if let image = session.wallpaper {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height)
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
                .animation(folderAnimation, value: session.folderID)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .ignoresSafeArea()
    }

    private func returnFromBlank() {
        if let id = session.editingFolderID { commitFolderName(folderID: id); return }
        if session.isSelectingApps {
            session.cancelAppSelection()
            searchFocused = true
            return
        }
        if session.folderID != nil { session.escape() }
        else { session.dismiss() }
    }

    private func pagedGrid(iconSize: CGFloat, cellWidth: CGFloat, rowHeight: CGFloat, rowCount: Int? = nil,
                           folder: LauncherItem? = nil) -> some View {
        let folderID = folder?.id
        let items: [LauncherItem] = folder.map { folder in
            folder.appIDs.compactMap { store.app(for: $0) }.map {
                LauncherItem(id: $0.id, name: $0.name, appIDs: [$0.id], isFolder: false)
            }
        } ?? (session.folderID == nil ? allItems : store.items)
        let width = cellWidth * CGFloat(session.columns)
        let height = rowHeight * CGFloat(rowCount ?? session.rows)
        let count = max(1, (items.count + session.pageSize - 1) / session.pageSize)
        let requestedPage = folderID == nil ? (session.folderID == nil ? session.page : session.homePage)
            : (session.folderID == folderID ? session.page : session.dragSourcePage)
        let current = max(0, min(requestedPage, count - 1))
        let context = LauncherPageContext(folderID: folderID, query: session.query)
        let active = context == pageContext
        return LauncherPagingSurface(paging: folderID == nil ? session.rootPaging : session.folderPaging, page: current, pageCount: count, preparedPages: mountedPages.pages, width: width, height: height,
                                     animatesPageChange: mountedPages.animatesTransition(to: current, in: context),
                                     isInteractionEnabled: active) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<count, id: \.self) { page in
                    Group {
                        if mountedPages.contains(page, currentPage: current, in: context, isDragging: session.draggingID != nil) {
                            appGrid(items: Array(items.dropFirst(page * session.pageSize).prefix(session.pageSize)),
                                    iconSize: iconSize, cellWidth: cellWidth, rowHeight: rowHeight, page: page, rowCount: rowCount ?? session.rows, folderID: folderID, isActive: active && page == current)
                        } else {
                            Color.clear
                        }
                    }
                        .frame(width: width, height: height, alignment: .top)
                        .allowsHitTesting(active && page == current)
                        .accessibilityHidden(!active || page != current)
                }
            }
        }
    }

    private func appGrid(items: [LauncherItem], iconSize: CGFloat, cellWidth: CGFloat, rowHeight: CGFloat, page: Int, rowCount: Int, folderID: String?, isActive: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<session.columns, id: \.self) { column in
                        let index = row * session.columns + column
                        if index < items.count {
                            appTile(items[index], iconSize: iconSize, cellWidth: cellWidth, rowHeight: rowHeight, page: page, folderID: folderID, isActive: isActive)
                        } else {
                            let slotIndex = page * session.pageSize + index
                            Color.clear.frame(width: cellWidth, height: rowHeight)
                                .overlay {
                                    LauncherEmptySlotFeedback(isTargeted: session.dropTarget == .slot(slotIndex), iconSize: iconSize)
                                }
                                .overlay {
                                    LauncherIconInteraction(id: "", name: "空位", image: NSImage(), sourceFolderID: folderID,
                                        onActivate: {}, onDragStarted: { _ in }, onDragEnded: {},
                                        canDrop: { payload in
                                            isActive && !session.isSelectingApps && (session.query.isEmpty || folderID != nil)
                                                && (folderID == nil || session.acceptsFolderDrop(payload))
                                        },
                                        onDrop: { payload, _ in
                                            LauncherDropActions.onSlot(payload, index: slotIndex, store: store, session: session)
                                        }, onTargetChanged: { targeted in
                                            if targeted { session.dropTarget = .slot(slotIndex) }
                                            else if session.dropTarget == .slot(slotIndex) { session.dropTarget = nil }
                                        }, onBlankClick: { returnFromBlank() }, isInteractionEnabled: isActive)
                                }
                        }
                    }
                }
            }
        }
    }

    private func appTile(_ item: LauncherItem, iconSize: CGFloat, cellWidth: CGFloat, rowHeight: CGFloat, page: Int, folderID: String?, isActive: Bool) -> some View {
        let selected = session.isSelectingApps ? session.selectedAppIDs.contains(item.id) : session.selectedID == item.id
        let placement = session.dropTarget?.placement(for: item.id)
        let merging = placement == .merge
        let query = session.query
        return LauncherTileFeedback(isFolder: item.isFolder || session.isSelectingApps, isActive: isActive,
            anchor: UnitPoint(x: 0.5, y: (iconSize + 10) / (2 * rowHeight)), onActivate: {
                if let id = session.editingFolderID { commitFolderName(folderID: id); return }
                guard session.isPresented, session.page == page, session.folderID == folderID,
                      session.query == query, session.draggingID == nil else { return }
                session.activate(item, store: store)
            }) {
            VStack(spacing: 5) {
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
                .background(RoundedRectangle(cornerRadius: 19).fill(merging ? Color.blue.opacity(0.3) : .white.opacity(selected ? 0.19 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(merging ? 0.85 : (selected ? 0.45 : 0)), lineWidth: merging ? 2 : 1))
                .animation(pageAnimation, value: selected)
                .modifier(LauncherBatchIconFeedback(id: item.id, isOrganizing: session.isSelectingApps && !item.isFolder,
                                                    isSelected: selected, isActive: isActive))
                .scaleEffect(merging && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.06 : 1)
                .animation(pageAnimation, value: merging)
                Text(merging ? (item.isFolder ? "加入“\(item.name)”" : "创建文件夹") : item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 4)
            }
            .frame(width: cellWidth, height: rowHeight, alignment: .top)
            .opacity(session.draggingID == item.id ? 0.35 : 1)
            .opacity(session.isSelectingApps && item.isFolder ? 0.45 : 1)
            .animation(pageAnimation, value: session.draggingID == item.id)
            .overlay { LauncherInsertionIndicator(placement: placement, height: iconSize + 16) }
            .contentShape(Rectangle())
        } interaction: { actions in
            LauncherIconInteraction(
                id: item.id,
                name: item.name,
                image: store.app(for: item.id)?.icon ?? NSImage(),
                sourceFolderID: folderID,
                onActivate: actions.activate,
                onDragStarted: { payload in
                    session.beginDrag(payload, exportsApplication: !item.isFolder,
                                      sourceFolder: store.items.first { $0.id == folderID && $0.isFolder })
                },
                onDragEnded: {
                    session.endDrag()
                    session.selectedID = nil
                },
                canDrop: { payload in
                    isActive && !session.isSelectingApps && payload.itemID != item.id && (session.query.isEmpty || folderID != nil)
                        && (folderID == nil || session.acceptsFolderDrop(payload))
                },
                onDrop: { payload, fraction in
                    LauncherDropActions.onIcon(payload, target: item, horizontalFraction: fraction, store: store, session: session)
                },
                onTargetChanged: { _ in },
                applicationURL: item.isFolder ? nil : store.app(for: item.appIDs.first ?? item.id)?.url,
                onDragMoved: { session.moveDrag(to: $0) },
                onDropLocationChanged: { fraction in
                    if let fraction {
                        let target = LauncherDropTarget.item(item.id, .resolve(horizontalFraction: fraction, inFolder: folderID != nil))
                        if session.dropTarget != target { session.dropTarget = target }
                    } else if session.dropTarget?.placement(for: item.id) != nil {
                        session.dropTarget = nil
                    }
                },
                activationSize: NSSize(width: iconSize + 10, height: iconSize + 35),
                onBlankClick: { returnFromBlank() },
                onPressedChanged: actions.setPressed,
                dragImageSize: NSSize(width: iconSize, height: iconSize),
                makeDragImage: item.isFolder ? {
                    let renderer = ImageRenderer(content: folderIcon(item, size: iconSize))
                    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
                    return renderer.nsImage
                } : nil,
                allowsDragging: !session.isSelectingApps,
                isInteractionEnabled: isActive
            )
        }
        .id(item.id)
        .contextMenu {
            if session.isSelectingApps {
                if !item.isFolder {
                    Button(selected ? "取消选择" : "选择应用") { session.toggleAppSelection(item.id, store: store) }
                }
            } else if item.isFolder {
                Button("打开文件夹") { session.activate(item, store: store) }
                Button("重命名") { renameFolder(item) }
                Divider()
                Button("一键解散文件夹") { store.dissolveFolder(item.id) }
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
                    if session.query.isEmpty {
                        Button("选择多个应用…") {
                            searchFocused = false
                            session.beginAppSelection(store: store, including: item.id)
                        }
                    }
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
        .accessibilityValue(session.isSelectingApps ? (item.isFolder ? "文件夹，不参与选择" : (selected ? "已选择" : "未选择")) :
                                (item.isFolder ? "文件夹，\(item.appIDs.count) 个应用" : "应用"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if let id = session.editingFolderID { commitFolderName(folderID: id) }
            else { session.activate(item, store: store) }
        }
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
        let visibleRows = max(1, min(session.rows, Int(ceil(Double(folder.appIDs.count) / Double(session.columns)))))
        let availableHeight = rowHeight * CGFloat(session.rows)
        // The title, spacing, and panel padding also occupy the fixed grid area.
        let folderRowHeight = min(rowHeight, (availableHeight - 102) / CGFloat(visibleRows))
        let folderIconSize = min(iconSize, max(24, folderRowHeight - 35))
        return VStack(spacing: 22) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Group {
                    if session.editingFolderID == folder.id {
                        LauncherFolderNameEditor(text: $folderNameDraft,
                            onCommit: { commitFolderName(folderID: folder.id) },
                            onCancel: { cancelFolderName(folderID: folder.id) })
                            .frame(width: min(gridWidth - 80, max(200, (folderNameDraft as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 28)]).width + 44)))
                            .id(folder.id)
                    } else {
                        Button { renameFolder(folder) } label: {
                            HStack(spacing: 10) {
                                Text(folder.name).font(.system(size: 28, weight: .regular)).foregroundStyle(.white)
                                    .lineLimit(1).truncationMode(.tail)
                                Image(systemName: "pencil").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 12)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).help("点按以重命名文件夹").accessibilityLabel("重命名文件夹“\(folder.name)”")
                    }
                }
                Menu {
                    Button("一键解散文件夹") { store.dissolveFolder(folder.id) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(.white.opacity(0.8))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("文件夹操作")
                .disabled(session.editingFolderID != nil || session.draggingID != nil)
                Spacer(minLength: 0)
            }
            .frame(height: 44)
            pagedGrid(iconSize: folderIconSize, cellWidth: (gridWidth - 40) / CGFloat(session.columns), rowHeight: folderRowHeight, rowCount: visibleRows, folder: folder)
                .frame(width: gridWidth - 40, height: CGFloat(visibleRows) * folderRowHeight, alignment: .top)
                .allowsHitTesting(session.editingFolderID == nil)
        }
        .padding(.horizontal, 20)
        .padding(.top, 25).padding(.bottom, 10)
        .frame(width: gridWidth)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.18)))
        .onDrop(of: [launcherItemType], delegate: BackgroundDrop(store: store, session: session, folderID: folder.id))
        .overlay(alignment: .leading) { folderPageEdge(-1, folderID: folder.id) }
        .overlay(alignment: .trailing) { folderPageEdge(1, folderID: folder.id) }
        .background {
            LauncherFolderFrameReader {
                if session.folderID == folder.id { session.folderPanelFrame = $0 }
            }
        }
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
        }.frame(height: 21).disabled(session.editingFolderID != nil)
    }

    private func folderPageEdge(_ direction: Int, folderID: String) -> some View {
        edgeTarget(direction, folderID: folderID)
            .frame(width: LauncherFolderDragEdge.width)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(session.draggingID != nil && session.folderID == folderID && session.editingFolderID == nil)
    }

    private func edgeTarget(_ direction: Int, folderID: String? = nil) -> some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.001))
            if session.dragPageDirection == direction {
                LinearGradient(colors: [.white.opacity(0.20), .clear],
                               startPoint: direction < 0 ? .leading : .trailing,
                               endPoint: direction < 0 ? .trailing : .leading)
                Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
        }
            .onDrop(of: [launcherItemType], delegate: PageEdgeDrop(direction: direction, store: store, session: session, folderID: folderID))
    }

    private func renameFolder(_ folder: LauncherItem) {
        guard session.draggingID == nil else { return }
        searchFocused = false
        if session.folderID != folder.id { session.activate(folder, store: store) }
        folderNameDraft = folder.name
        session.commitFolderRename = { commitFolderName(folderID: folder.id) }
        session.editingFolderID = folder.id
    }

    private func commitFolderName(folderID: String) {
        guard session.editingFolderID == folderID else { return }
        let name = folderNameDraft
        finishRenaming()
        store.renameFolder(folderID, name: name)
    }

    private func cancelFolderName(folderID: String) {
        guard session.editingFolderID == folderID else { return }
        finishRenaming()
    }

    private func finishRenaming() {
        session.editingFolderID = nil
        session.commitFolderRename = {}
        searchFocused = session.folderID == nil
    }
}

@MainActor
enum LauncherDropActions {
    static func canPlaceApp(_ payload: LauncherDragPayload, store: LauncherStore) -> Bool {
        guard store.app(for: payload.itemID) != nil else { return false }
        if let sourceFolder = payload.folderID {
            return store.items.contains { $0.id == sourceFolder && $0.isFolder && $0.appIDs.contains(payload.itemID) }
        }
        return store.items.contains { $0.id == payload.itemID && !$0.isFolder }
    }

    static func onPageBackground(_ payload: LauncherDragPayload, folderID: String?, store: LauncherStore, session: LauncherSession) -> Bool {
        guard !session.isSelectingApps else { return false }
        let insertionIndex: Int
        if let folderID {
            guard session.folderID == folderID else { return false }
            insertionIndex = (session.page + 1) * session.pageSize - 1
        } else {
            session.closeFolderForDrag()
            let remainingCount = store.items.count - (payload.folderID == nil ? 1 : 0)
            insertionIndex = min(remainingCount, (session.page + 1) * session.pageSize - 1)
        }
        guard onSlot(payload, index: insertionIndex, store: store, session: session) else { return false }
        session.dropTarget = nil
        session.dragPageDirection = nil
        session.selectedID = nil
        return true
    }

    static func onSlot(_ payload: LauncherDragPayload, index: Int, store: LauncherStore, session: LauncherSession) -> Bool {
        guard !session.isSelectingApps else { return false }
        if let folderID = session.folderID {
            guard session.acceptsFolderDrop(payload), canPlaceApp(payload, store: store) else { return false }
            return store.moveApp(payload.itemID, toFolder: folderID, at: index)
        }
        guard session.query.isEmpty else { return false }
        if let folderID = payload.folderID {
            guard store.items.contains(where: { $0.id == folderID && $0.isFolder && $0.appIDs.contains(payload.itemID) }) else { return false }
            store.moveAppOutOfFolder(appID: payload.itemID, folderID: folderID)
        }
        guard store.items.contains(where: { $0.id == payload.itemID }) else { return false }
        let remaining = store.items.filter { $0.id != payload.itemID }
        let destination = min(max(0, index), remaining.count)
        if destination < remaining.count { store.moveItem(payload.itemID, before: remaining[destination].id) }
        else { store.moveItemToEnd(payload.itemID) }
        return true
    }

    /// The native destination supplies the decoded payload; published UI state is
    /// only used to draw feedback, never to identify the item being moved.
    static func onIcon(_ payload: LauncherDragPayload, target: LauncherItem,
                       horizontalFraction: CGFloat, store: LauncherStore,
                       session: LauncherSession) -> Bool {
        let source = payload.itemID
        guard !session.isSelectingApps, source != target.id, session.query.isEmpty || session.folderID != nil else { return false }
        var targetID = target.id
        if let openFolder = session.folderID {
            guard let folder = store.items.first(where: { $0.id == openFolder && $0.isFolder }),
                  let targetIndex = folder.appIDs.firstIndex(of: target.id),
                  session.acceptsFolderDrop(payload), canPlaceApp(payload, store: store) else { return false }
            if payload.folderID == openFolder {
                store.reorderAppInFolder(sourceID: source, before: target.id, folderID: openFolder, after: horizontalFraction > 0.5)
                return true
            }
            return store.moveApp(source, toFolder: openFolder, at: targetIndex + (horizontalFraction > 0.5 ? 1 : 0))
        } else {
            guard store.items.contains(where: { $0.id == target.id }) else { return false }
        }
        if let sourceFolder = payload.folderID {
            guard store.items.contains(where: { $0.id == sourceFolder && $0.isFolder && $0.appIDs.contains(source) }) else { return false }
            if sourceFolder == target.id {
                // Dropping back into the original folder is a no-op. For a
                // side drop, keep targeting its surviving application if it
                // collapses while extracting the dragged member.
                if LauncherDropPlacement.resolve(horizontalFraction: horizontalFraction, inFolder: false) == .merge { return true }
                if target.appIDs.count == 2, let remaining = target.appIDs.first(where: { $0 != source }) {
                    targetID = remaining
                }
            }
            store.moveAppOutOfFolder(appID: source, folderID: sourceFolder)
        } else {
            guard store.items.contains(where: { $0.id == source }) else { return false }
        }
        if LauncherDropPlacement.resolve(horizontalFraction: horizontalFraction, inFolder: false) == .before {
            store.moveItem(source, before: targetID)
        } else if LauncherDropPlacement.resolve(horizontalFraction: horizontalFraction, inFolder: false) == .after {
            store.moveItem(source, after: targetID)
        } else {
            store.createFolder(sourceID: source, targetID: targetID)
        }
        return true
    }
}

private struct BackgroundDrop: DropDelegate {
    let store: LauncherStore
    let session: LauncherSession
    var folderID: String? = nil
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [launcherItemType]) && session.draggingID != nil
            && (session.query.isEmpty || session.folderID != nil)
            && !session.isSelectingApps && (folderID == nil || folderID == session.folderID)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let source = session.draggingID else { return false }
        let payload = LauncherDragPayload(itemID: source, folderID: session.dragFolderID)
        return LauncherDropActions.onPageBackground(payload, folderID: folderID, store: store, session: session)
    }
}

private struct PageEdgeDrop: DropDelegate {
    let direction: Int
    let store: LauncherStore
    let session: LauncherSession
    var folderID: String? = nil
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [launcherItemType]) && session.draggingID != nil
            && (session.query.isEmpty || session.folderID != nil)
            && folderID == session.folderID
    }
    func dropEntered(info: DropInfo) { session.dropTarget = nil; session.dragPageDirection = direction }
    func dropExited(info: DropInfo) {
        if session.dragPageDirection == direction { session.dragPageDirection = nil }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { BackgroundDrop(store: store, session: session, folderID: folderID).performDrop(info: info) }
}
