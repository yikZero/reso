#import "SPSetupWizardWindowController.h"
#import <Cocoa/Cocoa.h>

static NSString *const kConfigDir = @".koe";
static NSString *const kConfigFile = @"config.yaml";
static NSString *const kDictionaryFile = @"dictionary.txt";
static NSString *const kSystemPromptFile = @"system_prompt.txt";

// Toolbar item identifiers
static NSToolbarItemIdentifier const kToolbarASR = @"asr";
static NSToolbarItemIdentifier const kToolbarHotkey = @"hotkey";
static NSToolbarItemIdentifier const kToolbarDictionary = @"dictionary";
static NSToolbarItemIdentifier const kToolbarSystemPrompt = @"system_prompt";

// ─── YAML helpers (minimal, line-based) ─────────────────────────────
// We parse/write the config.yaml with simple line-based logic to avoid
// pulling in a YAML library.  The config file is flat enough for this.

static NSString *configDirPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:kConfigDir];
}

static NSString *configFilePath(void) {
    return [configDirPath() stringByAppendingPathComponent:kConfigFile];
}

/// Count leading spaces in a line (each tab counts as 2 spaces).
static NSInteger yamlIndentLevel(NSString *line) {
    NSInteger indent = 0;
    for (NSUInteger i = 0; i < line.length; i++) {
        unichar ch = [line characterAtIndex:i];
        if (ch == ' ') indent++;
        else if (ch == '\t') indent += 2;
        else break;
    }
    return indent;
}

/// Read a YAML value at an arbitrary depth key path, e.g. @"asr.api_key".
/// Returns @"" if not found.
static NSString *yamlRead(NSString *yaml, NSString *keyPath) {
    NSArray<NSString *> *parts = [keyPath componentsSeparatedByString:@"."];
    if (parts.count == 0) return @"";

    NSArray<NSString *> *lines = [yaml componentsSeparatedByString:@"\n"];
    // Track which depth of the path we've matched so far
    NSInteger matchedDepth = 0;
    // The minimum indent level required for each depth
    NSInteger requiredIndent[16] = {0}; // support up to 16 levels
    requiredIndent[0] = 0;

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;

        NSInteger indent = yamlIndentLevel(line);

        // If indent is less than what the current matched section requires, we've left that section
        if (matchedDepth > 0 && indent < requiredIndent[matchedDepth - 1] + 1) {
            // Reset to how many parent sections are still valid
            while (matchedDepth > 0 && indent < requiredIndent[matchedDepth - 1] + 1) {
                matchedDepth--;
            }
        }

        // Extract key from this line
        NSRange colonRange = [trimmed rangeOfString:@":"];
        if (colonRange.location == NSNotFound) continue;

        NSString *lineKey = [[trimmed substringToIndex:colonRange.location]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        NSString *expectedKey = (matchedDepth < (NSInteger)parts.count) ? parts[matchedDepth] : nil;
        if (!expectedKey) continue;

        if ([lineKey isEqualToString:expectedKey]) {
            if (matchedDepth == (NSInteger)parts.count - 1) {
                // This is the leaf key — extract value
                NSString *value = [trimmed substringFromIndex:colonRange.location + 1];
                value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([value hasPrefix:@"\""]) {
                    NSRange closeQuote = [value rangeOfString:@"\"" options:0 range:NSMakeRange(1, value.length - 1)];
                    if (closeQuote.location != NSNotFound) {
                        value = [value substringToIndex:closeQuote.location + 1];
                    }
                } else {
                    NSRange commentRange = [value rangeOfString:@" #"];
                    if (commentRange.location != NSNotFound) {
                        value = [[value substringToIndex:commentRange.location]
                                 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    }
                }
                if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
                    value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
                }
                return value;
            } else {
                // This is an intermediate section key — go deeper
                requiredIndent[matchedDepth] = indent;
                matchedDepth++;
            }
        }
    }
    return @"";
}

