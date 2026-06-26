// DockMover — move the iPad dock around
// Target: rootful iOS 14 iPad SpringBoard (SBDockView).
//
// Gestures (on the dock):
//   • two-finger drag  -> move the dock anywhere on screen (offset persists)
//   • two-finger triple-tap -> reset the dock to its default position
//
// A single-finger touch is left untouched so normal icon launching / context
// menus keep working.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static char kPanKey;     // marks gestures already installed
static char kOffsetKey;  // NSValue(CGPoint) of the live offset

static NSString *const kSuite  = @"com.mikey820.dockmover";
static NSString *const kKeyX   = @"offX";
static NSString *const kKeyY   = @"offY";

static CGPoint MKLoadOffset(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    return CGPointMake([d doubleForKey:kKeyX], [d doubleForKey:kKeyY]);
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

static void MKSaveOffset(CGPoint p) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    [d setDouble:p.x forKey:kKeyX];
    [d setDouble:p.y forKey:kKeyY];
    [d synchronize];
}

@interface SBDockView : UIView
- (CGPoint)mk_offset;
- (void)mk_setOffset:(CGPoint)o;
- (void)mk_applyOffset;
- (void)mk_installGestures;
@end

%hook SBDockView

%new
- (CGPoint)mk_offset {
    NSValue *v = objc_getAssociatedObject(self, &kOffsetKey);
    if (v) return [v CGPointValue];
    CGPoint o = MKLoadOffset();
    objc_setAssociatedObject(self, &kOffsetKey, [NSValue valueWithCGPoint:o], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return o;
}

%new
- (void)mk_setOffset:(CGPoint)o {
    objc_setAssociatedObject(self, &kOffsetKey, [NSValue valueWithCGPoint:o], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)mk_applyOffset {
    CGPoint o = [self mk_offset];
    self.transform = CGAffineTransformMakeTranslation(o.x, o.y);
    MKBump(@"applyCount");
    MKMark(@"lastFrame", NSStringFromCGRect(self.frame));
    MKMark(@"lastApplied", NSStringFromCGPoint(o));
}

%new
- (void)mk_handlePan:(UIPanGestureRecognizer *)g {
    static CGPoint start;
    if (g.state == UIGestureRecognizerStateBegan) {
        start = [self mk_offset];
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fb prepare];
        [fb impactOccurred];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.superview];
        CGPoint o = CGPointMake(start.x + t.x, start.y + t.y);
        [self mk_setOffset:o];
        self.transform = CGAffineTransformMakeTranslation(o.x, o.y);
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        CGPoint t = [g translationInView:self.superview];
        CGPoint o = CGPointMake(start.x + t.x, start.y + t.y);
        [self mk_setOffset:o];
        MKSaveOffset(o);
    }
}

%new
- (void)mk_handleReset:(UITapGestureRecognizer *)g {
    [self mk_setOffset:CGPointZero];
    MKSaveOffset(CGPointZero);
    [UIView animateWithDuration:0.25 animations:^{
        self.transform = CGAffineTransformIdentity;
    }];
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [fb impactOccurred];
}

%new
- (void)mk_installGestures {
    if (objc_getAssociatedObject(self, &kPanKey)) return;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mk_handlePan:)];
    pan.minimumNumberOfTouches = 2;
    pan.maximumNumberOfTouches = 2;
    [self addGestureRecognizer:pan];

    UITapGestureRecognizer *reset = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mk_handleReset:)];
    reset.numberOfTouchesRequired = 2;
    reset.numberOfTapsRequired = 3;
    [self addGestureRecognizer:reset];

    objc_setAssociatedObject(self, &kPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [self mk_installGestures];
        [self mk_applyOffset];
        MKBump(@"gestureInstallCount");
    }
}

- (void)layoutSubviews {
    %orig;
    [self mk_applyOffset];
}

%end

%ctor {
    // Fires whenever this dylib is injected into a process (SpringBoard here).
    // Distinguishes "injected" from "SBDockView hook matched".
    MKBump(@"loadCount");
    MKMark(@"loadedClassExists",
           NSStringFromClass(NSClassFromString(@"SBDockView")) ?: @"MISSING");
}
