# Linux 版第四階段（視窗與周邊）實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 fcitx5 版補上 Mac 智慧學習版的視窗與周邊功能：
- 管理詞彙視窗（Qt6，六個分頁）
- 浮動組字窗（指定程式不送 preedit）
- 候選字面板主題
- 使用說明與「關於」
- 選單補齊

**Architecture:**
- 詞彙管理員是獨立的 Qt6 Widgets 程式 `mcbopomofo-vocabulary`。它連結 `SmartLearningLib`，所有讀寫都透過共用模組。
- 管理員和輸入法是兩個程序。規則：本機檔被外部改動時，以檔案層級逐鍵合併；刪除只看 `removed.txt`；管理員寫完後用 D-Bus `ReloadAddonConfig` 通知輸入法。
- 浮動組字窗只在 `McBopomofo.cpp` 的 preedit 判斷加上程式清單。

**Tech Stack:** C++20、CMake、GoogleTest、fcitx5 5.1、Qt6 Widgets（Ubuntu 24.04／Mint 22 的 `qt6-base`）、gettext。

**Spec:** `docs/superpowers/specs/2026-11-23-linux-fcitx5-port-design.md`（Mac repo）。逐條行為以 fcitx repo 的 **`docs/phase4-mac-behavior.md`**（下稱「行為文件」）為準，每個 task 指出段落。

## Global Constraints

- 行為基準：Mac `smart-learning` `7446fd0`。行為文件與 Mac 原始碼衝突時以 Mac 為準，§8 決策照本計畫「決策」一節。
- `src/SmartLearning/` 不得 include fcitx 或 Qt 標頭。Qt 程式不得 include fcitx 標頭、不連 Fcitx5Core。
- 共用檔案規則同 phase 1–3：
  - 每台只寫自己的檔，讀別台的檔一律經 `otherDevicesLearningFiles`。
  - 自己的檔載入前不寫。
  - 單一共寫檔寫入前重讀，並經 `writeFileAtomically`。
  - 刪除以 `removed.txt` 與 exclude 檔為準。
- 管理員寫 `data.txt`、`exclude-phrases.txt`、`text-templates.txt` 時，檔案不存在就不寫，並顯示「找不到檔案，詞庫資料夾可能還在同步」（決策 D6）。
- 使用者可見字串照 Mac `zh-Hant.lproj/Localizable.strings`，經 gettext（`po/zh_TW.po`，Qt 程式用同一個 domain）。
- 註解、文件只描述功能，不提及或比較其他輸入法產品；測試資料只用合成樣本。
- 建置與測試、CI、commit trailer 同 phase 3。建置映像要加 `qt6-base-dev`，`.deb` 要加 Qt6 Widgets 相依。

## 決策（controller 裁定，使用者可推翻）

- D1：採 A，檔案層級合併加 `ReloadAddonConfig` 通知，不做 IPC。
- D2：程式名稱 `mcbopomofo-vocabulary`。單一視窗用 `QLocalServer`，再次開啟時帶到前景並重新整理。
- D3：從桌面選單開啟、設定檔沒有 `DeviceID` 時，唯讀開啟並顯示提示。
- D4：不加 OpenCC，讀音帶出不做簡轉繁，差異寫進使用說明。
- D5：gettext。
- D6：檔案不存在不建立。
- D7：視窗重新取得焦點時重新整理，不用 `QFileSystemWatcher`。
- D8：浮動組字窗清單放在 fcitx 設定（`FloatingCompositionPrograms`），同時有選單切換。
- D9：切換浮動組字窗時，組字中的文字先送出（照 Mac）。
- D10：隨套件提供 `mcbopomofo-light`、`mcbopomofo-dark` 兩個 classicui 主題。不附圖片、不寫死字型。顏色照 Mac 面板原始碼的色值。
- D11：不另做半形標點快速鍵。
- D12：「關於」做成使用說明的一節，選單開到該節。
- D13：Linux 使用說明的專案頁面與問題回報連 Linux 版 repo `butyroger/fcitx5-mcbopomofo`，另附 Mac 版連結。
- D14：不另加「偏好設定」選單項目，fcitx 系統匣已有「設定」。

## Review Focus

1. **管理員的修改被輸入法蓋掉，或刪掉的項目又帶舊次數回來**（行為文件 §1.5 的 1–3）：測試在 Task 1，兩個 store 實例模擬兩個程序。
2. **同步還沒完成時，管理員或輸入法寫出空檔或第三台裝置的檔**：測試在 Task 1、Task 3（檔名必須與輸入法相同；DeviceID 空白時唯讀）。
3. **浮動組字窗把一般程式也改成不送 preedit**：測試在 Task 5（`program()` 為空字串或不在清單時維持原樣）。
4. **Qt 程式沒裝 Qt 的機器上建置失敗**：CMake 選項 `ENABLE_VOCABULARY_MANAGER`，找不到 Qt6 就關閉，在 Task 3 驗證。
5. **選單動作在 Plain Bopomofo 模式出現不該有的項目，或兩個模式都缺**：測試在 Task 6（以行為文件 §5 為準）。

