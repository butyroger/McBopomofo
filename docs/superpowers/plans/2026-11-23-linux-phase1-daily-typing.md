# Linux 版第一階段（可日常打字）實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Ubuntu 24.04／Linux Mint 22 上裝得起來、天天能打字的小麥注音智慧學習版第一版：引擎與 Mac 版相同，選字記憶跟 Mac 共用同一個 Synology Drive 詞庫資料夾。

**Architecture:** fork `openvanilla/fcitx5-mcbopomofo`，開 `smart-learning` 分支。引擎（`src/Engine/`）套用 Mac fork 的修改。學習資料的讀寫放進新的純 C++ 模組 `src/SmartLearning/`（不 include 任何 fcitx 標頭，日後 Mac 可共用）。fcitx5 那層（`McBopomofo.cpp`）只負責計時存檔、切換輸入法時重新載入、以及設定。

**Tech Stack:** C++17、CMake、GoogleTest（`gtest_discover_tests`）、fcitx5 5.1（Ubuntu 24.04 套件）、Docker `ubuntu:24.04`（建置與測試）、GitHub Actions、CPack DEB。

**Spec:** `docs/superpowers/specs/2026-11-23-linux-fcitx5-port-design.md`（Mac repo `butyroger/McBopomofo`）

## Global Constraints

- 目標系統：Ubuntu 24.04 LTS 與 Linux Mint 22.x，一份 `.deb`。
- 行為基準：Mac `smart-learning` commit `7446fd0`（3.1.1-learning.23）。
- 詞庫檔案格式與 Mac 版完全相容，不得為了 Linux 改格式。
- `src/SmartLearning/` 只能依賴 C++ 標準函式庫，不得 include 任何 `fcitx` 標頭。
- 測試資料只用合成樣本，repo 是公開的，不放使用者真實檔案。
- README、CHANGELOG、release 說明、程式註解只描述功能本身，不比照、不提及其他輸入法產品。
- 不同時在兩台機器上打字；單一共寫檔案寫入前先重讀，一律 atomic write（寫暫存檔再 rename）。
- 建置與測試在 ubt（`ssh ubt`，Debian 13、24 核心、有 docker）上的 `ubuntu:24.04` container 裡跑，原始碼放 `~/src/fcitx5-mcbopomofo`。ubt 是公司內網伺服器：只用 docker，不在主機上裝套件、不改系統設定。

## Review Focus

