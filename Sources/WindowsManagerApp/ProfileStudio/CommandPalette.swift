import AppKit
import SwiftUI
import WMCore

/// One thing the palette can do.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let perform: () -> Void
}

/// Subsequence ("fuzzy") match: nil when the query letters do not appear in order; lower score is better.
enum PaletteFuzzy {
    static func score(query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let t = Array(text.lowercased())
        var qi = 0, score = 0, last = -1
        for (i, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += last < 0 ? i : (i - last - 1) * 2   // gaps cost; an early start costs less
            last = i
            qi += 1
        }
        return qi == q.count ? score : nil
    }
}

/// Opens the Cmd+K palette as a sheet on the Studio window.
@MainActor
enum CommandPaletteController {
    private static var sheet: NSWindow?

    static func present(studio: ProfileStudioModel) {
        guard sheet == nil, let host = NSApp.keyWindow, ProfileStudioModel.isStudioWindow(host) else { return }
        let items = makeItems(studio: studio)
        let view = CommandPaletteView(items: items, onClose: { dismiss() })
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        host.beginSheet(window) { _ in sheet = nil }
        sheet = window
    }

    static func dismiss() {
        guard let window = sheet else { return }
        window.sheetParent?.endSheet(window)
        sheet = nil
    }

    private static func makeItems(studio: ProfileStudioModel) -> [PaletteItem] {
        var items: [PaletteItem] = []
        items.append(PaletteItem(id: "capture", title: "Capture new profile", subtitle: "From your current windows",
                                 symbol: "camera.viewfinder") { studio.beginNewProfile() })
        for row in studio.rows {
            items.append(PaletteItem(id: "run:\(row.id)", title: "Run \(row.name)", subtitle: "Restore its windows now",
                                     symbol: "play.fill") { AppState.current?.run(id: row.id) })
            items.append(PaletteItem(id: "open:\(row.id)", title: "Open \(row.name) in Studio", subtitle: "Show the profile",
                                     symbol: "rectangle.3.group") { studio.requestSelect(row.id) })
        }
        return items
    }
}

/// Search field plus result list. Up / Down move, Return runs, Esc closes.
struct CommandPaletteView: View {
    let items: [PaletteItem]
    let onClose: () -> Void
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return items }
        return items.compactMap { item -> (PaletteItem, Int)? in
            PaletteFuzzy.score(query: q, in: item.title).map { (item, $0) }
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search profiles and actions", text: $query)
                .textFieldStyle(.plain).font(.wmSection)
                .padding(Spacing.m)
                .focused($focused)
                .onSubmit { performSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
                .accessibilityLabel("Command palette search")
                .help("Type to filter. Up / Down choose, Return runs, Esc closes")
            Divider()
            if results.isEmpty {
                Text("No matches").font(.wmBody).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(results, selection: $selection) { item in
                        row(item).tag(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = item.id; performSelected() }
                    }
                    .onChange(of: selection) { _, key in if let key { proxy.scrollTo(key) } }
                }
            }
        }
        .frame(width: 460, height: 340)
        .onAppear { focused = true; selection = results.first?.id }
        .onChange(of: query) { _, _ in selection = results.first?.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func row(_ item: PaletteItem) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: item.symbol).frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.wmBody).lineLimit(1)
                Text(item.subtitle).font(.wmCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func move(_ delta: Int) {
        let list = results
        guard !list.isEmpty else { return }
        let index = selection.flatMap { key in list.firstIndex { $0.id == key } } ?? (delta > 0 ? -1 : list.count)
        selection = list[min(max(index + delta, 0), list.count - 1)].id
    }

    private func performSelected() {
        guard let item = results.first(where: { $0.id == selection }) else { return }
        onClose()
        DispatchQueue.main.async { item.perform() }
    }
}
