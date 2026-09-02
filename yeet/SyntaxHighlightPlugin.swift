//
//  SyntaxHighlightPlugin.swift
//  kero
//
//  kero's own STTextView highlighting plugin. It reuses STTextView-Plugin-Neon's
//  tree-sitter grammars and query files (via TreeSitterResource) and Neon's
//  incremental Highlighter, but owns the glue so it can do one thing the stock
//  plugin can't: **merge a language's inherited base query**. tree-sitter
//  highlight queries use nvim-treesitter's `; inherits:` convention — e.g.
//  TypeScript inherits ecma/JavaScript, C++ inherits C — and SwiftTreeSitter
//  doesn't resolve that, so the stock plugin (which loads a single query file)
//  leaves comments, strings and base keywords unhighlighted. See
//  SyntaxHighlighting.highlightsData(for:).
//
//  Languages are named by kero's own `SyntaxLanguage`, not the plugin's
//  `TreeSitterLanguage`, because one grammar (TSX) is vendored rather than
//  bundled.
//
//  Adapted from STTextView-Plugin-Neon's Coordinator / STTextViewSystemInterface.
//

import AppKit
import Neon
import Rearrange
import STPluginNeon
import STTextKitPlus
import STTextView
import SwiftTreeSitter

private struct TokenProviderCompletion: @unchecked Sendable {
    let call: (Result<TokenApplication, Error>) -> Void
}
import TreeSitterClient

/// STTextView plugin that drives Neon's tree-sitter highlighter.
struct SyntaxHighlightPlugin: STPlugin {
    let theme: STPluginNeonAppKit.Theme
    let language: SyntaxLanguage
    /// The combined highlights query (`inherited base + language-specific`),
    /// already concatenated by `SyntaxHighlighting.highlightsData(for:)`.
    let highlightsData: Data
    /// The injections query for a language that embeds others (markdown code
    /// fences, HTML `<script>`, …), or `nil`. Drives the injection-aware token
    /// provider; see `SyntaxHighlighting.injectionsData(for:)`.
    let injectionsData: Data?

    /// These handlers are stored on `STPluginEvents`, which the text view
    /// itself retains (`STTextView.plugins`) for as long as it lives — and the
    /// view has no way to drop a plugin, so anything they capture strongly
    /// lives exactly as long as the view does. Capturing `context` whole would
    /// therefore close a cycle: it holds `textView` strongly, so every editor
    /// would stay alive for the life of the process. Capture the coordinator
    /// (which is meant to share the view's lifetime) and a *weak* view instead.
    func setUp(context: any Context) {
        let coordinator = context.coordinator

        context.events.onWillChangeText { [weak textView = context.textView] affectedRange, _ in
            guard let textView else { return }
            let range = NSRange(affectedRange, in: textView.textContentManager)
            coordinator.willChangeContent(in: range)
        }

        context.events.onDidChangeText { [weak textView = context.textView] affectedRange, replacementString in
            guard let textView, let replacementString else { return }
            // `affectedRange` is the pre-edit NSTextRange, but converting it
            // after storage has already changed can yield the replacement
            // span. Delta and tsClient both need the pre-edit UTF-16 range
            // captured in `willChangeContent`.
            let postEditRange = NSRange(affectedRange, in: textView.textContentManager)
            coordinator.didChangeContent(
                textView.textContentManager,
                in: postEditRange,
                replacementUTF16Count: replacementString.utf16.count,
                limit: textView.textContentManager.length
            )
        }

        context.events.onDidLayoutViewport { viewportRange in
            coordinator.updateViewportRange(viewportRange)
        }
    }

    func makeCoordinator(context: CoordinatorContext) -> SyntaxHighlightCoordinator {
        SyntaxHighlightCoordinator(
            textView: context.textView,
            theme: theme,
            language: language,
            highlightsData: highlightsData,
            injectionsData: injectionsData
        )
    }
}