/// Set a value in the YAML string at an arbitrary depth key path.
/// If the key exists, replace it; otherwise append under the parent section(s).
static NSString *yamlWrite(NSString *yaml, NSString *keyPath, NSString *value) {
    NSArray<NSString *> *parts = [keyPath componentsSeparatedByString:@"."];
    NSString *key = parts.lastObject;

    // Quote the value if it contains special chars or is empty
    NSString *quotedValue;
    if (value.length == 0 ||
        [value rangeOfString:@" "].location != NSNotFound ||
        [value rangeOfString:@"#"].location != NSNotFound ||
        [value rangeOfString:@":"].location != NSNotFound ||
        [value rangeOfString:@"\""].location != NSNotFound ||
        [value rangeOfString:@"$"].location != NSNotFound ||
        [value rangeOfString:@"@"].location != NSNotFound ||
        [value hasPrefix:@"wss://"] || [value hasPrefix:@"https://"] || [value hasPrefix:@"http://"]) {
        quotedValue = [NSString stringWithFormat:@"\"%@\"", value];
    } else {
        quotedValue = value;
    }

    NSMutableArray<NSString *> *lines = [[yaml componentsSeparatedByString:@"\n"] mutableCopy];

    // Build indent string for the leaf key (2 spaces per depth level for sections)
    NSInteger sectionCount = (NSInteger)parts.count - 1;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < sectionCount; i++) {
        [indent appendString:@"  "];
    }

    // Track section matching
    NSInteger matchedDepth = 0;
    NSInteger requiredIndent[16] = {0};

    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;

        NSInteger lineIndent = yamlIndentLevel(line);

        // Check if we've left a matched section
        while (matchedDepth > 0 && lineIndent < requiredIndent[matchedDepth - 1] + 1) {
            matchedDepth--;
        }

        NSRange colonRange = [trimmed rangeOfString:@":"];
        if (colonRange.location == NSNotFound) continue;

        NSString *lineKey = [[trimmed substringToIndex:colonRange.location]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if (matchedDepth < sectionCount) {
            // Still looking for parent sections
            NSString *expectedSection = parts[matchedDepth];
            if ([lineKey isEqualToString:expectedSection]) {
                requiredIndent[matchedDepth] = lineIndent;
                matchedDepth++;
            }
        } else if (matchedDepth == sectionCount) {
            // Looking for the leaf key
            if ([lineKey isEqualToString:key]) {
                // Replace this line
                NSString *newLine = [NSString stringWithFormat:@"%@%@: %@", indent, key, quotedValue];
                lines[i] = newLine;
                return [lines componentsJoinedByString:@"\n"];
            }
        }
    }

    // Key not found — insert it under the deepest existing parent section.
    NSInteger bestDepth = 0;
    NSInteger bestInsertIdx = (NSInteger)lines.count;

    matchedDepth = 0;
    memset(requiredIndent, 0, sizeof(requiredIndent));

    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;

        NSInteger lineIndent = yamlIndentLevel(line);
        while (matchedDepth > 0 && lineIndent < requiredIndent[matchedDepth - 1] + 1) {
            matchedDepth--;
        }

        NSRange colonRange = [trimmed rangeOfString:@":"];
        if (colonRange.location == NSNotFound) continue;

        NSString *lineKey = [[trimmed substringToIndex:colonRange.location]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if (matchedDepth < sectionCount) {
            NSString *expectedSection = parts[matchedDepth];
            if ([lineKey isEqualToString:expectedSection]) {
                requiredIndent[matchedDepth] = lineIndent;
                matchedDepth++;

                // Record deepest match and find end of this section
                if (matchedDepth > bestDepth) {
                    bestDepth = matchedDepth;
                    bestInsertIdx = i + 1;
                    while (bestInsertIdx < (NSInteger)lines.count) {
                        NSString *nextLine = lines[bestInsertIdx];
                        NSString *nextTrimmed = [nextLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (nextTrimmed.length > 0 && ![nextTrimmed hasPrefix:@"#"]) {
                            NSInteger nextIndent = yamlIndentLevel(nextLine);
                            if (nextIndent <= lineIndent) break;
                        }
                        bestInsertIdx++;
                    }
                }

                if (matchedDepth == sectionCount) break;
            }
        }
    }

    // Create missing parent sections starting from bestDepth
    NSInteger insertIdx = bestInsertIdx;
    for (NSInteger d = bestDepth; d < sectionCount; d++) {
        NSMutableString *secIndent = [NSMutableString string];
        for (NSInteger j = 0; j < d; j++) [secIndent appendString:@"  "];
        NSString *secLine = [NSString stringWithFormat:@"%@%@:", secIndent, parts[d]];
        [lines insertObject:secLine atIndex:insertIdx];
        insertIdx++;
    }

    // Insert the leaf key
    NSString *newLine = [NSString stringWithFormat:@"%@%@: %@", indent, key, quotedValue];
    [lines insertObject:newLine atIndex:insertIdx];

    return [lines componentsJoinedByString:@"\n"];
}

