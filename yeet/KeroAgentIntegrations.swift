//
//  KeroAgentIntegrations.swift
//  kero
//

import Foundation

/// Native lifecycle integrations for agent CLIs whose public event surfaces
/// cover an interactive turn. Kero never infers lifecycle state from rendered
/// terminal text, so these events are the only source of blocked and completed
/// transitions. Managed integrations are links into the app bundle so a Kero
/// update cannot leave copied hook/plugin code stale.
enum KeroAgentIntegrations {
    enum Kind: String, CaseIterable {
        case pi
        case opencode
        case grok
        case claude
        case codex

        /// Integrations Yeet delivers as a whole managed file (symlink into
        /// the app bundle).
        static let linkedKinds: [Kind] = [.pi, .opencode, .grok]
        /// Integrations delivered as hook entries merged into a JSON config
        /// file the agent — and often other tools — already own.
        static let mergedKinds: [Kind] = [.claude, .codex]

        var marker: String { "YEET_INTEGRATION_ID=\(rawValue)" }

        var resource: (name: String, extension: String, directories: [String?]) {
            switch self {
            case .pi:
                return (
                    "yeet-agent-state.pi", "txt",
                    ["AgentIntegrations/pi", "pi", nil]
                )
            case .opencode:
                return (
                    "yeet-agent-state", "js",
                    ["AgentIntegrations/opencode", "opencode", nil]
                )
            case .grok:
                return (
                    "yeet-agent-state.grok", "json",
                    ["AgentIntegrations/grok", "grok", nil]
                )
            case .claude, .codex:
                // Merged integrations carry their hook commands in code, not
                // in a bundled resource; `linkedKinds` never reaches here.
                fatalError("linked integrations have no bundled resource")
            }
        }

        var resourceFileName: String {
            let resource = resource
            return "\(resource.name).\(resource.extension)"
        }

        func installationRoot(
            homeURL: URL,
            environment: [String: String]
        ) -> URL {
            switch self {
            case .pi:
                if let configured = environment["PI_CODING_AGENT_DIR"],
                   !configured.isEmpty {
                    return expandedURL(configured, homeURL: homeURL)
                }
                return homeURL.appendingPathComponent(".pi/agent", isDirectory: true)
            case .opencode:
                return homeURL.appendingPathComponent(
                    ".config/opencode",
                    isDirectory: true
                )
            case .grok:
                if let configured = environment["GROK_HOME"],
                   !configured.isEmpty {
                    return expandedURL(configured, homeURL: homeURL)
                }
                return homeURL.appendingPathComponent(".grok", isDirectory: true)
            case .claude:
                if let configured = environment["CLAUDE_CONFIG_DIR"],
                   !configured.isEmpty {
                    return expandedURL(configured, homeURL: homeURL)
                }
                return homeURL.appendingPathComponent(".claude", isDirectory: true)
            case .codex:
                if let configured = environment["CODEX_HOME"],
                   !configured.isEmpty {
                    return expandedURL(configured, homeURL: homeURL)
                }
                return homeURL.appendingPathComponent(".codex", isDirectory: true)
            }
        }

        /// The user-owned JSON file merged integrations append hook entries
        /// to: Claude Code keeps hooks in `settings.json`; Codex keeps them
        /// in a dedicated `hooks.json`.
        func mergedHooksFileURL(
            homeURL: URL,
            environment: [String: String]
        ) -> URL {
            let root = installationRoot(homeURL: homeURL, environment: environment)
            let fileName = self == .claude ? "settings.json" : "hooks.json"
            return root.appendingPathComponent(fileName, isDirectory: false)
        }

        /// Both agents fire `UserPromptSubmit` with the session id at the
        /// first prompt — the earliest point a resume is worth offering — and
        /// `Stop` when a turn completes.
        var mergedHookEvents: [(event: String, phase: String)] {
            [
                ("UserPromptSubmit", "working"),
                ("Stop", "idle"),
            ]
        }

        func mergedHookCommand(phase: String) -> String {
            "[ \"$YEET_AUTOMATION\" = \"1\" ] || exit 0; "
                + "command -v yeet >/dev/null 2>&1 || exit 0; "
                + "exec yeet +agent _integration \(rawValue) \(phase) # \(marker)"
        }

