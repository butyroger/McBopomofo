# 小麥注音智慧學習版 Linux 版設計

日期：2026-11-23

## 目的與動機

把 `butyroger/McBopomofo` 的 `smart-learning` 分支（目前 3.1.1-learning.23）做成 Linux 版，給使用者自己的桌機／筆電使用。Linux 上已有的注音輸入法（包含官方 `fcitx5-mcbopomofo`）都缺少智慧學習版的功能，用起來不順手。目標是在 Linux 上得到「跟 Mac 上一樣的小麥」。

## 目標

1. Linux Mint（Cinnamon）與 Ubuntu（GNOME，Wayland 與 X11）上可安裝、可日常使用。
2. 智慧學習版的功能全部搬過去（清單見下），行為與 Mac 版一致。
3. 詞庫資料夾與 Mac 版**檔案格式完全相容**：同一個資料夾經由同步工具（建議 Synology Drive）在 Mac 與 Linux 間共用，兩邊的學習結果互通。
4. 新功能的邏輯寫成不依賴 fcitx5 的純 C++ 共用模組，附單元測試，將來 Mac 版可逐步改用。

## 非目標

- 不改動 Mac 版（第一階段完全不碰 `smart-learning` 的 Mac 程式碼；共用模組之後再由 Mac 版擇機採用，另案處理）。
- 不支援 ibus、不支援 Linux 以外的平台。
- 不搬「安全輸入提醒」（macOS 專屬問題）。
- 不負責同步：輸入法只讀寫一個本機資料夾，同步交給 Synology Drive／Syncthing 等外部工具。
- 不上架發行版官方套件庫；產出自用 `.deb` 即可。

## 反目標（做了也算失敗的情況）

- Linux 寫出的檔案讓 Mac 版讀錯、覆蓋或弄丟 Mac 的學習資料（反之亦然）。
- 打字延遲明顯變慢，或組字中漏字、重複字。
- 共用模組偷偷依賴 fcitx5，導致 Mac 版將來無法採用。
- 為了 Linux 去改動 Mac 版的檔案格式。

## 限制與已知事實

- 上游 `openvanilla/fcitx5-mcbopomofo`（MIT）已有：同一套 C++ 引擎（`src/Engine/`：gramambular2、Mandarin、McBopomofoLM、UserOverrideModel 等）、C++ 版 `KeyHandler.cpp`（約 69KB）、`InputState.h`、`McBopomofo.cpp`（fcitx5 addon 本體）、`InputMacro`、`NumberInputHelper`、`ChineseNumbers`、`DictionaryService`、`LanguageModelLoader`、`TimestampedPath`。
- Mac fork 相對上游（合併點 `e65f276`）在 `Source/` 增加約 5,500 行，主要在：
  - `KeyHandler.mm`（+1,082）、`LanguageModelManager.mm`（+548）
  - Swift：`VocabularyManager`、`QuickNumbers`、`CommonSentences`、`EnglishWords`、`FloatingComposition`、`InputState`、`Preferences`、`InputMethodController`
  - 引擎：`McBopomofoLM.cpp`（+190）、`UserOverrideModel.cpp`（+115）及其測試
- 引擎層的 fork 修改是 C++，可直接移植；Swift／Objective-C++ 部分需以 C++ 重寫。
- fcitx5 的候選字視窗由 fcitx5 自己的 UI（classicui／kimpanel）繪製，輸入法無法完全掌控外觀。
- Ubuntu GNOME Wayland 需安裝 GNOME 擴充套件（Input Method Panel／kimpanel）才能正確顯示候選字視窗。

## 詞庫資料夾（必須與 Mac 版相容）

以 Mac 版程式碼為準（`LanguageModelManager.mm`、`CommonSentences.swift`、`EnglishWords.swift` 等），Linux 版必須逐一對齊：

- `data.txt`、`exclude-phrases.txt`、`phrases-replacement.txt`、`text-templates.txt`、`symbol-table.txt`
- `learning/`：選字記憶、`temporary/`（暫存詞，30 天過期）、`english/`（打過的英文字）、`sentences/`（常用句）、`removed.txt`（跨機刪除紀錄）
- 每台機器各寫自己的檔案（以裝置 ID 區分，Mac 用 `UserOverrideModelDeviceID`）；Linux 產生並保存自己的裝置 ID，讀取時合併所有裝置的檔案。
- 檔案有變動時自動重新載入（Mac 版已拿掉手動重新載入）。
- 偏好設定可指定詞庫資料夾位置，預設 `~/.local/share/fcitx5/mcbopomofo/`。

