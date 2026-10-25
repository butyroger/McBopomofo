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

#import "LanguageModelManager.h"
#import "LanguageModelManager+Privates.h"
#import "McBopomofo-Swift.h"

#include "UTF8Helper.h"
#include "AssociatedPhrasesV2.h"

@import OpenCCBridge;
@import SystemConfiguration;

static const int kUserOverrideModelCapacity = 5000;
static const int kMergedUserOverrideModelCapacity = 20000;
static const double kUserOverrideModelSaveDelay = 2.0;
static const double kObservedOverrideHalflife = 30.0 * 86400.0; // 30 days.

static McBopomofo::McBopomofoLM gLanguageModelMcBopomofo;
static McBopomofo::McBopomofoLM gLanguageModelPlainBopomofo;
// What the user picked on this device. This is what gets saved.
static McBopomofo::UserOverrideModel gLocalUserOverrideModel(kUserOverrideModelCapacity, kObservedOverrideHalflife);
// gLocalUserOverrideModel plus what the user picked on other devices sharing
// the same user phrase folder. This is what the suggestions come from.
static McBopomofo::UserOverrideModel gUserOverrideModel(kMergedUserOverrideModelCapacity, kObservedOverrideHalflife);
static McBopomofo::VariantAnnotator gVariantAnnotator;

static NSString *const kUserDataTemplateName = @"template-data";
static NSString *const kUserDataPlainBopomofoTemplateName = @"template-data-plain-bpmf";
static NSString *const kExcludedPhrasesMcBopomofoTemplateName = @"template-exclude-phrases";
static NSString *const kExcludedPhrasesPlainBopomofoTemplateName = @"template-exclude-phrases-plain-bpmf";
static NSString *const kPhraseReplacementTemplateName = @"template-phrases-replacement";
static NSString *const kTemplateExtension = @".txt";
static NSString *const kSymbolTableFilename = @"symbol-table.txt";
static NSString *const kTextTemplatesFilename = @"text-templates.txt";

// Used when the user data folder has no symbol table. Each line is a category
// title, a tab, and the symbols separated by spaces.
static NSString *const kDefaultSymbolTable =
    @"標點\t　 ， 、 。 ． ‧ ； ： ？ ！ ︰ ⋯ ‥ … ｜ — ︴ ﹏ ＃ ＆ ＊ ※ § 〃 ＠ ～\n"
    @"括號\t（ ） 「 」 『 』 《 》 〈 〉 【 】 〔 〕 ｛ ｝ ︵ ︶ ﹁ ﹂ ﹃ ﹄ ︽ ︾ ︿ ﹀ ︻ ︼ ︷ ︸ ︹ ︺\n"
    @"標記\t○ ● ◎ ☆ ★ ◇ ◆ □ ■ △ ▲ ▽ ▼ ㊣ ♀ ♂ ✓ ✗ ⊙ ♠ ♥ ♦ ♣ ♪ ♫ ☎ ☞\n"
    @"箭頭\t→ ← ↑ ↓ ↗ ↖ ↘ ↙ ⇒ ⇔ ↔ ↕\n"
    @"數學\t＋ － ± × ÷ ＝ ≠ ≒ ≡ ＜ ＞ ≦ ≧ ∞ √ ∴ ∵ ∠ ⊥ ∟ ⊿ ∩ ∪ ∫ ∼\n"
    @"單位\t％ ‰ ° ℃ ℉ ＄ ￥ ￡ € ￠ ㎜ ㎝ ㎞ ㎡ ㎎ ㎏ ㏄ ㏕ ㏎ ㎖ ㎗ ㎘\n"
    @"數字\t① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩ ⑴ ⑵ ⑶ ⑷ ⑸ ⑹ ⑺ ⑻ ⑼ ⑽ Ⅰ Ⅱ Ⅲ Ⅳ Ⅴ Ⅵ Ⅶ Ⅷ Ⅸ Ⅹ 〡 〢 〣 〤 〥 〦 〧 〨 〩 十 卄 卅\n"
    @"表格\t┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ ─ │ ═ ║ ╔ ╦ ╗ ╠ ╬ ╣ ╚ ╩ ╝ ╞ ╪ ╡ ╭ ╮ ╰ ╯ ╱ ╲ ╳\n"
    @"圖塊\t▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ▏ ▎ ▍ ▌ ▋ ▊ ▉ ▔ ░ ▒ ▓\n"
    @"希臘\tΑ Β Γ Δ Ε Ζ Η Θ Ι Κ Λ Μ Ν Ξ Ο Π Ρ Σ Τ Υ Φ Χ Ψ Ω α β γ δ ε ζ η θ ι κ λ μ ν ξ ο π ρ σ τ υ φ χ ψ ω\n"
    @"注音\tㄅ ㄆ ㄇ ㄈ ㄉ ㄊ ㄋ ㄌ ㄍ ㄎ ㄏ ㄐ ㄑ ㄒ ㄓ ㄔ ㄕ ㄖ ㄗ ㄘ ㄙ ㄧ ㄨ ㄩ ㄚ ㄛ ㄜ ㄝ ㄞ ㄟ ㄠ ㄡ ㄢ ㄣ ㄤ ㄥ ㄦ ˙ ˊ ˇ ˋ\n";