---

### Task 1：共用模組的管理 API 與跨程序合併

**Files:**
- Modify: `src/SmartLearning/RemovedEntries.{h,cpp}`、`EnglishWords.{h,cpp}`、`CommonSentences.{h,cpp}`、`TemporaryPhrases.{h,cpp}`，以及各自的 Test
- Modify: `src/McBopomofo.cpp`：`reloadConfig()` 強制所有 store 重新檢查；`activate` 時若 removed.txt 的 stamp 改變，就 `reload()`

**Interfaces（行為文件 §1.6「需要在共用模組新增的 API」1–4、§1.5 A）：**
- `RemovedEntries::add(kind, key, double wallNow)`、`remove(kind, key)`：
  - 先重讀，輸出前依行排序，時間取整數秒，atomic 覆寫。
  - 讀不到檔時不寫。
- `EnglishWordStore::allWords()`、`add(word)`、`remove(word)`，照 Mac `EW:191-215`。
- `CommonSentenceStore::allEntries()`、`add(sentence)`、`remove(sentence)`，照 `CS:224-257`。
- `TemporaryPhraseStore::allPhrases()`、`forget(value, reading)`。
- 三個 store 都要：
  - 記住本機檔的 stamp。
  - 在 reload 與 save 之前，stamp 不同就重讀本機檔並逐鍵合併：
    - 英文字次數取大。
    - 常用句次數、`lastUsed` 取大，`pinned` 取聯集。
    - 暫存詞時間取大。
  - 丟掉已記在 removed.txt 的本機項目。

- [ ] **Step 1：寫會失敗的測試**
  - 兩個 `EnglishWordStore` 實例共用同一資料夾：A `add("zyxwv")` 並存檔後，B 存檔，A 加的字仍在。
  - 常用句：A 刪除後，B 再 `record` 同一句，次數從 1 開始。
  - `RemovedEntries::add` 的輸出排序與整數時間。
  - `forget` 會寫 removed.txt；Task 2 的 `remove` 不會。
  - pending 時三個 API 都不寫。
- [ ] **Step 2：跑測試，確認會失敗**
- [ ] **Step 3：實作**
- [ ] **Step 4：跑測試，確認通過**
- [ ] **Step 5：Commit** — `SmartLearning: management APIs and merging changes from another process`

---

### Task 2：單一行編輯與讀音帶出

**Files:**
- Create: `src/SmartLearning/VocabularyFile.{h,cpp}`、`ReadingExtraction.{h,cpp}`，各附 Test

**Interfaces：**
- `VocabularyFile`：
  - `bool replaceOrAppendLine(path, newLine, std::optional<std::string> oldLine)`
  - `bool removeLines(path, const std::vector<std::string>& lines)`
  - 規則照行為文件 §1.4：保留註解與順序；重複行只刪一行；檔案不存在不寫（D6）；寫入經 `writeFileAtomically`。
- `ReadingExtraction`：`std::optional<std::string> ExtractReading(McBopomofoLM&, const std::string& phrase)`，照行為文件 §1.2 第 9 點的貪婪比對。D4：不做簡轉繁。

- [ ] **Step 1：寫會失敗的測試**：保留註解、只刪一行、不存在不寫、多音字取第一個、找不到時回 nullopt。
- [ ] **Step 2–4：失敗 → 實作 → 通過**
- [ ] **Step 5：Commit** — `SmartLearning: line edits for the vocabulary files, and reading extraction`

---

### Task 3：Qt 詞彙管理員：程式骨架與三個檔案分頁

**Files:**
- Create: `src/VocabularyManager/`（`main.cpp`、`MainWindow.{h,cpp}`、各分頁）、`data/mcbopomofo-vocabulary.desktop`
- Modify:
  - 頂層 `CMakeLists.txt`（`ENABLE_VOCABULARY_MANAGER`；CPack Depends 加 `libqt6widgets6`）
  - `docker/Dockerfile.ubuntu2404`（加 `qt6-base-dev`）
  - `.github/workflows/*`（CI 安裝 Qt6）

**分頁：** 中文詞彙、排除詞彙、文字範本（行為文件 §1.2、§1.3.1、§1.3.2、§1.3.6）。

**啟動參數：**
- `--data-folder`、`--device-id`。
- 沒帶參數時讀 `~/.config/fcitx5/conf/mcbopomofo.conf` 的 `UserDataFolder`、`DeviceID`，並經 `resolveUserDataFolder`。
- `DeviceID` 空白時唯讀（D3）。
- 單一視窗用 `QLocalServer`（D2）。
- 視窗取得焦點時重新整理（D7）。
- 寫完後呼叫 D-Bus `org.fcitx.Fcitx5` `/controller` `org.fcitx.Fcitx.Controller1.ReloadAddonConfig("mcbopomofo")`，失敗就忽略。