1. **Synology 還沒同步完或資料夾暫時不存在時 fcitx5 就啟動了**：本機學習檔還沒載入之前不能存檔覆蓋。檔案之後出現時，要把啟動以來的觀察和檔案內容合併（Mac：`gLocalUserOverrideModelFilePending`）。測試在 Task 4。
2. **其他裝置的學習檔同步到一半**（最後一行被截斷、空行、欄位數不對）：略過壞行，其餘照常載入，不當機。測試在 Task 4。
3. **主機名稱含空白、中文、`/`、`:`**：檔名中 `/:\` 與換行、tab 換成 `_`，其他字元保留，跟 Mac 相同。測試在 Task 3。
4. **`learning/` 裡出現同步衝突副本**（Synology `*_Conflict*`、Syncthing `*.sync-conflict-*`）：合併時略過，也不能被當成自己的檔案改名。測試在 Task 3。
5. **偏好設定指到不存在或無法寫入的資料夾**：父目錄存在就建立該資料夾；否則退回預設資料夾，寫 log，不當機，也不在奇怪的位置建一整串目錄。測試在 Task 6。

---

### Task 1：fork、建置環境、CI、檔案格式規格

**Files:**
- Create: `docker/Dockerfile.ubuntu2404`
- Create: `scripts/docker-build-test.sh`
- Modify: `.github/workflows/ci.yaml`
- Create: `docs/file-formats.md`

**Interfaces:**
- Produces：`scripts/docker-build-test.sh`（在 repo 根目錄執行，於 container 中跑 cmake 建置與 `ctest --output-on-failure`，回傳 ctest 的結束碼）。之後每個 task 的驗證都用它。

- [ ] **Step 1：建 fork 與分支**

```bash
gh repo fork openvanilla/fcitx5-mcbopomofo --clone=false
git clone https://github.com/butyroger/fcitx5-mcbopomofo.git ~/Developer/fcitx5-mcbopomofo
cd ~/Developer/fcitx5-mcbopomofo && git remote add upstream https://github.com/openvanilla/fcitx5-mcbopomofo.git
git switch -c smart-learning && git push -u origin smart-learning
gh repo edit butyroger/fcitx5-mcbopomofo --default-branch smart-learning
```

- [ ] **Step 2：Dockerfile**：`FROM ubuntu:24.04`，apt 裝 README 列的套件（`g++ pkg-config fcitx5 libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev fcitx5-modules-dev cmake extra-cmake-modules gettext libfmt-dev libicu-dev libjson-c-dev`），另加 `libgtest-dev libgmock-dev ninja-build file`。

- [ ] **Step 3：`scripts/docker-build-test.sh`**：以 `docker build -t mcbpmf-u2404 -f docker/Dockerfile.ubuntu2404 docker`，再 `docker run --rm -v "$PWD":/src -w /src mcbpmf-u2404 sh -c 'cmake -B build-docker -G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_TEST=On && cmake --build build-docker && cd build-docker && ctest --output-on-failure'`。`build-docker/` 加進 `.gitignore`。

- [ ] **Step 4：在 ubt 跑基準建置**

Run: `rsync -a --delete --exclude build-docker ~/Developer/fcitx5-mcbopomofo/ ubt:src/fcitx5-mcbopomofo/ && ssh ubt 'cd src/fcitx5-mcbopomofo && scripts/docker-build-test.sh'`
Expected：`100% tests passed`

- [ ] **Step 5：CI**：`ci.yaml` 的 `runs-on: ubuntu-latest` 改成 `ubuntu-24.04`，觸發分支加 `smart-learning`。

- [ ] **Step 6：`docs/file-formats.md`**：依 Mac 程式碼（`Source/LanguageModelManager.mm`、`CommonSentences.swift`、`EnglishWords.swift`、`Engine/UserOverrideModel.cpp`）整理詞庫資料夾每個檔案：檔名、每行格式、誰寫、寫法（附加或整份 atomic 覆寫）、合併與過期規則。至少要涵蓋：
  - `data.txt`（`詞 注音`，注音以 `-` 連接；同讀音以前面的優先）
  - `exclude-phrases.txt`、`phrases-replacement.txt`、`text-templates.txt`（`代碼<Tab>內容`）、`symbol-table.txt`
  - `learning/<裝置ID>-<名稱>.txt`：`key<TAB>candidate<TAB>count<TAB>timestamp<TAB>forceHighScoreOverride`，由舊到新；每台上限 5000、合併上限 20000、半衰期 30 天
  - 裝置 ID：UUID 前 8 個大寫十六進位字元；檔名中 `/:\`、換行、tab 換成 `_`；換電腦名稱時把同 ID 前綴的舊檔改名
  - `learning/temporary/`（`值 讀音 時間`，30 天過期）、`learning/english/`、`learning/sentences/`、`learning/removed.txt`（格式照 Mac 程式碼寫清楚，第三階段要用）
  - 同步衝突副本的排除規則

- [ ] **Step 7：Commit 並推上去**，確認 GitHub Actions 綠燈。

```bash
git add docker scripts .github/workflows/ci.yaml docs/file-formats.md .gitignore
git commit -m "build: Ubuntu 24.04 container, CI, and the user data file formats"
git push
```

---

### Task 2：引擎套用 Mac fork 的修改

**Files:**
- Modify: `src/Engine/McBopomofoLM.{h,cpp}`、`src/Engine/UserOverrideModel.{h,cpp}`
- Test: `src/Engine/McBopomofoLMTest.cpp`、`src/Engine/UserOverrideModelTest.cpp`

**Interfaces:**
- Produces（從 Mac fork 原樣帶過來）：
  - `UserOverrideModel::serialize() const -> std::string`
  - `UserOverrideModel::deserialize(const std::string& text, bool append = false) -> size_t`
  - `UserOverrideModel::observationCount(walk, cursor, candidate) const -> size_t`
  - `UserOverrideModel::candidateObservationCount(candidate) const -> size_t`
  - `McBopomofoLM::setTemporaryPhrases`、`setEnglishCompletionProvider`、`setSymbolTable`、`getSymbolSections`、`getSymbolInitialIndex`、`kLiteralKeyPrefix`、`kEnglishKeyPrefix`、`kSymbolsKeyPrefix`

- [ ] **Step 1：產生 patch 並套用**。fcitx5 的 `src/Engine/` 這六個檔，除了 `McBopomofoLM.cpp` 差一行外，其餘和 Mac 的合併點 `e65f276` 完全相同。

```bash
cd ~/Developer/McBopomofo && git diff e65f276 7446fd0 -- Source/Engine > /tmp/engine.patch
cd ~/Developer/fcitx5-mcbopomofo && sed -E 's#([ab])/Source/Engine/#\1/src/Engine/#g' /tmp/engine.patch | git apply -3
```

`McBopomofoLM.cpp` 那一行衝突用手動合併：保留 fcitx5 的那一行，再加上 Mac 新增的部分。

- [ ] **Step 2：跑測試**

Run: `scripts/docker-build-test.sh`（在 ubt 上，同 Task 1 Step 4）
Expected：`McBopomofoLMLibTest` 包含 Mac 新增的 serialize／deserialize、observationCount、symbol 測試，全部 PASS。

- [ ] **Step 3：Commit**

```bash
git add src/Engine && git commit -m "engine: learning persistence, literal and English keys, symbol table"
```

---

### Task 3：`SmartLearning` 模組骨架：裝置身分與學習檔路徑

**Files:**
- Create: `src/SmartLearning/CMakeLists.txt`、`src/SmartLearning/LearningPaths.{h,cpp}`、`src/SmartLearning/AtomicFile.{h,cpp}`
- Create: `src/SmartLearning/LearningPathsTest.cpp`、`src/SmartLearning/AtomicFileTest.cpp`、`src/SmartLearning/NoFcitxIncludeTest.cmake`
- Modify: `src/CMakeLists.txt`（`add_subdirectory(SmartLearning)`，`McBopomofoLib` 連結 `SmartLearningLib`）

**Interfaces（namespace `McBopomofo::SmartLearning`）:**
- `std::string newDeviceID()`：8 個大寫十六進位字元
- `std::string sanitizeDeviceName(std::string_view name)`：把 `/ : \ \n \r \t` 換成 `_`；結果是空字串時傳回 `"Linux"`
- `std::string learningFilename(std::string_view deviceID, std::string_view deviceName)`：`ID-名稱.txt`
- `bool isSyncConflictCopy(std::string_view filename)`：含 `_Conflict` 或 `.sync-conflict-` 就傳回 true
- `std::vector<std::filesystem::path> otherDevicesLearningFiles(const std::filesystem::path& folder, std::string_view ownFilename)`：資料夾第一層的 `.txt` 一般檔，排除自己的檔、隱藏檔、衝突副本，依檔名排序
- `std::optional<std::filesystem::path> findRenamedOwnFile(const std::filesystem::path& folder, std::string_view deviceID, std::string_view ownFilename)`：找同一個 `ID-` 前綴、但檔名不同的 `.txt`（不含衝突副本）
- `bool writeFileAtomically(const std::filesystem::path& path, std::string_view content)`：先寫同目錄的 `.<檔名>.tmp-<pid>`，再 `rename`；失敗傳回 false，暫存檔要清掉

- [ ] **Step 1：寫會失敗的測試**（`LearningPathsTest.cpp`，用 `std::filesystem::temp_directory_path()` 底下的獨立資料夾）

```cpp
TEST(LearningPathsTest, DeviceIDIsEightUppercaseHex) {
  auto id = newDeviceID();
  EXPECT_EQ(id.size(), 8u);
  EXPECT_TRUE(std::all_of(id.begin(), id.end(), [](char c){ return std::isxdigit(c) && !std::islower(c); }));
}
TEST(LearningPathsTest, SanitizesLikeMac) {
  EXPECT_EQ(learningFilename("1778D9F7", sanitizeDeviceName("Mac Studio")), "1778D9F7-Mac Studio.txt");
  EXPECT_EQ(sanitizeDeviceName("a/b:c\\d\te"), "a_b_c_d_e");
  EXPECT_EQ(sanitizeDeviceName("筆電"), "筆電");
  EXPECT_EQ(sanitizeDeviceName(""), "Linux");
}
TEST(LearningPathsTest, SkipsConflictCopiesAndOwnFile) {
  // folder 中建立：自己的 "AAAA0001-mint.txt"、"1778D9F7-Mac Studio.txt"、
  // "523308DB-MacBook Neo_mint_Nov-23-120000-2026_Conflict.txt"、
  // "1778D9F7-Mac Studio.sync-conflict-20261123-120000-ABC.txt"、".hidden.txt"、
  // 子資料夾 "temporary/"、"notes.md"
  auto files = otherDevicesLearningFiles(folder, "AAAA0001-mint.txt");
  ASSERT_EQ(files.size(), 1u);
  EXPECT_EQ(files[0].filename(), "1778D9F7-Mac Studio.txt");
}
TEST(LearningPathsTest, FindsOwnFileAfterHostnameChange) {
  // folder 中有 "AAAA0001-oldname.txt" 和 "AAAA0001-oldname_x_Conflict.txt"
  EXPECT_EQ(findRenamedOwnFile(folder, "AAAA0001", "AAAA0001-newname.txt")->filename(), "AAAA0001-oldname.txt");
}
```

`AtomicFileTest.cpp`：寫入後內容相同；覆寫既有檔後沒有留下 `.tmp-` 檔；目錄不存在時傳回 false。

`NoFcitxIncludeTest.cmake`：用 `file(GLOB_RECURSE)` 讀 `src/SmartLearning/*.{h,cpp}`，任何一行符合 `#include <fcitx` 或 `#include "fcitx` 就 `message(FATAL_ERROR)`；以 `add_test(NAME SmartLearningNoFcitxInclude COMMAND ${CMAKE_COMMAND} -P ...)` 註冊。

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected：編譯失敗（函式尚未定義）

- [ ] **Step 3：實作上面的函式**。`newDeviceID` 用 `std::random_device` 產生 32 bit 亂數，格式化成 `%08X`。目錄列舉用 `std::filesystem::directory_iterator`，搭配 `std::error_code`，出錯就傳回空結果，不丟例外。

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected：`SmartLearningLibTest` 與 `SmartLearningNoFcitxInclude` 都 PASS

- [ ] **Step 5：Commit**

```bash
git add src/SmartLearning src/CMakeLists.txt && git commit -m "SmartLearning: device identity, learning file paths, atomic writes"
```

---

### Task 4：`UserOverrideStore`：選字記憶的載入、合併、存檔

**Files:**
- Create: `src/SmartLearning/UserOverrideStore.{h,cpp}`、`src/SmartLearning/UserOverrideStoreTest.cpp`

**Interfaces:**
- Consumes：Task 2 的 `UserOverrideModel::serialize/deserialize`；Task 3 的路徑與 atomic 函式
- Produces：

```cpp
namespace McBopomofo::SmartLearning {
class UserOverrideStore {
 public:
  static constexpr size_t kLocalCapacity = 5000;
  static constexpr size_t kMergedCapacity = 20000;
  static constexpr double kHalfLife = 30.0 * 86400.0;
  UserOverrideStore(std::string deviceID, std::string deviceName);
  void setLearningFolder(std::filesystem::path folder);  // 換資料夾：重設 pending 並 reload()
  UserOverrideModel* mergedModel();                      // 給 KeyHandler suggest／查次數用
  void observe(const ReadingGrid::WalkResult& before, const ReadingGrid::WalkResult& after,
               size_t cursor, double timestamp);         // 寫進本機和合併兩個 model
  bool reloadIfChanged();  // 資料夾內 .txt 的 (檔名, mtime, 大小) 快照有變才 reload()，有 reload 就傳回 true
  void reload();           // 本機 model 重新灌進合併 model，再依序 append 其他裝置的檔
  bool save();             // 本機檔還沒載入就不寫、傳回 false；否則 atomic 寫入自己的檔
  bool isLocalFilePending() const;
};
}
```

行為照 Mac `LanguageModelManager.mm` 第 747–1008 行：
- 載入本機檔前，先用 `findRenamedOwnFile` 把舊名稱的檔改成目前的檔名。
- 本機檔用 `deserialize(content, /*append=*/true)` 載入，保留檔案出現前已觀察到的資料。
- 資料夾不存在或讀不到時，維持 pending。

- [ ] **Step 1：寫會失敗的測試**（用 `UserOverrideModel` 現有測試的 walk 建法，產生兩個不同的觀察）

```cpp
TEST(UserOverrideStoreTest, MergesOtherDevicesAndSavesOnlyOwnFile) {
  // folder 中有 "1778D9F7-Mac Studio.txt"，內容是一行合成觀察
  UserOverrideStore store("AAAA0001", "mint"); store.setLearningFolder(folder);
  EXPECT_FALSE(store.mergedModel()->suggest(macWalk, cursor, now).empty());
  store.observe(before, after, cursor, now);
  ASSERT_TRUE(store.save());
  EXPECT_TRUE(exists(folder / "AAAA0001-mint.txt"));
  EXPECT_EQ(readFile(folder / "1778D9F7-Mac Studio.txt"), originalMacContent);  // 其他裝置的檔不被動到
  EXPECT_EQ(readFile(folder / "AAAA0001-mint.txt").find("1778D9F7"), std::string::npos);  // 只寫本機觀察
}
TEST(UserOverrideStoreTest, DoesNotOverwriteBeforeLocalFileLoads) {        // Review Focus 1
  UserOverrideStore store("AAAA0001", "mint"); store.setLearningFolder(folder / "not-yet");
  store.observe(before, after, cursor, now);
  EXPECT_TRUE(store.isLocalFilePending());
  EXPECT_FALSE(store.save());
  EXPECT_FALSE(exists(folder / "not-yet" / "AAAA0001-mint.txt"));
  // 資料夾與先前的本機檔出現（模擬同步完成）
  create_directories(folder / "not-yet"); writeFile(folder / "not-yet" / "AAAA0001-mint.txt", oldLine);
  EXPECT_TRUE(store.reloadIfChanged());
  ASSERT_TRUE(store.save());
  auto saved = readFile(folder / "not-yet" / "AAAA0001-mint.txt");
  EXPECT_NE(saved.find(oldLineKey), std::string::npos);                    // 舊資料還在
  EXPECT_NE(saved.find(newObservationKey), std::string::npos);             // 啟動後的觀察也在
}
TEST(UserOverrideStoreTest, SkipsTruncatedLines) {                         // Review Focus 2
  // 其他裝置的檔：一行正確、一行只有兩欄、最後一行被截斷且沒有換行、空行
  store.reload();
  EXPECT_FALSE(store.mergedModel()->suggest(goodWalk, cursor, now).empty());
}
TEST(UserOverrideStoreTest, ReloadIfChangedDetectsNewDeviceFile) {
  EXPECT_FALSE(store.reloadIfChanged());
  writeFile(folder / "523308DB-MacBook Neo.txt", line);
  EXPECT_TRUE(store.reloadIfChanged());
}
TEST(UserOverrideStoreTest, AdoptsRenamedOwnFile) {
  // "AAAA0001-oldname.txt" 存在 → 建 store("AAAA0001","mint") 後應改名為 "AAAA0001-mint.txt"
}
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected：編譯失敗（`UserOverrideStore` 尚未定義）