static NSString *const kUserOverrideModelFolderName = @"learning";
static NSString *const kUserOverrideModelDeviceIDKey = @"UserOverrideModelDeviceID";

@implementation LanguageModelManager

static void LTLoadLanguageModelFile(NSString *filenameWithoutExtension, McBopomofo::McBopomofoLM& lm)
{
    Class cls = NSClassFromString(@"McBopomofoInputMethodController");
    NSString *dataPath = [[NSBundle bundleForClass:cls] pathForResource:filenameWithoutExtension ofType:@"txt"];
    lm.loadLanguageModel(dataPath.UTF8String);
}

static void LTLoadAssociatedPhrases(McBopomofo::McBopomofoLM& lm)
{
    Class cls = NSClassFromString(@"McBopomofoInputMethodController");
    NSString *dataPath = [[NSBundle bundleForClass:cls] pathForResource:@"associated-phrases-v2" ofType:@"txt"];
    lm.loadAssociatedPhrasesV2(dataPath.UTF8String);
}

static void LTLoadVariantAnnotatorData()
{
    Class cls = NSClassFromString(@"McBopomofoInputMethodController");
    NSString *puaDataPath = [[NSBundle bundleForClass:cls] pathForResource:@"bpmfvs-pua" ofType:@"txt"];
    if (puaDataPath == nil) {
        NSLog(@"Error: No PUA data found in bundle");
        return;
    }

    NSString *variantsDataPath = [[NSBundle bundleForClass:cls] pathForResource:@"bpmfvs-variants" ofType:@"txt"];
    if (variantsDataPath == nil) {
        NSLog(@"Error: No variants data found in bundle");
        return;
    }

    BOOL puaLoaded = gVariantAnnotator.loadPUAFile(puaDataPath.UTF8String);
    BOOL variantsLoaded = gVariantAnnotator.loadVariantsFile(variantsDataPath.UTF8String);
    if (!gVariantAnnotator.loaded()) {
        NSLog(@"Error: VariantAnnotator not ready, puaLoaded: %d, variantsLoaded: %d", puaLoaded, variantsLoaded);
    }
}

+ (void)loadDataModels
{
    if (!gLanguageModelMcBopomofo.isDataModelLoaded()) {
        LTLoadLanguageModelFile(@"data", gLanguageModelMcBopomofo);
    }
    if (!gLanguageModelMcBopomofo.isAssociatedPhrasesV2Loaded()) {
        LTLoadAssociatedPhrases(gLanguageModelMcBopomofo);
    }

    if (!gLanguageModelPlainBopomofo.isDataModelLoaded()) {
        LTLoadLanguageModelFile(@"data-plain-bpmf", gLanguageModelPlainBopomofo);
    }
    if (!gLanguageModelPlainBopomofo.isAssociatedPhrasesV2Loaded()) {
        LTLoadAssociatedPhrases(gLanguageModelPlainBopomofo);
    }
    if (!gVariantAnnotator.loaded()) {
        LTLoadVariantAnnotatorData();
    }
}