        func destinationURL(
            homeURL: URL,
            environment: [String: String]
        ) -> URL {
            let root = installationRoot(homeURL: homeURL, environment: environment)
            switch self {
            case .pi:
                return root.appendingPathComponent(
                    "extensions/yeet-agent-state.ts",
                    isDirectory: false
                )
            case .opencode:
                return root.appendingPathComponent(
                    "plugins/yeet-agent-state.js",
                    isDirectory: false
                )
            case .grok:
                return root.appendingPathComponent(
                    "hooks/yeet-agent-state.json",
                    isDirectory: false
                )
            case .claude, .codex:
                fatalError("merged integrations have no owned destination file")
            }
        }

        func leftoverDestinationURL(
            homeURL: URL,
            environment: [String: String]
        ) -> URL {
            let root = installationRoot(homeURL: homeURL, environment: environment)
            switch self {
            case .pi:
                return root.appendingPathComponent(
                    "extensions/kero-agent-state.ts",
                    isDirectory: false
                )
            case .opencode:
                return root.appendingPathComponent(
                    "plugins/kero-agent-state.js",
                    isDirectory: false
                )
            case .grok:
                return root.appendingPathComponent(
                    "hooks/kero-agent-state.json",
                    isDirectory: false
                )
            case .claude, .codex:
                fatalError("merged integrations have no owned destination file")
            }
        }
    }