- [ ] **Step 3：照上面的 Interfaces 實作 `UserOverrideStore`**

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected：`UserOverrideStoreTest.*` 全部 PASS

- [ ] **Step 5：Commit**

```bash
git add src/SmartLearning && git commit -m "SmartLearning: load, merge and save the learned choices per device"
```

---

### Task 5：KeyHandler 改用共用的選字記憶，fcitx5 層延遲存檔與重新載入

**Files:**
- Modify: `src/KeyHandler.h`、`src/KeyHandler.cpp:56,105-116,213,1845`
- Modify: `src/McBopomofo.h`、`src/McBopomofo.cpp:451`（建構）、`:713`（activate 時重新載入）
- Test: `src/KeyHandlerTest.cpp`

**Interfaces:**
- Consumes：Task 4 的 `UserOverrideStore`
- Produces：
  - `KeyHandler` 建構子多一個參數 `std::shared_ptr<SmartLearning::UserOverrideStore> userOverrideStore`（放在最後）。`suggest` 改用 `store->mergedModel()`，`observe` 改呼叫 `store->observe(...)`。拿掉 `userOverrideModel_` 成員和 `kUserOverrideModelCapacity = 500`。
  - `KeyHandler::setOnUserOverrideObserved(std::function<void()> callback)`：每次 observe 之後呼叫。
  - `McBopomofoEngine` 持有 store。callback 透過 `instance_->eventLoop().addTimeEvent(CLOCK_MONOTONIC, now + 2s, ...)` 重設一個 2 秒的計時器，時間到才 `store->save()`。`save()` 傳回 false 時再排一次。activate 時呼叫 `store->reloadIfChanged()`。fcitx5 關閉（engine 解構）時呼叫一次 `save()`。

