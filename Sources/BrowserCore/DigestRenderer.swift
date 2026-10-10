import Foundation

/// Builds the page shown for a digest: plain HTML with inline CSS in the design system's own language (the same variables, fonts and
/// shapes as the start page). It is displayed with JavaScript off, so nothing in it can run; ticking a step off uses a CSS-only checkbox.
public enum DigestRenderer {
    /// What the app hands over from its design tokens (kept as plain strings so this stays free of AppKit).
    public struct Style: Sendable {
        /// `@font-face` rules for the bundled Instrument Sans / Serif.
        public var fontFace: String
        /// `--page:#…;--text:#…;…` for light and for dark appearance.
        public var variables: String
        public var darkVariables: String
        public var radiusSmall: Int, radius: Int, radiusLarge: Int
        public init(fontFace: String, variables: String, darkVariables: String, radiusSmall: Int, radius: Int, radiusLarge: Int) {
            self.fontFace = fontFace; self.variables = variables; self.darkVariables = darkVariables
            self.radiusSmall = radiusSmall; self.radius = radius; self.radiusLarge = radiusLarge
        }
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func kindLabel(_ kind: PageDigest.Kind) -> String {
        switch kind {
        case .recipe: "Recette"
        case .tutorial: "Tutoriel"
        case .review: "Comparatif"
        case .other: "L'essentiel"
        }
    }

    /// A list item with a CSS-only tick box (no JavaScript needed): ticked text goes quiet. `index` marks an ingredient whose text the
    /// servings slider rewrites.
    private static func tick(_ text: String, index: Int? = nil) -> String {
        let mark = index.map { " class=\"t\" data-i=\"\($0)\"" } ?? ""
        return "<li><label><input type=\"checkbox\"><span\(mark)>\(escape(text))</span></label></li>"
    }

    /// JSON for a `<script>`: strings only come from the page, so `<` is written as `\u003c` and nothing can close the tag.
    static func scriptJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// "personnes" for 1 → "personne": the label comes from the page in the plural.
    static func servingsText(_ count: Int, label: String) -> String {
        let word = count == 1 && label.hasSuffix("s") ? String(label.dropLast()) : label
        return "\(count) \(word)"
    }