/// Compiled highlight queries, cached per language.
///
/// Compiling a tree-sitter query (`ts_query_new`) costs O(grammar complexity),
/// not O(query size): it resolves every pattern against the grammar's symbol
/// table. For the Swift grammar (a 12 MB parser) that is ~190 ms, versus ~30 ms
/// for TypeScript. The query is identical for every file of a language and is
/// immutable and thread-safe once built, so it's compiled once and shared: the
/// first file of a language compiles it (off the main thread — see
/// `SyntaxHighlightCoordinator.installTokenProvider`), every later file reuses it.
@MainActor
enum HighlightQueryCache {
    private static var cache: [SyntaxLanguage: SwiftTreeSitter.Query] = [:]
    private static var injectionCache: [SyntaxLanguage: SwiftTreeSitter.Query] = [:]

    static func cached(_ language: SyntaxLanguage) -> SwiftTreeSitter.Query? {
        cache[language]
    }

    static func store(_ query: SwiftTreeSitter.Query, for language: SyntaxLanguage) {
        cache[language] = query
    }

    /// A language's compiled *injections* query. Separate from the highlights
    /// cache above because it's built from different `.scm` bytes against the
    /// same grammar. A language embedded in another (bash inside markdown)
    /// reuses the highlights cache via `cached(_:)` for its own tokens.
    static func cachedInjection(_ language: SyntaxLanguage) -> SwiftTreeSitter.Query? {
        injectionCache[language]
    }

    static func storeInjection(_ query: SwiftTreeSitter.Query, for language: SyntaxLanguage) {
        injectionCache[language] = query
    }
}

/// Identity of one cached embedded region (language + UTF-16 span).
struct InjectionCacheKey: Hashable {
    let language: SyntaxLanguage
    let location: Int
    let length: Int
}

@MainActor
final class SyntaxHighlightCoordinator {
    private var highlighter: Neon.Highlighter?
    private let language: SyntaxLanguage
    private let tsLanguage: SwiftTreeSitter.Language
    private let tsClient: TreeSitterClient?
    private let highlightsData: Data
    /// Injections query bytes for the root language, or `nil` when it embeds no
    /// other languages. Non-nil selects the injection-aware token provider.
    private let injectionsData: Data?
    /// Embedded languages whose highlights query is being compiled off the main
    /// thread right now, so the token provider kicks off each compile only once.
    private var pendingInjectionCompiles: Set<SyntaxLanguage> = []
    /// Highlight tokens for an embedded region, reused across Neon 1024-char
    /// requests. Edits drop overlapping fences and shift later ones.
    private var injectionTokenCache: [InjectionCacheKey: [Neon.Token]] = [:]
    /// Bumped in `didChangeContent` so a background fence parse cannot store
    /// tokens after the cache was rewritten for a newer document.
    private var injectionCacheGeneration: UInt64 = 0
    /// Pre-edit UTF-16 range from `willChangeContent`. `didChangeContent`
    /// must not re-convert the NSTextRange after storage has already changed.
    private var pendingPreEditRange: NSRange?
    private var prevViewportRange: NSTextRange?
    /// The text view owns this coordinator. Keep its content manager weak while
    /// a background query compile is pending so the editor can still close.
    private weak var textContentManager: NSTextContentManager?

    private nonisolated struct InjectionParseJob: @unchecked Sendable {
        let key: InjectionCacheKey
        let parser: OpaquePointer
        let query: SwiftTreeSitter.Query
        let fragment: String
        let offset: Int
    }

