import Foundation

/// The JavaScript Vibe Manager puts in a page (#69).
///
/// Two worlds. The console is caught in the page's own world, where its `console` is — the only
/// choice there is, and the reason a page can write false lines into its own console, which costs
/// nothing. Everything that reads or acts for the agent runs in a world of its own, `vibe-agent`:
/// the page shares the elements with it, and sees neither its code nor its references.
enum PageScripts {
  static let consoleHandlerName = "vibeConsole"
  static let agentWorldName = "vibe-agent"

  static let console = #"""
    (() => {
      if (window.__vibeConsoleInstalled) { return; }
      window.__vibeConsoleInstalled = true;
      const handler = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.vibeConsole;
      if (!handler) { return; }
      const describe = (value) => {
        if (typeof value === 'string') { return value; }
        if (value instanceof Error) { return value.stack || String(value); }
        try { return JSON.stringify(value); } catch (error) { return String(value); }
      };
      const post = (level, values) => {
        try {
          handler.postMessage({ level, text: values.map(describe).join(' ').slice(0, 2000) });
        } catch (error) {}
      };
      for (const level of ['debug', 'log', 'info', 'warn', 'error']) {
        const original = console[level];
        console[level] = function (...values) {
          post(level, values);
          return original.apply(this, values);
        };
      }
      window.addEventListener('error', (event) => {
        const where = event.filename ? ` (${event.filename}:${event.lineno})` : '';
        post('error', [`Uncaught ${event.message}${where}`]);
      });
      window.addEventListener('unhandledrejection', (event) => {
        const reason = event.reason;
        post('error', ['Unhandled rejection: '
          + ((reason && (reason.stack || reason.message)) || String(reason))]);
      });
    })();
    """#

  /// Installed at the start of every document, in the agent's world.
  static let agent = #"""
    window.__vibeAgent = (() => {
      let references = new Map();
      let next = 1;
      const interactiveRoles = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox',
        'radio', 'combobox', 'listbox', 'option', 'tab', 'menuitem', 'switch', 'slider',
        'spinbutton']);
      const clip = (text, limit) => {
        const flat = (text || '').replace(/\s+/g, ' ').trim();
        return flat.length > limit ? flat.slice(0, limit) + '…' : flat;
      };
      const isShown = (element) => {
        const style = getComputedStyle(element);
        if (style.visibility === 'hidden' || style.display === 'none') { return false; }
        const box = element.getBoundingClientRect();
        return box.width > 0 || box.height > 0;
      };
      const isSensitive = (element) => {
        const type = (element.getAttribute('type') || '').toLowerCase();
        const autocomplete = (element.getAttribute('autocomplete') || '').toLowerCase();
        return type === 'password' || /(^|\s)(cc-|one-time-code|current-password|new-password)/
          .test(autocomplete);
      };
      const roleOf = (element) => {
        const explicit = element.getAttribute('role');
        if (explicit) { return explicit.split(' ')[0]; }
        const tag = element.tagName.toLowerCase();
        if (tag === 'a' && element.hasAttribute('href')) { return 'link'; }
        if (tag === 'button' || tag === 'summary') { return 'button'; }
        if (tag === 'select') { return 'combobox'; }
        if (tag === 'textarea') { return 'textbox'; }
        if (/^h[1-6]$/.test(tag)) { return 'heading'; }
        if (tag === 'img') { return 'img'; }
        if (tag === 'input') {
          const type = (element.getAttribute('type') || 'text').toLowerCase();
          if (type === 'hidden') { return null; }
          if (['button', 'submit', 'reset', 'image'].includes(type)) { return 'button'; }
          if (type === 'checkbox' || type === 'radio') { return type; }
          if (type === 'range') { return 'slider'; }
          if (type === 'search') { return 'searchbox'; }
          return 'textbox';
        }
        if (element.isContentEditable && element.getAttribute('contenteditable') !== null) {
          return 'textbox';
        }
        return null;
      };
      const nameOf = (element) => {
        const label = element.getAttribute('aria-label');
        if (label) { return clip(label, 80); }
        const labelledBy = element.getAttribute('aria-labelledby');
        if (labelledBy) {
          const text = labelledBy.split(' ').map((id) => document.getElementById(id))
            .filter(Boolean).map((node) => node.innerText).join(' ');
          if (text.trim()) { return clip(text, 80); }
        }
        if (element.labels && element.labels.length) {
          return clip(Array.from(element.labels).map((node) => node.innerText).join(' '), 80);
        }
        const attribute = element.getAttribute('alt') || element.getAttribute('title')
          || element.getAttribute('placeholder');
        if (attribute) { return clip(attribute, 80); }
        if (element.tagName.toLowerCase() === 'input') {
          return clip(element.value || element.getAttribute('name') || '', 80);
        }
        return clip(element.innerText || element.textContent, 80);
      };
      const describe = (element) => {
        const role = roleOf(element) || element.tagName.toLowerCase();
        const name = nameOf(element);
        return name ? `${role} “${name}”` : role;
      };
      const resolve = (target) => {
        if (target && target.ref) {
          const held = references.get(target.ref);
          const element = held && held.deref();
          if (!element || !element.isConnected) {
            throw new Error(`The reference ${target.ref} is stale: read the page again.`);
          }
          return element;
        }
        if (target && target.selector) {
          const element = document.querySelector(target.selector);
          if (!element) { throw new Error(`Nothing matches ${target.selector}.`); }
          return element;
        }
        throw new Error('Name an element with ref or selector.');
      };
      const highlight = (element) => {
        const box = element.getBoundingClientRect();
        const mark = document.createElement('div');
        mark.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;'
          + 'border:2px solid #0a64d8;border-radius:6px;box-sizing:border-box;'
          + `left:${box.left - 4}px;top:${box.top - 4}px;`
          + `width:${box.width + 8}px;height:${box.height + 8}px;`;
        document.documentElement.appendChild(mark);
        setTimeout(() => mark.remove(), 600);
      };
      const snapshot = (limit) => {
        references = new Map();
        next = 1;
        const lines = [`Page: ${clip(document.title, 200)}`, `Address: ${location.href}`, ''];
        let length = lines.join('\n').length;
        let omitted = 0;
        const walker = document.createTreeWalker(document.body || document.documentElement,
          NodeFilter.SHOW_ELEMENT);
        let element = walker.currentNode;
        while (element) {
          let line = null;
          if (element.nodeType === 1 && isShown(element)) {
            const role = roleOf(element);
            if (role) {
              const reference = `e${next++}`;
              references.set(reference, new WeakRef(element));
              let text = `[${reference}] ${role}`;
              const name = nameOf(element);
              if (name && !(role === 'textbox' && element.tagName.toLowerCase() === 'input'
                && name === element.value)) { text += ` “${name}”`; }
              if (role === 'heading') { text += ` (level ${element.tagName.slice(1)})`; }
              if (role === 'textbox' || role === 'searchbox' || role === 'combobox') {
                const value = element.value !== undefined ? element.value : element.innerText;
                if (value) { text += ` value=“${isSensitive(element) ? '••••••' : clip(value, 80)}”`; }
              }
              if (role === 'checkbox' || role === 'radio') {
                text += element.checked ? ' (checked)' : ' (unchecked)';
              }
              if (element.disabled) { text += ' (disabled)'; }
              line = text;
            } else if (['P', 'LI', 'TD', 'TH', 'LABEL', 'DT', 'DD', 'PRE', 'BLOCKQUOTE',
              'FIGCAPTION', 'CAPTION'].includes(element.tagName)
              || (element.children.length === 0 && element.innerText
                && ['DIV', 'SPAN'].includes(element.tagName))) {
              const own = clip(element.innerText, 200);
              if (own) { line = `text “${own}”`; }
            }
          }
          if (line) {
            if (length + line.length + 1 > limit) { omitted++; } else {
              lines.push(line);
              length += line.length + 1;
            }
          }
          element = walker.nextNode();
        }
        if (omitted > 0) { lines.push(`[truncated: ${omitted} more elements]`); }
        return lines.join('\n');
      };
      const text = (limit) => {
        const body = (document.body && document.body.innerText) || '';
        const header = `Page: ${clip(document.title, 200)}\nAddress: ${location.href}\n\n`;
        const room = Math.max(0, limit - header.length);
        return header + (body.length > room ? body.slice(0, room) + '\n[truncated]' : body);
      };
      const inspect = (target) => {
        const element = resolve(target);
        return { description: describe(element), sensitive: isSensitive(element) };
      };
      const click = (target) => {
        const element = resolve(target);
        element.scrollIntoView({ block: 'center', inline: 'center' });
        highlight(element);
        const options = { bubbles: true, cancelable: true, view: window };
        element.dispatchEvent(new PointerEvent('pointerdown', options));
        element.dispatchEvent(new MouseEvent('mousedown', options));
        element.dispatchEvent(new PointerEvent('pointerup', options));
        element.dispatchEvent(new MouseEvent('mouseup', options));
        element.click();
        return describe(element);
      };
      const fill = (target, value, submit) => {
        const element = resolve(target);
        element.scrollIntoView({ block: 'center', inline: 'center' });
        highlight(element);
        element.focus();
        const tag = element.tagName.toLowerCase();
        if (tag === 'input' || tag === 'textarea') {
          const prototype = tag === 'input' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
          Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, value);
        } else if (tag === 'select') {
          Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set.call(element, value);
        } else if (element.isContentEditable) {
          element.textContent = value;
        } else {
          throw new Error(`${describe(element)} is not a field.`);
        }
        element.dispatchEvent(new Event('input', { bubbles: true }));
        element.dispatchEvent(new Event('change', { bubbles: true }));
        if (submit) {
          const form = element.form || element.closest('form');
          if (form && form.requestSubmit) { form.requestSubmit(); }
          else {
            element.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
          }
        }
        return { description: describe(element), sensitive: isSensitive(element) };
      };
      return { snapshot, text, inspect, click, fill };
    })();
    """#
}