- [ ] **Step 1：寫會失敗的測試**：可測的邏輯放在不含 Qt 的 helper（例如設定檔解析、裝置檔名與輸入法一致），以 gtest 測。
- [ ] **Step 2–4：失敗 → 實作 → 通過**（另外確認 `-DENABLE_VOCABULARY_MANAGER=Off` 時能建置）
- [ ] **Step 5：Commit** — `Vocabulary manager: phrases, excluded phrases and text templates`

---

### Task 4：Qt 詞彙管理員：英文詞彙、常用句、暫存詞，接上選單

**Files:**
- Modify: `src/VocabularyManager/*`
- Modify: `src/McBopomofo.{h,cpp}`：新增「管理詞彙…」動作，兩個模式都顯示；用 `fcitx::startProcess` 帶 `--data-folder`、`--device-id` 開啟

**分頁：** 行為文件 §1.3.3–§1.3.5，透過 Task 1 的 API。

- [ ] **Step 1：寫會失敗的測試**：選單動作存在（engine 層可測的部分），以及透過 Task 1 API 的分頁 model 邏輯（不含 Qt 的 helper）。
- [ ] **Step 2–4：失敗 → 實作 → 通過**
- [ ] **Step 5：Commit** — `Vocabulary manager: English words, common sentences and temporary phrases`

---

### Task 5：浮動組字窗

**Files:**
- Create: `src/SmartLearning/FloatingComposition.{h,cpp}`（純函式，附 Test）
- Modify: `src/McBopomofo.{h,cpp}`：
  - 新增 `FloatingCompositionPrograms` 設定（`Option<std::vector<std::string>>`，預設空，D8）。
  - 新增選單「此程式使用浮動組字窗」（checkable），切換前先送出組字（D9）。
  - 三處 `useClientPreedit` 判斷改用 helper。
- Modify: `po/zh_TW.po`

行為照行為文件 §2.3–§2.5。`program()` 為空字串時，不顯示選單項目，也不套用。

- [ ] **Step 1：寫會失敗的測試**：
  - 清單內的程式不用 client preedit。
  - 空字串和不在清單內的程式維持原樣。
  - 切換清單的增刪。
- [ ] **Step 2–4：失敗 → 實作 → 通過**
- [ ] **Step 5：Commit** — `Floating composition for chosen programs`

---

### Task 6：選單補齊、使用說明、關於、主題

**Files:**
- Modify: `src/McBopomofo.{h,cpp}`：新增「編輯文字範本」「編輯符號表」「使用說明」「關於小麥注音…」，依行為文件 §5 決定在哪些模式顯示。
- Create:
  - `data/user-guide.html`（由 Mac `Source/UserGuide.html` 改寫，依行為文件 §4.2，含「關於」一節，D12/D13）
  - `data/themes/mcbopomofo-light/theme.conf`、`data/themes/mcbopomofo-dark/theme.conf`（D10，§3.3）
- Modify: CMake 安裝規則、`README.md`

使用說明以 `xdg-open file:///usr/share/fcitx5-mcbopomofo/user-guide.html` 開啟；「關於」加 `#about`。

- [ ] **Step 1：寫會失敗的測試**：選單動作清單依模式正確（engine 層可測的部分）；安裝規則以 `cpack` 後 `dpkg -c` 檢查檔案存在。
- [ ] **Step 2–4：失敗 → 實作 → 通過**
- [ ] **Step 5：Commit** — `Menu items for templates, symbol table, user guide and about; candidate panel themes`

---

### Task 7：打包 learning.4、sindy-Mint 實測、Mac 共用模組採用計畫

**Files:** `CMakeLists.txt`（`-learning.4`）、`README.md`、`docs/acceptance-phase4.md`、`docs/mac-adoption-plan.md`

- [ ] **Step 1：打包並安裝到 sindy-Mint**。
- [ ] **Step 2：實機驗收**，由 controller 用 xdotool 加截圖：
  - 管理詞彙六個分頁可讀可改。
  - 加入英文字後打字不會被蓋掉。
  - 浮動組字窗對 xed 生效、對其他程式不變。
  - 選單各項。
  - 使用說明開啟。
  - 主題可在 classicui 選用。
  - 測完只扣掉測試寫入的內容，並與備份比對。
- [ ] **Step 3：寫 `docs/mac-adoption-plan.md`**：列出 `src/SmartLearning/` 各模組對應 Mac 的 Swift／ObjC++ 檔，說明 Mac 改用 C++ 共用模組的順序、風險與測試方式。只寫文件，不改 Mac 程式。
- [ ] **Step 4：Commit 並推送**（不打 tag、不發 release）
