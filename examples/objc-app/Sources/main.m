#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = @"Objective-C built on Linux";
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
    ]];

    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
