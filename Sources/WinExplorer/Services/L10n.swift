import Foundation

/// 极简本地化：只维护中英两套文案。
/// 默认跟随系统首选语言；`WINEXPLORER_LANG=zh|en` 可以强制指定（截图验收与自检用）。
///
/// 用法：`Text(L("新建文件夹", "New Folder"))`，带参数时用 `String(format: L("已选 %d 项", "%d selected"), count)`。
enum L10n {
    static let isEnglish: Bool = {
        if let forced = ProcessInfo.processInfo.environment["WINEXPLORER_LANG"]?
            .trimmingCharacters(in: .whitespaces).lowercased(), !forced.isEmpty {
            return forced.hasPrefix("en")
        }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("en")
    }()

    /// 当前语言代码（关于窗口里显示用）
    static var currentLanguageName: String { isEnglish ? "English" : "简体中文" }
}

/// 取当前语言的文案
func L(_ zh: String, _ en: String) -> String {
    L10n.isEnglish ? en : zh
}
