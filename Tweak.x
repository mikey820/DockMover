// DockMover — move the iPad dock around
// Target: rootful iOS 14 iPad SpringBoard.
//
// The visible iPad dock is the rounded "platter" (SBFloatingDockPlatterView),
// centered inside a full-width container (SBFloatingDockView). SpringBoard
// re-centers the platter on every layout pass and stomps any transform we set,
// so we re-apply our saved offset to the platter at the END of the container's
// -layoutSubviews (after %orig has placed it at its base position). Because we
// always offset from the freshly-computed base, the offset is stable and never
// compounds.
//
// Gestures (on the dock container):
//   • two-finger drag        -> move the dock anywhere on screen (persists)
//   • two-finger triple-tap  -> reset to default position
//
// Single-finger touches are left alone so icon launching / context menus work.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static char kInstalledKey;  // gestures already installed on this view

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

static UIView *MKFindPlatter(UIView *root) {
    Class P = NSClassFromString(@"SBFloatingDockPlatterView");
    if (!P) return nil;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:P]) return sub;
        UIView *found = MKFindPlatter(sub);
        if (found) return found;
    }
    return nil;
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
    UIView *container = g.view;
    if (!container) return;
    UIView *platter = MKFindPlatter(container) ?: container;
    CGPoint base = MKLoadOffset();
    CGPoint t = [g translationInView:container];
    if (g.state == UIGestureRecognizerStateBegan) {
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fb prepare]; [fb impactOccurred];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        platter.transform = CGAffineTransformMakeTranslation(base.x + t.x, base.y + t.y); // live feedback
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        platter.transform = CGAffineTransformIdentity;
        MKSaveOffset(CGPointMake(base.x + t.x, base.y + t.y));
        [container setNeedsLayout];
    }
}
- (void)handleReset:(UITapGestureRecognizer *)g {
    UIView *container = g.view;
    UIView *platter = MKFindPlatter(container) ?: container;
    platter.transform = CGAffineTransformIdentity;
    MKSaveOffset(CGPointZero);
    [container setNeedsLayout];
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

#pragma mark - hooks

@interface SBFloatingDockView : UIView
@end
@interface SBFloatingDockPlatterView : UIView
@end

%hook SBFloatingDockView

- (void)didMoveToWindow {
    %orig;
    if (self.window) [[MKDockMover shared] install:self];
}

- (void)layoutSubviews {
    %orig;
    CGPoint o = MKLoadOffset();
    UIView *platter = MKFindPlatter(self);
    if (platter) {
        // %orig just re-centered the platter to its base; shift it by our offset.
        platter.frame = CGRectOffset(platter.frame, o.x, o.y);
        MKMark(@"platterWin", NSStringFromCGRect([platter convertRect:platter.bounds toView:nil]));
    }
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
