import SwiftUI

/// 設定の各行の先頭に置く、画面を表す小さな図。
/// 設定が対象にする部分（マス・ギャップ・余白など）をアクセントカラーで示す。
struct LayoutIcon: View {
    enum Kind {
        /// 2×2・2×3 のマス
        case cell(GridLayout, Int)
        /// 左右に寄せる
        case side(left: Bool)
        /// マスを選ぶオーバーレイ
        case overlay
        /// ディスプレイ移動
        case display(next: Bool)
        /// ウィンドウ間のギャップ
        case gap
        /// 画面端の余白
        case margin
    }

    let kind: Kind

    static let size = CGSize(width: 34, height: 22)

    var body: some View {
        Group {
            switch kind {
            case let .display(next): displays(next: next)
            default: screen { content($0) }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }

    // MARK: 図

    private var accent: Color { .accentColor }
    private var dim: some ShapeStyle { .quaternary }

    private func screen<C: View>(@ViewBuilder _ content: @escaping (CGSize) -> C) -> some View {
        GeometryReader { geo in
            let inner = CGSize(width: geo.size.width - 4, height: geo.size.height - 4)
            content(inner)
                .frame(width: inner.width, height: inner.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary, lineWidth: 1))
    }

    @ViewBuilder
    private func content(_ size: CGSize) -> some View {
        let g: CGFloat = 1.5
        switch kind {
        case let .cell(layout, index):
            grid(layout, highlight: index, gap: g)
        case .overlay:
            grid(.quad, highlight: nil, gap: g)
        case let .side(left):
            HStack(spacing: g) {
                cell(left)
                cell(!left)
            }
        case .gap:
            // 2 つのウィンドウのあいだ（ギャップ）を塗る
            HStack(spacing: 0) {
                cell(false)
                Rectangle().fill(accent).frame(width: 3)
                cell(false)
            }
        case .margin:
            // 画面の端の帯（余白）を塗り、その内側にウィンドウを置く
            RoundedRectangle(cornerRadius: 2.5)
                .fill(accent.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 1.5).fill(.background).padding(3))
                .overlay(RoundedRectangle(cornerRadius: 1.5).fill(dim).padding(3))
        case .display:
            EmptyView()
        }
    }

    private func grid(_ layout: GridLayout, highlight: Int?, gap: CGFloat) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<layout.rows, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<layout.columns, id: \.self) { c in
                        cell(highlight == r * layout.columns + c)
                    }
                }
            }
        }
    }

    private func cell(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5).fill(on ? AnyShapeStyle(accent) : AnyShapeStyle(dim))
    }

    /// 横に並んだ 2 つの画面。移動先の画面を示す。
    private func displays(next: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            display(on: !next).frame(width: 18, height: 22)
            display(on: next).frame(width: 13, height: 16)
        }
    }

    private func display(on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(on ? accent.opacity(0.3) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(on ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary), lineWidth: on ? 1.5 : 1))
    }
}

/// 先頭に図を付けた設定の行。
struct IconRow<Trailing: View>: View {
    let icon: LayoutIcon.Kind
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        LabeledContent {
            trailing()
        } label: {
            HStack(spacing: 10) {
                LayoutIcon(kind: icon)
                Text(title)
            }
        }
    }
}
