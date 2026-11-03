//
//  TextAttachmentManager.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/24/25.
//

import Foundation

/// Manages a set of attachments for the layout manager, provides methods for efficiently finding attachments for a
/// line range.
///
/// If two attachments are overlapping, the one placed further along in the document will be
/// ignored when laying out attachments.
public final class TextAttachmentManager {
    private var orderedAttachments: [AnyTextAttachment] = []
    weak var layoutManager: TextLayoutManager?
    private var selectionObserver: (any NSObjectProtocol)?

    public weak var delegate: TextAttachmentManagerDelegate?

    /// 公开构造：便于在不持有 `TextLayoutManager` 的场景（基准、测试）单独使用。
    public init() { }

    /// 批量更新深度。>0 时布局失效只记标志，不真的触发。
    ///
    /// 一次装几千个标注（git blame、查找高亮）时，逐条 `setNeedsLayout()` 会让
    /// `visibleLineIds` 被清空 N 次、`layoutView.needsLayout` 被置 N 次，
    /// 主线程白白走 N 遍失效流程。批量期间只记一次。
    private var batchDepth: Int = 0
    private var needsLayoutAfterBatch: Bool = false

    /// 进入批量更新：期间不触发布局失效。
    public func beginBatchUpdates() {
        batchDepth += 1
    }

    /// 结束批量更新：若有累积的失效请求，这里统一触发一次。
    public func endBatchUpdates() {
        batchDepth = max(0, batchDepth - 1)
        guard batchDepth == 0, needsLayoutAfterBatch else { return }
        needsLayoutAfterBatch = false
        layoutManager?.setNeedsLayout()
    }

    /// 请求一次布局失效；批量期间只记标志。
    private func requestLayoutInvalidation() {
        if batchDepth > 0 {
            needsLayoutAfterBatch = true
        } else {
            layoutManager?.setNeedsLayout()
        }
    }

    /// 批量添加附件。
    ///
    /// 单条 `add` 是 `O(n)` 的数组插入 + 一次全量失效，N 条就是 `O(n²)` 加 N 次失效。
    /// 这里先拼接再一次排序（`O(n log n)`），并且只在末尾触发一次布局失效。
    /// - Parameter items: 附件与其范围。范围若落在同一行会按 location 排序后交给布局。
    public func add(contentsOf items: [(attachment: any TextAttachment, range: NSRange)]) {
        guard !items.isEmpty else { return }

        beginBatchUpdates()
        defer { endBatchUpdates() }

        // 拼接 + 一次排序。比逐个 insert 进已排序数组快一个量级。
        var merged = orderedAttachments
        merged.reserveCapacity(orderedAttachments.count + items.count)
        merged.append(contentsOf: items.map { AnyTextAttachment(range: $0.range, attachment: $0.attachment) })
        merged.sort { $0.range.location < $1.range.location }
        orderedAttachments = merged

        // 行高合并必须逐条做：它改的是 lineStorage 里的行高，不是纯数组操作。
        for item in items {
            mergeTrailingLine(for: item.range)
        }

        for item in items {
            delegate?.textAttachmentDidAdd(item.attachment, for: item.range)
        }
        // defer 里的 endBatchUpdates 会触发一次 setNeedsLayout。
        needsLayoutAfterBatch = true
    }

    /// Adds a new attachment, keeping `orderedAttachments` sorted by range.location.
    /// If two attachments overlap, the layout phase will later ignore the one with the higher start.
    /// - Complexity: `O(n log(n))` due to array insertion. Could be improved with a binary tree.
    public func add(_ attachment: any TextAttachment, for range: NSRange) {
        let attachment = AnyTextAttachment(range: range, attachment: attachment)
        let insertIndex = findInsertionIndex(for: range.location)
        orderedAttachments.insert(attachment, at: insertIndex)

        mergeTrailingLine(for: range)
        requestLayoutInvalidation()

        delegate?.textAttachmentDidAdd(attachment.attachment, for: range)
    }

