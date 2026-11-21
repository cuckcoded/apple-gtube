import GTubeCore
import SwiftUI

/// A scrollable, infinitely-loading grid or list of feed items, with an
/// optional header above it.
struct FeedView<Header: View>: View {
    let feed: FeedModel
    var layout: CardLayout = .grid
    var emptyIcon = "square.grid.2x2"
    var emptyTitle = "Nothing here"
    var emptyText = ""
    /// What clicking an item does (default: opens it).
    var onActivate: ((Int) -> Void)?
    @ViewBuilder var header: () -> Header

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header()
                if !feed.chips.isEmpty {
                    ChipsRow(titles: feed.chips.map(\.title), selected: feed.selectedChip) { feed.selectChip($0) }
                }
                content
                if feed.continuation != nil && feed.status == .idle {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .padding()
                        .id(feed.items.count)
                        .onAppear { feed.loadMore() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .padding(.bottom, 80)
        }
    }

    @ViewBuilder
    var content: some View {
        switch feed.status {
        case .loading:
            HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(64)
        case .needsLogin:
            StatusBox(icon: "person.crop.circle.badge.questionmark", title: "Sign in to see this",
                      description: "This page needs a signed-in YouTube account.", buttonTitle: "Sign in") { AppModel.shared.sheet = .signIn }
        case .error(let e):
            StatusBox(icon: "exclamationmark.triangle", title: "Could not load this page", description: e, buttonTitle: "Retry") { feed.reload() }
        case .empty:
            StatusBox(icon: emptyIcon, title: emptyTitle, description: emptyText)
        case .idle:
            if layout == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 18, alignment: .top)], alignment: .leading, spacing: 24) {
                    ForEach(Array(feed.items.enumerated()), id: \.element.id) { i, item in
                        ItemCard(item: item, layout: .grid)
                            .onTapGesture { activate(i, item) }
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(feed.items.enumerated()), id: \.element.id) { i, item in
                        ItemCard(item: item, layout: .list)
                            .onTapGesture { activate(i, item) }
                    }
                }
            }
        }
    }

    func activate(_ i: Int, _ item: Item) {
        if let f = onActivate { f(i) } else { AppModel.shared.activate(item) }
    }
}

extension FeedView where Header == EmptyView {
    init(feed: FeedModel, layout: CardLayout = .grid, emptyIcon: String = "square.grid.2x2", emptyTitle: String = "Nothing here", emptyText: String = "", onActivate: ((Int) -> Void)? = nil) {
        self.init(feed: feed, layout: layout, emptyIcon: emptyIcon, emptyTitle: emptyTitle, emptyText: emptyText, onActivate: onActivate) { EmptyView() }
    }
}
