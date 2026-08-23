import Foundation

/// 书架扫描的收工判据。
///
/// Amazon 的 `/kindle-library` 是**分批懒加载**：首屏渲染一批（约 50 本），
/// 滚到已渲染内容的底部才会去请求下一批。因此 `atScrollEnd` 只能证明
/// 「当前 DOM 到底了」，**不能证明「书架扫完了」**——这两件事之间隔着一次
/// 网络往返。旧实现把它们等同起来，并且只在 pass 之间等 650ms，于是在
/// 补货窗口内就宣布扫描完成，稳定地只拿到首批（线上表现为反复重试都是同一
/// 个数字，例如 48 本）。
///
/// 这里把判据收紧成三条同时成立：DOM 到底、连续多次没有新书、并且距离最后
/// 一次拿到新书已经过了一个真实的补货观察窗。只要还在出新书，预算就不消耗，
/// 所以大书架能一直滚下去。
enum KindleShelfScanPolicy {
    /// 绝对上限，只为防止页面异常时无限滚动；正常书架靠 `.scanComplete` 收工。
    /// 每批约 3 个 pass（滚到底、等补货、收下一批），要装得下很大的书架。
    static let maxPasses = 90

    /// 一本书都没抓到时不值得滚满全程——书架为空/页面不对的判定另有依据。
    static let emptyShelfMaxPasses = 12

    /// 到达 DOM 底部后留给 Amazon 补货的**基础**观察时间。
    /// 还没观测到任何一次补货时用它——单批就装下的小书架不会被额外拖慢。
    static let restockObservationWindow: TimeInterval = 3.0

    /// 观察窗按实测补货耗时放大的倍数，留出网络抖动的余量。
    static let restockWindowFactor: Double = 1.8

    /// 放大的上限，避免某次异常慢的补货把扫描拖到没边。
    static let maxObservationWindow: TimeInterval = 12.0

    /// 探针确认可用时的观察窗。此时「还有没有下一批」由在途请求直接回答，
    /// 窗口只留一点容错，不必再用时间去猜。
    static let probeTrustedWindow: TimeInterval = 2.0

    /// 实际使用的观察窗。
    ///
    /// 两种模式：
    /// - **探针可信**（这个页面上确实拦到过书架请求）：用 `probeTrustedWindow`。
    ///   有请求在途时策略本就不会收工，窗口只负责兜住「请求已结束但 DOM 还没
    ///   更新」这一小段。
    /// - **探针没拦到任何请求**：可能是它对这个页面失效了，退回按实测补货耗时
    ///   自适应的保守窗口。固定 3 秒对 2.5 秒补货只剩 0.5 秒余量，真机上出现过
    ///   只差 0.3 秒就收工的情形；慢网络用户补货要 4–5 秒，固定窗口必然截断。
    ///
    /// - Parameters:
    ///   - observedRestock: 目前观测到的最慢一次补货耗时；0 表示还没观测到。
    ///   - probeActive: 这个页面上探针是否拦到过书架请求。
    static func observationWindow(
        observedRestock: TimeInterval,
        probeActive: Bool = false
    ) -> TimeInterval {
        if probeActive { return probeTrustedWindow }
        guard observedRestock > 0 else { return restockObservationWindow }
        let scaled = observedRestock * restockWindowFactor
        return min(max(scaled, restockObservationWindow), maxObservationWindow)
    }

    /// 观察窗内还要连续这么多次「没有新书」才认定书架真的到底。
    static let requiredIdlePassesAtEnd = 3

    /// `atScrollEnd` / `shelfLoading` 都依赖 Amazon 的 markup，改版即失真。
    /// 这条保底停止与它们无关，保证扫描一定会结束。
    ///
    /// 它必须按**时间**算而不是按 pass 数算：滚过一整批的途中本来就不会有新书
    /// （整个 DOM 早在第一个 pass 就抓干净了），用 pass 数当保底会在扫描滚到
    /// 底部、触发下一批之前就把它掐断——这正是第一版修复没能跑通测试的原因。
    static let stallTimeout: TimeInterval = 18.0