- [ ] **Step 1：寫會失敗的測試**（`KeyHandlerTest.cpp`：fixture 改成建 store，指向暫存資料夾）

```cpp
TEST_F(KeyHandlerTest, ChoosingCandidateIsObservedAndPersisted) {
  int observed = 0;
  keyHandler_->setOnUserOverrideObserved([&]{ ++observed; });
  // 打 ㄋㄧˇ ㄏㄠˇ，開候選字，選一個非第一順位的候選字
  EXPECT_EQ(observed, 1);
  ASSERT_TRUE(store_->save());
  EXPECT_TRUE(exists(learningFolder_ / ("TESTDEV1-" + std::string("test") + ".txt")));
}
TEST_F(KeyHandlerTest, SuggestionFromAnotherDeviceIsUsed) {
  // 預先在 learningFolder_ 放一個合成的 "1778D9F7-Mac Studio.txt"，記錄同一讀音偏好次選字
  store_->reload();
  // 打同樣讀音 → 組字結果是該次選字
}
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected：編譯失敗（建構子參數、`setOnUserOverrideObserved` 不存在）

- [ ] **Step 3：照上面的 Interfaces 修改 KeyHandler 與 McBopomofo.cpp**。學習資料夾用 `<詞庫資料夾>/learning`。裝置 ID 與名稱來自 Task 7 的設定，名稱用 `gethostname()` 再經過 `sanitizeDeviceName`。

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected：全部 PASS（包含原有的 KeyHandlerTest）

- [ ] **Step 5：Commit**

```bash
git add src && git commit -m "Share learned choices across devices through the user data folder"
```

---

### Task 6：可指定詞庫資料夾，寫入改成 atomic

**Files:**
- Create: `src/SmartLearning/UserDataFolder.{h,cpp}`、`src/SmartLearning/UserDataFolderTest.cpp`
- Modify: `src/LanguageModelLoader.{h,cpp}`（`:84-124` 改成用解析後的路徑；`removePhraseFromFile` 改用 `writeFileAtomically`）
- Modify: `src/McBopomofo.{h,cpp}`（新增設定、`reloadConfig` 時套用）

**Interfaces:**
- Produces：
  - `std::filesystem::path resolveUserDataFolder(std::string_view configured, const std::filesystem::path& defaultFolder, std::string* warning)`：
    - `configured` 是空字串時傳回 `defaultFolder`（必要時建立）。
    - 開頭是 `~/` 時展開成 `$HOME`。
    - 路徑存在且是目錄時，直接傳回。
    - 不存在但父目錄存在時，建立後傳回。
    - 其他情況（父目錄不存在、無法建立、是一般檔案）傳回 `defaultFolder`，並把原因寫進 `*warning`。
  - `LanguageModelLoader::setUserDataFolder(std::filesystem::path folder)`：換路徑後重設三個 `TimestampedPath` 並重新載入。
  - 設定 `fcitx::Option<std::string> userDataFolder{this, "UserDataFolder", _("User data folder (shared with other computers)"), ""}`

- [ ] **Step 1：寫會失敗的測試**（Review Focus 5）

```cpp
TEST(UserDataFolderTest, EmptyMeansDefault)        { EXPECT_EQ(resolveUserDataFolder("", def, &w), def); }
TEST(UserDataFolderTest, ExpandsTilde)             { /* setenv HOME=tmp → "~/SynologyDrive/McBopomofo" 存在 → tmp/SynologyDrive/McBopomofo */ }
TEST(UserDataFolderTest, CreatesLeafWhenParentExists) { /* tmp/a 存在，"tmp/a/McBopomofo" → 建立並傳回 */ }
TEST(UserDataFolderTest, FallsBackWhenParentMissing) {
  auto p = resolveUserDataFolder((tmp / "no/such/dir").string(), def, &w);
  EXPECT_EQ(p, def); EXPECT_FALSE(w.empty()); EXPECT_FALSE(exists(tmp / "no"));
}
TEST(UserDataFolderTest, FallsBackWhenPathIsAFile) { /* 指到一般檔 → def，warning 非空 */ }
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected：編譯失敗

