# AI 助手（右側欄，⌘J）

Draft 自己的功能，不是 iA 的。做法照 `~/me/mailsift`：呼叫使用者本機已登入的 Claude Code 或 Codex，每輪一個行程，用 `--resume`／`codex exec resume` 接續對話。

| 項目 | 做法 |
|---|---|
| 開關 | View › Show Assistant（⌘J），工具列最右邊的 ✦ |
| 後端 | 欄位頂端切換 Claude Code／Codex（存在 `AssistantBackend`）；找不到的那個變灰。切換或按「新對話」會開新對話 |
| 找執行檔 | `zsh -lc command -v`，再試 `~/.local/bin`、`~/.nvm/versions/node/*/bin`（nvm 只在 .zshrc 裡）、Homebrew、ChatGPT.app 內附的 codex |
| 工作目錄 | 文件庫（`Library.rootURL`）。Claude：`--tools Read,Grep,Glob`，只預先允許 `propose_edit`，所以只能讀文件庫裡的檔；Codex：唯讀 sandbox，shell 開著讓它讀檔 |
| 每輪附上 | system prompt 裡放目前文件全文（編輯器裡的版本，可能比磁碟新，上限 6 萬字）；訊息裡附選取文字與行號、每個 `@[…]` 的內容 |
| 輸入框 | 一個圓角框：上面是選取文字卡片（左側游標色直條、「檔名 · 第 N 行」、最多三行原文、× 這次不附），中間輸入，下面「@ 文件或標題」與送出。卡片內容送出一次就收起，重新選取才再出現；送出的訊息在對話裡也帶著那張卡片。選了的 @ 在輸入框和訊息裡是一顆圓角標籤（一個字元，刪除鍵一次刪整顆；送給 AI 時寫成 `@[名稱]`）；檔案和標題不同色：沒選配色時是 iA 的資料夾青與智慧資料夾紫，有配色時是游標色與文字色。輸入框用 TextKit 1，TextKit 2 清空後會留下標籤的殘影。長選取不會撐寬側欄 |
| @ | 輸入 @ 跳出清單：目前文件的標題（`@[#標題]`，附該節到下一個同級或更高標題為止）、文件庫的檔案（`@[路徑]`，附全文，上限 2 萬字） |
| 修改 | AI 只能呼叫 Draft 的 MCP 工具 `propose_edit(file?, find, replace, reason)`；伺服器是同一個執行檔以 `Draft mcp` 啟動，什麼都不改。面板從串流讀到呼叫，做成卡片：原文灰色刪除線、新文字底下淡淡一層游標色（跟配色走，2026-10-16 起不用紅綠）、理由；「套用」在編輯器裡取代第一個相符的原文（可 ⌘Z），「忽略」；兩張以上時有「全部套用／全部忽略」。點原文會在文件裡標出位置。別的檔案的修改會先打開那個檔 |
| 回報 | 套用、忽略、找不到原文的結果在下一則訊息開頭告訴 AI（每張卡只說一次） |
| 模型 | 標頭的選單，每個後端各記一個（`AssistantModel.claude`／`.codex`），「預設模型」是 CLI 自己的選擇。Claude 列別名 fable、opus、sonnet、haiku；Codex 列 `codex debug models` 裡 visibility 為 list 的。換模型不換對話 |
| 紀錄 | 每段對話一個 JSON：`~/Library/Application Support/Draft/Assistant/<uuid>.json`（後端、session id、訊息、卡片和狀態）；每輪結束和每次套用／忽略時存。重開 Draft 回到上次的對話（`AssistantConversation`）。🕘 選單列出最近 50 段，點了接著聊；最下面「刪除目前這段對話」。✎ 開新對話，舊的留在紀錄裡 |

Claude Code 會照使用者的 `~/.claude/CLAUDE.md` 去讀記憶檔；system prompt 要它在這裡忽略，讀檔權限也只到文件庫。`--bare` 能完全跳過，但它不讀 OAuth 登入，不能用。

## 範例與實測（2026-10-15）

`~/Documents/Draft/AI 測試/` 六篇，每篇開頭寫了建議的問法：潤稿（選取＋精簡）、錯字（多張卡片、全部套用）、會議筆記（@#待辦 整理成清單）、人物設定＋故事（@檔案 跨文件比對）、翻譯（選取英文取代）。7–12 是較難的：同一個詞改很多處（卡片原文要夠長才不會改錯）、同一句出現四次只改第三個、表格與程式碼（只改註解）、改語氣後 ⌘Z 逐張還原與「找不到原文」、兩份設定跨檔只列不改再分檔修改（含改另一個檔）、紀錄重開後卡片狀態還在。每篇開頭寫了問法與預期結果。在文件庫副本上用真的 Claude 跑過全部，Codex 跑過錯字那篇：每張卡片都套用成功，結果正確，一輪 8–24 秒。第一次跨文件那篇 Claude 回了簡體，system prompt 已改成明確要求繁體中文（台灣用法）。