static NSString *normalizedHotkeyValue(NSString *value) {
    static NSSet<NSString *> *validValues;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        validValues = [NSSet setWithArray:@[
            @"fn",
            @"left_option",
            @"right_option",
            @"left_command",
            @"right_command",
        ]];
    });
    return [validValues containsObject:value] ? value : @"fn";
}

static NSString *defaultCancelKeyForTrigger(NSString *triggerKey) {
    NSString *normalizedTrigger = normalizedHotkeyValue(triggerKey);
    if ([normalizedTrigger isEqualToString:@"fn"]) return @"left_option";
    if ([normalizedTrigger isEqualToString:@"left_option"]) return @"right_option";
    if ([normalizedTrigger isEqualToString:@"right_option"]) return @"left_command";
    if ([normalizedTrigger isEqualToString:@"left_command"]) return @"right_command";
    return @"fn";
}

// ─── Window Controller ──────────────────────────────────────────────

@interface SPSetupWizardWindowController () <NSToolbarDelegate>

// Current pane
@property (nonatomic, copy) NSString *currentPaneIdentifier;
@property (nonatomic, strong) NSView *currentPaneView;

// ASR (Gemini) fields
@property (nonatomic, strong) NSTextField *geminiApiKeyField;
@property (nonatomic, strong) NSSecureTextField *geminiApiKeySecureField;
@property (nonatomic, strong) NSButton *geminiApiKeyToggle;
@property (nonatomic, strong) NSTextField *geminiModelField;

// Hotkey
@property (nonatomic, strong) NSPopUpButton *hotkeyPopup;
@property (nonatomic, strong) NSPopUpButton *cancelHotkeyPopup;
@property (nonatomic, strong) NSButton *hideMenuIconCheckbox;

// Dictionary
@property (nonatomic, strong) NSTextView *dictionaryTextView;

// System Prompt
@property (nonatomic, strong) NSTextView *systemPromptTextView;

@end

@implementation SPSetupWizardWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 600, 400)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:YES];
    window.title = @"Reso Settings";
    window.toolbarStyle = NSWindowToolbarStylePreference;

    self = [super initWithWindow:window];
    if (self) {
        [self setupToolbar];
        [self switchToPane:kToolbarASR];
        [self loadCurrentValues];
    }
    return self;
}

