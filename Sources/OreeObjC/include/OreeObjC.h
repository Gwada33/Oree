#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift ne peut pas attraper une exception Objective-C : WebKit en lève quand on lui parle d'une vue ou d'un cadre qui disparaît au même instant
/// (un onglet qu'on ferme ou endort pendant qu'un script tourne), et l'application s'arrête net. Cette fonction exécute `block` et renvoie
/// `NO` plutôt que de laisser l'exception remonter ; `reason` reçoit son texte (pour le journal).
BOOL OreeTryObjC(NS_NOESCAPE void (^block)(void), NSString *_Nullable *_Nullable reason);

NS_ASSUME_NONNULL_END
