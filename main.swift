import Cocoa
import ServiceManagement

// MARK: - 外部コマンド実行

struct AdminResult {
    let ok: Bool
    let cancelled: Bool   // 認証ダイアログでキャンセルされた
    let message: String
}

/// 管理者権限で `pmset -a disablesleep <0|1>` を実行する。
/// 認証ダイアログは osascript が表示するので、この関数は必ずバックグラウンドで呼ぶこと。
func runPmsetAsAdmin(disableSleep: Bool, onStart: ((Process) -> Void)? = nil) -> AdminResult {
    let value = disableSleep ? "1" : "0"
    let prompt = disableSleep
        ? "この Mac をスリープさせない設定に変更します。"
        : "この Mac を通常どおりスリープする設定に戻します。"
    let script = "do shell script \"/usr/bin/pmset -a disablesleep " + value + "\""
        + " with prompt \"" + prompt + "\""
        + " with administrator privileges"

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let errPipe = Pipe()
    p.standardOutput = FileHandle.nullDevice
    p.standardError = errPipe
    do {
        try p.run()
    } catch {
        return AdminResult(ok: false, cancelled: false, message: "osascript を起動できませんでした: \(error.localizedDescription)")
    }
    onStart?(p)
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let stderr = String(data: errData, encoding: .utf8) ?? ""
    if p.terminationStatus == 0 {
        return AdminResult(ok: true, cancelled: false, message: "")
    }
    // -128 = User canceled / シグナルで落とした場合もキャンセル扱いにする
    let cancelled = stderr.contains("-128") || p.terminationReason == .uncaughtSignal
    return AdminResult(ok: false, cancelled: cancelled, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// 現在スリープが無効化されているかを読む（権限不要）。
/// 判定できなかった場合は nil を返す。
///
/// 注意: 設定の書き込みキーは `disablesleep` だが、読み出しは `pmset -g` の
/// "SleepDisabled" 行に出る。`pmset -g custom` には出ないため、そちらを見てはいけない。
func readSleepDisabled() -> Bool? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8) else { return nil }

    // 出力形式が想定どおりかを確認してから判定する。
    // 想定外の形式のときに「オフ」と誤判定して状態を壊さないための保険。
    guard text.lowercased().contains("system-wide power settings") else { return nil }

    for rawLine in text.split(separator: "\n") {
        let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let key = fields.first, key.lowercased() == "sleepdisabled" else { continue }
        return fields.count >= 2 && fields[1] == "1"
    }
    // SleepDisabled 行が無い = 無効化されていない
    return false
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var caffeinate: Process?
    private var ticker: Timer?

    private var isOn = false
    private var expiry: Date?     // nil かつ isOn なら「無期限」
    private var busy = false      // 認証ダイアログ表示中
    private var pendingTurnOn = false   // 認証中の操作の向き（true=オンにしようとしている）
    private var pendingAuth: Process?   // 表示中の認証ダイアログ（キャンセル用）
    private var syncTimer: Timer?

    private lazy var clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f
    }()

    // MARK: 起動 / 終了

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 前回の異常終了などで disablesleep が 1 のまま残っていたら、その状態を引き継ぐ。
        // （こうしないと「オフ表示なのに実際はスリープしない」というズレが起きる）
        if readSleepDisabled() == true {
            isOn = true
            expiry = nil
            startCaffeinate(seconds: nil)
        }

        updateUI()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isOn, self.expiry != nil else { return }
            self.updateUI()
        }
        // 表示と実際の電源設定がズレないよう、定期的に pmset の値と突き合わせる。
        // シェルの nosleep 関数など、アプリ外から変更された場合もこれで追従する。
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.syncWithSystemState()
        }
    }

    /// 実際の disablesleep を読み、表示状態が違っていれば実態に合わせる
    private func syncWithSystemState() {
        guard !busy else { return }   // 操作中は触らない
        DispatchQueue.global(qos: .utility).async {
            // 読み取れなかったときは表示を書き換えない（誤判定で状態を壊さないため）
            guard let actual = readSleepDisabled() else { return }
            DispatchQueue.main.async {
                guard !self.busy, actual != self.isOn else { return }
                self.isOn = actual
                self.expiry = nil
                if actual {
                    self.startCaffeinate(seconds: nil)
                } else {
                    self.stopCaffeinate()
                }
                self.updateUI()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isOn else { return .terminateNow }
        turnOff(quitting: true) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: クリック処理

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if wantsMenu || busy {
            // 認証中の左クリックは何も起きないと不安なので、状況が読めるメニューを出す
            openMenu()
        } else {
            if isOn { turnOff() } else { turnOn(seconds: nil) }
        }
    }

    /// 右クリック時だけメニューを出す。出したあと nil に戻して左クリックをトグルに保つ。
    private func openMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 現在のモードを見出しとして最上部に出す
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.attributedTitle = headerTitle()
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let presets: [(String, Int?)] = [
            ("無期限でオン", nil),
            ("1時間だけオン", 3600),
            ("2時間だけオン", 7200),
            ("4時間だけオン", 14400),
        ]
        for (title, seconds) in presets {
            let item = NSMenuItem(title: title, action: #selector(presetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.isEnabled = !busy
            // いま選ばれているモードにチェックを付ける
            if isOn && !busy {
                if let s = seconds {
                    item.state = (expiry != nil && abs(remainingTotal(forPreset: s)) < 60) ? .on : .off
                } else {
                    item.state = (expiry == nil) ? .on : .off
                }
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if busy {
            let cancelItem = NSMenuItem(title: "認証をキャンセル", action: #selector(cancelPendingAuth), keyEquivalent: "")
            cancelItem.target = self
            menu.addItem(cancelItem)
            menu.addItem(.separator())
        }
        let offItem = NSMenuItem(title: "オフにする", action: #selector(offSelected), keyEquivalent: "")
        offItem.target = self
        offItem.isEnabled = isOn && !busy
        offItem.state = isOn ? .off : .on
        menu.addItem(offItem)

        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        let quitItem = NSMenuItem(title: "NoSleep を終了", action: #selector(quitSelected), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// プリセット s 秒でオンにした場合との残り時間の差（チェックマーク判定用）
    private func remainingTotal(forPreset seconds: Int) -> Double {
        guard let e = expiry else { return .infinity }
        return e.timeIntervalSinceNow - Double(seconds)
    }

    @objc private func presetSelected(_ sender: NSMenuItem) {
        let seconds = sender.representedObject as? Int
        if isOn {
            // すでにオンなら pmset は触らず、時間だけ引き直す（認証を増やさない）
            expiry = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
            startCaffeinate(seconds: seconds)
            updateUI()
        } else {
            turnOn(seconds: seconds)
        }
    }

    @objc private func cancelPendingAuth() {
        guard let p = pendingAuth, p.isRunning else { return }
        p.terminate()   // osascript を止めると認証ダイアログも閉じる
    }

    @objc private func offSelected() { turnOff() }
    @objc private func quitSelected() { NSApp.terminate(nil) }

    // MARK: オン / オフ

    private func turnOn(seconds: Int?) {
        guard !busy, !isOn else { return }
        busy = true
        pendingTurnOn = true
        updateUI()
        // 権限が要る pmset を先に実行し、成功したときだけ caffeinate を起動する。
        // 逆順だと認証キャンセル時に caffeinate だけ残ってしまう。
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runPmsetAsAdmin(disableSleep: true) { proc in
                DispatchQueue.main.async { self.pendingAuth = proc }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.pendingAuth = nil
                guard result.ok else {
                    if !result.cancelled {
                        self.showAlert(title: "スリープ抑止を有効にできませんでした",
                                       text: "pmset -a disablesleep 1 が失敗しました。電源設定は変更されていません。\n\n\(result.message)")
                    }
                    self.updateUI()
                    return
                }
                self.isOn = true
                self.expiry = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
                self.startCaffeinate(seconds: seconds)
                self.updateUI()
                // 変更が本当に反映されたかを少し後に確かめる
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.syncWithSystemState() }
            }
        }
    }

    private func turnOff(quitting: Bool = false, completion: (() -> Void)? = nil) {
        guard isOn, !busy else { completion?(); return }
        busy = true
        pendingTurnOn = false
        stopCaffeinate()
        updateUI()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runPmsetAsAdmin(disableSleep: false) { proc in
                DispatchQueue.main.async { self.pendingAuth = proc }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.pendingAuth = nil
                if result.ok {
                    self.isOn = false
                    self.expiry = nil
                } else {
                    // 解除できなかった＝実際にはまだスリープしない状態。
                    // 表示をオフにしてしまうと実態とズレるので、オンのまま維持する。
                    if !quitting {
                        self.startCaffeinate(seconds: self.remainingSeconds())
                    }
                    self.showAlert(title: "スリープ抑止を解除できませんでした",
                                   text: "この Mac はまだスリープしません。もう一度「オフにする」を試すか、ターミナルで次を実行してください。\n\n    sudo pmset -a disablesleep 0\n\n\(result.message)")
                }
                self.updateUI()
                if !quitting {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.syncWithSystemState() }
                }
                completion?()
            }
        }
    }

    // MARK: caffeinate の管理

    private func startCaffeinate(seconds: Int?) {
        stopCaffeinate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -d 画面 / -i アイドル / -m ディスク / -s システム / -u ユーザー活動
        var args = ["-dimsu"]
        if let s = seconds, s > 0 { args += ["-t", String(s)] }
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                // 自分で止めた場合は caffeinate を先に nil にしてあるので、ここは素通りする
                guard self.caffeinate === proc else { return }
                self.caffeinate = nil
                if self.isOn { self.turnOff() }   // -t の時間切れ → 自動でオフ
            }
        }
        do {
            try p.run()
            caffeinate = p
        } catch {
            caffeinate = nil
        }
    }

    private func stopCaffeinate() {
        guard let p = caffeinate else { return }
        caffeinate = nil
        if p.isRunning { p.terminate() }
    }

    private func remainingSeconds() -> Int? {
        guard let e = expiry else { return nil }
        return max(1, Int(e.timeIntervalSinceNow.rounded()))
    }

    private func remainingString(_ end: Date, short: Bool) -> String {
        let total = max(0, Int(end.timeIntervalSinceNow.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return short ? String(format: "%d:%02d", h, m) : String(format: "%d:%02d:%02d", h, m, s)
    }

    // MARK: 表示

    /// メニュー最上部の見出し（1行目=モード、2行目=補足）
    private func headerTitle() -> NSAttributedString {
        let mainText: String
        let subText: String
        let color: NSColor

        if busy {
            mainText = isOn ? "● オン — スリープしません（変更中…）"
                            : "○ オフ — 通常どおりスリープします（変更中…）"
            subText = (pendingTurnOn ? "オンに切り替え中" : "オフに戻し中")
                + "・パスワード入力のダイアログに応答してください"
            color = isOn ? .systemOrange : .labelColor
        } else if isOn {
            mainText = "● オン — スリープしません"
            if let e = expiry {
                subText = "残り \(remainingString(e, short: false))・\(clockFormatter.string(from: e)) に自動でオフ"
            } else {
                subText = "無期限（オフにするまで続きます）"
            }
            color = .systemOrange
        } else {
            mainText = "○ オフ — 通常どおりスリープします"
            subText = "省エネ設定に従ってスリープします"
            color = .labelColor
        }

        let result = NSMutableAttributedString(
            string: mainText + "\n",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: color,
            ])
        result.append(NSAttributedString(
            string: subText,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        return result
    }

    /// アイコンにカーソルを合わせたときに出る説明文
    private func tooltipText() -> String {
        if busy {
            let now = isOn ? "オン（この Mac はスリープしません）" : "オフ（この Mac は通常どおりスリープします）"
            let next = pendingTurnOn ? "オンに切り替えようとしています" : "オフに戻そうとしています"
            return """
            NoSleep — 現在のモード: \(now)
            \(next)。管理者パスワードのダイアログに応答してください。

            ダイアログが見当たらないときは、
            右クリック →「認証をキャンセル」で取り消せます。
            """
        }
        if isOn {
            let when: String
            if let e = expiry {
                when = "残り \(remainingString(e, short: false))（\(clockFormatter.string(from: e)) に自動でオフ）"
            } else {
                when = "無期限（オフにするまで続きます）"
            }
            return """
            NoSleep — 現在のモード: オン
            この Mac はスリープしません。
            \(when)

            画面・システムともスリープせず、フタを閉じてもスリープしません。
            左クリック: オフにする（管理者パスワードが必要）
            右クリック: 時間を選ぶ / 終了
            """
        }
        return """
        NoSleep — 現在のモード: オフ
        この Mac は通常どおりスリープします。
        省エネ設定に従って画面もシステムもスリープします。

        左クリック: 無期限でオンにする（管理者パスワードが必要）
        右クリック: 時間を選んでオンにする
        """
    }

    private func updateUI() {
        guard let button = statusItem.button else { return }

        // アイコンは常に「いまの実際のモード」を表す。
        // 認証中でも状態を差し替えず、薄く+「…」を足すだけにする。
        let symbol: String
        let accent: NSColor?      // nil ならメニューバーの標準色（白/黒）に追従する
        var label: String

        if isOn {
            symbol = "cup.and.saucer.fill"
            accent = .systemOrange   // オンのときだけ着色し、他の項目と一目で区別できるようにする
            label = expiry.map { " " + remainingString($0, short: true) } ?? " オン"
        } else {
            symbol = "moon.zzz"
            accent = nil
            label = " オフ"          // オフでも必ず文字を出す（無表示だと状態が読めないため）
        }
        if busy { label += "…" }

        // NSStatusBarButton では contentTintColor が効かず黒く沈むため、
        // シンボル自体に色を焼き込む（オフ時はテンプレートのまま背景に追従させる）。
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let color = accent {
            image = image?.withSymbolConfiguration(.init(paletteColors: [color]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.contentTintColor = nil
        button.imagePosition = label.isEmpty ? .imageOnly : .imageLeading
        button.title = label
        button.toolTip = tooltipText()
        button.setAccessibilityLabel(isOn ? "NoSleep: オン。スリープしません。" : "NoSleep: オフ。通常どおりスリープします。")
    }

    private func showAlert(title: String, text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: ログイン項目

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(title: "ログイン時の起動を変更できませんでした",
                      text: "システム設定 > 一般 > ログイン項目 から手動で追加してください。\n\n\(error.localizedDescription)")
        }
    }
}

// MARK: - 起動

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dock に出さない
app.run()
