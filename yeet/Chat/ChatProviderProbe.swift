//
//  ChatProviderProbe.swift
//  kero
//

import Foundation

/// One coding CLI that the chat empty state can show. Claude, Codex, and Grok
/// are always listed so a missing binary still gets install/login copy.
/// Other CLIs appear only when they resolve, and stay disabled.
struct ChatProviderDescriptor: Equatable, Sendable {
    var kind: KeroAgentKind
    var displayName: String
    var executableName: String
    var resolvedPath: String?
    var isSupported: Bool
    var installHint: String
}

enum ChatProviderProbe {
    /// First-cut chat talks to Claude Code, Codex, and Grok.
    private static let catalog: [(kind: KeroAgentKind, supported: Bool)] = [
        (.claude, true),
        (.codex, true),
        (.grok, true),
        (.cursor, false),
        (.opencode, false),
    ]

    static func isSupported(_ kind: KeroAgentKind) -> Bool {
        catalog.contains { $0.kind == kind && $0.supported }
    }

    static func probe(path: String) -> [ChatProviderDescriptor] {
        catalog.compactMap { entry in
            let name = entry.kind.executable
            let resolved = resolveExecutable(named: name, path: path)
            if !entry.supported, resolved == nil { return nil }
            return ChatProviderDescriptor(
                kind: entry.kind,
                displayName: entry.kind.displayName,
                executableName: name,
                resolvedPath: resolved,
                isSupported: entry.supported,
                installHint: installHint(for: entry.kind)
            )
        }
    }

    static func resolveExecutable(named name: String, path: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let fm = FileManager.default
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            guard fm.isExecutableFile(atPath: candidate) else { continue }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                continue
            }
            return candidate
        }
        return nil
    }

    static func installHint(for kind: KeroAgentKind) -> String {
        switch kind {
        case .claude:
            return String(localized: "Install Claude Code, then run `claude auth login`.")
        case .codex:
            return String(localized: "Install Codex, then run `codex login`.")
        case .grok:
            return String(localized: "Install Grok, then run `grok login`.")
        default:
            return String(localized: "This CLI is not supported in the chat pane yet.")
        }
    }
}
