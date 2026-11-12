#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CAGradientLayer.h>
#import <AVFAudio/AVFAudio.h>
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "OfflineDiagnostics.h"
#include <pthread.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <unistd.h>

extern "C" int port_game_main(int, char **);
extern "C" void port_set_active(int);
extern "C" int rsx_metal_backend_attach_layer(void *);
extern "C" void rsx_metal_backend_on_first_presented(void (^handler)(void));
extern "C" void rsx_metal_touch_key(unsigned, int);
extern "C" void rsx_metal_touch_axis(unsigned, unsigned);
extern "C" void rsx_metal_touch_clear(void);
extern "C" int ps3_msgdialog_progress(char *msg, unsigned cap, unsigned *percent);

// Direct PS3 pad lane: host key 64+n sets CELL_PAD button bit n in cellPad
// (no keyboard-context remapping). Xbox positions map to the PS3 positions.
enum : unsigned {
    kPS3Select = 64, kPS3L3 = 65, kPS3R3 = 66, kPS3Start = 67,
    kPS3Up = 68, kPS3Right = 69, kPS3Down = 70, kPS3Left = 71,
    kPS3L2 = 72, kPS3R2 = 73, kPS3L1 = 74, kPS3R1 = 75,
    kPS3Triangle = 76, kPS3Circle = 77, kPS3Cross = 78, kPS3Square = 79,
};
static const unsigned kXboxA = 2001;
static const unsigned kXboxB = 2002;
static const unsigned kXboxX = 2003;
static const unsigned kXboxY = 2004;
static const unsigned kXboxLB = 2005;
static const unsigned kXboxRB = 2006;
static const unsigned kXboxLT = 2007;
static const unsigned kXboxRT = 2008;
static const unsigned kXboxView = 2009;
static const unsigned kXboxMenu = 2010;
extern "C" void SDL_SetMainReady(void);

@interface DIRT3MetalView : UIView
@end
@implementation DIRT3MetalView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

// A static translucent surface: no backdrop blur, display link or render polling.
// Only layout and touch-state changes update these layers.
@interface DIRT3ControlButton : UIButton
@property(nonatomic, strong) CAGradientLayer *sheen;
@property(nonatomic, strong) UIView *stickKnob;
@property(nonatomic, strong) UILabel *stickLabel;
@property(nonatomic) CGPoint stickOffset;
@end
@implementation DIRT3ControlButton
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.75;
        self.layer.cornerRadius = 15;
        self.adjustsImageWhenHighlighted = NO;
        self.sheen = [CAGradientLayer layer];
        [self.layer insertSublayer:self.sheen atIndex:0];
        [self updateAppearance];
    }
    return self;
}
- (void)updateAppearance
{
    UIColor *accent = [UIColor colorWithRed:1.0 green:0.80 blue:0.28 alpha:1.0];
    UIColor *foreground = self.highlighted ? accent : [UIColor.whiteColor colorWithAlphaComponent:0.86];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.backgroundColor = self.highlighted ? [accent colorWithAlphaComponent:0.14] :
                                             [UIColor.blackColor colorWithAlphaComponent:0.10];
    self.layer.borderColor = (self.highlighted ? [accent colorWithAlphaComponent:0.85] :
                                                [UIColor.whiteColor colorWithAlphaComponent:0.24]).CGColor;
    self.sheen.colors = @[(id)[UIColor.whiteColor colorWithAlphaComponent:self.highlighted ? 0.16 : 0.10].CGColor,
                         (id)[UIColor.whiteColor colorWithAlphaComponent:0.015].CGColor];
    self.tintColor = foreground;
    [self setTitleColor:[UIColor.whiteColor colorWithAlphaComponent:0.86] forState:UIControlStateNormal];
    [self setTitleColor:accent forState:UIControlStateHighlighted];
    [CATransaction commit];
}
- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    [self updateAppearance];
}
- (void)layoutSubviews
{
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.sheen.frame = self.bounds;
    self.sheen.cornerRadius = self.layer.cornerRadius;
    self.sheen.cornerCurve = kCACornerCurveContinuous;
    if (self.stickKnob) {
        CGFloat diameter = MIN(self.bounds.size.width, self.bounds.size.height) * 0.42;
        self.stickKnob.bounds = CGRectMake(0, 0, diameter, diameter);
        self.stickKnob.center = CGPointMake(CGRectGetMidX(self.bounds) + self.stickOffset.x,
                                           CGRectGetMidY(self.bounds) + self.stickOffset.y);
        self.stickKnob.layer.cornerRadius = diameter / 2.0;
        self.stickLabel.frame = self.stickKnob.bounds;
    }
    [CATransaction commit];
}
@end

