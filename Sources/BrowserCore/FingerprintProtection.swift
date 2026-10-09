import WebKit

/// Reduces what a page can learn about the machine by "farbling" the APIs
/// fingerprinting scripts lean on: canvas readback, audio analysis,
/// WebGL renderer strings, and hardware-capability numbers.
///
/// Noise is seeded per *hostname* (session seed mixed with a hash of
/// `location.hostname`): stable within a site so nothing flickers, different
/// across sites so the noise itself can't be used to link them, and different
/// each session so it can't be used to re-identify you over time.
///
/// Deliberately modest: changes are at the least-significant-bit level
/// (invisible, but enough to change a fingerprint hash). Aggressive spoofing
/// breaks real sites; this is a mitigation, not an anonymity guarantee.
@MainActor
public enum FingerprintProtection {
    public static func makeUserScript(sessionSeed: UInt32 = .random(in: .min ... .max)) -> WKUserScript {
        WKUserScript(
            source: source(sessionSeed: sessionSeed),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    nonisolated public static func source(sessionSeed: UInt32) -> String {
        """
        (function () {
          'use strict';
          function hashString(s) {
            let h = 2166136261 >>> 0;
            for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
            return h >>> 0;
          }
          const siteSeed = (\(sessionSeed) ^ hashString(String(location.hostname))) >>> 0;
          function mulberry32(a) {
            return function () {
              a |= 0; a = a + 0x6D2B79F5 | 0;
              let t = Math.imul(a ^ a >>> 15, 1 | a);
              t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
              return ((t ^ t >>> 14) >>> 0) / 4294967296;
            };
          }
          function attempt(fn) { try { fn(); } catch (e) {} }
          function defineGetter(target, prop, getter) {
            Object.defineProperty(target, prop, { get: getter, configurable: true, enumerable: true });
          }

          // Hardware-capability numbers: report common values instead of the real ones.
          attempt(function () {
            if (typeof Navigator === 'undefined') return;
            defineGetter(Navigator.prototype, 'hardwareConcurrency', function () { return 4; });
            if ('deviceMemory' in Navigator.prototype) {
              defineGetter(Navigator.prototype, 'deviceMemory', function () { return 8; });
            }
          });

          // Canvas: flip the low bit of a sprinkling of pixels on readback.
          function noisify(imageData) {
            const rand = mulberry32((siteSeed ^ (imageData.width * 31 + imageData.height)) >>> 0);
            const d = imageData.data;
            for (let i = 0; i < d.length; i += 4) {
              if (d[i + 3] === 0) continue;
              if (rand() < 0.1) { d[i + ((rand() * 3) | 0)] ^= 1; }
            }
            return imageData;
          }
          attempt(function () {
            if (typeof CanvasRenderingContext2D === 'undefined') return;
            const origGetImageData = CanvasRenderingContext2D.prototype.getImageData;
            CanvasRenderingContext2D.prototype.getImageData = function () {
              const data = origGetImageData.apply(this, arguments);
              attempt(function () { if (data.width * data.height >= 64) noisify(data); });
              return data;
            };

            function noisyCopy(canvas) {
              if (canvas.width * canvas.height < 64) return canvas;
              try {
                const copy = document.createElement('canvas');
                copy.width = canvas.width; copy.height = canvas.height;
                const ctx = copy.getContext('2d');
                if (!ctx) return canvas;
                ctx.drawImage(canvas, 0, 0);
                const img = origGetImageData.call(ctx, 0, 0, copy.width, copy.height);
                ctx.putImageData(noisify(img), 0, 0);
                return copy;
              } catch (e) { return canvas; } // tainted canvas etc.
            }
            if (typeof HTMLCanvasElement !== 'undefined') {
              const origToDataURL = HTMLCanvasElement.prototype.toDataURL;
              HTMLCanvasElement.prototype.toDataURL = function () {
                return origToDataURL.apply(noisyCopy(this), arguments);
              };
              const origToBlob = HTMLCanvasElement.prototype.toBlob;
              HTMLCanvasElement.prototype.toBlob = function () {
                return origToBlob.apply(noisyCopy(this), arguments);
              };
            }
          });

          // WebGL: generic renderer strings.
          function patchGL(proto) {
            if (!proto) return;
            const origGetParameter = proto.getParameter;
            proto.getParameter = function (p) {
              if (p === 0x9245) return 'Apple Inc.';
              if (p === 0x9246) return 'Apple GPU';
              return origGetParameter.apply(this, arguments);
            };
          }
          attempt(function () { if (typeof WebGLRenderingContext !== 'undefined') patchGL(WebGLRenderingContext.prototype); });
          attempt(function () { if (typeof WebGL2RenderingContext !== 'undefined') patchGL(WebGL2RenderingContext.prototype); });

          // Audio: sub-audible noise on the sample/frequency readbacks used to fingerprint the audio stack.
          attempt(function () {
            if (typeof AudioBuffer === 'undefined') return;
            const seen = new WeakSet();
            const origGetChannelData = AudioBuffer.prototype.getChannelData;
            AudioBuffer.prototype.getChannelData = function () {
              const data = origGetChannelData.apply(this, arguments);
              if (!seen.has(data)) {
                seen.add(data);
                attempt(function () {
                  const rand = mulberry32((siteSeed ^ data.length) >>> 0);
                  for (let i = 0; i < data.length; i += 100) { data[i] += (rand() - 0.5) * 1e-7; }
                });
              }
              return data;
            };
          });
          attempt(function () {
            if (typeof AnalyserNode === 'undefined') return;
            const origFloat = AnalyserNode.prototype.getFloatFrequencyData;
            AnalyserNode.prototype.getFloatFrequencyData = function (array) {
              origFloat.apply(this, arguments);
              attempt(function () {
                const rand = mulberry32((siteSeed ^ array.length) >>> 0);
                for (let i = 0; i < array.length; i++) { array[i] += (rand() - 0.5) * 0.1; }
              });
            };
          });
        })();
        """
    }
}

/// Injects per-site cosmetic-filter CSS (element hiding) at document start.
@MainActor
public enum CosmeticScript {
    public static func makeUserScript(css: String) -> WKUserScript? {
        guard !css.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: [css]),
              let encodedArray = String(data: data, encoding: .utf8) else { return nil }
        // JSON-encode the CSS so quotes/newlines/backslashes in selectors can
        // never break out of the string literal.
        let source = """
        (function () {
          const css = \(encodedArray)[0];
          function inject() {
            const style = document.createElement('style');
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          }
          if (document.head || document.documentElement) { inject(); }
          else { document.addEventListener('readystatechange', inject, { once: true }); }
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}
