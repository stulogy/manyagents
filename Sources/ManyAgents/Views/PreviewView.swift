import SwiftUI
import WebKit

// One persistent data store shared across every preview panel —
// log in once and all agent previews are authenticated.
extension WKWebsiteDataStore {
    static var manyAgentsPreview: WKWebsiteDataStore {
        if #available(macOS 14.0, *) {
            // Fixed UUID identifying the shared ManyAgents preview store.
            // Must be a valid UUID — "app.manyagents.preview" is not one.
            let id = UUID(uuidString: "6F3B8E2A-4C1D-4A5B-9F0E-1D2C3E4F5A6B")!
            return WKWebsiteDataStore(forIdentifier: id)
        }
        return .default()
    }
}

// Navigation commands passed from the toolbar into the NSViewRepresentable.
enum WebNavAction {
    case load(URL), back, forward, reload
}

// MARK: - PreviewView

struct PreviewView: View {
    @EnvironmentObject var manager: AgentManager
    /// This checkout's browser, so the address bar follows agent-driven
    /// navigation and redirects, not just what the user typed. The view is
    /// re-created per scope (see `.id` at the call site), so this stays the
    /// right one.
    @ObservedObject private var browser: PreviewBrowser
    @State private var urlText = ""
    @State private var navAction: WebNavAction? = nil
    @State private var hasLoaded = false

    init(scope: String) {
        _browser = ObservedObject(wrappedValue: PreviewBrowser.forScope(scope))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            if hasLoaded {
                // Constrained to the device's LOGICAL size, on a dim ground
                // so the edges of the viewport are visible. The width is
                // what CSS media queries see; the user agent (set on the
                // browser) is what the server and the page's own JS see.
                // Both have to agree or you are testing a narrow desktop
                // page, which is exactly the bug this is meant to catch.
                ZStack {
                    if browser.device != .desktop {
                        Color.black.opacity(0.25)
                    }
                    BrowserView(browser: browser, navAction: $navAction) { newURL in
                        urlText = newURL
                    }
                    .frame(maxWidth: browser.device.width ?? .infinity,
                           maxHeight: browser.device.height ?? .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: browser.device == .desktop ? 0 : 10,
                                                style: .continuous))
                }
            } else {
                emptyState
            }
        }
        // Navigate when the active session's worktree URL changes (tab switch
        // or agent calling open_preview).
        .onChange(of: manager.activePreviewURL) { _, url in
            guard let url else { return }
            urlText = url.absoluteString
            navAction = .load(url)
            hasLoaded = true
        }
        // An agent navigating (or the site redirecting to /login) moves the
        // address bar too — otherwise it reads as the URL that was asked
        // for while the panel shows something else entirely.
        .onChange(of: browser.currentURL) { _, url in
            if let url { urlText = url.absoluteString }
        }
        .onAppear {
            // A page an agent already set up outlives the panel: show that
            // rather than yanking it back to the session's stored URL.
            if let live = browser.currentURL {
                urlText = live.absoluteString
                hasLoaded = true
            } else if let url = manager.activePreviewURL {
                urlText = url.absoluteString
                navAction = .load(url)
                hasLoaded = true
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No preview yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Ask your agent to start a server, or type a URL in the bar above.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { navAction = .back } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Back")

            Button { navAction = .forward } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Forward")

            Button { navAction = .reload } label: {
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

            devicePicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(.secondary)
    }

    /// Desktop / iPhone / iPad. Same hand-rolled pill as the sidebar's view
    /// switcher, so the app has one shape for "pick one of these".
    private var devicePicker: some View {
        HStack(spacing: 3) {
            ForEach(PreviewDevice.allCases) { d in
                let on = browser.device == d
                Button {
                    browser.device = d
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? Color.brandOrange : Color.clear)
                        .frame(width: 28, height: 22)
                        .overlay(
                            Image(systemName: d.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(on ? Color.white : .secondary)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(d.label)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private func navigate() {
        var raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            raw = "http://" + raw
            urlText = raw
        }
        guard let url = URL(string: raw) else { return }
        if let s = manager.activeSession {
            manager.previewURLs[s.previewScope] = url
        }
        hasLoaded = true
        navAction = .load(url)
    }
}

// MARK: - BrowserView (NSViewRepresentable)

struct BrowserView: NSViewRepresentable {
    let browser: PreviewBrowser
    @Binding var navAction: WebNavAction?
    var onURLChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onURLChange: onURLChange)
    }

    /// The panel renders PreviewBrowser's web view rather than one of its
    /// own. Same browser the agents drive, so what you see here is what
    /// they see, and a page an agent set up survives you closing the panel.
    func makeNSView(context: Context) -> WKWebView {
        browser.view()
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.onURLChange = onURLChange
        guard let action = navAction else { return }
        switch action {
        case .load(let url): wv.load(URLRequest(url: url))
        case .back:          wv.goBack()
        case .forward:       wv.goForward()
        case .reload:        wv.reload()
        }
        // Clear after handling without mutating state during an update pass.
        DispatchQueue.main.async { navAction = nil }
    }

    // MARK: Coordinator

    /// Only mirrors the address bar now — PreviewBrowser is the web view's
    /// navigation delegate, since it has to know about redirects whether or
    /// not this panel is on screen.
    final class Coordinator: NSObject {
        var onURLChange: (String) -> Void

        init(onURLChange: @escaping (String) -> Void) {
            self.onURLChange = onURLChange
        }
    }
}
