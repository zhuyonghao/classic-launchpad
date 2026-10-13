import AppKit

@MainActor
func runDockDragTests() throws {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    // Use a private pasteboard only; these checks never contact or modify Dock.
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let appURL = URL(fileURLWithPath: "/Applications/测试 App.app")
    let payload = LauncherDragPayload(itemID: appURL.path, folderID: "source-folder")
    guard let item = LauncherIconInteractionView.dragPasteboardItem(payload: payload, applicationURL: appURL) else {
        throw Failure(description: "application drag creates a pasteboard item")
    }
    try check(pasteboard.writeObjects([item]), "application drag writes to a private pasteboard")
    try check(pasteboard.pasteboardItems?.count == 1, "application drag exports one item, avoiding duplicate destinations")
    guard let writtenItem = pasteboard.pasteboardItems?.first,
          let data = writtenItem.data(forType: LauncherIconInteractionView.pasteboardType) else {
        throw Failure(description: "application drag retains its internal payload")
    }
    let decoded = try JSONDecoder().decode(LauncherDragPayload.self, from: data)
    try check(decoded.itemID == payload.itemID && decoded.folderID == payload.folderID,
              "an application dragged from a folder retains its internal source")
    try check(writtenItem.string(forType: .fileURL).flatMap(URL.init(string:)) == appURL,
              "the same item exports a standard file URL with spaces and Unicode intact")
    let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    try check(fileURLs == [appURL], "AppKit file URL consumers can read the application")

    let folderPayload = LauncherDragPayload(itemID: "folder", folderID: nil)
    let folderItem = LauncherIconInteractionView.dragPasteboardItem(payload: folderPayload, applicationURL: nil)
    try check(folderItem?.data(forType: LauncherIconInteractionView.pasteboardType) != nil,
              "folder drag keeps its internal representation")
    try check(folderItem?.string(forType: .fileURL) == nil, "folder drag cannot export a file URL")
    for invalidURL in [URL(string: "https://example.com/Example.app")!, URL(fileURLWithPath: "/tmp/document.txt")] {
        let invalidItem = LauncherIconInteractionView.dragPasteboardItem(payload: folderPayload, applicationURL: invalidURL)
        try check(invalidItem?.string(forType: .fileURL) == nil, "only application file URLs are exported")
        try check(LauncherIconInteractionView.sourceOperationMask(for: .outsideApplication, applicationURL: invalidURL).isEmpty,
                  "invalid external URLs cannot offer a Dock drop")
    }

    let internalMask = LauncherIconInteractionView.sourceOperationMask(for: .withinApplication, applicationURL: appURL)
    let externalMask = LauncherIconInteractionView.sourceOperationMask(for: .outsideApplication, applicationURL: appURL)
    try check(internalMask == .move, "internal application drags preserve rearranging")
    try check(LauncherIconInteractionView.sourceOperationMask(for: .withinApplication, applicationURL: nil) == .move,
              "folder drags remain movable internally")
    try check(externalMask.contains(.link) && externalMask.contains(.copy) && !externalMask.contains(.move),
              "external application drags offer references and never move the bundle")
    try check(LauncherIconInteractionView.sourceOperationMask(for: .outsideApplication, applicationURL: nil).isEmpty,
              "folder drags remain internal")
    try check(LauncherIconInteractionView.clampedHorizontalFraction(x: -10, width: 100) == 0 &&
              LauncherIconInteractionView.clampedHorizontalFraction(x: 25, width: 100) == 0.25 &&
              LauncherIconInteractionView.clampedHorizontalFraction(x: 110, width: 100) == 1 &&
              LauncherIconInteractionView.clampedHorizontalFraction(x: 5, width: 0) == 1,
              "drop previews and commits use the same bounded horizontal position")
    print("PASS: Dock file URL export, internal folder payloads, external reference operations, and drop position bounds")
}
