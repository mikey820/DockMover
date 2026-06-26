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
// Gestures (on the dock):
//   • two-finger drag        -> move the dock anywhere on screen (persists)
//   • two-finger triple-tap  -> reset to default position
//
// Single-finger touches are left alone so icon launching / context menus work.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static char kInstalledKey;  // gestures already installed on this container
static char kLiveOffsetKey; // NSValue(CGPoint) offset currently being applied

static NSString *const kSuite = @"com.mikey820.dockmover";
static NSString *const kKeyX  = @"offX";
static NSString *const kKeyY  = @"offY";

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

static CGPoint MKLiveOffset(UIView *container) {
    NSValue *v = objc_getAssociatedObject(container, &kLiveOffsetKey);
    if (v) return [v CGPointValue];
    CGPoint o = MKLoadOffset();
    objc_setAssociatedObject(container, &kLiveOffsetKey, [NSValue valueWithCGPoint:o], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return o;
}
static void MKSetLiveOffset(UIView *container, CGPoint o) {
    objc_setAssociatedObject(container, &kLiveOffsetKey, [NSValue valueWithCGPoint:o], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// Clamp the offset so the platter keeps at least this much on screen.
static CGPoint MKClampOffset(UIView *container, UIView *platter, CGPoint o) {
    UIWindow *win = container.window;
    if (!win) return o;
    // Called before the offset is applied, so this is the un-offset base rect.
    CGRect base = [platter convertRect:platter.bounds toView:win];
    CGRect screen = win.bounds;
    const CGFloat margin = 60.0; // keep at least this many points visible
    CGFloat baseX = base.origin.x;
    CGFloat baseY = base.origin.y;
    CGFloat w = base.size.width, h = base.size.height;
    CGFloat minX = margin - (baseX + w);            // platter right edge >= margin
    CGFloat maxX = (screen.size.width - margin) - baseX; // platter left edge <= screenW - margin
    CGFloat minY = margin - (baseY + h);
    CGFloat maxY = (screen.size.height - margin) - baseY;
    o.x = MAX(minX, MIN(maxX, o.x));
    o.y = MAX(minY, MIN(maxY, o.y));
    return o;
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
    static CGPoint base;
    CGPoint t = [g translationInView:container];
    if (g.state == UIGestureRecognizerStateBegan) {
        base = MKLoadOffset();
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fb prepare]; [fb impactOccurred];
    } else {
        CGPoint o = CGPointMake(base.x + t.x, base.y + t.y);
        MKSetLiveOffset(container, o);
        [container setNeedsLayout];
        [container layoutIfNeeded];
        if (g.state == UIGestureRecognizerStateEnded ||
            g.state == UIGestureRecognizerStateCancelled ||
            g.state == UIGestureRecognizerStateFailed) {
            // persist the clamped value that layout actually settled on
            MKSaveOffset(MKLiveOffset(container));
        }
    }
}
- (void)handleReset:(UITapGestureRecognizer *)g {
    UIView *container = g.view;
    MKSetLiveOffset(container, CGPointZero);
    MKSaveOffset(CGPointZero);
    [UIView animateWithDuration:0.25 animations:^{
        [container setNeedsLayout];
        [container layoutIfNeeded];
    }];
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

%hook SBFloatingDockView

- (void)didMoveToWindow {
    %orig;
    if (self.window) [[MKDockMover shared] install:self];
}

- (void)layoutSubviews {
    %orig; // re-centers the platter at its base position
    UIView *platter = MKFindPlatter(self);
    if (!platter) return;
    CGPoint o = MKClampOffset(self, platter, MKLiveOffset(self));
    MKSetLiveOffset(self, o); // remember the clamped value
    platter.frame = CGRectOffset(platter.frame, o.x, o.y);
}

%end
