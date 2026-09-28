# 全 App UI 重做（沿用已批准首頁風格）

使用者已批准：整個 App 沿用 `work/home-ui-reference` 與目前原生首頁的設計語言，全部頁面一致；全部批次完成並通過 build／analyzer／tests 後才交測試員。本文件是已授權的固定方案與分批計畫，不再另行詢問。

## 固定設計方案

### 共享元件（`lib/widgets/app_surface.dart`）

| 元件／常數 | 用途 |
|---|---|
| `appSurfaceRadius` = 18、`appInnerRadius` = 12 | 內容 surface 與內部小區塊圓角；首頁 `homeCardRadius`／`homeCardShape` 改為引用此值 |
| `appSurfaceShape(context)` | 圓角 + `outlineVariant` 60% 髮絲邊框；同時設為全域 `CardTheme`，所有 `Card` 自動一致 |
| `AppSurface` | 圓角 surface，可點擊（InkWell），預設內距 16/12 |
| `AppSectionHeader` | 區段標題（粗體 titleSmall、可選圖示與右側動作） |
| `AppContentWidth` | 內容置中、限制最大寬度（列表 960、閱讀 920、表單 760） |
| `AppCenteredList` + `appCenteredPadding` | 捲動視圖保持全寬（下拉重新整理、捲軸），列以 padding 置中；以實際量到的寬度計算，側欄／rail 也正確 |
| `appColumnsFor`／`appRowCount`／`AppColumnsRow` | 寬度 ≥ 840 時卡片兩欄，手機單欄 |
| `AppStateView` | 空白／失敗／資訊狀態：圓角圖示塊 + 文案 + 可選動作，窄螢幕可捲動不溢出；第 2 批加 `scrollable: false`（已在捲動視圖內時用） |
| `AppScrollableStateView`（第 2 批） | 把 `AppStateView` 撐滿可下拉重新整理的捲動視圖，空列表也能下拉 |
| `AppIconTile`（第 2 批） | 圓角方形圖示塊（通知、同步摘要、收藏／歷史卡片的前導） |
| `AppInfoPill`（第 2 批） | 卡片標題下的小型資訊膠囊（作者、版塊、時間、計數），`Wrap` 換行、長字省略 |
| `AppPager`（第 2 批） | 分頁切換：上一頁／「目前 / 總頁」（開跳頁）／下一頁，提示用 `MaterialLocalizations` |
| `AppFormSection`（第 3 批） | 表單分組 surface：可選區段標題＋圖示，子欄位固定間距（發文投票、評分、模板編輯） |
| `AppInsetBlock`（第 3 批） | surface 內的圓角小區塊（引用、論壇回傳訊息、預覽、統計格），可選髮絲框 |
| `AppNoticeBanner`（第 3 批） | info／warning／error 三種提示橫幅，可帶標題、可選取文字、動作按鈕（軟關閉、被拒、預檢失敗、投票狀態） |
| `AppEmbedCard`＋`appEmbedColor`（第 3 批） | 樓層內特殊區塊外框：淡色圓角＋髮絲框、圖示塊標題、副標、右側動作；巢狀時改較高容器色取代陰影 |
| `AppBottomActionBar`（第 3 批） | 表單底部固定操作列（髮絲線、SafeArea、置中寬度），鍵盤開啟時隨頁面上移 |
| `EditorFrame`／`EditorControlBar`（第 3 批，`features/editor/widgets/editor_frame.dart`） | 富文字編輯區圓角框（聚焦時主色邊框）；編輯控制列（左側可捲動、右側固定） |
| `ErrorCard`（既有 API） | 改用 `AppSurface` 與同款圖示塊，全 App 的 `buildRetryButton` 一起更新 |
| `AppDialogTitle`（第 5 批） | 對話框標題：圖示塊＋可換行標題，只用 `Row`＋`Expanded`（`AlertDialog` intrinsic 安全）；`error: true` 用錯誤容器色（破壞性確認） |
| `AppTileGroup`（第 5 批） | 設定類頁面的分組：一個 surface 內區段標題＋列（`ListTile`／`SwitchListTile`）＋髮絲分隔線＋可選頁尾（通常是 `AppNoticeBanner`）；列的水波紋被圓角裁切 |
| `appFieldDecoration`（第 5 批） | 表單欄位共用裝飾：填色、圓角 12、可選前置圖示與後綴，說明／錯誤最多 3 行 |

### Theme（`lib/themes/app_themes.dart`）

