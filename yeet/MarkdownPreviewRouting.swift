//
//  MarkdownPreviewRouting.swift
//  kero
//

import Foundation

/// Where a markdown-preview link or a classified local file should go.
///
/// Terminal Command-click still proves the path exists via the session
/// (`existingFileURL`) before this type is consulted. In-preview links
/// resolve against the markdown file's directory even when the target is
/// missing, so the destination pane can show an error instead of leaving
/// the app or opening Finder.
nonisolated enum MarkdownPreviewDestination: Equatable {
    case heading(String)
    case markdown(URL, heading: String?)
    case file(URL)
    case web(URL)
    case invalid
}

nonisolated enum MarkdownPreviewRouting {
    private nonisolated static let markdownExtensions: Set<String> = ["md", "markdown"]

    nonisolated static func isMarkdownFile(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func isMarkdownPath(_ path: String) -> Bool {
        isMarkdownFile(URL(fileURLWithPath: path))
    }

    nonisolated static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    nonisolated static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        standardizedPath(lhs) == standardizedPath(rhs)
    }

    /// GitHub-style heading slug used for `#fragment` jumps. Matching is
    /// cheap string compare after this transform; NSTextView scrolling is
    /// applied only when a rendered heading produced the same slug.
    nonisolated static func headingSlug(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var slug = ""
        slug.reserveCapacity(trimmed.count)
        for character in trimmed {
            if character.isLetter || character.isNumber {
                slug.append(character)
            } else if character.isWhitespace || character == "-" || character == "_" {
                if slug.last != "-" { slug.append("-") }
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    nonisolated static func normalizeHeading(_ raw: String) -> String {
        headingSlug(raw.removingPercentEncoding ?? raw)
    }

    /// Resolves an href from inside a preview. Relative and `file:` targets
    /// use `fileURL`'s directory — never the terminal cwd — so a plan that
    /// links to `./notes.md` keeps working after the shell moves.
    nonisolated static func resolve(
        _ href: String,
        relativeToFile fileURL: URL
    ) -> MarkdownPreviewDestination {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }

        if trimmed.hasPrefix("#") {
            let slug = normalizeHeading(String(trimmed.dropFirst()))
            return slug.isEmpty ? .invalid : .heading(slug)
        }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                return .web(url)
            case "file":
                return destination(
                    forFile: url.standardizedFileURL,
                    heading: url.fragment.map(normalizeHeading)
                )
            default:
                return .invalid
            }
        }

        let (pathPart, fragment) = splitFragment(trimmed)
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        let expanded = (decoded as NSString).expandingTildeInPath
        let resolved: URL
        if expanded.hasPrefix("/") {
            resolved = URL(fileURLWithPath: expanded)
        } else {
            resolved = URL(
                fileURLWithPath: expanded,
                relativeTo: fileURL.deletingLastPathComponent()
            )
        }
        return destination(
            forFile: resolved.standardizedFileURL,
            heading: fragment.map(normalizeHeading)
        )
    }

    private nonisolated static func destination(
        forFile url: URL,
        heading: String?
    ) -> MarkdownPreviewDestination {
        let heading = heading.flatMap { $0.isEmpty ? nil : $0 }
        if isMarkdownFile(url) {
            return .markdown(url, heading: heading)
        }
        return .file(url)
    }

    private nonisolated static func splitFragment(
        _ value: String
    ) -> (path: String, fragment: String?) {
        guard let index = value.firstIndex(of: "#") else {
            return (value, nil)
        }
        let path = String(value[..<index])
        let fragment = String(value[value.index(after: index)...])
        return (path, fragment)
    }
}
