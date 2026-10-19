#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

#import "VCPreferences.h"

static const CGFloat VCFloatingControlWidth = 156.0;
static const CGFloat VCFloatingControlHeight = 50.0;
static const CGFloat VCFloatingControlMargin = 10.0;

@interface VCFloatingRootViewController : UIViewController
@end

@implementation VCFloatingRootViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

@end

@interface VCFloatingControlController : NSObject

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, assign) BOOL observingPreferences;

+ (instancetype)sharedController;
- (void)start;
- (void)preferencesDidChange;

@end


static id VCReadFloatingPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFStringRef)VCPreferencesDomain);
    return CFBridgingRelease(value);
}

static BOOL VCReadFloatingBoolean(NSString *key, BOOL defaultValue) {
    id value = VCReadFloatingPreference(key);
    if (![value isKindOfClass:NSNumber.class] &&
        ![value isKindOfClass:NSString.class]) {
        return defaultValue;
    }
    if ([value isKindOfClass:NSString.class] && [value length] > 16) {
        return defaultValue;
    }
    return [value boolValue];
}

static CGFloat VCReadFloatingCoordinate(NSString *key, CGFloat fallback) {
    id value = VCReadFloatingPreference(key);
    if (![value isKindOfClass:NSNumber.class] &&
        ![value isKindOfClass:NSString.class]) {
        return fallback;
    }
    double coordinate = [value doubleValue];
    return isfinite(coordinate) ? (CGFloat)coordinate : fallback;
}

static void VCFloatingPreferencesChanged(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VCFloatingControlController sharedController] preferencesDidChange];
    });
}

@implementation VCFloatingControlController

+ (instancetype)sharedController {
    static VCFloatingControlController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
    });
    return controller;
}

- (void)start {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }

    if (!self.observingPreferences) {
        self.observingPreferences = YES;
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self,
            VCFloatingPreferencesChanged,
            (__bridge CFStringRef)VCPreferencesChangedNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(displayGeometryDidChange:)
                                                   name:UIApplicationDidChangeStatusBarFrameNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(displayGeometryDidChange:)
                                                   name:UIDeviceOrientationDidChangeNotification
                                                 object:nil];
    }

    CFPreferencesAppSynchronize((__bridge CFStringRef)VCPreferencesDomain);
    [VCPreferences.sharedPreferences reload];
    [VCPreferences.sharedPreferences publishSharedConfiguration];
    [self updateVisibilityAndState];
}

- (UIWindowScene *)activeWindowScene API_AVAILABLE(ios(13.0)) {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
        if (!fallback && scene.activationState != UISceneActivationStateUnattached) {
            fallback = windowScene;
        }
    }
    return fallback;
}

- (CGRect)displayBounds {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = self.window.windowScene ?: [self activeWindowScene];
        if (scene.screen) return scene.screen.bounds;
    }
    return UIScreen.mainScreen.bounds;
}

- (CGPoint)clampedCenter:(CGPoint)center {
    CGRect bounds = [self displayBounds];
    CGFloat halfWidth = VCFloatingControlWidth * 0.5;
    CGFloat halfHeight = VCFloatingControlHeight * 0.5;
    CGFloat minimumX = CGRectGetMinX(bounds) + halfWidth + VCFloatingControlMargin;
    CGFloat maximumX = CGRectGetMaxX(bounds) - halfWidth - VCFloatingControlMargin;
    CGFloat minimumY = CGRectGetMinY(bounds) + halfHeight + VCFloatingControlMargin;
    CGFloat maximumY = CGRectGetMaxY(bounds) - halfHeight - VCFloatingControlMargin;
    center.x = MIN(MAX(center.x, minimumX), maximumX);
    center.y = MIN(MAX(center.y, minimumY), maximumY);
    return center;
}

