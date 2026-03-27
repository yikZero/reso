#import "SPAppDelegate.h"
#import "SPPermissionManager.h"
#import "SPHotkeyMonitor.h"
#import "SPAudioCaptureManager.h"
#import "SPAudioDeviceManager.h"
#import "SPRustBridge.h"
#import "SPClipboardManager.h"
#import "SPPasteManager.h"
#import "SPCuePlayer.h"
#import "SPStatusBarManager.h"
#import "SPOverlayPanel.h"
#import "SPHistoryManager.h"
#import "SPSetupWizardWindowController.h"
#import "SPUpdateManager.h"
#import "koe_core.h"
#import <sys/stat.h>
#import <UserNotifications/UserNotifications.h>

@interface SPAppDelegate () <SPAudioDeviceManagerDelegate>
@property (nonatomic, strong) NSDate *recordingStartTime;
@property (nonatomic, assign) time_t lastConfigModTime;
@end

@implementation SPAppDelegate

- (void)applyHotkeyConfig:(struct SPHotkeyConfig)hotkeyConfig restartMonitorIfNeeded:(BOOL)restartIfNeeded {
    BOOL changed = self.hotkeyMonitor.targetKeyCode != hotkeyConfig.trigger_key_code ||
                   self.hotkeyMonitor.altKeyCode != hotkeyConfig.trigger_alt_key_code ||
                   self.hotkeyMonitor.targetModifierFlag != hotkeyConfig.trigger_modifier_flag ||
                   self.hotkeyMonitor.cancelKeyCode != hotkeyConfig.cancel_key_code ||
                   self.hotkeyMonitor.cancelAltKeyCode != hotkeyConfig.cancel_alt_key_code ||
                   self.hotkeyMonitor.cancelModifierFlag != hotkeyConfig.cancel_modifier_flag;

    if (!changed) return;

    if (restartIfNeeded) {
        [self.hotkeyMonitor stop];
    }

    self.hotkeyMonitor.targetKeyCode = hotkeyConfig.trigger_key_code;
    self.hotkeyMonitor.altKeyCode = hotkeyConfig.trigger_alt_key_code;
    self.hotkeyMonitor.targetModifierFlag = hotkeyConfig.trigger_modifier_flag;
    self.hotkeyMonitor.cancelKeyCode = hotkeyConfig.cancel_key_code;
    self.hotkeyMonitor.cancelAltKeyCode = hotkeyConfig.cancel_alt_key_code;
    self.hotkeyMonitor.cancelModifierFlag = hotkeyConfig.cancel_modifier_flag;

    if (restartIfNeeded) {
        [self.hotkeyMonitor start];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"[Koe] Application launching...");

    // Add Edit menu so Cmd+C/V/X/A work in text fields (menu-bar-only app has none by default)
    [self installEditMenu];

    // Initialize components
    self.cuePlayer = [[SPCuePlayer alloc] init];
    self.clipboardManager = [[SPClipboardManager alloc] init];
    self.pasteManager = [[SPPasteManager alloc] init];
    self.audioCaptureManager = [[SPAudioCaptureManager alloc] init];
    self.audioDeviceManager = [[SPAudioDeviceManager alloc] init];
    self.audioDeviceManager.delegate = self;
    [self.audioDeviceManager startListening];
    self.permissionManager = [[SPPermissionManager alloc] init];

    // Initialize Rust bridge (must be before hotkey monitor)
    self.rustBridge = [[SPRustBridge alloc] initWithDelegate:self];
    [self.rustBridge initializeCore];

    // Initialize status bar
    self.statusBarManager = [[SPStatusBarManager alloc] initWithDelegate:self
                                                       permissionManager:self.permissionManager
                                                      audioDeviceManager:self.audioDeviceManager];

    // Apply menu icon visibility
    [self applyMenuIconVisibility];

    // Initialize floating overlay
    self.overlayPanel = [[SPOverlayPanel alloc] init];

    // Initialize app update checker
    self.updateManager = [[SPUpdateManager alloc] initWithBundle:[NSBundle mainBundle]];
    [self.updateManager start];

    // Request notification permission
    [self.permissionManager requestNotificationPermission];

    // Check permissions
    [self.permissionManager checkAllPermissionsWithCompletion:^(BOOL micGranted, BOOL accessibilityGranted, BOOL inputMonitoringGranted) {
        NSLog(@"[Koe] Permissions — mic:%d accessibility:%d inputMonitoring:%d",
              micGranted, accessibilityGranted, inputMonitoringGranted);

        if (!micGranted) {
            NSLog(@"[Koe] ERROR: Microphone permission not granted");
            [self.cuePlayer playError];
            return;
        }

        if (!inputMonitoringGranted) {
            NSLog(@"[Koe] WARNING: Input Monitoring probe failed, will attempt hotkey monitor anyway");
        }

        // Start hotkey monitor (let it try CGEventTap directly — the probe may give false negatives)
        self.hotkeyMonitor = [[SPHotkeyMonitor alloc] initWithDelegate:self];

        // Apply hotkey configuration from config.yaml
        struct SPHotkeyConfig hotkeyConfig = sp_core_get_hotkey_config();
        [self applyHotkeyConfig:hotkeyConfig restartMonitorIfNeeded:NO];

        [self.hotkeyMonitor start];
        NSLog(@"[Koe] Ready — hotkey monitor active");

        // Start watching config file for hotkey changes
        [self startConfigWatcher];
    }];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"[Koe] Application terminating...");
    if (self.configWatcher) {
        dispatch_source_cancel(self.configWatcher);
        self.configWatcher = nil;
    }
    [self.audioDeviceManager stopListening];
    [self.hotkeyMonitor stop];
    [self.rustBridge destroyCore];
}

