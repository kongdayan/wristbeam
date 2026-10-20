import Foundation

enum PulseLanguage: String, CaseIterable, Identifiable {
    case system, zhHans, en
    var id: String { rawValue }
    var title: String { switch self { case .system: return L10n.text("跟随系统"); case .zhHans: return "简体中文"; case .en: return "English" } }
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        guard self == .system else { return self }
        let primary = (preferredLanguages.first ?? "en").lowercased().replacingOccurrences(of: "_", with: "-")
        return primary == "zh" || primary.hasPrefix("zh-") ? .zhHans : .en
    }
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
    static var isEnglish: Bool { language.resolved() == .en }
    static var languageTag: String { isEnglish ? "en-US" : "zh-CN" }
    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "zh_CN") }
    private static let english: [String: String] = {
        // Installed apps own their resources. Bundle.module traps when SwiftPM's
        // build-time resource bundle is absent, even if Bundle.main is valid.
        var bundles = [Bundle.main]
        if Bundle.main.bundleURL.pathExtension != "app" {
            let resource = Bundle.main.bundleURL.appendingPathComponent("WristBeam_GarminBar.bundle")
            if let bundle = Bundle(url: resource) { bundles.append(bundle) }
        }
        for bundle in bundles {
            for subdirectory in ["Localization", nil] as [String?] {
                if let url = bundle.url(forResource: "en", withExtension: "json", subdirectory: subdirectory),
                   let data = try? Data(contentsOf: url),
                   let table = try? JSONDecoder().decode([String: String].self, from: data) { return table }
            }
        }
        // Source-only harnesses have no app bundle. Never let a packaged app
        // silently borrow the checkout's catalog and hide a packaging error.
        if Bundle.main.bundleURL.pathExtension != "app" {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localization/en.json")
            if let data = try? Data(contentsOf: url), let table = try? JSONDecoder().decode([String: String].self, from: data) { return table }
        }
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
    static func verifyPackagedResources() -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app", english.count > 800 else { return false }
        let original = language; defer { language = original }
        language = .system
        let expectedEnglish = PulseLanguage.system.resolved() == .en
        guard text("腕映") == (expectedEnglish ? "WristBeam" : "腕映") else { return false }
        for _ in 0..<3 {
            language = .en
            guard text("腕映") == "WristBeam", text("显示设置") == "Display settings",
                  text("搜索结果") == "Search results",
                  text("搜索表盘名称、关键词或粘贴链接") == "Search watch faces by name, keyword or link",
                  text("已刷新 51 项云端同步指标") == "Refreshed 51 cloud metrics" else { return false }
            language = .zhHans
            guard text("腕映") == "腕映", text("显示设置") == "显示设置", text("搜索结果") == "搜索结果" else { return false }
        }
        return true
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
