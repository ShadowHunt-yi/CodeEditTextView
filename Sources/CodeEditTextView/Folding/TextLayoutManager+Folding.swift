//
//  TextLayoutManager+Folding.swift
//  CodeEditTextView
//
//  把折叠状态落到排版上：折叠区间内的行高度置 0。
//
//  为什么用「行高归零」而不是投影层：
//  - `TextLineStorage` 是红黑树，节点高度是**聚合值**，某个节点高度变 0 后，
//    其后续所有行的 y 自动前移，不需要我们维护任何偏移映射；
//  - 折叠/展开只碰被折叠的那几行（O(k log n)），不重排全文档；
//  - 光标、选区、命中测试全部走现有的 y/offset 接口，天然正确。
//
//  这与 `TextAttachmentManager.mergeTrailingLine` 是同一套机制（附件盖住换行符
//  时也是把下一行高度置 0，让两行看起来是一行）。
//

import AppKit

extension TextLayoutManager {

    /// 应用折叠结果。传入完整的折叠区间列表（而不是增量），便于做幂等处理。
    ///
    /// - Parameter ranges: 折叠区间，行号从 0 开始，包含首行（首行保持可见）。
    /// - Note: 内部会先还原上一次折叠的行，再应用新的状态，因此可以反复调用。
    public func setFoldedLineRanges(_ ranges: [ClosedRange<Int>]) {
        // 1) 还原上一轮折叠的行。
        if !foldedLineHeights.isEmpty {
            for (index, height) in foldedLineHeights {
                guard let position = lineStorage.getLine(atIndex: index) else { continue }
                lineStorage.update(atOffset: position.range.location, delta: 0, deltaHeight: height)
            }
            foldedLineHeights.removeAll(keepingCapacity: true)
        }

        guard !ranges.isEmpty else {
            setNeedsLayout()
            return
        }

        // 2) 应用新的折叠：区间内除首行外，高度全部置 0。
        for range in ranges {
            for index in range.dropFirst() {
                guard let position = lineStorage.getLine(atIndex: index), position.height > 0 else {
                    continue
                }
                foldedLineHeights[index] = position.height
                lineStorage.update(
                    atOffset: position.range.location,
                    delta: 0,
                    deltaHeight: -position.height
                )
            }
        }

        // 一次失效：行高变了，后续所有行的 y 都要重算（由红黑树聚合自动完成）。
        setNeedsLayout()
    }

    /// 折叠状态是否为空（供调用方决定要不要绘制折叠标记）。
    public var hasFoldedLines: Bool {
        !foldedLineHeights.isEmpty
    }

    /// 某个行号当前是否被折叠隐藏。
    public func isLineFolded(_ index: Int) -> Bool {
        foldedLineHeights[index] != nil
    }
}
