import AppKit
import WebKit
import ApplicationServices
import ClipRavenSync

// MARK: - OnboardingWindowController

/// First-launch guided setup.
///
/// Critical invariants:
/// - Window **cannot** be dismissed until user reaches the final page and taps Start.
///   The close button is removed and `windowShouldClose` returns false.
/// - Accessibility permission is requested mid-flow because the paste feature is
///   non-functional without it.
/// - Crash reporting (Sentry) is strictly opt-in — toggle defaults to OFF and sits
///   on the final page above the Start button.
final class OnboardingWindowController: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private override init() {}

    private var window: NSWindow?
    private var webView: WKWebView?
    private var axPollTimer: Timer?

    func show() {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            if #available(macOS 14.0, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
            return
        }

        let hotkey = HotKeyStore.shared.displayString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let lang = Self.resolveOnboardingLanguage(from: Locale.preferredLanguages.first)

        let config = WKWebViewConfiguration()
        let script = WKUserScript(
            source: "window.CR_HOTKEY='\(hotkey)';window.CR_LANG='\(lang)';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(script)
        config.userContentController.add(self, name: "onboarding")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv

        // Intentionally omit `.closable` — the onboarding flow is non-skippable.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = "ClipRaven"
        win.contentView = wv
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.059, alpha: 1)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        self.window = win

        wv.loadHTMLString(Self.onboardingHTML, baseURL: nil)
    }

    // MARK: NSWindowDelegate — block dismissal until flow completes
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    /// Map `Locale.preferredLanguages.first` (a BCP-47 tag like `ko-KR`,
    /// `zh-Hant-TW`, `pt-BR`) to one of the onboarding bundle's keys.
    /// Falls back to `en` for any locale we don't ship a translation for.
    ///
    /// Kept pure + internal so tests can pin the mapping without spinning
    /// up the whole onboarding flow.
    static func resolveOnboardingLanguage(from tag: String?) -> String {
        guard let tag = tag?.lowercased() else { return "en" }

        // Chinese needs special handling — script-variant vs. region tags
        // both appear in the wild (zh-Hans-CN vs. zh-CN, zh-Hant-TW vs.
        // zh-TW). Match on whichever appears first.
        if tag.hasPrefix("zh") {
            if tag.contains("hant") || tag.contains("-tw") || tag.contains("-hk") || tag.contains("-mo") {
                return "zh-Hant"
            }
            return "zh-Hans"
        }

        // Portuguese: we only ship pt-BR for now. pt-PT speakers fall
        // back to English until we add a separate bundle.
        if tag.hasPrefix("pt") {
            return tag.contains("-br") ? "pt-BR" : "en"
        }

        for prefix in ["ko", "ja", "es", "fr", "de", "it", "en"] {
            if tag.hasPrefix(prefix) { return prefix }
        }
        return "en"
    }

    // MARK: WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "onboarding", let body = message.body as? String else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if body.hasPrefix("selective:") {
                UserDefaults.standard.set(body == "selective:on", forKey: "selectiveMode")
                NotificationCenter.default.post(name: .clipRavenSelectiveModeChanged, object: nil)

            } else if body.hasPrefix("crashReports:") {
                UserDefaults.standard.set(body == "crashReports:on", forKey: "crashReportsEnabled")

            } else if body.hasPrefix("launchAtLogin:") {
                // Stored preference only — actual SMAppService hookup lives in Settings.
                UserDefaults.standard.set(body == "launchAtLogin:on", forKey: "launchAtLoginPending")

            } else if body == "accessibility:check" {
                self.reportAccessibilityStatus()

            } else if body == "accessibility:open" {
                // Prompt + deep-link to Accessibility pane.
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
                self.startAccessibilityPolling()

            } else if body == "accessibility:poll:start" {
                self.startAccessibilityPolling()

            } else if body == "accessibility:poll:stop" {
                self.stopAccessibilityPolling()

            } else if body == "intelligence:open" {
                // macOS 26 System Settings pane for Apple Intelligence & Siri.
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.intelligence") {
                    NSWorkspace.shared.open(url)
                }

            } else if body == "complete" {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                self.cleanup()
            }
        }
    }

    // MARK: Accessibility polling

    private func startAccessibilityPolling() {
        stopAccessibilityPolling()
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reportAccessibilityStatus()
        }
        reportAccessibilityStatus()
    }

    private func stopAccessibilityPolling() {
        axPollTimer?.invalidate()
        axPollTimer = nil
    }

    private func reportAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        let js = "window.__axStatus && window.__axStatus(\(trusted ? "true" : "false"));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func cleanup() {
        stopAccessibilityPolling()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "onboarding")
        webView = nil
        window?.delegate = nil
        // `isReleasedWhenClosed == false` + explicit close() so window de-allocates cleanly.
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - Inline Onboarding HTML

