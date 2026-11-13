#import <UIKit/UIKit.h>

// The window and the first screen come from Main.storyboard (UIMainStoryboardFile
// in Info.plist); the banner comes from Banner.xib; colors and the app icon come
// from Assets.xcassets. All of them are compiled on Linux by `idl build`.

@interface ViewController : UIViewController
@property(nonatomic, weak) IBOutlet UILabel *label;
@end

@implementation ViewController {
    NSUInteger _taps;
    UIView *_banner;
}

- (IBAction)tapped:(id)sender {
    _taps += 1;
    self.label.text = [NSString stringWithFormat:@"Tapped %lu time%@", (unsigned long)_taps, _taps == 1 ? @"" : @"s"];
    UIColor *accent = [UIColor colorNamed:@"AccentColor"];
    if (accent) self.label.textColor = accent;
    if (_banner) return;
    _banner = [[NSBundle.mainBundle loadNibNamed:@"Banner" owner:nil options:nil] firstObject];
    if (!_banner) return;
    _banner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_banner];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_banner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_banner.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [_banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-20],
        [_banner.heightAnchor constraintEqualToConstant:44],
    ]];
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
