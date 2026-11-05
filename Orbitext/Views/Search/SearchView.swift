import Observation
import SwiftUI

struct SearchView: View {
    @Environment(ChatRepository.self) private var chatRepository
    @Environment(MessageManager.self) private var messageManager
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var search = MessageSearchState()
    @State private var searchTask: Task<Void, Never>?
    @State private var selection = SearchResultNavigation()
    @State private var selectionTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                TextField(L10n.string("Search messages"), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .wristFieldRow()
            }

            switch search.phase {
            case .idle:
                Text(L10n.string("Enter at least 2 characters"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 11))
                    .wristGlassRow()
            case .loading:
                LoadingListRow()
                    .wristGlassRow()
            case .failed:
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L10n.string("Search unavailable"), systemImage: "exclamationmark.magnifyingglass")
                            .font(.headline)
                        Text(L10n.string("Check your connection and try again."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 11))
                    .wristGlassRow()
                    Button(L10n.string("Retry")) { scheduleSearch(force: true) }
                        .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                        .wristGlassRow()
                }
            case .loaded:
                if search.results.isEmpty {
                    Label(L10n.string("No Results"), systemImage: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 11))
                        .wristGlassRow()
                }
            }

            if let failedKey = selection.failedKey {
                Section {
                    Label(L10n.string("Could not open chat"), systemImage: "exclamationmark.bubble")
                        .font(.caption2)
                        .wristGlassRow()
                    Button(L10n.string("Retry")) {
                        if let message = search.results.first(where: { MessageKey(chatId: $0.chatId, messageId: $0.id) == failedKey }) {
                            openResult(message)
                        }
                    }
                    .wristGlassRow()
                }
            }

            ForEach(search.results, id: \.viewID) { message in
                Button {
                    openResult(message)
                } label: {
                    HStack {
                        searchResultRow(message)
                        if selection.loadingKey == MessageKey(chatId: message.chatId, messageId: message.id) {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                .wristGlassRow()
            }
        }
        .wristListStyle()
        .navigationTitle(L10n.string("Search"))
        .onAppear {
            if search.shouldResume { scheduleSearch(force: true) }
        }
        .onDisappear {
            searchTask?.cancel()
            search.cancelPending()
            cancelSelection()
        }
        .onChange(of: query) {
            cancelSelection()
            scheduleSearch()
        }
    }

    private func scheduleSearch(force: Bool = false) {
        let previousGeneration = search.generation
        let request = search.begin(query: query, force: force)
        guard search.generation != previousGeneration else { return }
        searchTask?.cancel()
        guard let request else { return }

        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(AppConstants.Network.searchDebounce))
                try Task.checkCancellation()
                // The generic manager fetch returns [] for errors; search needs
                // to distinguish an empty result from a failed request.
                let results = try await messageManager.service.searchMessages(query: request.query, chatId: nil)
                try Task.checkCancellation()
                search.complete(results: results, generation: request.generation)
            } catch is CancellationError {
                // A new query or leaving the screen supersedes this request.
            } catch {
                guard !Task.isCancelled else { return }
                search.fail(generation: request.generation)
            }
        }
    }

    private func openResult(_ message: MessageInfo) {
        selectionTask?.cancel()
        selectionTask = Task {
            await selection.open(
                message: message,
                cachedChat: chatRepository.chat(id: message.chatId),
                service: messageManager.service,
                router: router
            )
        }
    }

    private func cancelSelection() {
        selectionTask?.cancel()
        selection.cancel()
    }

    private func searchResultRow(_ message: MessageInfo) -> some View {
        let chat = chatRepository.chat(id: message.chatId)
        return VStack(alignment: .leading, spacing: 4) {
            Text(chat?.title ?? L10n.string("Chat"))
                .font(WristTheme.Typography.rowTitle)
                .lineLimit(2)
            if chat?.isGroup != false, !message.senderName.isEmpty {
                Text(message.senderName)
                    .font(WristTheme.Typography.rowMeta)
                    .foregroundStyle(WristTheme.Palette.accent)
                    .lineLimit(1)
            }
            Text(message.content.textPreview)
                .font(WristTheme.Typography.preview)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .accessibilityLabel(message.content.textPreview.speakingSpoilerMasks)
            Text(message.date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                .font(WristTheme.Typography.rowMeta)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Resolving a search hit is independent of the currently visible folder.
/// A stale selection may finish its request, but cannot navigate or replace an error.
@MainActor
@Observable
final class SearchResultNavigation {
    private var generation = 0
    private var didNavigate = false
    private(set) var loadingKey: MessageKey?
    private(set) var failedKey: MessageKey?

    func open(message: MessageInfo, cachedChat: ChatInfo?, service: any TelegramServiceProtocol, router: AppRouter) async {
        guard !Task.isCancelled, !didNavigate else { return }
        generation += 1
        let requestGeneration = generation
        let key = MessageKey(chatId: message.chatId, messageId: message.id)
        loadingKey = key
        failedKey = nil
        defer {
            if generation == requestGeneration { loadingKey = nil }
        }
        do {
            let chat: ChatInfo
            if let cachedChat, cachedChat.id == message.chatId {
                chat = cachedChat
            } else {
                chat = try await service.getChat(chatId: message.chatId)
            }
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            guard chat.id == message.chatId else { throw TDError.unexpectedResponse }
            didNavigate = true
            router.push(.searchResult(chat: chat, messageId: message.id))
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), generation == requestGeneration else { return }
            failedKey = key
        }
    }

    func cancel() {
        generation += 1
        didNavigate = false
        loadingKey = nil
        failedKey = nil
    }
}

/// Request generations keep cancelled and slower searches from replacing the
/// latest result. Failure stays distinct from a completed search with no hits.
struct MessageSearchState {
    enum Phase: Equatable {
        case idle, loading, loaded, failed
    }

    struct Request {
        let query: String
        let generation: Int
    }

    private(set) var phase = Phase.idle
    private(set) var results: [MessageInfo] = []
    private(set) var normalizedQuery = ""
    private(set) var generation = 0

    var shouldResume: Bool {
        phase == .idle && normalizedQuery.count >= 2
    }

    mutating func begin(query: String, force: Bool = false) -> Request? {
        let normalized = query.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard force || normalized != normalizedQuery else { return nil }
        generation += 1
        normalizedQuery = normalized
        results = []
        guard normalized.count >= 2 else {
            phase = .idle
            return nil
        }
        phase = .loading
        return Request(query: normalized, generation: generation)
    }

    mutating func complete(results: [MessageInfo], generation: Int) {
        guard generation == self.generation, phase == .loading else { return }
        self.results = results
        phase = .loaded
    }

    mutating func fail(generation: Int) {
        guard generation == self.generation, phase == .loading else { return }
        phase = .failed
    }

    mutating func cancelPending() {
        guard phase == .loading else { return }
        generation += 1
        phase = .idle
    }
}