    /// 附件盖住行尾换行符时，把它后面那一行合成同一行（行高置 0）。
    ///
    /// 抽出来是因为批量添加也要逐条做这一步——它改的是 `lineStorage` 的行高，
    /// 不是纯数组操作，没法像排序那样合并。
    private func mergeTrailingLine(for range: NSRange) {
        var getNextOne = false
        layoutManager?.lineStorage.linesInRange(range).dropFirst().forEach { line in
            if line.height != 0 {
                layoutManager?.lineStorage.update(atOffset: line.range.location, delta: 0, deltaHeight: -line.height)
            }

            // Only do this if it's not the end of the document
            if range.max == line.range.max && range.max != layoutManager?.lineStorage.length {
                getNextOne = true
            }
        }

        if getNextOne,
           let trailingLine = layoutManager?.lineStorage.getLine(atOffset: range.max),
           trailingLine.height != 0 {
            layoutManager?.lineStorage.update(atOffset: range.max, delta: 0, deltaHeight: -trailingLine.height)
        }
    }

    /// Removes an attachment and invalidates layout for the removed range.
    /// - Parameter offset: The offset the attachment begins at.
    /// - Returns: The removed attachment, if it exists.
    @discardableResult
    public func remove(atOffset offset: Int) -> AnyTextAttachment? {
        let index = findInsertionIndex(for: offset)

        guard index < orderedAttachments.count && orderedAttachments[index].range.location == offset else {
            return nil
        }

        let attachment = orderedAttachments.remove(at: index)
        layoutManager?.invalidateLayoutForRange(attachment.range)

        delegate?.textAttachmentDidRemove(attachment.attachment, for: attachment.range)

        return attachment
    }

    /// 按类型移除全部附件（例如卸载某一类行尾装饰）。
    ///
    /// 不要用「安装时记录的偏移」逐个移除：`textUpdated(atOffset:delta:)` 会在编辑后
    /// 平移附件位置，旧偏移随即失效，`remove(atOffset:)` 会返回 nil 并留下残留附件，
    /// 表现为同一行重复绘制多份标注。
    /// - Parameter type: 要移除的附件具体类型。
    public func removeAttachments<T: TextAttachment>(ofType type: T.Type) {
        // 单次过滤 + 一次整体替换：逐项 remove(at:) 会让数组反复搬移，n 个附件退化为 O(n²)。
        let removed = orderedAttachments.filter { $0.attachment is T }
        guard !removed.isEmpty else { return }
        orderedAttachments.removeAll { $0.attachment is T }
        for attachment in removed {
            layoutManager?.invalidateLayoutForRange(attachment.range)
            delegate?.textAttachmentDidRemove(attachment.attachment, for: attachment.range)
        }
        layoutManager?.setNeedsLayout()
    }

    /// Finds attachments starting in the given line range, and returns them as an array.
    /// Returned attachment's ranges will be relative to the _document_, not the line.
    /// - Complexity: `O(n log(n))`, ideally `O(log(n))`
    public func getAttachmentsStartingIn(_ range: NSRange) -> [AnyTextAttachment] {
        var results: [AnyTextAttachment] = []
        var idx = findInsertionIndex(for: range.location)
        while idx < orderedAttachments.count {
            let attachment = orderedAttachments[idx]
            let loc = attachment.range.location
            if loc >= range.upperBound {
                break
            }
            if range.contains(loc) {
                if let lastResult = results.last, !lastResult.range.contains(attachment.range.location) {
                    results.append(attachment)
                } else if results.isEmpty {
                    results.append(attachment)
                }
            }
            idx += 1
        }
        return results
    }

    /// Returns all attachments whose ranges overlap the given query range.
    ///
    /// - Parameter range: The `NSRange` to test for overlap.
    /// - Returns: An array of `AnyTextAttachment` instances whose ranges intersect `query`.
    public func getAttachmentsOverlapping(_ range: NSRange) -> [AnyTextAttachment] {
        // 起点用「按 location 二分」再向前回退：附件可能跨过查询起点，
        // 直接按 `upperBound >= range.location` 二分是不成立的谓词
        // （upperBound 随 location 不单调，长附件会破坏单调性），会漏掉跨行附件。
        var startIdx = findInsertionIndex(for: range.location)
        while startIdx > 0, orderedAttachments[startIdx - 1].range.max > range.location {
            startIdx -= 1
        }
        guard startIdx < orderedAttachments.count else { return [] }

        var results: [AnyTextAttachment] = []
        var idx = startIdx

        // Collect every subsequent attachment that truly overlaps the query.
        while idx < orderedAttachments.count {
            let attachment = orderedAttachments[idx]
            if attachment.range.location >= range.upperBound {
                break
            }
            if (attachment.range.intersection(range)?.length ?? 0 > 0 || attachment.range.max == range.location)
                && results.last?.range != attachment.range {
                results.append(attachment)
            }
            idx += 1
        }

        return results
    }