    init(
        textView: STTextView,
        theme: STPluginNeonAppKit.Theme,
        language: SyntaxLanguage,
        highlightsData: Data,
        injectionsData: Data?
    ) {
        self.language = language
        self.highlightsData = highlightsData
        self.injectionsData = injectionsData
        textContentManager = textView.textContentManager
        tsLanguage = Language(language: language.parser)

        // Weak throughout: this coordinator is reachable from the text view
        // (view → plugins → events → coordinator), so any strong capture of
        // the view here closes a retain cycle. See `SyntaxHighlightPlugin.setUp`.
        tsClient = try? TreeSitterClient(language: tsLanguage) { [weak textView] codePointIndex in
            guard let textView,
                  let location = textView.textContentManager.location(at: codePointIndex),
                  let position = textView.textContentManager.position(location)
            else {
                return .zero
            }
            return Point(row: position.row, column: position.column)
        }

        tsClient?.invalidationHandler = { [weak self] indexSet in
            self?.highlighter?.invalidate(.set(indexSet))
        }

        // Empty fonts table (see SyntaxHighlighting.theme) → this keeps kero's
        // own editor font instead of resetting to the theme's.
        textView.font = theme.font(forToken: "plain") ?? textView.font

        let textInterface = SyntaxHighlightTextInterface(textView: textView) { [weak textView] neonToken in
            // Metadata captures aren't colors — skip them so they don't repaint
            // a real capture on the same range. Swift captures comments as
            // `@comment @spell`; letting `spell` through (it resolves to the
            // plain fallback, applied after `comment`) turned comments black.
            guard textView != nil, !Self.ignoredCaptures.contains(neonToken.name) else {
                return nil
            }
            // Color only. Writing `.font` into text storage (even the same font)
            // runs an editing transaction and invalidates TextKit 2 layout for
            // every token — that is the open/scroll hitch. The theme ships no
            // per-token fonts, so the editor font already on the storage stays.
            guard let color = Self.themeColor(for: neonToken.name, theme: theme) else {
                return nil
            }
            return [.foregroundColor: color]
        }

        // Start with no token provider (a no-op); it's installed below once the
        // query is ready — off the main thread on first use, so opening a file
        // never blocks on the ~190 ms Swift query compile.
        highlighter = Neon.Highlighter(textInterface: textInterface)

        // Parse the whole document once up front.
        let documentRange = NSRange(textView.textContentManager.documentRange, in: textView.textContentManager)
        tsClient?.willChangeContent(in: documentRange)
        tsClient?.didChangeContent(
            in: documentRange,
            delta: textView.textContentManager.length,
            limit: textView.textContentManager.length,
            readHandler: Parser.readFunction(for: textView.textContentManager.attributedString(in: nil)?.string ?? ""),
            completionHandler: {}
        )

        installTokenProvider(textContentManager: textView.textContentManager)
    }

    /// tree-sitter capture names that carry no color — spell-check hints,
    /// concealment, and the explicit "no highlight" marker. Grammars attach
    /// these alongside real captures (e.g. Swift's `@comment @spell`), so they
    /// must be dropped rather than resolved to a color.
    nonisolated private static let ignoredCaptures: Set<String> = ["spell", "nospell", "conceal", "none"]

    /// The theme color for a tree-sitter capture name, trying the most specific
    /// name first and shortening on each dot (`variable.parameter` → `variable`),
    /// then the theme's `plain` default. The merged queries carry finer-grained
    /// capture names than the theme enumerates, so exact-match alone would leave
    /// many tokens uncolored.
    private static func themeColor(for name: String, theme: STPluginNeonAppKit.Theme) -> NSColor? {
        var key = name
        while true {
            if let color = theme.color(forToken: TokenName(key)) {
                return color
            }
            if let alias = captureAliases[key], let color = theme.color(forToken: TokenName(alias)) {
                return color
            }
            guard let dot = key.lastIndex(of: ".") else { break }
            key = String(key[..<dot])
        }
        return theme.color(forToken: "plain")
    }

    /// Capture names the theme's palette has no entry for, redirected onto ones
    /// it does. The palette is a fixed list that predates markup grammars, so
    /// `@tag` and `@attribute` — which carry most of the color in a JSX or HTML
    /// file — would otherwise walk straight to the `plain` fallback and leave
    /// every element name and prop the same black as the text around it.
    private static let captureAliases: [String: String] = [
        // Capitalized JSX components already reach `@constructor` through the
        // JavaScript query's `^[A-Z]` rule, so lowercase intrinsics match them
        // and `<main>` looks like `<Sidebar>`.
        "tag": "constructor",
        // The theme ships a `property` color but leaves it out of the palette;
        // `method` is the same value and does make the list.
        "attribute": "method",
    ]

