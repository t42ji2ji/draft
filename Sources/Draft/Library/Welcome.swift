import Foundation

// A new user's first launch: an empty library gets one sample document, opened in place of an untitled one.
// Runs once per Mac; a library that already has anything in it is left alone.
enum Welcome {
    private static let seededKey = "WelcomeSeeded"

    static func seedIfNew() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededKey) else { return }
        defaults.set(true, forKey: seededKey)
        let root = Library.rootURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty ?? false else { return }
        let url = root.appendingPathComponent(L10n.isChinese ? "歡迎使用 Draft" : "Welcome to Draft")
            .appendingPathExtension(TextDocument.pathExtension)
        guard (try? (L10n.isChinese ? chinese : english).write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        defaults.set(url.path, forKey: LibraryWindowController.lastDocumentKey)
    }

    private static let english = """
    # Welcome to Draft

    Draft is a quiet place to write. Everything you write is a plain text file in the Draft folder, saved as you type.

    ## Writing

    Draft uses Markdown. Marks like **bold**, *italic*, ==highlight== and `code` fade away once written; press ⌫ right after one to see the mark again.

    - Lists continue when you press Return
    - Tag a document with #draft and it shows up under Hashtags in the library

    > A quote looks like this.

    Code blocks are coloured by their language, and a `mermaid` block becomes a diagram in the preview:

    ```swift
    let greeting = "Hello, Draft"   // a comment
    ```

    ```mermaid
    flowchart LR
      A[Write] --> B[Preview] --> C[Export]
    ```

    ## Getting around

    - ⌃⌘S shows the library, ⇧⌘O the outline of this document
    - ⌘R shows the preview, ⇧⌘E exports it
    - ⌘D turns on Focus Mode, which dims everything but the sentence you're on
    - ⇧⌘D shows syntax: nouns, verbs, adjectives in their own colours
    - ⌘J opens the assistant, which works with Claude or Codex on this Mac

    Delete this document whenever you like, and ⌘N to start your own.
    """

    private static let chinese = """
    # 歡迎使用 Draft

    Draft 是一個安靜寫字的地方。你寫的每一篇都是 Draft 資料夾裡的純文字檔，邊打邊存。

    ## 寫作

    Draft 用 Markdown。**粗體**、*斜體*、==螢光筆==、`程式碼` 的記號寫完就會隱藏；游標停在後面按一下 ⌫ 就會再出現。

    - 清單按 Return 會自動接下一項
    - 寫上 #草稿 這樣的標籤，文件庫的標籤區就會出現它

    > 引文長這樣。

    程式碼區塊會依語言上色，`mermaid` 區塊在預覽裡會畫成圖：

    ```swift
    let greeting = "你好，Draft"   // 註解
    ```

    ```mermaid
    flowchart LR
      A[寫作] --> B[預覽] --> C[匯出]
    ```

    ## 操作

    - ⌃⌘S 顯示文件庫，⇧⌘O 顯示這篇的大綱
    - ⌘R 顯示預覽，⇧⌘E 匯出
    - ⌘D 開啟專注模式，只亮你正在寫的那一句
    - ⇧⌘D 顯示詞性：名詞、動詞、形容詞各有顏色
    - ⌘J 打開 AI 助理，用這台 Mac 上的 Claude 或 Codex

    這篇隨時可以刪掉，⌘N 開始寫你自己的。
    """
}
