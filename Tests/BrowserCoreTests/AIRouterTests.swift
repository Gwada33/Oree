import Foundation
import Testing
@testable import BrowserCore

@Suite("Routage de Luciole")
struct AIRouterTests {
    private func route(_ q: String, page: Bool = true) -> AIRoute { AIRouter.plan(question: q, pageReadable: page).route }

    @Test("une connaissance générale : réponse directe, sans page ni recherche d'office")
    func direct() {
        for q in ["Quelle est la capitale du Portugal ?", "Explique-moi la photosynthèse", "Combien font 12 fois 13 ?", "Écris un court e-mail pour demander un devis", "C'est quoi un trou noir ?"] {
            #expect(route(q) == .direct, "« \(q) »")
        }
        let plan = AIRouter.plan(question: "Quelle est la capitale du Portugal ?", pageReadable: true)
        #expect(!plan.includePage && plan.maxSearches == 1 && plan.tools.contains("done"))
    }

    @Test("une question sur la page : son contenu d'abord")
    func page() {
        for q in ["Résume cette page.", "Quels sont les points clés de cet article ?", "Qui est l'auteur ?", "Traduis ce texte en anglais", "Que dit ce site sur les tarifs ?"] {
            #expect(route(q) == .page, "« \(q) »")
        }
        let plan = AIRouter.plan(question: "Résume cette page.", pageReadable: true)
        #expect(plan.includePage && !plan.tools.contains("read_page") && plan.maxSearches <= 1)
        // Sans page lisible, « cette page » ne peut pas être lue : on ne fait pas semblant.
        #expect(route("Résume cette page.", page: false) == .direct)
    }

    @Test("une information récente ou à vérifier : recherche")
    func web() {
        for q in ["Quel temps fait-il demain à Lyon ?", "Quel est le prix du Bitcoin ?", "Qui a gagné le match hier soir ?", "Dernières nouvelles sur la mission Artemis", "Cherche un restaurant italien à Nantes"] {
            #expect(route(q, page: false) == .web, "« \(q) »")
        }
        let year = Calendar.current.component(.year, from: Date())
        #expect(route("Quels sont les films de \(year) ?", page: false) == .web)
        #expect(AIRouter.plan(question: "Compare les meilleurs casques à réduction de bruit", pageReadable: false).maxSearches == 3)
        #expect(AIRouter.plan(question: "Météo à Lyon", pageReadable: false).maxSearches == 2)
    }

    @Test("agir dans la page : tous les outils, la carte de la page")
    func agent() {
        for q in ["Remplis ce formulaire avec mes informations", "Clique sur le bouton Se connecter", "Ouvre la page des tarifs", "Ajoute au panier le modèle noir"] {
            #expect(route(q) == .agent, "« \(q) »")
        }
        let plan = AIRouter.plan(question: "Remplis ce formulaire", pageReadable: true)
        #expect(plan.includePage && plan.tools.contains("fill_form") && plan.tools.contains("click") && !plan.tools.contains("read_page"))
    }

    @Test("une action l'emporte sur un mot de page : « remplis cette page » agit")
    func priority() {
        #expect(route("Remplis cette page de réservation") == .agent)
        #expect(route("Cherche le prix de ce produit") == .web)
    }

    @Test("une question qui reprend la précédente garde la conversation, une autre non")
    func followUp() {
        #expect(AIRouter.plan(question: "Et à Madrid ?", pageReadable: false, hasConversation: true).keepsConversation)
        #expect(AIRouter.plan(question: "Pourquoi ?", pageReadable: false, hasConversation: true).keepsConversation)
        #expect(AIRouter.plan(question: "Quelle est la capitale de l'Espagne selon l'histoire moderne ?", pageReadable: false, hasConversation: true).keepsConversation)    // une conversation en cours se poursuit
        #expect(!AIRouter.plan(question: "Et à Madrid ?", pageReadable: false, hasConversation: false).keepsConversation)
    }

    @Test("le nombre d'essais suit la route : une question simple n'en mérite pas quinze")
    func steps() {
        #expect(AIRouter.plan(question: "Quelle est la capitale du Portugal ?", pageReadable: false).maxSteps <= 4)
        #expect(AIRouter.plan(question: "Résume cette page", pageReadable: true).maxSteps <= 6)
        #expect(AIRouter.plan(question: "Météo à Lyon", pageReadable: false).maxSteps <= 8)
        #expect(AIRouter.plan(question: "Remplis ce formulaire", pageReadable: true).maxSteps == 15)
    }

    @Test("les accents et les majuscules ne changent rien")
    func folding() {
        #expect(AIRouter.fold("Aujourd’hui À Été") == "aujourd'hui a ete")
        #expect(route("QUEL TEMPS FERA-T-IL DEMAIN ?", page: false) == .web)
    }
}