- 淺色／深色共用 `_finish`：在 FlexColorScheme 產生的主題上覆寫 Card（圓角 + 髮絲邊框、elevation 0）、PopupMenu（圓角 12）、Dialog（圓角 24）。以 `base.xxxTheme.copyWith` 保留 Flex 原有顏色。
- 不改種子色、字體、字級：使用者自訂主題色、自訂字體與文字縮放照舊生效；帖子內文仍走 `MunchedHtml` 與既有閱讀設定。

### 版面規則

- 手機（< 600）：單欄，側邊距 12（帖子樓層 6，保留閱讀寬度）；列與列間距 8。
- 平板／桌面：列表置中最寬 960、帖子最寬 920、表單與個人資料最寬 760；版塊列表 ≥ 840 兩欄。
- SafeArea 與既有 `context.safePadding()` 保留；表單頁仍由 Scaffold 處理鍵盤，內容可捲動。
- 只顯示真實資料，不使用 HTML 原型的虛構資料；無資料時顯示既有「沒有資料」類文案，不捏造。
- 新可見文字一律走既有三語 i18n；第 1 批沒有新增字串（沿用 `general.retry`、`general.failedToLoad`、`profilePage.secondaryTitle` 與 Flutter 內建 `MaterialLocalizations` 的翻頁提示）。第 2 批新增一條 `noticePage.syncAllPage.finished`（Finished／已完成／已完成），其餘沿用既有字串（`topicPage.threads/posts/today` 當版塊計數提示、`profilePage.online/offline` 當聊天狀態、分頁與展開提示用 `MaterialLocalizations`）。
- 未讀強調（第 2 批）：通知卡片只在該類未讀紅點設定開啟時才加底色與粗標題；分頁標籤的未讀數同樣遵守設定，私訊不計入本機封鎖（靜音）對象，與徽章規則一致。
- 聊天氣泡（第 2 批）：只有能確認是目前帳號（歷史頁以 uid、對話頁無 uid 時以使用者名稱）才靠右；無法確認一律當作對方，不猜測歸屬。
- 表單與編輯器（第 3 批）：表單頁置中 760（發文／回覆編輯器 920），欄位依寬度與字級決定每列數量（不用固定高度格，錯誤與說明文字不裁切）；主要送出鈕固定在底部操作列；對話框內不用 `LayoutBuilder`（`AlertDialog` 以 intrinsic 尺寸排版），寬度由 `briefProfileDialogContentWidth` 類的計算或 `Wrap` 處理。第 3 批沒有新增 i18n 字串（沿用 `forumPage.rulesTab.title`、`jumpDialog.title`、`ratePostPage.title`、`general.noData` 與 `MaterialLocalizations`），不需要跑 slang。
- 樓層內區塊（第 3 批）：上鎖、出售、投票、紅包、評分、代碼、懸賞、最佳答案、點評、隱藏內容共用 `AppEmbedCard`；引用改左側色條區塊。只改外觀，HTML／BBCode 解析、購買、投票、領取流程不變；X5 紅包信封保留論壇配色。
- 第 3 批修正：`AppContentWidth` 的 `Align` 會吃滿宿主給的高度，只能放在高度不受限（Column 等）或本來就該填滿的位置；高度有界但寬鬆的宿主（例如 `Scaffold.bottomNavigationBar`）要用 `heightFactor: 1`（回覆列收合框已改）。窄螢幕／大字級時，列尾動作鈕若會把說明文字擠成一字一行，就移到文字下方（封鎖樓層佔位：寬度 < 420×字級倍率）。選單一律依用途分組、以 `PopupMenuDivider(height: 8)` 分隔、文字可換行，破壞性或回報類動作（檢舉）用錯誤色；外部／本地套件產生的按鈕不改套件，只用 `IconButtonTheme` 統一圓角。帖子列表卡片頭部不用 `ListTile`（固定行數會裁切），改頭像＋名稱＋可換行的日期／版塊行＋右側標記。
- 商店、銀行、社群（第 4 批）：不新增共享元件，沿用 `AppSurface`／`AppFormSection`／`AppInsetBlock`／`AppNoticeBanner`／`AppStateView`／`AppInfoPill`／`AppIconTile`。稱號圖一律固定 184:100 比例、`BoxFit.contain`（卡片 138 寬或窄時最寬 184，對話框 138 固定尺寸），勳章圖固定正方形 contain。金額、價格、期限、購買限制、論壇確認句與收費說明只換外框，不縮寫、不省略、不改字串；交易類確認一律兩步（輸入 → 確認摘要 → 送出），摘要放外框區塊，交易說明用 warning 橫幅，破壞性（銷戶）用 error 橫幅。伺服器停用的動作除 Tooltip 外把原因以文字列出（觸控裝置不必長按）。列表頁置中 960、寬 ≥ 840 兩欄（商店、勳章、銀行列表、活動、好友、自動簽到）；銀行詳情寬時活期與紀錄並排；黑名單兩頁置中 760。所有帳號隔離、請求競態、確認與鎖定邏輯不變。第 4 批新增 i18n `userBlock.localTitle`（Blocked users (this device)／已屏蔽用户（本机）／已屏蔽用戶（本機）），需跑 slang。
- 設定、帳號、工具與個人資料（第 5 批）：設定頁每個區段一個 `AppTileGroup`（帳號／外觀／未讀提示／視窗〔桌面〕／簽到／行為／訊息同步〔含 Android 權限與背景服務〕／儲存／進階〔代理〕／備份與還原／除錯／其他），手機單欄置中 760，寬 ≥ 1200 兩欄（外觀類在左、行為與資料在右，最寬 1240）；主題模式改為列下方的圖示分段鈕（原本擠在列尾的 ToggleButtons 在 320 寬 2 倍字會擠壓標題），各項說明原文保留、限制說明改頁尾 info 橫幅。所有設定彈窗改 `AppDialogTitle`、填色欄位、主要動作 `FilledButton`、數值型（同步間隔、圖片清理、字級）改「目前值區塊＋滑桿＋兩端標示」、字型與字級附預覽；備份匯出／還原對話框的安全說明、兩次密碼、只能按鈕關閉（`barrierDismissible: false`、`PopScope`）與資料格式不變。通用 `showQuestionDialog`／`showMessageSingleButtonDialog` 加圖示標題（`dangerous` 時錯誤色），按鈕仍是兩個 `TextButton`、順序不變；`showCustomBottomSheet` 標題與關閉鈕同一列（長標題省略，不再壓在關閉鈕下）並加拉把。登入頁改整頁單一捲動（原本是置中 500 高的清單，鍵盤／大字時空間不足），登入方式改可換行的選擇晶片，帳號與安全問題兩組，失敗時表單內加錯誤橫幅（snack bar 照舊）；只預填呼叫端傳入的帳號名稱，不讀其他帳號資料。帳號管理頁置中、帳號一組、「新增帳號」獨立列；帳號對話框只顯示該帳號自己的名稱／UID／目前狀態，破壞性動作放最後並用錯誤色，所有確認對話框照舊。更新頁顯示目前版本與檢查結果（檢查到新版時在頁內列出版本與更新紀錄，因為全域更新提示在更新頁不出現），更新提示對話框改圖示標題、版本膠囊、更新紀錄外框（「更新」仍是 `TextButton`，只加 tonal 底色）。圖片檢視保留全頁 `PhotoView`（捏合／雙擊縮放、拖曳），下方浮動控制列：適應螢幕、統計資訊、圖片動作（儲存、複製網址、重新載入、存為貼圖；不再重複「檢視大圖」）。個人資料頁：無頭像時頭部改主題色漸層（原本整塊空白）、頭像白框陰影；身分資訊一個 surface；簡介／簽名、使用者組、第二稱號、勳章、管理版塊、簽到、活動、統計各為一個 surface；簽到、活動與統計改「依寬度與字級決定欄數」的數值格（每列等高，取代固定 70px 的 3 欄格），IP 仍預設遮蔽。第二稱號的資料來源與帳號隔離不變。資料編輯分「基本資料／聯絡方式／關於我／論壇顯示」四組，頂部提示「修改需按上傳才送到論壇」，欄位對話框改圖示標題與填色欄位。支持開發對話框保留真實支付寶 QR（白底圓角框以利深色模式掃描）、另存、功能許願連結與自願支持說明，只調整分組與視覺，不新增任何付款流程。
- 第 5 批新增 i18n（三語）：`settingsPage.advancedSection.backupTitle`、`settingsPage.appearanceSection.threadCard.preview`、`aboutPage.linksSection`、`aboutPage.buildSection`、`imageDetailPage.fitToScreen`、`editUserProfilePage.sections.{basic,contact,aboutMe,forum}`、`editUserProfilePage.uploadHint`，需跑 slang；generated 未手改。
- 導覽（第 2 批）：底部導覽列、rail、側欄 drawer 共用低容器底色、圓角 12 指示器與髮絲分隔線；rail 改為常駐標籤。導覽項目與路由不變（首頁／分區／設定）。

