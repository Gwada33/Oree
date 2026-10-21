import WebKit

/// Agrandissement des vidéos en temps réel, dans la page : le script copie chaque image de la vidéo dans une texture WebGL, l'agrandit (bicubique Catmull-Rom, puis netteté adaptative
/// au contraste « CAS » de FidelityFX) et l'affiche dans un canevas posé sur la vidéo. Dans un monde isolé : le site ne voit rien et rien n'est modifié dans sa page, à part ce canevas.
/// Ce n'est pas de l'IA : les contours sont plus nets, aucun détail absent de la source n'est inventé.
@MainActor
enum VideoUpscaleScript {
    /// Le moteur seul (WebGL), sans rien du navigateur : le banc `upscale_check.py` en extrait ce bloc pour mesurer la qualité sur des images de référence.
    static let core = #"""
    // <core>
    function OreeUpscaler(canvas) {
      const gl = canvas.getContext('webgl', { premultipliedAlpha: false, preserveDrawingBuffer: true, antialias: false, alpha: false });
      if (!gl) throw new Error('webgl indisponible');
      const vertex = 'attribute vec2 p; varying vec2 uv; void main(){ uv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }';
      const bilinear = 'precision highp float; varying vec2 uv; uniform sampler2D t; void main(){ gl_FragColor = texture2D(t, vec2(uv.x, 1.0 - uv.y)); }';
      // Catmull-Rom : 16 lectures au centre exact des pixels de la source.
      const bicubic = `precision highp float; varying vec2 uv; uniform sampler2D t; uniform vec2 src;
        vec4 w(float x){ float x2 = x * x, x3 = x2 * x; return vec4(-0.5*x3 + x2 - 0.5*x, 1.5*x3 - 2.5*x2 + 1.0, -1.5*x3 + 2.0*x2 + 0.5*x, 0.5*x3 - 0.5*x2); }
        vec3 at(vec2 i){ return texture2D(t, (clamp(i, vec2(0.0), src - 1.0) + 0.5) / src).rgb; }
        void main(){
          vec2 pos = vec2(uv.x, 1.0 - uv.y) * src - 0.5; vec2 i = floor(pos); vec2 f = pos - i;
          vec4 wx = w(f.x), wy = w(f.y); vec3 c = vec3(0.0);
          for (int y = 0; y < 4; y++) { vec3 row = vec3(0.0); float wyv = y == 0 ? wy.x : (y == 1 ? wy.y : (y == 2 ? wy.z : wy.w));
            for (int x = 0; x < 4; x++) { float wxv = x == 0 ? wx.x : (x == 1 ? wx.y : (x == 2 ? wx.z : wx.w)); row += at(i + vec2(float(x) - 1.0, float(y) - 1.0)) * wxv; }
            c += row * wyv; }
          gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0); }`;
      // CAS (FidelityFX Contrast Adaptive Sharpening) : accentue les contours sans faire sonner les zones déjà contrastées.
      const cas = `precision highp float; varying vec2 uv; uniform sampler2D t; uniform vec2 px; uniform float sharp;
        vec3 s(vec2 o){ return texture2D(t, uv + o * px).rgb; }
        void main(){
          vec3 a = s(vec2(-1.0,-1.0)), b = s(vec2(0.0,-1.0)), c = s(vec2(1.0,-1.0)), d = s(vec2(-1.0,0.0)), e = s(vec2(0.0,0.0)), f = s(vec2(1.0,0.0)), g = s(vec2(-1.0,1.0)), h = s(vec2(0.0,1.0)), i = s(vec2(1.0,1.0));
          vec3 mn = min(min(min(d,e),min(f,b)),h); vec3 mn2 = min(min(min(mn,a),min(c,g)),i); mn = mn + mn2;
          vec3 mx = max(max(max(d,e),max(f,b)),h); vec3 mx2 = max(max(max(mx,a),max(c,g)),i); mx = mx + mx2;
          vec3 amp = clamp(min(mn, 2.0 - mx) / max(mx, vec3(0.0001)), 0.0, 1.0); amp = sqrt(amp);
          float peak = -1.0 / mix(8.0, 5.0, sharp); vec3 wgt = amp * peak; vec3 rcp = 1.0 / (1.0 + 4.0 * wgt);
          gl_FragColor = vec4(clamp(((b + d + f + h) * wgt + e) * rcp, 0.0, 1.0), 1.0); }`;
      function program(fragment) {
        const make = (type, source) => { const shader = gl.createShader(type); gl.shaderSource(shader, source); gl.compileShader(shader);
          if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader)); return shader; };
        const prog = gl.createProgram(); gl.attachShader(prog, make(gl.VERTEX_SHADER, vertex)); gl.attachShader(prog, make(gl.FRAGMENT_SHADER, fragment)); gl.linkProgram(prog);
        if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
        return { prog, loc: (name) => gl.getUniformLocation(prog, name) };
      }
      const programs = { bilinear: program(bilinear), bicubic: program(bicubic), cas: program(cas) };
      const buffer = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buffer); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);
      function texture(linear) { const tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, linear ? gl.LINEAR : gl.NEAREST); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, linear ? gl.LINEAR : gl.NEAREST); return tex; }
      const source = { nearest: texture(false), linear: texture(true) }, mid = texture(false);
      let midSize = [0, 0], framebuffer = gl.createFramebuffer();
      function draw(p, uniforms) {
        gl.useProgram(p.prog); const at = gl.getAttribLocation(p.prog, 'p'); gl.enableVertexAttribArray(at); gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
        for (const [name, apply] of Object.entries(uniforms)) apply(p.loc(name)); gl.drawArrays(gl.TRIANGLES, 0, 3);
      }
      /** `mode` : 'bilinear' (ce que fait le navigateur), 'bicubic', ou 'cas' (bicubique + netteté). La taille de la source est celle de l'image ou de la vidéo. */
      this.render = function (element, srcW, srcH, outW, outH, mode, sharpness) {
        if (canvas.width !== outW || canvas.height !== outH) { canvas.width = outW; canvas.height = outH; }
        gl.viewport(0, 0, outW, outH);
        if (mode === 'bilinear') {
          gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, source.linear);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, element); draw(programs.bilinear, { t: (l) => gl.uniform1i(l, 0) }); return;
        }
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, source.nearest); gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, element);
        if (mode === 'bicubic') {
          gl.bindFramebuffer(gl.FRAMEBUFFER, null);
          draw(programs.bicubic, { t: (l) => gl.uniform1i(l, 0), src: (l) => gl.uniform2f(l, srcW, srcH) }); return;
        }
        if (midSize[0] !== outW || midSize[1] !== outH) { gl.bindTexture(gl.TEXTURE_2D, mid); gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, outW, outH, 0, gl.RGBA, gl.UNSIGNED_BYTE, null); midSize = [outW, outH]; }
        gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer); gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, mid, 0);
        draw(programs.bicubic, { t: (l) => gl.uniform1i(l, 0), src: (l) => gl.uniform2f(l, srcW, srcH) });
        gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.bindTexture(gl.TEXTURE_2D, mid);
        draw(programs.cas, { t: (l) => gl.uniform1i(l, 0), px: (l) => gl.uniform2f(l, 1 / outW, 1 / outH), sharp: (l) => gl.uniform1f(l, sharpness == null ? 0.6 : sharpness) });
      };
    }
    // </core>
    """#

    static let world = WKContentWorld.world(name: "oree-upscale")
    static let handlerName = "oreeUpscale"

    /// Dans toutes les pages et tous leurs cadres (les lecteurs vivent souvent dans une iframe). `auto` : agrandir tout de suite les vidéos éligibles ; sinon le script se contente de les repérer
    /// et la personne en choisit une (clic droit › Améliorer cette vidéo).
    static func makeUserScript(auto: Bool, sharpness: Double) -> WKUserScript {
        // Essais (debug) : la fenêtre d'une instance d'essai n'est pas visible, la page y est « cachée » ; HB_VIDEO_UPSCALE_FORCE lève cette condition.
        var force = false
        #if DEBUG
        force = ProcessInfo.processInfo.environment["HB_VIDEO_UPSCALE_FORCE"] == "1"
        #endif
        return WKUserScript(source: "window.__oreeUpscaleAuto = \(auto); window.__oreeUpscaleSharp = \(sharpness); window.__oreeUpscaleForce = \(force);\n" + core + "\n" + glue, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world)
    }

    /// Le script ne touche à une vidéo que si elle est lue, assez grande, et plus petite que l'espace où elle s'affiche. Une vidéo d'une autre origine sans autorisation (CORS) ou protégée
    /// ne peut pas être lue par WebGL : le navigateur le refuse, le script le constate (SecurityError) et laisse la vidéo telle quelle.
    private static let glue = #"""
    (() => {
      if (window.__oreeUpscale || !/^https?:$/.test(location.protocol)) return;
      const post = (o) => { try { window.webkit.messageHandlers.oreeUpscale.postMessage(JSON.stringify(o)); } catch (_) {} };
      const entries = new WeakMap();           // vidéo → { canvas, upscaler, running, note }
      let last = '';
      function geometry(v) {
        const r = v.getBoundingClientRect(), vw = v.videoWidth, vh = v.videoHeight;
        const fit = getComputedStyle(v).objectFit;
        let w = r.width, h = r.height, x = r.left, y = r.top;
        if (fit !== 'fill') {
          const k = fit === 'cover' ? Math.max(r.width / vw, r.height / vh) : Math.min(r.width / vw, r.height / vh);
          w = vw * k; h = vh * k; x = r.left + (r.width - w) / 2; y = r.top + (r.height - h) / 2;
        }
        return { x, y, w, h, boxW: r.width, boxH: r.height };
      }
      function eligible(v) {
        if (v.paused || v.ended || v.readyState < 2 || !v.videoWidth || (document.hidden && !window.__oreeUpscaleForce)) return false;
        if (v.webkitDisplayingFullscreen || document.fullscreenElement === v) return false;
        const g = geometry(v); const dpr = window.devicePixelRatio || 1;
        return g.boxW >= 320 && g.boxH >= 180 && v.videoWidth * 1.15 < g.w * dpr;
      }
      function stop(v, note) {
        const e = entries.get(v) || {};
        e.running = false; if (e.canvas && e.canvas.parentNode) e.canvas.parentNode.removeChild(e.canvas);
        e.canvas = null; e.note = note || ''; entries.set(v, e);
      }
      function start(v) {
        let e = entries.get(v) || {};
        if (e.running) return;
        try {
          const canvas = document.createElement('canvas'); canvas.setAttribute('data-oree-upscale', '1');
          canvas.style.cssText = 'position:fixed;pointer-events:none;margin:0;padding:0;border:0;background:#000;';
          const up = new OreeUpscaler(canvas);
          // Un premier essai : si la vidéo n'est pas lisible par WebGL (autre origine sans CORS, DRM), on s'arrête avant d'avoir rien affiché.
          up.render(v, v.videoWidth, v.videoHeight, 16, 16, 'bicubic', 0.4);
          v.parentNode.insertBefore(canvas, v.nextSibling);
          e = { canvas, upscaler: up, running: true, note: '', dropped0: (v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality().droppedVideoFrames : 0), total0: (v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality().totalVideoFrames : 0), t0: performance.now() };
          entries.set(v, e);
          const frame = () => {
            const cur = entries.get(v); if (!cur || !cur.running) return;
            if (!v.isConnected || v.ended || !v.videoWidth) { stop(v, 'terminée'); return; }
            if (!v.paused && !(document.hidden && !window.__oreeUpscaleForce) && v.readyState >= 2) {
              const g = geometry(v); const dpr = window.devicePixelRatio || 1;
              let outW = Math.round(g.w * dpr), outH = Math.round(g.h * dpr);
              const cap = Math.min(1, 1920 / outW, 1080 / outH); outW = Math.max(2, Math.round(outW * cap)); outH = Math.max(2, Math.round(outH * cap));
              cur.canvas.style.left = g.x + 'px'; cur.canvas.style.top = g.y + 'px'; cur.canvas.style.width = g.w + 'px'; cur.canvas.style.height = g.h + 'px';
              try { cur.upscaler.render(v, v.videoWidth, v.videoHeight, outW, outH, 'cas', window.__oreeUpscaleSharp); }
              catch (err) { stop(v, 'illisible (' + (err && err.name || 'erreur') + ')'); report(); return; }
              // Si le Mac n'y arrive pas (images perdues), on rend la vidéo telle quelle plutôt que de la saccader.
              if (v.getVideoPlaybackQuality && performance.now() - cur.t0 > 4000) {
                const q = v.getVideoPlaybackQuality(); const total = q.totalVideoFrames - cur.total0, lost = q.droppedVideoFrames - cur.dropped0;
                if (total > 60 && lost / total > 0.12) { stop(v, 'trop lourde pour ce Mac'); report(); return; }
              }
            }
            if (v.requestVideoFrameCallback) v.requestVideoFrameCallback(frame); else requestAnimationFrame(frame);
          };
          if (v.requestVideoFrameCallback) v.requestVideoFrameCallback(frame); else requestAnimationFrame(frame);
        } catch (err) { stop(v, 'illisible (' + (err && err.name || 'erreur') + ')'); }
        report();
      }
      function report() {
        let best = null;
        document.querySelectorAll('video').forEach(v => {
          const e = entries.get(v) || {}; const ok = e.running || eligible(v);
          if (!ok && !e.note) return;
          const g = geometry(v), dpr = window.devicePixelRatio || 1;
          const info = { on: !!e.running, note: e.note || '', vw: v.videoWidth, vh: v.videoHeight, w: Math.round(g.w * dpr), h: Math.round(g.h * dpr) };
          if (!best || (info.on && !best.on) || (!best.on && info.w > best.w)) best = info;
        });
        const text = JSON.stringify(best || { none: true });
        if (text !== last) { last = text; post(best || { none: true }); }
      }
      function scan() {
        if ((document.hidden && !window.__oreeUpscaleForce)) return;
        document.querySelectorAll('video').forEach(v => {
          const e = entries.get(v);
          if (e && e.running) { if (!eligible(v) && (v.paused || !v.videoWidth)) {} return; }
          if (window.__oreeUpscaleAuto && eligible(v) && !(e && e.note)) start(v);
        });
        report();
      }
      setInterval(scan, 1500);
      window.__oreeUpscale = {
        /** Bascule l'agrandissement de la meilleure vidéo du cadre (la plus grande lue). */
        toggle() {
          let pick = null;
          document.querySelectorAll('video').forEach(v => { const e = entries.get(v); if ((e && e.running) || eligible(v)) { const g = geometry(v); if (!pick || g.w > pick.w) pick = { v, w: g.w, running: e && e.running }; } });
          if (!pick) { report(); return 'aucune vidéo'; }
          if (pick.running) { stop(pick.v, 'désactivée par vous'); } else { const e = entries.get(pick.v) || {}; e.note = ''; entries.set(pick.v, e); start(pick.v); }
          report(); return pick.running ? 'off' : 'on';
        },
        status() { last = ''; report(); return last; },
      };
      scan();
    })();
    """#
}

/// Ce que le script voit : la meilleure vidéo du cadre (taille d'origine, taille d'affichage, état) ; `none` quand il n'y en a plus.
struct UpscaleStatus: Equatable {
    var on: Bool, note: String, sourceW: Int, sourceH: Int, shownW: Int, shownH: Int
    init?(json: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], object["none"] == nil else { return nil }
        on = (object["on"] as? Bool) ?? false; note = (object["note"] as? String) ?? ""
        sourceW = (object["vw"] as? Int) ?? 0; sourceH = (object["vh"] as? Int) ?? 0; shownW = (object["w"] as? Int) ?? 0; shownH = (object["h"] as? Int) ?? 0
    }
}

final class VideoUpscaleHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let json = message.body as? String else { return }
        let frame = message.frameInfo
        MainActor.assumeIsolated {
            guard let tab = Tab.tabsByWebView.object(forKey: message.webView) else { return }
            if let status = UpscaleStatus(json: json) { tab.upscaleStatus = status; tab.upscaleFrame = frame }
            else if tab.upscaleFrame?.request.url == frame.request.url { tab.upscaleStatus = nil; tab.upscaleFrame = nil }        // la vidéo de ce cadre n'est plus là
        }
    }
}