- (void)showWindow:(id)sender {
    [self loadCurrentValues];
    [self.window center];
    [self.window makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

// ─── Toolbar ────────────────────────────────────────────────────────

- (void)setupToolbar {
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"KoeSettingsToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
    toolbar.selectedItemIdentifier = kToolbarASR;
    self.window.toolbar = toolbar;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[kToolbarASR, kToolbarHotkey, kToolbarDictionary, kToolbarSystemPrompt];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[kToolbarASR, kToolbarHotkey, kToolbarDictionary, kToolbarSystemPrompt];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar {
    return @[kToolbarASR, kToolbarHotkey, kToolbarDictionary, kToolbarSystemPrompt];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    item.target = self;
    item.action = @selector(toolbarItemClicked:);

    if ([itemIdentifier isEqualToString:kToolbarASR]) {
        item.label = @"Gemini";
        item.image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:@"Gemini"];
    } else if ([itemIdentifier isEqualToString:kToolbarHotkey]) {
        item.label = @"Controls";
        item.image = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:@"Controls"];
    } else if ([itemIdentifier isEqualToString:kToolbarDictionary]) {
        item.label = @"Dictionary";
        item.image = [NSImage imageWithSystemSymbolName:@"book" accessibilityDescription:@"Dictionary"];
    } else if ([itemIdentifier isEqualToString:kToolbarSystemPrompt]) {
        item.label = @"Prompt";
        item.image = [NSImage imageWithSystemSymbolName:@"text.bubble" accessibilityDescription:@"System Prompt"];
    }

    return item;
}

- (void)toolbarItemClicked:(NSToolbarItem *)sender {
    [self switchToPane:sender.itemIdentifier];
}

// ─── Pane Switching ─────────────────────────────────────────────────

- (void)switchToPane:(NSString *)identifier {
    if ([self.currentPaneIdentifier isEqualToString:identifier]) return;
    self.currentPaneIdentifier = identifier;

    // Remove old pane
    [self.currentPaneView removeFromSuperview];

    // Build new pane
    NSView *paneView;
    if ([identifier isEqualToString:kToolbarASR]) {
        paneView = [self buildAsrPane];
    } else if ([identifier isEqualToString:kToolbarHotkey]) {
        paneView = [self buildHotkeyPane];
    } else if ([identifier isEqualToString:kToolbarDictionary]) {
        paneView = [self buildDictionaryPane];
    } else if ([identifier isEqualToString:kToolbarSystemPrompt]) {
        paneView = [self buildSystemPromptPane];
    }

    if (!paneView) return;

    self.currentPaneView = paneView;
    self.window.toolbar.selectedItemIdentifier = identifier;

    // Resize window to fit pane with animation
    NSSize paneSize = paneView.frame.size;
    NSRect windowFrame = self.window.frame;
    CGFloat contentHeight = paneSize.height;
    CGFloat titleBarHeight = windowFrame.size.height - [self.window.contentView frame].size.height;
    CGFloat newHeight = contentHeight + titleBarHeight;
    CGFloat newWidth = paneSize.width;

    NSRect newFrame = NSMakeRect(
        windowFrame.origin.x + (windowFrame.size.width - newWidth) / 2.0,
        windowFrame.origin.y + windowFrame.size.height - newHeight,
        newWidth,
        newHeight
    );

    [self.window setFrame:newFrame display:YES animate:YES];

    // Add pane to window
    paneView.frame = [self.window.contentView bounds];
    paneView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window.contentView addSubview:paneView];

    // Reload values for this pane
    [self loadValuesForPane:identifier];
}

// ─── Build Panes ────────────────────────────────────────────────────