- [ ] **Step 3：實作 `resolveUserDataFolder`，接進 LanguageModelLoader 與設定**。`warning` 非空時用 fcitx5 通知顯示一次。換資料夾時同時呼叫 `UserOverrideStore::setLearningFolder(folder / "learning")`。

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected：全部 PASS

- [ ] **Step 5：Commit**

```bash
git add src && git commit -m "Choose the user data folder, and write user files atomically"
```

---

### Task 7：偏好設定預設值對齊 Mac，裝置 ID 存進設定

**Files:**
- Modify: `src/McBopomofo.h:100-225`
- Create: `src/McBopomofoConfigTest.cpp`（在 `src/CMakeLists.txt` 加進 `McBopomofoTest`）

**Interfaces:**
- Produces：`fcitx::HiddenOption<std::string> deviceID{this, "DeviceID", "DeviceID", ""}`。McBopomofo 啟動時若是空字串，就用 `newDeviceID()` 產生一個並 `safeSaveAsIni` 存回去。

預設值（取自使用者 Mac 2026-11-23 的 `defaults read`）：

| 設定 | 新預設值 | Mac 來源 |
|---|---|---|
| `BopomofoKeyboardLayout` | `Hsu` | `KeyboardLayout=2` |
| `SelectionKeys` | `Key_asdfghjkl` | `CandidateKeys=asdfghjkl` |
| `CandidateLayout` | `Vertical` | `UseHorizontalCandidateList=0` |
| `ChooseCandidateUsingSpace` | `true` | 1 |
| `MoveCursorAfterSelection` | `true` | 1 |
| `EscKeyClearsEntireComposingBuffer` | `true` | `EscToCleanInputBuffer=1` |
| `KeepInvalidSyllableForFurtherInput` | `false` | 0 |
| `ShitEnterEnabled` | `true` | 1 |
| `RepeatedPunctuationToSelectCandidateEnabled` | `true` | 1 |
| `KeyHandlerCtrlEnter` | `OutputBpmfReading` | `ControlEnterOutput=1`（Mac enum：0 off、1 bpmfReading） |
| `SelectPhrase` | `BeforeCursor` | `SelectPhraseAfterCursorAsCandidate=0` |
| `AllowMovingCursorWhenChoosingCandidates` | `Disabled` | 0 |
| `capsLockAllowChineseInput` | `false` | Caps Lock 當一般大寫鎖定 |