static NSDictionary *launchConfiguration(void)
{
    NSURL *url = [NSBundle.mainBundle URLForResource:@"DIRT3Launch" withExtension:@"json"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    id config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [config isKindOfClass:NSDictionary.class] ? config : nil;
}

static NSString *portTitle(void)
{
    id title = launchConfiguration()[@"environment"][@"PS3_TITLE"];
    return [title isKindOfClass:NSString.class] && [title length] ? title : @"DiRT 3";
}

// File validation can touch thousands of files. Keep it off UIKit's thread so
// the interface remains responsive while local/bookmarked storage is checked.
static NSURL *validatedGameRoot(NSURL *root, NSDictionary *files)
{
    if (!root || ![files isKindOfClass:NSDictionary.class] || !files.count) return nil;
    if ([root.lastPathComponent isEqualToString:@"PS3_GAME"]) root = root.URLByDeletingLastPathComponent;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm isReadableFileAtPath:[root URLByAppendingPathComponent:@"PS3_GAME/USRDIR/EBOOT.elf"].path]) return nil;
    for (NSString *relative in files) {
        NSDictionary *attributes = [fm attributesOfItemAtPath:[root URLByAppendingPathComponent:relative].path error:nil];
        if (!attributes || [attributes fileSize] != [files[relative] unsignedLongLongValue]) return nil;
    }
    return root;
}

@interface DIRT3Controller : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic, strong) DIRT3MetalView *gameView;
@property(nonatomic, strong) UIView *controls;
@property(nonatomic, strong) UIButton *controlsToggle;
@property(nonatomic, strong) UIButton *stickToggle;
@property(nonatomic, strong) NSURL *gameRoot;
@property(nonatomic, strong) NSURL *scopedURL;
@property(nonatomic) BOOL attemptedLaunch;
@property(nonatomic) BOOL launchPending;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL gameRunning;
@property(nonatomic) BOOL fillGameScreen;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableSet<NSString *> *> *gamepadSources;
@property(nonatomic) BOOL stickControlsEnabled;
@property(nonatomic, strong) UIView *progressPanel;
@property(nonatomic, strong) UILabel *progressTitle;
@property(nonatomic, strong) UIProgressView *progressBar;
@property(nonatomic, strong) UILabel *progressPercent;
@property(nonatomic, strong) NSTimer *progressTimer;
- (void)gameReturned:(int)result;
- (void)updateControlsToggleLabel;
- (void)setTouchControlsVisible:(BOOL)visible;
@end

struct BootArguments { char *eboot; void *controller; };
static void *runGame(void *opaque)
{
    @autoreleasepool {
        BootArguments *boot = static_cast<BootArguments *>(opaque);
        DIRT3Controller *controller = (__bridge_transfer DIRT3Controller *)boot->controller;
        AVAudioSession *audio = AVAudioSession.sharedInstance;
        NSError *audioError = nil;
        BOOL configured = [audio setCategory:AVAudioSessionCategoryPlayback
                                      mode:AVAudioSessionModeDefault options:0 error:&audioError];
        BOOL activated = configured && [audio setActive:YES error:&audioError];
        if (!activated) NSLog(@"DiRT 3 audio activation failed: %@", audioError);
#if PORT_IOS_DIAGNOSTICS
        MSDiagnosticsEvent(@"audio_session", @{@"active":@(activated), @"main_thread":@(NSThread.isMainThread),
            @"sample_rate":@(audio.sampleRate), @"io_buffer_ms":@(audio.IOBufferDuration*1000),
            @"error":audioError.localizedDescription ?: @""});
#endif
        char name[] = "DIRT3";
        char *args[] = {name, boot->eboot, nullptr};
        int result = port_game_main(2, args);
        free(boot->eboot);
        delete boot;
        dispatch_async(dispatch_get_main_queue(), ^{ [controller gameReturned:result]; });
    }
    return nullptr;
}

