import Foundation

/// Finds the node an ElementLocator describes. Pure over the AXNode protocol.
public enum ElementSearch {
    /// One search pass (no waiting). Each matcher is searched below the node chosen by the previous one.
    public static func find(_ locator: ElementLocator, roots: [any AXNode],
                            maxDepth: Int = ActionDefaults.maxDepth,
                            maxNodes: Int = ActionDefaults.maxNodes) -> (any AXNode)? {
        if locator.structuralFirst {
            return findStructural(locator, roots: roots) ?? findSemantic(locator, roots: roots, maxDepth: maxDepth, maxNodes: maxNodes)
        }
        return findSemantic(locator, roots: roots, maxDepth: maxDepth, maxNodes: maxNodes)
            ?? findStructural(locator, roots: roots)
    }

    /// Follows the recorded position: the window, then role + index among same-role siblings at each level.
    /// The node found must have the role of the locator's last matcher.
    static func findStructural(_ locator: ElementLocator, roots: [any AXNode]) -> (any AXNode)? {
        guard let hops = locator.structural, !hops.isEmpty else { return nil }
        let windows = roots.filter { $0.role == "AXWindow" }
        let candidates = windows.isEmpty ? roots : windows
        guard !candidates.isEmpty else { return nil }
        var node: any AXNode
        if let title = locator.windowTitle, !title.isEmpty, let byTitle = candidates.first(where: { $0.title == title }) {
            node = byTitle
        } else if let i = locator.windowIndex, candidates.indices.contains(i) {
            node = candidates[i]
        } else if let first = candidates.first {
            node = first
        } else { return nil }
        for hop in hops {
            let same = node.children().filter { $0.role == hop.role }
            guard hop.index >= 0, hop.index < same.count else { return nil }
            node = same[hop.index]
        }
        if let want = locator.path.last?.role, !want.isEmpty, node.role != want { return nil }
        return node
    }

    static func findSemantic(_ locator: ElementLocator, roots: [any AXNode], maxDepth: Int, maxNodes: Int) -> (any AXNode)? {
        var scope = roots
        var found: (any AXNode)?
        var budget = maxNodes
        for matcher in locator.path {
            guard let hit = best(matcher, in: scope, maxDepth: maxDepth, budget: &budget) else { return nil }
            found = hit
            scope = hit.children()
        }
        return found
    }

    /// Breadth-first over `scope` and below. `index` counts among matches that share a parent (the siblings of
    /// one container; `scope` itself is one group), the same way the recorder counts. Returns the `index`-th
    /// match of the best rank within the first parent group that has that many.
    static func best(_ matcher: ElementMatcher, in scope: [any AXNode], maxDepth: Int,
                     budget: inout Int) -> (any AXNode)? {
        // rank -> parent groups in discovery order -> matches in order.
        var byRank: [Int: [Int: [any AXNode]]] = [:]
        var groupOrder: [Int: [Int]] = [:]
        let wanted = max(0, matcher.index ?? 0)
        var nextGroup = 1
        var level: [(node: any AXNode, group: Int)] = scope.map { ($0, 0) }
        var depth = 0
        while !level.isEmpty, depth < maxDepth, budget > 0 {
            var next: [(node: any AXNode, group: Int)] = []
            for (node, group) in level {
                if budget <= 0 { break }
                budget -= 1
                if let rank = matcher.rank(role: node.role, subrole: node.subrole, title: node.title,
                                           identifier: node.identifier, description: node.descriptionText) {
                    if byRank[rank]?[group] == nil { groupOrder[rank, default: []].append(group) }
                    byRank[rank, default: [:]][group, default: []].append(node)
                    if wanted == 0, rank == matcher.topRank { return node }
                }
                let kids = node.children()
                if !kids.isEmpty {
                    let id = nextGroup; nextGroup += 1
                    next.append(contentsOf: kids.map { ($0, id) })
                }
            }
            level = next
            depth += 1
        }
        for rank in stride(from: 3, through: 1, by: -1) {
            for group in groupOrder[rank] ?? [] {
                if let list = byRank[rank]?[group], wanted < list.count { return list[wanted] }
            }
        }
        return nil
    }

    /// Resolves a menu path ("File", "New Window") below a menu bar node, descending through AXMenu children.
    public static func menuItem(path: [String], in menuBar: any AXNode) -> (any AXNode)? {
        var current: any AXNode = menuBar
        for title in path {
            var candidates = current.children()
            // AXMenuBarItem / AXMenuItem hold an AXMenu whose children are the items.
            if candidates.count == 1, candidates[0].role == "AXMenu" { candidates = candidates[0].children() }
            guard let next = candidates.first(where: { $0.title == title })
                    ?? candidates.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(title) && !($0.title ?? "").isEmpty })
            else { return nil }
            current = next
        }
        return current
    }
}
