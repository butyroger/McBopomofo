# Linux 版第二階段（中英混打＋鍵盤快速切換）實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 fcitx5 版加上 Mac 智慧學習版的中英混打全套行為與「標準／許氏鍵盤」快速切換，行為與 Mac `7446fd0` 一致。中英混打包含：智慧中英切換、英文後直接接中文、中英自動空格、英數後半形標點、英文大小寫修正、Esc 清亂碼、中英模式提示。

**Architecture:** 規則全部寫成 `src/SmartLearning/` 的純 C++ 函式和類別，附 gtest。輸入是 readings、游標、按鍵；輸出是「要刪幾個、要插什麼」的計畫。`KeyHandler.cpp` 只負責依計畫操作 grid 和狀態旗標。`McBopomofo.cpp` 負責設定、狀態列 action、提示，以及英文字學習檔的延遲存檔。

**Tech Stack:** C++20、CMake、GoogleTest、fcitx5 5.1（Ubuntu 24.04／Mint 22）、`wamerican` 字典（`/usr/share/dict/american-english`）。

**Spec:** `docs/superpowers/specs/2026-11-23-linux-fcitx5-port-design.md`（Mac repo）。功能逐條行為以 fcitx repo 的 **`docs/phase2-mac-behavior.md`**（下稱「行為文件」，每條附 Mac 程式碼行號）為準；本計畫每個 task 指出要實作的段落。

## Global Constraints

- 行為基準是 Mac `smart-learning` commit `7446fd0`；行為文件與 Mac 原始碼衝突時，以 Mac 原始碼為準。
- `src/SmartLearning/` 只依賴 C++ 標準函式庫、引擎函式庫和 `MandarinLib`，不得 include 任何 `fcitx` 標頭。
- 詞庫檔案格式與 Mac 相容：`learning/english/<裝置ID>-<名稱>.txt`，每行 `word<TAB>count`，排序後整檔 atomic 重寫；`learning/removed.txt` 每行 `kind<TAB>key<TAB>time`，本階段唯讀。
- 讀取其他裝置的檔一律經過 `otherDevicesLearningFiles`（排除衝突副本）；只寫自己的檔；本機檔載入前不寫。
- 新設定（皆 `fcitx::Option<bool>`，名稱與 Mac 相同）：
  - `SmartChineseEnglishSwitchEnabled`=true
  - `AutoSpaceBetweenChineseAndEnglish`=true
  - `HalfWidthPunctuationAfterEnglish`=true
  - `FixEnglishWordCase`=true
  - `EscTrimsMistypedText`=true
  - `ChineseEnglishSwitchReminderEnabled`=true
  - `ShowChineseEnglishModeIcon`=true
  - `ShowFullHalfWidthModeIcon`=false
- 使用者可見字串用 `_()`，`po/zh_TW.po` 的繁中譯文照 Mac `zh-Hant.lproj/Localizable.strings`。
- 註解、README、說明只描述功能，不提及或比較其他輸入法產品；測試資料只用合成樣本。
- 建置與測試：在 ubt 上 `DOCKER="sudo docker" scripts/docker-build-test.sh`（rsync 同 phase 1）。CI 用 `gh run list -R butyroger/fcitx5-mcbopomofo`。
- Commit trailer 同 phase 1。

## Review Focus

1. **打中文的日常速度和結果不能變**：smart 開著時，一般注音（含 Hsu 的字母聲調鍵）照常組字；只有行為文件 §1.3 的四種情況才轉英文。測試在 Task 4（標準與 Hsu 各一句長句：組字結果與關閉 smart 時相同）。
2. **很短的英文剛好是合法注音**（Hsu `a`+空白 →「疵」）：照 Mac 維持中文，不得「猜」成英文。測試在 Task 4。
3. **英文學習檔還沒同步下來或讀取失敗**：不能把英文字檔覆蓋成只有本機新字的版本，規則同選字記憶。測試在 Task 2。
4. **游標不在句尾**時，插入、自動空白、Esc 修剪都以游標為準，游標後的內容不動。測試在 Task 1（純函式）與 Task 6（Esc）。
5. **字典檔不存在**（使用者沒裝 `wamerican`）：`isWord` 只靠學習字和內建表，不當機、不卡住打字。測試在 Task 2。

---

### Task 1：`MixedInput` 純函式：reading 分類、自動空白、Esc 修剪計畫

**Files:**
- Create: `src/SmartLearning/MixedInput.{h,cpp}`、`src/SmartLearning/MixedInputTest.cpp`
- Modify: `src/SmartLearning/CMakeLists.txt`

