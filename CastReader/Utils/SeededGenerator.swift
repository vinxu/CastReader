//
//  SeededGenerator.swift
//  CastReader
//
//  确定性随机数（SplitMix64）。手写标注的抖动取自它，保证同一 mark 重绘形状一致（不抖）。
//

import Foundation

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // 避免全 0 种子
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// [0, 1) 均匀分布
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// [lower, upper) 均匀分布
    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
    }
}

extension String {
    /// 跨进程稳定的 64-bit 哈希（FNV-1a）。Swift 的 Hasher 每次启动加盐，不能用于确定性种子。
    var stableSeed: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in self.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