+ (void)loadDataModel:(InputMode)mode
{
    if ([mode isEqualToString:InputModeBopomofo]) {
        if (!gLanguageModelMcBopomofo.isDataModelLoaded()) {
            LTLoadLanguageModelFile(@"data", gLanguageModelMcBopomofo);
        }
        if (!gLanguageModelMcBopomofo.isAssociatedPhrasesV2Loaded()) {
            LTLoadAssociatedPhrases(gLanguageModelMcBopomofo);
        }
        if (!gVariantAnnotator.loaded()) {
            LTLoadVariantAnnotatorData();
        }
    }

    if ([mode isEqualToString:InputModePlainBopomofo]) {
        if (!gLanguageModelPlainBopomofo.isDataModelLoaded()) {
            LTLoadLanguageModelFile(@"data-plain-bpmf", gLanguageModelPlainBopomofo);
        }
        if (!gLanguageModelPlainBopomofo.isAssociatedPhrasesV2Loaded()) {
            LTLoadAssociatedPhrases(gLanguageModelPlainBopomofo);
        }
        if (!gVariantAnnotator.loaded()) {
            LTLoadVariantAnnotatorData();
        }
    }
}

+ (void)loadUserPhrasesWithPlainBopomofoEnabled:(BOOL)userPhraseForPlainBopomofo
{
    [self _loadSymbolTable];
    gLanguageModelMcBopomofo.loadUserPhrases([self userPhrasesDataPathMcBopomofo].UTF8String, [self excludedPhrasesDataPathMcBopomofo].UTF8String);
    gLanguageModelPlainBopomofo.loadUserPhrases(userPhraseForPlainBopomofo ? [self userPhrasesDataPathPlainBopomofo].UTF8String : NULL,
        [self excludedPhrasesDataPathPlainBopomofo].UTF8String);
}

+ (void)loadUserPhraseReplacement
{
    gLanguageModelMcBopomofo.loadPhraseReplacementMap([self phraseReplacementDataPathMcBopomofo].UTF8String);
}

+ (void)setupDataModelValueConverter
{
    auto macroConverter = [](const std::string& input) {
        NSString *inputText = @(input.c_str());
        NSString *handled = [[InputMacroController shared] handle:inputText];
        return std::string(handled.UTF8String);
    };

    auto converter = [](const std::string& input) {
        if (!Preferences.chineseConversionEnabled) {
            return input;
        }

        if (Preferences.chineseConversionStyle == 0) {
            return input;
        }

        NSString *text = [[OpenCCBridge sharedInstance] convertToSimplified:@(input.c_str())];
        return std::string(text.UTF8String);
    };

    gLanguageModelMcBopomofo.setMacroConverter(macroConverter);
    gLanguageModelMcBopomofo.setExternalConverter(converter);
    gLanguageModelPlainBopomofo.setExternalConverter(converter);
}

+ (BOOL)checkIfUserDataFolderExists
{
    NSString *folderPath = [self dataFolderPath];
    BOOL isFolder = NO;
    BOOL folderExist = [[NSFileManager defaultManager] fileExistsAtPath:folderPath isDirectory:&isFolder];
    if (folderExist && !isFolder) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:folderPath error:&error];
        if (error) {
            NSLog(@"Failed to remove folder %@", error);
            return NO;
        }
        folderExist = NO;
    }
    if (!folderExist) {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"Failed to create folder %@", error);
            return NO;
        }
    }
    return YES;
}

+ (BOOL)ensureFileExists:(NSString *)filePath populateWithTemplate:(NSString *)templateBasename extension:(NSString *)ext
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {

        NSURL *templateURL = [[NSBundle mainBundle] URLForResource:templateBasename withExtension:ext];
        NSData *templateData;
        if (templateURL) {
            templateData = [NSData dataWithContentsOfURL:templateURL];
        } else {
            templateData = [@"" dataUsingEncoding:NSUTF8StringEncoding];
        }

        BOOL result = [templateData writeToFile:filePath atomically:YES];
        if (!result) {
            NSLog(@"Failed to write file");
            return NO;
        }
    }
    return YES;
}

