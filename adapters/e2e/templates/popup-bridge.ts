// sdlc-kit adapter template — popup bridge.
// e2e does not follow windows the app opens. This init script turns window.open into a
// full-viewport iframe in the same tab, with no app change, so popup flows stay testable.
//
// Top window:
//   - window.open(url, name, features) makes (or reuses, by name) a full-viewport iframe
//     and returns its contentWindow; '_self' | '_parent' | '_top' go to the native open;
//     '' | '_blank' always make a new iframe.
// Inside a bridge iframe:
//   - window.opener is the window that opened it; window.close() removes the iframe
//     (the opener's reference then reports closed === true); window.focus() raises it;
//     window.open() opens a nested bridge popup.
// Other iframes the app uses are left alone.
//
// Works for same-origin popups that talk through opener, postMessage, window.name and
// .closed. Not covered: cross-origin popups (frameElement is unreadable, and the server
// may forbid framing), <a target="_blank"> and form targets (no window.open), noopener.
// Differences from a real popup: sessionStorage is shared, not copied; size features are
// ignored; window.top is the app window; the app window gets no blur/visibilitychange;
// the popup covers the app until it closes.
//
// Use:
//   await installPopupBridge(browser);                        // before app.open
//   browser.frameLocator(popupFrameSelector('name'))          // assert inside the popup
//   await browser.evaluate(listPopups)                        // open popups
// toBeVisible passes on an element with opacity 0: assert something that proves the
// popup painted (an image loaded, computed opacity) before trusting a screenshot.

/** Self-contained: browser.addInitScript serializes it into every document, frames included. No outside references. */
export function popupBridgeInit(): void {
  const W = window as unknown as Record<string, any>;
  if (W.__popupBridgeInstalled) return;
  W.__popupBridgeInstalled = true;
  const ATTR = 'data-popup-bridge';

  if (window === window.top) {
    const nativeOpen = window.open.bind(window);
    const frames = new Map<string, HTMLIFrameElement>();
    const openers = new Map<HTMLIFrameElement, Window>();
    let seq = 0;
    let z = 2147480000;
    const frameOf = (win: unknown) => {
      for (const f of frames.values()) if (f.contentWindow === win) return f;
      return null;
    };
    const raise = (f: HTMLIFrameElement) => {
      f.style.zIndex = String(++z);
    };
    const api = {
      open(url: string, name: string | undefined, features: string | undefined, opener: Window): Window | null {
        const target = name ?? '';
        if (target === '_self' || target === '_parent' || target === '_top') return nativeOpen(url, target, features);
        const anonymous = target === '' || target === '_blank';
        const key = anonymous ? `__anonymous_${++seq}` : target;
        const href = url ? new URL(url, location.href).href : '';
        let f = frames.get(key);
        if (f && f.isConnected) {
          if (href) f.src = href;
        } else {
          f = document.createElement('iframe');
          if (!anonymous) f.name = target;
          f.setAttribute(ATTR, key);
          f.setAttribute('title', `popup ${key}`);
          if (features) f.setAttribute('data-popup-features', features);
          f.style.cssText = 'position:fixed;inset:0;width:100vw;height:100vh;border:0;margin:0;padding:0;background:#fff;';
          f.src = href || 'about:blank';
          (document.body ?? document.documentElement).appendChild(f);
          frames.set(key, f);
        }
        openers.set(f, opener);
        raise(f);
        return f.contentWindow;
      },
      close(win: Window): void {
        for (const [k, f] of frames) {
          if (f.contentWindow === win) {
            frames.delete(k);
            openers.delete(f);
            f.remove();
          }
        }
      },
      focus(win: Window): void {
        const f = frameOf(win);
        if (f) raise(f);
      },
      openerOf(win: Window): Window | null {
        const f = frameOf(win);
        return f ? (openers.get(f) ?? window) : null;
      },
      list(): { key: string; name: string; src: string; url: string; z: string }[] {
        return [...frames].map(([key, f]) => {
          let url = '';
          try {
            url = f.contentWindow?.location.href ?? '';
          } catch {
            url = '(cross-origin)';
          }
          return { key, name: f.name, src: f.src, url, z: f.style.zIndex };
        });
      },
    };
    W.__popupBridge = api;
    window.open = function (url?: string | URL, name?: string, features?: string) {
      return api.open(url == null ? '' : String(url), name, features, window);
    } as typeof window.open;
    return;
  }

  // Child document: act only inside an iframe the bridge made (frameElement is readable only same-origin).
  let host: Element | null = null;
  try {
    host = window.frameElement;
  } catch {
    host = null;
  }
  if (!host || !host.hasAttribute(ATTR)) return;
  const api = (window.top as unknown as Record<string, any>).__popupBridge;
  if (!api) return;
  Object.defineProperty(window, 'opener', { configurable: true, get: () => api.openerOf(window), set: () => undefined });
  window.close = () => api.close(window);
  window.focus = () => api.focus(window);
  window.open = function (url?: string | URL, name?: string, features?: string) {
    return api.open(url == null ? '' : String(url), name, features, window);
  } as typeof window.open;
}

type InitScriptHost = { addInitScript(script: () => unknown): Promise<void> };

/** Call before app.open; every later document gets the bridge. */
export async function installPopupBridge(browser: InitScriptHost): Promise<void> {
  await browser.addInitScript(popupBridgeInit);
}

/** Selector for a bridge iframe by window name; without a name, the newest one. */
export const popupFrameSelector = (name?: string): string =>
  name ? `iframe[data-popup-bridge="${name}"]` : 'iframe[data-popup-bridge]:last-of-type';

/** browser.evaluate(listPopups) lists the open bridge popups. */
export const listPopups = (): { key: string; name: string; src: string; url: string; z: string }[] =>
  ((window as unknown as Record<string, any>).__popupBridge?.list() ?? []) as {
    key: string;
    name: string;
    src: string;
    url: string;
    z: string;
  }[];
