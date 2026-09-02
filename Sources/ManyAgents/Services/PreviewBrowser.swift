import Foundation
import WebKit
import AppKit

/// The one browser the preview panel shows, owned here rather than by the
/// view, so agents can drive it whether or not the panel is on screen.
///
/// Before this, `open_preview(url)` was the entire browser surface an agent
/// had: load a URL and hope. No clicking, no typing, no reading the page,
/// not even a way to learn that the app had bounced it to /login — the tool
/// returned the URL it ASKED for, never the one it landed on. So agents
/// showed the user a login screen and moved on, or gave up on the panel and
/// launched their own headless Playwright, which the user can't see.
///
/// The cookie half was already solved: every panel shares
/// `WKWebsiteDataStore.manyAgentsPreview`, so the user signs in by hand once
/// and agents inherit the session. That's deliberate — agents drive this
/// browser, they never type credentials into it.
@MainActor
final class PreviewBrowser: NSObject, ObservableObject {
    /// One browser per CHECKOUT, not one for the app. Two worktrees of a
    /// repo run two dev servers on two ports, and a single shared panel
    /// meant each one navigated the other away — you'd switch tabs and find
    /// the other project's page, or an agent would drive a page that had
    /// moved under it. Cookies are still shared (one data store), so a
    /// sign-in in one carries to the rest.
    private static var browsers: [String: PreviewBrowser] = [:]

    static func forScope(_ scope: String) -> PreviewBrowser {
        if let existing = browsers[scope] { return existing }
        let made = PreviewBrowser()
        browsers[scope] = made
        return made
    }

    /// Every live browser, for the rare caller that needs to sweep them.
    static var all: [PreviewBrowser] { Array(browsers.values) }

    /// Nil until something first needs a browser. Created here, handed to
    /// `BrowserView` on demand, and outlives the panel being closed, so a
    /// page an agent set up is still there when the user opens the panel.
    private var webView: WKWebView?

    /// The last URL a load finished on — the REAL one after redirects, which
    /// is the whole point for a tab that expected a dashboard and got a
    /// login page. Published so the toolbar tracks agent-driven navigation.
    @Published private(set) var currentURL: URL?

    /// True while a navigation is in flight, so `settle()` knows to wait.
    private var loading = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    enum Failure: LocalizedError {
        case noPage
        case js(String)
        case notFound(String)
        case badURL(String)
        case snapshot(String)
        case blocked(String)

        var errorDescription: String? {
            switch self {
            case .noPage:
                return "Nothing is loaded in the preview yet — call open_preview with a URL first."
            case .js(let m):        return "The page rejected that: \(m)"
            case .notFound(let s):  return "No element matches \(s) on this page."
            case .blocked(let why):
                return "The form refused to submit — the browser's own validation rejected a field (\(why)). Fix the value and click again."
            case .badURL(let u):    return "Not a usable URL: \(u)"
            case .snapshot(let m):  return "Couldn't capture the page: \(m)"
            }
        }
    }

