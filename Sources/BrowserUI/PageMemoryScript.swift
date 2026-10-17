import WebKit

/// Lit le texte principal de la page pour la mémoire ambiante (monde isolé : le site ne voit rien, rien n'est modifié). Renvoie `secret: true` dès qu'un champ de mot de passe
/// ou de carte bancaire existe : la page n'est alors pas gardée.
@MainActor
enum PageMemoryScript {
    static let world = WKContentWorld.world(name: "oree-memory")
    static let source = """
    (function () {
      if (document.querySelector('input[type=password], input[autocomplete^="cc-"], input[name*="card" i], input[name*="cvc" i], input[name*="iban" i]')) return JSON.stringify({ secret: true });
      var main = document.querySelector('article, main, [role=main]') || document.body;
      var text = (main && main.innerText) || '';
      return JSON.stringify({ secret: false, title: document.title || '', text: text.slice(0, 24000) });
    })()
    """
}
