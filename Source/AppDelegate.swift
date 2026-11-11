// Copyright (c) 2022 and onwards The McBopomofo Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import Carbon
import Cocoa
import FSEventStreamHelper
import IOKit
import InputMethodKit
import NotifierUI

private let kCheckUpdateAutomatically = "CheckUpdateAutomatically"
private let kNextUpdateCheckDateKey = "NextUpdateCheckDate"
private let kUpdateInfoEndpointKey = "UpdateInfoEndpoint"
private let kUpdateInfoSiteKey = "UpdateInfoSite"
private let kNextCheckInterval: TimeInterval = 86400.0
private let kTimeoutInterval: TimeInterval = 60.0

struct VersionUpdateReport {
    var siteUrl: URL?
    var currentShortVersion: String = ""
    var currentVersion: String = ""
    var remoteShortVersion: String = ""
    var remoteVersion: String = ""
    var versionDescription: String = ""
}

enum VersionUpdateApiResult {
    case shouldUpdate(report: VersionUpdateReport)
    case noNeedToUpdate
    case ignored
}

enum VersionUpdateApiError: Error, LocalizedError {
    case connectionError(message: String)

    var errorDescription: String? {
        switch self {
        case .connectionError(let message):
            return String(
                format: NSLocalizedString(
                    "There may be no internet connection or the server failed to respond.\n\nError message: %@",
                    comment: ""), message)
        }
    }
}

struct VersionUpdateApi {
    static func check(
        forced: Bool, callback: @escaping (Result<VersionUpdateApiResult, Error>) -> Void
    ) -> URLSessionTask? {
        guard let infoDict = Bundle.main.infoDictionary,
            let updateInfoURLString = infoDict[kUpdateInfoEndpointKey] as? String,
            let updateInfoURL = URL(string: (updateInfoURLString + (forced ? "?manual=yes" : "")))
        else {
            return nil
        }

        let request = URLRequest(
            url: updateInfoURL, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: kTimeoutInterval)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    forced
                        ? callback(
                            .failure(
                                VersionUpdateApiError.connectionError(
                                    message: error.localizedDescription)))
                        : callback(.success(.ignored))
                }
                return
            }

            do {
                guard
                    let plist = try PropertyListSerialization.propertyList(
                        from: data ?? Data(), options: [], format: nil) as? [AnyHashable: Any],
                    let remoteVersion = plist[kCFBundleVersionKey] as? String,
                    let infoDict = Bundle.main.infoDictionary
                else {
                    DispatchQueue.main.async {
                        forced ? callback(.success(.noNeedToUpdate)) : callback(.success(.ignored))
                    }
                    return
                }

                // TODO: Validate info (e.g. bundle identifier)
                // TODO: Use HTML to display change log, need a new key like UpdateInfoChangeLogURL for this

                let currentVersion = infoDict[kCFBundleVersionKey as String] as? String ?? ""
                let result = currentVersion.compare(
                    remoteVersion, options: .numeric, range: nil, locale: nil)

                if result != .orderedAscending {
                    DispatchQueue.main.async {
                        forced ? callback(.success(.noNeedToUpdate)) : callback(.success(.ignored))
                    }
                    return
                }

                guard let siteInfoURLString = plist[kUpdateInfoSiteKey] as? String,
                    let siteInfoURL = URL(string: siteInfoURLString)
                else {
                    DispatchQueue.main.async {
                        forced ? callback(.success(.noNeedToUpdate)) : callback(.success(.ignored))
                    }
                    return
                }

                var report = VersionUpdateReport(siteUrl: siteInfoURL)
                var versionDescription = ""
                let versionDescriptions = plist["Description"] as? [AnyHashable: Any]
                if let versionDescriptions = versionDescriptions {
                    var locale = "en"
                    let supportedLocales = ["en", "zh-Hant", "zh-Hans"]
                    let preferredTags = Bundle.preferredLocalizations(from: supportedLocales)
                    if let first = preferredTags.first {
                        locale = first
                    }
                    versionDescription =
                        versionDescriptions[locale] as? String ?? versionDescriptions["en"]
                        as? String ?? ""
                    if !versionDescription.isEmpty {
                        versionDescription = "\n\n" + versionDescription
                    }
                }
                report.currentShortVersion = infoDict["CFBundleShortVersionString"] as? String ?? ""
                report.currentVersion = currentVersion
                report.remoteShortVersion = plist["CFBundleShortVersionString"] as? String ?? ""
                report.remoteVersion = remoteVersion
                report.versionDescription = versionDescription
                DispatchQueue.main.async {
                    callback(.success(.shouldUpdate(report: report)))
                }
            } catch {
                DispatchQueue.main.async {
                    forced ? callback(.success(.noNeedToUpdate)) : callback(.success(.ignored))
                }
            }
        }
        task.resume()
        return task
    }
}