- (NSView *)buildAsrPane {
    CGFloat paneWidth = 600;
    CGFloat labelW = 130;
    CGFloat fieldX = labelW + 24;
    CGFloat fieldW = paneWidth - fieldX - 32;
    CGFloat rowH = 32;
    CGFloat eyeW = 28;
    CGFloat secFieldW = fieldW - eyeW - 4;

    CGFloat contentHeight = 220;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"Configure Gemini Live API for voice input. Gemini handles both speech recognition and text correction in one step."];
    desc.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:desc];
    y -= 52;

    // API Key
    [pane addSubview:[self formLabel:@"API Key" frame:NSMakeRect(16, y, labelW, 22)]];
    self.geminiApiKeySecureField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, y, secFieldW, 22)];
    self.geminiApiKeySecureField.placeholderString = @"Google AI API Key";
    self.geminiApiKeySecureField.font = [NSFont systemFontOfSize:13];
    [pane addSubview:self.geminiApiKeySecureField];
    self.geminiApiKeyField = [self formTextField:NSMakeRect(fieldX, y, secFieldW, 22) placeholder:@"Google AI API Key"];
    self.geminiApiKeyField.hidden = YES;
    [pane addSubview:self.geminiApiKeyField];
    self.geminiApiKeyToggle = [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, y - 1, eyeW, 24)
                                                action:@selector(toggleGeminiApiKeyVisibility:)];
    [pane addSubview:self.geminiApiKeyToggle];
    y -= rowH;

    // Model
    [pane addSubview:[self formLabel:@"Model" frame:NSMakeRect(16, y, labelW, 22)]];
    self.geminiModelField = [self formTextField:NSMakeRect(fieldX, y, fieldW, 22) placeholder:@"gemini-3.1-flash-live-preview"];
    [pane addSubview:self.geminiModelField];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

- (void)toggleGeminiApiKeyVisibility:(NSButton *)sender {
    [self toggleSecureField:self.geminiApiKeySecureField plainField:self.geminiApiKeyField toggle:sender];
}

- (NSView *)buildHotkeyPane {
    CGFloat paneWidth = 600;
    CGFloat labelW = 130;
    CGFloat fieldX = labelW + 24;
    CGFloat rowH = 32;

    CGFloat contentHeight = 300;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"Choose a trigger key for voice input and a separate cancel key to abort the current session."];
    desc.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:desc];
    y -= 52;

    // Trigger Key
    [pane addSubview:[self formLabel:@"Trigger Key" frame:NSMakeRect(16, y, labelW, 22)]];

    self.hotkeyPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, 220, 26) pullsDown:NO];
    [self.hotkeyPopup addItemsWithTitles:@[
        @"Fn (Globe)",
        @"Left Option (\u2325)",
        @"Right Option (\u2325)",
        @"Left Command (\u2318)",
        @"Right Command (\u2318)",
    ]];
    [self.hotkeyPopup itemAtIndex:0].representedObject = @"fn";
    [self.hotkeyPopup itemAtIndex:1].representedObject = @"left_option";
    [self.hotkeyPopup itemAtIndex:2].representedObject = @"right_option";
    [self.hotkeyPopup itemAtIndex:3].representedObject = @"left_command";
    [self.hotkeyPopup itemAtIndex:4].representedObject = @"right_command";
    [pane addSubview:self.hotkeyPopup];
    y -= rowH + 16;

    // Cancel Key
    [pane addSubview:[self formLabel:@"Cancel Key" frame:NSMakeRect(16, y, labelW, 22)]];

    self.cancelHotkeyPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, 220, 26) pullsDown:NO];
    [self.cancelHotkeyPopup addItemsWithTitles:@[
        @"Fn (Globe)",
        @"Left Option (\u2325)",
        @"Right Option (\u2325)",
        @"Left Command (\u2318)",
        @"Right Command (\u2318)",
    ]];
    [self.cancelHotkeyPopup itemAtIndex:0].representedObject = @"fn";
    [self.cancelHotkeyPopup itemAtIndex:1].representedObject = @"left_option";
    [self.cancelHotkeyPopup itemAtIndex:2].representedObject = @"right_option";
    [self.cancelHotkeyPopup itemAtIndex:3].representedObject = @"left_command";
    [self.cancelHotkeyPopup itemAtIndex:4].representedObject = @"right_command";
    [pane addSubview:self.cancelHotkeyPopup];
    y -= rowH + 8;

    NSTextField *hotkeyHint = [self descriptionLabel:@"Trigger Key and Cancel Key must be different."];
    hotkeyHint.frame = NSMakeRect(fieldX, y + 2, paneWidth - fieldX - 32, 24);
    [pane addSubview:hotkeyHint];
    y -= 30;

    // Appearance
    [pane addSubview:[self formLabel:@"Appearance" frame:NSMakeRect(16, y, labelW, 22)]];

    self.hideMenuIconCheckbox = [NSButton checkboxWithTitle:@"Hide menu bar icon (show Dock icon instead)"
                                                    target:nil
                                                    action:nil];
    self.hideMenuIconCheckbox.frame = NSMakeRect(fieldX, y - 4, 350, 22);
    [pane addSubview:self.hideMenuIconCheckbox];
    y -= 34;

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:y width:paneWidth];

    return pane;
}

