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