    /// Install the highlighter's token provider. If the language's query is
    /// already compiled, this is synchronous (instant); otherwise the compile —
    /// the expensive part — runs on a background queue and the provider is
    /// installed when it finishes, so the editor opens without blocking and the
    /// colors appear a moment later.
    private func installTokenProvider(textContentManager: NSTextContentManager) {
        if let query = HighlightQueryCache.cached(language) {
            finishInstall(highlightsQuery: query, textContentManager: textContentManager)
            return
        }

        let data = highlightsData
        let tsLanguage = self.tsLanguage
        let language = self.language
        DispatchQueue.global(qos: .userInitiated).async {
            let query = try? SwiftTreeSitter.Query(language: tsLanguage, data: data)
            DispatchQueue.main.async { [weak self] in
                guard let self, let query, let textContentManager = self.textContentManager else {
                    return
                }
                HighlightQueryCache.store(query, for: language)
                self.finishInstall(highlightsQuery: query, textContentManager: textContentManager)
            }
        }
    }

    /// Install the right token provider now that the highlights query is ready:
    /// the injection-aware one when the root language embeds others (its
    /// injections query compiles fast — a handful of patterns against the root
    /// grammar — so it's done inline and cached), otherwise the plain
    /// single-language provider, unchanged.
    private func finishInstall(highlightsQuery: SwiftTreeSitter.Query, textContentManager: NSTextContentManager) {
        guard let injectionsData else {
            setTokenProvider(query: highlightsQuery, textContentManager: textContentManager)
            return
        }

        let injectionsQuery = HighlightQueryCache.cachedInjection(language)
            ?? (try? SwiftTreeSitter.Query(language: tsLanguage, data: injectionsData))
        guard let injectionsQuery else {
            setTokenProvider(query: highlightsQuery, textContentManager: textContentManager)
            return
        }
        HighlightQueryCache.storeInjection(injectionsQuery, for: language)

        setInjectionTokenProvider(
            highlightsQuery: highlightsQuery,
            injectionsQuery: injectionsQuery,
            textContentManager: textContentManager
        )
    }

    private func setTokenProvider(query: SwiftTreeSitter.Query, textContentManager: NSTextContentManager) {
        guard let tsClient else { return }
        highlighter?.tokenProvider = tsClient.tokenProvider(with: query) { range, _ in
            guard !range.isEmpty else { return nil }
            return textContentManager.attributedString(in: NSTextRange(range, provider: textContentManager))?.string
        }
        // Re-run highlighting now that the provider exists (the no-op provider
        // produced nothing during the initial parse).
        highlighter?.invalidate()
    }

    /// A token provider that highlights the root language *and* any embedded
    /// languages. For each request it runs the root highlights query for the
    /// base tokens, then the injections query to find embedded regions, and
    /// sub-highlights each region with its own grammar. Injected tokens are
    /// appended after the base ones so they win on the shared range: markdown
    /// tags fenced content `@none` (dropped), and the embedded bash/js/… tokens
    /// paint over it — e.g. a shell comment finally gets the comment color.
    private func setInjectionTokenProvider(
        highlightsQuery: SwiftTreeSitter.Query,
        injectionsQuery: SwiftTreeSitter.Query,
        textContentManager: NSTextContentManager
    ) {
        let textProvider: SwiftTreeSitter.Predicate.TextProvider = { range, _ in
            guard !range.isEmpty else { return nil }
            return textContentManager.attributedString(in: NSTextRange(range, provider: textContentManager))?.string
        }

        highlighter?.tokenProvider = { [weak self] range, completion in
            let completion = TokenProviderCompletion(call: completion)
            guard let self, let tsClient = self.tsClient else {
                completion.call(.success(.noChange))
                return
            }

            tsClient.executeHighlightsQuery(highlightsQuery, in: range, textProvider: textProvider) { baseResult in
                switch baseResult {
                case .failure(let error):
                    completion.call(.failure(error))
                case .success(let baseRanges):
                    let baseTokens = baseRanges.map { Neon.Token(name: $0.name, range: $0.range) }
                    tsClient.executeInjectionsQuery(injectionsQuery, in: range, textProvider: textProvider) { injectionResult in
                        let injections: [SwiftTreeSitter.NamedRange]
                        if case .success(let value) = injectionResult {
                            injections = value
                        } else {
                            injections = []
                        }
                        let (cached, jobs) = self.injectionWork(for: injections, textProvider: textProvider)
                        let known = baseTokens + cached
                        guard !jobs.isEmpty else {
                            completion.call(.success(TokenApplication(tokens: Self.clip(known, to: range), range: range)))
                            return
                        }
                        let generation = self.injectionCacheGeneration
                        DispatchQueue.global(qos: .userInitiated).async {
                            var parsed: [(InjectionCacheKey, [Neon.Token])] = []
                            parsed.reserveCapacity(jobs.count)
                            var extra: [Neon.Token] = []
                            for job in jobs {
                                let tokens = Self.tokensForFragment(job)
                                parsed.append((job.key, tokens))
                                extra.append(contentsOf: tokens)
                            }
                            DispatchQueue.main.async { [weak self] in
                                guard let self else {
                                    completion.call(.success(.noChange))
                                    return
                                }
                                guard self.injectionCacheGeneration == generation else {
                                    completion.call(.success(.noChange))
                                    return
                                }
                                for (key, tokens) in parsed {
                                    self.injectionTokenCache[key] = tokens
                                }
                                completion.call(.success(TokenApplication(
                                    tokens: Self.clip(known + extra, to: range),
                                    range: range
                                )))
                            }
                        }
                    }
                }
            }
        }
        highlighter?.invalidate()
    }