- [ ] **Step 1：寫會失敗的測試**

```cpp
TEST(McBopomofoConfigTest, DefaultsMatchTheMacSetup) {
  McBopomofo::McBopomofoConfig c;
  EXPECT_EQ(c.bopomofoKeyboardLayout.value(), BopomofoKeyboardLayout::Hsu);
  EXPECT_EQ(c.selectionKeys.value(), SelectionKeys::Key_asdfghjkl);
  // ……表中每一列各一個 EXPECT_EQ
  EXPECT_EQ(c.deviceID.value(), "");
}
```

- [ ] **Step 2：跑測試，確認會失敗**

Run: `scripts/docker-build-test.sh`
Expected：`DefaultsMatchTheMacSetup` FAIL

- [ ] **Step 3：照上表修改 `McBopomofo.h` 的預設值，並加上 `deviceID`**

- [ ] **Step 4：跑測試，確認通過**

Run: `scripts/docker-build-test.sh`
Expected：全部 PASS

- [ ] **Step 5：Commit**

```bash
git add src && git commit -m "Default settings for the Smart Learning Edition, and a device ID"
```

---

### Task 8：`.deb` 打包，實機驗收

**Files:**
- Modify: `CMakeLists.txt`（加入 CPack DEB 設定）
- Modify: `scripts/docker-build-test.sh`（加 `package` 參數：多跑 `cpack -G DEB`）
- Modify: `README.md`（最上方加智慧學習版說明、安裝方式、Synology Drive 共用詞庫的步驟）
- Create: `docs/acceptance-phase1.md`（驗收紀錄）

