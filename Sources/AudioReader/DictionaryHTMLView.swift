import SwiftUI
import WebKit

#if os(macOS)
struct DictionaryHTMLView: NSViewRepresentable {
    let html: String
    var dark: Bool = true
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.isInspectable = false
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let page = DictionaryLookup.displayHTML(html, dark: dark)
        if context.coordinator.lastHTML != page {
            context.coordinator.lastHTML = page
            view.loadHTMLString(page, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String = ""
        var height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { value, _ in
                let h = (value as? CGFloat) ?? CGFloat((value as? Double) ?? 120)
                DispatchQueue.main.async {
                    self.height.wrappedValue = min(max(h + 12, 120), 900)
                }
            }
        }
    }
}
#else
import UIKit

struct DictionaryHTMLView: UIViewRepresentable {
    let html: String
    var dark: Bool = true
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let page = DictionaryLookup.displayHTML(html, dark: dark)
        if context.coordinator.lastHTML != page {
            context.coordinator.lastHTML = page
            view.loadHTMLString(page, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        var height: Binding<CGFloat>

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { value, _ in
                let resolved = (value as? CGFloat) ?? CGFloat((value as? Double) ?? 120)
                DispatchQueue.main.async {
                    self.height.wrappedValue = min(max(resolved + 12, 120), 900)
                }
            }
        }
    }
}

#endif