- (NSView *)buildDictionaryPane {
    CGFloat paneWidth = 600;
    CGFloat contentHeight = 440;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"User dictionary \u2014 one term per line. These terms can be referenced in the system prompt. Lines starting with # are comments."];
    desc.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:desc];
    y -= 44;

    // Text editor
    CGFloat editorHeight = y - 56;
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 56, paneWidth - 48, editorHeight)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.borderType = NSBezelBorder;

    self.dictionaryTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth - 54, editorHeight)];
    self.dictionaryTextView.minSize = NSMakeSize(0, editorHeight);
    self.dictionaryTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.dictionaryTextView.verticallyResizable = YES;
    self.dictionaryTextView.horizontallyResizable = NO;
    self.dictionaryTextView.autoresizingMask = NSViewWidthSizable;
    self.dictionaryTextView.textContainer.containerSize = NSMakeSize(paneWidth - 54, FLT_MAX);
    self.dictionaryTextView.textContainer.widthTracksTextView = YES;
    self.dictionaryTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.dictionaryTextView.allowsUndo = YES;

    scrollView.documentView = self.dictionaryTextView;
    [pane addSubview:scrollView];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

- (NSView *)buildSystemPromptPane {
    CGFloat paneWidth = 600;
    CGFloat contentHeight = 440;
    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

    CGFloat y = contentHeight - 48;

    // Description
    NSTextField *desc = [self descriptionLabel:@"System prompt sent to Gemini as systemInstruction. Controls how speech is transcribed and corrected."];
    desc.frame = NSMakeRect(24, y - 10, paneWidth - 48, 36);
    [pane addSubview:desc];
    y -= 44;

    // Text editor
    CGFloat editorHeight = y - 56;
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 56, paneWidth - 48, editorHeight)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.borderType = NSBezelBorder;

    self.systemPromptTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth - 54, editorHeight)];
    self.systemPromptTextView.minSize = NSMakeSize(0, editorHeight);
    self.systemPromptTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.systemPromptTextView.verticallyResizable = YES;
    self.systemPromptTextView.horizontallyResizable = NO;
    self.systemPromptTextView.autoresizingMask = NSViewWidthSizable;
    self.systemPromptTextView.textContainer.containerSize = NSMakeSize(paneWidth - 54, FLT_MAX);
    self.systemPromptTextView.textContainer.widthTracksTextView = YES;
    self.systemPromptTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.systemPromptTextView.allowsUndo = YES;

    scrollView.documentView = self.systemPromptTextView;
    [pane addSubview:scrollView];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}

// ─── Shared button bar ──────────────────────────────────────────────

- (void)addButtonsToPane:(NSView *)pane atY:(CGFloat)y width:(CGFloat)paneWidth {
    NSButton *saveButton = [NSButton buttonWithTitle:@"Save" target:self action:@selector(saveConfig:)];
    saveButton.bezelStyle = NSBezelStyleRounded;
    saveButton.keyEquivalent = @"\r";
    saveButton.frame = NSMakeRect(paneWidth - 32 - 80, y, 80, 28);
    [pane addSubview:saveButton];

    NSButton *cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelSetup:)];
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.keyEquivalent = @"\033";
    cancelButton.frame = NSMakeRect(paneWidth - 32 - 80 - 88, y, 80, 28);
    [pane addSubview:cancelButton];
}

// ─── UI Helpers ─────────────────────────────────────────────────────

