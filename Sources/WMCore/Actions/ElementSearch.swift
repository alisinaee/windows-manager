import Foundation

/// Finds the node an ElementLocator describes. Pure over the AXNode protocol.
public enum ElementSearch {
    /// One search pass (no waiting). Each matcher is searched below the node chosen by the previous one.
    public static func find(_ locator: ElementLocator, roots: [any AXNode],
                            maxDepth: Int = ActionDefaults.maxDepth,
                            maxNodes: Int = ActionDefaults.maxNodes) -> (any AXNode)? {
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

    /// Breadth-first over `scope` and below; returns the `index`-th node of the best rank.
    static func best(_ matcher: ElementMatcher, in scope: [any AXNode], maxDepth: Int,
                     budget: inout Int) -> (any AXNode)? {
        var byRank: [Int: [any AXNode]] = [:]
        let wanted = max(0, matcher.index ?? 0)
        var level = scope
        var depth = 0
        while !level.isEmpty, depth < maxDepth, budget > 0 {
            var next: [any AXNode] = []
            for node in level {
                if budget <= 0 { break }
                budget -= 1
                if let rank = matcher.rank(role: node.role, subrole: node.subrole, title: node.title,
                                           identifier: node.identifier, description: node.descriptionText) {
                    byRank[rank, default: []].append(node)
                    if rank == matcher.topRank, byRank[rank]!.count > wanted { return byRank[rank]![wanted] }
                }
                next.append(contentsOf: node.children())
            }
            level = next
            depth += 1
        }
        for rank in stride(from: 3, through: 1, by: -1) {
            if let list = byRank[rank], !list.isEmpty { return wanted < list.count ? list[wanted] : nil }
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