#pragma mark - Edit Menu (for Cmd+C/V in text fields)

- (void)installEditMenu {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) {
        mainMenu = [[NSMenu alloc] init];
        [NSApp setMainMenu:mainMenu];
    }

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    editMenuItem.submenu = editMenu;
    [mainMenu addItem:editMenuItem];
}

#pragma mark - Config File Watcher

- (void)startConfigWatcher {
    NSString *configPath = [NSHomeDirectory() stringByAppendingPathComponent:@".koe/config.yaml"];

    // Record initial modification time
    struct stat st;
    if (stat(configPath.UTF8String, &st) == 0) {
        self.lastConfigModTime = st.st_mtime;
    }

    // Check config file modification every 3 seconds
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf checkConfigFileChanged];
    });

    dispatch_resume(timer);
    self.configWatcher = timer;
    NSLog(@"[Koe] Config file watcher started (polling every 3s)");
}

- (void)applyMenuIconVisibility {
    BOOL hideIcon = sp_core_get_hide_menu_icon();
    static BOOL lastHideIcon = NO;
    static BOOL initialized = NO;
    if (initialized && hideIcon == lastHideIcon) return;
    initialized = YES;
    lastHideIcon = hideIcon;

    if (hideIcon) {
        [self.statusBarManager hideStatusItem];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    } else {
        [self.statusBarManager showStatusItem];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}

- (void)checkConfigFileChanged {
    NSString *configPath = [NSHomeDirectory() stringByAppendingPathComponent:@".koe/config.yaml"];

    struct stat st;
    if (stat(configPath.UTF8String, &st) != 0) return;

    if (st.st_mtime == self.lastConfigModTime) return;
    self.lastConfigModTime = st.st_mtime;

    NSLog(@"[Koe] Config file changed, reloading hotkey config...");

    // Reload config in Rust core
    [self.rustBridge reloadConfig];

    // Read new hotkey config
    struct SPHotkeyConfig newConfig = sp_core_get_hotkey_config();

    NSLog(@"[Koe] Reloaded hotkey config: trigger=%d/%d flag=0x%llx cancel=%d/%d flag=0x%llx",
          newConfig.trigger_key_code,
          newConfig.trigger_alt_key_code,
          (unsigned long long)newConfig.trigger_modifier_flag,
          newConfig.cancel_key_code,
          newConfig.cancel_alt_key_code,
          (unsigned long long)newConfig.cancel_modifier_flag);
    [self applyHotkeyConfig:newConfig restartMonitorIfNeeded:YES];

    // Apply menu icon visibility
    [self applyMenuIconVisibility];
}

#pragma mark - SPHotkeyMonitorDelegate

- (void)hotkeyMonitorDidDetectHoldStart {
    NSLog(@"[Koe] Hold start detected");
    self.recordingStartTime = [NSDate date];
    [self.cuePlayer reloadFeedbackConfig];
    [self.cuePlayer playStart];
    [self.statusBarManager updateState:@"recording"];
    [self.overlayPanel updateState:@"recording"];

    // Start audio capture + Rust session
    [self.rustBridge beginSessionWithMode:SPSessionModeHold];
    [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
    [self.audioCaptureManager startCaptureWithAudioCallback:^(const void *buffer, uint32_t length, uint64_t timestamp) {
        [self.rustBridge pushAudioFrame:buffer length:length timestamp:timestamp];
    }];
}

- (void)hotkeyMonitorDidDetectHoldEnd {
    NSLog(@"[Koe] Hold end detected");
    [self.cuePlayer playStop];

    // Keep recording for 800ms after Fn release to capture trailing speech,
    // then stop mic and end session
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self.audioCaptureManager stopCapture];
        [self.rustBridge endSession];
    });
}