+ (BOOL)checkIfUserLanguageModelFilesExist
{
    if (![self checkIfUserDataFolderExists]) {
        return NO;
    }
    if (![self ensureFileExists:[self userPhrasesDataPathMcBopomofo] populateWithTemplate:kUserDataTemplateName extension:kTemplateExtension]) {
        return NO;
    }
    if (![self ensureFileExists:[self userPhrasesDataPathPlainBopomofo] populateWithTemplate:kUserDataPlainBopomofoTemplateName extension:kTemplateExtension]) {
        return NO;
    }
    if (![self ensureFileExists:[self excludedPhrasesDataPathMcBopomofo] populateWithTemplate:kExcludedPhrasesMcBopomofoTemplateName extension:kTemplateExtension]) {
        return NO;
    }
    if (![self ensureFileExists:[self excludedPhrasesDataPathPlainBopomofo] populateWithTemplate:kExcludedPhrasesPlainBopomofoTemplateName extension:kTemplateExtension]) {
        return NO;
    }
    if (![self ensureFileExists:[self phraseReplacementDataPathMcBopomofo] populateWithTemplate:kPhraseReplacementTemplateName extension:kTemplateExtension]) {
        return NO;
    }
    return YES;
}

+ (BOOL)checkIfUserPhraseExist:(NSString *)userPhrase key:(NSString *)key NS_SWIFT_NAME(checkIfExist(userPhrase:key:))
{
    std::string unigramKey(key.UTF8String);
    auto unigrams = gLanguageModelMcBopomofo.getUnigrams(unigramKey);
    std::string userPhraseString(userPhrase.UTF8String);
    for (const auto& unigram : unigrams) {
        if (unigram.value() == userPhraseString) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)_checkIfPhrase:(NSString *)phrase existAtPath:(NSString *)path
{
    NSString *exactPhrase = nil;
    NSString *key = nil;
    NSArray *components = [phrase componentsSeparatedByString:@" "];
    if (components.count != 2) {
        return NO;
    }
    exactPhrase = components[0];
    key = components[1];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return NO;
    }
    NSError *error = nil;
    NSString *content = [[NSString alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] encoding:NSUTF8StringEncoding error:&error];
    if (error != nil) {
        return NO;
    }
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *lineComponents = [trimmed componentsSeparatedByString:@" "];
        if (lineComponents.count != 2) {
            continue;
        }
        if ([lineComponents[0] isEqualToString:exactPhrase] &&
            [lineComponents[1] isEqualToString:key]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)_writePhrase:(NSString *)phrase atEndOfPath:(NSString *)path
{
    BOOL addLineBreakAtFront = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSError *error = nil;
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
        unsigned long long fileSize = [attr fileSize];
        if (!error && fileSize) {
            NSFileHandle *readFile = [NSFileHandle fileHandleForReadingAtPath:path];
            if (readFile) {
                [readFile seekToFileOffset:fileSize - 1];
                NSData *data = [readFile readDataToEndOfFile];
                const void *bytes = data.bytes;
                if (*(char *)bytes != '\n') {
                    addLineBreakAtFront = YES;
                }
                [readFile closeFile];
            }
        }
    }
    NSMutableString *currentMarkedPhrase = [NSMutableString string];
    if (addLineBreakAtFront) {
        [currentMarkedPhrase appendString:@"\n"];
    }
    [currentMarkedPhrase appendString:phrase];
    [currentMarkedPhrase appendString:@"\n"];

    NSFileHandle *writeFile = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (!writeFile) {
        return NO;
    }

    [writeFile seekToEndOfFile];
    NSData *data = [currentMarkedPhrase dataUsingEncoding:NSUTF8StringEncoding];
    [writeFile writeData:data];
    [writeFile closeFile];
    return YES;
}

+ (BOOL)_removePhrase:(NSString *)phrase atPath:(NSString *)path
{
    NSString *exactPhrase = nil;
    NSString *key = nil;
    NSArray *components = [phrase componentsSeparatedByString:@" "];
    if (components.count != 2) {
        return NO;
    }
    exactPhrase = components[0];
    key = components[1];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return NO;
    }
    NSError *error = nil;
    NSString *content = [[NSString alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] encoding:NSUTF8StringEncoding error:&error];
    if (error != nil) {
        return NO;
    }
    NSArray *lines = [content componentsSeparatedByString:@"\n"];

    BOOL result = NO;
    NSMutableString *mutableString = [NSMutableString string];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *lineComponents = [trimmed componentsSeparatedByString:@" "];
        if (lineComponents.count != 2) {
            [mutableString appendString:line];
            [mutableString appendString:@"\n"];
            continue;
        }
        if ([lineComponents[0] isEqualToString:exactPhrase] &&
            [lineComponents[1] isEqualToString:key]) {
            result = YES;
            continue;
        }
        [mutableString appendString:line];
        [mutableString appendString:@"\n"];
    }
    if (result) {
        NSError *writeError;
        [mutableString writeToURL:[NSURL fileURLWithPath:path] atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        if (writeError != nil) {
            return NO;
        }
        return YES;
    }

    return NO;
}

