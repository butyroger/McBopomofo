# OpenVanilla McBopomofo 小麥注音輸入法

> **這是 [openvanilla/McBopomofo](https://github.com/openvanilla/McBopomofo) 的非官方分支（`smart-learning`），加強選字學習。** 官方版本與問題回報請到原專案。

## 這個分支優化了什麼

原版小麥注音雖然會記住你手動選的字詞（User Override Model），但有兩個限制，導致同樣的詞每次都要重新選：

- 學習結果只存在記憶體，登出、重開機或輸入法重新啟動就全部消失。
- 記憶的半衰期只有 1.5 小時、最多 500 筆，隔天就忘了。

本分支的改動：

1. **學習結果寫入檔案，多台 Mac 共用**：每次選字後（約 2 秒內）存進使用者詞庫資料夾的 `learning/` 子資料夾，啟動時讀回，重開機也記得。詞庫資料夾若設在 iCloud Drive 等同步位置，多台 Mac 的學習記錄會自動合併：
   - 每台電腦只寫自己的檔案（`<裝置代號>-<電腦名稱>.txt`），讀取時合併所有電腦的記錄，不會互相覆蓋或產生同步衝突檔。
   - 其他電腦的記錄同步過來時會即時重新合併；學習檔的變動不會觸發詞庫重新載入。
   - iCloud 把檔案移出本機（只留 `.icloud` 占位檔）時，會先觸發下載，載入完成前不會覆寫雲端的檔案。
2. **記得更久**：半衰期由 1.5 小時改為 30 天，每台容量由 500 筆增為 5000 筆。
3. **常選的詞自動加入使用者詞庫**：兩個字以上的詞，（所有電腦合計）手動選了 3 次之後會自動寫入 `data.txt`，並跳出「已學會詞彙」通知；之後不需前後文也會優先出現。曾經排除（選字時按 `-`）的詞不會被自動加回。

想清除學習記錄，刪掉 `learning/` 資料夾裡的檔案即可；自動加入的詞可以在「編輯使用者詞彙」裡刪除。

### 小提示：Caps Lock 切換英文會卡、第一個字變大寫

這是 macOS「使用大寫鎖定鍵切換『ABC』輸入法」造成的：系統要先判斷輕按（切換輸入法）還是長按（大寫鎖定），所以會延遲，判斷錯就變成大寫。建議到「系統設定 → 鍵盤 → 輸入方式」關掉該選項，小麥注音本身在 Caps Lock 開啟時就會直接輸出小寫英文。

### 自行編譯安裝

```bash
xcodebuild -project McBopomofo.xcodeproj -scheme McBopomofo -configuration Release \
  -derivedDataPath build build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
ditto build/Build/Products/Release/McBopomofo.app ~/Library/Input\ Methods/McBopomofo.app
pkill -x McBopomofo
```

---

## 系統需求

小麥注音輸入法可以在 macOS 13 以上版本運作。如果您要自行編譯小麥注音輸入法，或參與開發，您需要：

- macOS 26 或更高版本
- Xcode 26 或更高版本
- Python 3.9 (使用 Xcode 安裝後內附的就可以，也可使用 homebrew 等方式安裝)

## 開發流程

用 Xcode 開啟 `McBopomofo.xcodeproj`，選 "McBopomofo Installer" target，build 完之後直接執行該安裝程式，就可以安裝小麥注音。

第一次安裝完，日後程式碼或詞庫有任何修改，只要重複上述流程，再次安裝小麥注音即可。

要注意的是 macOS 可能會限制同一次 login session 能 kill 同一個輸入法 process 的次數（安裝程式透過 kill input method process 來讓新版的輸入法生效）。如果安裝若干次後，發現程式修改的結果並沒有出現，或甚至輸入法已無法再選用，只要登出目前帳號再重新登入即可。

## 社群公約

歡迎小麥注音用戶回報問題與指教，也歡迎大家參與小麥注音開發。

首先，請參考我們在「[常見問題](https://github.com/openvanilla/McBopomofo/wiki/常見問題)」中所提「[我可以怎麼參與小麥注音？](https://github.com/openvanilla/McBopomofo/wiki/常見問題#我可以怎麼參與小麥注音)」一節的說明。

我們採用了 GitHub 的[通用社群公約](https://github.com/openvanilla/McBopomofo/blob/master/CODE_OF_CONDUCT.md)。公約的中文版請參考[這裡的翻譯](https://www.contributor-covenant.org/zh-tw/version/1/4/code-of-conduct/)。

## 軟體授權

本專案採用 MIT License 釋出，使用者可自由使用、散播本軟體，惟散播時必須完整保留版權聲明及軟體授權（[詳全文](https://github.com/openvanilla/McBopomofo/blob/master/LICENSE.txt)）。
