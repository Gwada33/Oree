import WebKit

/// Page-side half of "l'essentiel": reads the page's own structured data (schema.org JSON-LD: recipes, how-tos) and its main
/// text. Own content world, main frame.
@MainActor
enum DigestScript {
    static let world = WKContentWorld.world(name: "oree-digest")

    /// `{jsonld: [string], title, words}`: cheap enough to run on every page load.
    static let probe = """
    const blocks = [...document.querySelectorAll('script[type="application/ld+json"]')].map(s => s.textContent || '').filter(t => t.length < 400000);
    const words = (document.body ? document.body.innerText.length : 0) / 6;
    return { jsonld: blocks, title: document.title, words: Math.round(words) };
    """

    /// The main text of the page, without navigation, forms, ads and scripts: `<article>` or `<main>` when there is one, else the
    /// whole body. One line per block (the innermost one), short lines dropped; the whole visible text when blocks yield little.
    static let text = """
    const SKIP = 'script, style, noscript, nav, header, footer, aside, form, iframe, svg, button, [role="navigation"], [role="banner"], [aria-hidden="true"], .comments, #comments, .advert, .ad, [class*="cookie"], [id*="cookie"], [class*="newsletter"]';
    const BLOCKS = 'h1, h2, h3, h4, p, li, td, th, figcaption, blockquote, dt, dd, pre';
    const root = document.querySelector('article') || document.querySelector('main, [role="main"]') || document.body;
    const lines = [];
    for (const el of root.querySelectorAll(BLOCKS)) {
      if (el.closest(SKIP) || el.querySelector(BLOCKS)) continue;
      const t = (el.innerText || '').replace(/\\s+/g, ' ').trim();
      if (t.length > 2) lines.push(t);
    }
    let text = lines.join('\\n');
    if (text.length < 500) text = (document.body.innerText || '').split('\\n').map(l => l.trim()).filter(l => l.length > 2).join('\\n');
    return { title: document.title, text: text.slice(0, 60000) };
    """
}