@objc(AppDelegate)
class AppDelegate: NSObject, NSApplicationDelegate, NonModalAlertWindowControllerDelegate {

    @IBOutlet weak var window: NSWindow?
    private var preferencesWindowController: PreferencesWindowController?
    private var checkTask: URLSessionTask?
    private var updateNextStepURL: URL?
    private var fsStreamHelper: FSEventStreamHelper?
    private var serviceProvider = ServiceProvider()
    private var serviceProviderHelper = ServiceProviderInputHelper()

    func updateUserPhrases() {
        LanguageModelManager.loadUserPhrases(
            enableForPlainBopomofo: Preferences.enableUserPhrasesInPlainBopomofo)
        LanguageModelManager.loadUserPhraseReplacement()
        // The user phrase folder may have changed.
        LanguageModelManager.reloadUserOverrideModel()

        fsStreamHelper?.delegate = nil
        fsStreamHelper?.stop()
        fsStreamHelper = FSEventStreamHelper(
            path: LanguageModelManager.dataFolderPath, queue: DispatchQueue(label: "User Phrases"))
        fsStreamHelper?.delegate = self
        _ = fsStreamHelper?.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LanguageModelManager.setupDataModelValueConverter()
        updateUserPhrases()

        if UserDefaults.standard.object(forKey: kCheckUpdateAutomatically) == nil {
            UserDefaults.standard.set(true, forKey: kCheckUpdateAutomatically)
            UserDefaults.standard.synchronize()
        }

        if UserDefaults.standard.object(forKey: kBeepUponInputErrorKey) == nil {
            UserDefaults.standard.set(true, forKey: kBeepUponInputErrorKey)
            UserDefaults.standard.synchronize()
        }

        NotificationCenter.default.addObserver(
            forName: .userPhraseLocationDidChange, object: nil, queue: OperationQueue.main
        ) { notification in
            self.updateUserPhrases()
        }

        serviceProvider.delegate = (serviceProviderHelper as! any ServiceProviderDelegate)
        NSApp.servicesProvider = serviceProvider

        enableBopomofoFontAnnotationSupportMenuItemIfRelevantFontsInstalled()

        ChineseEnglishSwitchReminder.shared.start()
        SecureInputMonitor.shared.start()

        checkForUpdate()
    }

    private var vocabularyManagerWindowController: VocabularyManagerWindowController?

    @objc func showVocabularyManager() {
        if vocabularyManagerWindowController == nil {
            vocabularyManagerWindowController = VocabularyManagerWindowController()
        }
        vocabularyManagerWindowController?.showAndActivate()
    }