- (void)hotkeyMonitorDidDetectTapStart {
    NSLog(@"[Koe] Tap start detected");
    self.recordingStartTime = [NSDate date];
    [self.cuePlayer reloadFeedbackConfig];
    [self.cuePlayer playStart];
    [self.statusBarManager updateState:@"recording"];
    [self.overlayPanel updateState:@"recording"];

    [self.rustBridge beginSessionWithMode:SPSessionModeToggle];
    [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
    [self.audioCaptureManager startCaptureWithAudioCallback:^(const void *buffer, uint32_t length, uint64_t timestamp) {
        [self.rustBridge pushAudioFrame:buffer length:length timestamp:timestamp];
    }];
}

- (void)hotkeyMonitorDidDetectTapEnd {
    NSLog(@"[Koe] Tap end detected");
    [self.cuePlayer playStop];

    // Keep recording for 800ms after tap-end to capture trailing speech,
    // then stop mic and end session
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self.audioCaptureManager stopCapture];
        [self.rustBridge endSession];
    });
}

- (void)hotkeyMonitorDidDetectCancel {
    NSLog(@"[Koe] Cancel detected");
    [self.audioCaptureManager stopCapture];
    [self.rustBridge cancelSession];
    self.recordingStartTime = nil;
    [self.statusBarManager updateState:@"idle"];
    [self.overlayPanel updateState:@"idle"];
}

#pragma mark - SPRustBridgeDelegate

- (void)rustBridgeDidBecomeReady {
    NSLog(@"[Koe] Session ready (ASR connected)");
}

- (void)rustBridgeDidReceiveFinalText:(NSString *)text {
    NSLog(@"[Koe] Final text received (%lu chars)", (unsigned long)text.length);

    // Record history
    NSInteger durationMs = 0;
    if (self.recordingStartTime) {
        durationMs = (NSInteger)(-[self.recordingStartTime timeIntervalSinceNow] * 1000);
        self.recordingStartTime = nil;
    }
    [[SPHistoryManager sharedManager] recordSessionWithDurationMs:durationMs text:text];

    if ([self.permissionManager isAccessibilityGranted]) {
        [self.clipboardManager backup];
        [self.clipboardManager writeText:text];
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel updateState:@"idle"];
        [self.pasteManager simulatePasteWithCompletion:^{
            [self.clipboardManager scheduleRestoreAfterDelay:1500];
        }];
    } else {
        NSLog(@"[Koe] Accessibility not granted — showing text for manual copy");
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel updateState:@"idle"];
        [self showCopyableText:text];
    }
}

- (void)rustBridgeDidEncounterError:(NSString *)message {
    NSLog(@"[Koe] Session error: %@", message);
    BOOL isAuthError = [message containsString:@"401"];
    BOOL isNoSpeech = [message containsString:@"no speech recognized"];
    if (!isAuthError && !isNoSpeech) {
        [self.cuePlayer playError];
    }
    [self.audioCaptureManager stopCapture];
    [self.hotkeyMonitor resetToIdle];
    [self.statusBarManager updateState:@"error"];
    [self.overlayPanel updateState:@"error"];

    // Brief error display, then back to idle (only if still in error state)
    NSTimeInterval displayTime = isNoSpeech ? 1.0 : 2.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(displayTime * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self.overlayPanel.currentState isEqualToString:@"error"]) {
            [self.statusBarManager updateState:@"idle"];
            [self.overlayPanel updateState:@"idle"];
        }
    });
}

