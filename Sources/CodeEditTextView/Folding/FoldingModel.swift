//
//  FoldingModel.swift
//  CodeEditTextView
//
//  代码折叠的「状态」：哪些行区间是折叠的，以及怎么算出可折叠区间。
//
//  设计要点：折叠**不改文本、不改行偏移**，只记录行号区间。
//  真正让行消失的是 `TextLayoutManager+setFoldedLineRanges` —— 它把折叠区间内
//  的行高置 0（复用附件那套 `update(deltaHeight:)` 机制），于是：
//  - y 坐标由红黑树的聚合高度自动算对，不需要维护任何投影映射；
//  - 折叠/展开是 O(k log n)（k = 折叠行数），不是 O(文档行数)。
//
//  为什么不用「投影层」（VS Code 的 ViewModel 式）：那要求所有坐标转换
//  （光标、选区、命中测试、滚动）都经过一层映射，改动面覆盖整个 TextView。
//  行高归零能拿到同样的视觉效果，代价只是「折叠行仍占字符偏移」——
//  而这一点本来就必须处理（折叠不等于删除）。
//

import Foundation

public final class FoldingModel {

    /// 一个折叠区间，行号从 0 开始，**包含首行**（首行是可见的标题行）。
    public struct Region: Equatable {
        public var lines: ClosedRange<Int>
        /// 折叠时该区间共有多少行被隐藏（= lines.count - 1），用于绘制 `⋯N`。
        public var hiddenLineCount: Int { max(lines.count - 1, 0) }

        public init(lines: ClosedRange<Int>) {
            self.lines = lines
        }
    }

    /// 当前折叠的区间，按起点升序。
    public private(set) var regions: [Region] = []

    /// 可折叠候选（来自缩进扫描或语法树），按起点升序。
    ///
    /// 与 `regions` 分开存：候选量大（每层缩进一个），折叠态只有用户点开的那些，
    /// 每次折叠/展开都重新扫描全文是不可接受的。
    public private(set) var candidates: [Region] = []

    private var candidatesDirty = true

    public init() {}

    // MARK: - 折叠状态

    /// 该行是否被隐藏（在某个折叠区间内且不是首行）。
    public func isHidden(line: Int) -> Bool {
        guard let region = region(containing: line) else { return false }
        return line != region.lines.lowerBound
    }

    /// 包含该行的折叠区间。
    public func region(containing line: Int) -> Region? {
        // regions 按起点升序：二分找到最后一个 lowerBound <= line 的区间。
        var low = 0
        var high = regions.count
        while low < high {
            let mid = (low + high) / 2
            if regions[mid].lines.lowerBound <= line {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let index = low - 1
        guard index >= 0 else { return nil }
        let candidate = regions[index]
        return candidate.lines.contains(line) ? candidate : nil
    }

    /// 折叠一个区间。返回是否真的改变了状态。
    @discardableResult
    public func fold(_ range: ClosedRange<Int>) -> Bool {
        // 至少要隐藏一行，否则折叠没有意义。
        guard range.count > 1 else { return false }
        // 已经落在某个折叠区间里：不重复折叠（避免嵌套状态互相覆盖）。
        guard region(containing: range.lowerBound) == nil else { return false }

        regions.append(Region(lines: range))
        regions.sort { $0.lines.lowerBound < $1.lines.lowerBound }
        return true
    }

    /// 展开包含该行的折叠区间。返回被展开的区间，没有则 nil。
    @discardableResult
    public func unfold(containingLine line: Int) -> Region? {
        guard let index = regions.firstIndex(where: { $0.lines.contains(line) }) else { return nil }
        return regions.remove(at: index)
    }

    public func reset() {
        regions.removeAll()
    }

    // MARK: - 候选区间（缩进扫描）

    /// 标记候选需要重算（文本变化后调用）。
    public func invalidateCandidates() {
        candidatesDirty = true
    }

    /// 重算候选区间。`text` 是全文，`tabWidth` 用于把 tab 折算成列宽。
    ///
    /// 算法：逐行取缩进宽度；对每一行，向后吃掉所有缩进更深的行（空行跟随），
    /// 得到 `[i, j]`。整趟 O(n)，十万行约几毫秒，只在文本改动后算一次。
    ///
    /// 不做语法树折叠（tree-sitter 的 foldable 查询）是因为：
    /// 缩进规则对所有语言都成立，零配置、零解析成本；语法折叠可以作为后续增强，
    /// 两者算出的都是「行号区间」，接口一致。
    public func refreshCandidates(text: String, tabWidth: Int = 4) {
        candidates = Self.indentRanges(in: text, tabWidth: tabWidth)
        candidatesDirty = false
    }

    /// 候选区间；未初始化时返回空。
    public func currentCandidates() -> [Region] {
        candidatesDirty ? [] : candidates
    }

    /// 按缩进计算可折叠区间。
    ///
    /// 实现刻意只用一次 UTF-8 遍历：`String.Index` 的随机访问是 O(n)，
    /// 按行取子串/取字符会让整趟退化成 O(n²)（十万行文件上会卡秒级）。
    public static func indentRanges(in text: String, tabWidth: Int = 4) -> [Region] {
        var indents: [Int] = []
        var blank: [Bool] = []
        indents.reserveCapacity(1024)
        blank.reserveCapacity(1024)

        var width = 0
        var hasContent = false
        var atLineStart = true
        // `String.UTF8View` 的迭代是逐字节 O(1)：不像 `String.Index(offsetBy:)` 那样
        // 每次都要从头扫，十万行文本上不会退化成 O(n²)。
        for byte in text.utf8 {
            if byte == 0x0A { // \n
                indents.append(width)
                blank.append(!hasContent)
                width = 0
                hasContent = false
                atLineStart = true
            } else if atLineStart {
                if byte == 0x20 { // 空格
                    width += 1
                } else if byte == 0x09 { // tab
                    width += tabWidth - (width % tabWidth)
                } else {
                    atLineStart = false
                    hasContent = true
                }
            } else {
                hasContent = true
            }
        }
        // 末行（没有换行符结尾时补上）
        indents.append(width)
        blank.append(!hasContent)

        let totalLines = indents.count
        var result: [Region] = []
        var line = 0
        while line < totalLines {
            guard !blank[line], line + 1 < totalLines else {
                line += 1
                continue
            }
            let baseIndent = indents[line]
            var end = line + 1
            while end < totalLines {
                // 空行跟着走：折叠后它们本来也不占视觉空间。
                if blank[end] { end += 1; continue }
                guard indents[end] > baseIndent else { break }
                end += 1
            }
            // 去掉尾部空行，避免折叠区间把下一段前的空行也吞掉。
            var trimmedEnd = end - 1
            while trimmedEnd > line && blank[trimmedEnd] { trimmedEnd -= 1 }

            if trimmedEnd > line {
                result.append(Region(lines: line...trimmedEnd))
            }
            line += 1
        }
        return result
    }
}