**Interfaces（namespace `McBopomofo::SmartLearning`）：**
- `inline constexpr char kAutoSpaceReading[] = "_literal_ ";`
- `bool IsEnglishReading(const std::string& r)`、`bool IsHalfWidthAlphanumericReading(const std::string& r)`、`bool IsChineseReading(const std::string& r)`：行為文件 §0.2，逐條照搬。
- `bool IsLetterReading(const std::string& r)`：`_literal_` 後接 1 個 ASCII 字母。
- `std::string TrailingLetters(const std::vector<std::string>& readings, size_t cursor)`：游標前連續 `IsLetterReading` 的字母，不含 `_english_`。
- `bool AutoSpaceNeeded(const std::vector<std::string>& readings, size_t cursor, bool beforeEnglish)`：§3.1 規則 2–3（偏好與輸入模式由呼叫端判斷）。
- `bool ShouldRemoveAutoSpaceAfterDeletingEnglish(const std::vector<std::string>& readings, size_t cursor)`：§3.2 規則 1–2；readings 是刪掉英文之後的狀態。
- `size_t PlanTrimBeforeCursor(const std::vector<std::string>& readings, size_t cursor, const std::function<bool(const std::string&)>& isWord)`：§6.3 規則 2，回傳從游標往前要刪的 reading 數。
- `std::string LanguageModeLabel(bool capsLockOn, bool smartEnglish)` → `"英"`／`"中"`；`std::string WidthModeLabel(bool halfWidth)` → `"半"`／`"全"`。

- [ ] **Step 1：寫會失敗的測試**（`MixedInputTest.cpp`，readings 用字串向量，例如 `{"ㄋㄧˇ","ㄏㄠˇ","_literal_ ","_literal_h","_literal_i"}`）

```cpp
TEST(MixedInputTest, Classifiers) {
  EXPECT_TRUE(IsEnglishReading("_literal_a"));      EXPECT_TRUE(IsEnglishReading("_english_hello"));
  EXPECT_FALSE(IsEnglishReading("_literal_3"));     EXPECT_FALSE(IsEnglishReading("_letter_A"));
  EXPECT_TRUE(IsHalfWidthAlphanumericReading("_literal_3"));  EXPECT_TRUE(IsHalfWidthAlphanumericReading("_numpad_7"));
  EXPECT_TRUE(IsChineseReading("ㄏㄠˇ"));           EXPECT_TRUE(IsChineseReading("_literal_好"));
  EXPECT_FALSE(IsChineseReading("_literal_３"));    EXPECT_FALSE(IsChineseReading(" "));
}
TEST(MixedInputTest, AutoSpace) {
  std::vector<std::string> zh{"ㄋㄧˇ","ㄏㄠˇ"};
  EXPECT_TRUE(AutoSpaceNeeded(zh, 2, /*beforeEnglish=*/true));
  EXPECT_FALSE(AutoSpaceNeeded(zh, 0, true));
  std::vector<std::string> en{"_literal_o","_literal_k"};
  EXPECT_TRUE(AutoSpaceNeeded(en, 2, /*beforeEnglish=*/false));
  std::vector<std::string> digits{"_literal_2","_literal_0"};
  EXPECT_FALSE(AutoSpaceNeeded(digits, 2, false));                      // 數字後接中文不加
  EXPECT_FALSE(AutoSpaceNeeded({"ㄏㄠˇ","_literal_a"}, 1, false));       // 依游標，不看句尾
}
TEST(MixedInputTest, RemoveAutoSpace) {
  EXPECT_TRUE(ShouldRemoveAutoSpaceAfterDeletingEnglish({"ㄏㄠˇ","_literal_ "}, 2));
  EXPECT_FALSE(ShouldRemoveAutoSpaceAfterDeletingEnglish({"ㄏㄠˇ","_literal_ ","_literal_x"}, 2));  // 游標後還有英文
  EXPECT_FALSE(ShouldRemoveAutoSpaceAfterDeletingEnglish({"_literal_3","_literal_ "}, 2));
}
TEST(MixedInputTest, TrimPlan) {
  auto isWord = [](const std::string& w){ return w=="hello" || w=="ok"; };
  auto r = [](std::string s){ std::vector<std::string> v; for(char c: s) v.push_back(std::string("_literal_")+c); return v; };
  EXPECT_EQ(PlanTrimBeforeCursor(r("hellojkq"), 8, isWord), 3u);        // hellojkq → hello
  EXPECT_EQ(PlanTrimBeforeCursor(r("ok"), 2, isWord), 0u);
  std::vector<std::string> mixed{"ㄐㄧㄣ","ㄊㄧㄢ","_literal_ ","_literal_j","_literal_q","_literal_v","_literal_x"};
  EXPECT_EQ(PlanTrimBeforeCursor(mixed, 7, isWord), 5u);                  // 字母與空白都刪，停在中文
  std::vector<std::string> withDigit{"_literal_3","_punctuation_,"};
  EXPECT_EQ(PlanTrimBeforeCursor(withDigit, 2, isWord), 1u);              // 標點刪，數字留
  EXPECT_EQ(PlanTrimBeforeCursor(r("lsqq"), 4, [](auto& w){return w=="ls";}), 4u);  // 2 字母前綴不算
}
TEST(MixedInputTest, ModeLabels) {
  EXPECT_EQ(LanguageModeLabel(false,false),"中"); EXPECT_EQ(LanguageModeLabel(true,false),"英");
  EXPECT_EQ(LanguageModeLabel(false,true),"英");  EXPECT_EQ(WidthModeLabel(true),"半");
}
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`（在 ubt 上）
Expected: 編譯失敗（`MixedInput.h` 不存在）

