import Foundation

/// JavaScript injected into every live wallpaper page (our own "stage" page for videos and
/// pictures, and Wallpaper Engine web wallpapers). It provides:
/// - Wallpaper Engine's hooks: audio listeners get real system-audio levels, and the page gets
///   ordinary mousemove/pointermove events as the cursor moves over the desktop.
/// - The effects engine: particles, cursor glow, visualizer bars, vignette, parallax,
///   bass pulse and colour adjustments.
/// Swift drives it with `__bridgeFrame`, `__bridgeSetEffects`, `__bridgeSetMuted`,
/// `__bridgePause` and (stage page only) `__bridgeSetFit`.
enum WebBridge {
    /// Default values of the wallpaper's user settings from project.json, as JSON.
    static func userProperties(in folder: URL) -> String? {
        let project = WallpaperImporter.readProject(in: folder)
        guard let general = project["general"] as? [String: Any],
              let properties = general["properties"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: properties) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Our page for videos (any format WebKit plays) and still or animated pictures.
    static func stagePage(media relativePath: String, isVideo: Bool, fit: FitSettings) -> String {
        let src = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        let element = isVideo
            ? "<video id=\"m\" src=\"\(src)\" autoplay loop muted playsinline></video>"
            : "<img id=\"m\" src=\"\(src)\" alt=\"\">"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        html, body { margin: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
        #bridge-stage { position: fixed; left: 0; top: 0; width: 100vw; height: 100vh; overflow: hidden; }
        #m { position: absolute; display: block; object-fit: fill; }
        </style></head><body><div id="bridge-stage">\(element)</div>
        <script>
        var fit = \(fit.json);
        var m = document.getElementById('m');
        function layout() {
          var cw = m.videoWidth || m.naturalWidth, ch = m.videoHeight || m.naturalHeight;
          var W = window.innerWidth, H = window.innerHeight;
          if (!cw || !ch || fit.mode === 'stretch') {
            m.style.left = '0px'; m.style.top = '0px';
            m.style.width = W + 'px'; m.style.height = H + 'px';
            m.style.objectFit = (!cw || !ch) ? 'cover' : 'fill';
            return;
          }
          var s;
          if (fit.mode === 'fill') { s = Math.max(W / cw, H / ch); }
          else if (fit.mode === 'fit') { s = Math.min(W / cw, H / ch); }
          else { s = 1 / Math.max(window.devicePixelRatio || 1, 1); }
          s = s * fit.zoom;
          var w = cw * s, h = ch * s;
          m.style.objectFit = 'fill';
          m.style.width = w + 'px'; m.style.height = h + 'px';
          m.style.left = ((W - w) * fit.focusX) + 'px';
          m.style.top = ((H - h) * fit.focusY) + 'px';
        }
        window.__bridgeSetFit = function (f) { fit = f; layout(); };
        m.addEventListener('loadedmetadata', layout);
        m.addEventListener('load', layout);
        window.addEventListener('resize', layout);
        layout();
        if (m.tagName === 'VIDEO' && window.__bridge && !window.__bridge.muted) { m.muted = false; }
        </script>
        </body></html>
        """
    }

    static func script(properties: String?, muted: Bool, effects: EffectSettings) -> String {
        """
        (function () {
          if (window.__bridge) { return; }
          var B = window.__bridge = {
            muted: \(muted),
            paused: false,
            effects: \(effects.json),
            audio: null,
            bass: 0,
            pulse: 0,
            mouse: { x: -9999, y: -9999, inside: false, nx: 0.5, ny: 0.5, sx: 0.5, sy: 0.5 },
            listeners: []
          };

          function post(message) {
            try { window.webkit.messageHandlers.bridge.postMessage(message); } catch (e) {}
          }

          // ---------- Sound on/off ----------
          window.__bridgeSetMuted = function (m) {
            B.muted = m;
            document.querySelectorAll('video, audio').forEach(function (el) { el.muted = m; });
          };
          document.addEventListener('play', function (e) {
            if (B.muted && e.target) { e.target.muted = true; }
          }, true);
          window.__bridgePause = function (p) { B.paused = p; };

          // ---------- Wallpaper Engine hooks ----------
          window.wallpaperRegisterAudioListener = function (callback) {
            if (typeof callback === 'function') { B.listeners.push(callback); post('audio'); }
          };
          var noop = function () {};
          ['wallpaperRegisterMediaStatusListener', 'wallpaperRegisterMediaPropertiesListener',
           'wallpaperRegisterMediaThumbnailListener', 'wallpaperRegisterMediaPlaybackListener',
           'wallpaperRegisterMediaTimelineListener'
          ].forEach(function (name) { if (!window[name]) { window[name] = noop; } });

          var props = \(properties ?? "null");
          window.addEventListener('load', function () {
            setTimeout(function () {
              var listener = window.wallpaperPropertyListener;
              if (!listener) { return; }
              try {
                if (props && typeof listener.applyUserProperties === 'function') { listener.applyUserProperties(props); }
                if (typeof listener.applyGeneralProperties === 'function') { listener.applyGeneralProperties({ fps: 30 }); }
              } catch (err) { console.error(err); }
            }, 0);
          });

          // ---------- Data from the app (about 30 times a second) ----------
          function dispatchMouse(x, y) {
            var target = document.elementFromPoint(x, y) || document.body || document.documentElement;
            if (!target) { return; }
            var init = { clientX: x, clientY: y, screenX: x, screenY: y, bubbles: true, cancelable: true, view: window };
            try { target.dispatchEvent(new MouseEvent('mousemove', init)); } catch (e) {}
            try {
              var pointerInit = Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, init);
              target.dispatchEvent(new PointerEvent('pointermove', pointerInit));
            } catch (e) {}
          }

          window.__bridgeFrame = function (x, y, bands) {
            if (x !== null && y !== null) {
              var m = B.mouse;
              var W = window.innerWidth || 1, H = window.innerHeight || 1;
              var moved = x !== m.x || y !== m.y;
              m.x = x; m.y = y;
              m.inside = x >= 0 && y >= 0 && x < W && y < H;
              m.nx = Math.min(Math.max(x / W, 0), 1);
              m.ny = Math.min(Math.max(y / H, 0), 1);
              if (moved && m.inside) { dispatchMouse(x, y); }
            }
            if (bands) {
              B.audio = bands;
              var bass = 0;
              for (var i = 0; i < 6; i++) { bass += bands[i] + bands[64 + i]; }
              B.bass = bass / 12;
              for (var k = 0; k < B.listeners.length; k++) {
                try { B.listeners[k](bands); } catch (err) {}
              }
            }
          };

          window.__bridgeSetEffects = function (e) {
            B.effects = e;
            ensureOverlay();
            resetParticles();
            applyTarget(true);
            kick();
          };

          // ---------- Effects engine ----------
          var canvas = null, ctx = null, W = 0, H = 0, ratio = 1;
          var parts = [], kind = 'off', lastT = 0, running = false, lastStyle = '';
          var bars = new Array(64).fill(0);
          var COUNTS = { snow: 220, rain: 320, fireflies: 60, petals: 70, bubbles: 60, stars: 240 };

          function needsOverlay() {
            var e = B.effects;
            return e.particles !== 'off' || e.visualizer || e.vignette > 0 || e.cursorGlow;
          }
          function active() {
            var e = B.effects;
            return needsOverlay() || e.parallax > 0 || e.bassPulse > 0 ||
              e.brightness !== 1 || e.saturation !== 1 || e.blur > 0;
          }
          function rand(a, b) { return a + Math.random() * (b - a); }

          function ensureOverlay() {
            var need = needsOverlay();
            if (canvas) { canvas.style.display = need ? 'block' : 'none'; return; }
            if (!need || !document.documentElement) { return; }
            canvas = document.createElement('canvas');
            canvas.setAttribute('data-bridge-overlay', '1');
            canvas.style.cssText = 'position:fixed;left:0;top:0;width:100vw;height:100vh;pointer-events:none;z-index:2147483647;';
            document.documentElement.appendChild(canvas);
            ctx = canvas.getContext('2d');
            resize();
          }

          function resize() {
            if (!canvas) { return; }
            ratio = window.devicePixelRatio || 1;
            W = window.innerWidth; H = window.innerHeight;
            canvas.width = Math.round(W * ratio);
            canvas.height = Math.round(H * ratio);
            ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
            resetParticles();
          }

          function resetParticles() {
            kind = B.effects.particles;
            parts = [];
            if (!canvas || kind === 'off') { return; }
            var n = Math.round((COUNTS[kind] || 100) * Math.max(0.05, B.effects.particleAmount));
            for (var i = 0; i < n; i++) { parts.push(spawn(true)); }
          }

          function spawn(anywhere) {
            var p = { x: rand(0, W), y: anywhere ? rand(0, H) : -20, r: 1, vx: 0, vy: 0, a: 1,
                      rot: rand(0, 6.283), vr: 0, phase: rand(0, 6.283) };
            if (kind === 'snow') { p.r = rand(1, 3.5); p.vy = rand(25, 70); p.vx = rand(-10, 10); p.a = rand(0.5, 0.95); }
            else if (kind === 'rain') { p.x = rand(0, W + 200); p.r = rand(10, 22); p.vy = rand(600, 900); p.vx = -80; p.a = rand(0.15, 0.4); }
            else if (kind === 'fireflies') { p.y = rand(0, H); p.r = rand(1.5, 3); p.vx = rand(-15, 15); p.vy = rand(-15, 15); }
            else if (kind === 'petals') { p.x = rand(-100, W); p.r = rand(4, 8); p.vy = rand(30, 70); p.vx = rand(15, 45); p.vr = rand(-1.5, 1.5); }
            else if (kind === 'bubbles') { p.y = anywhere ? rand(0, H) : H + 20; p.r = rand(3, 12); p.vy = -rand(20, 60); p.vx = rand(-8, 8); p.a = rand(0.2, 0.5); }
            else if (kind === 'stars') { p.y = rand(0, H); p.r = rand(0.5, 1.8); p.a = rand(0.3, 1); }
            return p;
          }

          function alpha(a) { ctx.globalAlpha = Math.min(Math.max(a, 0), 1); }

          function drawOne(p) {
            if (kind === 'snow') {
              alpha(p.a); ctx.fillStyle = '#ffffff';
              ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, 6.283); ctx.fill();
            } else if (kind === 'rain') {
              alpha(p.a); ctx.strokeStyle = '#cfe3ff'; ctx.lineWidth = 1;
              ctx.beginPath(); ctx.moveTo(p.x, p.y); ctx.lineTo(p.x - p.r * 0.1, p.y + p.r); ctx.stroke();
            } else if (kind === 'fireflies') {
              var glow = 0.5 + 0.5 * Math.sin(p.phase * 2);
              var size = p.r * 6;
              var g = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, size);
              g.addColorStop(0, 'rgba(255,240,150,1)');
              g.addColorStop(1, 'rgba(255,200,60,0)');
              alpha(0.25 + 0.75 * glow); ctx.fillStyle = g;
              ctx.beginPath(); ctx.arc(p.x, p.y, size, 0, 6.283); ctx.fill();
            } else if (kind === 'petals') {
              alpha(0.85); ctx.fillStyle = '#ffb7c9';
              ctx.save(); ctx.translate(p.x, p.y); ctx.rotate(p.rot);
              ctx.scale(1, 0.55 + 0.45 * Math.sin(p.phase * 2));
              ctx.beginPath(); ctx.ellipse(0, 0, p.r, p.r * 0.6, 0, 0, 6.283); ctx.fill();
              ctx.restore();
            } else if (kind === 'bubbles') {
              alpha(p.a); ctx.strokeStyle = '#dff6ff'; ctx.lineWidth = 1;
              ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, 6.283); ctx.stroke();
            } else if (kind === 'stars') {
              alpha(p.a * (0.55 + 0.45 * Math.sin(p.phase * 1.7 + p.rot)) * (1 + B.pulse));
              ctx.fillStyle = '#ffffff';
              ctx.beginPath(); ctx.arc(p.x, p.y, p.r * (1 + B.pulse * 0.5), 0, 6.283); ctx.fill();
            }
            ctx.globalAlpha = 1;
          }

          function drawParticles(dt) {
            if (kind === 'off') { return; }
            var m = B.mouse;
            var repel = m.inside && kind !== 'rain' && kind !== 'stars';
            for (var i = 0; i < parts.length; i++) {
              var p = parts[i];
              p.phase += dt;
              if (kind === 'fireflies') {
                p.vx = (p.vx + rand(-20, 20) * dt) * 0.99;
                p.vy = (p.vy + rand(-20, 20) * dt) * 0.99;
              }
              var sway = (kind === 'snow' || kind === 'petals') ? Math.sin(p.phase) * 12 : 0;
              p.x += (p.vx + sway) * dt;
              p.y += p.vy * dt;
              p.rot += p.vr * dt;
              if (repel) {
                var dx = p.x - m.x, dy = p.y - m.y, d2 = dx * dx + dy * dy;
                if (d2 < 14400 && d2 > 0.01) {
                  var d = Math.sqrt(d2), push = (120 - d) / 120 * 300 * dt;
                  p.x += dx / d * push; p.y += dy / d * push;
                }
              }
              if (kind === 'fireflies' || kind === 'stars') {
                if (p.x < -10) { p.x = W + 10; } else if (p.x > W + 10) { p.x = -10; }
                if (p.y < -10) { p.y = H + 10; } else if (p.y > H + 10) { p.y = -10; }
              } else if (p.y > H + 30 || p.y < -40 || p.x < -60 || p.x > W + 260) {
                parts[i] = spawn(false);
                continue;
              }
              drawOne(p);
            }
          }

          function drawGlow() {
            var m = B.mouse, r = 260 * (1 + B.pulse * 0.5);
            var g = ctx.createRadialGradient(m.x, m.y, 0, m.x, m.y, r);
            g.addColorStop(0, 'rgba(255,255,255,0.22)');
            g.addColorStop(1, 'rgba(255,255,255,0)');
            ctx.globalCompositeOperation = 'lighter';
            ctx.fillStyle = g;
            ctx.fillRect(m.x - r, m.y - r, r * 2, r * 2);
            ctx.globalCompositeOperation = 'source-over';
          }

          function drawBars(dt) {
            var a = B.audio, n = 64, gap = 3;
            var bw = (W - gap * (n + 1)) / n, maxH = H * 0.22;
            ctx.fillStyle = '#ffffff';
            alpha(0.55);
            for (var i = 0; i < n; i++) {
              var v = a ? (a[i] + a[64 + i]) / 2 : 0;
              bars[i] = Math.max(v, bars[i] - dt * 1.5);
              var h = Math.max(2, Math.min(bars[i], 1.2) * maxH);
              ctx.fillRect(gap + i * (bw + gap), H - h - 8, bw, h);
            }
            ctx.globalAlpha = 1;
          }

          function drawVignette() {
            var r = Math.sqrt(W * W + H * H) / 2;
            var g = ctx.createRadialGradient(W / 2, H / 2, r * 0.35, W / 2, H / 2, r);
            g.addColorStop(0, 'rgba(0,0,0,0)');
            g.addColorStop(1, 'rgba(0,0,0,' + Math.min(0.95, B.effects.vignette) + ')');
            ctx.fillStyle = g;
            ctx.fillRect(0, 0, W, H);
          }

          // Parallax, bass pulse and colour act on the picture itself: our stage, or the page body.
          function applyTarget(force) {
            var t = document.getElementById('bridge-stage') || document.body;
            if (!t) { return; }
            var e = B.effects, m = B.mouse;
            var shift = e.parallax * 40;
            var scale = 1 + e.parallax * 0.09 + e.bassPulse * B.pulse * 0.15;
            var transform = '', filter = '';
            if (shift > 0 || scale !== 1) {
              transform = 'translate(' + ((0.5 - m.sx) * 2 * shift).toFixed(2) + 'px,' +
                ((0.5 - m.sy) * 2 * shift).toFixed(2) + 'px) scale(' + scale.toFixed(4) + ')';
            }
            if (e.brightness !== 1 || e.saturation !== 1 || e.blur > 0) {
              filter = 'brightness(' + e.brightness + ') saturate(' + e.saturation + ') blur(' + e.blur + 'px)';
            }
            var style = transform + '|' + filter;
            if (style === lastStyle && !force) { return; }
            lastStyle = style;
            t.style.transform = transform;
            t.style.transformOrigin = transform ? (window.innerWidth / 2) + 'px ' + (window.innerHeight / 2) + 'px' : '';
            t.style.filter = filter;
          }

          function tick(time) {
            if (!active()) {
              running = false;
              applyTarget(true);
              if (ctx) { ctx.clearRect(0, 0, W, H); }
              return;
            }
            requestAnimationFrame(tick);
            var dt = lastT ? Math.min((time - lastT) / 1000, 0.05) : 0.016;
            lastT = time;
            var m = B.mouse;
            m.sx += (m.nx - m.sx) * 0.06;
            m.sy += (m.ny - m.sy) * 0.06;
            B.pulse = B.pulse * 0.8 + B.bass * 0.2;
            applyTarget(false);
            if (!canvas || canvas.style.display === 'none') { return; }
            if (B.paused) { dt = 0; }
            ctx.clearRect(0, 0, W, H);
            drawParticles(dt * (1 + B.pulse * 2));
            if (B.effects.cursorGlow && m.inside) { drawGlow(); }
            if (B.effects.visualizer) { drawBars(dt); }
            if (B.effects.vignette > 0) { drawVignette(); }
          }

          function kick() {
            if (running || !active()) { return; }
            running = true;
            lastT = 0;
            requestAnimationFrame(tick);
          }

          function start() {
            ensureOverlay();
            window.addEventListener('resize', resize);
            kick();
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start);
          } else {
            start();
          }
        })();
        """
    }
}