    struct Input: Equatable {
        var pass: Int
        var bookCount: Int
        /// 连续多少个 pass 没有拿到新书（有新增即归零）。
        var idlePasses: Int
        var stableSnapshotPasses: Int
        /// 距离最后一次拿到新书过了多久；还没抓到书时从扫描开始计。
        var secondsSinceLastNewBook: TimeInterval
        /// 距离最后一次**滚到 DOM 底部**过了多久。
        ///
        /// 观察窗必须从这里算，不能从「最后一次拿到新书」算：Amazon 是滚到底
        /// 之后才去请求下一批的，两个时刻之间隔着一次滚动。用后者会让观察窗
        /// 少掉那一段——实测中补货只差 153ms 就落地，扫描却已经收工了。
        var secondsSinceReachedEnd: TimeInterval
        /// 目前观测到的最慢一次补货耗时（滚到底 → 拿到新书）；0 表示还没观测到。
        var observedRestock: TimeInterval = 0
        /// Amazon 是否还有取书架数据的请求在途。
        ///
        /// 这是唯一确定的信号：有请求就说明下一批还在路上，无论等了多久都不能
        /// 收工；没有请求才轮到观察窗去兜「它是不是压根不打算取了」。
        var shelfRequestInFlight: Bool = false
        /// 这个页面上探针一共拦到过几次书架请求。大于 0 说明探针确实在工作，
        /// 可以信任它的判断而不必再用时间窗去猜。
        var shelfRequestTotal: Int = 0
        var atScrollEnd: Bool
        var shelfLoading: Bool
        var pageReady: Bool
        var isExactBoundLibrary: Bool
    }

    enum Decision: Equatable {
        /// 书架确实扫完了。
        case scanComplete
        /// 继续滚，并在下一次抓取前等待这么久。
        case keepScrolling(waitSeconds: TimeInterval)
        /// 预算耗尽——拿到多少算多少，并让埋点把这次异常暴露出来。
        case exhausted
    }

    static func decide(_ input: Input) -> Decision {
        // 有请求在途 = 下一批正在路上，此时任何「扫完了」的判断都是错的。
        if input.shelfRequestInFlight {
            return .keepScrolling(waitSeconds: waitSeconds(after: input))
        }

        let window = observationWindow(
            observedRestock: input.observedRestock,
            probeActive: input.shelfRequestTotal > 0
        )
        let structurallyComplete = input.isExactBoundLibrary
            && input.pageReady
            && !input.shelfLoading
            && input.atScrollEnd
            && input.stableSnapshotPasses >= 2

        if input.bookCount > 0,
           input.pass >= 1,
           input.idlePasses >= requiredIdlePassesAtEnd,
           input.secondsSinceReachedEnd >= window,
           input.secondsSinceLastNewBook >= window,
           structurallyComplete {
            return .scanComplete
        }

        if input.bookCount == 0, input.pass >= emptyShelfMaxPasses - 1 {
            return .exhausted
        }

        // Amazon 改版让 atScrollEnd 失真时，扫描仍必须停下来；标记为
        // exhausted 而不是 scanComplete，好让 scan_timeout 埋点暴露出来。
        // 页面还挂着加载指示器时不算停滞——慢网络下补货本来就久，那正是
        // 最容易被误截断的一批用户；但也不能无限等，所以只放宽一倍。
        let stallLimit = input.shelfLoading ? stallTimeout * 2 : stallTimeout
        if input.bookCount > 0, input.secondsSinceLastNewBook >= stallLimit {
            return .exhausted
        }

        if input.pass >= maxPasses - 1 {
            return .exhausted
        }

        return .keepScrolling(waitSeconds: waitSeconds(after: input))
    }

    /// 还在出新书时快滚；到底之后改成小步轮询。
    ///
    /// 一次抓取现在只要几十毫秒（卡片去重 + a→card 缓存 + 已解析书缓存），
    /// 所以没必要再用秒级间隔去省开销——补货一落地就该被发现。收工的安全
    /// 边际由 `restockObservationWindow` 保证，与轮询快慢无关。
    static func waitSeconds(after input: Input) -> TimeInterval {
        if input.idlePasses == 0 { return 0.4 }
        return 0.45
    }
}