- (void)createWindowIfNeeded {
    if (self.window) return;

    CGRect screenBounds = [self displayBounds];
    CGRect frame = CGRectMake(0.0,
                              0.0,
                              VCFloatingControlWidth,
                              VCFloatingControlHeight);
    UIWindow *window = [[UIWindow alloc] initWithFrame:frame];
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeWindowScene];
        if (scene) window.windowScene = scene;
    }
    window.backgroundColor = UIColor.clearColor;
    window.windowLevel = UIWindowLevelAlert + 1000.0;
    window.clipsToBounds = NO;

    VCFloatingRootViewController *root = [[VCFloatingRootViewController alloc] init];
    root.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = root;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = root.view.bounds;
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                              UIViewAutoresizingFlexibleHeight;
    button.layer.cornerRadius = VCFloatingControlHeight * 0.5;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.34].CGColor;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.75;
    button.accessibilityLabel = @"Alternar cámara virtual";
    [button addTarget:self
               action:@selector(toggleVirtualCamera:)
     forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePan:)];
    pan.maximumNumberOfTouches = 1;
    [button addGestureRecognizer:pan];
    [root.view addSubview:button];

    window.layer.shadowColor = UIColor.blackColor.CGColor;
    window.layer.shadowOpacity = 0.34;
    window.layer.shadowRadius = 8.0;
    window.layer.shadowOffset = CGSizeMake(0.0, 3.0);

    self.window = window;
    self.toggleButton = button;

    CGPoint fallback = CGPointMake(CGRectGetMaxX(screenBounds) -
                                       VCFloatingControlWidth * 0.5 -
                                       VCFloatingControlMargin,
                                   CGRectGetMidY(screenBounds));
    CGPoint saved = CGPointMake(
        VCReadFloatingCoordinate(VCFloatingControlCenterXKey, fallback.x),
        VCReadFloatingCoordinate(VCFloatingControlCenterYKey, fallback.y));
    window.center = [self clampedCenter:saved];
}

- (void)updateButtonForEnabledState:(BOOL)enabled {
    UIColor *color = enabled
        ? [UIColor colorWithRed:0.08 green:0.66 blue:0.34 alpha:0.94]
        : [UIColor colorWithRed:0.78 green:0.16 blue:0.19 alpha:0.94];
    NSString *title = enabled ? @"VCAM\nACTIVA" : @"VCAM\nDESACTIVADA";
    [self.toggleButton setTitle:title forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = color;
    self.toggleButton.accessibilityValue = enabled ? @"Activada" : @"Desactivada";
}

- (void)updateVisibilityAndState {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCPreferencesDomain);
    BOOL controlVisible = VCReadFloatingBoolean(VCFloatingControlEnabledKey, YES);
    if (!controlVisible) {
        self.window.hidden = YES;
        return;
    }

    [self createWindowIfNeeded];
    [self updateButtonForEnabledState:VCReadFloatingBoolean(VCEnabledKey, NO)];
    self.window.hidden = NO;
}

- (void)preferencesDidChange {
    [VCPreferences.sharedPreferences reload];
    [VCPreferences.sharedPreferences publishSharedConfiguration];
    [self updateVisibilityAndState];
}

- (void)toggleVirtualCamera:(UIButton *)sender {
    BOOL oldEnabled = VCReadFloatingBoolean(VCEnabledKey, NO);
    BOOL newEnabled = !oldEnabled;
    CFPreferencesSetAppValue((__bridge CFStringRef)VCEnabledKey,
                             (__bridge CFPropertyListRef)@(newEnabled),
                             (__bridge CFStringRef)VCPreferencesDomain);
    BOOL synchronized = CFPreferencesAppSynchronize(
        (__bridge CFStringRef)VCPreferencesDomain);
    if (!synchronized) {
        [self updateButtonForEnabledState:oldEnabled];
        [sender setTitle:@"VCAM\nERROR" forState:UIControlStateNormal];
        sender.backgroundColor = [UIColor colorWithRed:0.92
                                                 green:0.48
                                                  blue:0.08
                                                 alpha:0.96];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self updateVisibilityAndState];
        });
        return;
    }

    [self updateButtonForEnabledState:newEnabled];
    [VCPreferences.sharedPreferences reload];
    [VCPreferences.sharedPreferences publishSharedConfiguration];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc]
            initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)VCPreferencesChangedNotification,
        NULL,
        NULL,
        YES);
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (!self.window) return;
    CGPoint translation = [gesture translationInView:self.window];
    CGPoint center = self.window.center;
    center.x += translation.x;
    center.y += translation.y;
    self.window.center = [self clampedCenter:center];
    [gesture setTranslation:CGPointZero inView:self.window];

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        CGPoint saved = self.window.center;
        CFPreferencesSetAppValue((__bridge CFStringRef)VCFloatingControlCenterXKey,
                                 (__bridge CFPropertyListRef)@(saved.x),
                                 (__bridge CFStringRef)VCPreferencesDomain);
        CFPreferencesSetAppValue((__bridge CFStringRef)VCFloatingControlCenterYKey,
                                 (__bridge CFPropertyListRef)@(saved.y),
                                 (__bridge CFStringRef)VCPreferencesDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)VCPreferencesDomain);
    }
}

- (void)displayGeometryDidChange:(NSNotification *)notification {
    if (!self.window) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.window.center = [self clampedCenter:self.window.center];
    });
}

@end


%ctor {
    @autoreleasepool {
        NSString *processName = NSProcessInfo.processInfo.processName;
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![processName isEqualToString:@"SpringBoard"] &&
            ![bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [[VCFloatingControlController sharedController] start];
        });
    }
}