- [ ] **Step 3：照 Interfaces 與行為文件 §0.2、§3.1、§3.2、§6.3 實作**

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected: `MixedInputTest.*` 全部 PASS，整套測試綠燈

- [ ] **Step 5：Commit** — `git commit -m "SmartLearning: classify mixed readings, auto spaces and Esc trimming"`

---

### Task 2：英文字典與英文學習字（`EnglishLexicon`、`EnglishWordStore`）

**Files:**
- Create: `src/SmartLearning/EnglishWords.{h,cpp}`、`src/SmartLearning/EnglishWordsTest.cpp`
- Modify: `src/SmartLearning/CMakeLists.txt`；頂層 `CMakeLists.txt` 的 CPack `Depends` 加 `wamerican`；`docker/Dockerfile.ubuntu2404` 加 `wamerican`

**Interfaces:**
- Consumes：`LearningPaths`（`learningFilename`、`otherDevicesLearningFiles`）、`AtomicFile`（`writeFileAtomically`）
- Produces：

```cpp
namespace McBopomofo::SmartLearning {
class EnglishLexicon {                       // 唯讀、排序好的小寫字表
 public:
  static std::shared_ptr<EnglishLexicon> loadFromFile(const std::filesystem::path&);  // 不存在或讀不到 → 空字表
  static std::shared_ptr<EnglishLexicon> fromWords(std::vector<std::string> words);    // 測試用
  bool contains(std::string_view lowercased) const;
  bool hasLongerWordWithPrefix(std::string_view lowercased) const;   // 有比 prefix 更長、以它開頭的字
};
inline constexpr char kDefaultEnglishWordList[] = "/usr/share/dict/american-english";

class EnglishWordStore {
 public:
  EnglishWordStore(std::string deviceID, std::string deviceName,
                   std::shared_ptr<const EnglishLexicon> lexicon,
                   std::function<double()> now);           // 秒；測試注入
  void setLearningFolder(std::filesystem::path learningFolder);   // english/ 與 removed.txt 都在此資料夾下
  void record(const std::vector<std::string>& words);       // 只記長度 >= 3 的字
  bool save();                                              // 本機檔未載入（pending）→ false 不寫
  bool hasUnsavedChanges() const;
  std::optional<std::string> preferredCase(const std::string& word);  // §5.2
  bool isWord(const std::string& word);                     // §5.5／Mac EW isWord 全部規則
  bool isWordOrPrefix(const std::string& text);             // Mac EW isWordOrPrefix
};
}
```

行為照行為文件 §5.2–§5.5：
- 60 秒重讀其他裝置。
- 本機檔只在第一次讀。
- `removed.txt` 中 `english` kind 的字一律排除。
- 內建 57 個大小寫字照 §5.2 原樣列出。

`isWord`／`isWordOrPrefix` 的規則逐條照 Mac `Source/EnglishWords.swift`（`7446fd0`），其中拼字檢查改用 `lexicon->contains(lowercased)` 和 `hasLongerWordWithPrefix`。字表載入時只收全 ASCII 字母的行，轉小寫、排序、去重。pending、資料夾不存在、改名規則都照 phase 1 `UserOverrideStore` 的做法。

- [ ] **Step 1：寫會失敗的測試**（暫存資料夾、合成資料，`now` 用可調的時鐘）

