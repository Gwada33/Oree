#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift ne peut pas attraper une exception Objective-C : WebKit en lève quand on lui parle d'une vue ou d'un cadre qui disparaît au même instant
/// (un onglet qu'on ferme ou endort pendant qu'un script tourne), et l'application s'arrête net. Cette fonction exécute `block` et renvoie
/// `NO` plutôt que de laisser l'exception remonter ; `reason` reçoit son texte (pour le journal).
BOOL OreeTryObjC(NS_NOESCAPE void (^block)(void), NSString *_Nullable *_Nullable reason);

/// Les deux appels qui plantaient : WebKit lève l'exception DEPUIS `evaluateJavaScript` / `callAsyncJavaScript`. Si l'appel est fait par une
/// fermeture Swift passée à `OreeTryObjC`, l'exception traverse cette fermeture avant d'atteindre le `@catch`, et le runtime Swift abandonne
/// (`_swift_exceptionPersonality`, rapports de plantage du 12 octobre). Ici l'appel est fait directement par le `@try`, sans cadre Swift entre les deux.
typedef void (^OreeJSCompletion)(id _Nullable result, NSError *_Nullable error);
BOOL OreeEvaluateJS(WKWebView *webView, NSString *script, WKFrameInfo *_Nullable frame, WKContentWorld *world,
                    OreeJSCompletion completion, NSString *_Nullable *_Nullable reason);
BOOL OreeCallAsyncJS(WKWebView *webView, NSString *body, NSDictionary<NSString *, id> *arguments, WKContentWorld *world,
                     OreeJSCompletion completion, NSString *_Nullable *_Nullable reason);

/// Le panneau de correction orthographique (« Voulez-vous dire… ? ») que WebKit affiche quand on tape dans un champ : AppKit peut y lever une exception
/// qui, faute de gestionnaire, arrête l'application (rapport du 13 octobre, `NSCorrectionPanel showPanelAtRect:` sous `NSPerformVisuallyAtomicChange`).
/// On entoure les deux variantes de `NSSpellChecker showCorrectionIndicator…` d'un `@try` : le panneau ne s'affiche pas, la saisie continue.
/// À appeler une fois, au lancement.
void OreeInstallSpellCheckerGuard(void);

NS_ASSUME_NONNULL_END