@implementation DIRT3Controller
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.gamepadSources = [NSMutableDictionary dictionary];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(gamepadConnected:)
        name:GCControllerDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(gamepadDisconnected:)
        name:GCControllerDidDisconnectNotification object:nil];
    for (GCController *controller in GCController.controllers) [self configureGamepad:controller];
    self.view.multipleTouchEnabled = YES;
    self.gameView = [DIRT3MetalView new];
    self.gameView.backgroundColor = UIColor.blackColor;
    self.gameView.userInteractionEnabled = NO;
    // Only stretch the presented texture. The renderer still owns drawableSize
    // at the guest resolution; the controls are a separate sibling view.
    self.gameView.layer.contentsGravity = kCAGravityResize;
    const char *fillScreen = getenv("PORT_IOS_FILL_SCREEN");
    self.fillGameScreen = !fillScreen || strcmp(fillScreen, "0") != 0;
    [self.view addSubview:self.gameView];
    [self buildProgressPanel];
    self.controls = [UIView new];
    self.controls.hidden = YES;
    self.controls.multipleTouchEnabled = YES;
    [self.view addSubview:self.controls];
    // Touch controls follow the Xbox controller positions and button labels.
    // They feed the same guest keys as the corresponding physical gamepad.
    [self addControl:@"◀" key:123];
    [self addControl:@"▶" key:124];
    [self addControl:@"↑" key:126];
    [self addControl:@"↓" key:125];
    [self addControl:@"A" key:kXboxA];
    [self addControl:@"B" key:kXboxB];
    [self addControl:@"X" key:kXboxX];
    [self addControl:@"Y" key:kXboxY];
    [self addControl:@"LB" key:kXboxLB];
    [self addControl:@"RB" key:kXboxRB];
    [self addControl:@"LT" key:kXboxLT];
    [self addControl:@"RT" key:kXboxRT];
    [self addControl:@"View" key:kXboxView];
    [self addControl:@"Menu" key:kXboxMenu];
    [self addControl:@"L3" key:130];
    [self addControl:@"R3" key:131];
    [self addControl:@"◉" key:132];
    [self addControl:@"◉" key:133];
    for (UIButton *stick in self.controls.subviews) if (stick.tag == 132 || stick.tag == 133) {
        DIRT3ControlButton *pad = (DIRT3ControlButton *)stick;
        [stick setTitle:nil forState:UIControlStateNormal];
        stick.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.20];
        pad.stickKnob = [UIView new];
        pad.stickKnob.userInteractionEnabled = NO;
        pad.stickKnob.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.18];
        pad.stickKnob.layer.borderWidth = 1.0;
        pad.stickKnob.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.48].CGColor;
        pad.stickLabel = [UILabel new];
        pad.stickLabel.text = stick.tag == 132 ? @"L" : @"R";
        pad.stickLabel.textAlignment = NSTextAlignmentCenter;
        pad.stickLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.8];
        pad.stickLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [pad.stickKnob addSubview:pad.stickLabel];
        [pad addSubview:pad.stickKnob];
        stick.accessibilityLabel = stick.tag == 132 ? @"Left analog stick" : @"Right analog stick";
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveVirtualStick:)];
        pan.cancelsTouchesInView = YES;
        [stick addGestureRecognizer:pan];
    }

    // Keep a small control-layout switch outside the hideable touch-control
    // container, so it remains available after the driving buttons are hidden.
    self.controlsToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    self.controlsToggle.accessibilityIdentifier = @"touch-controls-toggle";
    self.controlsToggle.accessibilityLabel = @"Show touch controls";
    self.controlsToggle.accessibilityHint = @"Shows or hides the on-screen controls.";
    [self.controlsToggle setImage:[UIImage systemImageNamed:@"gamecontroller"]
                         forState:UIControlStateNormal];
    self.controlsToggle.tintColor = UIColor.whiteColor;
    self.controlsToggle.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.5];
    self.controlsToggle.layer.cornerCurve = kCACornerCurveContinuous;
    self.controlsToggle.layer.cornerRadius = 21;
    self.controlsToggle.layer.borderWidth = 0.75;
    self.controlsToggle.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.28].CGColor;
    self.controlsToggle.alpha = 0.5;
    [self.controlsToggle addTarget:self action:@selector(toggleTouchControls)
                  forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.controlsToggle];
    self.stickToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.stickToggle setTitle:@"3D" forState:UIControlStateNormal];
    self.stickToggle.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    self.stickToggle.tintColor = UIColor.whiteColor;
    self.stickToggle.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.5];
    self.stickToggle.layer.cornerRadius = 21;
    self.stickToggle.layer.borderWidth = 0.75;
    self.stickToggle.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.28].CGColor;
    self.stickToggle.alpha = 0.5;
    self.stickToggle.accessibilityLabel = @"Show analog sticks and L3/R3";
    [self.stickToggle addTarget:self action:@selector(toggleStickControls) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.stickToggle];
    self.controls.hidden = GCController.controllers.count > 0;
    [self updateControlsToggleLabel];
}
- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.attemptedLaunch) return;
    self.attemptedLaunch = YES;
    // The Metal layer now has a window and laid-out bounds. No artificial delay
    // or developer launch argument is needed for an ordinary app-icon launch.
    [self locateGameAndStart:nil];
}
- (void)addControl:(NSString *)title key:(unsigned)key
{
    UIButton *button = [[DIRT3ControlButton alloc] initWithFrame:CGRectZero];
    button.tag = key;
    button.accessibilityIdentifier = [NSString stringWithFormat:@"pad-%u", key];
    button.accessibilityLabel = title;
    switch (key) {
        case 123: button.accessibilityLabel = @"Left"; break;
        case 124: button.accessibilityLabel = @"Right"; break;
        case 126: button.accessibilityLabel = @"Throttle / menu up"; break;
        case 125: button.accessibilityLabel = @"Brake / menu down"; break;
        case kXboxA: button.accessibilityLabel = @"Xbox A"; break;
        case kXboxB: button.accessibilityLabel = @"Xbox B"; break;
        case kXboxX: button.accessibilityLabel = @"Xbox X"; break;
        case kXboxY: button.accessibilityLabel = @"Xbox Y / camera"; break;
        case kXboxLB: button.accessibilityLabel = @"Left bumper"; break;
        case kXboxRB: button.accessibilityLabel = @"Right bumper"; break;
        case kXboxLT: button.accessibilityLabel = @"Left trigger / brake"; break;
        case kXboxRT: button.accessibilityLabel = @"Right trigger / throttle"; break;
        case kXboxView: button.accessibilityLabel = @"View / confirm"; break;
        case kXboxMenu: button.accessibilityLabel = @"Menu / back"; break;
        case 130: button.accessibilityLabel = @"Left stick click (L3)"; break;
        case 131: button.accessibilityLabel = @"Right stick click (R3)"; break;
    }
    BOOL xboxButton = key >= kXboxA && key <= kXboxY;
    button.titleLabel.font = [UIFont systemFontOfSize:xboxButton ? 19 : 13
                                               weight:xboxButton ? UIFontWeightBold : UIFontWeightSemibold];
    NSString *symbol = nil;
    switch (key) {
        case 123: symbol = @"chevron.left"; break;
        case 124: symbol = @"chevron.right"; break;
        case 126: symbol = @"chevron.up"; break;
        case 125: symbol = @"chevron.down"; break;
    }
    if (symbol) {
        [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
        [button setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22
            weight:UIImageSymbolWeightMedium] forImageInState:UIControlStateNormal];
    } else {
        [button setTitle:title forState:UIControlStateNormal];
    }
    [button addTarget:self action:@selector(controlDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [button addTarget:self action:@selector(controlUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    [self.controls addSubview:button];
}
- (NSArray<NSNumber *> *)guestKeysForTouchTag:(unsigned)tag
{
    switch (tag) {
        case 123: return @[@(kPS3Left)];
        case 124: return @[@(kPS3Right)];
        case 126: return @[@(kPS3Up)];
        case 125: return @[@(kPS3Down)];
        case kXboxA: return @[@(kPS3Cross)];
        case kXboxB: return @[@(kPS3Circle)];
        case kXboxX: return @[@(kPS3Square)];
        case kXboxY: return @[@(kPS3Triangle)];
        case kXboxLB: return @[@(kPS3L1)];
        case kXboxRB: return @[@(kPS3R1)];
        case kXboxLT: return @[@(kPS3L2)];
        case kXboxRT: return @[@(kPS3R2)];
        case kXboxView: return @[@(kPS3Select)];
        case kXboxMenu: return @[@(kPS3Start)];
        case 130: return @[@(kPS3L3)];
        case 131: return @[@(kPS3R3)];
        default: return @[];
    }
}
- (void)controlDown:(UIButton *)sender
{
    NSString *source = [NSString stringWithFormat:@"touch-button-%u", (unsigned)sender.tag];
    for (NSNumber *key in [self guestKeysForTouchTag:(unsigned)sender.tag])
        [self setGamepadKey:key.unsignedIntValue source:source pressed:YES];
    sender.highlighted = YES;
}
- (void)controlUp:(UIButton *)sender
{
    NSString *source = [NSString stringWithFormat:@"touch-button-%u", (unsigned)sender.tag];
    for (NSNumber *key in [self guestKeysForTouchTag:(unsigned)sender.tag])
        [self setGamepadKey:key.unsignedIntValue source:source pressed:NO];
    sender.highlighted = NO;
}
- (void)setGamepadKey:(unsigned)key source:(NSString *)source pressed:(BOOL)pressed
{
    void (^update)(void) = ^{
        NSNumber *number = @(key);
        NSMutableSet<NSString *> *sources = self.gamepadSources[number];
        BOOL wasPressed = sources.count != 0;
        if (pressed) {
            if (!sources) self.gamepadSources[number] = sources = [NSMutableSet set];
            [sources addObject:source];
        } else {
            [sources removeObject:source];
            if (!sources.count) [self.gamepadSources removeObjectForKey:number];
        }
        BOOL isPressed = self.gamepadSources[number].count != 0;
        if (wasPressed != isPressed) rsx_metal_touch_key(key, isPressed ? 1 : 0);
    };
    if (NSThread.isMainThread) update();
    else dispatch_async(dispatch_get_main_queue(), update);
}
- (void)gamepadConnected:(NSNotification *)notification
{
    [self configureGamepad:notification.object];
    dispatch_async(dispatch_get_main_queue(), ^{ [self setTouchControlsVisible:NO]; });
}
- (void)gamepadDisconnected:(NSNotification *)notification
{
    NSString *prefix = [NSString stringWithFormat:@"%p:", notification.object];
    for (NSNumber *key in self.gamepadSources.allKeys.copy) {
        for (NSString *source in self.gamepadSources[key].copy)
            if ([source hasPrefix:prefix]) [self setGamepadKey:key.unsignedIntValue source:source pressed:NO];
    }
    for (unsigned i = 0; i < 6; ++i) rsx_metal_touch_axis(i, i < 4 ? 128 : 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (GCController.controllers.count == 0) self.controls.hidden = NO;
        [self updateControlsToggleLabel];
    });
}
- (void)updateControlsToggleLabel
{
    self.controlsToggle.accessibilityLabel = self.controls.hidden ? @"Show touch controls" : @"Hide touch controls";
}
- (void)setTouchControlsVisible:(BOOL)visible
{
    if (!visible) {
        for (UIView *view in self.controls.subviews) {
            if ([view isKindOfClass:UIButton.class] && ((UIButton *)view).highlighted)
                [self controlUp:(UIButton *)view];
        }
    }
    if (!visible) {
        for (unsigned i=0; i<4; ++i) rsx_metal_touch_axis(i,128);
        for (UIView *view in self.controls.subviews)
            if (view.tag == 132 || view.tag == 133) {
                ((DIRT3ControlButton *)view).stickOffset = CGPointZero;
                [view setNeedsLayout];
            }
    }
    self.controls.hidden = !visible;
    [self updateControlsToggleLabel];
}
- (void)toggleTouchControls
{
    [self setTouchControlsVisible:self.controls.hidden];
}
- (void)toggleStickControls
{
    self.stickControlsEnabled = !self.stickControlsEnabled;
    self.stickToggle.accessibilityLabel = self.stickControlsEnabled ? @"Hide analog sticks and L3/R3" : @"Show analog sticks and L3/R3";
    self.stickToggle.backgroundColor = [UIColor colorWithWhite:self.stickControlsEnabled ? 0.28 : 0.0 alpha:0.55];
    for (UIView *v in self.controls.subviews) if (v.tag >= 130 && v.tag <= 133) {
        v.hidden = !self.stickControlsEnabled;
        if (v.tag == 132 || v.tag == 133) {
            ((DIRT3ControlButton *)v).stickOffset = CGPointZero;
            [v setNeedsLayout];
        }
    }
    for (unsigned i=0; i<4; ++i) rsx_metal_touch_axis(i,128);
}
- (void)moveVirtualStick:(UIPanGestureRecognizer *)gesture
{
    DIRT3ControlButton *stick = (DIRT3ControlButton *)gesture.view;
    CGPoint delta = [gesture translationInView:stick];
    CGFloat radius = MAX(1.0, MIN(stick.bounds.size.width, stick.bounds.size.height) * 0.29);
    CGFloat x = MAX(-1.0, MIN(1.0, delta.x / radius));
    CGFloat y = MAX(-1.0, MIN(1.0, delta.y / radius));
    unsigned base = stick.tag == 132 ? 0 : 2;
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) x = y = 0;
    stick.stickOffset = CGPointMake(x * radius, y * radius);
    [stick setNeedsLayout];
    rsx_metal_touch_axis(base, (unsigned)lrintf(128.0f + x * 127.0f));
    rsx_metal_touch_axis(base + 1, (unsigned)lrintf(128.0f + y * 127.0f));
}
- (void)clearGamepadInputs
{
    for (NSNumber *key in self.gamepadSources.allKeys) rsx_metal_touch_key(key.unsignedIntValue, 0);
    [self.gamepadSources removeAllObjects];
}
- (void)configureGamepad:(GCController *)controller
{
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;
    NSString *prefix = [NSString stringWithFormat:@"%p:", controller];
    void (^button)(GCControllerButtonInput *, unsigned, NSString *) = ^(GCControllerButtonInput *input, unsigned key, NSString *name) {
        input.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
            [self setGamepadKey:key source:[prefix stringByAppendingString:name] pressed:pressed];
        };
    };
    button(pad.dpad.left, kPS3Left, @"dpad-left"); button(pad.dpad.right, kPS3Right, @"dpad-right");
    button(pad.dpad.up, kPS3Up, @"dpad-up"); button(pad.dpad.down, kPS3Down, @"dpad-down");
    button(pad.buttonA, kPS3Cross, @"a-cross");
    button(pad.buttonB, kPS3Circle, @"b-circle");
    button(pad.buttonX, kPS3Square, @"x-square");
    button(pad.buttonY, kPS3Triangle, @"y-triangle");
    button(pad.leftShoulder, kPS3L1, @"lb-l1");
    button(pad.rightShoulder, kPS3R1, @"rb-r1");
    button(pad.buttonMenu, kPS3Start, @"menu-start");
    if (pad.buttonOptions) button(pad.buttonOptions, kPS3Select, @"view-select");
    if (pad.leftThumbstickButton) button(pad.leftThumbstickButton, kPS3L3, @"l3");
    if (pad.rightThumbstickButton) button(pad.rightThumbstickButton, kPS3R3, @"r3");
    // Analog triggers -> L2/R2 pressure (axes 4/5); cellPad derives the digital bit.
    pad.leftTrigger.valueChangedHandler = ^(GCControllerButtonInput *trigger, float value, BOOL pressed) {
        rsx_metal_touch_axis(4, (unsigned)lrintf(MAX(0.0f, MIN(1.0f, value)) * 255.0f));
    };
    pad.rightTrigger.valueChangedHandler = ^(GCControllerButtonInput *trigger, float value, BOOL pressed) {
        rsx_metal_touch_axis(5, (unsigned)lrintf(MAX(0.0f, MIN(1.0f, value)) * 255.0f));
    };
    pad.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *stick, float x, float y) {
        rsx_metal_touch_axis(0, (unsigned)lrintf(128.0f + MAX(-1.0f, MIN(1.0f, x)) * 127.0f));
        rsx_metal_touch_axis(1, (unsigned)lrintf(128.0f - MAX(-1.0f, MIN(1.0f, y)) * 127.0f));
    };
    pad.rightThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *stick, float x, float y) {
        rsx_metal_touch_axis(2, (unsigned)lrintf(128.0f + MAX(-1.0f, MIN(1.0f, x)) * 127.0f));
        rsx_metal_touch_axis(3, (unsigned)lrintf(128.0f - MAX(-1.0f, MIN(1.0f, y)) * 127.0f));
    };
}
// Semi-transparent progress panel for the game's progress-bar dialogs (the
// first-boot copy of install.nfs, about 4 GB). The firmware dialog is not
// rendered by the port, so without this the screen stays black while copying.
- (void)buildProgressPanel
{
    self.progressPanel = [UIView new];
    self.progressPanel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
    self.progressPanel.layer.cornerRadius = 16;
    self.progressPanel.layer.borderWidth = 1;
    self.progressPanel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    self.progressPanel.userInteractionEnabled = NO;
    self.progressPanel.hidden = YES;
    self.progressTitle = [UILabel new];
    self.progressTitle.text = @"Copying game files";
    self.progressTitle.textColor = UIColor.whiteColor;
    self.progressTitle.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.progressPercent = [UILabel new];
    self.progressPercent.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    self.progressPercent.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightMedium];
    self.progressPercent.textAlignment = NSTextAlignmentRight;
    self.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressBar.progressTintColor = [UIColor colorWithRed:1.0 green:0.62 blue:0.1 alpha:1.0];
    self.progressBar.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    for (UIView *v in @[self.progressTitle, self.progressPercent, self.progressBar])
        [self.progressPanel addSubview:v];
    [self.view addSubview:self.progressPanel];
}