```cpp
TEST(EnglishWordsTest, LexiconPrefixAndMissingFile) {
  auto lex = EnglishLexicon::fromWords({"Hello","help","helpful","a1b"});
  EXPECT_TRUE(lex->contains("hello"));  EXPECT_FALSE(lex->contains("a1b"));
  EXPECT_TRUE(lex->hasLongerWordWithPrefix("helpf"));  EXPECT_FALSE(lex->hasLongerWordWithPrefix("helpful"));
  EXPECT_FALSE(EnglishLexicon::loadFromFile("/no/such/file")->contains("hello"));   // Review Focus 5
}
TEST(EnglishWordsTest, PreferredCaseBuiltinAndLearned) {
  // iphone → iPhone（內建）；iPhone 不修（非全小寫）；
  // 本機檔有 "ButyPOS\t2" → butypos → ButyPOS；只有 1 次則 nil
  // 同票取字典序最小者
}
TEST(EnglishWordsTest, MergesOtherDevicesAndHonorsRemoved) {
  // 其他裝置檔 "vercel\t2"；removed.txt "english\tvercel\t1700000000" → isWord("vercel") 回傳的結果不因學習字成立
}
TEST(EnglishWordsTest, NeverOverwritesBeforeLocalLoads) {           // Review Focus 3
  // learning/english 資料夾不存在時 record 後 save() == false、沒有建檔；
  // 資料夾與舊本機檔（"oldword\t5"）出現後，save 結果同時含 oldword 5 與新字
}
TEST(EnglishWordsTest, SaveFormatSortedTabSeparated) {
  // record({"zeta","alpha","alpha"}) → 檔案內容 == "alpha\t2\nzeta\t1\n"
}
TEST(EnglishWordsTest, ReloadsOtherDevicesAfterSixtySeconds) { /* now+59 不重讀，now+60 重讀 */ }
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected: 編譯失敗

- [ ] **Step 3：照 Interfaces 與 Mac `EnglishWords.swift` 實作**

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected: `EnglishWordsTest.*` 全部 PASS

- [ ] **Step 5：Commit** — `git commit -m "SmartLearning: English word list and learned English words"`

---

### Task 3：`TrailingConversion` 與注音按鍵規則（純函式，依賴 Mandarin）

**Files:**
- Create: `src/SmartLearning/BopomofoKeys.{h,cpp}`、`src/SmartLearning/BopomofoKeysTest.cpp`
- Modify: `src/SmartLearning/CMakeLists.txt`（連結 `MandarinLib`）

**Interfaces:**
- Consumes：`Formosa::Mandarin::BopomofoReadingBuffer`、`BopomofoKeyboardLayout`（`src/Engine/Mandarin/Mandarin.h`）
- Produces：
  - `bool KeyReplacesComponent(const Formosa::Mandarin::BopomofoReadingBuffer& buffer, char key)`：行為文件 §1.3-3a。
  - `size_t ComponentCount(const Formosa::Mandarin::BopomofoSyllable&)`
  - `std::string RawKeysOfCurrentReading(const Formosa::Mandarin::BopomofoReadingBuffer& buffer, const std::string& rawKeys)`：§0.3。
  - `struct TrailingConversion { size_t lettersToDelete; std::string reading; };`
  - `std::optional<TrailingConversion> PlanTrailingEnglishToChinese(const std::string& run, char key, const Formosa::Mandarin::BopomofoKeyboardLayout* layout, const std::function<bool(const std::string&)>& hasUnigrams, const std::function<bool(const std::string&)>& isWord, const std::function<bool(const std::string&)>& isWordOrPrefix)`：§2.1 規則 1–4，`key == ' '` 視為一聲。

- [ ] **Step 1：寫會失敗的測試**（字典用 lambda 假造）

```cpp
// hasUnigrams 接受 "ㄏㄠˇ","ㄉㄤˇ","ㄋㄧ"；isWord 接受 "hello","PDF"；isWordOrPrefix 接受 "helpful" 的前綴
TEST(BopomofoKeysTest, HelloHaoStandard) {   // 標準鍵盤 "hellocl" + '3'
  auto r = PlanTrailingEnglishToChinese("hellocl", '3', BopomofoKeyboardLayout::StandardLayout(), has, isWord, isWop);
  ASSERT_TRUE(r); EXPECT_EQ(r->lettersToDelete, 2u); EXPECT_EQ(r->reading, "ㄏㄠˇ");
}
TEST(BopomofoKeysTest, HelloHaoHsu) {        // Hsu "hellohw" + 'f'
  auto r = PlanTrailingEnglishToChinese("hellohw", 'f', BopomofoKeyboardLayout::HsuLayout(), has, isWord, isWop);
  ASSERT_TRUE(r); EXPECT_EQ(r->reading, "ㄏㄠˇ");
}
TEST(BopomofoKeysTest, PdfDang) { /* "PDF" + 標準 ㄉㄤˇ 按法 → reading ㄉㄤˇ，刪 2 */ }
TEST(BopomofoKeysTest, HelpfulPrefixNotConverted) { EXPECT_FALSE(PlanTrailingEnglishToChinese("help","f",Hsu...)); }
TEST(BopomofoKeysTest, NonCanonicalKeysSkipped) { /* Hsu "hellone" + 空白：取 "ne"（ㄋㄧ）而非 "one" */ }
TEST(BopomofoKeysTest, ComponentReplaced) { /* 標準 buffer "ap" 再按 'p' → true；"a" 按 'j' → false */ }
TEST(BopomofoKeysTest, RawKeysFallbackToCanonical) { /* rawKeys 與 buffer 不同步時回傳 keySequenceFromSyllable */ }
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected: 編譯失敗

