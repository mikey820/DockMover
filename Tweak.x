// DockMover — move the iPad dock around
// Target: rootful iOS 14 iPad SpringBoard. On iPad the visible dock is the
// "floating dock" (SBFloatingDockView), not the legacy SBDockView, so the
// movement logic is written class-agnostically and applied to the dock view.
//
// Gestures (on the dock):
//   • two-finger drag        -> move the dock anywhere on screen (persists)
//   • two-finger triple-tap  -> reset to default position
//
// Single-finger touches are left alone so icon launching / context menus work.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static char kInstalledKey;  // gestures already installed on this view
static char kOffsetKey;     // NSValue(CGPoint) live offset for this view

static NSString *const kSuite = @"com.mikey820.dockmover";
static NSString *const kKeyX  = @"offX";
static NSString *const kKeyY  = @"offY";

#pragma mark - persistence + diagnostics

static CGPoint MKLoadOffset(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    return CGPointMake([d doubleForKey:kKeyX], [d doubleForKey:kKeyY]);
}
static void MKSaveOffset(CGPoint p) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    [d setDouble:p.x forKey:kKeyX];
    [d setDouble:p.y forKey:kKeyY];
    [d synchronize];
}
static void MKMark(NSString *key, id value) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    [d setObject:value forKey:key];
    [d synchronize];
}
static void MKBump(NSString *key) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    [d setInteger:[d integerForKey:key] + 1 forKey:key];
    [d synchronize];
}

#pragma mark - per-view offset state

static CGPoint MKViewOffset(UIView *v) {
    NSValue *val = objc_getAssociatedObject(v, &kOffsetKey);
    if (val) return [val CGPointValue];
    CGPoint o = MKLoadOffset();
    objc_setAssociatedObject(v, &kOffsetKey, [NSValue valueWithCGPoint:o], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return o;
}
static void MKSetViewOffset(UIView *v, CGPoint o) {
    objc_setAssociatedObject(v, &kOffsetKey, [NSValue valueWithCGPoint:o], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void MKApply(UIView *v) {
    CGPoint o = MKViewOffset(v);
    v.transform = CGAffineTransformMakeTranslation(o.x, o.y);
}

#pragma mark - shared gesture handler (singleton target)

@interface MKDockMover : NSObject
+ (instancetype)shared;
- (void)handlePan:(UIPanGestureRecognizer *)g;
- (void)handleReset:(UITapGestureRecognizer *)g;
- (void)install:(UIView *)v;
@end

@implementation MKDockMover
+ (instancetype)shared {
    static MKDockMover *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MKDockMover new]; });
    return s;
}
- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    if (!v) return;
    CGPoint start = [objc_getAssociatedObject(g, _cmd) CGPointValue];
    if (g.state == UIGestureRecognizerStateBegan) {
        start = MKViewOffset(v);
        objc_setAssociatedObject(g, _cmd, [NSValue valueWithCGPoint:start], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fb prepare]; [fb impactOccurred];
    } else {
        CGPoint t = [g translationInView:v.superview];
        CGPoint o = CGPointMake(start.x + t.x, start.y + t.y);
        MKSetViewOffset(v, o);
        v.transform = CGAffineTransformMakeTranslation(o.x, o.y);
        if (g.state == UIGestureRecognizerStateEnded ||
            g.state == UIGestureRecognizerStateCancelled ||
            g.state == UIGestureRecognizerStateFailed) {
            MKSaveOffset(o);
        }
    }
}
- (void)handleReset:(UITapGestureRecognizer *)g {
    UIView *v = g.view;
    MKSetViewOffset(v, CGPointZero);
    MKSaveOffset(CGPointZero);
    [UIView animateWithDuration:0.25 animations:^{ v.transform = CGAffineTransformIdentity; }];
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [fb impactOccurred];
}
- (void)install:(UIView *)v {
    if (objc_getAssociatedObject(v, &kInstalledKey)) return;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.minimumNumberOfTouches = 2;
    pan.maximumNumberOfTouches = 2;
    [v addGestureRecognizer:pan];
    UITapGestureRecognizer *reset = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleReset:)];
    reset.numberOfTouchesRequired = 2;
    reset.numberOfTapsRequired = 3;
    [v addGestureRecognizer:reset];
    objc_setAssociatedObject(v, &kInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

#pragma mark - the movable dock: SBFloatingDockView (iPad)

%hook SBFloatingDockView
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [[MKDockMover shared] install:self];
        MKApply(self);
        MKBump(@"floatingInstallCount");
    }
}
- (void)layoutSubviews {
    %orig;
    MKApply(self);
    MKBump(@"floatingApplyCount");
    MKMark(@"floatingFrame", NSStringFromCGRect(self.frame));
}
%end

#pragma mark - diagnostics only (find out which classes are actually live)

%hook SBFloatingDockPlatterView
- (void)layoutSubviews {
    %orig;
    MKBump(@"platterApplyCount");
    MKMark(@"platterFrame", NSStringFromCGRect(self.frame));
}
%end

%hook SBDockView
- (void)layoutSubviews {
    %orig;
    MKBump(@"legacyDockApplyCount");
}
%end

%ctor {
    MKBump(@"loadCount");
    MKMark(@"floatingClassExists",
           NSStringFromClass(NSClassFromString(@"SBFloatingDockView")) ?: @"MISSING");
    MKMark(@"platterClassExists",
           NSStringFromClass(NSClassFromString(@"SBFloatingDockPlatterView")) ?: @"MISSING");
}