## 第二牌子（稱號，原圖 184×100）

| 位置 | 來源 | 尺寸 |
|---|---|---|
| 首頁問候卡右上 | `CurrentTitleCubit`（目前帳號的稱號頁），只對目前帳號 uid | **2026-09-27 使用者細修取代舊目標**：寬版 240（放大超過原圖 184，仍 184:100 contain，不經 `fitWidth` 的原寬上限）；手機 160–184（依內容寬 45%）；不超過卡片寬；問候文字剩餘寬度 < 168 時換行到問候下方。（舊：桌面 184、手機 120–138） |
| 自己的個人資料 | 個人資料頁本身若有稱號區塊則用之；否則（僅本人）用 `CurrentTitleCubit` | 最大 184，完整顯示 |
| 別人的個人資料 | 只用該個人資料頁本身的稱號區塊（樣本尚未證實存在），絕不套目前帳號 | 同上；無資料不顯示 |
| 帖子作者區 | 該樓層作者欄 `div.tsdmtitle-badges div.tsdmtitle-title > img`（X5 樣本 #011 已驗證），舊版 `img.tsdmtitles`／`img.tsdm_lv_title` 後備 | 手機 120、寬螢幕 138；與等級牌子 `Wrap` 換行，不硬塞 |
| 作者彈窗 | 同一樓層資料；樓層沒有且作者 uid＝目前已驗證帳號時，改用 `CurrentTitleCubit`（2026-09-28 回饋 110），其他作者絕不套用 | 最大 184（依對話框內容寬度），與等級牌子 `Wrap` 換行 |
| 我的稱號／勳章稱號中心 | 稱號頁／`CurrentTitleCubit` | 最大 184，空間不足時改直排 |

