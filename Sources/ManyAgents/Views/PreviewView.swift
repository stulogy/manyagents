import SwiftUI
import WebKit

// MARK: - Shared data store

extension WKWebsiteDataStore {
    /// One persistent data store shared across every preview panel.
    /// Logging in once authenticates all of them.
    static var manyAgentsPreview: WKWebsiteDataStore {
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: UUID(uuidString: "app.manyagents.preview")!)
        }
        return .default()
    }
}

// MARK: - PreviewView

struct PreviewView: View {
    @EnvironmentObject var manager: AgentManager
    @State private var urlText: String = "http://localhost:3000"
    @State private var coordinator = WebCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WebViewRepresentable(coordinator: coordinator)
        }
        .onChange(of: manager.previewURL) { _, newURL in
            guard let url = newURL else { return }
            urlText = url.absoluteString
            coordinator.load(url)
        }
        .onAppear {
            if let url = manager.previewURL {
                urlText = url.absoluteString
                coordinator.load(url)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { coordinator.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Back")

            Button { coordinator.goForward() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Forward")

            Button { coordinator.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Reload")

            TextField("http://localhost:3000", text: $urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .onSubmit { navigate() }

            Button { navigate() } label: {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Go")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(.secondary)
    }

    private func navigate() {
        var raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            raw = "http://" + raw
            urlText = raw
        }
        guard let url = URL(string: raw) else { return }
        coordinator.load(url)
    }
}

// MARK: - Coordinator (holds the WKWebView across SwiftUI redraws)

final class WebCoordinator: NSObject, WKNavigationDelegate, ObservableObject {
    var webView: WKWebView?

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .manyAgentsPreview
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        self.webView = wv
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    func goBack()    { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload()    { webView?.reload() }
}

// MARK: - NSViewRepresentable bridge

struct WebViewRepresentable: NSViewRepresentable {
    let coordinator: WebCoordinator

    func makeNSView(context: Context) -> WKWebView {
        coordinator.webView ?? WKWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> WebCoordinator { coordinator }
}
