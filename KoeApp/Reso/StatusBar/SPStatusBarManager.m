#import "SPStatusBarManager.h"
#import "SPPermissionManager.h"
#import "SPAudioDeviceManager.h"
#import "SPHistoryManager.h"
#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>

// Icon size for menu bar (points)
static const CGFloat kIconSize = 18.0;

@interface SPStatusBarManager ()

@property (nonatomic, weak) id<SPStatusBarDelegate> delegate;
@property (nonatomic, strong) SPPermissionManager *permissionManager;
@property (nonatomic, strong) SPAudioDeviceManager *audioDeviceManager;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@property (nonatomic, copy) NSString *currentState;

@end

static NSString *displayNameForHotkeyValue(NSString *value) {
    if ([value isEqualToString:@"left_option"]) {
        return @"Left Option (⌥)";
    }
    if ([value isEqualToString:@"right_option"]) {
        return @"Right Option (⌥)";
    }
    if ([value isEqualToString:@"left_command"]) {
        return @"Left Command (⌘)";
    }
    if ([value isEqualToString:@"right_command"]) {
        return @"Right Command (⌘)";
    }
    return @"Fn (Globe)";
}

@implementation SPStatusBarManager

- (instancetype)initWithDelegate:(id<SPStatusBarDelegate>)delegate
               permissionManager:(SPPermissionManager *)permissionManager
              audioDeviceManager:(SPAudioDeviceManager *)audioDeviceManager {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _permissionManager = permissionManager;
        _audioDeviceManager = audioDeviceManager;
        _currentState = @"idle";
        [self setupStatusBar];
    }
    return self;
}

- (void)setupStatusBar {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

    [self applyIdleIcon];

    // Build menu
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    menu.autoenablesItems = NO;

    // Status display with version info
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *statusTitle = [NSString stringWithFormat:@"Reso v%@", version];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:statusTitle
                                                    action:nil
                                             keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Settings..."
                                                      action:@selector(openSetupWizard:)
                                               keyEquivalent:@","];
    settings.target = self;
    [menu addItem:settings];

    NSMenuItem *checkForUpdates = [[NSMenuItem alloc] initWithTitle:@"Check for Updates..."
                                                             action:@selector(checkForUpdates:)
                                                      keyEquivalent:@""];
    checkForUpdates.target = self;
    [menu addItem:checkForUpdates];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *loginItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                      action:@selector(toggleLaunchAtLogin:)
                                               keyEquivalent:@""];
    loginItem.target = self;
    if (@available(macOS 13.0, *)) {
        loginItem.state = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled)
                          ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu addItem:loginItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Reso"
                                                 action:@selector(quitApp:)
                                          keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu {
    if ([self.delegate respondsToSelector:@selector(statusBarMenuDidOpen)]) {
        [self.delegate statusBarMenuDidOpen];
    }
}

- (void)menuDidClose:(NSMenu *)menu {
    if ([self.delegate respondsToSelector:@selector(statusBarMenuDidClose)]) {
        [self.delegate statusBarMenuDidClose];
    }
}

- (void)refreshMicrophoneSubmenu:(NSMenu *)menu {
    // Find the Microphone menu item
    NSInteger micIndex = [menu indexOfItemWithTitle:@"Microphone"];
    if (micIndex == -1) return;

    NSMenu *submenu = [menu itemAtIndex:micIndex].submenu;
    [submenu removeAllItems];

    NSString *selectedUID = self.audioDeviceManager.selectedDeviceUID;
    NSArray<SPAudioInputDevice *> *devices = [self.audioDeviceManager availableInputDevices];

    // Check if selected device is currently available
    BOOL selectedFound = NO;
    if (selectedUID) {
        for (SPAudioInputDevice *device in devices) {
            if ([device.uid isEqualToString:selectedUID]) {
                selectedFound = YES;
                break;
            }
        }
    }

    // "System Default" option
    NSMenuItem *defaultItem = [[NSMenuItem alloc] initWithTitle:@"System Default"
                                                        action:@selector(selectAudioDevice:)
                                                 keyEquivalent:@""];
    defaultItem.target = self;
    defaultItem.representedObject = nil;
    defaultItem.state = (selectedUID == nil) ? NSControlStateValueOn : NSControlStateValueOff;
    [submenu addItem:defaultItem];

    if (devices.count > 0) {
        [submenu addItem:[NSMenuItem separatorItem]];
    }

    // Available input devices
    // NOTE: Only device.name is shown. If the user has multiple devices with identical
    // names (e.g. two identical USB mics), they cannot be distinguished visually.
    // A future improvement could append a disambiguator (manufacturer, UID suffix, etc.).
    for (SPAudioInputDevice *device in devices) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:device.name
                                                      action:@selector(selectAudioDevice:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = device.uid;
        item.state = [device.uid isEqualToString:selectedUID] ? NSControlStateValueOn : NSControlStateValueOff;
        [submenu addItem:item];
    }

    // Show disconnected but still-selected device as a greyed-out item
    if (selectedUID && !selectedFound) {
        NSString *deviceName = self.audioDeviceManager.selectedDeviceName ?: selectedUID;
        [submenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *unavailableItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ (Unavailable)", deviceName]
                                                                action:nil
                                                         keyEquivalent:@""];
        unavailableItem.state = NSControlStateValueOn;
        unavailableItem.enabled = NO;
        [submenu addItem:unavailableItem];
    }
}