狀態：讀取中保留牌子大小的佔位；讀取失敗顯示「重試」方塊（Tooltip／語意標籤為「第二稱號 · 載入失敗」），不顯示成「未佩戴」；成功且未佩戴才什麼都不顯示。狀態只對應同一 uid（`CurrentTitleState.statusFor`），其他使用者不會看到目前帳號的佔位或重試。

已知風險：使用者截圖中作者卡只見等級牌子。原始碼解析在 X5 樣本可取得第二牌子，舊版 76px 太小且與等級牌子擠在同一列；本批已放大並換行。若該作者本身未佩戴、或論壇對某些頁面輸出不同標記（目前沒有樣本），仍會不顯示，需要測試員以真實帖子確認。未登入時 X5 作者欄為空，無法取得。

## 分批計畫

| 批次 | 範圍 | 狀態 |
|---|---|---|
| 1 | 共享元件／Theme；App shell 與導覽；首頁；分區、版塊群組、版塊、搜尋、最新帖、我的帖子、收藏、歷史的列表面；帖子閱讀（v1、v2 路由）、作者區、作者彈窗、跳頁控制；個人資料、我的資料、使用者組、稱號展示、資料編輯、頭像 | 本批實作（細節見 `work/full-ui-coverage.md`） |
| 2 | 消息／聊天／通知（含搜尋、同步全部、廣播詳情、回覆詳情）、搜尋頁表單／結果列／分頁、版塊篩選列與篩選表單、底部導覽列／rail／drawer、版塊／收藏／歷史卡片內容層級 | 已實作，Codex 已跑 slang／format／strict analyze／相關測試 PASS |
| 3 | 發文／回覆編輯器與回覆列、草稿箱、投票、評分與評分紀錄、快速回覆／評分模板、檢舉、編輯器彈窗、價格／權限、閱讀控制（麵包屑、`ListAppBar` 頁碼與選單、操作／出售紀錄、複製、封鎖佔位、軟關閉）、樓層內卡片與引用、樓層操作選單、帖子卡片頭部、編輯器工具列外觀、版塊 FAB／版規、收藏備註、作者簡介剩餘區段 | 已實作，Codex 已跑 format／strict analyze／相關測試 PASS |
| 4 | 稱號商店（含購買確認）、勳章中心（含購買／申請對話框）、銀行（列表、活期、紀錄、服務、存取款與服務確認）、活動、成就、積分（統計、紀錄、篩選）、紅包詳情、自動簽到與 `AutoCheckinUserCard`、紅包對話框、好友頁／卡片／選擇器／加好友／同意好友、本機封鎖、網站黑名單、通知忽略動作 | 已實作，Codex 已跑 slang／format／strict analyze／相關測試 PASS |
| 5 | 設定所有區段與設定彈窗、備份對話框、帖子卡片外觀頁、登入／需登入、帳號管理與帳號對話框、首頁使用者選單、更新頁／更新提示／更新紀錄、關於、授權頁外框、贊助、除錯紀錄（歷史／詳情）與除錯展示、於 App 開啟、圖片檢視控制列、個人資料頁剩餘區塊、資料編輯分組與欄位／生日對話框、頭像預覽、分區版主列、通用問答／訊息對話框與底部表單框架 | 已實作，**未驗證**：待 Codex 跑 slang／format／strict analyze／相關測試（新測試 `test_167_full_ui_phase5_test.dart`） |

