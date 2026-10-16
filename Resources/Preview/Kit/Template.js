// Draft preview page runtime. PreviewViewController calls these after the template loads
// and on every render; data arguments arrive as encodeURIComponent(JSON) strings.
// katex, SmartTables and diff are loaded alongside this file, so they are only looked up at call time.
window.Template = (() => {
  const root = document.documentElement;
  const decode = (arg) => JSON.parse(decodeURIComponent(arg));

  return {
    // [{id, style}] with CSS text, appended to <head> as <style data-id>.
    insertStylesheets(arg) {
      for (const { id, style } of decode(arg)) {
        const sheet = document.createElement('style');
        sheet.dataset.id = id;
        sheet.textContent = style;
        document.head.appendChild(sheet);
      }
    },

    updateLang(arg) {
      root.lang = decode(arg).join(', ');
    },

    // Plain CSS length. Export strips the html style attribute by matching `style="padding-top: …"`,
    // and the scroll bridge reads the inset back from padding-top.
    updateInset(height) {
      root.style.paddingTop = height;
      root.style.paddingBottom = height;
    },

    // The full class list for <html>; replaces whatever was there.
    updateClass(arg) {
      root.className = decode(arg).join(' ');
    },

    // {key: html} goes into every [data-key] element. diffHTML patches the DOM so
    // unchanged blocks (and the scroll position) survive a re-render.
    updateContent(arg, optionsArg) {
      const options = optionsArg ? decode(optionsArg) : {};
      for (const [key, html] of Object.entries(decode(arg))) {
        for (const el of document.querySelectorAll(`[data-${key}]`)) {
          if (options.useDiffHTML) diff.innerHTML(el, html);
          else el.innerHTML = html;
        }
      }
    },

    // Typesets span.math with KaTeX. The renderer wraps TeX in \(…\) or \[…\];
    // macros are shared so a \gdef in one formula is seen by the ones after it.
    updateMath() {
      const macros = {};
      for (const el of document.body.querySelectorAll('.math')) {
        const text = el.textContent.trim();
        const match = /^\\\(([\s\S]*)\\\)$/.exec(text) || /^\\\[([\s\S]*)\\\]$/.exec(text)
          || /^\$\$([\s\S]*)\$\$$/.exec(text) || /^\$([\s\S]*)\$$/.exec(text);
        const tex = match ? match[1].trim() : '';
        if (!tex) continue;
        const displayMode = text.startsWith('\\[') || text.startsWith('$$');
        katex.render(tex, el, { displayMode, throwOnError: false, trust: true, macros });
        el.lang = 'und-Zmth';
        el.dataset.displayMath = String(displayMode);
      }
    },

    updateSmartTables() {
      document.body.querySelectorAll('table').forEach((table) => SmartTables.processTable(table));
    },
  };
})();
