import Foundation

enum PulseLanguage: String, CaseIterable, Identifiable {
    case system, zhHans, en
    var id: String { rawValue }
    var title: String { switch self { case .system: return L10n.text("跟随系统"); case .zhHans: return "简体中文"; case .en: return "English" } }
}

/// Stable Chinese source keys keep protocol identifiers and persisted data intact.
/// Translations are applied at presentation time, including saved status messages.
enum L10n {
    private static let lock = NSLock()
    private static var selected: PulseLanguage = .system
    private static var cache: [String: String] = [:]
    static var language: PulseLanguage {
        get { lock.lock(); defer { lock.unlock() }; return selected }
        set { lock.lock(); selected = newValue; cache.removeAll(); lock.unlock() }
    }
    static var isEnglish: Bool { language == .en || (language == .system && !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh")) }
    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "zh_CN") }
    private static let english: [String: String] = {
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: "en", withExtension: "json", subdirectory: "Localization") { urls.append(url) }
        if let url = Bundle.main.url(forResource: "en", withExtension: "json") { urls.append(url) }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "en", withExtension: "json", subdirectory: "Localization") { urls.append(url) }
        if let url = Bundle.module.url(forResource: "en", withExtension: "json") { urls.append(url) }
        #endif
        // CLT test harness and source builds do not have a main application bundle.
        urls.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localization/en.json"))
        for url in urls { if let data = try? Data(contentsOf: url), let table = try? JSONDecoder().decode([String: String].self, from: data) { return table } }
        return [:]
    }()
    private static let templates: [(NSRegularExpression, String)] = english.keys.filter { $0.contains("{0}") }.sorted { $0.count > $1.count }.compactMap { key in
        let marker = try! NSRegularExpression(pattern: "\\{[0-9]+\\}")
        let matches = marker.matches(in: key, range: NSRange(key.startIndex..., in: key))
        var pattern = "", position = key.startIndex
        for match in matches {
            guard let range = Range(match.range, in: key) else { continue }
            pattern += NSRegularExpression.escapedPattern(for: String(key[position..<range.lowerBound])) + "(.+?)"
            position = range.upperBound
        }
        pattern += NSRegularExpression.escapedPattern(for: String(key[position...]))
        guard let expression = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators]) else { return nil }
        return (expression, english[key]!)
    }
    static func text(_ source: String) -> String { translated(source, depth: 0) }
    static func format(_ key: String, _ arguments: String...) -> String {
        var result = isEnglish ? english[key] ?? key : key
        for (index, argument) in arguments.enumerated() { result = result.replacingOccurrences(of: "{\(index)}", with: text(argument)) }
        return result
    }
    private static func translated(_ source: String, depth: Int) -> String {
        guard isEnglish, source.range(of: "\\p{Han}", options: .regularExpression) != nil else { return source }
        if let value = english[source] { return value }
        lock.lock(); let found = cache[source]; lock.unlock()
        if let found { return found }
        var result = source
        let range = NSRange(source.startIndex..., in: source)
        if depth < 3 {
            for (pattern, translation) in templates {
                guard let match = pattern.firstMatch(in: source, range: range) else { continue }
                result = translation
                for index in 1..<match.numberOfRanges {
                    if let part = Range(match.range(at: index), in: source) { result = result.replacingOccurrences(of: "{\(index - 1)}", with: translated(String(source[part]), depth: depth + 1)) }
                }
                break
            }
        }
        lock.lock(); if cache.count > 2048 { cache.removeAll(keepingCapacity: true) }; cache[source] = result; lock.unlock()
        return result
    }
}