    /// `cooking` = kitchen mode: much larger text, one column, steps as cards, to read from a distance.
    /// `notice` = a line under the title (for example the model's warning).
    public static func html(_ digest: PageDigest, style: Style, cooking: Bool, notice: String?) -> String {
        var body = "<header><span class=\"kind\">\(kindLabel(digest.kind))</span><h1>\(escape(digest.title))</h1>"
        // A recipe's description is shop-window text that repeats the title and the times: not the point.
        if let summary = digest.summary, !cooking, digest.kind != .recipe { body += "<p class=\"summary\">\(escape(summary))</p>" }
        if !digest.times.isEmpty { body += "<p class=\"chips\">" + digest.times.map { "<span class=\"chip\">\(escape($0))</span>" }.joined() + "</p>" }
        if let notice { body += "<p class=\"note\">\(escape(notice))</p>" }
        body += "</header>"
        var script = ""
        if !digest.ingredients.isEmpty {
            var control = ""
            let scalable = digest.servings != nil && IngredientScaler.hasScalableLine(digest.ingredients)
            if scalable, let base = digest.servings {
                let maximum = min(max(12, base * 3), 60)
                let label = digest.servingsLabel ?? "personnes"
                control = """
                <div class="servings"><span class="who" id="who">\(escape(servingsText(base, label: label)))</span>
                <button class="step" type="button" data-d="-1" aria-label="Moins">−</button>
                <input id="sv" type="range" min="1" max="\(maximum)" value="\(min(base, maximum))" aria-label="Nombre de personnes">
                <button class="step" type="button" data-d="1" aria-label="Plus">+</button></div>
                """
                script = """
                <script>(function(){var T=\(scriptJSON(IngredientScaler.table(for: digest.ingredients, base: base, maximum: maximum)));var L=\(scriptJSON(label));
                var sv=document.getElementById('sv'),who=document.getElementById('who'),items=document.querySelectorAll('.t[data-i]');
                function set(n){n=Math.max(+sv.min,Math.min(+sv.max,n));sv.value=n;who.textContent=n+' '+(n===1&&/s$/.test(L)?L.slice(0,-1):L);
                  for(var i=0;i<items.length;i++){items[i].textContent=T[n-1][+items[i].getAttribute('data-i')];}}
                sv.addEventListener('input',function(){set(+sv.value)});
                document.querySelectorAll('.step').forEach(function(b){b.addEventListener('click',function(){set(+sv.value+ +b.getAttribute('data-d'))})});})();</script>
                """
            }
            let items = digest.ingredients.enumerated().map { tick($1, index: scalable ? $0 : nil) }.joined()
            body += "<section><h2>\(digest.kind == .recipe ? "Ingrédients" : "Matériel")</h2>\(control)<ul class=\"rows\">\(items)</ul></section>"
        }
        if !digest.steps.isEmpty {
            body += "<section><h2>Étapes</h2><ol class=\"steps\">" + digest.steps.map { tick($0) }.joined() + "</ol></section>"
        }
        if let verdict = digest.verdict, !verdict.isEmpty { body += "<section><h2>Verdict</h2><p class=\"verdict\">\(escape(verdict))</p></section>" }
        if !digest.pros.isEmpty { body += "<section><h2>Points forts</h2><ul class=\"rows pros\">" + digest.pros.map { "<li><span>\(escape($0))</span></li>" }.joined() + "</ul></section>" }
        if !digest.cons.isEmpty { body += "<section><h2>Points faibles</h2><ul class=\"rows cons\">" + digest.cons.map { "<li><span>\(escape($0))</span></li>" }.joined() + "</ul></section>" }

        let size = cooking ? 28 : 16
        return """
        <!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src oree:; script-src 'unsafe-inline'">
        <style>
        \(style.fontFace)
        :root{\(style.variables)--sans:"Instrument Sans",-apple-system,"SF Pro Text",sans-serif;--serif:"Instrument Serif",Georgia,serif;
          --r:\(style.radius)px;--r-sm:\(style.radiusSmall)px;--r-lg:\(style.radiusLarge)px;
          --s2:0 2px 10px -2px rgba(30,25,15,.14),0 1px 2px rgba(30,25,15,.08);color-scheme:light dark}
        @media (prefers-color-scheme: dark){:root{\(style.darkVariables)--s2:0 2px 10px -2px rgba(0,0,0,.5),0 1px 2px rgba(0,0,0,.3)}}
        *{box-sizing:border-box}
        body{margin:0;background:var(--page);color:var(--text);font:400 \(size)px/1.5 var(--sans)}
        main{max-width:\(cooking ? 1040 : 700)px;margin:0 auto;padding:\(cooking ? 48 : 56)px clamp(20px,5vw,56px) 96px;display:flex;flex-direction:column;gap:\(cooking ? 44 : 34)px}
        header{display:flex;flex-direction:column;gap:\(cooking ? 14 : 8)px}
        .kind{font-size:\(cooking ? 18 : 13)px;font-weight:600;color:var(--muted)}
        h1{margin:0;font:italic 400 \(cooking ? 76 : 54)px/.98 var(--serif);letter-spacing:-.015em}
        h2{margin:0 0 \(cooking ? 10 : 4)px;padding:0 6px;font-size:\(cooking ? 18 : 13)px;font-weight:600;color:var(--muted)}
        .summary{margin:4px 0 0;color:var(--muted);font-size:\(size)px}
        .chips{display:flex;flex-wrap:wrap;gap:8px;margin:\(cooking ? 8 : 6)px 0 0}
        .chip{font-size:\(cooking ? 20 : 12)px;font-weight:500;padding:\(cooking ? 7 : 5)px \(cooking ? 14 : 9)px;border-radius:999px;background:var(--hover);color:var(--muted)}
        .note{margin:\(cooking ? 10 : 6)px 0 0;padding:8px 12px;border-radius:var(--r-sm);background:var(--h-soft);color:var(--h-ink);font-size:\(cooking ? 18 : 12.5)px;font-weight:500;align-self:flex-start}
        section{display:flex;flex-direction:column}
        ul,ol{list-style:none;margin:0;padding:0}
        .servings{display:flex;align-items:center;gap:\(cooking ? 16 : 10)px;margin:2px 6px \(cooking ? 18 : 10)px}
        .who{min-width:\(cooking ? 190 : 108)px;font-size:\(cooking ? 24 : 14)px;font-weight:600;color:var(--h-ink)}
        .step{appearance:none;-webkit-appearance:none;width:\(cooking ? 46 : 28)px;height:\(cooking ? 46 : 28)px;border:0;border-radius:999px;background:var(--hover);color:var(--text);font:600 \(cooking ? 26 : 16)px/1 var(--sans);cursor:pointer;transition:background .12s}
        .step:hover{background:var(--press,var(--hover))}
        input[type=range]{flex:1;max-width:\(cooking ? 420 : 260)px;accent-color:var(--h)}
        .rows li,.steps li{border-top:1px solid var(--line)}
        .rows li:last-child,.steps li:last-child{border-bottom:1px solid var(--line)}
        label{display:flex;gap:\(cooking ? 18 : 12)px;align-items:baseline;padding:\(cooking ? 18 : 9)px 6px;cursor:pointer;border-radius:var(--r-sm);transition:background .12s cubic-bezier(.2,.8,.2,1)}
        label:hover{background:var(--hover)}
        input[type=checkbox]{appearance:none;-webkit-appearance:none;flex:none;width:\(cooking ? 26 : 16)px;height:\(cooking ? 26 : 16)px;margin:0;border:1.5px solid var(--muted);border-radius:\(cooking ? 8 : 5)px;
          position:relative;top:\(cooking ? 3 : 2)px;background:transparent;transition:background .12s,border-color .12s}
        input[type=checkbox]:checked{background:var(--h);border-color:var(--h)}
        input[type=checkbox]:checked::after{content:"";position:absolute;left:\(cooking ? 8 : 4.5)px;top:\(cooking ? 3 : 1)px;width:\(cooking ? 7 : 4)px;height:\(cooking ? 13 : 8)px;border:solid var(--on);border-width:0 2px 2px 0;transform:rotate(45deg)}
        input[type=checkbox]:checked+span{color:var(--muted);text-decoration:line-through;text-decoration-color:var(--line)}
        input:focus-visible{outline:2px solid var(--h);outline-offset:2px}
        .steps{counter-reset:step}
        .steps li{counter-increment:step}
        .steps label::before{content:counter(step);font:italic 400 \(cooking ? 40 : 22)px/1 var(--serif);color:var(--h-ink);min-width:\(cooking ? 36 : 22)px;text-align:right;order:-1}
        \(cooking ? ".steps li{border:0;margin-top:14px}.steps label{background:var(--raised);box-shadow:var(--s2);border-radius:var(--r-lg);padding:26px 28px}.rows li:last-child,.steps li:last-child{border-bottom:0}" : "")
        .verdict{margin:0;padding:\(cooking ? 24 : 16)px \(cooking ? 28 : 20)px;border-radius:var(--r-lg);background:var(--raised);box-shadow:var(--s2);font-size:\(Int(Double(size) * 1.1))px}
        .pros li,.cons li{display:flex;gap:12px;align-items:baseline;padding:\(cooking ? 16 : 8)px 6px}
        .pros li::before{content:"";width:8px;height:8px;border-radius:50%;background:var(--h);flex:none;position:relative;top:-1px}
        .cons li::before{content:"";width:8px;height:2px;background:var(--muted);flex:none;position:relative;top:-4px}
        @media (prefers-reduced-motion:reduce){*{transition:none!important}}
        </style></head><body><main>\(body)</main>\(script)</body></html>
        """
    }
}