實作前，第一步是從 Mac 版程式碼整理出一份**檔案格式規格**（每個檔名、每行格式、裝置 ID 命名、過期與合併規則），放在 repo 中，並做相容測試。repo 是公開的，測試資料只能用**合成或去識別化的樣本**（依 Mac 版程式碼產生格式相同的檔案），不得放入使用者真實的打字紀錄。

**詞庫位置（2026-11-23 已遷移）**：詞庫已從 iCloud Drive 搬到 Synology Drive 的 `Drive/McBopomofo`（NAS `/volume1/homes/roger/Drive/McBopomofo`），Mac Studio 為 `~/SynologyDrive/McBopomofo`，MacBook Neo 為 `~/Library/CloudStorage/SynologyDrive-neo/McBopomofo`。Linux 端以 Synology Drive Client 同步同一資料夾，在偏好設定指向該路徑。Mac 版對 iCloud `.icloud` 佔位檔的處理在新位置不會用到，但不需移除。

**同步衝突副本**（實作者決定、已定）：讀取「所有裝置的檔案」時，排除同步工具產生的衝突副本（Synology Drive 的 `*_Conflict*`、Syncthing 的 `*.sync-conflict-*`）。

**單一共寫檔案**（`data.txt`、`exclude-phrases.txt`、`removed.txt`、`text-templates.txt` 等，Mac 以 atomic write 整份覆寫）：使用者不會同時在兩台機器上打字，因此整份覆寫可接受。為保險起見（設計者的判斷），Linux 每次寫入前先重讀檔案、以行為單位合併本機尚未寫出的變更再 atomic write；刪除以 `removed.txt`／exclude 的紀錄為準，不以「檔案中消失」判斷。

## 做法比較

1. **fork `fcitx5-mcbopomofo`，功能直接寫進它的 KeyHandler**：最快，但之後 Mac 每加一個功能，Linux 要重寫一次，兩邊會越差越多。
2. **先把 Mac 版功能抽成共用 C++ 核心，兩邊都改用**：長期最乾淨，但要大改每天在用的 Mac 版，Linux 第一版會延後很多，風險高。
3. **（選定）fork `fcitx5-mcbopomofo`，新功能寫成獨立純 C++ 模組**：Linux 版較快出來、Mac 版不動，模組附測試，日後 Mac 可逐一換用。代價是比做法 1 多花一些力氣把邏輯切乾淨。

使用者選擇做法 3。

## 架構

新 repo：`butyroger/fcitx5-mcbopomofo`（fork 自 `openvanilla/fcitx5-mcbopomofo`），開發分支 `smart-learning`。

- `src/Engine/`：套用 Mac fork 對 `McBopomofoLM`、`UserOverrideModel` 的修改（含測試）。
- `src/SmartLearning/`（新）：純 C++17 共用模組，只依賴 C++ 標準函式庫（必要時可用 ICU，因上游已依賴），**不得 include 任何 fcitx 標頭**。每個模組附 GoogleTest 測試。預定模組：
  - 學習資料存取（暫存詞、選字記憶、英文字、常用句、removed.txt、裝置 ID、過期規則）
  - 中英判斷（智慧中英切換、英文接中文自動轉回、中英自動空格、英數後半形標點、英文大小寫修正）
  - Esc 清除亂碼（字尾修剪規則）
  - 英文聯想（字首與跳字比對、打過兩次以上優先）
  - 數字快打（日期／時間／金額／四則運算各格式）與中文模式算式
  - 常用句（記憶、提示、Tab 接上）
  - 文字範本、符號表解析
- `src/KeyHandler.cpp`、`InputState.h`：接上共用模組，對齊 Mac `KeyHandler.mm` 的行為。
- `src/McBopomofo.cpp`：fcitx5 介面層（按鍵、preedit、候選字、選單、設定）。
- 管理詞彙視窗：獨立 Qt 程式（fcitx5 設定工具本身用 Qt，KDE／Mint／Ubuntu 皆可執行），由輸入法選單開啟；直接讀寫詞庫資料夾。
- 偏好設定：使用 fcitx5 原生設定（`fcitx5-configtool`），新增智慧學習版的各選項，選項名稱與預設值對齊 Mac 版 `Preferences.swift`。
- 使用說明：沿用 Mac 版 `UserGuide.html` 內容，改寫 Linux 相關段落（快速鍵、安裝、詞庫位置），由選單開啟瀏覽器。