- (void)rustBridgeDidReceiveWarning:(NSString *)message {
    NSLog(@"[Koe] Session warning: %@", message);
}

- (void)rustBridgeDidReceiveInterimText:(NSString *)text {
}

- (void)rustBridgeDidChangeState:(NSString *)state {
    // Filter terminal states already handled by other callbacks:
    // - preparing_paste/pasting/completed: handled by rustBridgeDidReceiveFinalText:
    // - failed: handled by rustBridgeDidEncounterError: (which shows error + auto-dismiss)
    if ([state hasPrefix:@"preparing_paste"] || [state isEqualToString:@"pasting"]
        || [state isEqualToString:@"completed"] || [state isEqualToString:@"failed"]) {
        return;
    }
    [self.statusBarManager updateState:state];
    [self.overlayPanel updateState:state];
}

#pragma mark - Audio Error Recovery

- (void)showCopyableText:(NSString *)text {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Voice Input Result";
    alert.informativeText = @"Accessibility permission not granted. You can copy the text below:";

    NSTextField *textField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 80)];
    textField.stringValue = text;
    textField.editable = NO;
    textField.selectable = YES;
    textField.bezeled = YES;
    textField.bezelStyle = NSTextFieldRoundedBezel;
    textField.font = [NSFont systemFontOfSize:13];
    textField.lineBreakMode = NSLineBreakByWordWrapping;
    textField.usesSingleLineMode = NO;
    alert.accessoryView = textField;

    [alert addButtonWithTitle:@"Copy"];
    [alert addButtonWithTitle:@"Close"];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:text forType:NSPasteboardTypeString];
    }
}

- (void)handleAudioCaptureError:(NSString *)reason {
    NSLog(@"[Koe] Audio capture error: %@", reason);
    [self.cuePlayer playError];
    [self.rustBridge endSession];
    [self.hotkeyMonitor resetToIdle];
    [self.statusBarManager updateState:@"error"];
    [self.overlayPanel updateState:@"error"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self.overlayPanel.currentState isEqualToString:@"error"]) {
            [self.statusBarManager updateState:@"idle"];
            [self.overlayPanel updateState:@"idle"];
        }
    });
}

#pragma mark - SPAudioDeviceManagerDelegate

- (void)audioDeviceManagerDeviceListDidChange {
    if (!self.audioCaptureManager.isCapturing) return;

    // If the selected device disappeared mid-recording, stop gracefully
    if (![self.audioDeviceManager isSelectedDeviceAvailable]) {
        NSLog(@"[Koe] Selected audio device disappeared during recording");
        [self.audioCaptureManager stopCapture];
        [self handleAudioCaptureError:@"Audio device disconnected"];
    }
}

#pragma mark - Reopen (Spotlight / Finder re-launch)

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self statusBarDidSelectSetupWizard];
    return NO;
}

#pragma mark - SPStatusBarDelegate (menu)

- (void)statusBarMenuDidOpen {
    self.hotkeyMonitor.suspended = YES;
}

- (void)statusBarMenuDidClose {
    self.hotkeyMonitor.suspended = NO;
}

- (void)statusBarDidSelectQuit {
    [self.hotkeyMonitor stop];
    [NSApp terminate:nil];
}

- (void)statusBarDidSelectAudioDeviceWithUID:(NSString *)uid {
    NSLog(@"[Koe] Audio input device changed: %@", uid ?: @"System Default");
}

- (void)statusBarDidSelectSetupWizard {
    if (!self.setupWizard) {
        self.setupWizard = [[SPSetupWizardWindowController alloc] init];
        self.setupWizard.delegate = self;
    }
    [self.setupWizard showWindow:nil];
}

- (void)statusBarDidSelectCheckForUpdates {
    [self.updateManager checkForUpdatesFromUserAction];
}

#pragma mark - SPSetupWizardDelegate

- (void)setupWizardDidSaveConfig {
    NSLog(@"[Koe] Setup wizard saved config, reloading...");
    [self.rustBridge reloadConfig];

    // Re-apply hotkey config
    struct SPHotkeyConfig newConfig = sp_core_get_hotkey_config();
    [self applyHotkeyConfig:newConfig restartMonitorIfNeeded:YES];

    // Apply menu icon visibility
    [self applyMenuIconVisibility];
    NSLog(@"[Koe] Config reloaded after setup wizard save");
}

@end
