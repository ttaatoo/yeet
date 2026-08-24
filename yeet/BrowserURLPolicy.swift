//
//  BrowserURLPolicy.swift
//  kero
//

import Foundation

/// What the in-app browser and address bar will actually load. Untrusted page
/// content and OSC-8-style strings must not open arbitrary URL schemes, and
/// `file:` / `data:` are not treated as ordinary navigations.
enum BrowserURLPolicy {
    /// Schemes the WKWebView is allowed to navigate. `blob:` stays because
    /// pages use it for same-document object URLs; it is not opened via
    /// NSWorkspace. `about` is only `about:blank`.
    nonisolated static let webViewSchemes: Set<String> = ["http", "https", "about", "blob"]

    nonisolated static func isAboutBlank(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "about"
            && (url.absoluteString == "about:blank" || url.absoluteString.hasPrefix("about:blank?"))
    }

    /// Whether this URL may load inside Yeet's browser. `file:` and `data:`
    /// are refused — they are not a web page the user typed as a host.
    nonisolated static func allowsWebViewNavigation(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return isAboutBlank(url) }
        if scheme == "file" || scheme == "data" || scheme == "javascript" {
            return false
        }
        return webViewSchemes.contains(scheme)
    }

    /// External schemes (`mailto:`, `slack:`, …) are cancelled, not handed
    /// to NSWorkspace — a page must not launch other apps from navigation.
    nonisolated static func shouldOpenExternally(_ url: URL) -> Bool {
        false
    }

    /// Turns the Safari-style combined address/search field into a request.
    /// Explicit http(s) and about:blank are preserved; `file:` / `data:` are
    /// not treated as destinations; likely hostnames gain a scheme; everything
    /// else becomes a web search.
    nonisolated static func destination(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.lowercased()

        if lowercased.hasPrefix("javascript:") { return nil }
        if lowercased.hasPrefix("file:") || lowercased.hasPrefix("data:") {
            return nil
        }
        if lowercased == "about:blank" || lowercased.hasPrefix("about:blank?") {
            return URL(string: trimmed)
        }
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return urlAllowingSpaces(trimmed)
        }

        if !trimmed.contains(where: \.isWhitespace), looksLikeHost(trimmed) {
            let host = host(in: trimmed).lowercased()
            let useHTTP = host == "localhost"
                || host.hasSuffix(".local")
                || isIPv4(host)
                || host.hasPrefix("[::")
                || hasExplicitPort(trimmed)
            return urlAllowingSpaces("\(useHTTP ? "http" : "https")://\(trimmed)")
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    /// Command-click / OSC 8: only http(s) leave the terminal as a URL.
    /// Local paths stay a separate file-reveal path.
    nonisolated static func allowsTerminalWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    private nonisolated static func looksLikeHost(_ input: String) -> Bool {
        let host = host(in: input)
        if host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        if host.hasPrefix("[") && host.contains("]") { return true }
        if host.contains(".") { return true }
        return hasExplicitPort(input)
    }

    private nonisolated static func host(in input: String) -> String {
        let authority = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        if authority.hasPrefix("["),
           let bracket = authority.firstIndex(of: "]") {
            return String(authority[...bracket])
        }
        return authority.split(separator: ":", maxSplits: 1).first.map(String.init)
            ?? authority
    }

    private nonisolated static func isIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4
            && components.allSatisfy {
                guard let octet = Int($0) else { return false }
                return (0...255).contains(octet)
            }
    }

    private nonisolated static func hasExplicitPort(_ input: String) -> Bool {
        let authority = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        if authority.hasPrefix("["),
           let bracket = authority.firstIndex(of: "]") {
            let remainder = authority[authority.index(after: bracket)...]
            return remainder.first == ":" && Int(remainder.dropFirst()) != nil
        }
        guard let colon = authority.lastIndex(of: ":") else { return false }
        return Int(authority[authority.index(after: colon)...]) != nil
    }

    private nonisolated static func urlAllowingSpaces(_ string: String) -> URL? {
        if let url = URL(string: string) { return url }
        return string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            .flatMap(URL.init(string:))
    }
}
