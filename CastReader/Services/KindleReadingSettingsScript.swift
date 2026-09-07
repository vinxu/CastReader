import Foundation

/// Only user-requested changes reach Amazon's native range. Its live value is
/// authoritative; localStorage can lag behind React's persisted preferences.
enum KindleReadingSettingsScript {
    static let read = script(operation: "read")
    static func close(attempt: UInt64) -> String {
        """
        (() => {
          if(window.__crKindleFontCloseAttempt !== '\(attempt)') {
            window.__crKindleFontCloseAttempt = '\(attempt)';
            window.__crKindleFontOpenedByNative = true;
          }
          return \(close);
        })()
        """
    }
    static let close = """
    (() => {
      \(KindleWebScripts.uiSemanticHelpers)
      const button = window.__crKindleFontSettingsButton;
      const visible = el => {
        if(!el || !el.isConnected) return false;
        const r=el.getBoundingClientRect(), s=getComputedStyle(el);
        return r.width>2 && r.height>2 && s.display!=='none' && s.visibility!=='hidden';
      };
      const panel = window.__crKindleFontSettingsPanel;
      const visibleFontRange = () => Array.from(document.querySelectorAll('input[type="range"],ion-range,[role="slider"]')).some(el => {
        const r=el.getBoundingClientRect(), s=getComputedStyle(el);
        return r.width>2 && r.height>2 && s.display!=='none' && s.visibility!=='hidden' && crKindleUISemanticScore(el,'font-size')>=45;
      });
      if (window.__crKindleFontOpenedByNative) {
        window.__crKindleFontOpenedByNative = false;
        if (visibleFontRange() || visible(panel) || (button && button.getAttribute('aria-expanded')==='true')) {
          const current = button && button.isConnected ? button :
            (crKindleUIFind('settings',document,'button,[role="button"],ion-button,[aria-label],[title]') || {}).el;
          if (current) current.click();
        }
      }
      return JSON.stringify({ok:!visibleFontRange() && !visible(panel) && !(button && button.getAttribute('aria-expanded')==='true')});
    })()
    """

    static func change(by delta: Int) -> String {
        script(operation: delta < 0 ? "decrease" : "increase")
    }

    private static func script(operation: String) -> String {
        """
        (() => {
          \(KindleWebScripts.uiSemanticHelpers)
          const visible = el => {
            const r = el.getBoundingClientRect(), s = getComputedStyle(el);
            return r.width > 2 && r.height > 2 && s.display !== 'none' && s.visibility !== 'hidden';
          };
          const ranges = Array.from(document.querySelectorAll('input[type="range"],ion-range,[role="slider"]')).filter(visible);
          const ranked = ranges.map(el => ({el, score:crKindleUISemanticScore(el,'font-size')})).sort((a,b)=>b.score-a.score);
          const range = ranked.length && ranked[0].score >= 45 ? ranked[0].el : null;
          const panels = Array.from(document.querySelectorAll('ion-menu,ion-popover,[role="dialog"],[role="menu"],.popover-content,.modal-wrapper,section')).filter(el =>
            visible(el) && el.querySelector('input[type="range"],ion-range,[role="slider"]'));
          const containingPanel = range && range.closest('ion-menu,ion-popover,[role="dialog"],[role="menu"],.popover-content,.modal-wrapper,section');
          if (containingPanel || panels.length===1) window.__crKindleFontSettingsPanel = containingPanel || panels[0];
          if (!range) {
            if ('\(operation)' !== 'read') return JSON.stringify({ok:false,reason:'range-not-found'});
            const match = crKindleUIFind('settings',document,'button,[role="button"],ion-button,[data-testid],[data-action],[aria-label],[title]');
            const glyph = Array.from(document.querySelectorAll('button,[role="button"],ion-button')).find(el=>visible(el) && /^aa$/i.test((el.textContent||'').trim()));
            const button = glyph || (match && match.el);
            if (!button || !visible(button)) return JSON.stringify({ok:false,reason:'settings-unavailable'});
            if (!window.__crKindleFontOpenedByNative) {
              window.__crKindleFontSettingsButton = button;
              window.__crKindleFontOpenedByNative = true;
              button.click();
            }
            return JSON.stringify({ok:false,reason:'opening-settings'});
          }
          const numeric = (attribute, fallback) => {
            const raw = range.getAttribute(attribute) ?? range[attribute];
            return raw !== null && raw !== '' && Number.isFinite(Number(raw)) ? Number(raw) : fallback;
          };
          const nativeInput = range instanceof HTMLInputElement;
          const min = numeric('min', nativeInput ? 0 : NaN), max = numeric('max', nativeInput ? 100 : NaN), step = numeric('step',1);
          const value = Number(range.value ?? range.getAttribute('aria-valuenow'));
          if (!Number.isFinite(value) || !Number.isFinite(min) || !Number.isFinite(max) || max <= min || step <= 0 || value < min || value > max) return JSON.stringify({ok:false,reason:'invalid-range'});
          if ('\(operation)' === 'read') return JSON.stringify({ok:true,value,min,max,step});
          const target = Math.max(min,Math.min(max,min + Math.round((value-min)/step + ('\(operation)' === 'increase' ? 1 : -1))*step));
          if (target === value) return JSON.stringify({ok:true,value,min,max,step,changed:false});
          if (range instanceof HTMLInputElement) {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(range,String(target));
            range.dispatchEvent(new Event('input',{bubbles:true}));
            range.dispatchEvent(new Event('change',{bubbles:true}));
          } else if (range.tagName.toLowerCase() === 'ion-range') {
            range.value = target;
            range.dispatchEvent(new CustomEvent('ionInput',{bubbles:true,detail:{value:target}}));
            range.dispatchEvent(new CustomEvent('ionChange',{bubbles:true,detail:{value:target}}));
          } else return JSON.stringify({ok:false,reason:'unsupported-range'});
          return JSON.stringify({ok:true,value:target,min,max,step,changed:true});
        })()
        """
    }
}
