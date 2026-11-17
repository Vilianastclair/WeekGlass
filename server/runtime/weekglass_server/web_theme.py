"""Shared light/dark preference for the first-party account surfaces."""
import base64
import hashlib


# Run before the page CSS so a stored preference applies to the first paint.
# Storage is cosmetic and never holds any account or authorization data.
THEME_SCRIPT = r"""(function () {
  const root = document.documentElement;
  const key = 'weekglass-theme';
  const valid = (value) => value === 'light' || value === 'dark';
  function readTheme(fallback) {
    try {
      const stored = window.localStorage.getItem(key);
      return valid(stored) ? stored : 'light';
    } catch {
      return fallback;
    }
  }
  root.dataset.theme = readTheme('light');
  document.addEventListener('DOMContentLoaded', function () {
    const control = document.querySelector('[data-theme-control]');
    if (!control) return;
    function apply(theme) {
      root.dataset.theme = control.value = theme;
    }
    apply(root.dataset.theme);
    control.addEventListener('change', function () {
      if (!valid(control.value)) return;
      apply(control.value);
      try { window.localStorage.setItem(key, control.value); } catch {}
    });
    window.addEventListener('pageshow', function (event) {
      if (event.persisted) apply(readTheme(root.dataset.theme));
    });
    control.hidden = false;
  });
})();"""

THEME_STYLE = r"""select[data-theme-control] {
  width: auto;
  max-width: 100%;
  min-height: 44px;
  padding: 4px 8px;
  border: 1px solid color-mix(in srgb, var(--muted) 40%, transparent);
  border-radius: 11px;
  background: var(--field);
  color: var(--ink);
  font-size: 14px;
  font-weight: 600;
  box-shadow: none;
  transition: none;
  cursor: pointer;
}
select[data-theme-control] option { background: var(--canvas); color: var(--ink); }
select[data-theme-control]:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }
@media (pointer: coarse) { select[data-theme-control] { font-size: 16px; } }
@media (forced-colors: active) { select[data-theme-control] { border-color: CanvasText; } }
"""


def _csp_source(value):
    digest = base64.b64encode(hashlib.sha256(value.encode()).digest()).decode()
    return f"'sha256-{digest}'"


THEME_SCRIPT_SOURCE = _csp_source(THEME_SCRIPT)
THEME_STYLE_SOURCE = _csp_source(THEME_STYLE)


def theme_head():
    return f'<script>{THEME_SCRIPT}</script><style>{THEME_STYLE}</style>'


def theme_toggle():
    return ('<select data-theme-control aria-label="页面外观" hidden>'
            '<option value="light">浅色</option><option value="dark">深色</option></select>')