每批：只做 UI 結構／閱讀層級／響應式改造，保持路由、帳號隔離、通知徽章、樓層／跳轉／分頁、封鎖過濾、BBCode／HTML 解析與網路交易語意；不重寫 repository、不新增交易。

## 驗證

每批以 `slang`（若有新字串）、`build_runner`（若有 mapper 變動）、`dart format`、`flutter analyze`、`flutter test` 驗證；少量 widget test 覆蓋窄螢幕、長文字與第二牌子（第 1 批：`test/regression/test_163_full_ui_phase1_test.dart`；第 2 批：`test/regression/test_164_full_ui_phase2_test.dart`；第 3 批：`test/regression/test_165_full_ui_phase3_test.dart`，含鍵盤開啟時底部送出列仍可點；第 4 批：`test/regression/test_166_full_ui_phase4_test.dart`，稱號圖比例、320 寬 2 倍字購買確認與銀行確認、寬螢幕兩欄、自動簽到卡片換行；第 5 批：`test/regression/test_167_full_ui_phase5_test.dart`，320 寬 2 倍字的破壞性問答（按鈕型別與順序、回傳值）、備份匯出（鍵盤開啟、兩個密碼欄、回傳密碼）與還原錯誤文字、同步間隔／圖片清理不在選項中的預設值（原本會超出索引）、字級與語言回傳值、設定分組列可切換、需登入狀態單一登入鈕）。

## 導覽與首頁細修（使用者追加需求，2026-09-27）— 程式已改，未驗證

依使用者提供的 `work/ui-navigation-reference/reference-sidebar.png`（左欄分組）與 `current-greeting.png`：

- **側欄（drawer 大視窗、rail 中寬）**：9 個真實入口兩組——首頁、版塊、活動、通知、我的；「更多功能」：稱號商店、勳章中心、銀行、設定。沿用 App 主題色（深淺色／自訂色），不強制參考圖的紫色。首頁／版塊／設定是 shell tab（保留分支狀態、雙擊回頂送 `HomeTab.index`）；其他 6 項 `pushNamed` 蓋在 shell 上，返回回到原 tab，選取高亮只給 tab，不把 9 個索引塞進 `HomeTab`。通知入口的未讀徽章只用 `NotificationStateCubit`，規則同 AppBar 通知鈕；無帳號點通知開登入頁。rail 標籤常駐、組間 16px 間距，包在不佔 PrimaryScrollController 的捲動區，短視窗不溢出。手機底部列維持 3 個 tab，其他入口沿用首頁既有入口。
- **文案**：導覽「分割區」改「版塊」（簡「版块」、英「Forums」），僅 `navigation.topics` 與 `topicPage.title`。
- **每日紅包入口**：問候卡簽到旁常駐 `DailyRedPacketEntry`。可領（config＋formHash）→原 `claimDaily`，單次提交防連點；伺服器確認領到／已領→「今日紅包已領取」停用（只針對該頁面的紅包）；頁面沒有紅包時一律顯示「目前無可領取」並可點擊重新整理首頁（tooltip 說明可能已領或未開放）——repo 沒有站點時區依據，不以推測日期宣稱今日已領（2026-09-27 修正移除原 UTC+8 推測）；無帳號→「登入後可領取」。不新增協定、不持久化、不假造可領。
- **問候卡第二牌子**：見上表，寬版 240、手機 160–184。

## 全 UI 自動驗證結果（2026-09-27）
五批實作與測試發現的修正已完成。slang、format、嚴格分析通過，完整 Flutter 測試 1629 通過／1 略過。長標題對話框在 320px／2 倍字且鍵盤開啟時保留可捲動完整文字與固定動作；登入表單改為一次建立所有欄位以確保驗證與重試可達。Android／Windows 預覽建置與實機驗收仍待完成，禁止據此宣稱已發布或實機測試。

## 追加導覽驗證（2026-09-27）
導覽細修及其修正已通過 slang、format、嚴格分析與完整 Flutter 測試：1648 通過、1 略過、0 失敗。未讀徽章的測試等待修正保留並加強正負例，紅包移除未確認的時區假設。預覽106建置和實機驗收待完成。

## 版塊頁桌面放大（使用者 preview106 回饋，2026-09-28）— 程式已改，未驗證

回饋：「電腦版的版塊太小」（`work/ui-topic-reference/desktop-too-small.png`：寬視窗內容只佔中間約 960，四張卡、版塊圖、標題、統計都小）。根因：版塊頁用共用 `AppCenteredList` 預設 `appListMaxWidth` 960，`ForumCard` 在所有寬度都用手機密度（圖 88×44、`titleMedium`、`labelSmall` 統計）。