+ (BOOL)writeUserPhrase:(NSString *)userPhrase
{
    if (![self checkIfUserLanguageModelFilesExist]) {
        return NO;
    }

    NSString *excludePath = [self excludedPhrasesDataPathMcBopomofo];
    [self _removePhrase:userPhrase atPath:excludePath];

    NSString *includePath = [self userPhrasesDataPathMcBopomofo];
    if ([self _checkIfPhrase:userPhrase existAtPath:includePath]) {
        return NO;
    }
    BOOL result = [self _writePhrase:userPhrase atEndOfPath:includePath];

    //  We use FSEventStream to monitor the change of the user phrase folder,
    //  so we don't have to load data here.
    //  [self loadUserPhrases];
    return result;
}

+ (BOOL)learnUserPhrase:(NSString *)userPhrase
{
    if (![self checkIfUserLanguageModelFilesExist]) {
        return NO;
    }

    // Unlike writeUserPhrase:, respect the user's decision to exclude a
    // phrase, and never bring it back automatically.
    if ([self _checkIfPhrase:userPhrase existAtPath:[self excludedPhrasesDataPathMcBopomofo]]) {
        return NO;
    }

    NSArray *components = [userPhrase componentsSeparatedByString:@" "];
    if (components.count != 2) {
        return NO;
    }
    NSString *phrase = components[0];
    NSString *reading = components[1];

    NSString *path = [self userPhrasesDataPathMcBopomofo];
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (content == nil) {
        return NO;
    }

    // Among the user phrases of the same reading, the earlier one wins. So the
    // learned phrase goes before the others, and the latest choice prevails.
    NSMutableArray<NSString *> *lines = [[content componentsSeparatedByString:@"\n"] mutableCopy];
    NSUInteger firstIndexOfReading = NSNotFound;
    NSMutableIndexSet *phraseIndexes = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *trimmed = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *lineComponents = [trimmed componentsSeparatedByString:@" "];
        if ([trimmed hasPrefix:@"#"] || lineComponents.count != 2 || ![lineComponents[1] isEqualToString:reading]) {
            continue;
        }
        if (firstIndexOfReading == NSNotFound) {
            firstIndexOfReading = i;
        }
        if ([lineComponents[0] isEqualToString:phrase]) {
            [phraseIndexes addIndex:i];
        }
    }

    if (firstIndexOfReading == NSNotFound) {
        return [self _writePhrase:userPhrase atEndOfPath:path];
    }
    if ([phraseIndexes containsIndex:firstIndexOfReading]) {
        // Already the first one.
        return NO;
    }

    [lines removeObjectsAtIndexes:phraseIndexes];
    [lines insertObject:userPhrase atIndex:firstIndexOfReading];
    NSString *newContent = [lines componentsJoinedByString:@"\n"];
    if (![newContent writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSLog(@"Failed to write %@: %@", path, error);
        return NO;
    }
    return YES;
}

+ (BOOL)removeUserPhrase:(NSString *)userPhrase
{
    if (![self checkIfUserLanguageModelFilesExist]) {
        return NO;
    }

    NSString *includePath = [self userPhrasesDataPathMcBopomofo];
    [self _removePhrase:userPhrase atPath:includePath];

    NSString *excludePath = [self excludedPhrasesDataPathMcBopomofo];
    if ([self _checkIfPhrase:userPhrase existAtPath:excludePath]) {
        return NO;
    }
    BOOL result = [self _writePhrase:userPhrase atEndOfPath:excludePath];

    //  We use FSEventStream to monitor the change of the user phrase folder,
    //  so we don't have to load data here.
    //  [self loadUserPhrases];
    return result;
}

