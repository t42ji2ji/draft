import AppKit

// WebKit and PDFKit are not linked: they are dlopen'ed the first time the preview is shown, so they cost nothing
// at launch (measured: dlopen of WebKit after AppKit is up takes ~8 ms, PDFKit ~1 ms). Everything the preview needs
// from them goes through the Objective-C runtime here; delegate objects implement the selectors by name.
enum WebKitRuntime {
    static let loaded: Bool = {
        let webKit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW) != nil
        let pdfKit = dlopen("/System/Library/Frameworks/PDFKit.framework/PDFKit", RTLD_NOW) != nil
        return webKit && pdfKit
    }()

    static func make(_ className: String) -> NSObject {
        precondition(loaded, "WebKit could not be loaded")
        return (NSClassFromString(className) as! NSObject.Type).init()
    }

    static func sel(_ s: String) -> Selector { NSSelectorFromString(s) }
}

/// A WKWebView reached through the runtime.
final class DynamicWebView {
    let view: NSView

    /// `handlers` are installed with `setURLSchemeHandler:forURLScheme:`; `messageHandler` receives
    /// `window.webkit.messageHandlers[messageName].postMessage(…)`.
    init(schemeHandlers: [String: NSObject], messageHandler: NSObject, messageName: String, navigationDelegate: NSObject) {
        let config = WebKitRuntime.make("WKWebViewConfiguration")
        for (scheme, handler) in schemeHandlers {
            config.perform(WebKitRuntime.sel("setURLSchemeHandler:forURLScheme:"), with: handler, with: scheme)
        }
        let content = config.value(forKey: "userContentController") as! NSObject
        content.perform(WebKitRuntime.sel("addScriptMessageHandler:name:"), with: messageHandler, with: messageName)

        let cls: AnyClass = NSClassFromString("WKWebView")!
        let alloc = WebKitRuntime.sel("alloc"), initSel = WebKitRuntime.sel("initWithFrame:configuration:")
        let allocated = (cls as AnyObject).perform(alloc)!.takeUnretainedValue()
        typealias Init = @convention(c) (AnyObject, Selector, NSRect, AnyObject) -> Unmanaged<NSView>
        let imp = unsafeBitCast(class_getMethodImplementation(cls, initSel)!, to: Init.self)
        view = imp(allocated, initSel, NSRect(x: 0, y: 0, width: 600, height: 600), config).takeRetainedValue()
        view.perform(WebKitRuntime.sel("setNavigationDelegate:"), with: navigationDelegate)
        view.setValue(false, forKey: "drawsBackground")
        view.setValue(false, forKey: "allowsMagnification")
    }

    var url: URL? { view.value(forKey: "URL") as? URL }

    func loadFileURL(_ url: URL, allowingReadAccessTo root: URL) {
        view.perform(WebKitRuntime.sel("loadFileURL:allowingReadAccessToURL:"), with: url, with: root)
    }

    func evaluateJavaScript(_ source: String, completion: ((Any?, Error?) -> Void)? = nil) {
        let sel = WebKitRuntime.sel("evaluateJavaScript:completionHandler:")
        typealias Eval = @convention(c) (AnyObject, Selector, NSString, AnyObject) -> Void
        let imp = unsafeBitCast(view.method(for: sel)!, to: Eval.self)
        let block: @convention(block) (AnyObject?, NSError?) -> Void = { completion?($0, $1) }
        imp(view, sel, source as NSString, block as AnyObject)
    }

    func printOperation(with info: NSPrintInfo) -> NSPrintOperation {
        view.perform(WebKitRuntime.sel("printOperationWithPrintInfo:"), with: info)!.takeUnretainedValue() as! NSPrintOperation
    }
}

/// PDFKit's PDFView and PDFDocument, through the runtime.
enum DynamicPDF {
    static func makeView() -> NSView {
        _ = WebKitRuntime.loaded
        let view = (NSClassFromString("PDFView") as! NSView.Type).init(frame: .zero)
        view.setValue(true, forKey: "autoScales")
        view.setValue(1, forKey: "displayMode")   // kPDFDisplaySinglePageContinuous
        return view
    }

    static func setDocument(_ data: Data, on view: NSView) {
        let cls: AnyClass = NSClassFromString("PDFDocument")!
        let allocated = (cls as AnyObject).perform(WebKitRuntime.sel("alloc"))!.takeUnretainedValue()
        guard let doc = allocated.perform(WebKitRuntime.sel("initWithData:"), with: data)?.takeRetainedValue() else { return }
        view.setValue(doc, forKey: "document")
    }
}
