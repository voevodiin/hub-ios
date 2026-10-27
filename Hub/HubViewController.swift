import UIKit
import WebKit
import LocalAuthentication
import UserNotifications

/// Оболочка Hub: открывает сайт во весь экран, закрывает вход по Face ID,
/// показывает число просроченных дел на значке и ставит локальные уведомления.
final class HubViewController: UIViewController, WKNavigationDelegate, WKUIDelegate,
                               WKScriptMessageHandler, WKDownloadDelegate {

    private let host = "153-76-162-117.sslip.io"
    private let startURL = URL(string: "https://153-76-162-117.sslip.io/")!

    private var webView: WKWebView!
    private let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let unlockButton = UIButton(type: .system)

    private var locked = true
    private var authBusy = false
    private var lastBackground: Date?
    private var pendingFile: URL?
    private let lockAfter: TimeInterval = 60

    // MARK: - Загрузка

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.10, blue: 0.09, alpha: 1)

        let cfg = WKWebViewConfiguration()
        // Ограничение «только привязанные домены» отключено: при подписи сторонним сертификатом оно мешает загрузке сайта.
        cfg.allowsInlineMediaPlayback = true
        cfg.applicationNameForUserAgent = "HubApp/1.0"
        cfg.userContentController.add(self, name: "hub")

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        pin(webView)

        cover.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cover)
        pin(cover)
        unlockButton.setTitle("Открыть Hub", for: .normal)
        unlockButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        unlockButton.addTarget(self, action: #selector(tryUnlock), for: .touchUpInside)
        unlockButton.translatesAutoresizingMaskIntoConstraints = false
        unlockButton.isHidden = true
        cover.contentView.addSubview(unlockButton)
        NSLayoutConstraint.activate([
            unlockButton.centerXAnchor.constraint(equalTo: cover.contentView.centerXAnchor),
            unlockButton.centerYAnchor.constraint(equalTo: cover.contentView.centerYAnchor)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(willResign), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }

        loadStart()
    }

    private func loadStart() {
        webView.load(URLRequest(url: startURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if locked { authenticate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            if self.locked && !self.authBusy { self.unlockButton.isHidden = false }
        }
    }

    private func pin(_ v: UIView) {
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - Блокировка (Face ID или пароль телефона)

    @objc private func willResign() {
        cover.isHidden = false
    }

    @objc private func didEnterBackground() {
        lastBackground = Date()
    }

    @objc private func didBecomeActive() {
        if let t = lastBackground, Date().timeIntervalSince(t) > lockAfter { locked = true }
        lastBackground = nil
        if locked {
            cover.isHidden = false
            authenticate()
        } else {
            cover.isHidden = true
        }
    }

    private func authenticate() {
        if authBusy { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            unlock()
            return
        }
        authBusy = true
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Откройте Hub") { ok, _ in
            DispatchQueue.main.async {
                self.authBusy = false
                if ok { self.unlock() } else { self.unlockButton.isHidden = false }
            }
        }
    }

    @objc private func tryUnlock() {
        unlockButton.isHidden = true
        authenticate()
    }

    private func unlock() {
        locked = false
        cover.isHidden = true
        unlockButton.isHidden = true
    }

    // MARK: - Сообщения из сайта (значок и уведомления)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any] else { return }
        if let b = d["badge"] as? Int {
            UIApplication.shared.applicationIconBadgeNumber = max(0, b)
        }
        if let notes = d["notes"] as? [[String: Any]] {
            schedule(notes)
        }
    }

    private func schedule(_ notes: [[String: Any]]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date().timeIntervalSince1970
        for n in notes.prefix(60) {
            guard let ts = n["ts"] as? Double, ts > now + 5 else { continue }
            let content = UNMutableNotificationContent()
            content.title = (n["title"] as? String) ?? "Hub"
            content.body = (n["body"] as? String) ?? ""
            content.sound = UNNotificationSound.default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                        from: Date(timeIntervalSince1970: ts))
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = (n["id"] as? String) ?? UUID().uuidString
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger), withCompletionHandler: nil)
        }
    }

    // MARK: - Навигация

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                if url.host != host {
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            } else if scheme == "tel" || scheme == "mailto" || scheme == "sms" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        if let r = navigationResponse.response as? HTTPURLResponse,
           let cd = r.value(forHTTPHeaderField: "Content-Disposition"),
           cd.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    private func handleLoadError(_ error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
        let html = "<meta name='viewport' content='width=device-width,initial-scale=1'>" +
            "<body style='font-family:-apple-system;background:#12201a;color:#e6eee8;padding:48px 24px'>" +
            "<h2>Нет связи</h2><p>Не удаётся открыть Hub. Проверьте интернет.</p>" +
            "<p><a href='https://153-76-162-117.sslip.io/' style='color:#6fcfa0;font-size:22px'>Повторить</a></p>" +
            "<p style='opacity:.6;font-size:13px;word-break:break-all'>Техническая причина: \(e.domain) \(e.code)<br>\(e.localizedDescription)</p></body>"
        webView.loadHTMLString(html, baseURL: startURL)
    }

    // MARK: - Окна и диалоги сайта

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.host == host { webView.load(navigationAction.request) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    // MARK: - Скачивание файлов (копия данных, выгрузка дневника)

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(suggestedFilename)
        pendingFile = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let f = pendingFile else { return }
        let vc = UIActivityViewController(activityItems: [f], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = view
        vc.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(vc, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pendingFile = nil
    }
}
