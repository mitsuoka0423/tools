import AppKit
import Observation

/// マルチクリックの「離してから、次に押すまで」の時間を、ふだんの操作の中で測り、待つ時間（W）を決める。
/// 測った値はメモリ上だけに持つ（ファイルには書かない）。
@MainActor
@Observable
final class ClickGapLearner {
    /// 直近の間隔（ミリ秒）。最大 50 件。
    private(set) var samples: [Double] = []
    /// 内訳の表示用：1→2 回目、2→3 回目
    private(set) var firstGaps: [Double] = []
    private(set) var secondGaps: [Double] = []
    /// 学んだ待ち時間。10 件たまるまでは nil（システムの間隔を使う）。
    private(set) var learnedMs: Int?
    @ObservationIgnored private var sinceUpdate = 0

    static let windowSize = 50
    static let minimumSamples = 10
    static let minimumMs = 120
    static let maxStepMs = 50
    static let marginMs = 60.0

    /// 上限：システムの「ダブルクリックの間隔」。それより遅い次のクリックは、アプリがマルチクリックと見なさない。
    static var systemMaxMs: Int { Int((NSEvent.doubleClickInterval * 1000).rounded()) }

    var currentMs: Int { learnedMs ?? Self.systemMaxMs }

    func record(gap seconds: Double, afterClick clicks: Int) {
        let ms = seconds * 1000
        append(ms, to: &samples)
        if clicks <= 1 { append(ms, to: &firstGaps) } else { append(ms, to: &secondGaps) }
        sinceUpdate += 1
        if samples.count >= Self.minimumSamples, learnedMs == nil || sinceUpdate >= Self.minimumSamples {
            recompute()
            sinceUpdate = 0
        }
    }

    func reset() {
        samples = []
        firstGaps = []
        secondGaps = []
        learnedMs = nil
        sinceUpdate = 0
    }

    /// W ＝ 長いほうから 5% の値 ＋ 60 ms。120 ms 以上、システムの間隔以下。1 回に動かすのは最大 50 ms。
    private func recompute() {
        let sorted = samples.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let target = min(Self.systemMaxMs, max(Self.minimumMs, Int(((p95 + Self.marginMs) / 10).rounded()) * 10))
        let current = learnedMs ?? Self.systemMaxMs
        learnedMs = current + max(-Self.maxStepMs, min(Self.maxStepMs, target - current))
    }

    private func append(_ value: Double, to array: inout [Double]) {
        array.append(value)
        if array.count > Self.windowSize { array.removeFirst(array.count - Self.windowSize) }
    }
}
