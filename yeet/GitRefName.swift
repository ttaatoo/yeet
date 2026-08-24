//
//  GitRefName.swift
//  kero
//

import Foundation

/// User-supplied Git branch names. `git switch` treats a leading `-` as an
/// option, so those names are rejected before any argv is built. Create uses
/// `switch -c <name> --` because `-c` consumes the next token as the branch
/// name — `switch -c -- name` would try to create a branch named `--`.
enum GitRefName {
    enum Rejection: Error, Equatable {
        case empty
        case leadingDash
        case invalidFormat
    }

    /// Trims surrounding whitespace and rejects empty or dash-leading names
    /// without talking to Git. Further syntax is `check-ref-format --branch`.
    nonisolated static func sanitizedUserName(_ raw: String) -> Result<String, Rejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed.hasPrefix("-") { return .failure(.leadingDash) }
        return .success(trimmed)
    }

    /// Whether the create-branch field should enable its confirm button.
    nonisolated static func isAcceptableUserInput(_ raw: String) -> Bool {
        if case .success = sanitizedUserName(raw) { return true }
        return false
    }

    /// `git switch -- <name>` so a name cannot be parsed as an option.
    nonisolated static func switchArguments(to name: String) -> [String]? {
        guard case .success(let trimmed) = sanitizedUserName(name) else { return nil }
        return ["switch", "--", trimmed]
    }

    /// `git switch -c <name> --` after the name has already been rejected
    /// when it starts with `-`. The trailing `--` ends option parsing for
    /// any later start-point argument.
    nonisolated static func createArguments(named name: String) -> [String]? {
        guard case .success(let trimmed) = sanitizedUserName(name) else { return nil }
        return ["switch", "-c", trimmed, "--"]
    }

    /// Local checks that match the common `git check-ref-format --branch`
    /// failures, so tests and the create-branch field do not need a Git
    /// process. Runtime still asks Git as well.
    nonisolated static func passesLocalFormat(_ name: String) -> Bool {
        guard case .success(let trimmed) = sanitizedUserName(name) else { return false }
        if trimmed == "@" || trimmed == "HEAD" { return false }
        if trimmed.hasPrefix(".") || trimmed.hasSuffix(".") { return false }
        if trimmed.hasPrefix("/") || trimmed.hasSuffix("/") { return false }
        if trimmed.hasSuffix(".lock") { return false }
        if trimmed.contains("..") || trimmed.contains("//") { return false }
        if trimmed.contains("@{") { return false }
        if trimmed.contains("\\") { return false }
        let forbidden = CharacterSet(charactersIn: "~^:?*[ \t\n")
            .union(.controlCharacters)
        if trimmed.unicodeScalars.contains(where: { forbidden.contains($0) }) {
            return false
        }
        return true
    }
}