    @MainActor
    @objc func showPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.showAndActivate()
    }

    @objc(checkForUpdate)
    func checkForUpdate() {
        checkForUpdate(forced: false)
    }

    @objc(checkForUpdateForced:)
    func checkForUpdate(forced: Bool) {
        if checkTask != nil {
            // busy
            return
        }

        // time for update?
        if !forced {
            if UserDefaults.standard.bool(forKey: kCheckUpdateAutomatically) == false {
                return
            }
            let now = Date()
            let date = UserDefaults.standard.object(forKey: kNextUpdateCheckDateKey) as? Date ?? now
            if now.compare(date) == .orderedAscending {
                return
            }
        }

        let nextUpdateDate = Date(timeInterval: kNextCheckInterval, since: Date())
        UserDefaults.standard.set(nextUpdateDate, forKey: kNextUpdateCheckDateKey)

        checkTask = VersionUpdateApi.check(forced: forced) { result in
            defer {
                self.checkTask = nil
            }
            switch result {
            case .success(let apiResult):
                switch apiResult {
                case .shouldUpdate(let report):
                    self.updateNextStepURL = report.siteUrl
                    let content = String(
                        format: NSLocalizedString(
                            "You're currently using McBopomofo %@ (%@), a new version %@ (%@) is now available. Do you want to visit McBopomofo's website to download the version?%@",
                            comment: ""),
                        report.currentShortVersion,
                        report.currentVersion,
                        report.remoteShortVersion,
                        report.remoteVersion,
                        report.versionDescription)
                    NonModalAlertWindowController.shared.show(
                        title: NSLocalizedString("New Version Available", comment: ""),
                        content: content,
                        confirmButtonTitle: NSLocalizedString("Visit Website", comment: ""),
                        cancelButtonTitle: NSLocalizedString("Not Now", comment: ""),
                        cancelAsDefault: false, delegate: self)
                case .noNeedToUpdate:
                    NonModalAlertWindowController.shared.show(
                        title: NSLocalizedString("Check for Update Completed", comment: ""),
                        content: NSLocalizedString("McBopomofo is up to date.", comment: ""),
                        confirmButtonTitle: NSLocalizedString("OK", comment: ""),
                        cancelButtonTitle: nil, cancelAsDefault: false, delegate: self)
                case .ignored:
                    break
                }
            case .failure(let error):
                switch error {
                case VersionUpdateApiError.connectionError(let message):
                    let title = NSLocalizedString("Update Check Failed", comment: "")
                    let content = String(
                        format: NSLocalizedString(
                            "There may be no internet connection or the server failed to respond.\n\nError message: %@",
                            comment: ""), message)
                    let buttonTitle = NSLocalizedString("Dismiss", comment: "")
                    NonModalAlertWindowController.shared.show(
                        title: title, content: content, confirmButtonTitle: buttonTitle,
                        cancelButtonTitle: nil, cancelAsDefault: false, delegate: nil)
                default:
                    break
                }
            }
        }
    }

    func nonModalAlertWindowControllerDidConfirm(_ controller: NonModalAlertWindowController) {
        if let updateNextStepURL = updateNextStepURL {
            NSWorkspace.shared.open(updateNextStepURL)
        }
        updateNextStepURL = nil
    }

    func nonModalAlertWindowControllerDidCancel(_ controller: NonModalAlertWindowController) {
        updateNextStepURL = nil
    }
}

extension AppDelegate: FSEventStreamHelperDelegate {
    func helper(_ helper: FSEventStreamHelper, didReceive events: [FSEventStreamHelper.Event]) {
        let learningFolder = (LanguageModelManager.userOverrideModelFolderPath as NSString)
            .resolvingSymlinksInPath
        let isLearningFolder: (FSEventStreamHelper.Event) -> Bool = {
            ($0.path as NSString).resolvingSymlinksInPath.hasPrefix(learningFolder)
        }
        if events.contains(where: isLearningFolder) {
            DispatchQueue.main.async {
                LanguageModelManager.reloadUserOverrideModel()
            }
        }
        // Saving the user override model happens all the time, and it
        // should not trigger reloading the user phrases.
        if events.allSatisfy(isLearningFolder) {
            return
        }
        DispatchQueue.main.async {
            LanguageModelManager.loadUserPhrases(
                enableForPlainBopomofo: Preferences.enableUserPhrasesInPlainBopomofo)
            LanguageModelManager.loadUserPhraseReplacement()
        }
    }
}

extension AppDelegate {
    private func open(userFileAt path: String) {
        func checkIfUserFilesExist() -> Bool {
            if !LanguageModelManager.checkIfUserLanguageModelFilesExist() {
                let content = String(
                    format: NSLocalizedString(
                        "Please check the permission of the path at \"%@\".", comment: ""),
                    LanguageModelManager.dataFolderPath)
                NonModalAlertWindowController.shared.show(
                    title: NSLocalizedString("Failed to Create the User Phrase File", comment: ""),
                    content: content, confirmButtonTitle: NSLocalizedString("OK", comment: ""),
                    cancelButtonTitle: nil, cancelAsDefault: false, delegate: nil)
                return false
            }
            return true
        }

        if !checkIfUserFilesExist() {
            return
        }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }

    @objc func openUserPhrases(_ sender: Any?) {
        open(userFileAt: LanguageModelManager.userPhrasesDataPathMcBopomofo)
    }

    @objc func openUserPhrasesPlainBopomofo(_ sender: Any?) {
        open(userFileAt: LanguageModelManager.userPhrasesDataPathPlainBopomofo)
    }

    @objc func openExcludedPhrasesPlainBopomofo(_ sender: Any?) {
        open(userFileAt: LanguageModelManager.excludedPhrasesDataPathPlainBopomofo)
    }

    @objc func openExcludedPhrasesMcBopomofo(_ sender: Any?) {
        open(userFileAt: LanguageModelManager.excludedPhrasesDataPathMcBopomofo)
    }

    @objc func openPhraseReplacementMcBopomofo(_ sender: Any?) {
        open(userFileAt: LanguageModelManager.phraseReplacementDataPathMcBopomofo)
    }

    @objc func openTextTemplates(_ sender: Any?) {
        InputState.TextTemplate.createSampleFileIfNeeded()
        open(userFileAt: LanguageModelManager.textTemplatesDataPath)
    }

    @objc func openSymbolTable(_ sender: Any?) {
        let path = LanguageModelManager.symbolTableDataPath
        if !FileManager.default.fileExists(atPath: path) {
            try? LanguageModelManager.defaultSymbolTable.write(
                toFile: path, atomically: true, encoding: .utf8)
        }
        open(userFileAt: path)
    }
}

extension AppDelegate {
    private func enableBopomofoFontAnnotationSupportMenuItemIfRelevantFontsInstalled() {
        guard !Preferences.bopomofoFontAnnotationSupportMenuItemEnabledByInstalledFontsCheck_V1
        else {
            return
        }

        Preferences.bopomofoFontAnnotationSupportMenuItemEnabledByInstalledFontsCheck_V1 = true

        let supportedFontNames = [
            "BpmfGenRyuMin-B",
            "BpmfGenRyuMin-EL",
            "BpmfGenRyuMin-H",
            "BpmfGenRyuMin-L",
            "BpmfGenRyuMin-M",
            "BpmfGenRyuMin-R",
            "BpmfGenRyuMin-SB",
            "BpmfGenSekiGothic-B",
            "BpmfGenSekiGothic-H",
            "BpmfGenSekiGothic-L",
            "BpmfGenSekiGothic-M",
            "BpmfGenSekiGothic-R",
            "BpmfGenSenRounded-B",
            "BpmfGenSenRounded-EL",
            "BpmfGenSenRounded-H",
            "BpmfGenSenRounded-L",
            "BpmfGenSenRounded-M",
            "BpmfGenSenRounded-R",
            "BpmfGenWanMin-EL",
            "BpmfGenWanMin-L",
            "BpmfGenWanMin-M",
            "BpmfGenWanMin-R",
            "BpmfGenWanMin-SB",
            "BpmfGenYoGothic-B",
            "BpmfGenYoGothic-EL",
            "BpmfGenYoGothic-H",
            "BpmfGenYoGothic-L",
            "BpmfGenYoGothic-M",
            "BpmfGenYoGothic-N",
            "BpmfGenYoGothic-R",
            "BpmfGenYoMin-B",
            "BpmfGenYoMin-EL",
            "BpmfGenYoMin-H",
            "BpmfGenYoMin-L",
            "BpmfGenYoMin-M",
            "BpmfGenYoMin-R",
            "BpmfGenYoMin-SB",
            "BpmfHuninn-Regular",
            "BpmfIansui-Regular",
            "BpmfZihiBox-R",
            "BpmfZihiKaiStd-Regular",
            "BpmfZihiOnly-R",
            "BpmfZihiSans-Bold",
            "BpmfZihiSans-ExtraLight",
            "BpmfZihiSans-Heavy",
            "BpmfZihiSans-Light",
            "BpmfZihiSans-Medium",
            "BpmfZihiSans-Regular",
            "BpmfZihiSerif-Bold",
            "BpmfZihiSerif-ExtraLight",
            "BpmfZihiSerif-Heavy",
            "BpmfZihiSerif-Light",
            "BpmfZihiSerif-Medium",
            "BpmfZihiSerif-Regular",
            "BpmfZihiSerif-SemiBold",
        ]

        var hasSupportingFont = false
        let allFonts = Set(NSFontManager.shared.availableFonts)
        for fontName in supportedFontNames {
            if allFonts.contains(fontName) {
                hasSupportingFont = true
                break
            }
        }

        if hasSupportingFont {
            Preferences.showBopomofoFontAnnotationSupportItemInInputMenu = true
        }
    }
}