- **只改版塊頁**：`topics_page.dart` 依 `LayoutBuilder` 量到的頁面實際寬度（扣掉側欄，不看 Platform）判斷：寬 ≥ `topicsPageLargeCardWidth` 1100 → 內容區最寬 `topicsPageMaxWidth` 1320，仍兩欄，卡片／欄距 12；未達 1100 → 與改前完全相同（960、一欄→840 起兩欄、間距 8）。全域 `appListMaxWidth` 不動，其他列表頁不變。
- **大卡（`ForumCard(large: true)`，只有版塊頁寬版傳入）**：內距 20/18；版塊圖 136×68 且 `BoxFit.contain`（完整呈現、小圖會放大；精簡卡維持原本只縮不放）；名稱 20、w600、最多兩行；時間 `bodyMedium` 14；三個統計 `AppInfoPill(large: true)`（圖示 17、`labelLarge` 14、內距 10/5）；捷徑區（最新主題、連結、子版塊）字級各升一級。無圖 fallback、點卡片進版塊、統計 tooltip、捷徑設定不變。
- **版主列**：`GroupModeratorsRow(large: true)` 內距 16/12、圖示 22、標籤 `titleSmall`、人名 chip `labelLarge` 標準密度；與卡片同一 ListView，左右邊緣對齊。
- 字級全走 theme＋`TextScaler`，系統／App 文字縮放照常作用；1100 寬 2 倍字時名稱換行／省略、統計 Wrap 換行。
- 新增共用參數（預設值保持原樣）：`AppInfoPill.large`、`NetworkIndicatorImage.fit`（轉給 `CachedImage.fit`）、`ForumCard.large`、`GroupModeratorsRow.large`。
- 測試：`test/regression/test_169_topics_desktop_test.dart`（1600 寬：內容 1320 置中、兩欄、卡寬 654、版主列同邊緣、圖 136×68、名稱 20、統計 large；1000 寬：960、兩欄、88×44、非大卡；320 寬 2 倍字長名稱：單欄、捲動無例外；1100 寬 2 倍字長名稱：大卡兩欄、捲動無例外；大卡與版主 chip 導覽仍正確）。

## 電腦版版塊驗證（2026-09-28）
format、嚴格分析通過；新 test169 五項尺寸/大字/導覽測試通過，完整 Flutter 測試1653通過／1略過／0失敗。Codex補上新測試漏掉的shared models引用，並以ActionChip本體作點擊目標。預覽107建置與實機驗收待完成。

## 版塊大卡填滿（使用者 UI107 回饋，2026-09-28）— 程式已改，未驗證

回饋：「還是有點小，讓整體再每格滿版一點」（`work/ui-topic-reference/desktop-card-too-empty.png`：兩欄四卡，圖 136×68、名稱 20，卡片右半大片空白，統計是左下三個小膠囊）。取代上一節大卡的數值；< 1100 頁寬與其他 `ForumCard` 使用者不變。

- **內容區**：`topicsPageMaxWidth` 1320 → 1520，仍兩欄（1600 寬視窗卡寬 754）。
- **大卡版頭依卡片實際內容寬與字級自適應**（`forumCardLargeHeaderLayout(contentWidth, textScale)`，卡內 `LayoutBuilder`）：版塊圖寬 = 內容寬 × 0.42，限制在 180–240，高 = 寬 / 2（最大 240×120，`BoxFit.contain` 完整呈現、小圖放大）；圖與名稱間距 20。名稱需要 ≥ 220 × 文字縮放的空間才並排，否則（窄桌面＋大字）版塊圖保持 240×120、名稱改放圖下方。兩欄同寬，所以同列兩卡的圖尺寸、圖頂、名稱起點一致。
- **名稱／時間**：名稱 24、w600、行高 1.3、最多兩行省略；時間 16（`bodyLarge`，secondary）前加 18px 時鐘圖示。
- **統計**：新 `ForumCardStat`，三個等寬區塊（間距 12）橫跨整個卡片底部：上排 20px 主色圖示＋說明文字 15（由 `topicPage.threads/posts/today` 去掉結尾冒號，無新 i18n），下排數字 20 w700；數字用 `FittedBox.scaleDown` 保證不被截斷（窄區塊＋大字只縮小不溢出）；tooltip 仍是原本「主題: 123」全文。大卡不再使用 `AppInfoPill`（`AppInfoPill.large` 保留未刪，其他頁不受影響）。
- **內距**：24/20（`forumCardLargePadding`），版頭與統計間 18。捷徑區、點卡片進版塊、無圖 fallback、tooltip、收藏分組、版主列不變。
- 測試 `test_169` 調整：1600 寬 → 內容 1520、卡寬 754、圖 240×120 且在名稱左側、名稱 24、兩欄圖尺寸／圖頂／名稱位置一致、三統計等寬填滿底部（圖示 20、數字 20）；1000 寬與 320@2x 另外斷言仍是 88×44 圖＋三個小膠囊、沒有 `ForumCardStat`；1100@2x 長名稱＋12–14 位數統計 → 名稱在圖下方、圖 240×120、統計填滿、捲動無例外；新增 1100@1x 長名稱＋長統計 → 圖在 180–240 間並排、名稱不越界、捲動無例外。