**Interfaces:**
- Produces：`build-docker/fcitx5-mcbopomofo-smart-learning_<版本>_amd64.deb`。版本格式為 `<上游版本>-learning.1`。

- [ ] **Step 1：CPack 設定**：
  - `CPACK_DEBIAN_PACKAGE_DEPENDS` 由 `CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON` 自動產生，另加 `fcitx5`。
  - `CPACK_DEBIAN_PACKAGE_CONFLICTS` 設為 `fcitx5-mcbopomofo`。
  - 套件名稱 `fcitx5-mcbopomofo-smart-learning`。

- [ ] **Step 2：在 ubt 打包**

Run: `ssh ubt 'cd src/fcitx5-mcbopomofo && scripts/docker-build-test.sh package'`
Expected：測試 PASS，產生 `.deb`。在 container 內執行 `dpkg -I <deb>` 會列出相依套件。

- [ ] **Step 3：安裝 smoke test**：用乾淨的 `ubuntu:24.04` container 執行 `apt install ./<deb>`。
Expected：安裝成功，`/usr/lib/x86_64-linux-gnu/fcitx5/mcbopomofo.so` 與 `/usr/share/fcitx5/inputmethod/mcbopomofo.conf` 存在。

- [ ] **Step 4：實機驗收**（使用者的 Mint／Ubuntu 筆電。需要使用者自己操作的步驟要先跟使用者確認）。逐項記錄到 `docs/acceptance-phase1.md`：
  1. 安裝 fcitx5 與 `.deb`，在系統輸入法設定加入小麥（Ubuntu GNOME 要另裝 Input Method Panel 擴充套件）。
  2. 安裝 Synology Drive Client（使用者從 Synology 官網下載），同步 `Drive/McBopomofo`。
  3. fcitx5 設定把「User data folder」指到同步下來的 `McBopomofo` 資料夾。
  4. 打一段日常文字：許氏鍵盤、`asdfghjkl` 選字、空白選字、Esc、數字鍵盤 Enter、Caps Lock 都和 Mac 相同。
  5. Mac 上加的 `data.txt` 詞在 Linux 打得出來；Linux 加的詞在 Mac 打得出來。
  6. 在 Mac 對某個讀音選次選字幾次後，Linux 切一次輸入法再打同一讀音，會優先出現該次選字。反過來也一樣。
  7. `learning/` 出現 `<裝置ID>-<主機名>.txt`，而 Mac 的兩個檔案內容不變。