    enum IntegrationError: Error, LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message): message
            }
        }
    }

    /// Validates every integration whose agent config already exists. Missing
    /// agents are intentionally skipped so enabling AI never creates unrelated
    /// provider configuration in the user's home directory.
    static func preflightInstallAvailable(
        bundle: Bundle = .main,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        for kind in Kind.linkedKinds {
            let root = kind.installationRoot(homeURL: homeURL, environment: environment)
            guard isDirectory(root) else { continue }
            let source = try source(for: kind, bundle: bundle)
            let destination = kind.destinationURL(
                homeURL: homeURL,
                environment: environment
            )
            if itemType(at: destination) != nil,
               !isManaged(destination, kind: kind, sourceURL: source.url) {
                throw IntegrationError.message(
                    "The \(kind.rawValue) integration at \(destination.path) is not managed by Yeet."
                )
            }
        }
        for kind in Kind.mergedKinds {
            let root = kind.installationRoot(homeURL: homeURL, environment: environment)
            guard isDirectory(root) else { continue }
            // A file Yeet cannot parse is never rewritten; the error names the
            // agent config that blocked enabling AI.
            let url = kind.mergedHooksFileURL(
                homeURL: homeURL,
                environment: environment
            )
            _ = try mergedHooksContainer(from: try readJSONObject(at: url))
        }
    }

    static func installAvailable(
        bundle: Bundle = .main,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try preflightInstallAvailable(
            bundle: bundle,
            homeURL: homeURL,
            environment: environment
        )
        for kind in Kind.linkedKinds {
            let root = kind.installationRoot(homeURL: homeURL, environment: environment)
            guard isDirectory(root) else { continue }
            let source = try source(for: kind, bundle: bundle)
            let destination = kind.destinationURL(
                homeURL: homeURL,
                environment: environment
            )
            if isCurrentLink(destination, sourceURL: source.url) { continue }
            // Recheck ownership after the all-destination preflight so a file
            // changed concurrently is never replaced.
            if itemType(at: destination) != nil,
               !isManaged(destination, kind: kind, sourceURL: source.url) {
                throw IntegrationError.message(
                    "The \(kind.rawValue) integration at \(destination.path) changed while Yeet was enabling AI."
                )
            }
            try replaceWithLink(at: destination, sourceURL: source.url)
        }
        for kind in Kind.mergedKinds {
            try installMergedHooks(
                kind: kind, homeURL: homeURL, environment: environment
            )
        }
        removeLeftoverInstallations(homeURL: homeURL, environment: environment)
    }

    static func preflightUninstallManaged(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        for kind in Kind.linkedKinds {
            let destination = kind.destinationURL(
                homeURL: homeURL,
                environment: environment
            )
            guard itemType(at: destination) != nil else { continue }
            guard isManaged(destination, kind: kind, sourceURL: nil) else {
                throw IntegrationError.message(
                    "The \(kind.rawValue) integration at \(destination.path) has local changes."
                )
            }
        }
        for kind in Kind.mergedKinds {
            let url = kind.mergedHooksFileURL(
                homeURL: homeURL,
                environment: environment
            )
            guard itemType(at: url) != nil else { continue }
            // Foreign entries in a shared file are expected and never count
            // as local changes; only a file that fails to parse blocks.
            _ = try mergedHooksContainer(from: try readJSONObject(at: url))
        }
    }

    static func uninstallManaged(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try preflightUninstallManaged(homeURL: homeURL, environment: environment)
        for kind in Kind.linkedKinds {
            let destination = kind.destinationURL(
                homeURL: homeURL,
                environment: environment
            )
            if itemType(at: destination) != nil {
                try FileManager.default.removeItem(at: destination)
            }
        }
        for kind in Kind.mergedKinds {
            try uninstallMergedHooks(
                kind: kind, homeURL: homeURL, environment: environment
            )
        }
        removeLeftoverInstallations(homeURL: homeURL, environment: environment)
    }

    // MARK: - Merged hook integrations

    private nonisolated static let mergedEntryMarker = "_yeet"

    /// Reads the shared JSON config. A missing file is an empty object —
    /// Codex users may not have a `hooks.json` until Yeet creates one.
    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        guard itemType(at: url) != nil else { return [:] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= 4 * 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw IntegrationError.message(
                "The file at \(url.path) is not a JSON object Yeet can merge hooks into."
            )
        }
        return dictionary
    }

    /// The `hooks` object inside a shared config. Absent is fine; present but
    /// the wrong type means another tool owns a shape Yeet does not know, so
    /// refuse rather than guess.
    private static func mergedHooksContainer(
        from object: [String: Any]
    ) throws -> [String: Any] {
        guard let hooks = object["hooks"] as? [String: Any] else {
            if object["hooks"] == nil { return [:] }
            throw IntegrationError.message(
                "The hooks entry is not a JSON object."
            )
        }
        return hooks
    }

    private nonisolated static func isYeetHookGroup(_ entry: Any) -> Bool {
        (entry as? [String: Any])?[mergedEntryMarker] as? Bool == true
    }

    private static func yeetHookGroup(kind: Kind, phase: String) -> [String: Any] {
        [
            mergedEntryMarker: true,
            "hooks": [
                [
                    "type": "command",
                    "command": kind.mergedHookCommand(phase: phase),
                    "timeout": 2,
                ]
            ],
        ]
    }

    /// Appends Yeet's hook groups to the shared config. The rewrite is
    /// pretty-printed with sorted keys — the same trade every tool merging
    /// into these files makes (see Otty's `_otty` groups) — and every
    /// foreign entry is preserved verbatim.
    private static func installMergedHooks(
        kind: Kind,
        homeURL: URL,
        environment: [String: String]
    ) throws {
        let root = kind.installationRoot(homeURL: homeURL, environment: environment)
        guard isDirectory(root) else { return }
        let url = kind.mergedHooksFileURL(homeURL: homeURL, environment: environment)
        var object = try readJSONObject(at: url)
        var hooks = try mergedHooksContainer(from: object)
        for hook in kind.mergedHookEvents {
            var groups = hooks[hook.event] as? [Any] ?? []
            groups.removeAll(where: isYeetHookGroup)
            groups.append(yeetHookGroup(kind: kind, phase: hook.phase))
            hooks[hook.event] = groups
        }
        object["hooks"] = hooks
        try writeJSONObject(object, to: url)
    }

    /// Strips only Yeet's own groups. A file left with nothing but Yeet
    /// entries (Codex `hooks.json` Yeet created) is removed entirely.
    private static func uninstallMergedHooks(
        kind: Kind,
        homeURL: URL,
        environment: [String: String]
    ) throws {
        let url = kind.mergedHooksFileURL(homeURL: homeURL, environment: environment)
        guard itemType(at: url) != nil else { return }
        var object = try readJSONObject(at: url)
        var hooks = try mergedHooksContainer(from: object)
        for hook in kind.mergedHookEvents {
            guard let groups = hooks[hook.event] as? [Any] else { continue }
            let remaining = groups.filter { !isYeetHookGroup($0) }
            if remaining.isEmpty {
                hooks.removeValue(forKey: hook.event)
            } else {
                hooks[hook.event] = remaining
            }
        }
        if hooks.isEmpty {
            object.removeValue(forKey: "hooks")
        } else {
            object["hooks"] = hooks
        }
        if object.isEmpty {
            try FileManager.default.removeItem(at: url)
        } else {
            try writeJSONObject(object, to: url)
        }
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private struct Source {
        let url: URL
    }

    private static func source(for kind: Kind, bundle: Bundle) throws -> Source {
        let resource = kind.resource
        for directory in resource.directories {
            guard let url = bundle.url(
                forResource: resource.name,
                withExtension: resource.extension,
                subdirectory: directory
            ) else { continue }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8),
                  text.contains(kind.marker) else { continue }
            return Source(url: url.standardizedFileURL)
        }
        throw IntegrationError.message(
            "Yeet's bundled \(kind.rawValue) lifecycle integration is missing."
        )
    }

    private static func isManaged(
        _ url: URL,
        kind: Kind,
        sourceURL: URL?
    ) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= 256 * 1_024,
              let text = String(data: data, encoding: .utf8)
        else {
            // A moved or replaced app can leave Kero's absolute resource link
            // temporarily dangling. Recognize only its exact resource name
            // beneath an app bundle so launch reconciliation can repair it.
            guard itemType(at: url) == .typeSymbolicLink,
                  let target = symbolicLinkTarget(at: url),
                  target.lastPathComponent == kind.resourceFileName,
                  target.path.contains(".app/Contents/Resources/")
            else { return false }
            return true
        }
        if text.contains(kind.marker) { return true }
        guard let sourceURL else { return false }
        return isCurrentLink(url, sourceURL: sourceURL)
    }

    private static func isCurrentLink(_ url: URL, sourceURL: URL) -> Bool {
        guard itemType(at: url) == .typeSymbolicLink,
              let target = symbolicLinkTarget(at: url)
        else { return false }
        return target.standardizedFileURL.path == sourceURL.standardizedFileURL.path
    }

    private static func symbolicLinkTarget(at url: URL) -> URL? {
        guard let path = try? FileManager.default.destinationOfSymbolicLink(
            atPath: url.path
        ) else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return url.deletingLastPathComponent().appendingPathComponent(path)
    }

    private static func replaceWithLink(at destination: URL, sourceURL: URL) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let stem = destination.lastPathComponent
        let staging = parent.appendingPathComponent(
            ".\(stem).yeet-staging-\(UUID().uuidString)"
        )
        let backup = parent.appendingPathComponent(
            ".\(stem).yeet-backup-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createSymbolicLink(
            atPath: staging.path,
            withDestinationPath: sourceURL.standardizedFileURL.path
        )

        let existed = itemType(at: destination) != nil
        if existed {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if existed, itemType(at: destination) == nil {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
        if existed { try? fileManager.removeItem(at: backup) }
    }

    private static func removeLeftoverInstallations(
        homeURL: URL,
        environment: [String: String]
    ) {
        for kind in Kind.linkedKinds {
            let leftover = kind.leftoverDestinationURL(
                homeURL: homeURL,
                environment: environment
            )
            guard itemType(at: leftover) != nil else { continue }
            guard isLeftoverManaged(leftover, kind: kind) else { continue }
            try? FileManager.default.removeItem(at: leftover)
        }
    }

    private static func isLeftoverManaged(_ url: URL, kind: Kind) -> Bool {
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           data.count <= 256 * 1_024,
           let text = String(data: data, encoding: .utf8),
           text.contains("KERO_INTEGRATION_ID=\(kind.rawValue)")
            || text.contains(kind.marker) {
            return true
        }
        guard itemType(at: url) == .typeSymbolicLink,
              let target = symbolicLinkTarget(at: url),
              target.path.contains(".app/Contents/Resources/")
        else { return false }
        let name = target.lastPathComponent
        return name.hasPrefix("kero-agent-state") || name.hasPrefix("yeet-agent-state")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func itemType(at url: URL) -> FileAttributeType? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType
    }

    private static func expandedURL(_ path: String, homeURL: URL) -> URL {
        if path == "~" { return homeURL }
        if path.hasPrefix("~/") {
            return homeURL.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}