    /// Updates the text attachments to stay in the same relative spot after the edit, and removes any attachments that
    /// were in the updated range.
    /// - Parameters:
    ///   - atOffset: The offset text was updated at.
    ///   - delta: The change delta, positive is an insertion.
    package func textUpdated(atOffset: Int, delta: Int) {
        // 附件按 location 升序排列，所以只有位置 >= atOffset 的才需要平移。
        //
        // 原来是每次编辑都倒序遍历**全部**附件，且在循环里 `remove(at:)`——
        // 几千个附件（git blame、查找高亮）时，每次按键都是 O(n)，最坏 O(n²)。
        // 现在用二分定位分界点，只处理尾部，删除改成一次过滤。
        let split = findInsertionIndex(for: atOffset)

        // 跨过编辑点的附件要删除。它们的位置在 atOffset 之前、但范围覆盖到 atOffset，
        // 数量极少，从分界点往前扫到 range.max <= atOffset 为止。
        var headEnd = split
        while headEnd > 0, orderedAttachments[headEnd - 1].range.max > atOffset {
            headEnd -= 1
        }

        var kept: [AnyTextAttachment] = []
        kept.reserveCapacity(orderedAttachments.count)

        // 分界点之前：位置与范围都不受影响。
        for index in 0..<headEnd {
            kept.append(orderedAttachments[index])
        }
        // 分界点之后：落在编辑区间内的丢弃，其余整体平移。
        for index in headEnd..<orderedAttachments.count {
            var attachment = orderedAttachments[index]
            if attachment.range.contains(atOffset) {
                continue
            }
            if attachment.range.location > atOffset {
                attachment.range.location += delta
            }
            kept.append(attachment)
        }
        orderedAttachments = kept
    }

    /// Set up the attachment manager to listen to selection updates, giving text attachments a chance to respond to
    /// selection state.
    ///
    /// This is specifically not in the initializer to prevent a bit of a chicken-and-the-egg situation where the
    /// layout manager and selection manager need each other to init.
    ///
    /// - Parameter selectionManager: The selection manager to listen to.
    func setUpSelectionListener(for selectionManager: TextSelectionManager) {
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }

        selectionObserver = NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: selectionManager,
            queue: .main
        ) { [weak self] notification in
            guard let selectionManager = notification.object as? TextSelectionManager else {
                return
            }
            let selectedSet = IndexSet(ranges: selectionManager.textSelections.map({ $0.range }))
            for attachment in self?.orderedAttachments ?? [] {
                let isSelected = selectedSet.contains(integersIn: attachment.range)
                if attachment.attachment.isSelected != isSelected {
                    self?.layoutManager?.invalidateLayoutForRange(attachment.range)
                }
                attachment.attachment.isSelected = isSelected
            }
        }
    }

    deinit {
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
    }
}

private extension TextAttachmentManager {
    /// Binary-searches `orderedAttachments` and returns the smallest index
    /// at which `predicate(attachment)` is true (i.e. the lower-bound index).
    ///
    /// - Note: always returns a value in `0...orderedAttachments.count`.
    ///         If it returns `orderedAttachments.count`, no element satisfied
    ///         the predicate, but that’s still a valid insertion point.
    func lowerBoundIndex(
        where predicate: (AnyTextAttachment) -> Bool
    ) -> Int {
        var low = 0
        var high = orderedAttachments.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(orderedAttachments[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    /// Returns the index in `orderedAttachments` at which an attachment whose
    /// `range.location == location` *could* be inserted, keeping the array sorted.
    ///
    /// - Parameter location: the attachment’s `range.location`
    /// - Returns: a valid insertion index in `0...orderedAttachments.count`
    func findInsertionIndex(for location: Int) -> Int {
        lowerBoundIndex { $0.range.location >= location }
    }

    /// Finds the first index whose attachment satisfies `predicate`.
    ///
    /// - Parameter predicate: the query predicate.
    /// - Returns: the first matching index, or `nil` if none of the
    ///            attachments satisfy the predicate.
    func firstIndex(where predicate: (AnyTextAttachment) -> Bool) -> Int? {
        let idx = lowerBoundIndex { predicate($0) }
        return idx < orderedAttachments.count ? idx : nil
    }
}
