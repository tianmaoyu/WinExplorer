import AppKit
import Foundation

/// 右键「新建」支持的文件类型（对齐 Windows 右键 → 新建的常用项）
enum NewFileKind: String, CaseIterable, Identifiable {
    case text
    case markdown
    case csv
    case rtf
    case word
    case excel
    case powerpoint

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return L("文本文档", "Text Document")
        case .markdown: return L("Markdown 文档", "Markdown Document")
        case .csv: return L("CSV 表格", "CSV Spreadsheet")
        case .rtf: return L("RTF 文档", "Rich Text Document")
        case .word: return L("Word 文档", "Word Document")
        case .excel: return L("Excel 工作表", "Excel Worksheet")
        case .powerpoint: return L("PowerPoint 演示文稿", "PowerPoint Presentation")
        }
    }

    /// 默认文件名主体（重名时后面加编号）
    var defaultBaseName: String {
        switch self {
        case .text: return L("新建文本文档", "New Text Document")
        case .markdown: return L("新建 Markdown 文档", "New Markdown Document")
        case .csv: return L("新建 CSV 表格", "New CSV Spreadsheet")
        case .rtf: return L("新建 RTF 文档", "New Rich Text Document")
        case .word: return L("新建 Word 文档", "New Word Document")
        case .excel: return L("新建 Excel 工作表", "New Excel Worksheet")
        case .powerpoint: return L("新建 PowerPoint 演示文稿", "New PowerPoint Presentation")
        }
    }

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .csv: return "csv"
        case .rtf: return "rtf"
        case .word: return "docx"
        case .excel: return "xlsx"
        case .powerpoint: return "pptx"
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "doc.plaintext"
        case .markdown: return "text.justify"
        case .csv: return "tablecells"
        case .rtf: return "doc.richtext"
        case .word: return "doc.text"
        case .excel: return "tablecells"
        case .powerpoint: return "rectangle.inset.filled"
        }
    }
}

/// 新建文件的初始内容。
///
/// Office 三件套用「ECMA-376 最小空白包」直接以 base64 内嵌（合计约 5 KB）：
/// - docx 三件套、xlsx 五件套、pptx 六件套（生成与验证见 docs/adr/0004）
/// - 不依赖 Bundle 布局，自检可以直接断言魔数
/// - Word / Excel / PowerPoint / WPS / Numbers 都能打开
enum DocumentTemplates {

    /// 返回该类型的初始内容；文本类返回空 Data
    static func content(for kind: NewFileKind) -> Data? {
        switch kind {
        case .text, .markdown, .csv:
            return Data()
        case .rtf:
            return emptyRTF
        case .word:
            return Data(base64Encoded: embedded.word)
        case .excel:
            return Data(base64Encoded: embedded.excel)
        case .powerpoint:
            return Data(base64Encoded: embedded.powerpoint)
        }
    }

    /// 空白 RTF：TextEdit 可直接打开编辑
    private static var emptyRTF: Data {
        NSAttributedString(string: "")
            .rtf(from: NSRange(location: 0, length: 0), documentAttributes: [:])
            ?? Data("{\\rtf1}".utf8)
    }

    private enum embedded {
        static let word = "UEsDBBQAAAAIALhmdV0XmADX6wAAALIBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbH1QyU4DMQy98xWRr2gmAweEUKc9sByBQ/kAK/HMRM2mOC3t3+NpoQdUONpvs99itQ9e7aiwS7GHm7YDRdEk6+LYw8f6pbkHxRWjRZ8i9XAghtXyarE+ZGIl4sg9TLXmB63ZTBSQ25QpCjKkErDKWEad0WxwJH3bdXfapFgp1qbOHiBmTzTg1lf1vJf96ZJCnkE9nphzWA+Ys3cGq+B6F+2vmOY7ohXlkcOTy3wtBNCXI2bo74Qf4ZuUU5wl9Y6lvmIQmv5MxWqbzDaItP3f58KlaRicobN+dsslGWKW1oNvz0hAF88f6GPlyy9QSwMEFAAAAAgAuGZ1XT+t/vqvAAAALAEAAAsAAABfcmVscy8ucmVsc43POw7CMAwA0J1TRN5pWgaEUEMXhNQVlQNEiZtWNB/F4dPbk4EBKgZG/57tunnaid0x0uidgKoogaFTXo/OCLh0p/UOGCXptJy8QwEzEjSHVX3GSaY8Q8MYiGXEkYAhpbDnnNSAVlLhA7pc6X20MuUwGh6kukqDfFOWWx4/DVigrNUCYqsrYN0c8B/c9/2o8OjVzaJLP3YsOrIso8Ek4OGj5vqdLjILPJ/Dv548vABQSwMEFAAAAAgAuGZ1Xd5vwPaNAAAArwAAABEAAAB3b3JkL2RvY3VtZW50LnhtbEWNQQ7CIBBF956CzN5OdWFMU+jOE+gBELBtUmYIg9beXlwYVz8vP3mvH95xUa+QZWbScGhaUIEc+5lGDbfrZX8GJcWStwtT0LAFgcHs+rXz7J4xUFHVQNKtGqZSUocobgrRSsMpUP0enKMtFfOIK2efMrsgUgNxwWPbnjDamcBU5Z399t2Epscf4j9lPlBLAQIUAxQAAAAIALhmdV0XmADX6wAAALIBAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAgAuGZ1XT+t/vqvAAAALAEAAAsAAAAAAAAAAAAAAIABHAEAAF9yZWxzLy5yZWxzUEsBAhQDFAAAAAgAuGZ1Xd5vwPaNAAAArwAAABEAAAAAAAAAAAAAAIAB9AEAAHdvcmQvZG9jdW1lbnQueG1sUEsFBgAAAAADAAMAuQAAALACAAAAAA=="
        static let excel = "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"
        static let powerpoint = "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"
    }
}
