//
//  TextAttachment.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/24/25.
//

import AppKit

public enum TextAttachmentAction {
    /// Perform no action.
    case none
    /// Replace the attachment range with the given string.
    case replace(text: String)
    /// Discard the attachment and perform no other action, this is the default action.
    case discard
}

/// Represents an attachment type. Attachments take up some set width, and draw their contents in a receiver view.
public protocol TextAttachment: AnyObject {
    var width: CGFloat { get }
    var isSelected: Bool { get set }

    func draw(in context: CGContext, rect: NSRect)

    /// The action that should be performed when this attachment is invoked (double-click, enter pressed).
    /// This method is optional, by default the attachment is discarded.
    func attachmentAction() -> TextAttachmentAction
}

public extension TextAttachment {
    func attachmentAction() -> TextAttachmentAction { .discard }

    /// 单击附件时调用。默认无操作；标注类附件（如 git blame）可借此响应单击。
    func attachmentSingleClick() {}

    /// 是否为「行尾装饰」：绘制在行末但不参与换行计算。
    ///
    /// 行尾标注（git blame 等）如果按普通附件计入行宽，当标注宽度超过剩余空间时，
    /// 排版器会把换行符挤到下一行，产生幽灵空行与行号错位。装饰类附件因此跳过换行判断，
    /// 超出部分由视图裁剪（等价于 VS Code 的行尾截断）。
    var isTrailingDecoration: Bool { false }
}

/// Type-erasing type for ``TextAttachment`` that also contains range information about the attachment.
///
/// This type cannot be initialized outside of `CodeEditTextView`, but will be received when interrogating
/// the ``TextAttachmentManager``.
public struct AnyTextAttachment: Equatable {
    package(set) public var range: NSRange
    public let attachment: any TextAttachment

    var width: CGFloat {
        attachment.width
    }

    public static func == (_ lhs: AnyTextAttachment, _ rhs: AnyTextAttachment) -> Bool {
        lhs.range == rhs.range && lhs.attachment === rhs.attachment
    }
}