- [ ] **Step 3：照 §1.3-3a、§0.3、§2.1 實作**

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected: `BopomofoKeysTest.*` PASS

- [ ] **Step 5：Commit** — `git commit -m "SmartLearning: Bopomofo key rules for switching between Chinese and English"`

---

### Task 4：KeyHandler 智慧中英切換（含英文接中文、自動空白、大小寫修正、學英文字）

**Files:**
- Modify: `src/KeyHandler.{h,cpp}`（掛點見行為文件 §1.8、§2.3、§3.3、§5.4）、`src/McBopomofo.{h,cpp}`（新設定、建立與存檔 `EnglishWordStore`）
- Create: `src/KeyHandlerSmartTest.cpp`（使用 `McBopomofoLM` 載入 `data/data.txt` 的 fixture，因為 `ParselessLM` 不認 `_literal_`）
- Modify: `src/KeyHandlerTest.cpp`：三個大寫字母測試先關閉 smart（行為文件 §10 最後一段）

**Interfaces:**
- Consumes：Task 1、2、3 的全部函式；phase 1 的 `scheduleLearningSave` 模式
- Produces：
  - `KeyHandler::setSmartChineseEnglishSwitchEnabled(bool)`、`setAutoSpaceBetweenChineseAndEnglish(bool)`、`setFixEnglishWordCase(bool)`
  - `KeyHandler::setEnglishWordStore(std::shared_ptr<SmartLearning::EnglishWordStore>)`
  - `KeyHandler::setOnSmartEnglishModeChanged(std::function<void(bool)>)`：只在值改變時呼叫
  - `bool KeyHandler::isSmartEnglishMode() const`
  - 私有：`insertLiteralText(const std::string&)`、`switchToSmartEnglish(const std::string&)`、`fixCaseOfEnglishWordBeforeCursor()`、`learnEnglishWordsFromWalk()`、成員 `rawKeysOfReading_`、`smartEnglishMode_`、`smartEnglishDigitsOnly_`
  - 設定：上列 Global Constraints 中的 `SmartChineseEnglishSwitchEnabled`、`AutoSpaceBetweenChineseAndEnglish`、`FixEnglishWordCase`，在 activate／reloadConfig 時套用。`EnglishWordStore` 的學習資料夾與 phase 1 `applyLearningFolder()` 同時設定。英文字存檔用同一個 2 秒計時器，按 `hasUnsavedChanges()` 決定是否存。

行為：行為文件 §1.1–§1.5、§2.1、§3.1（插入）、§5.1。fcitx 結構差異照 §0.4 處理：
- Enter 遇到不成字的 reading 時，把 raw keys 轉成英文再送出。
- 英文模式按 Tab：本階段不做聯想，維持 error。
- 數字鍵盤、Control、Plain 模式、漢語拼音配列都不觸發 smart。

- [ ] **Step 1：寫會失敗的測試**（`KeyHandlerSmartTest.cpp`；以 `keyHandler_->handle(Key::asciiKey(c), ...)` 依序送鍵，斷言 `InputStates::Inputting::composingBuffer` 或 committed text）

