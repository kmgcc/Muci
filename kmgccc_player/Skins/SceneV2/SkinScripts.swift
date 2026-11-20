import AppKit
import Foundation
import JavaScriptCore
import NaturalLanguage

/// A skin's own JavaScript. Every `scripts/*.js` file in the package runs once, in file-name
/// order, in one private JavaScriptCore context; expressions call its top-level function
/// declarations with `script(name, …)`.
///
/// Values go in and out as plain data: numbers, text, booleans, null, lists and records (a
/// colour arrives as its hex text). The context has no file, network or timer access; the host
/// adds one object, `host`, with what only the app can answer:
/// - `host.measureText(text, size, weight, font)`: typographic width in points, the same as
///   the expression `measureText`.
/// - `host.lineHeight(font, weight, size)`: ascender + descender + leading of that face.
/// - `host.wordStarts(text)`: where the system's word tokenizer starts each word, as UTF-16
///   offsets (the units of JavaScript string indices). It splits Chinese and Japanese into words.
///
/// Calls run synchronously on the main thread, so a script should do one bounded piece of work
/// per call (laying out a line, deciding the next camera move) and keep no state of its own
/// between calls: hot reloading a skin starts a new context.
@MainActor
final class SkinScripts {
    struct LoadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The top-level functions expressions may call.
    let functions: Set<String>
    private let context: JSContext
    private var reported: Set<String> = []

    /// Loads `scripts/*.js` from a package directory; nil when it has none.
    static func load(from root: URL) throws -> SkinScripts? {
        let directory = root.appendingPathComponent("scripts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "js" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return nil }
        var sources: [(name: String, text: String)] = []
        for url in files {
            let safeURL = try SkinResourceResolver.resolve("scripts/" + url.lastPathComponent, root: root)
            guard (try safeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1024 * 1024 else {
                throw LoadError(message: "脚本超过大小限制：scripts/\(url.lastPathComponent)")
            }
            sources.append(("scripts/" + url.lastPathComponent, try String(contentsOf: safeURL, encoding: .utf8)))
        }
        return try SkinScripts(sources: sources)
    }

    init(sources: [(name: String, text: String)]) throws {
        guard let context = JSContext() else { throw LoadError(message: "无法创建脚本环境") }
        self.context = context
        context.name = "skin scripts"
        context.setObject(Self.host(in: context), forKeyedSubscript: "host" as NSString)
        for source in sources {
            context.exception = nil
            context.evaluateScript(source.text, withSourceURL: URL(fileURLWithPath: source.name))
            if let exception = context.exception {
                throw LoadError(message: "\(source.name)：\(Self.describe(exception))")
            }
        }
        let names = context.evaluateScript("Object.keys(globalThis).filter(function (k) { return typeof globalThis[k] === 'function' })")
        functions = Set((names?.toArray() as? [String]) ?? [])
    }

    /// Calls a top-level function. A thrown error or a missing function gives null; each
    /// distinct error is logged once.
    func call(_ name: String, _ arguments: [SkinValue]) -> SkinValue {
        guard functions.contains(name), let function = context.objectForKeyedSubscript(name) else { return .null }
        context.exception = nil
        let result = function.call(withArguments: arguments.map(Self.object))
        if let exception = context.exception {
            let message = "\(name)()：\(Self.describe(exception))"
            if reported.insert(message).inserted { Log.warning("Skin script failed: \(message)", category: .ui) }
            context.exception = nil
            return .null
        }
        return Self.value(result?.toObject(), depth: 0)
    }

    // MARK: Values

    private static func object(_ value: SkinValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .boolean(let flag): return NSNumber(value: flag)
        case .number(let number): return NSNumber(value: number.isFinite ? number : 0)
        case .text(let text): return text
        case .color(let color): return color.hexString
        case .list(let items): return items.map(object)
        case .record(let fields): return fields.mapValues(object)
        }
    }

    private static func value(_ object: Any?, depth: Int) -> SkinValue {
        guard depth < 32, let object else { return .null }
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            return .number(SkinFunctions.sanitized(number.doubleValue))
        case let text as String: return .text(text)
        case let items as [Any]: return .list(items.prefix(4096).map { value($0, depth: depth + 1) })
        case let fields as [String: Any]: return .record(fields.mapValues { value($0, depth: depth + 1) })
        default: return .null
        }
    }

    private static func describe(_ exception: JSValue) -> String {
        let line = exception.objectForKeyedSubscript("line").flatMap { $0.isUndefined ? nil : $0.toInt32() }
        return (exception.toString() ?? "脚本错误") + (line.map { "（第 \($0) 行）" } ?? "")
    }

    // MARK: Host

    private static let tokenizer = NLTokenizer(unit: .word)

    private static func host(in context: JSContext) -> JSValue {
        let host = JSValue(newObjectIn: context)!
        func text(_ value: JSValue?) -> String { value.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() } ?? "" }
        let measureText: @convention(block) (JSValue?, JSValue?, JSValue?, JSValue?) -> Double = { string, size, weight, font in
            MainActor.assumeIsolated {
                SkinTextMeasure.width(text(string), size: size?.toDouble() ?? 0, weight: text(weight), font: text(font))
            }
        }
        let lineHeight: @convention(block) (JSValue?, JSValue?, JSValue?) -> Double = { font, weight, size in
            let face = SkinFontResolver.font(text(font), size: max(1, size?.toDouble() ?? 100), weight: text(weight))
            return Double(face.ascender - face.descender + face.leading)
        }
        let wordStarts: @convention(block) (JSValue?) -> [Int] = { string in
            MainActor.assumeIsolated {
                let joined = text(string)
                var starts: [Int] = []
                tokenizer.string = joined
                tokenizer.enumerateTokens(in: joined.startIndex..<joined.endIndex) { range, _ in
                    starts.append(range.lowerBound.utf16Offset(in: joined))
                    return true
                }
                return starts
            }
        }
        host.setObject(unsafeBitCast(measureText, to: AnyObject.self), forKeyedSubscript: "measureText" as NSString)
        host.setObject(unsafeBitCast(lineHeight, to: AnyObject.self), forKeyedSubscript: "lineHeight" as NSString)
        host.setObject(unsafeBitCast(wordStarts, to: AnyObject.self), forKeyedSubscript: "wordStarts" as NSString)
        return host
    }
}
