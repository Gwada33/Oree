#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "OreeObjC.h"

BOOL OreeTryObjC(NS_NOESCAPE void (^block)(void), NSString *_Nullable *_Nullable reason) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (reason) { *reason = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]; }
        return NO;
    }
}

BOOL OreeEvaluateJS(WKWebView *webView, NSString *script, WKFrameInfo *frame, WKContentWorld *world,
                    OreeJSCompletion completion, NSString **reason) {
    @try {
        [webView evaluateJavaScript:script inFrame:frame inContentWorld:world completionHandler:completion];
        return YES;
    } @catch (NSException *exception) {
        if (reason) { *reason = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]; }
        return NO;
    }
}

BOOL OreeCallAsyncJS(WKWebView *webView, NSString *body, NSDictionary<NSString *, id> *arguments, WKContentWorld *world,
                     OreeJSCompletion completion, NSString **reason) {
    @try {
        [webView callAsyncJavaScript:body arguments:arguments inFrame:nil inContentWorld:world completionHandler:completion];
        return YES;
    } @catch (NSException *exception) {
        if (reason) { *reason = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]; }
        return NO;
    }
}

// MARK: Correction panel guard

typedef void (*OreeIndicator)(id, SEL, NSInteger, NSString *, NSArray *, NSRect, NSView *, id);
typedef void (*OreeIndicatorRange)(id, SEL, NSInteger, NSRange, NSString *, NSArray *, NSRect, NSView *, id);

void OreeInstallSpellCheckerGuard(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSSpellChecker.class;
        SEL plain = NSSelectorFromString(@"showCorrectionIndicatorOfType:primaryString:alternativeStrings:forStringInRect:view:completionHandler:");
        SEL ranged = NSSelectorFromString(@"showCorrectionIndicatorOfType:range:primaryString:alternativeStrings:forStringInRect:view:completionHandler:");

        Method plainMethod = class_getInstanceMethod(cls, plain);
        if (plainMethod) {
            OreeIndicator original = (OreeIndicator)method_getImplementation(plainMethod);
            method_setImplementation(plainMethod, imp_implementationWithBlock(^(id me, NSInteger type, NSString *primary, NSArray *alternatives, NSRect rect, NSView *view, id completion) {
                @try { original(me, plain, type, primary, alternatives, rect, view, completion); }
                @catch (NSException *exception) {
                    NSLog(@"Orée: correction panel refused (%@: %@)", exception.name, exception.reason);
                    if (completion) { ((void (^)(NSString *))completion)(nil); }
                }
            }));
        }
        Method rangedMethod = class_getInstanceMethod(cls, ranged);
        if (rangedMethod) {
            OreeIndicatorRange original = (OreeIndicatorRange)method_getImplementation(rangedMethod);
            method_setImplementation(rangedMethod, imp_implementationWithBlock(^(id me, NSInteger type, NSRange range, NSString *primary, NSArray *alternatives, NSRect rect, NSView *view, id completion) {
                @try { original(me, ranged, type, range, primary, alternatives, rect, view, completion); }
                @catch (NSException *exception) {
                    NSLog(@"Orée: correction panel refused (%@: %@)", exception.name, exception.reason);
                    if (completion) { ((void (^)(NSString *))completion)(nil); }
                }
            }));
        }
    });
}
