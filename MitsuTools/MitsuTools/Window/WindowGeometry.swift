import AppKit

/// マスの区切り方。
nonisolated enum GridLayout: String, CaseIterable, Codable, Sendable {
    case halves = "1x2"
    case quad = "2x2"
    case six = "2x3"

    var rows: Int { self == .halves ? 1 : 2 }
    var columns: Int { switch self { case .halves: 2; case .quad: 2; case .six: 3 } }
    var cellCount: Int { rows * columns }
    var label: String { "\(rows)×\(columns)" }

    var next: GridLayout {
        let all = GridLayout.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// ウィンドウをどこに置いたか。
nonisolated enum Placement: Equatable, Sendable {
    /// 2×2・2×3 のマス（index は左上から 0 始まり）。
    case cell(GridLayout, Int)
    /// 左右どちらかに寄せる。step は 1/2 → 1/3 → 2/3 の何番目か。
    case side(left: Bool, step: Int)

    static let sideFractions: [CGFloat] = [1.0 / 2, 1.0 / 3, 2.0 / 3]
    static let sideLabels = ["1/2", "1/3", "2/3"]

    var hudText: String {
        switch self {
        case let .cell(layout, index): "\(layout.label) のマス \(index + 1)"
        case let .side(left, step): "\(left ? "左" : "右") \(Placement.sideLabels[step])"
        }
    }
}

/// ギャップと余白を考慮して、マスの位置と大きさを計算する。
/// 座標はすべて Accessibility API と同じ「左上原点」の座標系。
nonisolated struct LayoutGeometry: Sendable {
    var gap: CGFloat
    var margin: CGFloat

    func frame(for placement: Placement, in area: CGRect) -> CGRect {
        let inner = area.insetBy(dx: margin, dy: margin)
        switch placement {
        case let .cell(layout, index):
            let cols = CGFloat(layout.columns), rows = CGFloat(layout.rows)
            let w = (inner.width - gap * (cols - 1)) / cols
            let h = (inner.height - gap * (rows - 1)) / rows
            let c = CGFloat(index % layout.columns), r = CGFloat(index / layout.columns)
            return CGRect(x: inner.minX + c * (w + gap), y: inner.minY + r * (h + gap), width: w, height: h).integral
        case let .side(left, step):
            // 反対側に同じ割合で置いたウィンドウとの間がちょうど gap になるようにする。
            let width = (inner.width - gap) * Placement.sideFractions[step]
            let x = left ? inner.minX : inner.maxX - width
            return CGRect(x: x, y: inner.minY, width: width, height: inner.height).integral
        }
    }
}

extension NSScreen {
    /// 主ディスプレイの高さ（座標変換に使う）。
    private static var primaryHeight: CGFloat { screens.first?.frame.maxY ?? 0 }

    /// 左下原点の AppKit 座標を、左上原点の Accessibility 座標に変換する。
    static func toAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func fromAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    var axFrame: CGRect { NSScreen.toAX(frame) }
    var axVisibleFrame: CGRect { NSScreen.toAX(visibleFrame) }

    /// ウィンドウと一番重なっている画面。
    static func best(for axRect: CGRect) -> NSScreen? {
        screens.max { a, b in
            a.axFrame.intersection(axRect).area < b.axFrame.intersection(axRect).area
        } ?? main
    }

    /// 左から右（同じなら上から下）の順に並べた画面。
    static var ordered: [NSScreen] {
        screens.sorted { ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY) }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func isClose(to other: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
