# Linux 版第三階段（自動學習與輸入輔助）實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 fcitx5 版加入 Mac 智慧學習版第三階段的全部功能，行為與 Mac `7446fd0` 一致：
- 暫存詞兩段式學習、拆詞學習
- 候選字 `+`／`-`（含單字）
- 英文聯想（Tab）
- 數字快打（`` ` ``）與中文模式 `=` 直接算
- 常用句
- 文字範本、分類符號表（兩鍵選字）
- 許氏鍵盤數字進組字區、沒有標點的符號鍵打全形

**Architecture:** 同前兩階段。規則寫成 `src/SmartLearning/` 的純 C++ 模組（附 gtest，不 include fcitx）；`KeyHandler.cpp` 依模組回傳的計畫操作 grid 與狀態；`McBopomofo.cpp` 負責候選清單、設定、存檔計時器。

**Tech Stack:** C++20、CMake、GoogleTest、fcitx5 5.1、ICU（常用句斷句已依賴）、`ChineseNumbersLib`（上游既有）。

**Spec:** `docs/superpowers/specs/2026-11-23-linux-fcitx5-port-design.md`（Mac repo）。逐條行為以 fcitx repo 的 **`docs/phase3-mac-behavior.md`**（下稱「行為文件」）為準，每個 task 指出段落。`docs/phase2-mac-behavior.md` 與 `docs/file-formats.md` 仍適用。

## Global Constraints

- 行為基準是 Mac `smart-learning` commit `7446fd0`；行為文件與 Mac 原始碼衝突時以 Mac 為準。行為文件 §12 的 UNKNOWN 由實作者實測或追 Mac 原始碼後決定，並寫進報告。
- `src/SmartLearning/` 只依賴標準函式庫、引擎、`MandarinLib`、`ChineseNumbersLib`、ICU，不得 include fcitx 標頭。
- 共用檔案規則同 phase 1／2：
  - 每台只寫自己的檔，讀其他裝置一律經 `otherDevicesLearningFiles`（排除衝突副本）。
  - 自己的檔讀取失敗時維持 pending，不寫。
  - 使用者資料夾存在時，缺少的子資料夾當作空檔，由 `save()` 建立（final review 裁定）。
  - 單一共寫檔（`data.txt`、`exclude-phrases.txt`）寫入前重讀，並經 `writeFileAtomically`。
- 學習檔格式與 Mac 相容：
  - `learning/temporary/<裝置>.txt`：`值 讀音 時間`，30 天過期。
  - `learning/sentences/<裝置>.txt`：格式見行為文件 §5.6。
  - `learning/removed.txt`：本階段唯讀（行為文件 §8）。
  - Mac 寫暫存詞檔與常用句檔時沒有「本機檔載入前不寫」的保護，Linux 刻意加上。
- 新設定只有 `CommonSentencesEnabled`（`fcitx::Option<bool>`，預設 true），其餘功能照 Mac 無開關（行為文件 §9）。英文聯想跟隨 `SmartChineseEnglishSwitchEnabled`。
- 使用者可見字串用 `_()`，`po/zh_TW.po` 譯文照 Mac `zh-Hant.lproj/Localizable.strings`。
- 註解、文件只描述功能，不提及或比較其他輸入法產品；測試資料只用合成樣本。
- 建置與測試、CI、commit trailer 同 phase 2。

## Review Focus

1. **學習寫入 Mac 的 `data.txt` 時順序或內容錯了**（同讀音詞的先後、被排除過的詞被加回、整檔被截斷）：測試在 Task 1（`UserPhraseFile::learn` 的排序與排除規則、重讀後寫入）。
2. **一般打字被學習流程拖慢**：選字與送出時不得在按鍵路徑讀整個 data.txt；學習寫檔排到存檔計時器或一次性同步寫入，並量測。測試在 Task 2（送出 20 字的組字，學習路徑只呼叫一次檔案寫入）。
3. **暫存詞或常用句在另一台過期或被刪除後又被這台寫回來**：合併時尊重 removed.txt 與過期時間。測試在 Task 1、Task 6。
4. **反引號、Tab 在非預期狀態被吃掉**（例如組字區空白時在 App 裡按 Tab）：只在 Mac 會攔的狀態攔。測試在 Task 4、Task 7。
5. **數字快打的金額大寫或民國年算錯**：用 Mac 的格式清單逐項比對。測試在 Task 5。

---

### Task 1：`RemovedEntries`、`TemporaryPhraseStore`、`UserPhraseFile`

**Files:**
- Create: `src/SmartLearning/RemovedEntries.{h,cpp}`、`TemporaryPhrases.{h,cpp}`、`UserPhraseFile.{h,cpp}`，各自附 `*Test.cpp`
- Modify: `src/SmartLearning/CMakeLists.txt`、`src/LanguageModelLoader.cpp`（`addUserPhrase`／`removeUserPhrase` 改呼叫 `UserPhraseFile`）

**Interfaces:**
- `RemovedEntries`：行為文件 §8.2 的介面。`removedTime(kind, key) -> double`，0 表示沒被刪；60 秒重讀；唯讀。
- `TemporaryPhraseStore`：行為文件 §1.8 的類別介面。`add` 不直接寫檔，改設 `hasUnsavedChanges()` 由引擎計時器存；`kLifetime = 30*86400`；需注入 `wallNow`（暫存詞的時間要跨裝置比較，所以用牆上時間）。
- `UserPhraseFile`（namespace 函式）：
  - `bool learn(const std::filesystem::path& data, const std::filesystem::path& exclude, const std::string& value, const std::string& reading)`：行為文件 §1.5。
  - `bool write(...)`、`bool remove(...)`：§2.2。
  - 三者都先重讀再 `writeFileAtomically`，`remove` 讀取失敗不寫。

- [ ] **Step 1：寫會失敗的測試**
  - `learn`：
    - 新詞追加到檔尾。
    - 同讀音已有其他詞時，插到該讀音第一筆之前。
    - 已是第一筆時不改檔。
    - 在 exclude 裡的詞不加。
    - 行首有空白的行照 Mac 規則比對。
  - `TemporaryPhraseStore`：
    - 合併其他裝置的檔。
    - 30 天過期。
    - removed.txt 刪除時間 ≥ 詞的時間就排除（Review Focus 3）。
    - pending 時不寫。
    - `phrasesByReading` 的內容正確。
  - `RemovedEntries`：
    - 每行剛好 3 欄。
    - 空欄位保留。
    - 時間不是數字的行略過。

- [ ] **Step 2：跑測試，確認會失敗** — Run: `scripts/docker-build-test.sh`（ubt）；Expected: 編譯失敗

- [ ] **Step 3：照行為文件 §0.3、§1.4、§1.5、§2.2、§8 實作，並讓 `LanguageModelLoader` 改用 `UserPhraseFile`**

- [ ] **Step 4：跑測試，確認通過** — Expected: 新測試與既有測試全過

- [ ] **Step 5：Commit** — `git commit -m "SmartLearning: temporary phrases, removed entries and user phrase file edits"`

---

### Task 2：兩段式學習與拆詞學習接進 KeyHandler

**Files:**
- Create: `src/SmartLearning/LearnPhrase.{h,cpp}`、`LearnPhraseTest.cpp`
- Modify: `src/KeyHandler.{h,cpp}`（行為文件 §1.7 掛點）、`src/McBopomofo.{h,cpp}`（建立 `TemporaryPhraseStore`、`applyLearningFolder` 設定資料夾、存檔計時器納入、`setTemporaryPhrases` 餵進 LM）
- Test: `src/KeyHandlerSmartTest.cpp`

**Interfaces:**
- Consumes：Task 1 全部；`UserOverrideStore::mergedModel()`（`observationCount`、`candidateObservationCount`）
- Produces：行為文件 §1.8 的 `LearnAction`、`PlanLearnPickedPhrase`、`PlanLearnBrokenUpPhrase`、`PhrasesToLearnOnCommit`；`KeyHandler::setOnPhraseLearned(std::function<void()>)`（引擎收到後重載使用者詞庫並排程存檔）；KeyHandler 新增成員 `phrasesPickedInComposition_`，`reset()` 清除。

行為照行為文件 §0.1、§1.1–§1.3、§1.6：
- 門檻 `kLearnPhraseThreshold = 2`，看合併後的次數，包含當下這次選字。
- 4 字以上只能在「再打出來送出」時寫入。

`learn` 寫入 `data.txt` 時，比照 Mac 在選字或送出當下同步寫入。這是單次 I/O，Review Focus 2 量測的是「每次送出最多寫一次」。

**UNKNOWN 3 的決定：** 大寫字母送出的路徑不學，比照 Mac。

- [ ] **Step 1：寫會失敗的測試**
  - 純函式：
    - 單字不進暫存詞。
    - 兩字詞選一次進暫存詞，同處再選一次就 `kLearnUserPhrase`。
    - 拆詞（例：內建「許是」被選成「許氏」）第一次進暫存、第二次寫入。
    - 4 字詞只能在送出時寫入。
  - KeyHandler：
    - 選字後 `TemporaryPhraseStore::contains` 為真，暫存詞在下次組字優先出現。
    - 再打出來送出後，`data.txt` 有該行，暫存詞也移除。
    - 送出 20 字的句子只寫一次檔（Review Focus 2，以注入的寫檔計數器驗證）。

- [ ] **Step 2：跑測試，確認會失敗**

- [ ] **Step 3：實作並接線**

- [ ] **Step 4：跑測試，確認通過**

- [ ] **Step 5：Commit** — `git commit -m "Learn phrases in two steps, and learn broken-up phrases"`

---

### Task 3：候選字 `+`／`-`（含單字）

**Files:**
- Create: `src/SmartLearning/CandidateAdjustment.{h,cpp}`、`CandidateAdjustmentTest.cpp`
- Modify: `src/McBopomofo.cpp`（候選鍵處理，行為文件 §2.3 列出的五處差異）

**Interfaces:**
- Consumes：Task 1 `UserPhraseFile::write`／`remove`
- Produces：行為文件 §2.4 的判斷函式，例如 `CandidateAdjustmentKind ClassifyCandidateForAdjustment(const std::string& reading, const std::string& value)`，對應可提高、可排除、要響一聲三種結果

行為照行為文件 §2.1–§2.3。五處修正：
1. 拿掉「讀音必須含 `-`」的限制，讓單字也能用。
2. 符號、英文、`_` 開頭的讀音改成響一聲，不再安靜略過。
3. 全域索引改用 `globalCursorIndex()`，修正最後一頁算錯的問題。
4. 確認後重新 walk，讓組字區反映新排序。
5. 取消時還原原本反白的位置。

- [ ] **Step 1：寫會失敗的測試**：純函式涵蓋單字、多字詞、`_punctuation_`、`_literal_`、`_english_`、符號表讀音；對檔案的寫入用 Task 1 的函式另外測。

- [ ] **Step 2：跑測試，確認會失敗**

- [ ] **Step 3：實作五處修正**

- [ ] **Step 4：跑測試，確認通過**

- [ ] **Step 5：Commit** — `git commit -m "Raise or exclude single characters and phrases from the candidate list"`

---

### Task 4：英文聯想（Tab）

**Files:**
- Modify: `src/SmartLearning/EnglishWords.{h,cpp}`（`EnglishLexicon::wordsWithPrefix`、`EnglishWordStore::completions`）、`src/SmartLearning/MixedInput.{h,cpp}`（`PlanEnglishCompletion`）、`src/KeyHandler.cpp`（英文模式的 Tab、未完成讀音後的 Tab，KH:1188-1199、1177-1184）、`src/McBopomofo.cpp`（`setEnglishCompletionProvider`）
- Test: `EnglishWordsTest.cpp`、`MixedInputTest.cpp`、`KeyHandlerSmartTest.cpp`

**Interfaces:**
- `std::vector<std::string> EnglishLexicon::wordsWithPrefix(std::string_view lowercased, size_t limit) const`
- `std::vector<std::string> EnglishWordStore::completions(const std::string& prefix)`，排序照行為文件 §3.3：
  1. 打過兩次以上的字。
  2. 字典補完。
  3. 打過一次的字。
  - 跳字比對只套用在學過的字上，最多 20 個。
  - 字典補完的順序，Linux 用「長度短的優先，同長度依字母序」，屬刻意差異（UNKNOWN 4），寫進報告。
- `PlanEnglishCompletion`：行為文件 §3.6。

行為照行為文件 §3.1–§3.5：
- 組字區空白時按 Tab 一律放行給 App（Review Focus 4）。
- 沒有補完時響一聲。
- 選定的補完以單一 `_english_word` reading 放入組字區。

- [ ] **Step 1：寫會失敗的測試**
  - `ass` → associate、assume 在前面。
  - 學過兩次的 `associated` 用 `aocd` 也找得到。
  - 學過的字排在字典之前。
  - 組字區空白時按 Tab，`handle()` 回傳 false。
  - 許氏 `hel` 再按 Tab 出現 hello 的聯想。

- [ ] **Step 2：跑測試，確認會失敗**

- [ ] **Step 3：實作**

- [ ] **Step 4：跑測試，確認通過**

- [ ] **Step 5：Commit** — `git commit -m "English completions with Tab"`

---

### Task 5：`QuickNumbers`、中文模式 `=` 直接算

**Files:**
- Create: `src/SmartLearning/QuickNumbers.{h,cpp}`、`QuickNumbersTest.cpp`（連結 `ChineseNumbersLib`）
- Modify: `src/KeyHandler.cpp`（`=` 掛點，行為文件 §4.9；英文模式 isprint 分支後的 `_appendArithmeticResultAfterKey`，KH:1167）

**Interfaces:**
- `std::string NormalizeNumberCode(const std::string&)`（§4.2）
- `bool IsNumberCode(const std::string&)`（§4.3）
- `std::vector<std::string> QuickNumberCandidates(const std::string& code, std::time_t now)`（§4.4–§4.8，輸出順序逐項照 Mac）
- `std::optional<std::string> ArithmeticResult(const std::string& expressionBeforeEquals)`（§4.8–§4.9；全形與半形運算子、數字間的「。」當小數點）

金額大寫優先用 fcitx `ChineseNumbers`。若逐字比對發現和 Mac 不同（UNKNOWN 6），在本模組內補正，並列出差異。

- [ ] **Step 1：寫會失敗的測試**：照行為文件 §4.11 與使用說明範例逐條：
  - `2023.09.07`、`112.9.7`、`9/7` 的各種格式（日期固定注入）。
  - `12:30`。
  - `6548` → 6,548、陸仟伍佰肆拾捌元整、六千五百四十八、6,548元…
  - `10*15/6` → 25 等。
  - `（2＋3）＊3＝` → 15、`3。5＊2＝` → 7（Review Focus 5）。

- [ ] **Step 2：跑測試，確認會失敗**

- [ ] **Step 3：實作 `QuickNumbers`，並接上 `=` 的掛點**

- [ ] **Step 4：跑測試，確認通過**

- [ ] **Step 5：Commit** — `git commit -m "Quick numbers, and arithmetic in the Chinese mode"`

---

### Task 6：常用句

**Files:**
- Create: `src/SmartLearning/CommonSentences.{h,cpp}`、`CommonSentencesTest.cpp`（ICU 斷句）
- Modify: `src/KeyHandler.{h,cpp}`（行為文件 §5.5、§5.7：送出時記錄、組字中依標點後文字提示 tooltip、Tab 接上，且優先於英文聯想）、`src/McBopomofo.{h,cpp}`（`CommonSentencesEnabled` 設定、store 建立、資料夾、存檔計時器）、`po/zh_TW.po`（「Tab：後半句」等提示字串照 Mac）

**Interfaces:**
- 行為文件 §5.8 的 `CommonSentenceStore`：`record`、`completion(forTypedText)`、`setLearningFolder`、`save`、`hasUnsavedChanges`、`isLocalFilePending`、`reload`
- 規則常數照 §5.1：3 次、6–40 字（英文單字與數字串算 1）、90 天、每 3 次延長 30 天

- [ ] **Step 1：寫會失敗的測試**
  - 同一句送出 3 次後，打開頭 2 字有提示，按 Tab 接上後半句。
  - 5 字的句子不記。
  - 標點與 emoji 會斷句，空白不斷句。
  - 另一台的 removed.txt 刪除後不再提示（Review Focus 3）。
  - 過期與延長規則。
  - pending 時不寫。

- [ ] **Step 2：跑測試，確認會失敗**

- [ ] **Step 3：實作**

- [ ] **Step 4：跑測試，確認通過**

- [ ] **Step 5：Commit** — `git commit -m "Common sentences"`

---

### Task 7：反引號文字範本、數字快打候選、分類符號表

**Files:**
- Create: `src/SmartLearning/TextTemplates.{h,cpp}`、`SymbolTable.{h,cpp}`（含 `SymbolGrid`），各自附 Test
- Modify: `src/KeyHandler.{h,cpp}`、`src/InputState.h`（範本／符號表的 state，行為文件 §6.1、§6.4）、`src/McBopomofo.cpp`（候選清單：範本、數字快打、符號表兩段選擇）
- Modify: 引擎啟動時讀 `symbol-table.txt` 並 `setSymbolTable`；檔案不存在時用內建表（§6.3）

**Interfaces:**
- `TextTemplates`：解析 `代碼<Tab>內容`，`matches(query)` 依 §6.2 比對（UNKNOWN 7：非 ASCII 用 ICU 不分大小寫）
- `SymbolTable`：解析與內建表；`SymbolGrid`：§6.6 的「先選列、再選格」模型，選字鍵對應、Backspace 回選列、反白跟著標籤，欄數 = 選字鍵數（UNKNOWN 9）

行為照行為文件 §6：
- 反引號進入範本與數字快打。
- 在範本中再按反引號，或打標點後按 ↓，開啟符號表。
- 選範本或數字結果後送出。
- fcitx 介面用兩段清單模擬格狀：第一段直式清單選列，第二段橫式清單選格。
- 修正符號表重複符號旁會顯示讀音的問題（行為文件 §6.3 附帶發現）。

**UNKNOWN 8：** 若 fcitx5 5.1 沒有 `setCustomLabel`，用候選文字前綴模擬標籤，並寫進報告。

- [ ] **Step 1：寫會失敗的測試**：
  - 純模組：範本解析與比對、符號表解析、內建表、`SymbolGrid` 的兩鍵選字與 Backspace。
  - KeyHandler：照行為文件 §6.7 列出的 9 個 Mac 測試移植。
  - 組字區空白時按反引號的行為與 Mac 相同（Review Focus 4）。

- [ ] **Step 2：跑測試，確認會失敗**

- [ ] **Step 3：實作**

- [ ] **Step 4：跑測試，確認通過**

- [ ] **Step 5：Commit** — `git commit -m "Text templates, quick numbers and the categorized symbol table"`

---

### Task 8：許氏鍵盤數字進組字區、沒有標點的符號鍵打全形

**Files:**
- Modify: `src/KeyHandler.cpp`（行為文件 §7.1 KH:1578-1597、§7.2 KH:1645-1652）
- Test: `src/KeyHandlerSmartTest.cpp`

**Interfaces:** 無新介面。§7.3 若有純函式就放進 `MixedInput`。

- [ ] **Step 1：寫會失敗的測試**：
  - 許氏組字區有中文時打 `2026`，以 `_numpad_` 進入組字區，送出為半形數字。
  - 許氏的 `/` 等沒有標點對應的鍵，在中文後打全形，在英數後打半形。

- [ ] **Step 2：跑測試，確認會失敗**

- [ ] **Step 3：實作**

- [ ] **Step 4：跑測試，確認通過**

- [ ] **Step 5：Commit** — `git commit -m "Digits in the composition with the Hsu keyboard, and full-width symbols for keys without punctuation"`

---

### Task 9：打包 learning.3、更新說明、sindy-Mint 實測

**Files:** `CMakeLists.txt`（版本 `-learning.3`）、`README.md`、`docs/acceptance-phase3.md`

- [ ] **Step 1：打包**（同 phase 2），產生 `fcitx5-mcbopomofo-smart-learning_3.1.1-learning.3_amd64.deb`

- [ ] **Step 2：安裝到 sindy-Mint 並 `fcitx5 -rd`**（同 phase 2 Task 9）

- [ ] **Step 3：實機驗收**：由 controller 用 xdotool 在 xed 實測，逐項記錄到 `docs/acceptance-phase3.md`。
  - 驗收項目：
    1. 暫存詞：選一次後下次優先出現；再打出來送出後寫入 `data.txt`。
    2. `+`／`-` 可用在單字。
    3. `ass`＋Tab 出現英文聯想。
    4. `` ` `` 後打 `6548`，出現各種金額格式。
    5. `（2＋3）＊3＝`。
    6. 常用句：送出 3 次後按 Tab 接上後半句。
    7. 文字範本、符號表兩鍵選字。
    8. 許氏數字進組字區。
  - 測完清掉測試寫入的學習資料：
    - 先 `fcitx5-remote -e`。
    - 只扣掉測試加入的行，不整檔刪除。
    - 重新啟動 fcitx5。

- [ ] **Step 4：Commit 並推送**（不打 tag、不發 release）