## 桌面卡片第二次放大驗證（2026-09-28）
Codex 已執行格式、嚴格分析並通過完整 Flutter 測試：1654 通過、1 略過、0 失敗。涵蓋 1600 寬大卡與全寬統計、1100 寬長名稱/長數字/2倍字、1000 與320寬手機精簡卡保持原樣，以及導航。Windows 預覽108待建置與實機確認；手機布局不變。

## 子版塊與分組頁大卡（使用者 108 回饋，2026-09-28）— 程式已改，未驗證

回饋：「子版塊都很小需要調整」（`work/ui-topic-reference/subforums-too-small.png`：版塊內「子版塊」tab 仍 960 寬、88×44 小圖）。根因：`forum_page.dart` `_buildSubredditTab` 與 `forum_group_page.dart` `_buildContent` 仍用 `AppCenteredList` 預設 960，`ForumCard` 未傳 `large`。`rg ForumCard(` 的 lib 使用處只有這兩處與 `topics_page`。

- **共用規則移到 `widgets/card/forum_card.dart`**：`forumCardListMaxWidth` 1520、`forumCardListLargeWidth` 1100、`forumCardListUsesLargeCards(width)`、`forumCardListLayout(width)`（回傳 large、欄數、左右置中內距、欄距、列分隔）。forum 層不再需要 import topics。`topics_page` 改用它；`topicsPageMaxWidth`／`topicsPageLargeCardWidth`／`topicsPageUsesLargeCards` 保留為同值別名，test_169 不需改。
- **子版塊 tab、gid 分組頁**：與版塊頁相同——`LayoutBuilder` 量到的頁寬（兩頁 body 都在 `SafeArea(bottom: false)` 內，已扣掉 Android 橫向左右安全區與側欄）≥ 1100 → 內容最寬 1520 置中、兩欄、`ForumCard(large: true)`、欄距／列距 12、上 16 下 20；< 1100 → 與改前完全相同（960、一欄→840 起兩欄、間距 8、88×44）。底部仍加 `context.safePadding()`。
- 未動：ScrollController、EasyRefresh／下拉重整、空狀態、載入／錯誤、自動切到子版塊 tab、雙擊回頂、FAB、帖子列表、卡片本身。
- 測試：新 `test/regression/test_170_subforum_cards_test.dart`，子版塊 tab（真 `ForumPage`，無帖子自動切 tab）與 `ForumGroupPage` 各跑一次：1600 → 兩欄大卡、內容 1520 置中、圖 240×120、名稱 24、三統計；1100@2x 長名稱 → 大卡、捲動無例外；1140 寬左側 inset 44 → 實際 1096 維持精簡卡；844×390@2x 左右 inset 44 → 精簡卡且都在安全區內、捲動無例外；320@2x → 單欄精簡 88×44、捲動無例外；390 與 1600 點卡片進入子版塊。

## 手機不用電腦版大小＋無帖子自動切 tab 修正（使用者 109 追加與 Codex 實跑結果，2026-09-28）— 程式已改，未驗證

- **僅桌面平台放大**：使用者明確要求「手機版不要用電腦版這個大小」。`forum_card.dart` 新增 `forumCardListIsDesktop(TargetPlatform)`（Windows／Linux／macOS 為桌面，Android／iOS／Fuchsia 否）；`forumCardListUsesLargeCards(width, platform)`＝桌面且量到寬度 ≥ 1100；`forumCardListLayout(width, platform)`。三處（版塊頁、子版塊 tab、gid 分組頁）皆傳 `Theme.of(context).platform`（App 未設 ThemeData.platform，正式環境即實際平台；測試用 `TargetPlatformVariant` 可控）。Android／iOS 即使 1600 寬橫向或平板也維持手機精簡卡、960 共用寬度；寬度仍於 SafeArea 內量測。
- **strict**：`topics_page.dart` 別名補型別 `const double topicsPageMaxWidth`／`topicsPageLargeCardWidth`；`topicsPageUsesLargeCards` 改為 `(width, platform)`。
- **生命週期**：`ForumPage` 原在 `BlocBuilder` builder 內呼叫 `tabController.animateTo(子版塊)`，TabController 同步通知 `_updateFabVisibilityByTabIndex` → build 中 `setState`（test_170 子版塊全敗的原因），且每次重建都把 tab 拉回子版塊。改為外層 `BlocListener`：`listenWhen` 為載入成功、無帖子、非篩選；listener 檢查 `mounted` 與目前不在子版塊 tab 才切。只在新狀態觸發，不在 build 中，使用者手動切回主題 tab 不再被拉回。
- **測試**：test_169 桌面案例（1600、1000 中寬、1100@2x、1100@1x、導航）標 Windows，320@2x 標 Android，新增 Android 1600 寬仍精簡卡。test_170 兩頁各 8 項：Windows 1600 大卡、Android 1600 精簡、Windows 1100@2x、Windows 1140−inset44、Android 844×390@2x 安全區、Android 320@2x、Android 390 導航、Windows 1600 導航；另加「無帖子」群組：Android 390 自動切子版塊 → 點主題 tab 維持在主題 tab（顯示無帖子）→ 切回子版塊點卡片導航；Windows 1600 自動切子版塊且大卡。