    /// Collect cached tokens and background parse jobs for one Neon request.
    /// Names with no bundled grammar (`markdown_inline`, `text`, …) are skipped.
    private func injectionWork(
        for injections: [SwiftTreeSitter.NamedRange],
        textProvider: SwiftTreeSitter.Predicate.TextProvider
    ) -> (cached: [Neon.Token], jobs: [InjectionParseJob]) {
        var cached: [Neon.Token] = []
        var jobs: [InjectionParseJob] = []
        for injection in injections {
            let injectionRange = injection.range
            guard injectionRange.length > 0,
                  let language = SyntaxHighlighting.language(forInjectionName: injection.name)
            else { continue }
            let key = InjectionCacheKey(
                language: language,
                location: injectionRange.location,
                length: injectionRange.length
            )
            if let tokens = injectionTokenCache[key] {
                cached.append(contentsOf: tokens)
                continue
            }
            guard let query = injectedHighlightsQuery(for: language),
                  let fragment = textProvider(injectionRange, Point.zero..<Point.zero),
                  !fragment.isEmpty
            else { continue }
            jobs.append(InjectionParseJob(
                key: key,
                parser: language.parser,
                query: query,
                fragment: fragment,
                offset: injectionRange.location
            ))
        }
        return (cached, jobs)
    }

    /// Parse one embedded region off the main thread. Ranges are fragment-relative
    /// and shifted into document coordinates.
    nonisolated private static func tokensForFragment(_ job: InjectionParseJob) -> [Neon.Token] {
        let parser = Parser()
        do {
            try parser.setLanguage(job.parser)
        } catch {
            return []
        }
        guard let tree = parser.parse(job.fragment), let root = tree.rootNode else {
            return []
        }
        let context = SwiftTreeSitter.Predicate.Context(string: job.fragment)
        var tokens: [Neon.Token] = []
        for named in job.query.execute(node: root, in: tree).resolve(with: context).highlights() {
            guard named.range.length > 0, !ignoredCaptures.contains(named.name) else { continue }
            let range = NSRange(location: named.range.location + job.offset, length: named.range.length)
            tokens.append(Neon.Token(name: named.name, range: range))
        }
        return tokens
    }

    /// Keep applied tokens inside the Neon request so a large fence does not
    /// expand `receivedSet` and restyle the whole block on the main thread.
    nonisolated private static func clip(_ tokens: [Neon.Token], to range: NSRange) -> [Neon.Token] {
        tokens.compactMap { token in
            let overlap = NSIntersectionRange(token.range, range)
            guard overlap.length > 0 else { return nil }
            if overlap == token.range { return token }
            return Neon.Token(name: token.name, range: overlap)
        }
    }