```cpp
TEST_F(KeyHandlerSmartTest, ReplacedComponentSwitchesToEnglish) { /* 標準 "app" → 組字區 "app"、英文模式 */ }
TEST_F(KeyHandlerSmartTest, NonSyllableWithSpaceBecomesEnglishWord) { /* 標準 "you"+空白 → "you "，回中文模式 */ }
TEST_F(KeyHandlerSmartTest, UppercaseStartsEnglish) { /* "ChatGPT" → 組字區 "ChatGPT" */ }
TEST_F(KeyHandlerSmartTest, SymbolAfterUnfinishedBopomofo) { /* "ok?" → "ok?"，不在英文模式 */ }
TEST_F(KeyHandlerSmartTest, DigitsThenSpaceNoSpace) { /* 標準 "2026"+空白+"年"的按鍵 → "2026年" */ }
TEST_F(KeyHandlerSmartTest, EnglishThenChineseWithoutSpace) { /* Hsu "hello"+"hwf" → "hello 好"；"PDF"+ㄉㄤˇ → "PDF 檔" */ }
TEST_F(KeyHandlerSmartTest, AutoSpaceBetweenChineseAndEnglish) { /* "你好"+"hello" → "你好 hello" */ }
TEST_F(KeyHandlerSmartTest, CaseFixOnSpaceNotOnEnter) { /* "iphone"+空白 → "iPhone "；"iphone"+Enter 送出 "iphone" */ }
TEST_F(KeyHandlerSmartTest, ShortEnglishThatIsBopomofoStaysChinese) { /* Hsu "a"+空白 → 中文（Review Focus 2）*/ }
TEST_F(KeyHandlerSmartTest, ChineseTypingUnchanged) {               // Review Focus 1
  // 標準與 Hsu 各一句 ≥ 8 個字的注音按鍵：smart 開與關的 composingBuffer 完全相同
}
TEST_F(KeyHandlerSmartTest, LearnsEnglishWordsOnCommit) { /* "ButyPOS"+Enter 兩次 → store 有 ButyPOS:2；之後 "butypos"+空白 → "ButyPOS " */ }
TEST_F(KeyHandlerSmartTest, ModeChangeCallback) { /* 進入／離開英文模式各呼叫一次 callback */ }
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected: 編譯失敗（setter 不存在）

- [ ] **Step 3：照上列行為文件段落與掛點實作**

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected: `KeyHandlerSmartTest.*` 與原有 `KeyHandlerTest.*` 全部 PASS

- [ ] **Step 5：Commit** — `git commit -m "Smart switching between Chinese and English"`

---

### Task 5：英數後半形標點、Backspace 連同自動空白刪除

**Files:**
- Modify: `src/KeyHandler.{h,cpp}`（標點 `fKH:492-521`、Backspace `fKH:1108-1110`，行號以行為文件為準）、`src/McBopomofo.{h,cpp}`（`HalfWidthPunctuationAfterEnglish`）
- Test: `src/KeyHandlerSmartTest.cpp`

**Interfaces:**
- Produces：`KeyHandler::setHalfWidthPunctuationAfterEnglish(bool)`；私有 `isAfterHalfWidthAlphanumeric() const`（§4.1）

行為：
- 行為文件 §4.1、§4.2-1、§3.2。
- **比照 Mac**：選了半形前綴（全域半形，或游標前是英數）時，兩個半形鍵都查不到就不回退到全形，改走一般的「找不到標點」路徑。Control 永遠全形。

- [ ] **Step 1：寫會失敗的測試**

```cpp
TEST_F(KeyHandlerSmartTest, HalfWidthPunctuationAfterDigits) { /* "300" 後按 '.' → "300."（半形）*/ }
TEST_F(KeyHandlerSmartTest, FullWidthAfterChinese) { /* "好"+',' → "好，" */ }
TEST_F(KeyHandlerSmartTest, ControlForcesFullWidth) { /* "hello"+Ctrl+',' → "hello，" */ }
TEST_F(KeyHandlerSmartTest, BackspaceRemovesAutoSpace) { /* "用"+"iPhone" 後連按 Backspace 6 次 → "用"（空白一起消失）*/ }
TEST_F(KeyHandlerSmartTest, BackspaceKeepsSpaceWhenEnglishRemainsAfterCursor) { /* 游標移到英文中間刪光前段，不刪空白 */ }
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected: 新測試 FAIL

- [ ] **Step 3：實作**

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected: 全部 PASS

- [ ] **Step 5：Commit** — `git commit -m "Half-width punctuation after English and digits, and remove the auto space with the English"`

---

### Task 6：Esc 清除亂碼、連按兩下清除全部