- (void)selectAudioDevice:(NSMenuItem *)sender {
    NSString *uid = sender.representedObject;
    NSString *name = uid ? sender.title : nil;
    [self.audioDeviceManager selectDevice:uid name:name];
    NSLog(@"[Koe] Audio device selected: %@", uid ?: @"System Default");

    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectAudioDeviceWithUID:)]) {
        [self.delegate statusBarDidSelectAudioDeviceWithUID:uid];
    }
}

#pragma mark - Helpers

- (NSView *)headerViewWithTitle:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:[NSFont systemFontSize] weight:NSFontWeightMedium];
    label.textColor = [NSColor labelColor];
    [label sizeToFit];

    // Match standard menu item padding
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, label.frame.size.height + 4)];
    label.frame = NSMakeRect(20, 2, label.frame.size.width, label.frame.size.height);
    [container addSubview:label];
    return container;
}

#pragma mark - Custom Icon Drawing

/// Create a template image drawn with the given block. Template images auto-adapt to dark/light mode.
- (NSImage *)templateImageWithDrawing:(void (^)(NSSize size))drawBlock {
    NSSize size = NSMakeSize(kIconSize, kIconSize);
    NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        drawBlock(size);
        return YES;
    }];
    image.template = YES;
    return image;
}

/// Idle: five static waveform bars — a calm, resting audio visualizer matching recording style
- (void)applyIdleIcon {
    NSImage *icon = [self templateImageWithDrawing:^(NSSize size) {
        CGFloat barWidth = 2.0;
        CGFloat spacing = 2.0;
        CGFloat centerX = size.width / 2.0;
        CGFloat centerY = size.height / 2.0;

        // Heights for 5 bars — symmetric resting state (short, medium, tall, medium, short)
        CGFloat heights[] = {4.0, 7.0, 11.0, 7.0, 4.0};
        NSInteger barCount = 5;
        CGFloat totalWidth = barCount * barWidth + (barCount - 1) * spacing;
        CGFloat startX = centerX - totalWidth / 2.0;

        [[NSColor blackColor] setFill];
        for (NSInteger i = 0; i < barCount; i++) {
            CGFloat x = startX + i * (barWidth + spacing);
            CGFloat h = heights[i];
            CGFloat y = centerY - h / 2.0;
            NSBezierPath *bar = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, barWidth, h)
                                                               xRadius:barWidth / 2.0
                                                               yRadius:barWidth / 2.0];
            [bar fill];
        }
    }];
    self.statusItem.button.image = icon;
}

#pragma mark - State Updates

- (void)updateState:(NSString *)state {
    self.currentState = state;

    if ([state isEqualToString:@"idle"] || [state isEqualToString:@"completed"]) {
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *ver = info[@"CFBundleShortVersionString"] ?: @"?";
        self.statusMenuItem.title = [NSString stringWithFormat:@"Ready — v%@", ver];
    } else if ([state hasPrefix:@"recording"]) {
        self.statusMenuItem.title = @"Listening...";
    } else if ([state isEqualToString:@"connecting_asr"] || [state isEqualToString:@"finalizing_asr"]) {
        self.statusMenuItem.title = @"Processing...";
    } else if ([state hasPrefix:@"preparing_paste"] || [state isEqualToString:@"pasting"]) {
        self.statusMenuItem.title = @"Copied to clipboard";
    } else if ([state isEqualToString:@"error"] || [state isEqualToString:@"failed"]) {
        self.statusMenuItem.title = @"Something went wrong";
    } else {
        self.statusMenuItem.title = @"Working...";
    }
}

#pragma mark - Actions

- (void)openSetupWizard:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectSetupWizard)]) {
        [self.delegate statusBarDidSelectSetupWizard];
    }
}

- (void)reloadConfig:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectReloadConfig)]) {
        [self.delegate statusBarDidSelectReloadConfig];
    }
}

- (void)checkForUpdates:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectCheckForUpdates)]) {
        [self.delegate statusBarDidSelectCheckForUpdates];
    }
}

- (void)toggleLaunchAtLogin:(NSMenuItem *)sender {
    if (@available(macOS 13.0, *)) {
        SMAppService *service = SMAppService.mainAppService;
        NSError *error = nil;
        if (service.status == SMAppServiceStatusEnabled) {
            [service unregisterAndReturnError:&error];
            sender.state = NSControlStateValueOff;
        } else {
            [service registerAndReturnError:&error];
            sender.state = NSControlStateValueOn;
        }
        if (error) {
            NSLog(@"[Koe] Launch at login toggle failed: %@", error.localizedDescription);
        }
    }
}

- (void)quitApp:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectQuit)]) {
        [self.delegate statusBarDidSelectQuit];
    } else {
        [NSApp terminate:nil];
    }
}

- (void)showStatusItem {
    if (!self.statusItem) {
        self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
        [self setupStatusBar];
    }
    self.statusItem.visible = YES;
}

- (void)hideStatusItem {
    if (self.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
        self.statusItem = nil;
    }
}


@end