/// Shows "ABC" or "中文" at the top-right corner of the screen when the user
/// switches between Chinese and English: Caps Lock in McBopomofo, or switching
/// between McBopomofo and another input source.
class ChineseEnglishSwitchReminder: NSObject {
    static let shared = ChineseEnglishSwitchReminder()

    private var isMcBopomofoSelected = false

    static func notify(isEnglish: Bool) {
        guard Preferences.chineseEnglishSwitchReminderEnabled else {
            return
        }
        NotifierController.notify(
            message: isEnglish
                ? NSLocalizedString("English Mode", comment: "")
                : NSLocalizedString("Chinese Mode", comment: ""))
    }

    func start() {
        isMcBopomofoSelected = Self.isMcBopomofo(Self.currentInputSourceID())
        ModeStatusBar.shared.setMcBopomofoSelected(isMcBopomofoSelected)
        // The input method is never the active app, so the notification has
        // to be delivered immediately, or it waits until the app is active.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(selectedInputSourceDidChange(_:)),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func selectedInputSourceDidChange(_ notification: Notification) {
        DispatchQueue.main.async {
            let selected = Self.isMcBopomofo(Self.currentInputSourceID())
            if selected == self.isMcBopomofoSelected {
                return
            }
            self.isMcBopomofoSelected = selected
            ModeStatusBar.shared.setMcBopomofoSelected(selected)
            // With Caps Lock on, McBopomofo types English letters.
            Self.notify(isEnglish: !selected || NSEvent.modifierFlags.contains(.capsLock))
        }
    }

    private static func currentInputSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func isMcBopomofo(_ sourceID: String?) -> Bool {
        guard let sourceID, let bundleID = Bundle.main.bundleIdentifier else {
            return false
        }
        return sourceID.hasPrefix(bundleID)
    }
}

/// Shows the mode of McBopomofo in the menu bar while it is the selected
/// input source: "中" or "英", and "全" or "半" for the punctuation width.
@objc class ModeStatusBar: NSObject {
    @objc static let shared = ModeStatusBar()

    private var isMcBopomofoSelected = false
    private var isCapsLockOn = false
    private var isSmartEnglishMode = false

    // Created in this order, so that "全/半" is on the left of "中/英".
    private lazy var languageItem = makeItem(action: nil)
    private lazy var widthItem = makeItem(action: #selector(toggleHalfWidthPunctuation(_:)))

    func setMcBopomofoSelected(_ selected: Bool) {
        isMcBopomofoSelected = selected
        // Caps Lock may have been toggled while another input source is used.
        isCapsLockOn = NSEvent.modifierFlags.contains(.capsLock)
        update()
    }

    func setCapsLockOn(_ on: Bool) {
        isCapsLockOn = on
        update()
    }

    @objc func setSmartEnglishMode(_ englishMode: Bool) {
        isSmartEnglishMode = englishMode
        update()
    }

    @objc func update() {
        let showLanguage = isMcBopomofoSelected && Preferences.showChineseEnglishModeIcon
        let showWidth = isMcBopomofoSelected && Preferences.showFullHalfWidthModeIcon
        // Do not create the items until they are to be shown.
        if !showLanguage && !showWidth && !itemsCreated {
            return
        }
        languageItem.isVisible = showLanguage
        languageItem.button?.title = isCapsLockOn || isSmartEnglishMode ? "英" : "中"
        widthItem.isVisible = showWidth
        widthItem.button?.title = Preferences.halfWidthPunctuationEnabled ? "半" : "全"
    }

    private var itemsCreated = false

    private func makeItem(action: Selector?) -> NSStatusItem {
        itemsCreated = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.menuBarFont(ofSize: 0)
        if let action {
            item.button?.target = self
            item.button?.action = action
        }
        return item
    }

    @objc private func toggleHalfWidthPunctuation(_ sender: Any?) {
        _ = Preferences.toggleHalfWidthPunctuationEnabled()
        update()
    }
}

/// Tells the user which app has turned on Secure Input for a while. While it
/// is on, macOS disables all third-party input methods, so McBopomofo turns
/// gray in the input menu and cannot be selected. An app may leave it on, such
/// as a password manager or a password field that is never closed.
class SecureInputMonitor: NSObject, NonModalAlertWindowControllerDelegate {
    static let shared = SecureInputMonitor()