**Files:**
- Modify: `src/KeyHandler.{h,cpp}`（Esc 處理 `fKH:306-329`；`handle()` 開頭設定連按旗標）、`src/McBopomofo.{h,cpp}`（`EscTrimsMistypedText`；`LocalizedStrings` 新增 `pressEscAgainToClearAll()`）、`src/InputState.h`（`Inputting` 可帶 tooltip）、`po/zh_TW.po`（「再按一次 Esc 清除全部」）
- Test: `src/KeyHandlerSmartTest.cpp`

**Interfaces:**
- Consumes：Task 1 `PlanTrimBeforeCursor`；Task 2 `EnglishWordStore::isWord`
- Produces：`KeyHandler::setEscTrimsMistypedText(bool)`；`LocalizedStrings::pressEscAgainToClearAll()`

行為：
- 行為文件 §6.1–§6.3。開著時完全取代 `EscKeyClearsEntireComposingBuffer`。
- 只接受 Inputting 狀態，與 Mac 相同；Marking 狀態照舊行為。
- 修剪後游標前已不是字母時，離開英文模式。

- [ ] **Step 1：寫會失敗的測試**

```cpp
TEST_F(KeyHandlerSmartTest, EscTrimsGarbage) { /* "今天開會"+" jqvx" → Esc → "今天開會"，tooltip 為 "再按一次 Esc 清除全部" */ }
TEST_F(KeyHandlerSmartTest, EscKeepsWordPrefix) { /* "hellojkq" → Esc → "hello" */ }
TEST_F(KeyHandlerSmartTest, EscClearsUnfinishedReadingAndTrailing) { /* "下午 3 點"+"ㄒㄧ" → Esc → "下午 3 點" */ }
TEST_F(KeyHandlerSmartTest, EscOnCleanTextOnlyHints) { /* "你好" → Esc → 仍是 "你好"，有提示；再 Esc → Empty */ }
TEST_F(KeyHandlerSmartTest, OtherKeyBreaksDoubleEsc) { /* Esc、任一鍵、Esc → 第二次 Esc 不全清 */ }
TEST_F(KeyHandlerSmartTest, EscOnlyBeforeCursor) {                  // Review Focus 4
  /* "你好jq" 游標移到 "你" 之後 → Esc：游標後內容不變 */
}
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected: 新測試 FAIL

- [ ] **Step 3：實作**

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected: 全部 PASS

- [ ] **Step 5：Commit** — `git commit -m "Esc removes only mistyped text, twice clears all"`

---

### Task 7：中英模式圖示、全／半圖示、切換提醒

**Files:**
- Modify: `src/McBopomofo.{h,cpp}`、`po/zh_TW.po`
- Test: `src/McBopomofoConfigTest.cpp`（新設定的預設值）

**Interfaces:**
- Consumes：Task 1 `LanguageModeLabel`／`WidthModeLabel`；Task 4 `setOnSmartEnglishModeChanged`
- Produces：
  - 設定 `ChineseEnglishSwitchReminderEnabled`=true、`ShowChineseEnglishModeIcon`=true、`ShowFullHalfWidthModeIcon`=false
  - 新 `fcitx::SimpleAction` `mcbopomofo-chinese-english-mode`（`ShowChineseEnglishModeIcon` 開時加入狀態列，文字為「中」或「英」）
  - 既有半形標點 action 在 `ShowFullHalfWidthModeIcon` 開時，短文字改成「全」或「半」

行為：
- 「英」的條件：Caps Lock 開著，或在智慧英文模式（§7.2）。
- 每次按鍵都從 `rawKey().states()` 讀 Caps Lock，值變了才更新圖示。
- 切換提醒：Caps Lock 狀態改變時，用既有的 `showTip` 顯示「ABC」或「中文」。智慧英文模式切換只換圖示，不跳提醒（§7.1）。
- fcitx 收不收得到 Caps Lock 鍵本身的事件（行為文件 UNKNOWN 5），留到 Task 9 實機確認，並記錄在驗收紀錄。

- [ ] **Step 1：寫會失敗的測試**：在 `McBopomofoConfigTest` 新增上列 8 個新設定的預設值斷言（含 Task 4–6 的設定）。

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected: 新的預設值斷言 FAIL（屬於本 task 的 3 個設定）

- [ ] **Step 3：實作 action、圖示更新、提醒**

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected: 全部 PASS

- [ ] **Step 5：Commit** — `git commit -m "Chinese/English mode icon, full/half width icon, and switch reminder"`

---

### Task 8：鍵盤快速切換（注音－標準鍵盤／許氏鍵盤）

**Files:**
- Modify: `src/McBopomofo.{h,cpp}`、`po/zh_TW.po`
- Create/Modify: `src/McBopomofoConfigTest.cpp`（配列對照 helper 的測試）

**Interfaces:**
- Produces：
  - `const Formosa::Mandarin::BopomofoKeyboardLayout* layoutForConfig(BopomofoKeyboardLayout)`（自由函式，放在 `McBopomofo.h`）。activate 與 action 共用，取代 activate 內的 switch。
  - 兩個 `fcitx::SimpleAction`：`mcbopomofo-layout-standard`（「注音－標準鍵盤」）、`mcbopomofo-layout-hsu`（「注音－許氏鍵盤」），checkable，在狀態列放在其他 action 之前。

行為照行為文件 §8，按下其中一個 action 時：
1. 設定 config 並用 `safeSaveAsIni` 存檔。
2. `keyHandler_->setKeyboardLayout(...)`。
3. 清掉組字中的內容（不送出），回到 Empty。
4. 用 `showTip` 顯示項目名稱。
5. 更新兩個 action 的勾選狀態。

fcitx5 設定工具改了配列時，勾選狀態也要跟著同步。

- [ ] **Step 1：寫會失敗的測試**

```cpp
TEST(McBopomofoConfigTest, LayoutForConfig) {
  EXPECT_EQ(layoutForConfig(BopomofoKeyboardLayout::Standard), Formosa::Mandarin::BopomofoKeyboardLayout::StandardLayout());
  EXPECT_EQ(layoutForConfig(BopomofoKeyboardLayout::Hsu), Formosa::Mandarin::BopomofoKeyboardLayout::HsuLayout());
  // 其餘四種各一行
}
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected: 編譯失敗

