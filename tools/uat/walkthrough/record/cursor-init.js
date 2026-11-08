// Big visible cursor for recordings: a 44px arrow that follows mousemove,
// a ring pulse on mousedown. Injected via addInitScript before any page JS.
(function () {
  function install() {
    if (document.getElementById('rec-cursor')) return;
    const css = document.createElement('style');
    css.id = 'rec-cursor-style';
    css.textContent = `
      html.rec-cursor, html.rec-cursor * { cursor: none !important; }
      #rec-cursor { position: fixed; z-index: 2147483647; pointer-events: none;
        width: 44px; height: 44px; left: 0; top: 0;
        filter: drop-shadow(0 2px 4px rgba(0,0,0,.45)); }
      #rec-ring { position: fixed; z-index: 2147483646; pointer-events: none;
        width: 64px; height: 64px; border-radius: 50%;
        border: 4px solid rgba(94,106,210,.9); left: 0; top: 0;
        transform: translate(-50%,-50%) scale(0); opacity: 0; }
    `;
    document.documentElement.classList.add('rec-cursor');
    document.head.appendChild(css);
    const cur = document.createElement('div');
    cur.id = 'rec-cursor';
    cur.innerHTML = `<svg width="44" height="44" viewBox="0 0 24 24">
      <path d="M5 3 L19 12 L12.5 13.5 L9.5 20 Z" fill="#fff" stroke="#1a1a1a" stroke-width="1.6" stroke-linejoin="round"/></svg>`;
    const ring = document.createElement('div');
    ring.id = 'rec-ring';
    document.body.appendChild(cur);
    document.body.appendChild(ring);
    if (!window.__recCursor) window.__recCursor = { x: innerWidth / 2, y: innerHeight / 2 };
    function place() {
      cur.style.transform = `translate(${window.__recCursor.x - 6}px,${window.__recCursor.y - 2}px)`;
      requestAnimationFrame(place);
    }
    document.addEventListener('mousemove', e => { window.__recCursor.x = e.clientX; window.__recCursor.y = e.clientY; }, true);
    document.addEventListener('mousedown', e => {
      const r = document.getElementById('rec-ring');
      r.style.left = e.clientX + 'px'; r.style.top = e.clientY + 'px';
      r.animate(
        [{ transform: 'translate(-50%,-50%) scale(.15)', opacity: .95 },
         { transform: 'translate(-50%,-50%) scale(1)', opacity: 0 }],
        { duration: 450, easing: 'ease-out' });
    }, true);
    requestAnimationFrame(place);
  }
  if (document.body) install();
  else document.addEventListener('DOMContentLoaded', install);
})();