+ (NSString *)dataFolderPath
{
    BOOL useCustomLocation = Preferences.useCustomUserPhraseLocation;
    if (!useCustomLocation) {
        return [UserPhraseLocationHelper defaultUserPhraseLocation];
    }
    return Preferences.customUserPhraseLocation;
}

+ (NSString *)symbolTableDataPath
{
    return [[self dataFolderPath] stringByAppendingPathComponent:kSymbolTableFilename];
}

+ (NSString *)textTemplatesDataPath
{
    return [[self dataFolderPath] stringByAppendingPathComponent:kTextTemplatesFilename];
}

+ (NSString *)defaultSymbolTable
{
    return [NSLocalizedString(@"# Symbol table. Each line is a category, a tab, and the symbols separated by spaces.\n", @"") stringByAppendingString:kDefaultSymbolTable];
}

+ (void)_loadSymbolTable
{
    NSString *content = [NSString stringWithContentsOfFile:[self symbolTableDataPath] encoding:NSUTF8StringEncoding error:nil];
    if (content.length == 0) {
        content = kDefaultSymbolTable;
    }

    std::vector<McBopomofo::McBopomofoLM::SymbolCategory> table;
    NSCharacterSet *asciiWhitespaces = [NSCharacterSet characterSetWithCharactersInString:@" \t\r"];
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([line hasPrefix:@"#"] || [line hasPrefix:@"\uFEFF#"]) {
            continue;
        }
        NSRange tab = [line rangeOfString:@"\t"];
        if (tab.location == NSNotFound) {
            continue;
        }
        // A trailing "*" marks a category in the symbol table of some other
        // input methods. It is not a part of the title.
        NSString *title = [[line substringToIndex:tab.location] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\uFEFF* "]];
        McBopomofo::McBopomofoLM::SymbolCategory category;
        category.title = title.UTF8String;
        // Separated by ASCII spaces only, since the full-width space is a
        // symbol too.
        for (NSString *rawSymbol in [[line substringFromIndex:NSMaxRange(tab)] componentsSeparatedByString:@" "]) {
            NSString *symbol = [rawSymbol stringByTrimmingCharactersInSet:asciiWhitespaces];
            if (symbol.length > 0) {
                category.symbols.push_back(symbol.UTF8String);
            }
        }
        if (!category.symbols.empty()) {
            table.push_back(std::move(category));
        }
    }
    gLanguageModelMcBopomofo.setSymbolTable(std::move(table));
}

+ (NSArray<NSArray *> *)symbolSectionsForReading:(NSString *)reading
{
    NSMutableArray *sections = [NSMutableArray array];
    std::string keyTitle = NSLocalizedString(@"Symbols for the Key", @"").UTF8String;
    for (const auto& [title, count] : gLanguageModelMcBopomofo.getSymbolSections(reading.UTF8String, keyTitle)) {
        [sections addObject:@[@(title.c_str()), @(count)]];
    }
    return sections;
}

+ (NSUInteger)symbolInitialIndexForReading:(NSString *)reading
{
    return gLanguageModelMcBopomofo.getSymbolInitialIndex(reading.UTF8String);
}

+ (NSString *)userPhrasesDataPathMcBopomofo
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"data.txt"];
}

+ (NSString *)userPhrasesDataPathPlainBopomofo
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"data-plain-bpmf.txt"];
}

+ (NSString *)excludedPhrasesDataPathMcBopomofo
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"exclude-phrases.txt"];
}

+ (NSString *)excludedPhrasesDataPathPlainBopomofo
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"exclude-phrases-plain-bpmf.txt"];
}

+ (NSString *)phraseReplacementDataPathMcBopomofo
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"phrases-replacement.txt"];
}

+ (McBopomofo::McBopomofoLM *)languageModelMcBopomofo
{
    return &gLanguageModelMcBopomofo;
}

+ (McBopomofo::McBopomofoLM *)languageModelPlainBopomofo
{
    return &gLanguageModelPlainBopomofo;
}

// The model is shared among the devices using the same user phrase folder
// (for example, on iCloud Drive). Each device writes its own file, named
// "<device ID>-<computer name>.txt", and reads the files of the others, so
// that the devices never overwrite each other.
+ (NSString *)userOverrideModelFolderPath
{
    return [[self dataFolderPath] stringByAppendingPathComponent:kUserOverrideModelFolderName];
}

