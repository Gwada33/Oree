import WebKit

/// Page-side half of the "now playing" card: reports what the page is playing and carries out the card's commands.
///
/// It looks at the `<video>` / `<audio>` elements of the main frame (a player inside an iframe is not seen), prefers the one that plays,
/// then the longest, and reads the title, artist and cover from the page's Media Session when it gives them. The report goes out on
/// every state change and, while something plays, at most once a second for the position. Own content world; the page cannot see it.
@MainActor
enum MediaScript {
    static let world = WKContentWorld.world(name: "oree-media")
    static let handlerName = "oreeMedia"

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    /// `play`, `pause`, `toggle`, `seek` (seconds), `skip` (± seconds), `rate` (speed), `pip` (enter or leave picture in picture), `report` (answer now).
    static func commandCall(_ name: String, value: Double = 0) -> (body: String, arguments: [String: Any]) {
        ("return window.__oreeMedia ? window.__oreeMedia.command(name, value) : 'no-script';", ["name": name, "value": value])
    }

    private static let source = #"""
    (() => {
      if (!/^https?:$/.test(location.protocol) || window.__oreeMedia) return;
      let sent = '', lastTime = 0, poll = 0;
      const send = o => {
        const text = JSON.stringify(o);
        if (text === sent) return;
        sent = text;
        try { o.u = location.href; window.webkit.messageHandlers.oreeMedia.postMessage(JSON.stringify(o)); } catch (_) {}
      };
      const pick = () => {
        const all = [...document.querySelectorAll('video,audio')].filter(e => e.readyState > 0 || !e.paused);
        all.sort((a, b) => (Number(a.paused) - Number(b.paused)) || ((b.duration || 0) - (a.duration || 0)));
        return all[0] || null;
      };
      const inPiP = v => document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture';
      function report() {
        const v = pick();
        // Poll (for a title or cover the page sets later) only while something is there: no timer on a page that plays nothing.
        if (!v) { if (poll) { clearInterval(poll); poll = 0; } send({ none: true }); return; }
        if (!poll) poll = setInterval(report, 2500);
        const md = (navigator.mediaSession && navigator.mediaSession.metadata) || null;
        const art = md && md.artwork && md.artwork.length ? md.artwork[md.artwork.length - 1].src : '';
        send({
          title: (md && md.title) || document.title || '', artist: (md && md.artist) || '', artwork: art,
          position: Math.floor(v.currentTime), duration: isFinite(v.duration) ? Math.floor(v.duration) : 0,
          paused: v.paused || v.ended, video: v.tagName === 'VIDEO' && v.videoWidth > 0, pip: inPiP(v), rate: v.playbackRate,
        });
      }
      // Media events do not bubble: listen in the capture phase on the document.
      for (const type of ['play', 'playing', 'pause', 'ended', 'seeked', 'loadedmetadata', 'durationchange', 'emptied', 'enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged', 'ratechange'])
        document.addEventListener(type, report, true);
      document.addEventListener('timeupdate', () => {
        const now = Date.now();
        if (now - lastTime < 1000) return;
        lastTime = now; report();
      }, true);
      addEventListener('pagehide', () => { clearInterval(poll); poll = 0; send({ none: true }); });

      window.__oreeMedia = {
        command(name, value) {
          const v = pick() || document.querySelector('video,audio');
          if (!v) return 'no-media';
          switch (name) {
            case 'play': v.play(); break;
            case 'pause': v.pause(); break;
            case 'toggle': v.paused ? v.play() : v.pause(); break;
            case 'seek': if (isFinite(v.duration)) v.currentTime = Math.max(0, Math.min(value, v.duration)); break;
            case 'skip': v.currentTime = Math.max(0, v.currentTime + value); break;
            case 'rate': v.playbackRate = Math.max(0.0625, Math.min(16, value)); break;
            case 'pip':
              if (inPiP(v)) { if (document.exitPictureInPicture && document.pictureInPictureElement) document.exitPictureInPicture(); else v.webkitSetPresentationMode('inline'); }
              else if (v.requestPictureInPicture) v.requestPictureInPicture().catch(e => { try { v.webkitSetPresentationMode('picture-in-picture'); } catch (_) {} });
              else if (v.webkitSetPresentationMode) v.webkitSetPresentationMode('picture-in-picture');
              break;
          }
          setTimeout(report, 50);
          return 'ok';
        },
      };
      report();
    })();
    """#
}

/// Receives the media script's reports and hands them to the window.
final class MediaMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let json = message.body as? String else { return }
        MainActor.assumeIsolated { if let tab = Tab.tabsByWebView.object(forKey: message.webView) { tab.owner?.handleMedia(tab: tab, json: json) } }
    }
}
