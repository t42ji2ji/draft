// Draft preview page runtime. PreviewViewController calls these after the template loads
// and on every render; data arguments arrive as encodeURIComponent(JSON) strings.
// katex, SmartTables, pele and diff are loaded alongside this file, so they are only looked up at call time.
window.Template = (() => {
  const root = document.documentElement;
  const decode = (arg) => JSON.parse(decodeURIComponent(arg));
  const diagrams = new WeakMap();   // .mermaid-diagram → Pele's mounted diagram

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

    // ```mermaid blocks, drawn by Pele into a div after the <code>. diffHTML only knows the <code>, so it leaves
    // the diagram alone and removes it with its <pre>. A diagram is redrawn only when its source changed; a source
    // with an error shows Pele's error message instead.
    updateMermaid() {
      for (const box of document.body.querySelectorAll('pre > .mermaid-diagram')) {
        if (!box.previousElementSibling?.matches('code.mermaid')) { diagrams.get(box)?.destroy(); box.remove(); }
      }
      for (const code of document.body.querySelectorAll('pre > code.mermaid')) {
        let box = code.nextElementSibling;
        if (!box) {
          box = document.createElement('div');
          box.className = 'mermaid-diagram';
          code.after(box);
        }
        const text = code.textContent, drawn = diagrams.get(box);
        if (!drawn) diagrams.set(box, pele.mount(box, text, { zoom: false }));
        else if (drawn.source !== text) drawn.update(text);
      }
    },
  };
})();
