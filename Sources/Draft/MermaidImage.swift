import AppKit
import JavaScriptCore

// ```mermaid blocks drawn in the editor (Draft addition, docs/markdown-styling.md). Pele, the preview's renderer
// (Kit/Pele.js), runs in JavaScriptCore; its SVG reads CSS variables, which CoreSVG doesn't know, so they are filled
// in with the editor's colours before the SVG becomes an NSImage.
enum MermaidImage {
    // Hex colours for Pele's --pele-* variables (bg, fg, line, muted, border, surface, surface-alt).
    typealias Colors = [String: String]

    private static var cache: [String: NSImage] = [:]

    private static let context: JSContext? = {
        let file = PreviewViewController.resourceRoot.appendingPathComponent("Kit/Pele.js")
        guard let source = try? String(contentsOf: file, encoding: .utf8), let context = JSContext() else { return nil }
        context.evaluateScript(source + ";globalThis.pele = pele;")
        return context
    }()

    // nil when the source doesn't parse.
    static func image(for source: String, colors: Colors) -> NSImage? {
        let key = source + "\u{0}" + colors.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined()
        if let image = cache[key] { return image }
        guard let context, let pele = context.objectForKeyedSubscript("pele") else { return nil }
        context.exception = nil
        let result = pele.invokeMethod("render", withArguments: [source])
        guard context.exception == nil, let svg = result?.objectForKeyedSubscript("svg")?.toString(),
              let image = NSImage(data: Data(resolve(svg, colors: colors).utf8)) else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[key] = image
        return image
    }

    private static let peleVariable = try! NSRegularExpression(pattern: #"var\(--pele-([a-z0-9-]+),\s*([^()]*(?:\([^()]*\))?[^()]*)\)"#)
    private static let localVariable = try! NSRegularExpression(pattern: #"--(_[a-z]+):([^;"]+)"#)

    // `var(--pele-x, fallback)` becomes our colour or the fallback; then Pele's own `--_x` shorthands, declared on
    // the root element from those, are substituted where they are used.
    private static func resolve(_ svg: String, colors: Colors) -> String {
        var out = svg
        while let m = peleVariable.firstMatch(in: out, range: NSRange(location: 0, length: (out as NSString).length)) {
            let ns = out as NSString
            out = ns.replacingCharacters(in: m.range, with: colors[ns.substring(with: m.range(at: 1))] ?? ns.substring(with: m.range(at: 2)))
        }
        let ns = out as NSString
        var values: [String: String] = [:]
        for m in localVariable.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            values[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        for (name, value) in values { out = out.replacingOccurrences(of: "var(--\(name))", with: value) }
        return out
    }
}
