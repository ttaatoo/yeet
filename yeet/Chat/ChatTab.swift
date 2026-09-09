//
//  ChatTab.swift
//  kero
//

import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// Posted when a chat turn may have written workspace files. Git status
    /// does not watch the tree; ContentView refreshes on this name.
    static let yeetWorkingTreeMayHaveChanged = Notification.Name(
        "yeetWorkingTreeMayHaveChanged"
    )
}

/// One chat pane's model. Owns a local CLI runtime (Codex, Claude, or Grok).
/// The AppKit view is recreated on tab switches; items live here.
@MainActor
final class ChatTab: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case idle
        case running
        case needsLogin
        case missingBinary
        case error(String)
    }

    nonisolated let id = UUID()

    @Published private(set) var title = String(localized: "Chat")
    @Published var provider: String?
    @Published var threadID: String?
    @Published var workingDirectory: String
    @Published private(set) var items: [ChatTimelineItem] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var providers: [ChatProviderDescriptor] = []
    @Published var draft = ""

    private var runtime: ChatRuntime?
    private var eventTask: Task<Void, Never>?
    private var didAppear = false

    init(
        provider: String? = nil,
        threadID: String? = nil,
        workingDirectory: String
    ) {
        self.provider = provider
        self.threadID = threadID
        self.workingDirectory = workingDirectory
        self.providers = ChatProviderProbe.probe(path: LoginShellPath.resolved())
    }

    func refreshProviders() {
        providers = ChatProviderProbe.probe(path: LoginShellPath.resolved())
    }

    /// Restored panes keep a provider and thread id but spawn lazily so
    /// off-screen tabs do not start a CLI until shown.
    func appear() {
        guard !didAppear else { return }
        didAppear = true
        guard runtime == nil, let provider,
              let kind = KeroAgentKind(rawValue: provider),
              ChatProviderProbe.isSupported(kind)
        else { return }
        Task { await bind(kind) }
    }

    func bind(_ kind: KeroAgentKind) async {
        let path = ChatProviderProbe.resolveExecutable(
            named: kind.executable,
            path: LoginShellPath.resolved()
        )
        guard let path else {
            phase = .missingBinary
            return
        }
        provider = kind.rawValue
        let runtime = ChatRuntimeFactory.make(
            kind: kind,
            executable: path,
            currentDirectory: workingDirectory,
            environmentPath: LoginShellPath.resolved(),
            resumeID: threadID
        )
        self.runtime = runtime
        listen(to: runtime)
        do {
            try await runtime.start()
            if runtime.needsLogin {
                phase = .needsLogin
                return
            }
            let id = try await runtime.startOrResumeThread(
                cwd: workingDirectory,
                threadID: threadID
            )
            if !id.isEmpty { threadID = id }
            phase = .idle
            title = kind.displayName
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if runtime == nil {
            if let provider, let kind = KeroAgentKind(rawValue: provider) {
                await bind(kind)
            } else {
                return
            }
        }
        guard phase != .missingBinary, phase != .needsLogin else { return }
        guard let runtime else { return }
        items.append(.user(id: UUID().uuidString, text: trimmed))
        draft = ""
        phase = .running
        do {
            try await runtime.startTurn(text: trimmed)
        } catch {
            phase = .error(error.localizedDescription)
            items.append(.error(id: UUID().uuidString, message: error.localizedDescription))
        }
    }

    func respond(to item: ChatTimelineItem, decision: ChatApprovalDecision) {
        guard case .approval(_, let requestID, _, _, _) = item else { return }
        do {
            try runtime?.respond(to: requestID, decision: decision)
            items.removeAll { $0.id == item.id }
        } catch {
            items.append(.error(id: UUID().uuidString, message: error.localizedDescription))
        }
    }

    func interrupt() {
        Task {
            try? await runtime?.interrupt()
            if phase == .running { phase = .idle }
        }
    }

    func upsert(_ item: ChatTimelineItem) {
        if case .turnFinished = item {
            markTurnFinished()
            return
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        switch item {
        case .tool, .turnFiles:
            NotificationCenter.default.post(name: .yeetWorkingTreeMayHaveChanged, object: self)
        case .assistant(_, let text):
            let fallback = [
                String(localized: "Chat"),
                KeroAgentKind.codex.displayName,
                KeroAgentKind.claude.displayName,
                KeroAgentKind.grok.displayName,
            ]
            if fallback.contains(title) {
                let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    title = String(preview.prefix(40))
                }
            }
        default:
            break
        }
        if case .error = item {
            phase = .idle
        }
    }

    func markTurnFinished() {
        if phase == .running { phase = .idle }
        NotificationCenter.default.post(name: .yeetWorkingTreeMayHaveChanged, object: self)
    }

    func tearDown() {
        eventTask?.cancel()
        eventTask = nil
        runtime?.shutdown()
        runtime = nil
        if phase == .running { phase = .idle }
    }

    private func listen(to runtime: ChatRuntime) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await item in runtime.events {
                guard let self, !Task.isCancelled else { return }
                self.upsert(item)
                if case .error = item {
                    self.phase = .idle
                }
            }
            self?.markTurnFinished()
        }
    }
}
