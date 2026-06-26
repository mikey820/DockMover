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
// Gestures live on the platter itself (the visible dock) so they travel with
// it — otherwise, once the dock is moved away from the bottom strip, a second
// drag would land on the now-empty container and do nothing.
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

// The container (SBFloatingDockView) is the stable, full-width view that drives
// the platter's layout and our offset. Find it by walking up from the platter.
static UIView *MKContainerOf(UIView *v) {
    Class C = NSClassFromString(@"SBFloatingDockView");
    while (v && C && ![v isKindOfClass:C]) v = v.superview;
    return v;
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
    UIView *container = MKContainerOf(g.view); // g.view is the platter
    if (!container) return;
    static CGPoint base;
    CGPoint t = [g translationInView:container]; // container is stable, doesn't move
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
            MKSaveOffset(MKLiveOffset(container));
        }
    }
}
- (void)handleReset:(UITapGestureRecognizer *)g {
    UIView *container = MKContainerOf(g.view);
    if (!container) return;
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

// The container is only as tall as the bottom dock strip. Once the platter is
// moved out of that strip, the container's default -pointInside: rejects the
// touch and the moved dock becomes untouchable. When the dock is moved, route
// hit-testing to the platter wherever it now is.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *platter = MKFindPlatter(self);
    if (platter) {
        CGPoint o = MKLiveOffset(self);
        if (o.x != 0.0 || o.y != 0.0) {
            CGPoint p = [self convertPoint:point toView:platter];
            if ([platter pointInside:p withEvent:event]) {
                UIView *hit = [platter hitTest:p withEvent:event];
                if (hit) return hit;
            }
        }
    }
    return %orig;
}

- (void)layoutSubviews {
    %orig; // re-centers the platter at its base position
    UIView *platter = MKFindPlatter(self);
    if (!platter) return;
    [[MKDockMover shared] install:platter]; // gestures travel with the visible dock
    CGPoint o = MKLiveOffset(self);
    platter.frame = CGRectOffset(platter.frame, o.x, o.y);
#ifdef DOCKMOVER_VERIFY
    if (platter.bounds.size.width < 100) return; // skip transient zero-size passes
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    // Probe the full hit-test chain as a real touch would: what view resolves
    // at the moved platter's centre?
    if ((o.x != 0.0 || o.y != 0.0) && self.window) {
        CGRect win = [platter convertRect:platter.bounds toView:nil];
        CGPoint c = CGPointMake(CGRectGetMidX(win), CGRectGetMidY(win));
        UIView *hit = [self.window hitTest:c withEvent:nil];
        [d setObject:(hit ? NSStringFromClass([hit class]) : @"nil") forKey:@"hitProbe"];
        [d setObject:NSStringFromCGPoint(c) forKey:@"probePoint"];
    }
    [d setObject:NSStringFromCGRect([platter convertRect:platter.bounds toView:nil]) forKey:@"platterWin"];
    [d synchronize];
#endif
}

%end