- [ ] **Step 3：實作 helper 與兩個 action**

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected: 全部 PASS

- [ ] **Step 5：Commit** — `git commit -m "Switch between the standard and Hsu keyboards from the menu"`

---

### Task 9：打包 learning.2、更新說明、sindy-Mint 實機驗收

**Files:**
- Modify: `CMakeLists.txt`（套件版本 `-learning.2`）、`README.md`（新增功能段落；安裝指令檔名）
- Create: `docs/acceptance-phase2.md`

**Interfaces:** 無新程式介面。

- [ ] **Step 1：打包**

Run: `ssh ubt 'cd src/fcitx5-mcbopomofo && DOCKER="sudo docker" scripts/docker-build-test.sh package'`
Expected: 測試全過，產生 `fcitx5-mcbopomofo-smart-learning_3.1.1-learning.2_amd64.deb`；`dpkg -I` 的 Depends 含 `wamerican`

- [ ] **Step 2：在 sindy-Mint（`ssh sindy@192.168.1.132`）安裝並重啟 fcitx5**

Run: `ssh sindy@192.168.1.132 'cat > /tmp/mcbpmf.deb' < dist/<deb>`，再執行 `sudo apt-get install -y /tmp/mcbpmf.deb && fcitx5 -rd`
Expected: 安裝成功，fcitx5 重新啟動並載入小麥

- [ ] **Step 3：驗收清單**（使用者經 RustDesk 操作；逐項把結果記在 `docs/acceptance-phase2.md`）：
  1. 標準與許氏鍵盤從狀態列選單互切，切換後立即生效。
  2. `app`、`you`＋空白、`ChatGPT`、`hello`＋ㄏㄠˇ、`PDF`＋ㄉㄤˇ 的結果與 Mac 相同。
  3. 「你好 hello」「用 iPhone 拍」有自動空白；Backspace 刪光英文時，空白一起消失。
  4. 「價格是300.」用半形句點，「好，」用全形逗號。
  5. `iphone`＋空白 → iPhone；按 Enter 送出則保留小寫。
  6. `今天開會 jqvx` 按 Esc 一次清亂碼，連按兩次清全部。
  7. 中／英圖示跟著切換；Caps Lock 有沒有跳提醒（記錄 UNKNOWN 5 的實測結果）。
  8. iMac 打過兩次以上的英文字（`learning/english/`）在 Mint 上會修正大小寫。

- [ ] **Step 4：Commit 並推送**（不打 tag、不發 release，等使用者決定）

```bash
git add CMakeLists.txt README.md docs/acceptance-phase2.md
git commit -m "Version 3.1.1-learning.2, and the phase 2 acceptance record"
git push
```