    /// The compiled highlights query for an embedded language, reusing (and
    /// populating) the shared `HighlightQueryCache`. On a miss the compile —
    /// which can be costly for a big grammar dropped into a code fence — runs
    /// off the main thread and `invalidate()` repaints when it lands; the region
    /// stays plain until then. Mirrors `installTokenProvider`'s root compile.
    private func injectedHighlightsQuery(for language: SyntaxLanguage) -> SwiftTreeSitter.Query? {
        if let query = HighlightQueryCache.cached(language) {
            return query
        }
        guard !pendingInjectionCompiles.contains(language) else { return nil }
        pendingInjectionCompiles.insert(language)

        let data = SyntaxHighlighting.highlightsData(for: language)
        // Grammar pointers live for the process. Pass the address because
        // OpaquePointer is not Sendable, then rebuild it on the worker queue.
        let parserAddress = UInt(bitPattern: language.parser)
        DispatchQueue.global(qos: .userInitiated).async {
            let query = OpaquePointer(bitPattern: parserAddress).flatMap { parser in
                try? SwiftTreeSitter.Query(language: Language(language: parser), data: data)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingInjectionCompiles.remove(language)
                if let query {
                    HighlightQueryCache.store(query, for: language)
                }
                // Repaint only newly visible invalid text. `.all` re-parses
                // every fence on the next highlight pass.
                self.highlighter?.visibleContentDidChange()
            }
        }
        return nil
    }

    func updateViewportRange(_ range: NSTextRange?) {
        if range != prevViewportRange {
            highlighter?.visibleContentDidChange()
        }
        prevViewportRange = range
    }

    func willChangeContent(in range: NSRange) {
        pendingPreEditRange = range.location == NSNotFound ? nil : range
        tsClient?.willChangeContent(in: range)
    }

    func didChangeContent(
        _ textContentManager: NSTextContentManager,
        in range: NSRange,
        replacementUTF16Count: Int,
        limit: Int
    ) {
        let preEdit = pendingPreEditRange ?? range
        pendingPreEditRange = nil
        let delta = replacementUTF16Count - preEdit.length
        injectionCacheGeneration &+= 1
        if !injectionTokenCache.isEmpty {
            injectionTokenCache = InjectionTokenCacheShift.rewrite(
                injectionTokenCache,
                preEdit: preEdit,
                delta: delta
            )
        }
        guard let string = textContentManager.attributedString(in: nil)?.string else { return }
        tsClient?.didChangeContent(
            in: preEdit,
            delta: delta,
            limit: limit,
            readHandler: Parser.readFunction(for: string),
            completionHandler: {}
        )
    }
}

/// Keep injection tokens whose fences sit wholly outside a UTF-16 edit;
/// drop overlapping fences; shift later fences (and their token ranges) by
/// `delta`. In-flight parses are dropped separately via `injectionCacheGeneration`.
enum InjectionTokenCacheShift {
    static func rewrite(
        _ cache: [InjectionCacheKey: [Neon.Token]],
        preEdit: NSRange,
        delta: Int
    ) -> [InjectionCacheKey: [Neon.Token]] {
        let editStart = preEdit.location
        let editOldEnd = NSMaxRange(preEdit)
        var next: [InjectionCacheKey: [Neon.Token]] = [:]
        next.reserveCapacity(cache.count)
        for (key, tokens) in cache {
            let keyEnd = key.location + key.length
            if keyEnd <= editStart {
                next[key] = tokens
            } else if key.location >= editOldEnd {
                let shiftedKey = InjectionCacheKey(
                    language: key.language,
                    location: key.location + delta,
                    length: key.length
                )
                if delta == 0 {
                    next[shiftedKey] = tokens
                } else {
                    next[shiftedKey] = tokens.map { token in
                        Neon.Token(
                            name: token.name,
                            range: NSRange(
                                location: token.range.location + delta,
                                length: token.range.length
                            )
                        )
                    }
                }
            }
        }
        return next
    }