- [ ] **Step 5：Commit 並發布**

```bash
git add CMakeLists.txt scripts README.md docs/acceptance-phase1.md
git commit -m "Package as a .deb, and the phase 1 acceptance record"
git tag v<上游版本>-learning.1 && git push --follow-tags
gh release create v<上游版本>-learning.1 build-docker/*.deb --title "智慧學習版 Linux 第一版" --notes-file docs/acceptance-phase1.md
```

---

## 之後的階段（各自另寫計畫）

第二到第四階段要在第一階段完成後才寫計畫，因為它們都建立在 Task 3／Task 4 的模組介面和 Task 1 的檔案格式規格上。每個階段的計畫都照同樣的方式寫：純 C++ 模組加測試，fcitx5 層只負責接線。

- **第二階段（中英混打）**：`SmartLearning/ChineseEnglish`（智慧切換規則、英文接中文自動轉回、自動空格、英數後半形標點、大小寫修正）、`SmartLearning/EscTrim`；KeyHandler 對齊 Mac `KeyHandler.mm` 的 Smart 區塊；中英模式圖示（fcitx5 status area）。
- **第三階段（學習與快打）**：`TemporaryPhraseStore`、拆詞學習、`EnglishWords`（打過的字與補完；拼字檢查改用 hunspell）、`QuickNumbers`、算式、`CommonSentences`、`RemovedEntries`、文字範本、符號表兩鍵選字、候選字 `+`／`-`。
- **第四階段（視窗與周邊）**：Qt6 管理詞彙程式、浮動組字窗的 fcitx5 對應方式、候選字主題、使用說明頁、與 Mac 共用模組的回收計畫。
