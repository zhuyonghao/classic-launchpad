struct LauncherPageContext: Equatable {
    let folderID: String?
    let query: String
}

/// Retains visited native drag surfaces without building every page on open.
struct LauncherPageMountState {
    private(set) var context: LauncherPageContext?
    private(set) var pages: Set<Int> = []
    private(set) var lastPage: Int?

    mutating func visit(_ page: Int, in context: LauncherPageContext, isDragging: Bool) {
        if self.context != context && !isDragging {
            pages = [page]
            self.context = context
        } else {
            pages.insert(page)
        }
        lastPage = page
    }

    mutating func clear() {
        self = LauncherPageMountState()
    }

    func needsNeighbors(of page: Int, count: Int, in context: LauncherPageContext) -> Bool {
        self.context == context && [page - 1, page + 1].contains {
            $0 >= 0 && $0 < count && !pages.contains($0)
        }
    }

    mutating func prepareNeighbors(of page: Int, count: Int, in context: LauncherPageContext) {
        guard self.context == context else { return }
        for neighbor in [page - 1, page + 1] where neighbor >= 0 && neighbor < count {
            pages.insert(neighbor)
        }
    }

    func contains(_ page: Int, currentPage: Int, in context: LauncherPageContext, isDragging: Bool) -> Bool {
        page == currentPage || ((self.context == context || isDragging) && pages.contains(page))
    }

    func animatesTransition(to page: Int, in context: LauncherPageContext) -> Bool {
        guard self.context == context, let lastPage else { return false }
        return abs(page - lastPage) <= 1
    }
}