    /// The live web view, made on first use. `BrowserView` renders THIS
    /// instance instead of making its own, which is what lets the same page
    /// survive the panel being closed and reopened.
    func view() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .manyAgentsPreview
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900),
                           configuration: config)
        wv.navigationDelegate = self
        // A real user agent. Some apps serve a stripped or "unsupported
        // browser" page to WebKit clients that don't look like Safari, and
        // an agent then reports the app is broken when it isn't.
        wv.customUserAgent = nil
        webView = wv
        return wv
    }

    /// True once a page has been loaded — the tools refuse politely rather
    /// than silently doing nothing against an empty browser.
    var hasPage: Bool { webView?.url != nil }

    // MARK: - Driving

    func load(_ url: URL) async {
        let wv = view()
        loading = true
        wv.load(URLRequest(url: url))
        await settle()
    }

    func goBack() async { view().goBack(); await settle() }
    func goForward() async { view().goForward(); await settle() }
    func reload() async { view().reload(); await settle() }

    /// Wait for the current navigation to finish, then give the page a beat
    /// to render. Capped: a page that never stops loading (a dev server
    /// holding a websocket open, an endless spinner) must not hang the
    /// agent's tool call until the relay times out — better to hand back
    /// whatever is on screen and let it look again.
    func settle(timeout: Double = 12) async {
        if loading {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    await withCheckedContinuation { cont in
                        self.loadWaiters.append(cont)
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                }
                await group.next()
                group.cancelAll()
            }
        }
        // Client-rendered pages paint after load fires; without this an
        // agent screenshots a blank shell and concludes the page is broken.
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    private func finishLoading() {
        loading = false
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    // MARK: - Reading

    func title() async -> String {
        (try? await js("document.title")) as? String ?? ""
    }

    /// What a person would read on the page. innerText, not innerHTML: an
    /// agent deciding "am I on the login page or the dashboard" needs the
    /// words, and markup is mostly tokens spent on nothing.
    func visibleText(selector: String?, limit: Int) async throws -> String {
        let target = selector.map { "document.querySelector(\(jsString($0)))" } ?? "document.body"
        let script = """
        (() => {
          const el = \(target);
          if (!el) return null;
          return (el.innerText || '').replace(/\\n{3,}/g, '\\n\\n').trim();
        })()
        """
        let result = try await js(script)
        if result is NSNull || result == nil {
            if let selector { throw Failure.notFound(selector) }
            return ""
        }
        let text = result as? String ?? ""
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n[… truncated at \(limit) characters]"
    }

    /// PNG of the visible page. Scaled down: a retina snapshot of a wide
    /// panel is several megabytes, and every one of those bytes crosses the
    /// relay socket and lands in the agent's context.
    func snapshot(maxWidth: CGFloat = 1200) async throws -> Data {
        guard let wv = webView, wv.url != nil else { throw Failure.noPage }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            wv.takeSnapshot(with: config) { image, error in
                if let image { cont.resume(returning: image) }
                else { cont.resume(throwing: Failure.snapshot(error?.localizedDescription ?? "no image")) }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { throw Failure.snapshot("could not read the captured image") }

        let width = CGFloat(rep.pixelsWide)
        let scale = width > maxWidth ? maxWidth / width : 1
        let outW = Int(width * scale)
        let outH = Int(CGFloat(rep.pixelsHigh) * scale)
        guard scale < 1 else {
            return rep.representation(using: .png, properties: [:]) ?? Data()
        }
        guard let scaled = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: outW, pixelsHigh: outH,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0)
        else { throw Failure.snapshot("could not allocate the scaled image") }
        scaled.size = NSSize(width: outW, height: outH)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        image.draw(in: NSRect(x: 0, y: 0, width: outW, height: outH))
        NSGraphicsContext.restoreGraphicsState()
        return scaled.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: - Acting

    /// Click, and say so when the browser silently refused. HTML5
    /// constraint validation swallows a click on a submit button whose form
    /// has an invalid field — no error, no event, nothing happens. The
    /// agent gets "ok", sees an unchanged page, and concludes the app is
    /// broken. Naming the offending field turns that into a fixable fact.
    func click(selector: String) async throws {
        let script = """
        (() => {
          const el = document.querySelector(\(jsString(selector)));
          if (!el) return 'missing';
          el.scrollIntoView({block: 'center'});
          const form = el.form;
          const submits = el.type === 'submit' || el.type === 'image';
          if (form && submits && typeof form.checkValidity === 'function'
              && !form.checkValidity()) {
            const bad = Array.from(form.elements)
              .filter(f => typeof f.checkValidity === 'function' && !f.checkValidity())
              .map(f => (f.name || f.id || f.type) + ': ' + (f.validationMessage || 'invalid'));
            return 'invalid|' + bad.join('; ');
          }
          el.click();
          return 'ok';
        })()
        """
        let outcome = (try await js(script)) as? String ?? ""
        if outcome == "missing" { throw Failure.notFound(selector) }
        if outcome.hasPrefix("invalid|") {
            throw Failure.blocked(String(outcome.dropFirst("invalid|".count)))
        }
        await settle(timeout: 8)
    }

    /// Set a field's value the way a person would. Assigning `.value`
    /// directly is invisible to React and Vue — they track the native
    /// setter and the framework's state never updates, so the form submits
    /// empty. Going through the prototype setter and firing input/change
    /// is what makes it stick.
    func fill(selector: String, value: String) async throws {
        let script = """
        (() => {
          const el = document.querySelector(\(jsString(selector)));
          if (!el) return 'missing';
          el.focus();
          const proto = el instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
          if (setter) { setter.call(el, \(jsString(value))); }
          else { el.value = \(jsString(value)); }
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          return 'ok';
        })()
        """
        if (try await js(script)) as? String == "missing" { throw Failure.notFound(selector) }
    }

    func press(key: String, selector: String?) async throws {
        let target = selector.map { "document.querySelector(\(jsString($0)))" }
            ?? "(document.activeElement || document.body)"
        let script = """
        (() => {
          const el = \(target);
          if (!el) return 'missing';
          for (const type of ['keydown', 'keypress', 'keyup']) {
            el.dispatchEvent(new KeyboardEvent(type, {
              key: \(jsString(key)), bubbles: true, cancelable: true
            }));
          }
          if (\(jsString(key)) === 'Enter' && el.form) {
            el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
          }
          return 'ok';
        })()
        """
        if (try await js(script)) as? String == "missing" {
            throw Failure.notFound(selector ?? "the focused element")
        }
        await settle(timeout: 8)
    }

    func scroll(to target: String) async throws {
        let script: String
        switch target.lowercased() {
        case "top":    script = "window.scrollTo(0, 0); 'ok'"
        case "bottom": script = "window.scrollTo(0, document.body.scrollHeight); 'ok'"
        default:
            let amount = Int(target) ?? 600
            script = "window.scrollBy(0, \(amount)); 'ok'"
        }
        _ = try await js(script)
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - JS plumbing

    @discardableResult
    private func js(_ script: String) async throws -> Any? {
        guard let wv = webView, wv.url != nil else { throw Failure.noPage }
        return try await withCheckedThrowingContinuation { cont in
            wv.evaluateJavaScript(script) { value, error in
                if let error {
                    cont.resume(throwing: Failure.js(error.localizedDescription))
                } else {
                    cont.resume(returning: value)
                }
            }
        }
    }

    /// JSON-encode a Swift string into a JS literal. Hand-rolled quoting
    /// breaks on the first apostrophe in a password or a selector, and the
    /// failure looks like "the page rejected that" rather than a quoting bug.
    private func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: []))
            ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

extension PreviewBrowser: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.loading = true }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.currentURL = webView.url
            self.finishLoading()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoading() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoading() }
    }
}
