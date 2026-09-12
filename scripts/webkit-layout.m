#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

// Isolated native renderer for the layout regression. No application code lives here.
@interface ResultHandler : NSObject <WKScriptMessageHandler>
@end
@implementation ResultHandler
- (void)userContentController:(WKUserContentController *)controller
     didReceiveScriptMessage:(WKScriptMessage *)message {
    puts([[message.body description] UTF8String]);
    exit(0);
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        WKWebViewConfiguration *config = [WKWebViewConfiguration new];
        config.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        ResultHandler *handler = [ResultHandler new];
        [config.userContentController addScriptMessageHandler:handler name:@"result"];
        NSRect frame = NSMakeRect(0, 0, 1200, 820);
        WKWebView *web = [[WKWebView alloc] initWithFrame:frame configuration:config];
        // A window lets WebKit run its normal animation-frame/layout scheduler.
        NSWindow *host = [[NSWindow alloc] initWithContentRect:frame
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        host.contentView = web;
        [host orderFrontRegardless];
        NSError *error = nil;
        NSString *html = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]
            encoding:NSUTF8StringEncoding error:&error];
        if (!html) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
        [web loadHTMLString:html baseURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fputs("WebKit layout check timed out\n", stderr);
            exit(1);
        });
        [app run];
    }
    return 0;
}