- (NSTextField *)formLabel:(NSString *)title frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:title];
    label.frame = frame;
    label.alignment = NSTextAlignmentRight;
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = [NSColor labelColor];
    return label;
}

- (NSTextField *)formTextField:(NSRect)frame placeholder:(NSString *)placeholder {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.placeholderString = placeholder;
    field.font = [NSFont systemFontOfSize:13];
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    field.usesSingleLineMode = YES;
    return field;
}

- (NSTextField *)descriptionLabel:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:12];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

- (NSButton *)eyeButtonWithFrame:(NSRect)frame action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.bezelStyle = NSBezelStyleInline;
    button.bordered = NO;
    button.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
    button.imageScaling = NSImageScaleProportionallyUpOrDown;
    button.target = self;
    button.action = action;
    button.tag = 0; // 0 = hidden, 1 = visible
    return button;
}

- (void)toggleSecureField:(NSSecureTextField *)secureField
               plainField:(NSTextField *)plainField
                   toggle:(NSButton *)sender {
    if (sender.tag == 0) {
        plainField.stringValue = secureField.stringValue;
        secureField.hidden = YES;
        plainField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:@"Hide"];
        sender.tag = 1;
    } else {
        secureField.stringValue = plainField.stringValue;
        plainField.hidden = YES;
        secureField.hidden = NO;
        sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
        sender.tag = 0;
    }
}

- (void)resetSecureField:(NSSecureTextField *)secureField
              plainField:(NSTextField *)plainField
                  toggle:(NSButton *)toggle
                   value:(NSString *)value {
    secureField.stringValue = value;
    plainField.stringValue = value;
    secureField.hidden = NO;
    plainField.hidden = YES;
    toggle.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:@"Show"];
    toggle.tag = 0;
}

// ─── Load / Save ────────────────────────────────────────────────────

- (void)loadCurrentValues {
    [self loadValuesForPane:self.currentPaneIdentifier];
}