## 功能清單與搬移方式

全部搬，依下列階段交付；每階段結束都要能日常使用。

**階段 1：可日常打字的基礎**
- 上游 fcitx5-mcbopomofo 建置與安裝（`.deb`），確認 Mint 與 Ubuntu 可用
- 引擎修改移植、詞庫資料夾相容（讀寫 data.txt、exclude、選字記憶、自訂資料夾路徑、自動重新載入）
- 偏好設定基礎值對齊 Mac（使用者目前設定：許氏鍵盤、選字鍵 `asdfghjkl`、空白選字、Esc 清組字區等）
- 數字鍵盤 Enter 等同 Return、Caps Lock 當一般鎖定

**階段 2：中英混打**
- 智慧中英切換與中英提示／模式圖示、英文後直接打中文自動轉回
- 中英自動空格、英數後半形標點（Control 強制全形）、英文大小寫修正
- Esc 清除亂碼（含連按兩下清全部、偏好設定開關）

**階段 3：自動學習與輸入輔助**
- 暫存詞（兩段式學習）、斷開詞學習、候選字 `+`／`-` 調整
- 英文聯想（Tab）、數字快打（`` ` ``）、中文模式算式（`=`）、無對應標點的符號鍵
- 常用句（三次記住、Tab 接上、三個月遺忘）
- 文字範本、符號表與 emoji（兩鍵選符號）、快速切換鍵盤配置

**階段 4：視窗與周邊**
- 管理詞彙視窗（六個分頁：中文詞彙、排除詞彙、英文詞彙、常用句、暫存詞、文字範本）
- 浮動組字窗（在 Linux 上的對應：對指定程式改用不送 preedit、送出時才 commit 的模式；實際對應方式由實作評估）
- 候選字視窗主題：改用 fcitx5 主題，提供一組接近 Mac 版的建議主題設定
- 使用說明、Mac 版「關於」對應的連結

## 已定的實作決策（設計者的判斷，使用者可推翻）

- **目標版本**：Ubuntu 24.04 LTS 與 Linux Mint 22.x（同為 noble 基底），一份 `.deb`；用該版本的 fcitx5 與 Qt6。
- **行為基準**：以 Mac `smart-learning` commit `7446fd0`（3.1.1-learning.23）為準。之後 Mac 新增的功能不在本次範圍，另案追加，屆時優先寫進共用模組。
- **偏好設定預設值**：完整對照 `Preferences.swift` 全部設定鍵；Linux 預設值採用使用者 Mac 目前的值（2026-11-23 `defaults read` 匯出：許氏鍵盤 `KeyboardLayout=2`、選字鍵 `asdfghjkl`、空白選字、`EscTrimsMistypedText=1`、`SmartChineseEnglishSwitchEnabled=1`、`ShiftEnterEnabled=1`、`ControlEnterOutput=1`、`MoveCursorAfterSelectingCandidate=1`、`RepeatedPunctuationToSelectCandidateEnabled=1`、`CandidateListTextSize=64`、`CandidatePanelTheme=1`、垂直候選字等），其餘鍵用 Mac 程式碼預設值。macOS 專屬鍵（`BasisKeyboardLayout`、`FunctionKeyKeyboardLayout`、Command 切換輸入源、更新檢查、AddPhraseHook 路徑）不搬。
- **修飾鍵對應**：Mac 的 Option → Linux 的 Alt；Mac 的 Command → Linux 的 Super。凡 Mac 版「按著 Command 時輸入法不處理、交給 App」的判斷，Linux 對 Super 與 Ctrl+Alt 組合同樣放行；Control 的行為（如 Control 打全形標點）不變。

## 留給實作者決定的事

- 每個共用模組的 API 形狀與檔案切分。
- 浮動組字窗在 fcitx5 上的具體做法；若做不到與 Mac 等價，記錄差異並回報。
- 符號表「鍵位標籤跟著亮點走」在 fcitx5 候選字 UI 上能做到的程度。
- Qt 版管理詞彙視窗的版面細節。
- 測試以 Mac 版現有測試（`KeyHandlerTest`、`UserOverrideModelTest`、`McBopomofoLMTest` 等）的案例為基準移植，行為以 Mac 版為準。

## 公開文字規範

README、CHANGELOG、release 說明、程式註解只描述功能本身，不比照、不提及其他輸入法產品。