+ (NSString *)_userOverrideModelDeviceID
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *deviceID = [defaults stringForKey:kUserOverrideModelDeviceIDKey];
    if (deviceID.length == 0) {
        deviceID = [[NSUUID UUID].UUIDString substringToIndex:8];
        [defaults setObject:deviceID forKey:kUserOverrideModelDeviceIDKey];
    }
    return deviceID;
}

+ (NSString *)userOverrideModelDataPath
{
    static NSString *filename;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *name = CFBridgingRelease(SCDynamicStoreCopyComputerName(NULL, NULL));
        if (name.length == 0) {
            name = @"Mac";
        }
        NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/:\\\n\r\t"];
        name = [[name componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@"_"];
        filename = [NSString stringWithFormat:@"%@-%@.txt", [self _userOverrideModelDeviceID], name];
    });
    return [[self userOverrideModelFolderPath] stringByAppendingPathComponent:filename];
}

+ (dispatch_queue_t)_userOverrideModelIOQueue
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("org.openvanilla.McBopomofo.UserOverrideModelIO", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *LTReadUserOverrideModelFile(NSString *path)
{
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (content == nil) {
        NSLog(@"Failed to read user override model at %@: %@", path, error);
    }
    return content;
}

+ (McBopomofo::UserOverrideModel *)userOverrideModel
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self reloadUserOverrideModel];
    });
    return &gUserOverrideModel;
}

// iCloud Drive may evict a file and leave a ".<name>.icloud" placeholder.
static NSString *LTICloudPlaceholderPath(NSString *path)
{
    NSString *placeholder = [NSString stringWithFormat:@".%@.icloud", path.lastPathComponent];
    return [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:placeholder];
}

static void LTDownloadICloudPlaceholder(NSString *path)
{
    NSError *error = nil;
    if (![[NSFileManager defaultManager] startDownloadingUbiquitousItemAtURL:[NSURL fileURLWithPath:path] error:&error]) {
        NSLog(@"Failed to download %@: %@", path, error);
    }
}

// Whether the saved model of this device is yet to be merged into
// gLocalUserOverrideModel, e.g. when it is still being downloaded.
static BOOL gLocalUserOverrideModelFilePending = YES;

+ (void)_loadLocalUserOverrideModelIfNeeded
{
    if (!gLocalUserOverrideModelFilePending) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *folderPath = [self userOverrideModelFolderPath];
    NSString *path = [self userOverrideModelDataPath];

    // The computer may have been renamed since the file was written.
    NSString *prefix = [[self _userOverrideModelDeviceID] stringByAppendingString:@"-"];
    for (NSString *filename in [fileManager contentsOfDirectoryAtPath:folderPath error:nil]) {
        NSString *existingPath = [folderPath stringByAppendingPathComponent:filename];
        if ([filename hasPrefix:prefix] && [filename.pathExtension isEqualToString:@"txt"] && ![existingPath isEqualToString:path]) {
            [fileManager moveItemAtPath:existingPath toPath:path error:nil];
            break;
        }
    }

    if ([fileManager fileExistsAtPath:path]) {
        NSString *content = LTReadUserOverrideModelFile(path);
        if (content != nil) {
            // Appending keeps what has been observed while the file was not
            // available yet.
            gLocalUserOverrideModel.deserialize(content.UTF8String, true);
            gLocalUserOverrideModelFilePending = NO;
        }
        return;
    }

    if ([fileManager fileExistsAtPath:LTICloudPlaceholderPath(path)]) {
        // Try again when the download finishes and the folder changes.
        LTDownloadICloudPlaceholder(path);
        return;
    }
    gLocalUserOverrideModelFilePending = NO;
}