- (void)loadValuesForPane:(NSString *)identifier {
    NSString *dir = configDirPath();
    NSString *configPath = configFilePath();
    NSString *yaml = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:nil] ?: @"";

    if ([identifier isEqualToString:kToolbarASR]) {
        [self resetSecureField:self.geminiApiKeySecureField plainField:self.geminiApiKeyField
                        toggle:self.geminiApiKeyToggle value:yamlRead(yaml, @"asr.api_key")];
        NSString *geminiModel = yamlRead(yaml, @"asr.model");
        self.geminiModelField.stringValue = geminiModel.length > 0 ? geminiModel : @"gemini-3.1-flash-live-preview";
    } else if ([identifier isEqualToString:kToolbarHotkey]) {
        NSString *triggerKey = normalizedHotkeyValue(yamlRead(yaml, @"hotkey.trigger_key"));
        NSString *cancelKey = normalizedHotkeyValue(yamlRead(yaml, @"hotkey.cancel_key"));
        if (cancelKey.length == 0 || [cancelKey isEqualToString:triggerKey]) {
            cancelKey = defaultCancelKeyForTrigger(triggerKey);
        }
        for (NSInteger i = 0; i < self.hotkeyPopup.numberOfItems; i++) {
            if ([[self.hotkeyPopup itemAtIndex:i].representedObject isEqualToString:triggerKey]) {
                [self.hotkeyPopup selectItemAtIndex:i];
                break;
            }
        }
        for (NSInteger i = 0; i < self.cancelHotkeyPopup.numberOfItems; i++) {
            if ([[self.cancelHotkeyPopup itemAtIndex:i].representedObject isEqualToString:cancelKey]) {
                [self.cancelHotkeyPopup selectItemAtIndex:i];
                break;
            }
        }

        NSString *hideMenuIcon = yamlRead(yaml, @"appearance.hide_menu_icon");
        self.hideMenuIconCheckbox.state = [hideMenuIcon isEqualToString:@"true"] ? NSControlStateValueOn : NSControlStateValueOff;
    } else if ([identifier isEqualToString:kToolbarDictionary]) {
        NSString *dictPath = [dir stringByAppendingPathComponent:kDictionaryFile];
        NSString *dictContent = [NSString stringWithContentsOfFile:dictPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [self.dictionaryTextView setString:dictContent];
    } else if ([identifier isEqualToString:kToolbarSystemPrompt]) {
        NSString *promptPath = [dir stringByAppendingPathComponent:kSystemPromptFile];
        NSString *promptContent = [NSString stringWithContentsOfFile:promptPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [self.systemPromptTextView setString:promptContent];
    }
}

- (void)saveConfig:(id)sender {
    NSString *dir = configDirPath();

    // Ensure directory exists
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Read existing config.yaml (preserve structure)
    NSString *configPath = configFilePath();
    NSString *yaml = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:nil] ?: @"";

    // Update ASR (Gemini) fields
    if (self.geminiApiKeyField) {
        NSString *geminiApiKey = self.geminiApiKeyToggle.tag == 1 ? self.geminiApiKeyField.stringValue : self.geminiApiKeySecureField.stringValue;
        yaml = yamlWrite(yaml, @"asr.api_key", geminiApiKey);
        yaml = yamlWrite(yaml, @"asr.model", self.geminiModelField.stringValue);
    }

    // Update hotkey
    if (self.hotkeyPopup) {
        NSString *selectedTriggerHotkey = self.hotkeyPopup.selectedItem.representedObject ?: @"fn";
        NSString *selectedCancelHotkey = self.cancelHotkeyPopup.selectedItem.representedObject ?: defaultCancelKeyForTrigger(selectedTriggerHotkey);
        if ([selectedTriggerHotkey isEqualToString:selectedCancelHotkey]) {
            [self showAlert:@"Trigger and Cancel keys must be different"
                       info:@"Choose two different keys for starting and cancelling voice input."];
            return;
        }
        yaml = yamlWrite(yaml, @"hotkey.trigger_key", selectedTriggerHotkey);
        yaml = yamlWrite(yaml, @"hotkey.cancel_key", selectedCancelHotkey);
    }
    if (self.hideMenuIconCheckbox) {
        NSString *hideMenuIcon = (self.hideMenuIconCheckbox.state == NSControlStateValueOn) ? @"true" : @"false";
        yaml = yamlWrite(yaml, @"appearance.hide_menu_icon", hideMenuIcon);
    }

    // Write config.yaml
    NSError *error = nil;
    [yaml writeToFile:configPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        NSLog(@"[Koe] Failed to write config.yaml: %@", error.localizedDescription);
        [self showAlert:@"Failed to save config.yaml" info:error.localizedDescription];
        return;
    }

    // Write dictionary.txt
    if (self.dictionaryTextView) {
        NSString *dictPath = [dir stringByAppendingPathComponent:kDictionaryFile];
        [self.dictionaryTextView.string writeToFile:dictPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            NSLog(@"[Koe] Failed to write dictionary.txt: %@", error.localizedDescription);
            [self showAlert:@"Failed to save dictionary.txt" info:error.localizedDescription];
            return;
        }
    }

    // Write system_prompt.txt
    if (self.systemPromptTextView) {
        NSString *promptPath = [dir stringByAppendingPathComponent:kSystemPromptFile];
        [self.systemPromptTextView.string writeToFile:promptPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            NSLog(@"[Koe] Failed to write system_prompt.txt: %@", error.localizedDescription);
            [self showAlert:@"Failed to save system_prompt.txt" info:error.localizedDescription];
            return;
        }
    }

    NSLog(@"[Koe] Settings saved");

    // Notify delegate to reload
    if ([self.delegate respondsToSelector:@selector(setupWizardDidSaveConfig)]) {
        [self.delegate setupWizardDidSaveConfig];
    }

    [self.window close];
}

- (void)cancelSetup:(id)sender {
    [self.window close];
}

- (void)showAlert:(NSString *)message info:(NSString *)info {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info ?: @"";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

@end