    private static let checkInterval: TimeInterval = 10
    /// How long Secure Input has to be on before the user is told, since
    /// typing a password in a password field turns it on for a short while.
    private static let delay: TimeInterval = 90

    private var timer: Timer?
    private var since: Date?
    private var notified = false

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) {
            [weak self] _ in
            self?.check()
        }
    }

    private func check() {
        // The PID reported may change while it is on, such as to the
        // frontmost app, so only the time it has been on counts.
        guard Preferences.secureInputReminderEnabled, let pid = Self.secureInputPID(),
            !Self.isScreenLocked()
        else {
            since = nil
            notified = false
            return
        }
        guard let since else {
            since = Date()
            return
        }
        if !notified && Date().timeIntervalSince(since) >= Self.delay {
            notified = true
            showAlert(pid: pid)
        }
    }

    private func showAlert(pid: pid_t) {
        let isRunning = kill(pid, 0) == 0 || errno == EPERM
        let name = Self.appName(pid: pid)
        let content: String
        if !isRunning {
            content = String(
                format: NSLocalizedString(
                    "The app that turned on Secure Input (PID %d) has quit, but macOS has not turned it off. Third-party input methods, including McBopomofo, cannot be used until then.\n\nPlease log out and log in again.",
                    comment: ""), pid)
        } else if name == "loginwindow" {
            content = NSLocalizedString(
                "macOS reports that the login window has turned on Secure Input, which usually comes from a password manager or a password field in a browser. Third-party input methods, including McBopomofo, cannot be used while it is on.\n\nPlease try:\n1. Quit the password manager, such as 1Password, completely.\n2. Close the pages or windows waiting for a password.\n3. Lock the screen and unlock it with your password.\n4. Log out and log in again.",
                comment: "")
        } else {
            content = String(
                format: NSLocalizedString(
                    "\"%@\" (PID %d) has turned on Secure Input for more than a minute and a half. Third-party input methods, including McBopomofo, cannot be used while it is on.\n\nIf McBopomofo is gray in the input menu, please try:\n1. Close the pages or windows in the app waiting for a password.\n2. Quit the app completely and open it again.\n3. For a terminal, turn off \"Secure Keyboard Entry\".\n4. Lock the screen and unlock it, or log out and log in again.\n\nThe app name reported by macOS may not be accurate.",
                    comment: ""), name, pid)
        }
        NonModalAlertWindowController.shared.show(
            title: NSLocalizedString("Secure Input Is On", comment: ""), content: content,
            confirmButtonTitle: NSLocalizedString("OK", comment: ""),
            cancelButtonTitle: NSLocalizedString("Don't Remind Me Again", comment: ""),
            cancelAsDefault: false, delegate: self)
    }

    func nonModalAlertWindowControllerDidConfirm(_ controller: NonModalAlertWindowController) {
    }

    func nonModalAlertWindowControllerDidCancel(_ controller: NonModalAlertWindowController) {
        Preferences.secureInputReminderEnabled = false
    }

    /// The process that has turned on Secure Input in the session of the
    /// user, as reported by the I/O Registry.
    static func secureInputPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard
            let property = IORegistryEntryCreateCFProperty(
                root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
            let users = property as? [[String: Any]]
        else {
            return nil
        }
        let uid = Int(getuid())
        for user in users {
            if let userID = user["kCGSSessionUserIDKey"] as? Int, userID != uid {
                continue
            }
            if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 {
                return pid_t(pid)
            }
        }
        return nil
    }

    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private static func appName(pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 1024)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            return String(cString: buffer)
        }
        return "PID \(pid)"
    }
}