extension OnboardingWindowController {
    static let onboardingHTML: String = #"""
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<style>
*{margin:0;padding:0;box-sizing:border-box;}
body{
  font-family:-apple-system,'Helvetica Neue',sans-serif;
  background:#0C0C0F;color:#FFF;overflow:hidden;
  width:100vw;height:100vh;user-select:none;-webkit-user-select:none;
}
.slider{position:relative;width:100%;height:calc(100vh - 72px);overflow:hidden;}
.page{
  position:absolute;top:0;left:0;width:100%;height:100%;
  opacity:0;transform:translateX(80px);
  transition:opacity .45s ease,transform .45s ease;
  pointer-events:none;display:flex;align-items:center;justify-content:center;
}
.page.active{opacity:1;transform:translateX(0);pointer-events:auto;}
.page-content{text-align:center;padding:0 80px;max-width:900px;width:100%;position:relative;}
h2{font-size:28px;font-weight:700;margin-bottom:10px;letter-spacing:-.3px;}
.page-desc{font-size:15px;color:#8E8E93;line-height:1.7;max-width:480px;margin:0 auto;white-space:pre-line;}

/* Page 1 */
.welcome-page{overflow:visible;}
.particles{position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:0;}
.particle{position:absolute;font-size:20px;opacity:0;animation:particleFloat 8s ease-in-out infinite;filter:blur(.5px);}
.welcome-icon-wrap{position:relative;width:140px;height:140px;margin:0 auto 28px;z-index:2;}
.welcome-icon-svg{
  width:140px;height:140px;border-radius:28px;
  background:linear-gradient(135deg,#1A1A25 0%,#0D0D15 100%);
  border:1px solid rgba(255,255,255,.08);
  display:flex;align-items:center;justify-content:center;
  position:relative;z-index:2;animation:iconAppear .8s ease-out both;margin:0 auto;
}
.welcome-glow{
  position:absolute;top:50%;left:50%;width:220px;height:220px;
  transform:translate(-50%,-50%);border-radius:50%;
  background:radial-gradient(circle,rgba(0,200,180,.18) 0%,transparent 70%);
  animation:glowPulse 3s ease-in-out infinite;z-index:1;
}
.welcome-title{font-size:40px;font-weight:800;letter-spacing:-.5px;margin-bottom:10px;animation:fadeSlideUp .6s .3s ease-out both;position:relative;z-index:2;}
.welcome-subtitle{font-size:17px;color:#8E8E93;animation:fadeSlideUp .6s .5s ease-out both;position:relative;z-index:2;}

/* Page 2 */
.hotkey-page h2{margin-bottom:6px;}
.hotkey-page .page-desc{margin-bottom:20px;}
.keyboard-demo{display:flex;align-items:center;justify-content:center;gap:8px;margin-bottom:24px;}
.kb-key{
  display:inline-block;padding:10px 22px;border-radius:10px;
  background:linear-gradient(180deg,#2A2A30 0%,#1A1A20 100%);
  border:1px solid rgba(255,255,255,.1);border-bottom:3px solid rgba(0,0,0,.4);
  font-size:18px;font-weight:700;color:#CCC;min-width:48px;text-align:center;
  transition:transform .1s,border-bottom-width .1s,background .1s;opacity:0;
}
.kb-key.pressed{
  transform:translateY(2px);border-bottom-width:1px;
  background:linear-gradient(180deg,#1E3A3A 0%,#0D2A2A 100%);
  color:#4DD8C0;box-shadow:0 0 16px rgba(0,180,160,.3);
}
.kb-plus{font-size:20px;color:#555;opacity:0;}
.page.active .kb-key,.page.active .kb-plus{animation:fadeSlideUp .4s ease-out both;}
.page.active .kb-key:nth-child(1){animation-delay:.1s;}
.page.active .kb-plus:nth-child(2){animation-delay:.15s;}
.page.active .kb-key:nth-child(3){animation-delay:.2s;}
.page.active .kb-plus:nth-child(4){animation-delay:.25s;}
.page.active .kb-key:nth-child(5){animation-delay:.3s;}
.strip-mock{
  display:flex;gap:8px;justify-content:center;align-items:center;
  padding:16px 24px;background:rgba(255,255,255,.03);
  border-radius:16px;border:1px solid rgba(255,255,255,.06);
  max-width:560px;margin:0 auto;opacity:0;transform:translateY(30px);
}
.page.active .strip-mock{animation:stripSlideUp .7s .8s ease-out both;}
.strip-card-mock{
  width:80px;height:64px;border-radius:10px;
  background:#1A1A22;border:1px solid rgba(255,255,255,.06);
  display:flex;flex-direction:column;gap:5px;padding:8px;flex-shrink:0;
}
.strip-card-mock.hi{border-color:#4DD8C0;box-shadow:0 0 12px rgba(77,216,192,.2);}
.sl{height:4px;border-radius:2px;background:rgba(255,255,255,.1);}
.sl.s{width:50%;}.sl.m{width:75%;}.sl.l{width:92%;}

/* Page 3 */
.selection-page h2{margin-top:20px;}
.selection-flow{display:flex;align-items:center;justify-content:center;gap:24px;margin-bottom:8px;}
.sel-card-wrap{position:relative;flex-shrink:0;}
.sel-card-mock{
  width:120px;height:88px;border-radius:12px;
  background:#1A1A22;border:1px solid rgba(255,255,255,.06);
  box-shadow:0 12px 48px rgba(0,0,0,.6);overflow:hidden;
  display:flex;flex-direction:column;gap:5px;padding:10px;
}
.sel-ring{position:absolute;inset:-4px;border-radius:16px;border:3px solid rgba(0,180,160,.5);opacity:0;pointer-events:none;}
.sel-cursor{
  position:absolute;bottom:20%;right:5%;width:24px;height:24px;
  background:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='white'%3E%3Cpath d='M7 2l12 11.2-5.8.5 3.3 7.3-2.2 1-3.2-7.4L7 18.5V2z'/%3E%3C/svg%3E") no-repeat center/contain;
  opacity:0;filter:drop-shadow(0 2px 6px rgba(0,0,0,.6));z-index:10;
}
.sel-arrow{opacity:0;flex-shrink:0;}
.sel-editor{width:180px;border-radius:12px;overflow:hidden;background:#1A1A20;border:1px solid rgba(255,255,255,.06);box-shadow:0 8px 32px rgba(0,0,0,.4);opacity:0;flex-shrink:0;}
.sel-editor-bar{display:flex;align-items:center;gap:6px;padding:8px 12px;background:rgba(255,255,255,.03);border-bottom:1px solid rgba(255,255,255,.04);}
.sel-dot{width:10px;height:10px;border-radius:50%;}
.sel-dot.red{background:#FF5F57;}.sel-dot.yellow{background:#FEBC2E;}.sel-dot.green{background:#28C840;}
.sel-editor-title{font-size:11px;color:#666;margin-left:8px;}
.sel-editor-body{padding:12px;min-height:60px;font-family:'SF Mono','Menlo',monospace;font-size:12px;color:#4DD8C0;}
.sel-editor-cursor{display:inline-block;width:2px;height:14px;background:#4DD8C0;vertical-align:middle;animation:blink 1s step-end infinite;}
.sel-pasted-badge{display:inline-block;background:#30D158;color:#FFF;font-size:13px;font-weight:700;padding:6px 20px;border-radius:20px;opacity:0;transform:scale(.7) translateY(10px);margin-bottom:8px;}
.sel-anim-step1 .sel-cursor{animation:cursorEnter .6s ease-out both;}
.sel-anim-step2 .sel-ring{animation:ringPulse .5s ease-out both;}
.sel-anim-step2 .sel-cursor{opacity:1;animation:cursorPress .3s ease both;}
.sel-anim-step3 .sel-arrow{animation:arrowShoot .5s ease-out both;}
.sel-anim-step4 .sel-editor{animation:fadeSlideUp .4s ease-out both;}
.sel-anim-step5 .sel-pasted-badge{animation:badgePop .5s ease-out both;}

/* Page 4 */
.selective-page h2{margin-bottom:6px;}
.selective-page .page-desc{margin-bottom:24px;}
.svm-demo{display:flex;flex-direction:column;align-items:center;gap:6px;margin-bottom:28px;}
.svm-keys-wrap{display:flex;align-items:center;gap:6px;}
.svm-key{
  display:inline-block;padding:8px 18px;border-radius:8px;
  background:linear-gradient(180deg,#2A2A30 0%,#1A1A20 100%);
  border:1px solid rgba(255,255,255,.1);border-bottom:3px solid rgba(0,0,0,.4);
  font-size:15px;font-weight:700;color:#888;min-width:40px;text-align:center;
  transition:transform .1s,color .15s,border-bottom-width .1s,box-shadow .2s;
}
.svm-plus{font-size:18px;color:#444;}
.svm-x2{font-size:22px;font-weight:800;color:#FF9500;opacity:0;transform:scale(.5);}
.svm-arrow-down{opacity:0;}
.svm-card-appear{position:relative;opacity:0;transform:scale(.7) translateY(-10px);}
.svm-card-inner{width:100px;height:70px;background:#1A1A22;border-radius:10px;border:1px solid rgba(255,255,255,.06);box-shadow:0 8px 24px rgba(0,0,0,.4);overflow:hidden;position:relative;}
.svm-card-stripe{height:6px;background:linear-gradient(90deg,#4DD8C0,#007AFF);}
.svm-card-line{height:4px;border-radius:2px;background:rgba(255,255,255,.08);margin:8px 10px 0;}
.svm-card-line.l1{width:60%;}.svm-card-line.l2{width:80%;}.svm-card-line.l3{width:40%;}
.svm-card-check{position:absolute;top:-8px;right:-8px;width:24px;height:24px;border-radius:50%;background:#30D158;color:#fff;font-size:14px;font-weight:700;display:flex;align-items:center;justify-content:center;opacity:0;transform:scale(0);}
.svm-step1 .svm-key{color:#FF9500;transform:translateY(1px);border-bottom-width:1px;box-shadow:0 0 12px rgba(255,149,0,.2);}
.svm-step2 .svm-key{color:#FF9500;transform:translateY(1px);border-bottom-width:1px;box-shadow:0 0 12px rgba(255,149,0,.4);}
.svm-step3 .svm-x2{animation:badgePop .4s ease-out both;}
.svm-step4 .svm-arrow-down{animation:fadeSlideUp .3s ease-out both;}
.svm-step5 .svm-card-appear{animation:cardAppear .5s ease-out both;}
.svm-step5 .svm-card-check{animation:checkPop .3s .3s ease-out both;}
.svm-choice{margin-top:0;}
.svm-options{display:flex;gap:12px;max-width:520px;margin:0 auto 12px;}
.svm-option{
  flex:1;display:flex;flex-direction:column;align-items:center;gap:8px;
  padding:18px 16px;border-radius:14px;background:rgba(255,255,255,.03);
  border:2px solid rgba(255,255,255,.06);cursor:pointer;
  transition:border-color .25s,background .25s,box-shadow .25s;
  color:#888;text-align:center;font-family:inherit;
}
.svm-option:hover{background:rgba(255,255,255,.05);border-color:rgba(255,255,255,.12);}
.svm-option.active{border-color:#FF9500;background:rgba(255,149,0,.06);color:#FF9500;box-shadow:0 0 20px rgba(255,149,0,.1);}
.svm-opt-icon{margin-bottom:2px;}
.svm-opt-title{font-size:15px;font-weight:700;display:block;}
.svm-option.active .svm-opt-title{color:#FFF;}
.svm-opt-desc{font-size:11px;line-height:1.5;display:block;white-space:pre-line;color:#666;}
.svm-option.active .svm-opt-desc{color:#999;}
.svm-hint{font-size:11px;color:#555;text-align:center;}

/* Page 5 (Final: feature carousel) */
.final-page{display:flex;flex-direction:column;align-items:center;gap:12px;padding:0 40px;}
.final-page h2{margin-bottom:0;}
.fx-stage{position:relative;width:100%;max-width:560px;height:210px;margin-top:8px;}
.fx-slide{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;gap:10px;
  opacity:0;transform:translateY(8px);transition:opacity .45s ease,transform .45s ease;pointer-events:none;}
.fx-slide.active{opacity:1;transform:translateY(0);pointer-events:auto;}
.fx-visual{width:100%;height:120px;display:flex;align-items:center;justify-content:center;position:relative;}
.fx-title{font-size:15px;font-weight:700;color:#CFE;letter-spacing:.2px;}
.fx-desc{font-size:12px;color:#888;text-align:center;line-height:1.5;max-width:440px;}

/* Slide 0: Search */
.fx-searchbar{width:260px;height:32px;border-radius:9px;background:rgba(255,255,255,.06);
  border:1px solid rgba(255,255,255,.08);display:flex;align-items:center;gap:8px;padding:0 12px;margin-bottom:10px;}
.fx-search-icon{color:#666;font-size:14px;}
.fx-search-input{font-size:13px;color:#DDD;letter-spacing:.3px;font-family:inherit;}
.fx-search-caret{display:inline-block;width:1.5px;height:14px;background:#4DD8C0;animation:blink 1s step-end infinite;margin-left:-2px;}
.fx-card-grid{display:flex;gap:8px;}
.fx-mini-card{width:54px;height:36px;border-radius:7px;background:rgba(255,255,255,.04);
  border:1px solid rgba(255,255,255,.06);padding:6px;display:flex;flex-direction:column;gap:3px;
  transition:opacity .4s ease,transform .4s ease;}
.fx-slide[data-fx="0"].active .fx-mini-card:not([data-keep]){animation:fxFadeOut 2.2s .9s ease-in-out infinite;}

/* Slide 1: Paste As */
.fx-pa-card{width:120px;height:84px;border-radius:10px;background:rgba(255,255,255,.05);
  border:1px solid rgba(255,255,255,.08);padding:10px;display:flex;flex-direction:column;gap:6px;flex-shrink:0;}
.fx-pa-menu{margin-left:14px;width:150px;border-radius:10px;background:rgba(20,20,26,.95);
  border:1px solid rgba(255,255,255,.08);padding:6px;box-shadow:0 12px 32px rgba(0,0,0,.6);
  display:flex;flex-direction:column;gap:2px;opacity:0;transform:translateX(-8px);}
.fx-slide[data-fx="1"].active .fx-pa-menu{animation:fxMenuIn .5s .3s ease-out forwards;}
.fx-pa-item{font-size:12px;color:#BBB;padding:6px 10px;border-radius:5px;}
.fx-pa-item.hl{color:#4DD8C0;background:rgba(77,216,192,.12);animation:fxHlPulse 1.8s 1s ease-in-out infinite;}

/* Slide 2: AI classify */
.fx-ai-card{width:170px;height:100px;border-radius:10px;background:rgba(255,255,255,.05);
  border:1px solid rgba(255,255,255,.08);padding:10px;display:flex;flex-direction:column;gap:4px;position:relative;overflow:hidden;}
.fx-ai-scan{position:absolute;top:0;left:-40%;width:40%;height:100%;
  background:linear-gradient(90deg,transparent,rgba(77,216,192,.25),transparent);}
.fx-slide[data-fx="2"].active .fx-ai-scan{animation:fxScan 2.4s ease-in-out infinite;}
.fx-ai-tag{position:absolute;right:-6px;top:-6px;font-size:10px;font-weight:700;color:#0C0C0F;
  background:linear-gradient(135deg,#FFD66E,#FFA938);padding:3px 8px;border-radius:6px;opacity:0;transform:scale(.6);}
.fx-slide[data-fx="2"].active .fx-ai-tag{animation:fxTagIn .5s 1.3s ease-out forwards;}

/* Carousel dots */
.fx-dots{display:flex;gap:8px;margin-top:4px;}
.fx-dot{width:6px;height:6px;border-radius:50%;background:rgba(255,255,255,.15);transition:background .3s,width .3s,border-radius .3s;cursor:pointer;}
.fx-dot.active{background:#4DD8C0;width:20px;border-radius:3px;}

@keyframes fxFadeOut{0%,40%{opacity:1;transform:scale(1);}60%,100%{opacity:.15;transform:scale(.92);}}
@keyframes fxMenuIn{to{opacity:1;transform:translateX(0);}}
@keyframes fxHlPulse{0%,100%{background:rgba(77,216,192,.12);}50%{background:rgba(77,216,192,.28);}}
@keyframes fxScan{0%{left:-40%;}100%{left:100%;}}
@keyframes fxTagIn{to{opacity:1;transform:scale(1);}}

/* Legacy shortcut-list/feature-tips rules kept below for backward-compat references */
.shortcuts-page h2{margin-bottom:4px;}
.shortcut-list{display:grid;grid-template-columns:1fr 1fr;gap:12px;max-width:560px;margin:24px auto 36px;text-align:left;}
.shortcut-item{
  display:flex;align-items:center;gap:12px;padding:10px 14px;
  border-radius:10px;background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.03);
  opacity:0;cursor:default;transition:background .25s,border-color .25s,box-shadow .25s;
}
.shortcut-item:hover{background:rgba(0,180,160,.06);border-color:rgba(0,180,160,.15);box-shadow:0 0 20px rgba(0,180,160,.08);}
.page.active .shortcut-item{animation:fadeSlideUp .4s ease-out both;}
.page.active .shortcut-item:nth-child(1){animation-delay:.1s;}
.page.active .shortcut-item:nth-child(2){animation-delay:.15s;}
.page.active .shortcut-item:nth-child(3){animation-delay:.2s;}
.page.active .shortcut-item:nth-child(4){animation-delay:.25s;}
.page.active .shortcut-item:nth-child(5){animation-delay:.3s;}
.page.active .shortcut-item:nth-child(6){animation-delay:.35s;}
.page.active .shortcut-item:nth-child(7){animation-delay:.4s;}
.page.active .shortcut-item:nth-child(8){animation-delay:.45s;}
.shortcut-keys{display:flex;gap:3px;flex-shrink:0;}
.key{display:inline-block;padding:4px 10px;border-radius:6px;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.1);border-bottom:2px solid rgba(0,0,0,.3);font-size:11px;font-weight:600;font-family:'SF Mono','Menlo',monospace;color:#BBB;white-space:nowrap;}
.shortcut-label{font-size:13px;color:#888;}
.feature-tips{display:grid;grid-template-columns:1fr 1fr;gap:10px;max-width:560px;margin:0 auto 28px;text-align:left;}
.feature-tip{display:flex;gap:10px;align-items:flex-start;padding:10px 12px;border-radius:10px;background:rgba(77,216,192,.04);border:1px solid rgba(77,216,192,.08);opacity:0;}
.page.active .feature-tip{animation:fadeSlideUp .4s ease-out both;}
.page.active .feature-tip:nth-child(1){animation-delay:.5s;}
.page.active .feature-tip:nth-child(2){animation-delay:.55s;}
.page.active .feature-tip:nth-child(3){animation-delay:.6s;}
.page.active .feature-tip:nth-child(4){animation-delay:.65s;}
.feature-tip-icon{font-size:16px;line-height:1.2;flex-shrink:0;width:24px;text-align:center;}
.feature-tip-body{display:flex;flex-direction:column;gap:2px;min-width:0;}
.feature-tip-title{font-size:12px;font-weight:700;color:#CFE;letter-spacing:.2px;}
.feature-tip-desc{font-size:11px;color:#879;line-height:1.4;}
.start-btn{
  padding:14px 56px;border:none;border-radius:14px;
  background:linear-gradient(135deg,#00B4A0,#007AFF);color:#FFF;
  font-size:17px;font-weight:700;cursor:pointer;font-family:inherit;
  transition:transform .15s,box-shadow .3s;
  animation:btnPulse 2.5s 1s ease-in-out infinite;
}
.start-btn:hover{transform:scale(1.04);box-shadow:0 4px 24px rgba(0,122,255,.3);}
.start-btn:active{transform:scale(.97);}

/* Nav */
.nav-bar{position:fixed;bottom:0;left:0;right:0;height:72px;display:flex;align-items:center;justify-content:center;padding:0 32px;}
.dots{display:flex;gap:10px;}
.dot{width:8px;height:8px;border-radius:50%;background:rgba(255,255,255,.12);transition:background .3s,width .3s,border-radius .3s;cursor:pointer;}
.dot.active{background:#00B4A0;width:24px;border-radius:4px;}
.next-btn{position:absolute;right:32px;padding:10px 28px;border:none;border-radius:10px;background:rgba(0,180,160,.12);color:#4DD8C0;font-size:14px;font-weight:600;cursor:pointer;transition:background .2s,opacity .2s;font-family:inherit;}
.next-btn:hover{background:rgba(0,180,160,.2);}
.next-btn.locked,.next-btn:disabled{opacity:.35;cursor:not-allowed;background:rgba(255,255,255,.05);color:#666;}
.next-btn.locked:hover{background:rgba(255,255,255,.05);}
.next-btn.hidden{display:none;}

/* Keyframes */
@keyframes iconAppear{0%{opacity:0;transform:scale(.5) rotate(-12deg);}60%{transform:scale(1.05) rotate(2deg);}100%{opacity:1;transform:scale(1) rotate(0);}}
@keyframes glowPulse{0%,100%{opacity:.5;transform:translate(-50%,-50%) scale(1);}50%{opacity:1;transform:translate(-50%,-50%) scale(1.15);}}
@keyframes fadeSlideUp{0%{opacity:0;transform:translateY(20px);}100%{opacity:1;transform:translateY(0);}}
@keyframes stripSlideUp{0%{opacity:0;transform:translateY(30px);}100%{opacity:1;transform:translateY(0);}}
@keyframes particleFloat{0%{opacity:0;transform:translateY(20px) scale(.8);}15%{opacity:.5;}50%{opacity:.3;transform:translateY(-30px) scale(1);}85%{opacity:.5;}100%{opacity:0;transform:translateY(20px) scale(.8);}}
@keyframes cursorEnter{0%{opacity:0;transform:translate(40px,-30px);}100%{opacity:1;transform:translate(0,0);}}
@keyframes cursorPress{0%{transform:translate(0,0);}50%{transform:translate(0,4px);}100%{transform:translate(0,0);}}
@keyframes ringPulse{0%{opacity:0;transform:scale(.9);}50%{opacity:1;transform:scale(1.02);}100%{opacity:.7;transform:scale(1);}}
@keyframes arrowShoot{0%{opacity:0;transform:translateX(-16px);}100%{opacity:1;transform:translateX(0);}}
@keyframes badgePop{0%{opacity:0;transform:scale(.5) translateY(10px);}60%{opacity:1;transform:scale(1.1) translateY(0);}100%{opacity:1;transform:scale(1) translateY(0);}}
@keyframes blink{0%,100%{opacity:1;}50%{opacity:0;}}
@keyframes btnPulse{0%,100%{box-shadow:0 0 0 0 rgba(0,180,160,.3);}50%{box-shadow:0 0 0 10px rgba(0,180,160,0);}}
@keyframes cardAppear{0%{opacity:0;transform:scale(.7) translateY(-10px);}60%{opacity:1;transform:scale(1.05) translateY(0);}100%{opacity:1;transform:scale(1) translateY(0);}}
@keyframes checkPop{0%{opacity:0;transform:scale(0);}60%{opacity:1;transform:scale(1.3);}100%{opacity:1;transform:scale(1);}}

/* Page 2 — Menu bar hint */
.menubar-hint{margin:0 auto 28px;width:100%;max-width:640px;position:relative;}
.menubar-strip{display:flex;align-items:center;gap:14px;padding:6px 18px;border-radius:10px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.08);height:28px;box-shadow:0 4px 24px rgba(0,0,0,.3);}
.mb-spacer{flex:1;}
.mb-item{display:inline-flex;align-items:center;justify-content:center;color:rgba(255,255,255,.5);font-size:13px;}
.mb-item.mb-clipraven{padding:2px;border-radius:6px;background:rgba(77,216,192,.15);box-shadow:0 0 12px rgba(77,216,192,.35);animation:mbGlow 2s ease-in-out infinite;}
.mb-clock{font-family:'SF Mono','Menlo',monospace;font-size:12px;color:rgba(255,255,255,.6);}
.mb-arrow{position:absolute;top:40px;left:calc(100% - 76px);opacity:0;animation:arrowDrop .5s .3s ease-out forwards, arrowPulse 2s .8s ease-in-out infinite;}
@keyframes mbGlow{0%,100%{box-shadow:0 0 12px rgba(77,216,192,.35);}50%{box-shadow:0 0 18px rgba(77,216,192,.55);}}
@keyframes arrowDrop{0%{opacity:0;transform:translateY(-10px);}100%{opacity:1;transform:translateY(0);}}
@keyframes arrowPulse{0%,100%{transform:translateY(0);}50%{transform:translateY(-4px);}}

/* Page 3 — Accessibility */
.ax-page{max-width:560px;margin:0 auto;}
.ax-badge{margin:0 auto 18px;width:72px;height:72px;border-radius:22px;background:rgba(77,216,192,.08);display:flex;align-items:center;justify-content:center;border:1px solid rgba(77,216,192,.2);}
.ax-page h2{margin-bottom:8px;}
.ax-card{margin:24px auto 12px;max-width:440px;padding:18px 20px;border-radius:14px;background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.06);display:flex;flex-direction:column;gap:14px;}
.ax-row{display:flex;align-items:center;gap:10px;font-size:13px;color:#CCC;}
.ax-status-dot{display:inline-block;width:10px;height:10px;border-radius:50%;background:#FF6B6B;box-shadow:0 0 10px rgba(255,107,107,.5);transition:background .3s,box-shadow .3s;}
.ax-status-dot.granted{background:#4DD8C0;box-shadow:0 0 10px rgba(77,216,192,.6);}
.ax-status-text{font-weight:600;}
.ax-cta{padding:10px 18px;border:none;border-radius:10px;background:linear-gradient(135deg,#4DD8C0,#007AFF);color:#FFF;font-size:13px;font-weight:700;font-family:inherit;cursor:pointer;transition:transform .12s,box-shadow .25s;}
.ax-cta:hover{transform:translateY(-1px);box-shadow:0 4px 16px rgba(0,122,255,.25);}
.ax-cta:active{transform:translateY(0);}
.ax-cta.granted{background:rgba(77,216,192,.15);color:#4DD8C0;cursor:default;}
.ax-hint{font-size:11px;color:#666;text-align:center;margin-top:8px;}

/* Page 6 — Privacy prefs */
.privacy-prefs{max-width:520px;margin:4px auto 18px;padding:14px 18px;border-radius:12px;background:rgba(255,255,255,.02);border:1px solid rgba(255,255,255,.05);}
.pref-row{display:flex;align-items:center;gap:10px;cursor:pointer;}
.pref-label{flex:1;font-size:13px;color:#CCC;font-weight:600;}
.pref-check{position:absolute;opacity:0;pointer-events:none;}
.pref-track{position:relative;width:36px;height:20px;border-radius:10px;background:rgba(255,255,255,.1);transition:background .2s;flex-shrink:0;}
.pref-thumb{position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;background:#FFF;transition:left .2s;}
.pref-check:checked ~ .pref-track{background:#4DD8C0;}
.pref-check:checked ~ .pref-track .pref-thumb{left:18px;}
.pref-desc{font-size:11px;color:#666;margin-top:8px;line-height:1.5;}
</style>
</head>
<body>

<div class="slider" id="slider">

  <!-- PAGE 1: Welcome -->
  <section class="page active" data-page="0">
    <div class="page-content welcome-page">
      <div class="particles" id="particles1"></div>
      <div class="welcome-icon-wrap">
        <div class="welcome-icon-svg">
          <svg width="72" height="72" viewBox="0 0 24 24" fill="none">
            <rect x="8" y="2" width="8" height="4" rx="1.5" fill="rgba(255,255,255,.65)"/>
            <rect x="5" y="4" width="14" height="17" rx="2.5" stroke="rgba(255,255,255,.5)" stroke-width="1.5" fill="none"/>
            <line x1="8.5" y1="11" x2="15.5" y2="11" stroke="#4DD8C0" stroke-width="1.5" stroke-linecap="round"/>
            <line x1="8.5" y1="14" x2="14" y2="14" stroke="rgba(255,255,255,.3)" stroke-width="1.5" stroke-linecap="round"/>
            <line x1="8.5" y1="17" x2="12" y2="17" stroke="rgba(255,255,255,.18)" stroke-width="1.5" stroke-linecap="round"/>
          </svg>
        </div>
        <div class="welcome-glow"></div>
      </div>
      <h1 class="welcome-title">ClipRaven</h1>
      <p class="welcome-subtitle" id="welcomeSubtitle"></p>
    </div>
  </section>

  <!-- PAGE 2: Menu Bar location + Hotkey -->
  <section class="page" data-page="1">
    <div class="page-content hotkey-page">
      <div class="menubar-hint">
        <div class="menubar-strip">
          <div class="mb-spacer"></div>
          <div class="mb-item mb-clipraven" id="mbClipraven">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <rect x="8" y="2" width="8" height="4" rx="1.5" fill="rgba(255,255,255,.85)"/>
              <rect x="5" y="4" width="14" height="17" rx="2.5" stroke="rgba(255,255,255,.75)" stroke-width="1.6" fill="none"/>
              <line x1="8.5" y1="11" x2="15.5" y2="11" stroke="#4DD8C0" stroke-width="1.6" stroke-linecap="round"/>
              <line x1="8.5" y1="14" x2="14" y2="14" stroke="rgba(255,255,255,.4)" stroke-width="1.6" stroke-linecap="round"/>
            </svg>
          </div>
          <div class="mb-item">􀙘</div>
          <div class="mb-item">􀋦</div>
          <div class="mb-item">􀋧</div>
          <div class="mb-clock">9:41</div>
        </div>
        <div class="mb-arrow">
          <svg width="24" height="28" viewBox="0 0 24 28"><path d="M12 26V4m0 0l-6 6m6-6l6 6" stroke="#4DD8C0" stroke-width="2" fill="none" stroke-linecap="round"/></svg>
        </div>
      </div>
      <div class="keyboard-demo" id="kbDemo"></div>
      <h2 id="hotkeyTitle"></h2>
      <p class="page-desc" id="hotkeyDesc"></p>
      <div class="strip-mock">
        <div class="strip-card-mock"><div class="sl l"></div><div class="sl m"></div><div class="sl s"></div></div>
        <div class="strip-card-mock hi"><div class="sl m"></div><div class="sl l"></div><div class="sl s"></div></div>
        <div class="strip-card-mock"><div class="sl s"></div><div class="sl m"></div><div class="sl l"></div></div>
        <div class="strip-card-mock"><div class="sl l"></div><div class="sl s"></div><div class="sl m"></div></div>
        <div class="strip-card-mock"><div class="sl m"></div><div class="sl s"></div><div class="sl l"></div></div>
      </div>
    </div>
  </section>

  <!-- PAGE 3: Accessibility permission (CRITICAL) -->
  <section class="page" data-page="2">
    <div class="page-content ax-page">
      <div class="ax-badge">
        <svg width="42" height="42" viewBox="0 0 24 24" fill="none">
          <circle cx="12" cy="12" r="10" stroke="#4DD8C0" stroke-width="1.6" fill="rgba(77,216,192,.08)"/>
          <path d="M8 12l3 3 5-6" stroke="#4DD8C0" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
      </div>
      <h2 id="axTitle"></h2>
      <p class="page-desc" id="axDesc"></p>
      <div class="ax-card">
        <div class="ax-row">
          <span class="ax-status-dot" id="axStatusDot"></span>
          <span class="ax-status-text" id="axStatusText"></span>
        </div>
        <button class="ax-cta" id="axOpenBtn"></button>
      </div>
      <p class="ax-hint" id="axHint"></p>
    </div>
  </section>

  <!-- PAGE 4: Selective Mode -->
  <section class="page" data-page="3">
    <div class="page-content selective-page">
      <h2 id="selectiveTitle"></h2>
      <p class="page-desc" id="selectiveDesc"></p>
      <div class="svm-demo">
        <div class="svm-keys-wrap">
          <div class="svm-key">⌘</div>
          <div class="svm-plus">+</div>
          <div class="svm-key">C</div>
        </div>
        <div class="svm-x2" id="svmX2">×2</div>
        <div class="svm-arrow-down">
          <svg width="24" height="40" viewBox="0 0 24 40"><path d="M12 0v32m0 0l-7-7m7 7l7-7" stroke="#FF9500" stroke-width="2" fill="none" stroke-linecap="round"/></svg>
        </div>
        <div class="svm-card-appear">
          <div class="svm-card-inner">
            <div class="svm-card-stripe"></div>
            <div class="svm-card-line l1"></div>
            <div class="svm-card-line l2"></div>
            <div class="svm-card-line l3"></div>
          </div>
          <div class="svm-card-check">✓</div>
        </div>
      </div>
      <div class="svm-choice">
        <div class="svm-options">
          <button class="svm-option active" id="svmOff">
            <div class="svm-opt-icon">
              <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
                <rect x="3" y="3" width="18" height="18" rx="4" stroke="currentColor" stroke-width="1.5"/>
                <path d="M7 12h10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
              </svg>
            </div>
            <span class="svm-opt-title" id="svmOffTitle"></span>
            <span class="svm-opt-desc" id="svmOffDesc"></span>
          </button>
          <button class="svm-option" id="svmOn">
            <div class="svm-opt-icon">
              <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
                <rect x="3" y="3" width="18" height="18" rx="4" stroke="currentColor" stroke-width="1.5"/>
                <path d="M8 12l3 3 5-5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
              </svg>
            </div>
            <span class="svm-opt-title" id="svmOnTitle"></span>
            <span class="svm-opt-desc" id="svmOnDesc"></span>
          </button>
        </div>
        <p class="svm-hint" id="svmHint"></p>
      </div>
    </div>
  </section>

  <!-- PAGE 5: Feature Showcase + Privacy + Start -->
  <section class="page" data-page="4">
    <div class="page-content final-page">
      <h2 id="finalTitle"></h2>
      <div class="fx-stage" id="fxStage">
        <!-- Slide 0: Search -->
        <div class="fx-slide active" data-fx="0">
          <div class="fx-visual">
            <div class="fx-searchbar">
              <span class="fx-search-icon">⌕</span>
              <span class="fx-search-input" id="fxSearchText"></span>
              <span class="fx-search-caret"></span>
            </div>
            <div class="fx-card-grid">
              <div class="fx-mini-card" data-keep="1"><div class="sl l"></div><div class="sl m"></div></div>
              <div class="fx-mini-card"><div class="sl m"></div><div class="sl s"></div></div>
              <div class="fx-mini-card" data-keep="1"><div class="sl l"></div><div class="sl s"></div></div>
              <div class="fx-mini-card"><div class="sl s"></div><div class="sl m"></div></div>
            </div>
          </div>
          <div class="fx-title" id="fx0Title"></div>
          <div class="fx-desc"  id="fx0Desc"></div>
        </div>
        <!-- Slide 1: Paste As… -->
        <div class="fx-slide" data-fx="1">
          <div class="fx-visual">
            <div class="fx-pa-card"><div class="sl l"></div><div class="sl m"></div><div class="sl s"></div></div>
            <div class="fx-pa-menu">
              <div class="fx-pa-item">Plain Text</div>
              <div class="fx-pa-item hl">Markdown</div>
              <div class="fx-pa-item">Rich Text</div>
            </div>
          </div>
          <div class="fx-title" id="fx1Title"></div>
          <div class="fx-desc"  id="fx1Desc"></div>
        </div>
        <!-- Slide 2: AI auto-classify -->
        <div class="fx-slide" data-fx="2">
          <div class="fx-visual">
            <div class="fx-ai-card">
              <div class="fx-ai-scan"></div>
              <div class="sl l"></div><div class="sl m"></div><div class="sl s"></div><div class="sl m"></div>
              <div class="fx-ai-tag">✨ Receipt</div>
            </div>
          </div>
          <div class="fx-title" id="fx2Title"></div>
          <div class="fx-desc"  id="fx2Desc"></div>
        </div>
      </div>
      <div class="fx-dots" id="fxDots">
        <span class="fx-dot active" data-fxi="0"></span>
        <span class="fx-dot" data-fxi="1"></span>
        <span class="fx-dot" data-fxi="2"></span>
      </div>
      <div class="privacy-prefs" id="privacyPrefs">
        <label class="pref-row">
          <span class="pref-label" id="crashLabel"></span>
          <input type="checkbox" id="crashToggle" class="pref-check" />
          <span class="pref-track"><span class="pref-thumb"></span></span>
        </label>
        <p class="pref-desc" id="crashDesc"></p>
      </div>
      <button class="start-btn" id="startBtn"></button>
    </div>
  </section>

</div><!-- /.slider -->

<div class="nav-bar">
  <div class="dots" id="dots">
    <span class="dot active" data-idx="0"></span>
    <span class="dot" data-idx="1"></span>
    <span class="dot" data-idx="2"></span>
    <span class="dot" data-idx="3"></span>
    <span class="dot" data-idx="4"></span>
  </div>
  <button class="next-btn" id="nextBtn"></button>
</div>

<script>
(function(){
'use strict';
var HOTKEY = window.CR_HOTKEY || '\u21e7V';
var LANG   = window.CR_LANG   || 'ko';

var I18N = {
  en:{
    welcome_subtitle:'Your smart clipboard, reimagined.',
    hotkey_title:'Open ClipRaven Instantly',
    hotkey_desc:'Press your hotkey to reveal the clipboard panel.\nClipRaven lives in the background \u2014 this is how you summon it.',
    selection_title:'Click to Paste',
    selection_desc:'Click any card to paste it into the active app.\nNo \u2318V needed \u2014 it just works.',
    selection_pasted:'Pasted!',
    selective_title:'Selective Capture',
    selective_desc:'Choose how clipboard items are saved.\nSelective mode gives you full control over your history.',
    selective_off_title:'Capture All',
    selective_off_desc:'Every copy is saved automatically.',
    selective_on_title:'Selective',
    selective_on_desc:'\u2318C \u00d72 items are saved.\nFull control over your history.',
    selective_hint:'You can change this anytime in Settings.',
    ax_title:'Grant Accessibility Access',
    ax_desc:"ClipRaven needs Accessibility permission to paste clips into the app you're working in (via synthesized \u2318V). Without it, pasting won't work.",
    ax_status_off:'Not granted',
    ax_status_on:'Granted',
    ax_cta_open:'Open System Settings',
    ax_cta_granted:'Verify in System Settings',
    ax_hint:"You can revoke this any time in System Settings \u2192 Privacy \u2192 Accessibility.",
    crash_label:'Send anonymous crash reports',
    crash_desc:'If enabled, technical crash traces are sent to help fix bugs. Clipboard content is never included. You can change this any time in Settings.',
    final_title:'A Few Things You\u2019ll Love',
    fx_search_text:'meeting',
    fx0_title:'Instant Search',
    fx0_desc:'Find any clip in milliseconds \u2014 text, code, even text inside images.',
    fx1_title:'Paste As\u2026',
    fx1_desc:'Right-click any clip to paste as Plain Text, Markdown, or Rich Text.',
    fx2_title:'Apple Intelligence',
    fx2_desc:'On macOS 26, clips are auto-classified (receipts, code, emails\u2026) right on-device.',
    shortcuts_title:'Shortcuts & More',
    shortcuts_start:'Get Started',
    nav_next:'Next',
    shortcuts:[
      {keys:null,      label:'Toggle ClipRaven panel'},
      {keys:['Enter'], label:'Paste selected card'},
      {keys:['Click'], label:'Paste into active app'},
      {keys:['\u2325','1-9'], label:'Quick paste #1-9'},
      {keys:['Space'], label:'Quick Look preview'},
      {keys:['Esc'],   label:'Close panel'},
      {keys:['\u2318','F'],label:'Focus search'},
      {keys:['\u2191\u2193'],  label:'Navigate cards'}
    ],
    tips:[
      {icon:'\u2728', title:'Apple Intelligence', desc:'On macOS 26, clips are auto-classified (receipt, code, email…) and long texts can be summarized on-device.'},
      {icon:'\ud83d\udd0d', title:'OCR for Images', desc:'Text inside screenshots becomes searchable automatically \u2014 including Korean.'},
      {icon:'\u21b7',  title:'Paste As\u2026',        desc:'Right-click any clip to paste as Plain Text, Markdown, or Rich Text.'},
      {icon:'\u2318',  title:'Custom Shortcuts',   desc:'Assign a global hotkey to any clip from Settings \u2192 Shortcuts.'}
    ]
  },
  ko:{
    welcome_subtitle:'\uc2a4\ub9c8\ud2b8 \ud074\ub9bd\ubcf4\ub4dc, \uc0c8\ub86d\uac8c \ub9cc\ub098\ubcf4\uc138\uc694.',
    hotkey_title:'ClipRaven\uc744 \ube60\ub974\uac8c \uc5f4\uae30',
    hotkey_desc:'\ub2e8\ucd95\ud0a4\ub97c \ub204\ub974\uba74 \ud074\ub9bd\ubcf4\ub4dc \ud328\ub110\uc774 \ub098\ud0c0\ub0a9\ub2c8\ub2e4.\nClipRaven\uc740 \ubc31\uadf8\ub77c\uc6b4\ub4dc\uc5d0\uc11c \ub300\uae30 \u2014 \ub2e8\ucd95\ud0a4\ub85c \ubd88\ub7ec\uc624\uc138\uc694.',
    selection_title:'\ud074\ub9ad\uc73c\ub85c \ubd99\uc5ec\ub123\uae30',
    selection_desc:'\uce74\ub4dc\ub97c \ud074\ub9ad\ud558\uba74 \ud65c\uc131 \uc571\uc5d0 \ubc14\ub85c \ubd99\uc5ec\ub123\uc5b4\uc9d1\ub2c8\ub2e4.\n\u2318V \uc5c6\uc774 \u2014 \ubc14\ub85c \ub3d9\uc791\ud569\ub2c8\ub2e4.',
    selection_pasted:'\ubd99\uc5ec\ub123\uae30 \uc644\ub8cc!',
    selective_title:'\uc120\ud0dd \uce90\uce58 \ubaa8\ub4dc',
    selective_desc:'\ud074\ub9bd\ubcf4\ub4dc \ud56d\ubaa9\uc774 \uc800\uc7a5\ub418\ub294 \ubc29\uc2dd\uc744 \uc120\ud0dd\ud558\uc138\uc694.\n\uc120\ud0dd \ubaa8\ub4dc\ub85c \ud788\uc2a4\ud1a0\ub9ac\ub97c \uc9c1\uc811 \uc81c\uc5b4\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4.',
    selective_off_title:'\ubaa8\ub450 \uc800\uc7a5',
    selective_off_desc:'\ubcf5\uc0ac\ud558\uba74 \uc790\ub3d9\uc73c\ub85c \ubaa8\ub450 \uc800\uc7a5\ub429\ub2c8\ub2e4.',
    selective_on_title:'\uc120\ud0dd\uc801 \uc800\uc7a5',
    selective_on_desc:'\u2318C \u00d72\ub85c \uc800\uc7a5\ud55c \ud56d\ubaa9\ub9cc \uae30\ub85d\ub429\ub2c8\ub2e4.\n\ud788\uc2a4\ud1a0\ub9ac\ub97c \uc644\uc804\ud788 \uc81c\uc5b4\ud558\uc138\uc694.',
    selective_hint:'\uc124\uc815\uc5d0\uc11c \uc5b8\uc81c\ub4e0 \ubcc0\uacbd\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4.',
    ax_title:'\uc811\uadfc\uc131 \uad8c\ud55c \ud5c8\uc6a9',
    ax_desc:'ClipRaven\uc774 \uc120\ud0dd\ud55c \ud074\ub9bd\uc744 \ud604\uc7ac \uc0ac\uc6a9 \uc911\uc778 \uc571\uc5d0 \ubc14\ub85c \ubd99\uc5ec\ub123\uc73c\ub824\uba74 \uc811\uadfc\uc131 \uad8c\ud55c(\uc190\uc27d\uc740 \uc0ac\uc6a9)\uc774 \ud544\uc694\ud569\ub2c8\ub2e4. \uac1c\uc778 \uc785\ub825\uc744 \uac10\uc2dc\ud558\uc9c0 \uc54a\uc73c\uba70, \u2318V \uc774\ubca4\ud2b8 \uc804\uc1a1\uc5d0\ub9cc \uc0ac\uc6a9\ud569\ub2c8\ub2e4.',
    ax_status_off:'\uad8c\ud55c \uc5c6\uc74c',
    ax_status_on:'\ud5c8\uc6a9\ub428',
    ax_cta_open:'\uc2dc\uc2a4\ud15c \uc124\uc815 \uc5f4\uae30',
    ax_cta_granted:'\uc2dc\uc2a4\ud15c \uc124\uc815\uc5d0\uc11c \ud655\uc778',
    ax_hint:'\uc2dc\uc2a4\ud15c \uc124\uc815 \u2192 \uac1c\uc778\uc815\ubcf4 \ubcf4\ud638 \ubc0f \ubcf4\uc548 \u2192 \uc811\uadfc\uc131\uc5d0\uc11c \uc5b8\uc81c\ub4e0 \ud574\uc81c\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4.',
    crash_label:'\uc775\uba85 \ud06c\ub798\uc2dc \ub9ac\ud3ec\ud2b8 \uc804\uc1a1',
    crash_desc:'\ud65c\uc131\ud654\ud558\uba74 \uc571 \ube44\uc815\uc0c1 \uc885\ub8cc \uc2dc \uae30\uc220\uc801 \ucd94\uc801 \uc815\ubcf4\ub9cc \uc804\uc1a1\ub418\uc5b4 \ubc84\uadf8 \uc218\uc815\uc5d0 \uc0ac\uc6a9\ub429\ub2c8\ub2e4. \ud074\ub9bd\ubcf4\ub4dc \ub0b4\uc6a9\uc740 \uc808\ub300 \ud3ec\ud568\ub418\uc9c0 \uc54a\uc73c\uba70, \uc124\uc815\uc5d0\uc11c \uc5b8\uc81c\ub4e0 \ubcc0\uacbd\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4.',
    final_title:'\ub9c8\uc9c0\ub9c9\uc73c\ub85c, \uc774\ub7f0 \uae30\ub2a5\ub3c4 \uc788\uc5b4\uc694',
    fx_search_text:'\ud68c\uc758',
    fx0_title:'\uc990\uc2dc \uac80\uc0c9',
    fx0_desc:'\ud14d\uc2a4\ud2b8\u00b7\ucf54\ub4dc\u00b7\uc774\ubbf8\uc9c0 \uc548 \uae00\uc790\uae4c\uc9c0 \u2014 \uba87 \ubc00\ub9ac\ucd08 \ub9cc\uc5d0 \ucc3e\uc544\uc918\uc694.',
    fx1_title:'Paste As\u2026',
    fx1_desc:'\ud074\ub9bd \uc6b0\ud074\ub9ad \u2192 \uc77c\ubc18 \ud14d\uc2a4\ud2b8\u00b7\ub9c8\ud06c\ub2e4\uc6b4\u00b7\uc11c\uc2dd \uc788\ub294 \ud14d\uc2a4\ud2b8\ub85c \ubcc0\ud658\ud574 \ubd99\uc5ec\ub123\uc2b5\ub2c8\ub2e4.',
    fx2_title:'Apple Intelligence',
    fx2_desc:'macOS 26\uc5d0\uc11c \ud074\ub9bd\uc774 \uc790\ub3d9\uc73c\ub85c \ubd84\ub958\ub429\ub2c8\ub2e4 \u2014 \uc601\uc218\uc99d\u00b7\ucf54\ub4dc\u00b7\uba54\uc77c, \ubaa8\ub450 \uc628\ub514\ubc14\uc774\uc2a4\uc5d0\uc11c.',
    shortcuts_title:'\ub2e8\ucd95\ud0a4 & \ub354 \ub9ce\uc740 \uae30\ub2a5',
    shortcuts_start:'\uc2dc\uc791\ud558\uae30',
    nav_next:'\ub2e4\uc74c',
    shortcuts:[
      {keys:null,      label:'ClipRaven \ud328\ub110 \uc5f4\uae30/\ub2eb\uae30'},
      {keys:['Enter'], label:'\uc120\ud0dd\ud55c \uce74\ub4dc \ubd99\uc5ec\ub123\uae30'},
      {keys:['\ud074\ub9ad'],label:'\ud65c\uc131 \uc571\uc5d0 \ubd99\uc5ec\ub123\uae30'},
      {keys:['\u2325','1-9'], label:'\ube60\ub978 \ud398\uc774\uc2a4\ud2b8 #1-9'},
      {keys:['Space'], label:'\ud034\ub85d \ubbf8\ub9ac\ubcf4\uae30'},
      {keys:['Esc'],   label:'\ud328\ub110 \ub2eb\uae30'},
      {keys:['\u2318','F'],label:'\uac80\uc0c9 \ud3ec\ucee4\uc2a4'},
      {keys:['\u2191\u2193'],  label:'\uce74\ub4dc \ud0d0\uc0c9'}
    ],
    tips:[
      {icon:'\u2728', title:'Apple Intelligence', desc:'macOS 26\uc5d0\uc11c \ud074\ub9bd\uc744 \uc790\ub3d9 \ubd84\ub958(\uc601\uc218\uc99d\u00b7\ucf54\ub4dc\u00b7\uba54\uc77c...) \ud558\uace0, \uae34 \ud14d\uc2a4\ud2b8\ub294 \uc628\ub514\ubc14\uc774\uc2a4 AI\ub85c \uc694\uc57d\ud574\uc9d1\ub2c8\ub2e4.'},
      {icon:'\ud83d\udd0d', title:'\uc774\ubbf8\uc9c0 OCR', desc:'\uc2a4\ud06c\ub9b0\uc0f7 \uc548\uc758 \ud14d\uc2a4\ud2b8\uac00 \uc790\ub3d9\uc73c\ub85c \uac80\uc0c9\ub418\uc5b4\uc694. \ud55c\uae00\ub3c4 \uc9c0\uc6d0.'},
      {icon:'\u21b7',  title:'Paste As\u2026', desc:'\ud074\ub9bd \uc6b0\ud074\ub9ad \u2192 \uc77c\ubc18 \ud14d\uc2a4\ud2b8\u00b7\ub9c8\ud06c\ub2e4\uc6b4\u00b7\uc11c\uc2dd \uc788\ub294 \ud14d\uc2a4\ud2b8\ub85c \ubcc0\ud658\ud574\uc11c \ubd99\uc5ec\ub123\uae30.'},
      {icon:'\u2318',  title:'\ud074\ub9bd\ubcc4 \ub2e8\ucd95\ud0a4', desc:'\uc124\uc815 \u2192 \ub2e8\ucd95\ud0a4\uc5d0\uc11c \ud2b9\uc815 \ud074\ub9bd\uc5d0 \uc804\uc6a9 \ud558\ub2e8\ucd95\ud0a4\ub97c \uc9c0\uc815\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4.'}
    ]
  },
  ja:{
    welcome_subtitle:'\u30b9\u30de\u30fc\u30c8\u306a\u30af\u30ea\u30c3\u30d7\u30dc\u30fc\u30c9\u3001\u518d\u767a\u898b\u3002',
    hotkey_title:'ClipRaven\u3092\u7d20\u65e9\u304f\u958b\u304f',
    hotkey_desc:'\u30db\u30c3\u30c8\u30ad\u30fc\u3067\u30af\u30ea\u30c3\u30d7\u30dc\u30fc\u30c9\u30d1\u30cd\u30eb\u304c\u8868\u793a\u3055\u308c\u307e\u3059\u3002\nClipRaven\u306f\u30d0\u30c3\u30af\u30b0\u30e9\u30a6\u30f3\u30c9\u3067\u5f85\u6a5f \u2014 \u30db\u30c3\u30c8\u30ad\u30fc\u3067\u547c\u3073\u51fa\u305b\u307e\u3059\u3002',
    selection_title:'\u30af\u30ea\u30c3\u30af\u3067\u8cbc\u308a\u4ed8\u3051',
    selection_desc:'\u30ab\u30fc\u30c9\u3092\u30af\u30ea\u30c3\u30af\u3059\u308b\u3068\u3001\u30a2\u30af\u30c6\u30a3\u30d6\u306a\u30a2\u30d7\u30ea\u306b\u305d\u306e\u307e\u307e\u8cbc\u308a\u4ed8\u3051\u3089\u308c\u307e\u3059\u3002\n\u2318V\u4e0d\u8981 \u2014 \u3059\u3050\u306b\u4f7f\u3048\u307e\u3059\u3002',
    selection_pasted:'\u8cbc\u308a\u4ed8\u3051\u5b8c\u4e86\uff01',
    selective_title:'\u9078\u629e\u30ad\u30e3\u30d7\u30c1\u30e3',
    selective_desc:'\u30af\u30ea\u30c3\u30d7\u30dc\u30fc\u30c9\u306e\u4fdd\u5b58\u65b9\u6cd5\u3092\u9078\u3073\u307e\u3059\u3002\n\u9078\u629e\u30e2\u30fc\u30c9\u306a\u3089\u5c65\u6b74\u3092\u5b8c\u5168\u306b\u30b3\u30f3\u30c8\u30ed\u30fc\u30eb\u3067\u304d\u307e\u3059\u3002',
    selective_off_title:'\u3059\u3079\u3066\u4fdd\u5b58',
    selective_off_desc:'\u30b3\u30d4\u30fc\u306f\u5168\u3066\u81ea\u52d5\u4fdd\u5b58\u3055\u308c\u307e\u3059\u3002',
    selective_on_title:'\u9078\u629e\u7684',
    selective_on_desc:'\u2318C\u00d72\u3057\u305f\u30a2\u30a4\u30c6\u30e0\u306e\u307f\u4fdd\u5b58\u3055\u308c\u307e\u3059\u3002\n\u5c65\u6b74\u3092\u5b8c\u5168\u306b\u30b3\u30f3\u30c8\u30ed\u30fc\u30eb\u3067\u304d\u307e\u3059\u3002',
    selective_hint:'\u8a2d\u5b9a\u304b\u3089\u3044\u3064\u3067\u3082\u5909\u66f4\u3067\u304d\u307e\u3059\u3002',
    ax_title:'\u30a2\u30af\u30bb\u30b7\u30d3\u30ea\u30c6\u30a3\u6a29\u9650\u3092\u8a31\u53ef',
    ax_desc:'ClipRaven\u304c\u4f5c\u696d\u4e2d\u306e\u30a2\u30d7\u30ea\u306b\u30af\u30ea\u30c3\u30d7\u3092\u8cbc\u308a\u4ed8\u3051\u308b\u306b\u306f\u30a2\u30af\u30bb\u30b7\u30d3\u30ea\u30c6\u30a3\u6a29\u9650\u304c\u5fc5\u8981\u3067\u3059\uff08\u540c\u671f\u7684\u306a\u2318V\u306e\u305f\u3081\uff09\u3002\u8a31\u53ef\u304c\u306a\u3044\u3068\u8cbc\u308a\u4ed8\u3051\u306f\u6a5f\u80fd\u3057\u307e\u305b\u3093\u3002',
    ax_status_off:'\u672a\u8a31\u53ef',
    ax_status_on:'\u8a31\u53ef\u6e08\u307f',
    ax_cta_open:'\u30b7\u30b9\u30c6\u30e0\u8a2d\u5b9a\u3092\u958b\u304f',
    ax_cta_granted:'\u30b7\u30b9\u30c6\u30e0\u8a2d\u5b9a\u3067\u78ba\u8a8d',
    ax_hint:'\u30b7\u30b9\u30c6\u30e0\u8a2d\u5b9a \u2192 \u30d7\u30e9\u30a4\u30d0\u30b7\u30fc\u3068\u30bb\u30ad\u30e5\u30ea\u30c6\u30a3 \u2192 \u30a2\u30af\u30bb\u30b7\u30d3\u30ea\u30c6\u30a3 \u3067\u3044\u3064\u3067\u3082\u5272\u308a\u5f53\u3066\u3092\u89e3\u9664\u3067\u304d\u307e\u3059\u3002',
    crash_label:'\u533f\u540d\u30af\u30e9\u30c3\u30b7\u30e5\u30ec\u30dd\u30fc\u30c8\u3092\u9001\u4fe1',
    crash_desc:'\u6709\u52b9\u306b\u3059\u308b\u3068\u3001\u30d0\u30b0\u4fee\u6b63\u306e\u305f\u3081\u306e\u6280\u8853\u7684\u306a\u30af\u30e9\u30c3\u30b7\u30e5\u30c8\u30ec\u30fc\u30b9\u304c\u9001\u4fe1\u3055\u308c\u307e\u3059\u3002\u30af\u30ea\u30c3\u30d7\u30dc\u30fc\u30c9\u306e\u5185\u5bb9\u306f\u7d76\u5bfe\u306b\u542b\u307e\u308c\u307e\u305b\u3093\u3002\u8a2d\u5b9a\u304b\u3089\u3044\u3064\u3067\u3082\u5909\u66f4\u3067\u304d\u307e\u3059\u3002',
    final_title:'\u304a\u6c17\u306b\u5165\u308a\u306e\u6a5f\u80fd\u305f\u3061',
    fx_search_text:'\u4f1a\u8b70',
    fx0_title:'\u30a4\u30f3\u30b9\u30bf\u30f3\u30c8\u691c\u7d22',
    fx0_desc:'\u30c6\u30ad\u30b9\u30c8\u3001\u30b3\u30fc\u30c9\u3001\u753b\u50cf\u5185\u306e\u6587\u5b57\u307e\u3067 \u2014 \u30df\u30ea\u79d2\u3067\u898b\u3064\u304b\u308a\u307e\u3059\u3002',
    fx1_title:'Paste As\u2026',
    fx1_desc:'\u30af\u30ea\u30c3\u30d7\u3092\u53f3\u30af\u30ea\u30c3\u30af\u3057\u3066\u30d7\u30ec\u30fc\u30f3\u30c6\u30ad\u30b9\u30c8\u3001Markdown\u3001\u30ea\u30c3\u30c1\u30c6\u30ad\u30b9\u30c8\u3068\u3057\u3066\u8cbc\u308a\u4ed8\u3051\u307e\u3059\u3002',
    fx2_title:'Apple Intelligence',
    fx2_desc:'macOS 26\u3067\u306f\u30af\u30ea\u30c3\u30d7\u304c\u81ea\u52d5\u5206\u985e\u3055\u308c\u307e\u3059\uff08\u30ec\u30b7\u30fc\u30c8\u3001\u30b3\u30fc\u30c9\u3001\u30e1\u30fc\u30eb\u2026\uff09\u2014 \u5168\u3066\u30c7\u30d0\u30a4\u30b9\u4e0a\u3067\u3002',
    shortcuts_title:'\u30b7\u30e7\u30fc\u30c8\u30ab\u30c3\u30c8 & \u305d\u306e\u4ed6',
    shortcuts_start:'\u59cb\u3081\u308b',
    nav_next:'\u6b21\u3078',
    shortcuts:[
      {keys:null,      label:'ClipRaven\u30d1\u30cd\u30eb\u3092\u958b\u304f/\u9589\u3058\u308b'},
      {keys:['Enter'], label:'\u9078\u629e\u3057\u305f\u30ab\u30fc\u30c9\u3092\u8cbc\u308a\u4ed8\u3051'},
      {keys:['\u30af\u30ea\u30c3\u30af'], label:'\u30a2\u30af\u30c6\u30a3\u30d6\u30a2\u30d7\u30ea\u306b\u8cbc\u308a\u4ed8\u3051'},
      {keys:['\u2325','1-9'], label:'\u30af\u30a4\u30c3\u30af\u30da\u30fc\u30b9\u30c8 #1-9'},
      {keys:['Space'], label:'\u30af\u30a4\u30c3\u30af\u30eb\u30c3\u30af\u30d7\u30ec\u30d3\u30e5\u30fc'},
      {keys:['Esc'],   label:'\u30d1\u30cd\u30eb\u3092\u9589\u3058\u308b'},
      {keys:['\u2318','F'],label:'\u691c\u7d22\u306b\u30d5\u30a9\u30fc\u30ab\u30b9'},
      {keys:['\u2191\u2193'],  label:'\u30ab\u30fc\u30c9\u3092\u30ca\u30d3\u30b2\u30fc\u30c8'}
    ],
    tips:[
      {icon:'\u2728', title:'Apple Intelligence', desc:'macOS 26\u3067\u306f\u30af\u30ea\u30c3\u30d7\u3092\u81ea\u52d5\u5206\u985e\uff08\u30ec\u30b7\u30fc\u30c8\u3001\u30b3\u30fc\u30c9\u3001\u30e1\u30fc\u30eb\u2026\uff09\u3057\u3001\u9577\u3044\u30c6\u30ad\u30b9\u30c8\u3092\u30c7\u30d0\u30a4\u30b9\u5185AI\u3067\u8981\u7d04\u3067\u304d\u307e\u3059\u3002'},
      {icon:'\ud83d\udd0d', title:'\u753b\u50cfOCR', desc:'\u30b9\u30af\u30ea\u30fc\u30f3\u30b7\u30e7\u30c3\u30c8\u5185\u306e\u30c6\u30ad\u30b9\u30c8\u304c\u81ea\u52d5\u7684\u306b\u691c\u7d22\u53ef\u80fd\u306b\u306a\u308a\u307e\u3059\u3002'},
      {icon:'\u21b7',  title:'Paste As\u2026', desc:'\u30af\u30ea\u30c3\u30d7\u3092\u53f3\u30af\u30ea\u30c3\u30af\u3057\u3066\u30d7\u30ec\u30fc\u30f3\u30c6\u30ad\u30b9\u30c8\u3001Markdown\u3001\u30ea\u30c3\u30c1\u30c6\u30ad\u30b9\u30c8\u3068\u3057\u3066\u8cbc\u308a\u4ed8\u3051\u307e\u3059\u3002'},
      {icon:'\u2318',  title:'\u30ab\u30b9\u30bf\u30e0\u30b7\u30e7\u30fc\u30c8\u30ab\u30c3\u30c8', desc:'\u8a2d\u5b9a \u2192 \u30b7\u30e7\u30fc\u30c8\u30ab\u30c3\u30c8\u3067\u4efb\u610f\u306e\u30af\u30ea\u30c3\u30d7\u306b\u30b0\u30ed\u30fc\u30d0\u30eb\u30db\u30c3\u30c8\u30ad\u30fc\u3092\u5272\u308a\u5f53\u3066\u3089\u308c\u307e\u3059\u3002'}
    ]
  },
  'zh-Hans':{
    welcome_subtitle:'\u91cd\u65b0\u8bbe\u8ba1\u7684\u667a\u80fd\u526a\u8d34\u677f\u3002',
    hotkey_title:'\u7acb\u5373\u6253\u5f00 ClipRaven',
    hotkey_desc:'\u6309\u5feb\u6377\u952e\u5373\u53ef\u663e\u793a\u526a\u8d34\u677f\u9762\u677f\u3002\nClipRaven \u5728\u540e\u53f0\u8fd0\u884c \u2014 \u4f7f\u7528\u5feb\u6377\u952e\u968f\u65f6\u5524\u51fa\u3002',
    selection_title:'\u70b9\u51fb\u7c98\u8d34',
    selection_desc:'\u70b9\u51fb\u5361\u7247\u5373\u53ef\u7c98\u8d34\u5230\u5f53\u524d\u5e94\u7528\u3002\n\u65e0\u9700 \u2318V \u2014 \u7acb\u5373\u751f\u6548\u3002',
    selection_pasted:'\u5df2\u7c98\u8d34\uff01',
    selective_title:'\u9009\u62e9\u6027\u6355\u83b7',
    selective_desc:'\u9009\u62e9\u526a\u8d34\u677f\u9879\u76ee\u7684\u4fdd\u5b58\u65b9\u5f0f\u3002\n\u9009\u62e9\u6027\u6a21\u5f0f\u8ba9\u60a8\u5b8c\u5168\u638c\u63a7\u5386\u53f2\u8bb0\u5f55\u3002',
    selective_off_title:'\u5168\u90e8\u4fdd\u5b58',
    selective_off_desc:'\u6bcf\u6b21\u590d\u5236\u90fd\u4f1a\u81ea\u52a8\u4fdd\u5b58\u3002',
    selective_on_title:'\u9009\u62e9\u6027',
    selective_on_desc:'\u4ec5\u4fdd\u5b58 \u2318C \u00d72 \u7684\u9879\u76ee\u3002\n\u5b8c\u5168\u638c\u63a7\u5386\u53f2\u8bb0\u5f55\u3002',
    selective_hint:'\u53ef\u968f\u65f6\u5728\u8bbe\u7f6e\u4e2d\u66f4\u6539\u3002',
    ax_title:'\u6388\u4e88\u8f85\u52a9\u529f\u80fd\u6743\u9650',
    ax_desc:'ClipRaven \u9700\u8981\u8f85\u52a9\u529f\u80fd\u6743\u9650\u624d\u80fd\u5c06\u526a\u8d34\u5185\u5bb9\u7c98\u8d34\u5230\u60a8\u6b63\u5728\u4f7f\u7528\u7684\u5e94\u7528\u7a0b\u5e8f\uff08\u901a\u8fc7\u6a21\u62df \u2318V \u5b9e\u73b0\uff09\u3002\u6ca1\u6709\u6743\u9650\u65f6\u65e0\u6cd5\u7c98\u8d34\u3002',
    ax_status_off:'\u672a\u6388\u4e88',
    ax_status_on:'\u5df2\u6388\u4e88',
    ax_cta_open:'\u6253\u5f00\u7cfb\u7edf\u8bbe\u7f6e',
    ax_cta_granted:'\u5728\u7cfb\u7edf\u8bbe\u7f6e\u4e2d\u786e\u8ba4',
    ax_hint:'\u53ef\u968f\u65f6\u5728\u7cfb\u7edf\u8bbe\u7f6e \u2192 \u9690\u79c1\u4e0e\u5b89\u5168 \u2192 \u8f85\u52a9\u529f\u80fd \u4e2d\u64a4\u9500\u6388\u6743\u3002',
    crash_label:'\u53d1\u9001\u533f\u540d\u5d29\u6e83\u62a5\u544a',
    crash_desc:'\u542f\u7528\u540e\u4f1a\u53d1\u9001\u6280\u672f\u5d29\u6e83\u8ffd\u8e2a\u4ee5\u5e2e\u52a9\u4fee\u590d\u95ee\u9898\u3002\u526a\u8d34\u677f\u5185\u5bb9\u7edd\u4e0d\u4f1a\u88ab\u5305\u542b\u5728\u5185\u3002\u53ef\u968f\u65f6\u5728\u8bbe\u7f6e\u4e2d\u66f4\u6539\u3002',
    final_title:'\u4f60\u4f1a\u559c\u6b22\u7684\u51e0\u9879\u529f\u80fd',
    fx_search_text:'\u4f1a\u8bae',
    fx0_title:'\u5373\u65f6\u641c\u7d22',
    fx0_desc:'\u6587\u672c\u3001\u4ee3\u7801\u3001\u751a\u81f3\u56fe\u7247\u4e2d\u7684\u6587\u5b57 \u2014 \u6beb\u79d2\u627e\u5230\u3002',
    fx1_title:'Paste As\u2026',
    fx1_desc:'\u53f3\u51fb\u526a\u8d34\u53ef\u9009\u62e9\u4ee5\u7eaf\u6587\u672c\u3001Markdown \u6216\u5bcc\u6587\u672c\u683c\u5f0f\u7c98\u8d34\u3002',
    fx2_title:'Apple Intelligence',
    fx2_desc:'\u5728 macOS 26 \u4e0a\uff0c\u526a\u8d34\u88ab\u81ea\u52a8\u5206\u7c7b\uff08\u6536\u636e\u3001\u4ee3\u7801\u3001\u90ae\u4ef6\u2026\uff09\u2014 \u5168\u90e8\u5728\u672c\u5730\u8fdb\u884c\u3002',
    shortcuts_title:'\u5feb\u6377\u952e\u4e0e\u66f4\u591a',
    shortcuts_start:'\u5f00\u59cb\u4f7f\u7528',
    nav_next:'\u4e0b\u4e00\u6b65',
    shortcuts:[
      {keys:null,      label:'\u5207\u6362 ClipRaven \u9762\u677f'},
      {keys:['Enter'], label:'\u7c98\u8d34\u9009\u4e2d\u7684\u5361\u7247'},
      {keys:['\u70b9\u51fb'], label:'\u7c98\u8d34\u5230\u5f53\u524d\u5e94\u7528'},
      {keys:['\u2325','1-9'], label:'\u5feb\u901f\u7c98\u8d34 #1-9'},
      {keys:['Space'], label:'Quick Look \u9884\u89c8'},
      {keys:['Esc'],   label:'\u5173\u95ed\u9762\u677f'},
      {keys:['\u2318','F'],label:'\u805a\u7126\u641c\u7d22\u6846'},
      {keys:['\u2191\u2193'],  label:'\u6d4f\u89c8\u5361\u7247'}
    ],
    tips:[
      {icon:'\u2728', title:'Apple Intelligence', desc:'macOS 26 \u4e0a\u526a\u8d34\u88ab\u81ea\u52a8\u5206\u7c7b\uff08\u6536\u636e\u3001\u4ee3\u7801\u3001\u90ae\u4ef6\u2026\uff09\uff0c\u957f\u6587\u672c\u53ef\u672c\u5730 AI \u6458\u8981\u3002'},
      {icon:'\ud83d\udd0d', title:'\u56fe\u7247 OCR', desc:'\u622a\u56fe\u5185\u7684\u6587\u5b57\u81ea\u52a8\u53ef\u641c\u7d22\u3002'},
      {icon:'\u21b7',  title:'Paste As\u2026', desc:'\u53f3\u51fb\u526a\u8d34\u53ef\u9009\u62e9\u7eaf\u6587\u672c\u3001Markdown \u6216\u5bcc\u6587\u672c\u683c\u5f0f\u7c98\u8d34\u3002'},
      {icon:'\u2318',  title:'\u81ea\u5b9a\u4e49\u5feb\u6377\u952e', desc:'\u5728\u8bbe\u7f6e \u2192 \u5feb\u6377\u952e \u4e2d\u4e3a\u4efb\u4f55\u526a\u8d34\u6307\u5b9a\u5168\u5c40\u5feb\u6377\u952e\u3002'}
    ]
  },
  'zh-Hant':{
    welcome_subtitle:'\u91cd\u65b0\u8a2d\u8a08\u7684\u667a\u6167\u526a\u8cbc\u677f\u3002',
    hotkey_title:'\u7acb\u5373\u958b\u555f ClipRaven',
    hotkey_desc:'\u6309\u5feb\u901f\u9375\u5373\u53ef\u986f\u793a\u526a\u8cbc\u677f\u9762\u677f\u3002\nClipRaven \u5728\u80cc\u666f\u57f7\u884c \u2014 \u4f7f\u7528\u5feb\u901f\u9375\u96a8\u6642\u547c\u53eb\u3002',
    selection_title:'\u9ede\u64ca\u8cbc\u4e0a',
    selection_desc:'\u9ede\u64ca\u5361\u7247\u5373\u53ef\u8cbc\u4e0a\u7576\u524d\u61c9\u7528\u3002\n\u7121\u9700 \u2318V \u2014 \u7acb\u5373\u751f\u6548\u3002',
    selection_pasted:'\u5df2\u8cbc\u4e0a\uff01',
    selective_title:'\u9078\u64c7\u6027\u64f7\u53d6',
    selective_desc:'\u9078\u64c7\u526a\u8cbc\u677f\u9805\u76ee\u7684\u5132\u5b58\u65b9\u5f0f\u3002\n\u9078\u64c7\u6027\u6a21\u5f0f\u8b93\u60a8\u5b8c\u5168\u638c\u63a7\u6b77\u53f2\u8a18\u9304\u3002',
    selective_off_title:'\u5168\u90e8\u5132\u5b58',
    selective_off_desc:'\u6bcf\u6b21\u8907\u88fd\u90fd\u6703\u81ea\u52d5\u5132\u5b58\u3002',
    selective_on_title:'\u9078\u64c7\u6027',
    selective_on_desc:'\u50c5\u5132\u5b58 \u2318C \u00d72 \u7684\u9805\u76ee\u3002\n\u5b8c\u5168\u638c\u63a7\u6b77\u53f2\u8a18\u9304\u3002',
    selective_hint:'\u53ef\u96a8\u6642\u5728\u8a2d\u5b9a\u4e2d\u66f4\u6539\u3002',
    ax_title:'\u6388\u4e88\u8f14\u52a9\u529f\u80fd\u6b0a\u9650',
    ax_desc:'ClipRaven \u9700\u8981\u8f14\u52a9\u529f\u80fd\u6b0a\u9650\u624d\u80fd\u5c07\u526a\u8cbc\u5167\u5bb9\u8cbc\u4e0a\u60a8\u6b63\u5728\u4f7f\u7528\u7684\u61c9\u7528\u7a0b\u5f0f\uff08\u900f\u904e\u6a21\u64ec \u2318V \u5be6\u73fe\uff09\u3002\u6c92\u6709\u6b0a\u9650\u6642\u7121\u6cd5\u8cbc\u4e0a\u3002',
    ax_status_off:'\u672a\u6388\u4e88',
    ax_status_on:'\u5df2\u6388\u4e88',
    ax_cta_open:'\u958b\u555f\u7cfb\u7d71\u8a2d\u5b9a',
    ax_cta_granted:'\u5728\u7cfb\u7d71\u8a2d\u5b9a\u4e2d\u78ba\u8a8d',
    ax_hint:'\u53ef\u96a8\u6642\u5728\u7cfb\u7d71\u8a2d\u5b9a \u2192 \u96b1\u79c1\u8207\u5b89\u5168\u6027 \u2192 \u8f14\u52a9\u529f\u80fd \u4e2d\u64a4\u92b7\u6388\u6b0a\u3002',
    crash_label:'\u50b3\u9001\u533f\u540d\u5d29\u6f70\u5831\u544a',
    crash_desc:'\u555f\u7528\u5f8c\u6703\u50b3\u9001\u6280\u8853\u5d29\u6f70\u8ffd\u8e64\u4ee5\u5354\u52a9\u4fee\u5fa9\u554f\u984c\u3002\u526a\u8cbc\u677f\u5167\u5bb9\u7d55\u4e0d\u6703\u88ab\u5305\u542b\u5728\u5167\u3002\u53ef\u96a8\u6642\u5728\u8a2d\u5b9a\u4e2d\u66f4\u6539\u3002',
    final_title:'\u60a8\u6703\u559c\u6b61\u7684\u6578\u9805\u529f\u80fd',
    fx_search_text:'\u6703\u8b70',
    fx0_title:'\u5373\u6642\u641c\u5c0b',
    fx0_desc:'\u6587\u5b57\u3001\u7a0b\u5f0f\u78bc\u3001\u751a\u81f3\u5716\u7247\u5167\u7684\u6587\u5b57 \u2014 \u6beb\u79d2\u5c0b\u7372\u3002',
    fx1_title:'Paste As\u2026',
    fx1_desc:'\u53f3\u9375\u526a\u8cbc\u53ef\u9078\u64c7\u4ee5\u7d14\u6587\u5b57\u3001Markdown \u6216\u5bcc\u6587\u5b57\u683c\u5f0f\u8cbc\u4e0a\u3002',
    fx2_title:'Apple Intelligence',
    fx2_desc:'\u5728 macOS 26 \u4e0a\uff0c\u526a\u8cbc\u88ab\u81ea\u52d5\u5206\u985e\uff08\u6536\u64da\u3001\u7a0b\u5f0f\u78bc\u3001\u90f5\u4ef6\u2026\uff09\u2014 \u5168\u90e8\u5728\u88dd\u7f6e\u4e0a\u9032\u884c\u3002',
    shortcuts_title:'\u5feb\u901f\u9375\u8207\u66f4\u591a',
    shortcuts_start:'\u958b\u59cb\u4f7f\u7528',
    nav_next:'\u4e0b\u4e00\u6b65',
    shortcuts:[
      {keys:null,      label:'\u5207\u63db ClipRaven \u9762\u677f'},
      {keys:['Enter'], label:'\u8cbc\u4e0a\u9078\u4e2d\u7684\u5361\u7247'},
      {keys:['\u9ede\u64ca'], label:'\u8cbc\u4e0a\u7576\u524d\u61c9\u7528'},
      {keys:['\u2325','1-9'], label:'\u5feb\u901f\u8cbc\u4e0a #1-9'},
      {keys:['Space'], label:'Quick Look \u9810\u89bd'},
      {keys:['Esc'],   label:'\u95dc\u9589\u9762\u677f'},
      {keys:['\u2318','F'],label:'\u805a\u7126\u641c\u5c0b\u6846'},
      {keys:['\u2191\u2193'],  label:'\u700f\u89bd\u5361\u7247'}
    ],
    tips:[
      {icon:'\u2728', title:'Apple Intelligence', desc:'macOS 26 \u4e0a\u526a\u8cbc\u88ab\u81ea\u52d5\u5206\u985e\uff08\u6536\u64da\u3001\u7a0b\u5f0f\u78bc\u3001\u90f5\u4ef6\u2026\uff09\uff0c\u9577\u6587\u5b57\u53ef\u672c\u6a5f AI \u6458\u8981\u3002'},
      {icon:'\ud83d\udd0d', title:'\u5716\u7247 OCR', desc:'\u622a\u5716\u5167\u7684\u6587\u5b57\u81ea\u52d5\u53ef\u641c\u5c0b\u3002'},
      {icon:'\u21b7',  title:'Paste As\u2026', desc:'\u53f3\u9375\u526a\u8cbc\u53ef\u9078\u64c7\u7d14\u6587\u5b57\u3001Markdown \u6216\u5bcc\u6587\u5b57\u683c\u5f0f\u8cbc\u4e0a\u3002'},
      {icon:'\u2318',  title:'\u81ea\u5b9a\u5feb\u901f\u9375', desc:'\u5728\u8a2d\u5b9a \u2192 \u5feb\u901f\u9375 \u4e2d\u70ba\u4efb\u4f55\u526a\u8cbc\u6307\u5b9a\u5168\u57df\u5feb\u901f\u9375\u3002'}
    ]
  },
  es:{
    welcome_subtitle:'Tu portapapeles inteligente, reinventado.',
    hotkey_title:'Abre ClipRaven al instante',
    hotkey_desc:'Pulsa tu atajo para mostrar el panel del portapapeles.\nClipRaven vive en segundo plano \u2014 as\u00ed lo invocas.',
    selection_title:'Haz clic para pegar',
    selection_desc:'Haz clic en cualquier tarjeta para pegarla en la app activa.\nSin \u2318V \u2014 funciona directamente.',
    selection_pasted:'\u00a1Pegado!',
    selective_title:'Captura selectiva',
    selective_desc:'Elige c\u00f3mo se guardan los elementos del portapapeles.\nEl modo selectivo te da el control total sobre tu historial.',
    selective_off_title:'Guardar todo',
    selective_off_desc:'Cada copia se guarda autom\u00e1ticamente.',
    selective_on_title:'Selectivo',
    selective_on_desc:'Solo se guardan los elementos con \u2318C \u00d72.\nControl total sobre tu historial.',
    selective_hint:'Puedes cambiarlo en cualquier momento en Ajustes.',
    ax_title:'Conceder acceso de accesibilidad',
    ax_desc:'ClipRaven necesita permiso de Accesibilidad para pegar clips en la app en la que est\u00e1s trabajando (mediante \u2318V sint\u00e9tico). Sin ello, pegar no funcionar\u00e1.',
    ax_status_off:'No concedido',
    ax_status_on:'Concedido',
    ax_cta_open:'Abrir Ajustes del Sistema',
    ax_cta_granted:'Verificar en Ajustes',
    ax_hint:'Puedes revocarlo en cualquier momento en Ajustes del Sistema \u2192 Privacidad y seguridad \u2192 Accesibilidad.',
    crash_label:'Enviar informes de fallo an\u00f3nimos',
    crash_desc:'Si est\u00e1 activado, se env\u00edan trazas t\u00e9cnicas de fallo para ayudar a corregir errores. El contenido del portapapeles nunca se incluye. Puedes cambiarlo en Ajustes.',
    final_title:'Algunas cosas que te van a encantar',
    fx_search_text:'reuni\u00f3n',
    fx0_title:'B\u00fasqueda instant\u00e1nea',
    fx0_desc:'Encuentra cualquier clip en milisegundos \u2014 texto, c\u00f3digo, incluso el texto dentro de im\u00e1genes.',
    fx1_title:'Paste As\u2026',
    fx1_desc:'Clic derecho en cualquier clip para pegarlo como texto plano, Markdown o texto con formato.',
    fx2_title:'Apple Intelligence',
    fx2_desc:'En macOS 26, los clips se clasifican autom\u00e1ticamente (recibos, c\u00f3digo, correos\u2026) en el propio dispositivo.',
    shortcuts_title:'Atajos y m\u00e1s',
    shortcuts_start:'Comenzar',
    nav_next:'Siguiente',
    shortcuts:[
      {keys:null,      label:'Abrir/cerrar el panel de ClipRaven'},
      {keys:['Enter'], label:'Pegar la tarjeta seleccionada'},
      {keys:['Clic'],  label:'Pegar en la app activa'},
      {keys:['\u2325','1-9'], label:'Pegado r\u00e1pido #1-9'},
      {keys:['Space'], label:'Previsualizaci\u00f3n Quick Look'},
      {keys:['Esc'],   label:'Cerrar panel'},
      {keys:['\u2318','F'],label:'Enfocar b\u00fasqueda'},
      {keys:['\u2191\u2193'],  label:'Navegar por las tarjetas'}
    ],
    tips:[
      {icon:'\u2728', title:'Apple Intelligence', desc:'En macOS 26, los clips se clasifican autom\u00e1ticamente (recibo, c\u00f3digo, correo\u2026) y los textos largos pueden resumirse en el dispositivo.'},
      {icon:'\ud83d\udd0d', title:'OCR de im\u00e1genes', desc:'El texto dentro de capturas de pantalla se vuelve buscable autom\u00e1ticamente.'},
      {icon:'\u21b7',  title:'Paste As\u2026', desc:'Clic derecho en cualquier clip para pegar como texto plano, Markdown o texto con formato.'},
      {icon:'\u2318',  title:'Atajos personalizados', desc:'Asigna un atajo global a cualquier clip desde Ajustes \u2192 Atajos.'}
    ]
  },
  fr:{
    welcome_subtitle:'Votre presse-papiers intelligent, r\u00e9imagin\u00e9.',
    hotkey_title:'Ouvrir ClipRaven instantan\u00e9ment',
    hotkey_desc:'Appuyez sur votre raccourci pour afficher le panneau du presse-papiers.\nClipRaven vit en arri\u00e8re-plan \u2014 c\u2019est ainsi que vous l\u2019invoquez.',
    selection_title:'Cliquez pour coller',
    selection_desc:'Cliquez sur n\u2019importe quelle carte pour la coller dans l\u2019app active.\nPas de \u2318V \u2014 \u00e7a marche tout seul.',
    selection_pasted:'Coll\u00e9\u00a0!',
    selective_title:'Capture s\u00e9lective',
    selective_desc:'Choisissez comment les \u00e9l\u00e9ments du presse-papiers sont enregistr\u00e9s.\nLe mode s\u00e9lectif vous donne le contr\u00f4le total de votre historique.',
    selective_off_title:'Tout capturer',
    selective_off_desc:'Chaque copie est enregistr\u00e9e automatiquement.',
    selective_on_title:'S\u00e9lectif',
    selective_on_desc:'Seuls les \u00e9l\u00e9ments \u2318C \u00d72 sont enregistr\u00e9s.\nContr\u00f4le total sur votre historique.',
    selective_hint:'Vous pouvez le modifier \u00e0 tout moment dans R\u00e9glages.',
    ax_title:'Autoriser l\u2019acc\u00e8s \u00e0 l\u2019accessibilit\u00e9',
    ax_desc:'ClipRaven a besoin de l\u2019autorisation Accessibilit\u00e9 pour coller les clips dans l\u2019app que vous utilisez (via \u2318V synth\u00e9tis\u00e9). Sans elle, le collage ne fonctionnera pas.',
    ax_status_off:'Non accord\u00e9',
    ax_status_on:'Accord\u00e9',
    ax_cta_open:'Ouvrir R\u00e9glages Syst\u00e8me',
    ax_cta_granted:'V\u00e9rifier dans R\u00e9glages Syst\u00e8me',
    ax_hint:'Vous pouvez r\u00e9voquer \u00e0 tout moment dans R\u00e9glages Syst\u00e8me \u2192 Confidentialit\u00e9 et s\u00e9curit\u00e9 \u2192 Accessibilit\u00e9.',
    crash_label:'Envoyer des rapports de plantage anonymes',
    crash_desc:'Si activ\u00e9, des traces techniques sont envoy\u00e9es pour aider \u00e0 corriger les bugs. Le contenu du presse-papiers n\u2019est jamais inclus. Modifiable dans R\u00e9glages.',
    final_title:'Quelques fonctionnalit\u00e9s que vous allez adorer',
    fx_search_text:'r\u00e9union',
    fx0_title:'Recherche instantan\u00e9e',
    fx0_desc:'Trouvez n\u2019importe quel clip en quelques millisecondes \u2014 texte, code, m\u00eame le texte dans les images.',
    fx1_title:'Paste As\u2026',
    fx1_desc:'Clic droit sur un clip pour coller en texte brut, Markdown ou texte enrichi.',
    fx2_title:'Apple Intelligence',
    fx2_desc:'Sur macOS 26, les clips sont classifi\u00e9s automatiquement (re\u00e7us, code, e-mails\u2026) directement sur l\u2019appareil.',
    shortcuts_title:'Raccourcis et plus',
    shortcuts_start:'Commencer',
    nav_next:'Suivant',
    shortcuts:[
      {keys:null,      label:'Ouvrir/fermer le panneau ClipRaven'},
      {keys:['Enter'], label:'Coller la carte s\u00e9lectionn\u00e9e'},
      {keys:['Clic'],  label:'Coller dans l\u2019app active'},
      {keys:['\u2325','1-9'], label:'Collage rapide #1-9'},
      {keys:['Space'], label:'Aper\u00e7u Quick Look'},
      {keys:['Esc'],   label:'Fermer le panneau'},
      {keys:['\u2318','F'],label:'Focus recherche'},
      {keys:['\u2191\u2193'],  label:'Parcourir les cartes'}
    ],
    tips:[
      {icon:'\u2728', title:'Apple Intelligence', desc:'Sur macOS 26, les clips sont class\u00e9s automatiquement (re\u00e7u, code, e-mail\u2026) et les longs textes peuvent \u00eatre r\u00e9sum\u00e9s sur l\u2019appareil.'},
      {icon:'\ud83d\udd0d', title:'OCR d\u2019images', desc:'Le texte dans les captures d\u2019\u00e9cran devient automatiquement recherchable.'},
      {icon:'\u21b7',  title:'Paste As\u2026', desc:'Clic droit sur un clip pour coller en texte brut, Markdown ou texte enrichi.'},
      {icon:'\u2318',  title:'Raccourcis personnalis\u00e9s', desc:'Attribuez un raccourci global \u00e0 n\u2019importe quel clip depuis R\u00e9glages \u2192 Raccourcis.'}
    ]
  },
  de:{
    welcome_subtitle:'Ihre intelligente Zwischenablage, neu gedacht.',
    hotkey_title:'ClipRaven sofort \u00f6ffnen',
    hotkey_desc:'Dr\u00fccken Sie Ihren Kurzbefehl, um das Zwischenablage-Panel einzublenden.\nClipRaven l\u00e4uft im Hintergrund \u2014 so rufen Sie es auf.',
    selection_title:'Zum Einf\u00fcgen klicken',
    selection_desc:'Klicken Sie auf eine Karte, um sie in die aktive App einzuf\u00fcgen.\nKein \u2318V n\u00f6tig \u2014 es funktioniert einfach.',
    selection_pasted:'Eingef\u00fcgt!',
    selective_title:'Selektive Erfassung',
    selective_desc:'W\u00e4hlen Sie, wie Zwischenablage-Eintr\u00e4ge gespeichert werden.\nDer selektive Modus gibt Ihnen volle Kontrolle \u00fcber Ihren Verlauf.',
    selective_off_title:'Alles erfassen',
    selective_off_desc:'Jede Kopie wird automatisch gespeichert.',
    selective_on_title:'Selektiv',
    selective_on_desc:'Nur Eintr\u00e4ge mit \u2318C \u00d72 werden gespeichert.\nVolle Kontrolle \u00fcber Ihren Verlauf.',
    selective_hint:'Jederzeit in den Einstellungen \u00e4nderbar.',
    ax_title:'Bedienungshilfen-Zugriff erteilen',
    ax_desc:'ClipRaven ben\u00f6tigt die Berechtigung "Bedienungshilfen", um Clips in die App einzuf\u00fcgen, in der Sie arbeiten (durch simuliertes \u2318V). Ohne sie funktioniert das Einf\u00fcgen nicht.',
    ax_status_off:'Nicht erteilt',
    ax_status_on:'Erteilt',
    ax_cta_open:'Systemeinstellungen \u00f6ffnen',
    ax_cta_granted:'In Systemeinstellungen pr\u00fcfen',
    ax_hint:'Sie k\u00f6nnen den Zugriff jederzeit unter Systemeinstellungen \u2192 Datenschutz & Sicherheit \u2192 Bedienungshilfen entziehen.',
    crash_label:'Anonyme Absturzberichte senden',
    crash_desc:'Wenn aktiviert, werden technische Absturz-Traces gesendet, um Fehler zu beheben. Zwischenablage-Inhalte werden niemals eingeschlossen. Jederzeit \u00e4nderbar.',
    final_title:'Ein paar Funktionen, die Sie lieben werden',
    fx_search_text:'Meeting',
    fx0_title:'Sofortsuche',
    fx0_desc:'Finden Sie jeden Clip in Millisekunden \u2014 Text, Code, sogar Text in Bildern.',
    fx1_title:'Paste As\u2026',
    fx1_desc:'Rechtsklick auf einen Clip, um ihn als reinen Text, Markdown oder formatierten Text einzuf\u00fcgen.',
    fx2_title:'Apple Intelligence',
    fx2_desc:'Unter macOS 26 werden Clips automatisch klassifiziert (Belege, Code, E-Mails\u2026) \u2014 komplett auf dem Ger\u00e4t.',
    shortcuts_title:'Tastaturk\u00fcrzel & mehr',
    shortcuts_start:'Los geht\u2019s',
    nav_next:'Weiter',
    shortcuts:[
      {keys:null,      label:'ClipRaven-Panel umschalten'},
      {keys:['Enter'], label:'Ausgew\u00e4hlte Karte einf\u00fcgen'},
      {keys:['Klick'], label:'In aktive App einf\u00fcgen'},
      {keys:['\u2325','1-9'], label:'Schnelles Einf\u00fcgen #1-9'},
      {keys:['Space'], label:'Quick Look Vorschau'},
      {keys:['Esc'],   label:'Panel schlie\u00dfen'},
      {keys:['\u2318','F'],label:'Suche fokussieren'},
      {keys:['\u2191\u2193'],  label:'Karten navigieren'}
    ],
    tips:[
      {icon:'\u2728', title:'Apple Intelligence', desc:'Unter macOS 26 werden Clips automatisch klassifiziert (Beleg, Code, E-Mail\u2026) und lange Texte k\u00f6nnen on-device zusammengefasst werden.'},
      {icon:'\ud83d\udd0d', title:'Bild-OCR', desc:'Text in Screenshots wird automatisch durchsuchbar.'},
      {icon:'\u21b7',  title:'Paste As\u2026', desc:'Rechtsklick auf einen Clip, um ihn als reinen Text, Markdown oder formatierten Text einzuf\u00fcgen.'},
      {icon:'\u2318',  title:'Eigene Kurzbefehle', desc:'Weisen Sie jedem Clip einen globalen Kurzbefehl unter Einstellungen \u2192 Kurzbefehle zu.'}
    ]
  },
  it:{
    welcome_subtitle:'I tuoi appunti intelligenti, reinventati.',
    hotkey_title:'Apri ClipRaven all\u2019istante',
    hotkey_desc:'Premi la tua scorciatoia per mostrare il pannello degli appunti.\nClipRaven vive in background \u2014 cos\u00ec lo richiami.',
    selection_title:'Clicca per incollare',
    selection_desc:'Clicca una scheda per incollarla nell\u2019app attiva.\nNiente \u2318V \u2014 funziona e basta.',
    selection_pasted:'Incollato!',
    selective_title:'Cattura selettiva',
    selective_desc:'Scegli come vengono salvati gli elementi degli appunti.\nLa modalit\u00e0 selettiva ti d\u00e0 il pieno controllo della cronologia.',
    selective_off_title:'Cattura tutto',
    selective_off_desc:'Ogni copia viene salvata automaticamente.',
    selective_on_title:'Selettiva',
    selective_on_desc:'Solo gli elementi con \u2318C \u00d72 vengono salvati.\nControllo totale sulla cronologia.',
    selective_hint:'Puoi cambiarlo in qualsiasi momento nelle Impostazioni.',
    ax_title:'Concedi accesso Accessibilit\u00e0',
    ax_desc:'ClipRaven necessita del permesso di Accessibilit\u00e0 per incollare i clip nell\u2019app in cui stai lavorando (tramite \u2318V sintetizzato). Senza di esso, l\u2019incolla non funzioner\u00e0.',
    ax_status_off:'Non concesso',
    ax_status_on:'Concesso',
    ax_cta_open:'Apri Impostazioni di Sistema',
    ax_cta_granted:'Verifica in Impostazioni di Sistema',
    ax_hint:'Puoi revocarlo in qualsiasi momento in Impostazioni di Sistema \u2192 Privacy e sicurezza \u2192 Accessibilit\u00e0.',
    crash_label:'Invia segnalazioni di arresto anonime',
    crash_desc:'Se attivato, vengono inviate tracce tecniche di arresto per aiutare a correggere i bug. Il contenuto degli appunti non \u00e8 mai incluso. Modificabile dalle Impostazioni.',
    final_title:'Alcune cose che adorerai',
    fx_search_text:'riunione',
    fx0_title:'Ricerca istantanea',
    fx0_desc:'Trova qualsiasi clip in millisecondi \u2014 testo, codice, persino il testo dentro le immagini.',
    fx1_title:'Paste As\u2026',
    fx1_desc:'Clic destro su un clip per incollarlo come testo semplice, Markdown o testo formattato.',
    fx2_title:'Apple Intelligence',
    fx2_desc:'Su macOS 26 i clip vengono classificati automaticamente (ricevute, codice, email\u2026) direttamente sul dispositivo.',
    shortcuts_title:'Scorciatoie e altro',
    shortcuts_start:'Inizia',
    nav_next:'Avanti',
    shortcuts:[
      {keys:null,      label:'Apri/chiudi il pannello ClipRaven'},
      {keys:['Enter'], label:'Incolla la scheda selezionata'},
      {keys:['Clic'],  label:'Incolla nell\u2019app attiva'},
      {keys:['\u2325','1-9'], label:'Incolla rapido #1-9'},
      {keys:['Space'], label:'Anteprima Quick Look'},
      {keys:['Esc'],   label:'Chiudi pannello'},
      {keys:['\u2318','F'],label:'Metti a fuoco la ricerca'},
      {keys:['\u2191\u2193'],  label:'Naviga tra le schede'}
    ],
    tips:[
      {icon:'\u2728', title:'Apple Intelligence', desc:'Su macOS 26 i clip vengono classificati automaticamente (ricevuta, codice, email\u2026) e i testi lunghi possono essere riassunti sul dispositivo.'},
      {icon:'\ud83d\udd0d', title:'OCR immagini', desc:'Il testo dentro gli screenshot diventa automaticamente ricercabile.'},
      {icon:'\u21b7',  title:'Paste As\u2026', desc:'Clic destro su un clip per incollarlo come testo semplice, Markdown o testo formattato.'},
      {icon:'\u2318',  title:'Scorciatoie personalizzate', desc:'Assegna una scorciatoia globale a qualsiasi clip da Impostazioni \u2192 Scorciatoie.'}
    ]
  },
  'pt-BR':{
    welcome_subtitle:'Sua \u00e1rea de transfer\u00eancia inteligente, reimaginada.',
    hotkey_title:'Abra o ClipRaven instantaneamente',
    hotkey_desc:'Pressione seu atalho para mostrar o painel da \u00e1rea de transfer\u00eancia.\nO ClipRaven roda em segundo plano \u2014 \u00e9 assim que voc\u00ea o chama.',
    selection_title:'Clique para colar',
    selection_desc:'Clique em qualquer cart\u00e3o para col\u00e1-lo no app ativo.\nSem \u2318V \u2014 simplesmente funciona.',
    selection_pasted:'Colado!',
    selective_title:'Captura seletiva',
    selective_desc:'Escolha como os itens da \u00e1rea de transfer\u00eancia s\u00e3o salvos.\nO modo seletivo te d\u00e1 controle total do hist\u00f3rico.',
    selective_off_title:'Capturar tudo',
    selective_off_desc:'Cada c\u00f3pia \u00e9 salva automaticamente.',
    selective_on_title:'Seletivo',
    selective_on_desc:'Apenas itens com \u2318C \u00d72 s\u00e3o salvos.\nControle total sobre seu hist\u00f3rico.',
    selective_hint:'Voc\u00ea pode mudar isso a qualquer momento em Ajustes.',
    ax_title:'Conceder acesso de Acessibilidade',
    ax_desc:'O ClipRaven precisa da permiss\u00e3o de Acessibilidade para colar clips no app em que voc\u00ea est\u00e1 trabalhando (via \u2318V sintetizado). Sem ela, colar n\u00e3o funcionar\u00e1.',
    ax_status_off:'N\u00e3o concedido',
    ax_status_on:'Concedido',
    ax_cta_open:'Abrir Ajustes do Sistema',
    ax_cta_granted:'Verificar nos Ajustes do Sistema',
    ax_hint:'Voc\u00ea pode revogar a qualquer momento em Ajustes do Sistema \u2192 Privacidade e Seguran\u00e7a \u2192 Acessibilidade.',
    crash_label:'Enviar relat\u00f3rios de falha an\u00f4nimos',
    crash_desc:'Se ativado, traces t\u00e9cnicos de falha s\u00e3o enviados para ajudar a corrigir bugs. O conte\u00fado da \u00e1rea de transfer\u00eancia nunca \u00e9 inclu\u00eddo. Modific\u00e1vel em Ajustes.',
    final_title:'Algumas coisas que voc\u00ea vai amar',
    fx_search_text:'reuni\u00e3o',
    fx0_title:'Busca instant\u00e2nea',
    fx0_desc:'Encontre qualquer clip em milissegundos \u2014 texto, c\u00f3digo, at\u00e9 texto dentro de imagens.',
    fx1_title:'Paste As\u2026',
    fx1_desc:'Clique com o bot\u00e3o direito em qualquer clip para col\u00e1-lo como texto simples, Markdown ou texto rico.',
    fx2_title:'Apple Intelligence',
    fx2_desc:'No macOS 26, clips s\u00e3o classificados automaticamente (recibos, c\u00f3digo, e-mails\u2026) direto no dispositivo.',
    shortcuts_title:'Atalhos e mais',
    shortcuts_start:'Come\u00e7ar',
    nav_next:'Pr\u00f3ximo',
    shortcuts:[
      {keys:null,      label:'Alternar painel do ClipRaven'},
      {keys:['Enter'], label:'Colar o cart\u00e3o selecionado'},
      {keys:['Clique'],label:'Colar no app ativo'},
      {keys:['\u2325','1-9'], label:'Colagem r\u00e1pida #1-9'},
      {keys:['Space'], label:'Pr\u00e9-visualiza\u00e7\u00e3o Quick Look'},
      {keys:['Esc'],   label:'Fechar painel'},
      {keys:['\u2318','F'],label:'Focar busca'},
      {keys:['\u2191\u2193'],  label:'Navegar pelos cart\u00f5es'}
    ],
    tips:[
      {icon:'\u2728', title:'Apple Intelligence', desc:'No macOS 26, clips s\u00e3o classificados automaticamente (recibo, c\u00f3digo, e-mail\u2026) e textos longos podem ser resumidos no dispositivo.'},
      {icon:'\ud83d\udd0d', title:'OCR de imagens', desc:'O texto dentro de capturas de tela se torna pesquis\u00e1vel automaticamente.'},
      {icon:'\u21b7',  title:'Paste As\u2026', desc:'Clique com o bot\u00e3o direito em qualquer clip para colar como texto simples, Markdown ou texto rico.'},
      {icon:'\u2318',  title:'Atalhos personalizados', desc:'Atribua um atalho global a qualquer clip em Ajustes \u2192 Atalhos.'}
    ]
  }
};

function t(k){return (I18N[LANG]||I18N.en)[k]||I18N.en[k]||'';}

var currentPage=0, TOTAL=5, selectedSelective=false, crashReportsEnabled=false;
var slider=document.getElementById('slider');
var pages=slider.querySelectorAll('.page');
var dots=document.querySelectorAll('.dot');
var nextBtn=document.getElementById('nextBtn');
var startBtn=document.getElementById('startBtn');

function init(){
  applyI18n(); buildKbDemo(); createParticles();
  setupNav(); setupSelMode(); setupAx(); setupPrivacyPrefs(); setupCarousel(); onPageEnter(0);
}

function applyI18n(){
  var s=I18N[LANG]||I18N.en;
  var m={
    welcomeSubtitle:'welcome_subtitle',hotkeyTitle:'hotkey_title',hotkeyDesc:'hotkey_desc',
    axTitle:'ax_title',axDesc:'ax_desc',axHint:'ax_hint',axStatusText:'ax_status_off',
    axOpenBtn:'ax_cta_open',
    selectiveTitle:'selective_title',selectiveDesc:'selective_desc',
    svmOffTitle:'selective_off_title',svmOffDesc:'selective_off_desc',
    svmOnTitle:'selective_on_title',svmOnDesc:'selective_on_desc',
    svmHint:'selective_hint',
    finalTitle:'final_title',fxSearchText:'fx_search_text',
    fx0Title:'fx0_title',fx0Desc:'fx0_desc',
    fx1Title:'fx1_title',fx1Desc:'fx1_desc',
    fx2Title:'fx2_title',fx2Desc:'fx2_desc',
    crashLabel:'crash_label',crashDesc:'crash_desc',
    startBtn:'shortcuts_start',nextBtn:'nav_next'
  };
  Object.keys(m).forEach(function(id){
    var el=document.getElementById(id);
    if(el) el.textContent=s[m[id]]||'';
  });
}

/* Feature carousel on the final page */
var fxIndex=0, fxTimer=null, fxTotal=3;
function setupCarousel(){
  var slides=document.querySelectorAll('.fx-slide');
  var cdots=document.querySelectorAll('.fx-dot');
  cdots.forEach(function(d){
    d.addEventListener('click',function(){
      var i=parseInt(d.getAttribute('data-fxi'),10);
      if(!isNaN(i)) showFxSlide(i);
      restartFxTimer();
    });
  });
  function showFxSlide(i){
    fxIndex=((i%fxTotal)+fxTotal)%fxTotal;
    slides.forEach(function(s,idx){s.classList.toggle('active',idx===fxIndex);});
    cdots.forEach(function(d,idx){d.classList.toggle('active',idx===fxIndex);});
  }
  window.__fxShow=showFxSlide;
}
function startFxRotation(){
  stopFxRotation();
  fxTimer=setInterval(function(){window.__fxShow&&window.__fxShow(fxIndex+1);},3600);
}
function stopFxRotation(){if(fxTimer){clearInterval(fxTimer);fxTimer=null;}}
function restartFxTimer(){if(fxTimer){startFxRotation();}}

/* Accessibility page */
function setupAx(){
  var btn=document.getElementById('axOpenBtn');
  if(btn) btn.addEventListener('click',function(){send('accessibility:open');});
}

// Swift invokes this via evaluateJavaScript when AX state changes.
var axGranted=false;
window.__axStatus=function(granted){
  axGranted=!!granted;
  var s=I18N[LANG]||I18N.en;
  var dot=document.getElementById('axStatusDot');
  var txt=document.getElementById('axStatusText');
  var btn=document.getElementById('axOpenBtn');
  if(dot) dot.classList.toggle('granted',granted);
  if(txt) txt.textContent=granted?s.ax_status_on:s.ax_status_off;
  if(btn){
    btn.classList.toggle('granted',granted);
    btn.textContent=granted?s.ax_cta_granted:s.ax_cta_open;
  }
  // Unblock the Next button only when the AX page is active and permission is granted.
  if(currentPage===2) updateAxGate();
};
function updateAxGate(){
  nextBtn.disabled=!axGranted;
  nextBtn.classList.toggle('locked',!axGranted);
}

/* Privacy preferences (final page) */
function setupPrivacyPrefs(){
  var chk=document.getElementById('crashToggle');
  if(!chk) return;
  chk.checked=false;  // opt-in default
  chk.addEventListener('change',function(){
    crashReportsEnabled=chk.checked;
    send('crashReports:'+(chk.checked?'on':'off'));
  });
}

function parseHotkey(h){
  var parts=[],r=h,mods=['\u2303','\u2325','\u21e7','\u2318'];
  mods.forEach(function(m){if(r.indexOf(m)>=0){parts.push(m);r=r.replace(m,'');}});
  if(r) parts.push(r);
  return parts;
}

function buildKbDemo(){
  var demo=document.getElementById('kbDemo');
  var parts=parseHotkey(HOTKEY);
  demo.innerHTML='';
  parts.forEach(function(k,i){
    if(i>0){var p=document.createElement('div');p.className='kb-plus';p.textContent='+';demo.appendChild(p);}
    var key=document.createElement('div');key.className='kb-key';key.textContent=k;demo.appendChild(key);
  });
}

function createParticles(){
  var c=document.getElementById('particles1');if(!c)return;
  var icons=['\ud83d\udccb','\ud83d\udcc4','\ud83d\udcdd','\ud83d\udd17','\ud83d\udcce','\ud83d\udcbe','\ud83d\uddbc\ufe0f','\ud83d\udcd1','\u2702\ufe0f','\ud83d\udccc'];
  for(var i=0;i<16;i++){
    var el=document.createElement('span');el.className='particle';
    el.textContent=icons[i%icons.length];
    el.style.left=(Math.random()*90+5)+'%';
    el.style.top=(Math.random()*80+10)+'%';
    el.style.fontSize=(14+Math.random()*10)+'px';
    el.style.animationDelay=(Math.random()*6)+'s';
    el.style.animationDuration=(6+Math.random()*4)+'s';
    c.appendChild(el);
  }
}

function setupNav(){
  nextBtn.addEventListener('click',function(){goTo(currentPage+1);});
  startBtn.addEventListener('click',function(){send('selective:'+(selectedSelective?'on':'off'));send('complete');});
  dots.forEach(function(d){
    d.addEventListener('click',function(){var i=parseInt(d.getAttribute('data-idx'),10);if(!isNaN(i))goTo(i);});
  });
  document.addEventListener('keydown',function(e){
    if(e.key==='ArrowRight'||e.key==='Enter'){
      if(currentPage<TOTAL-1)goTo(currentPage+1);
      else{send('selective:'+(selectedSelective?'on':'off'));send('complete');}
    }
    if(e.key==='ArrowLeft'&&currentPage>0)goTo(currentPage-1);
  });
}

function goTo(idx){
  if(idx<0||idx>=TOTAL||idx===currentPage)return;
  // Block any forward navigation past the AX page unless permission is granted.
  if(currentPage===2 && idx>2 && !axGranted)return;
  if(currentPage<2 && idx>2 && !axGranted)return;
  var dir=idx>currentPage?1:-1;
  var op=pages[currentPage],np=pages[idx];
  onPageLeave(currentPage);
  op.classList.remove('active');op.style.transform='translateX('+(-80*dir)+'px)';
  np.style.transition='none';np.style.transform='translateX('+(80*dir)+'px)';np.style.opacity='0';
  void np.offsetHeight;
  np.style.transition='';np.style.transform='';np.style.opacity='';
  np.classList.add('active');
  currentPage=idx;
  dots.forEach(function(d,i){d.classList.toggle('active',i===idx);});
  nextBtn.classList.toggle('hidden',idx===TOTAL-1);
  onPageEnter(idx);
}

function onPageEnter(i){
  if(i===1)startKb();
  if(i===2){send('accessibility:poll:start');updateAxGate();}
  if(i===3)startSvm();
  if(i===4)startFxRotation();
}
function onPageLeave(i){
  if(i===1)stopKb();
  if(i===2){send('accessibility:poll:stop');nextBtn.disabled=false;nextBtn.classList.remove('locked');}
  if(i===3)stopSvm();
  if(i===4)stopFxRotation();
}

/* Keyboard anim */
var kbIv=null,kbTo=null;
function startKb(){
  var keys=document.querySelectorAll('#kbDemo .kb-key'),step=0;
  function press(){
    if(step<keys.length){keys[step].classList.add('pressed');step++;}
    else{
      clearInterval(kbIv);
      kbTo=setTimeout(function(){keys.forEach(function(k){k.classList.remove('pressed');});step=0;kbIv=setInterval(press,250);},1000);
    }
  }
  kbTo=setTimeout(function(){kbIv=setInterval(press,250);},700);
}
function stopKb(){
  clearInterval(kbIv);clearTimeout(kbTo);kbIv=kbTo=null;
  document.querySelectorAll('#kbDemo .kb-key').forEach(function(k){k.classList.remove('pressed');});
}

/* Selective demo anim */
var svmT=[];
function startSvm(){
  stopSvm();
  var c=pages[3].querySelector('.page-content');
  var steps=[{cls:'svm-step1',d:400},{cls:'svm-step2',d:500},{cls:'svm-step3',d:400},{cls:'svm-step4',d:600},{cls:'svm-step5',d:0}];
  var total=600;
  steps.forEach(function(s){var id=setTimeout(function(){c.classList.add(s.cls);},total);svmT.push(id);total+=s.d;});
  svmT.push(setTimeout(function(){stopSvm();svmT.push(setTimeout(startSvm,800));},total+2000));
}
function stopSvm(){
  var c=pages[3]?pages[3].querySelector('.page-content'):null;
  if(c)['svm-step1','svm-step2','svm-step3','svm-step4','svm-step5'].forEach(function(cl){c.classList.remove(cl);});
  svmT.forEach(clearTimeout);svmT=[];
}

function setupSelMode(){
  document.getElementById('svmOn').addEventListener('click',function(){
    selectedSelective=true;
    document.getElementById('svmOn').classList.add('active');
    document.getElementById('svmOff').classList.remove('active');
  });
  document.getElementById('svmOff').addEventListener('click',function(){
    selectedSelective=false;
    document.getElementById('svmOff').classList.add('active');
    document.getElementById('svmOn').classList.remove('active');
  });
}

function send(msg){
  if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.onboarding){
    window.webkit.messageHandlers.onboarding.postMessage(msg);
  }
}

if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',init);}
else{init();}
})();
</script>
</body>
</html>
"""#
}
