import SwiftUI

/// MitsuTools に載せる機能（モジュール）の共通インターフェース。
///
/// 新しい機能を足すときは、このプロトコルを実装したクラスを
/// `AppModel.makeModules()` に追加するだけでよい。
/// メニューバーのメニュー、設定ウィンドウのペイン、グローバルショートカットは
/// ここで宣言した内容から自動で組み立てられる。
@MainActor
protocol ToolModule: AnyObject {
    /// UserDefaults のキーなどに使う、変わらない ID。
    var id: String { get }
    /// 設定のツールバーや一般ペインに出す名前。
    var title: String { get }
    /// SF Symbols の名前。
    var systemImage: String { get }
    /// このモジュールが登録するグローバルショートカット。
    var actions: [ShortcutAction] { get }
    /// Accessibility 権限が必要かどうか。
    var needsAccessibility: Bool { get }

    /// モジュールを有効にしたときに呼ばれる。監視などを始める。
    func start()
    /// モジュールを無効にしたときに呼ばれる。監視などを止める。
    func stop()

    /// メニューバーのメニューに差し込む項目。不要なら `EmptyView` を返す。
    func menuItems() -> AnyView
    /// 設定ウィンドウのペイン。
    func settingsView() -> AnyView

    /// 設定ファイルの [id] テーブルに書き出す値（書き出す順に並べる）。
    func exportConfig() -> [(key: String, value: TOMLValue)]
    /// 設定ファイルの [id] テーブルを読み込んで反映する。書かれていないキーは今の値のままにする。
    func importConfig(_ table: TOMLTable)
}

extension ToolModule {
    var needsAccessibility: Bool { false }
    func menuItems() -> AnyView { AnyView(EmptyView()) }
    func exportConfig() -> [(key: String, value: TOMLValue)] { [] }
    func importConfig(_ table: TOMLTable) {}
}

/// グローバルショートカットで呼び出す操作。
struct ShortcutAction: Identifiable {
    /// 例: "window.left"。ショートカットの保存キーにも使う。
    let id: String
    let title: String
    let defaultShortcut: Shortcut?
    let handler: @MainActor () -> Void
}
