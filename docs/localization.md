# 介面語言

Settings › Language：Follow System／English／繁體中文，存在 `Language`（0／1／2）。切換即時生效，不用重開。

- 程式裡寫英文，`L("…")` 查 `Sources/Draft/Localization/Strings+*.swift` 的繁中表；表依區域分檔（Menu、Settings、Library、Preview、Assistant），合併時同一個鍵以排前面的表為準（Menu 最先）。
- 同一個英文在不同地方譯法不同時，鍵寫成 `"情境|英文"`（例如 `"Status|Cut"`、`"Card|Edit"`），英文模式只顯示 `|` 後面。
- 會顯示文字的畫面各自監聽 `L10n.didChange` 重設文字；選單整個重建（`AppDelegate.installMenu`）。
- 「Follow System」看系統偏好語言的第一個是不是 zh-Hant／zh-TW／zh-HK／zh-MO，其他都是英文。
- 系統自己畫的部分（存檔／打開對話框、尋找列、About、Edit 選單裡系統加的項目、「還原 ⋯」的前綴、同步狀態裡的時間）只在啟動時決定語言：選了語言會寫 app 自己的 `AppleLanguages`，下次開才跟上（Info.plist 宣告了 en、zh-Hant，沒有 .lproj 資料夾也行：2026-10-16 實測切繁中重開後，Edit 選單的「自動填寫」「啟動聽寫」「表情符號和其他符號」、View 的「進入全螢幕」都是中文）。

不翻的：寫進檔名或文件內容的字（`Untitled` 檔名、` copy`、衝突檔名、表格範本）、存檔用的值、送給 AI 的提示詞與 MCP 工具定義、git 訊息、樣板名與產品名。AI 側欄已經在對話裡的行保留當時的語言（存在對話紀錄裡）；設定視窗的預覽範例文字固定中英混排。
