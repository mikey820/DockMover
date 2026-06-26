// DockMover — move the iPad dock around
// Target: rootful iOS 14 iPad SpringBoard. The visible iPad dock is the
// floating dock (SBFloatingDockView). Its position is driven by SpringBoard's
// own layout, which stomps any transform we set — so instead we hook
// -setCenter: and bake our saved offset into the system's own positioning.
// That is self-correcting: every time SpringBoard repositions the dock it
// lands at base + offset.
//
// Gestures (on the dock):
//   • two-finger drag        -> move the dock anywhere on screen (persists)
//   • two-finger triple-tap  -> reset to default position
//
// Single-finger touches are left alone so icon launching / context menus work.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static char kInstalledKey;  // gestures already installed on this view
static char kDragDeltaKey;  // NSValue(CGPoint) live drag delta (transform only)

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

#pragma mark - shared gesture handler (singleton target)

@interface MKDockMover : NSObject
+ (instancetype)shared;
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
    CGPoint base = MKLoadOffset();
    CGPoint t = [g translationInView:v.superview];
    if (g.state == UIGestureRecognizerStateBegan) {
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fb prepare]; [fb impactOccurred];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        // live feedback via transform (cheap, no relayout thrash)
        v.transform = CGAffineTransformMakeTranslation(t.x, t.y);
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        v.transform = CGAffineTransformIdentity;             // drop temp transform
        MKSaveOffset(CGPointMake(base.x + t.x, base.y + t.y)); // commit into persistent offset
        [v.superview setNeedsLayout];                         // force setCenter: to re-run
    }
}
- (void)handleReset:(UITapGestureRecognizer *)g {
    UIView *v = g.view;
    v.transform = CGAffineTransformIdentity;
    MKSaveOffset(CGPointZero);
    [v.superview setNeedsLayout];
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

@interface SBFloatingDockView : UIView
@end

%hook SBFloatingDockView

- (void)setCenter:(CGPoint)center {
    CGPoint o = MKLoadOffset();
    %orig(CGPointMake(center.x + o.x, center.y + o.y));
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [[MKDockMover shared] install:self];
    }
}

- (void)layoutSubviews {
    %orig;
    // ground-truth on-screen position (independent of transform/frame quirks)
    CGRect win = [self convertRect:self.bounds toView:nil];
    MKMark(@"winRect", NSStringFromCGRect(win));
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    [d setInteger:[d integerForKey:@"applyCount"] + 1 forKey:@"applyCount"];
    [d synchronize];
}

%end

%ctor {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    [d setInteger:[d integerForKey:@"loadCount"] + 1 forKey:@"loadCount"];
    [d synchronize];
}
