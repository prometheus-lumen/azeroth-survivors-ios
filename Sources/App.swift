import UIKit
import WebKit

final class GameViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let server = LocalServer()
    private var webView: WKWebView!
    private var validationSnapshotScheduled = false
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.02, green: 0.016, blue: 0.012, alpha: 1)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let restore = "const previous = " + SaveStore.shared.initialJSON() + ";"
        let bridge = #"""
        (() => {
          const send = (kind, value) => window.webkit.messageHandlers.gameBridge.postMessage({kind, value});
          try { for (const [key, value] of Object.entries(previous)) if (!localStorage.getItem(key)) localStorage.setItem(key, value); } catch (_) {}
          const backup = () => {
            try {
              const values = {};
              for (let i=0;i<localStorage.length;i++) {
                const key=localStorage.key(i);
                if (key === 'rogue.characters' || key.startsWith('rogue.characters.backup.')) values[key]=localStorage.getItem(key);
              }
              if (Object.keys(values).length) send('backup',values);
            } catch (_) {}
          };
          setInterval(backup,5000);
          document.addEventListener('visibilitychange',backup);
          window.addEventListener('pagehide',backup);
          let progress;
          Object.defineProperty(window,'__wenilla_progress',{configurable:true,get(){return progress;},set(callback){
            progress=typeof callback==='function' ? function(stage){send('progress',String(stage));return callback.apply(this,arguments);} : callback;
          }});
          let saves;
          Object.defineProperty(window,'__rogue_saves',{configurable:true,get(){return saves;},set(value){
            saves=value;
            if (saves && typeof saves.download==='function') saves.download=function(text){send('export',String(text));};
          }});
          window.addEventListener('error',event=>send('error',String(event.message || 'Resource failed')));
          window.addEventListener('unhandledrejection',event=>send('error',String(event.reason?.message || 'Promise rejected')));
          document.addEventListener('DOMContentLoaded',()=>{
            const box=document.getElementById('gpu-warning');
            if (!box) return;
            let last='';
            const check=()=>{
              const text=box.hidden ? '' : document.getElementById('gpu-warning-text')?.textContent || '';
              if (text && text!==last) {last=text;send('boot-error',text);}
            };
            new MutationObserver(check).observe(box,{attributes:true,childList:true,subtree:true,characterData:true});
            check();
          });
        })();
        """#
        configuration.userContentController.addUserScript(WKUserScript(source: restore + bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(self, name: "gameBridge")
        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false; webView.backgroundColor = view.backgroundColor
        webView.scrollView.bounces = false; webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self; webView.uiDelegate = self
        view.addSubview(webView)
        let gesture = UITapGestureRecognizer(target: self, action: #selector(menu))
        gesture.numberOfTouchesRequired = 3; gesture.numberOfTapsRequired = 2
        gesture.cancelsTouchesInView = false; view.addGestureRecognizer(gesture)
        server.start { [weak self] ready in
            guard let self = self else { return }
            NetworkDiagnostics.shared.record("LOCAL-SERVER ready=\(ready) port=\(self.server.port)")
            if ready { self.webView.load(URLRequest(url: URL(string: self.server.origin + "/")!)) }
            else { self.alert("本地服务未能启动", "请重新打开 App。") }
        }
    }

    @objc private func menu() {
        let menu = UIAlertController(title: "Azeroth Survivors", message: "三指双击打开菜单。角色存档保存在本机，请定期导出。", preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: "导出当前存档", style: .default) { [weak self] _ in
            self?.webView.evaluateJavaScript("window.__rogue_saves?.download(localStorage.getItem('rogue.characters') || localStorage.getItem('rogue.characters.backup.1') || '')")
        })
        menu.addAction(UIAlertAction(title: "重新载入游戏", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            let confirm = UIAlertController(title: "重新载入", message: "当前尚未保存的对局可能结束。", preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: "取消", style: .cancel))
            confirm.addAction(UIAlertAction(title: "重新载入", style: .destructive) { _ in self.webView.reload() })
            self.present(confirm, animated: true)
        })
        menu.addAction(UIAlertAction(title: "打开游戏官网", style: .default) { _ in UIApplication.shared.open(URL(string: ResourceStore.site)!) })
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        menu.popoverPresentationController?.sourceView = view
        menu.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(menu, animated: true)
    }

    private func alert(_ title: String, _ text: String) {
        guard presentedViewController == nil else { return }
        let message = UIAlertController(title: title, message: text, preferredStyle: .alert)
        message.addAction(UIAlertAction(title: "确定", style: .default)); present(message, animated: true)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let entry = message.body as? [String: Any], let kind = entry["kind"] as? String else { return }
        if kind == "backup", let values = entry["value"] as? [String: String] { SaveStore.shared.save(values); return }
        if kind == "export", let text = entry["value"] as? String {
            guard !text.isEmpty, text.utf8.count < 16 * 1024 * 1024 else { alert("没有可导出的存档", "请先创建角色并由游戏保存进度。"); return }
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("AzerothSurvivors.sav")
            do {
                try text.write(to: path, atomically: true, encoding: .utf8)
                let sheet = UIActivityViewController(activityItems: [path], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = view
                sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                present(sheet, animated: true)
            } catch { alert("导出失败", error.localizedDescription) }
            return
        }
        if let text = entry["value"] as? String {
            NetworkDiagnostics.shared.record("\(kind.uppercased()) \(text)")
            if kind == "progress", text == "ready", !validationSnapshotScheduled,
               ProcessInfo.processInfo.environment["AZEROTH_VALIDATE"] == "1" {
                validationSnapshotScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.webView.takeSnapshot(with: nil) { image, error in
                        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ValidationSnapshot.png")
                        if let data = image?.pngData() { try? data.write(to: file, options: .atomic) }
                        NetworkDiagnostics.shared.record("VALIDATION snapshot=\(image != nil) error=\(error?.localizedDescription ?? "none")")
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript("return JSON.stringify({secure:isSecureContext,webgpu:!!navigator.gpu,adapter:!!(await navigator.gpu?.requestAdapter()),online:navigator.onLine});", arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): NetworkDiagnostics.shared.record("WEB-CAPABILITIES \(value)")
            case .failure(let error): NetworkDiagnostics.shared.record("WEB-CAPABILITIES failed \(error.localizedDescription)")
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NetworkDiagnostics.shared.request(webView.url, status: nil, error: error)
        if (error as NSError).code != NSURLErrorCancelled { alert("页面加载失败", error.localizedDescription) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { alert("游戏进程已被系统关闭", "可能是 GPU 或内存压力。重新打开前，请确认重要存档已导出。"); }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.host == "127.0.0.1", !url.path.hasPrefix("/download/") { decisionHandler(.allow); return }
        if ["about", "blob"].contains(url.scheme ?? "") { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if url.host == "127.0.0.1", let upstream = URL(string: ResourceStore.site + url.path) { UIApplication.shared.open(upstream) }
        else if ["https", "http"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if url.host == "127.0.0.1", let original = URL(string: ResourceStore.site + url.path) { UIApplication.shared.open(original) }
            else if url.scheme == "https" { UIApplication.shared.open(url) }
        }
        return nil
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = GameViewController(); window.makeKeyAndVisible(); self.window = window
        return true
    }
    func applicationDidBecomeActive(_ application: UIApplication) { application.isIdleTimerDisabled = true }
    func applicationWillResignActive(_ application: UIApplication) { application.isIdleTimerDisabled = false }
}