## Android 預覽 109 回饋（feedback 110，2026-09-28）— 程式已改，修正後的測試尚未重跑，未實機驗收

逐項根因、測試與未解事項見 `work/pr135-feedback110/coverage.md`；新測試 `test/regression/test_171_feedback110_test.dart`。需要 slang（紅包文案）與 build_runner（`HomepageState`／新事件）。

- **選擇器欄位**：新增共用 `appPickerDecoration(context, label:, icon:)`：填色＋圓角無線 `UnderlineInputBorder`（聚焦主色底線），各狀態邊框都明確設定，浮動標籤在填色區內。勳章中心分類、銀行業務改用它；銀行未選值時標籤作 placeholder（`isEmpty`），不再同時顯示同字 hint。
- **rail**：上下 inset 移到捲動區外的同色帶，捲動只在兩帶之間裁切（`Clip.hardEdge`）；左 cutout 仍由 `NavigationRail` 處理。捲動高度改為量測 rail 的 intrinsic 高度（至少一個視窗高），不再用估算值：估算偏大時拖到底會留下空白，最後一項停在捲動區上緣被切掉一半。
- **SafeArea 分工**：瀏覽紀錄篩選列與列表同一個 SafeArea，篩選列的左右留白直接用列表的 `appCenteredPadding`（同一寬度量測），所以 chip 與卡片起點一致。`ReplyBar` 背景延伸到螢幕邊緣，輸入框自加左右 inset 與底部 `safePadding()`；點開後的編輯器 sheet 本來就不在頁面的 SafeArea 內，這次也讓它的內容與按鈕（含手機工具列面板）避開左右 inset，背景仍到邊。帖子（含軟關閉橫幅）、私訊兩頁、通知詳情只把內容包 SafeArea，錯誤／需登入等狀態仍在 SafeArea 內。`resizeToAvoidBottomInset` 與 chat_bottom_container 的鍵盤處理不變。
- **作者彈窗第二牌子**：解析改為稱號區塊內任何後代 `img`（例如被連結包住）；彈窗樓層無稱號且作者 uid 等於目前已驗證帳號時顯示 `CurrentAccountTitleBadge`（以作者 uid 為 key），他人樓層無資料就不顯示。已驗證的只有解析器與彈窗接線（樣本與合成樓層）；測試員截圖的名字被遮住，也沒有那一樓的原始 HTML，所以「截圖是本人樓層」「那一樓沒有稱號區塊」都只是假設，不是已確認的根因。他人樓層在真實頁面上為何沒有第二牌子，仍待測試員提供可重現的樓層。
- **首頁**：AppBar 的活動／簽到只在 `failure`（沒有問候卡）時出現，載入／刷新不再閃出。問候卡牌子改用 `homeGreetingBadgeLayout`：手機問候至少 148×字級，旁邊空間 ≥ 偏好 160–184 就並排，≥ 144 就用剩餘寬並排，否則放下方（160）；桌面 240 不變；手機日期行可兩行。紅包「暫無」改送 `HomepageDailyRedPacketCheckRequested`：不進 loading、只重抓 `forum.php` 並只更新紅包與 formHash，頁面重載／換帳號／文件 uid 不符時丟棄；下拉仍是整頁刷新。紅包文案三語縮短（「紅包：暫無」「紅包已領取」「登入領紅包」），說明留在 tooltip。
- **通知**：「未讀」改為 AppBar 切換鈕（選取 tonal 底色＋實心圖示、tooltip、`toggled` 語意），移除獨佔的篩選列。
- **設定**：除錯區 `ExpansionTile` 的 `tilePadding` 改為與其他列相同的 16。
- 手機維持精簡 `ForumCard`、桌面 ≥ 1100 才大卡（test169／170 不變）。