    /// Returns the first mismatch, or nil when keep/drop/shift cases hold.
    static func firstFailingCase() -> String? {
        let language = SyntaxLanguage.tsx
        func key(_ location: Int, _ length: Int) -> InjectionCacheKey {
            InjectionCacheKey(language: language, location: location, length: length)
        }
        func token(_ location: Int, _ length: Int) -> Neon.Token {
            Neon.Token(name: "kw", range: NSRange(location: location, length: length))
        }

        let before = key(0, 8)
        let overlap = key(8, 8)
        let after = key(20, 5)
        let cache: [InjectionCacheKey: [Neon.Token]] = [
            before: [token(1, 2)],
            overlap: [token(9, 2)],
            after: [token(21, 2)],
        ]

        // Replace 2 UTF-16 units at 10 with 5 units (delta +3).
        let shifted = rewrite(cache, preEdit: NSRange(location: 10, length: 2), delta: 3)
        guard shifted[before]?.count == 1 else { return "keep span wholly before edit" }
        guard shifted[overlap] == nil else { return "drop overlapping span" }
        guard shifted[after] == nil else { return "old after-key must not remain" }
        let shiftedAfter = key(23, 5)
        guard let afterTokens = shifted[shiftedAfter],
              afterTokens.count == 1,
              afterTokens[0].range == NSRange(location: 24, length: 2)
        else { return "shift span wholly after edit, including token ranges" }

        // Insertion at 8: fence ending at 8 stays; fence starting at 8 moves.
        let boundary: [InjectionCacheKey: [Neon.Token]] = [
            key(0, 8): [token(0, 8)],
            key(8, 4): [token(8, 2)],
        ]
        let inserted = rewrite(boundary, preEdit: NSRange(location: 8, length: 0), delta: 1)
        guard inserted[key(0, 8)] != nil else { return "keep fence ending at insertion point" }
        guard inserted[key(8, 4)] == nil else { return "fence starting at insertion point must shift" }
        guard inserted[key(9, 4)]?.first?.range == NSRange(location: 9, length: 2) else {
            return "shift fence that starts at insertion point"
        }

        let sameLength = rewrite(cache, preEdit: NSRange(location: 10, length: 2), delta: 0)
        guard sameLength[before] != nil, sameLength[overlap] == nil, sameLength[after] != nil else {
            return "delta 0 still drops overlap and leaves non-overlapping keys unshifted"
        }

        let empty = rewrite([:], preEdit: NSRange(location: 0, length: 1), delta: 1)
        guard empty.isEmpty else { return "empty cache stays empty" }
        return nil
    }
}

/// Bridges Neon's token styling onto an STTextView. Colors are applied as
/// rendering (temporary) attributes so they layer over the base text color;
/// any other attributes (currently none, since the theme carries no per-token
/// fonts) go into the text storage.
private final class SyntaxHighlightTextInterface: TextSystemInterface {
    typealias AttributeProvider = (Neon.Token) -> [NSAttributedString.Key: Any]?

    /// Weak: the text view owns this interface transitively (view → plugins →
    /// events → coordinator → highlighter → here), so a strong reference back
    /// would keep every editor — and its whole document — alive forever.
    private weak var textView: STTextView?
    private let attributeProvider: AttributeProvider

    init(textView: STTextView, attributeProvider: @escaping AttributeProvider) {
        self.textView = textView
        self.attributeProvider = attributeProvider
    }

    func clearStyle(in range: NSRange) {
        guard let textView,
              let textRange = NSTextRange(range, in: textView.textContentManager)
        else { return }
        textView.textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
    }

    func applyStyle(to token: Neon.Token) {
        // Zero-length tokens (markdown emits them) would crash TextKit when
        // used as a rendering-attribute range; STTextLayoutManager also guards
        // this, but skipping here avoids the wasted work.
        guard let textView,
              token.range.length > 0,
              let attributes = attributeProvider(token),
              let color = attributes[.foregroundColor],
              let textRange = NSTextRange(token.range, in: textView.textContentManager)
        else {
            return
        }
        textView.textLayoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
    }

    var length: Int {
        textView?.textContentManager.length ?? 0
    }

    var visibleRange: NSRange {
        guard let textView,
              let viewportRange = textView.textLayoutManager.textViewportLayoutController.viewportRange
        else {
            return .zero
        }
        return NSRange(viewportRange, provider: textView.textContentManager)
    }
}
