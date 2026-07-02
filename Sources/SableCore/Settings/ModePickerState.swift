import Foundation

public struct ModePickerState: Equatable, Sendable {
    public private(set) var modes: [SableMode]
    public private(set) var query: String
    public private(set) var highlightedModeID: UUID?

    public init(modes: [SableMode] = [], query: String = "", highlightedModeID: UUID? = nil) {
        self.modes = modes
        self.query = query
        self.highlightedModeID = highlightedModeID
        syncHighlightedMode()
    }

    public var visibleModes: [SableMode] {
        ModeSearch.filter(modes, query: query)
    }

    public var selectedModeID: UUID? {
        highlightedModeID ?? visibleModes.first?.id
    }

    public mutating func configure(modes: [SableMode], initialModeID: UUID?) {
        self.modes = modes
        query = ""
        syncHighlightedMode(preferredID: initialModeID)
    }

    public mutating func setQuery(_ query: String) {
        self.query = query
        syncHighlightedMode()
    }

    public mutating func highlight(_ id: UUID) {
        guard visibleModes.contains(where: { $0.id == id }) else { return }
        highlightedModeID = id
    }

    public mutating func selectNext() {
        moveHighlight(by: 1)
    }

    public mutating func selectPrevious() {
        moveHighlight(by: -1)
    }

    private mutating func syncHighlightedMode(preferredID: UUID? = nil) {
        let visibleModes = self.visibleModes
        guard !visibleModes.isEmpty else {
            highlightedModeID = nil
            return
        }

        if let preferredID, visibleModes.contains(where: { $0.id == preferredID }) {
            highlightedModeID = preferredID
            return
        }

        if let highlightedModeID, visibleModes.contains(where: { $0.id == highlightedModeID }) {
            return
        }

        highlightedModeID = visibleModes.first?.id
    }

    private mutating func moveHighlight(by offset: Int) {
        let visibleModes = self.visibleModes
        guard !visibleModes.isEmpty else {
            highlightedModeID = nil
            return
        }

        let currentIndex = highlightedModeID.flatMap { id in
            visibleModes.firstIndex { $0.id == id }
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + visibleModes.count) % visibleModes.count
        highlightedModeID = visibleModes[nextIndex].id
    }
}