+ (void)reloadUserOverrideModel
{
    [self _loadLocalUserOverrideModelIfNeeded];
    gUserOverrideModel.deserialize(gLocalUserOverrideModel.serialize());

    NSString *folderPath = [self userOverrideModelFolderPath];
    NSString *localFilename = [[self userOverrideModelDataPath] lastPathComponent];
    NSArray *filenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folderPath error:nil];
    for (NSString *filename in [filenames sortedArrayUsingSelector:@selector(compare:)]) {
        if ([filename hasPrefix:@"."] && [filename.pathExtension isEqualToString:@"icloud"]) {
            NSString *original = [[filename substringFromIndex:1] stringByDeletingPathExtension];
            LTDownloadICloudPlaceholder([folderPath stringByAppendingPathComponent:original]);
            continue;
        }
        if (![filename.pathExtension isEqualToString:@"txt"] || [filename isEqualToString:localFilename]) {
            continue;
        }
        NSString *content = LTReadUserOverrideModelFile([folderPath stringByAppendingPathComponent:filename]);
        if (content != nil) {
            gUserOverrideModel.deserialize(content.UTF8String, true);
        }
    }
}

+ (void)observeUserOverrideWithWalkBefore:(const Formosa::Gramambular2::ReadingGrid::WalkResult &)walkBefore walkAfter:(const Formosa::Gramambular2::ReadingGrid::WalkResult &)walkAfter cursor:(size_t)cursor
{
    [self userOverrideModel];
    double timestamp = [NSDate date].timeIntervalSince1970;
    gLocalUserOverrideModel.observe(walkBefore, walkAfter, cursor, timestamp);
    gUserOverrideModel.observe(walkBefore, walkAfter, cursor, timestamp);
    [self _scheduleSavingUserOverrideModel];
}

// Coalesces consecutive selections into one save, so that a synced folder is
// not flooded with uploads.
+ (void)_scheduleSavingUserOverrideModel
{
    static NSUInteger generation = 0;
    NSUInteger currentGeneration = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kUserOverrideModelSaveDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (currentGeneration == generation) {
            [self saveUserOverrideModel];
        }
    });
}

+ (void)saveUserOverrideModel
{
    // Never overwrite the saved model before it has been loaded.
    [self _loadLocalUserOverrideModelIfNeeded];
    if (gLocalUserOverrideModelFilePending) {
        [self _scheduleSavingUserOverrideModel];
        return;
    }

    // Serialize on the caller's thread, which owns the model, and leave the
    // file I/O to a serial queue so that typing is never blocked.
    std::string serialized = gLocalUserOverrideModel.serialize();
    NSData *data = [NSData dataWithBytes:serialized.data() length:serialized.size()];
    NSString *path = [self userOverrideModelDataPath];
    dispatch_async([self _userOverrideModelIOQueue], ^{
        NSError *error = nil;
        NSString *folderPath = [path stringByDeletingLastPathComponent];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Failed to create %@: %@", folderPath, error);
            return;
        }
        if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
            NSLog(@"Failed to save user override model to %@: %@", path, error);
        }
    });
}

+ (McBopomofo::VariantAnnotator *)variantAnnotator
{
    return &gVariantAnnotator;
}

+ (BOOL)phraseReplacementEnabled
{
    return gLanguageModelMcBopomofo.phraseReplacementEnabled();
}

+ (void)setPhraseReplacementEnabled:(BOOL)phraseReplacementEnabled
{
    gLanguageModelMcBopomofo.setPhraseReplacementEnabled(phraseReplacementEnabled);
}

+ (nullable NSString *)readingFor:(NSString *)phrase
{
    if (!gLanguageModelMcBopomofo.isDataModelLoaded()) {
        [self loadDataModel:InputModeBopomofo];
    }

    std::string reading = gLanguageModelMcBopomofo.getReading(phrase.UTF8String);
    return !reading.empty() ? @(reading.c_str()) : nil;
}

+ (NSString *)annotateVariantForCharacters:(NSString *)inCharacters readings:(NSString *)inReadings
{
    McBopomofo::VariantAnnotator *annotator = LanguageModelManager.variantAnnotator;
    if (!annotator || !annotator->loaded()) {
        return inCharacters;
    }

    std::string value(inCharacters.UTF8String);
    std::string readingString(inReadings.UTF8String);
    std::vector<std::string> characters = McBopomofo::Split(value);
    std::vector<std::string> readings = McBopomofo::AssociatedPhrasesV2::SplitReadings(readingString);

    McBopomofo::VariantAnnotator::CombinedResult result = LanguageModelManager.variantAnnotator->annotate(characters,
                                                                                                          readings);
    return [[NSString alloc] initWithUTF8String:result.annotatedString.c_str()];
}


@end