- (void)pollProgress
{
    char msg[256]; unsigned percent = 0;
    BOOL open = ps3_msgdialog_progress(msg, sizeof msg, &percent) != 0;
    if (open) {
        [self.view bringSubviewToFront:self.progressPanel];
        self.progressPercent.text = [NSString stringWithFormat:@"%u%%", percent];
        [self.progressBar setProgress:percent / 100.0f animated:YES];
    }
    self.progressPanel.hidden = !open;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat scale = MIN(bounds.size.width / 1280.0, bounds.size.height / 720.0);
    CGSize size = CGSizeMake(1280 * scale, 720 * scale);
    // Fill Duo's taller landscape display. Conventional 16:9/wider displays
    // retain the previous fit. A launch override of 0 restores fit everywhere.
    BOOL tallerLandscape = bounds.size.width > bounds.size.height &&
                           bounds.size.height > bounds.size.width * (720.0 / 1280.0);
    self.gameView.frame = self.fillGameScreen && tallerLandscape ? bounds :
        CGRectMake((bounds.size.width-size.width)/2, (bounds.size.height-size.height)/2, size.width, size.height);
    self.controls.frame = bounds;
    CGFloat panelWidth = MIN(420.0, bounds.size.width - 48.0);
    self.progressPanel.frame = CGRectMake((bounds.size.width - panelWidth) / 2,
                                          (bounds.size.height - 112.0) / 2, panelWidth, 112.0);
    self.progressTitle.frame = CGRectMake(20, 18, panelWidth - 110, 26);
    self.progressPercent.frame = CGRectMake(panelWidth - 90, 18, 70, 26);
    self.progressBar.frame = CGRectMake(20, 62, panelWidth - 40, 8);
    UIEdgeInsets safe = self.view.safeAreaInsets;
    // Anchor the overlay to the screen edges. The Duo cover display reports a
    // large horizontal safe inset that swaps sides on rotation; applying it to
    // these controls leaves one entire thumb group unnecessarily far inboard.
    // Keep safe-area sizing and vertical placement, including on the inner screen.
    CGFloat left = 12, right = bounds.size.width - 12;
    CGFloat centerX = bounds.size.width / 2.0;
    self.controlsToggle.frame = CGRectMake(centerX - 46.0, safe.top + 10.0, 42.0, 42.0);
    self.stickToggle.frame = CGRectMake(centerX + 4.0, safe.top + 10.0, 42.0, 42.0);
    // Compact Xbox layout: the D-pad sits at the left thumb position, the
    // ABXY cluster at the right, and bumpers/triggers plus View/Menu stay above.
    CGFloat safeWidth = bounds.size.width - safe.left - safe.right;
    CGFloat buttonSize = MIN(60.0, MAX(46.0, safeWidth * 0.065));
    CGFloat buttonGap = 7.0;
    CGFloat bottom = bounds.size.height - safe.bottom - 16.0;
    CGFloat leftCenterX = left + buttonSize * 1.5 + buttonGap;
    CGFloat leftCenterY = bottom - buttonSize * 1.5 - buttonGap;
    CGFloat rightCenterX = right - buttonSize * 1.5 - buttonGap;
    CGFloat rightCenterY = bottom - buttonSize * 1.5 - buttonGap;
    CGFloat topY = safe.top + 12.0;
    CGFloat triggerWidth = 58.0, triggerHeight = 38.0, triggerGap = 8.0;
    for (UIButton *b in self.controls.subviews) {
        if (b.tag >= 123 && b.tag <= 126) {
            [b setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:buttonSize * 0.36
                weight:UIImageSymbolWeightMedium] forImageInState:UIControlStateNormal];
            b.layer.cornerRadius = buttonSize * 0.25;
        }
        switch (b.tag) {
            case 123: b.frame=CGRectMake(leftCenterX-buttonSize*1.5-buttonGap,leftCenterY-buttonSize/2,buttonSize,buttonSize); break;
            case 124: b.frame=CGRectMake(leftCenterX+buttonSize/2+buttonGap,leftCenterY-buttonSize/2,buttonSize,buttonSize); break;
            case 126: b.frame=CGRectMake(leftCenterX-buttonSize/2,leftCenterY-buttonSize*1.5-buttonGap,buttonSize,buttonSize); break;
            case 125: b.frame=CGRectMake(leftCenterX-buttonSize/2,leftCenterY+buttonSize/2+buttonGap,buttonSize,buttonSize); break;
            case kXboxX: b.frame=CGRectMake(rightCenterX-buttonSize*1.5-buttonGap,rightCenterY-buttonSize/2,buttonSize,buttonSize); break;
            case kXboxB: b.frame=CGRectMake(rightCenterX+buttonSize/2+buttonGap,rightCenterY-buttonSize/2,buttonSize,buttonSize); break;
            case kXboxY: b.frame=CGRectMake(rightCenterX-buttonSize/2,rightCenterY-buttonSize*1.5-buttonGap,buttonSize,buttonSize); break;
            case kXboxA: b.frame=CGRectMake(rightCenterX-buttonSize/2,rightCenterY+buttonSize/2+buttonGap,buttonSize,buttonSize); break;
            case kXboxLB: b.frame=CGRectMake(left,topY,triggerWidth,triggerHeight); break;
            case kXboxLT: b.frame=CGRectMake(left+triggerWidth+triggerGap,topY,triggerWidth,triggerHeight); break;
            case kXboxRT: b.frame=CGRectMake(right-2*triggerWidth-triggerGap,topY,triggerWidth,triggerHeight); break;
            case kXboxRB: b.frame=CGRectMake(right-triggerWidth,topY,triggerWidth,triggerHeight); break;
            case kXboxView: b.frame=CGRectMake(centerX-118.0,topY,64,triggerHeight); break;
            case kXboxMenu: b.frame=CGRectMake(centerX+54.0,topY,64,triggerHeight); break;
            case 130: b.frame=CGRectMake(bounds.size.width*0.31-25,bounds.size.height-safe.bottom-214,50,42); b.hidden=!self.stickControlsEnabled; break;
            case 131: b.frame=CGRectMake(bounds.size.width*0.69-25,bounds.size.height-safe.bottom-214,50,42); b.hidden=!self.stickControlsEnabled; break;
            case 132: b.frame=CGRectMake(bounds.size.width*0.31-60,bounds.size.height-safe.bottom-164,120,120); b.layer.cornerRadius=60; b.hidden=!self.stickControlsEnabled; break;
            case 133: b.frame=CGRectMake(bounds.size.width*0.69-60,bounds.size.height-safe.bottom-164,120,120); b.layer.cornerRadius=60; b.hidden=!self.stickControlsEnabled; break;
        }
    }
}
- (NSURL *)documents
{
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
}
- (void)showLaunchError:(NSString *)message allowFolder:(BOOL)allowFolder
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Unable to start %@", portTitle()]
        message:message preferredStyle:UIAlertControllerStyleAlert];
    if (allowFolder) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Choose game folder" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) { [self chooseGame]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Try again" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) { [self locateGameAndStart:nil]; }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)locateGameAndStart:(NSURL *)picked
{
    if (self.started || self.launchPending) return;
    self.launchPending = YES;
    [self.scopedURL stopAccessingSecurityScopedResource]; self.scopedURL = nil;
    NSURL *documents = [self documents];
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:@"GameFolder"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSDictionary *config = launchConfiguration();
            NSDictionary *files = config[@"files"];
            NSURL *access = nil;
            NSURL *root = nil;
            NSURL *chosen = picked;
            if (!picked) root = validatedGameRoot([documents URLByAppendingPathComponent:@"game" isDirectory:YES], files);
            if (!root && !chosen && bookmark) {
                BOOL stale = NO;
                chosen = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
            }
            if (!root && chosen) {
                if ([chosen startAccessingSecurityScopedResource]) access = chosen;
                root = validatedGameRoot(chosen, files);
                if (!root) { [access stopAccessingSecurityScopedResource]; access = nil; }
            }
            NSData *newBookmark = picked && root ? [picked bookmarkDataWithOptions:0
                includingResourceValuesForKeys:nil relativeToURL:nil error:nil] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.launchPending = NO;
                self.scopedURL = access;
                self.gameRoot = root;
                if (newBookmark) [NSUserDefaults.standardUserDefaults setObject:newBookmark forKey:@"GameFolder"];
                if (root) [self startGame];
                else [self showLaunchError:[NSString stringWithFormat:@"Game files are missing or still copying. Finish copying the game folder into %@ in Files, or choose an existing game folder.", portTitle()]
                    allowFolder:YES];
            });
        }
    });
}
- (void)chooseGame
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    [controller dismissViewControllerAnimated:YES completion:^{ if (url) [self locateGameAndStart:url]; }];
}
- (void)startGame
{
    if (self.started || !self.gameRoot) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *documents = [self documents];
    NSURL *cache = [fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSDictionary *dirs = @{@"PS3_HDD0_ROOT":[documents URLByAppendingPathComponent:@"gamedata/dev_hdd0"],
                          @"PS3_HDD1_ROOT":[cache URLByAppendingPathComponent:@"dev_hdd1"],
                          @"PS3RECOMP_MSL_CACHE":[cache URLByAppendingPathComponent:@"msl-ios"]};
    NSDictionary *config = launchConfiguration();
    if (![config[@"environment"] isKindOfClass:NSDictionary.class]) {
        [self showLaunchError:@"Launch settings are missing. Reinstall the app." allowFolder:NO]; return;
    }
    for (NSString *key in config[@"environment"]) setenv(key.UTF8String, [config[@"environment"][key] UTF8String], 0);
    for (NSString *key in dirs) {
        NSURL *url = dirs[key]; NSError *error = nil;
        if (![fm createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self showLaunchError:error.localizedDescription allowFolder:NO]; return;
        }
        setenv(key.UTF8String, url.fileSystemRepresentation, 1);
    }
    setenv("PS3_VFS_ROOT", self.gameRoot.fileSystemRepresentation, 1);
    if (chdir(documents.fileSystemRepresentation) != 0) {
        [self showLaunchError:@"Cannot open app storage." allowFolder:NO]; return;
    }
    SDL_SetMainReady();
    if (rsx_metal_backend_attach_layer((__bridge void *)self.gameView.layer) != 0) {
        [self showLaunchError:@"Could not attach the Metal display." allowFolder:NO]; return;
    }
#if PORT_IOS_DIAGNOSTICS
    NSURL *offlineLog = MSDiagnosticsStart(documents);
    const char *log = offlineLog ? offlineLog.fileSystemRepresentation : "/dev/null";
#else
    // Normal gameplay has no session logger, sampling timer or growing log file.
    const char *log = "/dev/null";
#endif
    if (freopen(log,"a",stdout)) setvbuf(stdout,nullptr,_IOFBF,64*1024);
    if (freopen(log,"a",stderr)) setvbuf(stderr,nullptr,_IOFBF,16*1024);
    setenv("PORT_BUFFERED_LOG","1",1);
    MSDiagnosticsEvent(@"start", @{});
    self.started = YES;
    self.gameRunning = YES;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    [self.progressTimer invalidate];
    __weak DIRT3Controller *pollTarget = self;
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        DIRT3Controller *controller = pollTarget;
        if (!controller) { [timer invalidate]; return; }
        [controller pollProgress];
    }];
    __weak DIRT3Controller *weakSelf = self;
    rsx_metal_backend_on_first_presented(^{
        DIRT3Controller *controller = weakSelf;
        if (!controller.gameRunning) return;
        MSDiagnosticsEvent(@"first_frame_presented", @{});
        controller.controls.hidden = NO;
    });
    BootArguments *boot = new BootArguments{strdup([self.gameRoot URLByAppendingPathComponent:@"PS3_GAME/USRDIR/EBOOT.elf"].fileSystemRepresentation), (__bridge_retained void *)self};
    pthread_attr_t attr; pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16 * 1024 * 1024);
    pthread_t thread;
    int result = pthread_create(&thread,&attr,runGame,boot);
    pthread_attr_destroy(&attr);
    if (result==0) pthread_detach(thread);
    else { CFBridgingRelease(boot->controller); free(boot->eboot); delete boot; [self gameReturned:result]; }
}
- (void)dealloc { [_scopedURL stopAccessingSecurityScopedResource]; }
- (void)gameReturned:(int)result
{
    self.gameRunning = NO;
    MSDiagnosticsFinish(result);
    self.controls.hidden = YES;
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    [self showLaunchError:[NSString stringWithFormat:@"Game stopped (%d). Close and reopen DiRT 3 to try again.",result] allowFolder:NO];
}
@end

@interface DIRT3SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation DIRT3SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController=[DIRT3Controller new];
    [self.window makeKeyAndVisible];
}
- (void)sceneWillResignActive:(UIScene *)scene
{ port_set_active(0); [(DIRT3Controller *)self.window.rootViewController clearGamepadInputs]; rsx_metal_touch_clear(); MSDiagnosticsSetActive(NO); }
- (void)sceneDidBecomeActive:(UIScene *)scene
{ port_set_active(1); MSDiagnosticsSetActive(YES); }
@end

@interface DIRT3AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation DIRT3AppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *configuration=[[UISceneConfiguration alloc] initWithName:@"DIRT3" sessionRole:session.role];
    configuration.delegateClass=DIRT3SceneDelegate.class;
    return configuration;
}
@end

int main(int argc,char **argv)
{
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(DIRT3AppDelegate.class)); }
}
