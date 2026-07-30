var ce=Object.defineProperty;var de=(o,e,t)=>e in o?ce(o,e,{enumerable:!0,configurable:!0,writable:!0,value:t}):o[e]=t;var g=(o,e,t)=>de(o,typeof e!="symbol"?e+"":e,t);import{i as pe}from"./webextension-api-CtVjzsOJ.js";import{r as E,S as H,j as l,R as ge,a as ue}from"./constants-D8bfdZWb.js";import{b as j,T as he}from"./kindle-language-BJgUKStR.js";import{D as se,p as me,a as be,x as fe,t as B,u as G,l as $,S as ve,F as xe,k as Y,H as ye,E as X,G as ke,C as Pe,T as we}from"./speed-CBKNvZ0y.js";const J=`
:host {
  all: initial;
  display: block;
  position: fixed;
  top: 32%;
  right: 0;
  z-index: 2147483646;
  pointer-events: none;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif;
}

.host-wrap {
  pointer-events: auto;
  position: relative;
}

/* ════════════════════════════════════════════════════════════
   PLAYER PANEL — compact dark D-shape (Speechify-sized)
   ════════════════════════════════════════════════════════════ */
.player-panel {
  background: rgba(38, 38, 42, 0.96);
  border-radius: 18px 0 0 18px;
  padding: 4px 10px 4px 5px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 3px;
  box-shadow: -3px 4px 12px rgba(0, 0, 0, 0.22);
  position: relative;
  backdrop-filter: blur(8px);
  transition: opacity 0.2s ease;
}

.player-panel.idle {
  opacity: 0.7;
}
.player-panel.idle:hover {
  opacity: 1;
}

/* ───── Primary (orange circle) ───── */
.primary-btn {
  width: 28px;
  height: 28px;
  border-radius: 50%;
  border: none;
  background: #F26522;
  color: #fff;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  font-family: inherit;
  box-shadow: 0 2px 5px rgba(242, 101, 34, 0.35);
  transition: background 0.15s, transform 0.1s, box-shadow 0.2s;
  flex-shrink: 0;
}
.primary-btn:hover {
  background: #ff7838;
  box-shadow: 0 3px 8px rgba(242, 101, 34, 0.5);
}
.primary-btn:active {
  transform: scale(0.94);
}
.primary-btn svg {
  width: 12px;
  height: 12px;
}
.primary-btn.loading svg {
  animation: cr-spin 0.9s linear infinite;
}
@keyframes cr-spin { to { transform: rotate(360deg); } }

/* LLM 自动朗读模式开启时的"ON"绿色角标(右上角) */
.primary-btn { position: relative; }
.primary-btn.llm-auto-on::after {
  content: 'ON';
  position: absolute;
  top: -4px;
  right: -8px;
  font-size: 8px;
  font-weight: 800;
  letter-spacing: 0.3px;
  background: #10b981;
  color: #fff;
  padding: 1px 4px;
  border-radius: 6px;
  line-height: 1.2;
  box-shadow: 0 0 0 1.5px #fff, 0 0 6px rgba(16, 185, 129, 0.6);
  pointer-events: none;
}

/* ───── Secondary controls (speed/voice/stop) ───── */
.ctrl-btn {
  width: 30px;
  height: 26px;
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.62);
  cursor: pointer;
  border-radius: 6px;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  font-family: inherit;
  font-weight: 600;
  transition: background 0.15s, transform 0.1s, color 0.15s;
}
.ctrl-btn:hover {
  background: rgba(255, 255, 255, 0.1);
  color: #fff;
}
.ctrl-btn:active {
  transform: scale(0.92);
}
.ctrl-btn svg { width: 15px; height: 15px; }

.speed-btn { font-variant-numeric: tabular-nums; }

/* 📺 Brainrot toggle — gray like other ctrl-btn when off, brand orange when on.
   TV silhouette reads cleanly at the default 13px ctrl-btn svg size. */
/* Active mode key (解读/脑腐) — brand orange highlight. */
.mode-btn.active {
  color: #ff8a3d;
  background: rgba(255, 138, 61, 0.32);
}
.mode-btn.active:hover {
  color: #ff8a3d;
  background: rgba(255, 138, 61, 0.42);
}
/* 关闭键 — smaller + dimmer than the mode keys, visually subordinate. */
.close-btn {
  height: 18px;
  color: rgba(255, 255, 255, 0.28);
}
.close-btn svg { width: 11px; height: 11px; }
.close-btn:hover {
  color: rgba(255, 255, 255, 0.6);
  background: rgba(255, 255, 255, 0.08);
}

/* 速读 (quickread) — replaces the brainrot mechanic.  Subtle pulse glow draws
   the eye to the new affordance.  Disables itself once .active (the cinematic
   is playing, so we don't want to keep "look at me" pulsing).  Kept on
   .brain-btn (same DOM node) so existing wiring/refs stay intact. */
@keyframes quickreadGlow {
  0%   { box-shadow: 0 0 0 0   rgba(255, 138, 61, 0.55); }
  60%  { box-shadow: 0 0 0 6px rgba(255, 138, 61, 0);    }
  100% { box-shadow: 0 0 0 0   rgba(255, 138, 61, 0);    }
}
.brain-btn.is-quickread:not(.active) {
  color: #ffb37a;
  animation: quickreadGlow 2.4s cubic-bezier(0.4, 0, 0.6, 1) infinite;
}
.brain-btn.is-quickread:not(.active):hover {
  color: #ff8a3d;
  background: rgba(255, 138, 61, 0.18);
}

/* Stop ✕ — muted by default to avoid visual competition with the primary
   play/pause button. Voice picker stays at the .ctrl-btn default so it reads
   the same weight as the speed (1x) and 📱 buttons next to it. */
.stop-btn {
  color: rgba(255, 255, 255, 0.42);
}
.stop-btn:hover {
  color: rgba(255, 255, 255, 0.9);
  background: rgba(255, 255, 255, 0.08);
}
/* Stop ✕ icon — 30% smaller than other ctrl icons (13px → 9px) so the close
   X doesn't visually dominate the panel. */
.stop-btn svg {
  width: 9px;
  height: 9px;
}

/* ───── Hide-on-page ✕ (idle only) ───── */
.close-page-btn {
  position: absolute;
  top: -5px;
  left: -5px;
  width: 14px;
  height: 14px;
  border-radius: 50%;
  background: rgba(180, 180, 185, 0.6);
  border: none;
  color: #fff;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  font-family: inherit;
  opacity: 0;
  transform: scale(0.6);
  transition: opacity 0.15s ease, transform 0.15s ease, background 0.15s;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.18);
  z-index: 3;
}
.player-panel.idle:hover .close-page-btn {
  opacity: 1;
  transform: scale(1);
}

.close-page-btn:hover {
  background: rgba(120, 120, 130, 0.95);
}
.close-page-btn svg { width: 7px; height: 7px; }

/* ───── Tooltip on the LEFT ───── */
/* The host wrap MUST be position:relative so the absolutely-positioned tooltip
   anchors to the button (not the panel). Without this rule the tooltip falls
   back to the nearest positioned ancestor (the panel), and ends up centered
   on the panel rather than the hovered button. */
.has-tooltip {
  position: relative;
}
.tooltip {
  position: absolute;
  right: 100%;
  margin-right: 8px;
  top: 50%;
  transform: translateY(-50%) translateX(4px);
  /* Soft gray, partially transparent — less heavy than near-black */
  background: rgba(80, 80, 90, 0.78);
  color: rgba(255, 255, 255, 0.95);
  padding: 5px 10px;
  border-radius: 6px;
  font-size: 11px;
  font-weight: 500;
  white-space: nowrap;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.12s ease, transform 0.12s ease;
  letter-spacing: 0.1px;
  box-shadow: 0 2px 5px rgba(0, 0, 0, 0.12);
  backdrop-filter: blur(2px);
}
.has-tooltip:hover > .tooltip {
  opacity: 1;
  transform: translateY(-50%) translateX(0);
}
/* Suppress all tooltips while any popover (speed / voice / QR / notice / close)
   is open. The popover sits in the same left-of-panel slot as the tooltip and
   the two would overlap (tooltip's dark pill peeks out behind the popover and
   reads like a glitch). User has to dismiss the popover first to get tooltips
   back — same convention as macOS / VSCode menus. */
.player-panel:has(.popover.open) .tooltip {
  opacity: 0 !important;
  transform: translateY(-50%) translateX(4px) !important;
}

/* 首触极简气泡:在 🎧 左侧、橙底单行,自动淡出(.show 由 JS 控制)。比 tooltip 更醒目,
   只教「这是朗读入口」。无交互、一次性。带一个指向 🎧 的小三角。 */
.listen-hint {
  position: absolute;
  right: 100%;
  margin-right: 12px;
  top: 50%;
  transform: translateY(-50%) translateX(8px);
  background: #ff8a3d;
  color: #fff;
  padding: 8px 13px;
  border-radius: 9px;
  font-size: 12.5px;
  font-weight: 600;
  white-space: nowrap;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.28s ease, transform 0.28s ease;
  box-shadow: 0 5px 18px rgba(255, 138, 61, 0.4);
  z-index: 6;
}
.listen-hint::after {
  content: '';
  position: absolute;
  left: 100%;
  top: 50%;
  transform: translateY(-50%);
  border: 6px solid transparent;
  border-left-color: #ff8a3d;
}
.listen-hint.show {
  opacity: 1;
  transform: translateY(-50%) translateX(0);
}

/* ═══════════════════════ POPOVER ═══════════════════════
   Positioned to the LEFT of the panel, vertically centered
   on the panel — adapts to panel height automatically.
   ═══════════════════════════════════════════════════════ */
.popover {
  position: absolute;
  right: 100%;
  margin-right: 10px;
  top: 50%;
  transform: translateY(-50%);
  background: rgba(38, 38, 42, 0.97);
  border-radius: 10px;
  padding: 4px;
  min-width: 100px;
  max-height: 280px;
  overflow-y: auto;
  box-shadow: -3px 4px 14px rgba(0, 0, 0, 0.4);
  display: none;
  flex-direction: column;
  gap: 1px;
  backdrop-filter: blur(10px);
  z-index: 4;
}
.popover.open { display: flex; }

.settings-popover {
  width: 270px;
  max-width: calc(100vw - 96px);
}

/* Settings-only Pro discovery. It lives inside a user-opened surface, never on
   the reading page itself, and can be permanently dismissed. */
.settings-pro-banner {
  position: relative;
  flex: none;
  margin: 1px 2px 7px;
  overflow: hidden;
  border: 1px solid rgba(255, 138, 61, 0.42);
  border-radius: 11px;
  background:
    radial-gradient(circle at 12% 12%, rgba(255, 200, 140, 0.18), transparent 42%),
    linear-gradient(120deg, rgba(242, 101, 34, 0.2), rgba(255, 138, 61, 0.1));
}
.settings-pro-banner-action {
  width: 100%;
  min-height: 72px;
  border: 0;
  background: transparent;
  color: rgba(255, 255, 255, 0.94);
  cursor: pointer;
  padding: 11px 29px 11px 10px;
  display: grid;
  grid-template-columns: 32px minmax(0, 1fr) 25px;
  align-items: center;
  gap: 8px;
  font: inherit;
  text-align: left;
}
.settings-pro-banner-action:hover {
  background: rgba(255, 138, 61, 0.1);
}
.settings-pro-banner-action:focus-visible,
.settings-pro-banner-dismiss:focus-visible {
  outline: 2px solid #ff8a3d;
  outline-offset: -2px;
}
.settings-pro-banner-gift {
  width: 32px;
  height: 32px;
  border-radius: 10px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  background: rgba(255, 138, 61, 0.17);
  font-size: 19px;
}
.settings-pro-banner-copy {
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 3px;
  white-space: normal;
}
.settings-pro-banner-copy strong {
  color: #ff9656;
  font-size: 12.5px;
  font-weight: 750;
  line-height: 1.28;
}
.settings-pro-banner-copy > span {
  color: rgba(255, 255, 255, 0.62);
  font-size: 10.5px;
  font-weight: 450;
  line-height: 1.35;
}
.settings-pro-banner-arrow {
  width: 25px;
  height: 25px;
  border-radius: 8px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  background: #f26522;
  color: #fff;
  font-size: 15px;
  font-weight: 700;
  transition: transform 0.12s, background 0.12s;
}
.settings-pro-banner-action:hover .settings-pro-banner-arrow {
  transform: translateX(2px);
  background: #ff7838;
}
.settings-pro-banner-dismiss {
  position: absolute;
  z-index: 1;
  top: 4px;
  right: 5px;
  width: 20px;
  height: 20px;
  padding: 0;
  border: 0;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.1);
  color: rgba(255, 255, 255, 0.52);
  cursor: pointer;
  font: 700 15px/20px system-ui, sans-serif;
}
.settings-pro-banner-dismiss:hover {
  background: rgba(255, 255, 255, 0.18);
  color: #fff;
}

.popover-item {
  width: 100%;
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.85);
  cursor: pointer;
  padding: 7px 12px;
  border-radius: 6px;
  text-align: left;
  font-size: 12px;
  font-weight: 500;
  font-family: inherit;
  display: flex;
  align-items: center;
  justify-content: space-between;
  transition: background 0.12s, color 0.12s;
  white-space: nowrap;
}
.popover-item:hover {
  background: rgba(255, 255, 255, 0.1);
  color: #fff;
}
.popover-item.selected {
  color: #F26522;
  font-weight: 600;
}
.popover-item.selected::after {
  content: '✓';
  margin-left: 8px;
  color: #F26522;
}
/* 朗读分层:Pro 专属档(>1.25× 速 / 锁定语音)。label 灰显 + 右侧试用角标。 */
.popover-item-locked {
  color: rgba(255, 255, 255, 0.4);
}
.popover-item-locked:hover {
  background: rgba(255, 255, 255, 0.06);
  color: rgba(255, 255, 255, 0.6);
}
.popover-pro-badge {
  margin-left: 8px;
  flex-shrink: 0;
  font-size: 8.5px;
  font-weight: 700;
  line-height: 1;
  letter-spacing: 0.3px;
  color: #F26522;
  background: rgba(242, 101, 34, 0.15);
  border: 1px solid rgba(242, 101, 34, 0.5);
  border-radius: 5px;
  padding: 2px 5px;
  white-space: nowrap;
}
/* 解读「专家级」档:始终突出(金色 👑 + 高级感),Pro/免费都一眼认出高级档;免费额外 Pro 角标。
   selected 时仍走 .popover-item.selected 的橙色 + ✓(:not(.selected) 让位),状态反馈与其他档统一。 */
.popover-item-expert {
  background: linear-gradient(90deg, rgba(255, 200, 61, 0.08), transparent 70%);
}
.popover-item-expert .popover-expert-main {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}
.popover-item-expert .popover-expert-icon {
  font-size: 11px;
  flex-shrink: 0;
}
.popover-item-expert:not(.selected) {
  color: #FFC83D;
  font-weight: 600;
}
.popover-item-expert:not(.selected):hover {
  color: #FFD66B;
  background: linear-gradient(90deg, rgba(255, 200, 61, 0.16), rgba(255, 255, 255, 0.06));
}

/* 三层设置:概览行右侧当前值(灰显) + 返回行 */
.popover-nav-row {
  gap: 16px;   /* label 与 value 之间最小间距,避免长值与 label 叠在一起 */
}
.popover-nav-row > span:first-child {
  flex-shrink: 0;   /* label 不被压缩 */
}
.popover-nav-value {
  color: rgba(255, 255, 255, 0.45);
  font-weight: 400;
  font-size: 11px;
  text-align: right;   /* 值靠右,过长时换行而非与 label 重叠 */
  min-width: 0;
}
/* 高亮颜色:色块圆点(概览行右侧 + 颜色列表项) */
.popover-swatch {
  display: inline-block;
  width: 12px;
  height: 12px;
  border-radius: 50%;
  vertical-align: middle;
  margin-right: 6px;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.25);
  flex-shrink: 0;
}
.popover-swatch-item {
  justify-content: flex-start;
  gap: 10px;
}
.popover-back-row {
  color: rgba(255, 255, 255, 0.5);
  font-weight: 600;
  justify-content: flex-start;
  gap: 4px;
  margin-bottom: 2px;
}

.popover-empty {
  padding: 10px 12px;
  color: rgba(255, 255, 255, 0.4);
  font-size: 11px;
  text-align: center;
}

.popover-section-title {
  padding: 6px 12px 3px;
  font-size: 10px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.4);
  text-transform: uppercase;
  letter-spacing: 0.06em;
  user-select: none;
  pointer-events: none;
}
.popover-divider {
  height: 1px;
  background: rgba(255, 255, 255, 0.13);
  margin: 3px 0;
}
.voice-popover { min-width: 140px; }

/* ─── Feedback popover ─── */
.feedback-popover {
  min-width: 230px;
  max-width: 270px;
  padding: 12px;
  gap: 8px;
}
.feedback-header {
  font-size: 12px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.9);
  margin-bottom: 2px;
}
.feedback-textarea {
  width: 100%;
  min-height: 80px;
  resize: vertical;
  background: rgba(255,255,255,0.1);
  border: 1px solid rgba(255,255,255,0.18);
  border-radius: 6px;
  color: rgba(255,255,255,0.92);
  font-size: 12px;
  font-family: inherit;
  padding: 7px 9px;
  box-sizing: border-box;
  outline: none;
  line-height: 1.5;
  transition: border-color 0.15s;
}
.feedback-textarea:focus {
  border-color: rgba(242,101,34,0.7);
  box-shadow: 0 0 0 2px rgba(242,101,34,0.15);
}
.feedback-email {
  width: 100%;
  background: rgba(255,255,255,0.1);
  border: 1px solid rgba(255,255,255,0.18);
  border-radius: 6px;
  color: rgba(255,255,255,0.92);
  font-size: 12px;
  font-family: inherit;
  padding: 6px 9px;
  box-sizing: border-box;
  outline: none;
  transition: border-color 0.15s;
}
.feedback-email:focus {
  border-color: rgba(242,101,34,0.7);
  box-shadow: 0 0 0 2px rgba(242,101,34,0.15);
}
.feedback-textarea::placeholder,
.feedback-email::placeholder { color: rgba(255,255,255,0.32); }
.feedback-submit {
  width: 100%;
  padding: 7px 12px;
  background: #F26522;
  color: #fff;
  border: none;
  border-radius: 6px;
  font-size: 12px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
  transition: opacity 0.15s;
}
.feedback-submit:hover { opacity: 0.88; }
.feedback-submit:disabled { opacity: 0.5; cursor: wait; }
.feedback-status {
  font-size: 11px;
  text-align: center;
  color: rgba(255,255,255,0.55);
  min-height: 16px;
}
.feedback-status.success { color: #4ade80; }
.feedback-status.error   { color: #f87171; }

/* ─── Generic notice popover (errors / rating prompts) ─── */
.popover-notice {
  padding: 12px;
  min-width: 200px;
  max-width: 240px;
  color: rgba(255, 255, 255, 0.92);
}
.popover-notice-title {
  font-size: 12px;
  font-weight: 600;
  margin: 0 0 6px;
  letter-spacing: 0.1px;
}
.popover-notice-body {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.7);
  line-height: 1.45;
  margin: 0 0 10px;
}
.popover-notice-actions {
  display: flex;
  gap: 6px;
  justify-content: flex-end;
}
.popover-notice-btn {
  border: none;
  padding: 5px 12px;
  border-radius: 5px;
  font-size: 11px;
  font-weight: 600;
  cursor: pointer;
  font-family: inherit;
  transition: opacity 0.12s, background 0.12s;
}
.popover-notice-btn.primary {
  background: #F26522;
  color: #fff;
}
.popover-notice-btn.primary:hover { background: #ff7838; }
.popover-notice-btn.secondary {
  background: transparent;
  color: rgba(255, 255, 255, 0.55);
}
.popover-notice-btn.secondary:hover { color: rgba(255, 255, 255, 0.9); }

/* ─── Rating popover (5 stars) ─── */
.popover-rating {
  padding: 14px 16px;
  min-width: 180px;
  text-align: center;
}
.popover-rating-title {
  font-size: 12px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.92);
  margin: 0 0 10px;
}
.popover-rating-stars {
  display: flex;
  justify-content: center;
  gap: 4px;
  margin: 0 0 8px;
}
.popover-rating-star {
  cursor: pointer;
  color: rgba(255, 255, 255, 0.3);
  transition: color 0.15s, transform 0.1s;
  font-size: 22px;
  line-height: 1;
  user-select: none;
  -webkit-user-select: none;
}
.popover-rating-star:hover,
.popover-rating-star.active {
  color: #F26522;
}
.popover-rating-star:hover { transform: scale(1.15); }
.popover-rating-dismiss {
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.45);
  font-size: 11px;
  cursor: pointer;
  padding: 4px 8px;
  font-family: inherit;
}
.popover-rating-dismiss:hover { color: rgba(255, 255, 255, 0.85); }

/* ─── Close-options popover (clicking ✕ on idle-state panel) ─── */
.popover-close {
  padding: 6px 6px 8px;
  min-width: 220px;
}
.popover-close-title {
  font-size: 12px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.92);
  padding: 4px 8px 8px;
  letter-spacing: 0.1px;
}
.popover-close-btn {
  width: 100%;
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.85);
  cursor: pointer;
  padding: 8px 10px;
  border-radius: 6px;
  text-align: left;
  font-size: 12px;
  font-weight: 500;
  font-family: inherit;
  transition: background 0.12s, color 0.12s;
}
.popover-close-btn:hover {
  background: rgba(255, 255, 255, 0.1);
  color: #fff;
}
.popover-close-btn .hint {
  display: block;
  font-size: 10px;
  color: rgba(255, 255, 255, 0.45);
  margin-top: 2px;
  font-weight: 400;
}
.popover-close-btn:hover .hint {
  color: rgba(255, 255, 255, 0.7);
}
.popover-close-btn.cancel {
  color: rgba(255, 255, 255, 0.5);
  text-align: center;
  margin-top: 4px;
}
.popover-close-divider {
  height: 1px;
  background: rgba(255, 255, 255, 0.08);
  margin: 4px 0;
}

/* ─── Top-right toast (used for close-confirmation, errors, etc.) ───
   Free-floating in the viewport corner, not anchored to the panel. */
.toast-host {
  position: fixed;
  top: 16px;
  right: 16px;
  z-index: 2147483646;
  pointer-events: none;
}
.toast {
  pointer-events: auto;
  background: rgba(38, 38, 42, 0.97);
  color: rgba(255, 255, 255, 0.92);
  padding: 14px 16px;
  border-radius: 12px;
  min-width: 280px;
  max-width: 360px;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.25);
  backdrop-filter: blur(8px);
  font-family: inherit;
  animation: cr-toast-in 0.18s ease;
}
@keyframes cr-toast-in {
  from { opacity: 0; transform: translateY(-6px); }
  to   { opacity: 1; transform: translateY(0); }
}
.toast-title {
  font-size: 13px;
  font-weight: 700;
  margin: 0 0 6px;
  letter-spacing: 0.1px;
}
.toast-body {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.7);
  line-height: 1.5;
  margin: 0 0 12px;
}
.toast-actions {
  display: flex;
  gap: 8px;
  justify-content: flex-end;
}
.toast-btn {
  border: none;
  padding: 6px 14px;
  border-radius: 6px;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  font-family: inherit;
  transition: opacity 0.12s, background 0.12s;
}
.toast-btn.primary {
  background: #F26522;
  color: #fff;
}
.toast-btn.primary:hover { background: #ff7838; }
.toast-btn.secondary {
  background: transparent;
  color: rgba(255, 255, 255, 0.55);
}
.toast-btn.secondary:hover { color: rgba(255, 255, 255, 0.9); }

.toast { position: relative; }

/* ════════════════════════════════════════════════════════════
   LIGHT MODE OVERRIDES
   Triggered by OS/Chrome dark/light theme. The panel and all
   popovers flip to a white surface with dark text.
   ════════════════════════════════════════════════════════════ */
@media (prefers-color-scheme: light) {
  .player-panel {
    background: rgba(255, 255, 255, 0.96);
    box-shadow: -3px 4px 14px rgba(0, 0, 0, 0.12);
  }

  .ctrl-btn {
    color: rgba(0, 0, 0, 0.6);
  }
  .ctrl-btn:hover {
    background: rgba(0, 0, 0, 0.06);
    color: #1a1a1a;
  }
  .stop-btn {
    color: rgba(0, 0, 0, 0.4);
  }
  .stop-btn:hover {
    color: rgba(0, 0, 0, 0.85);
    background: rgba(0, 0, 0, 0.05);
  }

  .close-page-btn {
    background: rgba(0, 0, 0, 0.18);
  }
  .close-page-btn:hover {
    background: rgba(0, 0, 0, 0.4);
  }

  /* Tooltip in light mode — slightly darker gray for contrast against white pages */
  .tooltip {
    background: rgba(70, 70, 80, 0.82);
    color: rgba(255, 255, 255, 0.95);
  }

  .popover {
    background: rgba(255, 255, 255, 0.98);
    box-shadow: -3px 4px 16px rgba(0, 0, 0, 0.14);
  }
  .settings-pro-banner {
    border-color: rgba(242, 101, 34, 0.3);
    background:
      radial-gradient(circle at 12% 12%, rgba(255, 202, 153, 0.5), transparent 44%),
      linear-gradient(120deg, #fff2e9, #fff8f3);
  }
  .settings-pro-banner-copy strong {
    color: #d94e12;
  }
  .settings-pro-banner-copy > span {
    color: rgba(41, 37, 36, 0.62);
  }
  .settings-pro-banner-dismiss {
    background: rgba(120, 80, 60, 0.08);
    color: rgba(80, 55, 45, 0.45);
  }
  .settings-pro-banner-dismiss:hover {
    background: rgba(120, 80, 60, 0.14);
    color: rgba(55, 35, 28, 0.82);
  }
  .popover-item {
    color: rgba(0, 0, 0, 0.82);
  }
  .popover-item:hover {
    background: rgba(0, 0, 0, 0.05);
    color: #000;
  }
  .popover-item.selected {
    color: #F26522;
  }
  .popover-item.selected::after {
    color: #F26522;
  }
  .popover-empty {
    color: rgba(0, 0, 0, 0.4);
  }
  .popover-section-title {
    color: rgba(0, 0, 0, 0.38);
  }
  .popover-nav-value {
    color: rgba(0, 0, 0, 0.45);
  }
  .popover-back-row {
    color: rgba(0, 0, 0, 0.5);
  }
  .popover-divider {
    background: rgba(0, 0, 0, 0.14);
  }

  /* Notice popover */
  .popover-notice {
    color: rgba(0, 0, 0, 0.92);
  }
  .popover-notice-title {
    color: rgba(0, 0, 0, 0.92);
  }
  .popover-notice-body {
    color: rgba(0, 0, 0, 0.6);
  }
  .popover-notice-btn.secondary {
    color: rgba(0, 0, 0, 0.55);
  }
  .popover-notice-btn.secondary:hover {
    color: #000;
  }

  /* Rating popover */
  .popover-rating-title {
    color: rgba(0, 0, 0, 0.92);
  }
  .popover-rating-star {
    color: rgba(0, 0, 0, 0.25);
  }
  .popover-rating-dismiss {
    color: rgba(0, 0, 0, 0.55);
  }
  .popover-rating-dismiss:hover {
    color: #000;
  }

  /* Close-options popover */
  .popover-close-title {
    color: rgba(0, 0, 0, 0.9);
  }
  .popover-close-btn {
    color: rgba(0, 0, 0, 0.85);
  }
  .popover-close-btn:hover {
    background: rgba(0, 0, 0, 0.06);
    color: #000;
  }
  .popover-close-btn .hint {
    color: rgba(0, 0, 0, 0.5);
  }
  .popover-close-btn:hover .hint {
    color: rgba(0, 0, 0, 0.7);
  }
  .popover-close-btn.cancel {
    color: rgba(0, 0, 0, 0.5);
  }
  .popover-close-divider {
    background: rgba(0, 0, 0, 0.08);
  }

  /* Feedback popover in light mode */
  .feedback-header {
    color: rgba(0, 0, 0, 0.85);
  }
  .feedback-textarea,
  .feedback-email {
    background: #fff;
    border-color: rgba(0, 0, 0, 0.16);
    color: rgba(0, 0, 0, 0.85);
  }
  .feedback-textarea:focus,
  .feedback-email:focus {
    border-color: rgba(242, 101, 34, 0.7);
    box-shadow: 0 0 0 2px rgba(242, 101, 34, 0.12);
  }
  .feedback-textarea::placeholder,
  .feedback-email::placeholder {
    color: rgba(0, 0, 0, 0.35);
  }
  .feedback-status {
    color: rgba(0, 0, 0, 0.5);
  }

  /* Toast in light mode */
  .toast {
    background: rgba(255, 255, 255, 0.98);
    color: rgba(0, 0, 0, 0.92);
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.18);
  }
  .toast-body {
    color: rgba(0, 0, 0, 0.6);
  }
  .toast-btn.secondary {
    color: rgba(0, 0, 0, 0.55);
  }
  .toast-btn.secondary:hover {
    color: #000;
  }

}
`,V="castreader_pro_settings_banner_dismissed",Z={en:"Run the getting-started guide",zh:"重新体验首次使用引导",ja:"初回ガイドをもう一度見る",es:"Volver a ver la guía inicial",fr:"Revoir le guide de démarrage",de:"Einführung erneut starten",pt:"Rever o guia de início",it:"Rivedi la guida introduttiva",hi:"शुरुआती गाइड फिर से देखें"},ee='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 18v-6a9 9 0 0 1 18 0v6"/><path d="M21 19a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3z"/><path d="M3 19a2 2 0 0 0 2 2h1a2 2 0 0 0 2-2v-3a2 2 0 0 0-2-2H3z"/></svg>',Ce='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" stroke="none"><polygon points="6 4 20 12 6 20 6 4"/></svg>',Ee='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" stroke="none"><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></svg>',Se='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="20" y1="4" x2="4" y2="20"/><line x1="4" y1="4" x2="20" y2="20"/></svg>',Te='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M21 12a9 9 0 1 1-6.219-8.56"/></svg>',Le='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="4.5"/><path d="M3.5 21v-1.5A5.5 5.5 0 0 1 9 14h6a5.5 5.5 0 0 1 5.5 5.5V21"/></svg>',Re='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2 4h7a3 3 0 0 1 3 3v13a2.5 2.5 0 0 0-2.5-2.5H2z"/><path d="M22 4h-7a3 3 0 0 0-3 3v13a2.5 2.5 0 0 1 2.5-2.5H22z"/></svg>',De='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>',Ae='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="8" y1="13" x2="16" y2="13"/><line x1="8" y1="17" x2="13" y2="17"/></svg>',te=[{code:"overview",labelKey:"depthOverview"},{code:"standard",labelKey:"depthStandard"},{code:"deep",labelKey:"depthDeep"}],oe={en:{listen:"Read this page",pause:"Pause",resume:"Resume",loading:"Loading…",hideOnPage:"Hide on this page",stop:"Stop",speed:"Playback speed",voice:"Voice",lang:"Language",readingLang:"Reading language",sendFeedback:"Send feedback",stopReading:"Stop reading",feedbackTitle:"Quick feedback",feedbackPlaceholder:"Something went wrong? Or a suggestion?",feedbackEmailPlaceholder:"Your email (required)",feedbackEmailRequired:"Please enter your email.",feedbackSend:"Send",feedbackSending:"Sending…",feedbackDone:"Sent! Thank you.",feedbackFailed:"Send failed, please try again.",get brainrotOn(){var o,e;return typeof chrome<"u"&&((e=(o=chrome.i18n)==null?void 0:o.getMessage)==null?void 0:e.call(o,"quickreadBtn"))||"Quick Overview"},get brainrotOff(){var o,e;return typeof chrome<"u"&&((e=(o=chrome.i18n)==null?void 0:o.getMessage)==null?void 0:e.call(o,"quickreadBtnExit"))||"Exit Overview"},modeRead:"Read",modeExplain:"Explain",modeBrainrot:"Quick Read",openReader:"Read a file (PDF / Word / Text)",settings:"Settings",close:"Close",highlightColorTitle:"Highlight color",explainLangTitle:"Explain in",explainAuto:"Auto (my language)",explainFollow:"Follow page",depthTitle:"Detail level",depthOverview:"Overview",depthStandard:"Standard",depthDeep:"Expert",groupReading:"Reading",groupExplain:"Explain",closeTitle:"Turn off CastReader on {domain}?",closeSession:"Yes, for this session",closeDomain:"Yes, from now on",closeCancel:"No, don’t turn it off",selectionReaderTitle:"Selection reading",stateOn:"On",stateOff:"Off",ytSourceTitle:"Choose what to read",ytCaptions:"🎬 Listen to the captions",ytRecommended:"Recommended",ytPage:"📄 Listen to the page",notSignedIn:"Not signed in",signIn:"Sign in",enablePro:"Enable Pro",quotaPro:"Explain · Pro ∞",quotaTip:o=>`Explain · ${o} left today`,listenQuotaPro:"Listen · Pro ∞",listenQuotaTip:o=>`Listen · ${o} min left today`,logout:"↩ Log out",todayUsage:"Today's usage",remainingMinutes:o=>`${o} min left`,remainingUses:o=>`${o} left`},zh:{listen:"朗读当前页",pause:"暂停",resume:"继续",loading:"加载中…",hideOnPage:"本页隐藏",stop:"停止",speed:"播放速度",voice:"音色",lang:"语言",readingLang:"朗读语言",sendFeedback:"发送反馈",stopReading:"停止朗读",feedbackTitle:"留下反馈",feedbackPlaceholder:"遇到问题？或者有建议？",feedbackEmailPlaceholder:"你的邮箱（必填）",feedbackEmailRequired:"请输入邮箱",feedbackSend:"发送",feedbackSending:"发送中…",feedbackDone:"已发送，谢谢！",feedbackFailed:"发送失败，请重试",get brainrotOn(){var o,e;return typeof chrome<"u"&&((e=(o=chrome.i18n)==null?void 0:o.getMessage)==null?void 0:e.call(o,"quickreadBtn"))||"Quick Overview"},get brainrotOff(){var o,e;return typeof chrome<"u"&&((e=(o=chrome.i18n)==null?void 0:o.getMessage)==null?void 0:e.call(o,"quickreadBtnExit"))||"Exit Overview"},modeRead:"朗读",modeExplain:"解读",modeBrainrot:"速读",openReader:"读本地文档（PDF / Word / Text）",settings:"设置",close:"关闭",highlightColorTitle:"高亮颜色",explainLangTitle:"讲解语言",explainAuto:"自动（跟随我）",explainFollow:"跟随原文",depthTitle:"讲解详略",depthOverview:"速览",depthStandard:"标准",depthDeep:"专家级",groupReading:"朗读",groupExplain:"解读",closeTitle:"在 {domain} 关闭 CastReader？",closeSession:"本次访问关闭",closeDomain:"从现在起一直关闭",closeCancel:"不关闭",selectionReaderTitle:"划词朗读",stateOn:"开",stateOff:"关",ytSourceTitle:"选择朗读来源",ytCaptions:"🎬 听视频字幕",ytRecommended:"推荐",ytPage:"📄 听页面内容",notSignedIn:"未登录",signIn:"登录",enablePro:"开启 Pro",quotaPro:"解读 · Pro 无限",quotaTip:o=>`解读 · 今日还剩 ${o} 次`,listenQuotaPro:"朗读 · Pro 无限",listenQuotaTip:o=>`朗读 · 今日还剩 ${o} 分钟`,logout:"↩ 退出登录",todayUsage:"今日用量",remainingMinutes:o=>`还剩 ${o} 分钟`,remainingUses:o=>`还剩 ${o} 次`},ja:{listen:"このページを読む",pause:"一時停止",resume:"再開",loading:"読み込み中…",hideOnPage:"このページで非表示",stop:"停止",speed:"再生速度",voice:"音声",lang:"言語",readingLang:"読み上げ言語",sendFeedback:"フィードバックを送信",stopReading:"読み上げを停止",feedbackTitle:"クイックフィードバック",feedbackPlaceholder:"問題やご要望をお聞かせください",feedbackEmailPlaceholder:"メールアドレス（必須）",feedbackEmailRequired:"メールアドレスを入力してください。",feedbackSend:"送信",feedbackSending:"送信中…",feedbackDone:"送信しました。ありがとうございます。",feedbackFailed:"送信できませんでした。もう一度お試しください。",brainrotOn:"クイック概要",brainrotOff:"概要を終了",modeRead:"読み上げ",modeExplain:"解説",modeBrainrot:"速読",openReader:"ファイルを読む（PDF / Word / Text）",settings:"設定",close:"閉じる",highlightColorTitle:"ハイライト色",explainLangTitle:"解説言語",explainAuto:"自動（自分の言語）",explainFollow:"ページに合わせる",depthTitle:"詳細度",depthOverview:"概要",depthStandard:"標準",depthDeep:"専門",groupReading:"読み上げ",groupExplain:"解説",closeTitle:"{domain} で CastReader をオフにしますか？",closeSession:"このセッションだけオフ",closeDomain:"今後このサイトでオフ",closeCancel:"オフにしない",selectionReaderTitle:"選択テキストの読み上げ",stateOn:"オン",stateOff:"オフ",ytSourceTitle:"読み上げる内容を選択",ytCaptions:"🎬 字幕を聴く",ytRecommended:"おすすめ",ytPage:"📄 ページを聴く",notSignedIn:"未ログイン",signIn:"ログイン",enablePro:"Pro を有効にする",quotaPro:"解説 · Pro 無制限",quotaTip:o=>`解説 · 本日残り ${o} 回`,listenQuotaPro:"読み上げ · Pro 無制限",listenQuotaTip:o=>`読み上げ · 本日残り ${o} 分`,logout:"↩ ログアウト",todayUsage:"本日の利用量",remainingMinutes:o=>`残り ${o} 分`,remainingUses:o=>`残り ${o} 回`},es:{listen:"Leer esta página",pause:"Pausar",resume:"Reanudar",loading:"Cargando…",hideOnPage:"Ocultar en esta página",stop:"Detener",speed:"Velocidad de reproducción",voice:"Voz",lang:"Idioma",readingLang:"Idioma de lectura",sendFeedback:"Enviar comentarios",stopReading:"Detener lectura",feedbackTitle:"Comentario rápido",feedbackPlaceholder:"¿Algo salió mal o tienes una sugerencia?",feedbackEmailPlaceholder:"Tu correo (obligatorio)",feedbackEmailRequired:"Introduce tu correo.",feedbackSend:"Enviar",feedbackSending:"Enviando…",feedbackDone:"¡Enviado! Gracias.",feedbackFailed:"No se pudo enviar. Inténtalo de nuevo.",brainrotOn:"Resumen rápido",brainrotOff:"Salir del resumen",modeRead:"Leer",modeExplain:"Explicar",modeBrainrot:"Lectura rápida",openReader:"Leer un archivo (PDF / Word / Text)",settings:"Ajustes",close:"Cerrar",highlightColorTitle:"Color de resaltado",explainLangTitle:"Explicar en",explainAuto:"Automático (mi idioma)",explainFollow:"Seguir la página",depthTitle:"Nivel de detalle",depthOverview:"Resumen",depthStandard:"Estándar",depthDeep:"Experto",groupReading:"Lectura",groupExplain:"Explicación",closeTitle:"¿Desactivar CastReader en {domain}?",closeSession:"Sí, en esta sesión",closeDomain:"Sí, a partir de ahora",closeCancel:"No desactivar",selectionReaderTitle:"Leer al seleccionar",stateOn:"Activado",stateOff:"Desactivado",ytSourceTitle:"Elige qué leer",ytCaptions:"🎬 Escuchar los subtítulos",ytRecommended:"Recomendado",ytPage:"📄 Escuchar la página",notSignedIn:"Sesión no iniciada",signIn:"Iniciar sesión",enablePro:"Activar Pro",quotaPro:"Explicar · Pro ∞",quotaTip:o=>`Explicar · ${o} restantes hoy`,listenQuotaPro:"Escuchar · Pro ∞",listenQuotaTip:o=>`Escuchar · ${o} min restantes hoy`,logout:"↩ Cerrar sesión",todayUsage:"Uso de hoy",remainingMinutes:o=>`${o} min restantes`,remainingUses:o=>`${o} restantes`},fr:{listen:"Lire cette page",pause:"Pause",resume:"Reprendre",loading:"Chargement…",hideOnPage:"Masquer sur cette page",stop:"Arrêter",speed:"Vitesse de lecture",voice:"Voix",lang:"Langue",readingLang:"Langue de lecture",sendFeedback:"Envoyer un commentaire",stopReading:"Arrêter la lecture",feedbackTitle:"Commentaire rapide",feedbackPlaceholder:"Un problème ou une suggestion ?",feedbackEmailPlaceholder:"Votre e-mail (obligatoire)",feedbackEmailRequired:"Saisissez votre e-mail.",feedbackSend:"Envoyer",feedbackSending:"Envoi…",feedbackDone:"Envoyé ! Merci.",feedbackFailed:"Échec de l’envoi. Réessayez.",brainrotOn:"Aperçu rapide",brainrotOff:"Quitter l’aperçu",modeRead:"Lire",modeExplain:"Expliquer",modeBrainrot:"Lecture rapide",openReader:"Lire un fichier (PDF / Word / Text)",settings:"Paramètres",close:"Fermer",highlightColorTitle:"Couleur de surbrillance",explainLangTitle:"Expliquer en",explainAuto:"Auto (ma langue)",explainFollow:"Suivre la page",depthTitle:"Niveau de détail",depthOverview:"Aperçu",depthStandard:"Standard",depthDeep:"Expert",groupReading:"Lecture",groupExplain:"Explication",closeTitle:"Désactiver CastReader sur {domain} ?",closeSession:"Oui, pour cette session",closeDomain:"Oui, désormais",closeCancel:"Ne pas désactiver",selectionReaderTitle:"Lecture de la sélection",stateOn:"Activé",stateOff:"Désactivé",ytSourceTitle:"Choisissez le contenu à lire",ytCaptions:"🎬 Écouter les sous-titres",ytRecommended:"Recommandé",ytPage:"📄 Écouter la page",notSignedIn:"Non connecté",signIn:"Se connecter",enablePro:"Activer Pro",quotaPro:"Expliquer · Pro ∞",quotaTip:o=>`Expliquer · ${o} restant(s) aujourd’hui`,listenQuotaPro:"Écouter · Pro ∞",listenQuotaTip:o=>`Écouter · ${o} min restantes aujourd’hui`,logout:"↩ Se déconnecter",todayUsage:"Utilisation du jour",remainingMinutes:o=>`${o} min restantes`,remainingUses:o=>`${o} restantes`},de:{listen:"Diese Seite vorlesen",pause:"Pause",resume:"Fortsetzen",loading:"Wird geladen…",hideOnPage:"Auf dieser Seite ausblenden",stop:"Stopp",speed:"Wiedergabegeschwindigkeit",voice:"Stimme",lang:"Sprache",readingLang:"Vorlesesprache",sendFeedback:"Feedback senden",stopReading:"Vorlesen beenden",feedbackTitle:"Kurzes Feedback",feedbackPlaceholder:"Ist etwas schiefgelaufen oder hast du einen Vorschlag?",feedbackEmailPlaceholder:"Deine E-Mail-Adresse (erforderlich)",feedbackEmailRequired:"Bitte gib deine E-Mail-Adresse ein.",feedbackSend:"Senden",feedbackSending:"Wird gesendet…",feedbackDone:"Gesendet! Vielen Dank.",feedbackFailed:"Senden fehlgeschlagen. Bitte erneut versuchen.",brainrotOn:"Schnellübersicht",brainrotOff:"Übersicht schließen",modeRead:"Vorlesen",modeExplain:"Erklären",modeBrainrot:"Schnelllesen",openReader:"Datei vorlesen (PDF / Word / Text)",settings:"Einstellungen",close:"Schließen",highlightColorTitle:"Markierungsfarbe",explainLangTitle:"Erklären auf",explainAuto:"Automatisch (meine Sprache)",explainFollow:"Seitensprache verwenden",depthTitle:"Detailgrad",depthOverview:"Übersicht",depthStandard:"Standard",depthDeep:"Experte",groupReading:"Vorlesen",groupExplain:"Erklären",closeTitle:"CastReader auf {domain} deaktivieren?",closeSession:"Ja, für diese Sitzung",closeDomain:"Ja, ab jetzt immer",closeCancel:"Nicht deaktivieren",selectionReaderTitle:"Auswahl vorlesen",stateOn:"An",stateOff:"Aus",ytSourceTitle:"Wähle den vorzulesenden Inhalt",ytCaptions:"🎬 Untertitel anhören",ytRecommended:"Empfohlen",ytPage:"📄 Seite anhören",notSignedIn:"Nicht angemeldet",signIn:"Anmelden",enablePro:"Pro aktivieren",quotaPro:"Erklären · Pro ∞",quotaTip:o=>`Erklären · heute noch ${o}`,listenQuotaPro:"Anhören · Pro ∞",listenQuotaTip:o=>`Anhören · heute noch ${o} Min.`,logout:"↩ Abmelden",todayUsage:"Heutige Nutzung",remainingMinutes:o=>`${o} Min. übrig`,remainingUses:o=>`${o} übrig`},pt:{listen:"Ler esta página",pause:"Pausar",resume:"Continuar",loading:"Carregando…",hideOnPage:"Ocultar nesta página",stop:"Parar",speed:"Velocidade de reprodução",voice:"Voz",lang:"Idioma",readingLang:"Idioma da leitura",sendFeedback:"Enviar feedback",stopReading:"Parar leitura",feedbackTitle:"Feedback rápido",feedbackPlaceholder:"Algo deu errado ou tem uma sugestão?",feedbackEmailPlaceholder:"Seu e-mail (obrigatório)",feedbackEmailRequired:"Digite seu e-mail.",feedbackSend:"Enviar",feedbackSending:"Enviando…",feedbackDone:"Enviado! Obrigado.",feedbackFailed:"Falha no envio. Tente novamente.",brainrotOn:"Visão geral rápida",brainrotOff:"Sair da visão geral",modeRead:"Ler",modeExplain:"Explicar",modeBrainrot:"Leitura rápida",openReader:"Ler um arquivo (PDF / Word / Text)",settings:"Configurações",close:"Fechar",highlightColorTitle:"Cor do destaque",explainLangTitle:"Explicar em",explainAuto:"Automático (meu idioma)",explainFollow:"Seguir a página",depthTitle:"Nível de detalhe",depthOverview:"Visão geral",depthStandard:"Padrão",depthDeep:"Especialista",groupReading:"Leitura",groupExplain:"Explicação",closeTitle:"Desativar o CastReader em {domain}?",closeSession:"Sim, nesta sessão",closeDomain:"Sim, de agora em diante",closeCancel:"Não desativar",selectionReaderTitle:"Leitura da seleção",stateOn:"Ativado",stateOff:"Desativado",ytSourceTitle:"Escolha o que ler",ytCaptions:"🎬 Ouvir as legendas",ytRecommended:"Recomendado",ytPage:"📄 Ouvir a página",notSignedIn:"Não conectado",signIn:"Entrar",enablePro:"Ativar Pro",quotaPro:"Explicar · Pro ∞",quotaTip:o=>`Explicar · ${o} restantes hoje`,listenQuotaPro:"Ouvir · Pro ∞",listenQuotaTip:o=>`Ouvir · ${o} min restantes hoje`,logout:"↩ Sair",todayUsage:"Uso de hoje",remainingMinutes:o=>`${o} min restantes`,remainingUses:o=>`${o} restantes`},it:{listen:"Leggi questa pagina",pause:"Pausa",resume:"Riprendi",loading:"Caricamento…",hideOnPage:"Nascondi in questa pagina",stop:"Interrompi",speed:"Velocità di riproduzione",voice:"Voce",lang:"Lingua",readingLang:"Lingua di lettura",sendFeedback:"Invia feedback",stopReading:"Interrompi lettura",feedbackTitle:"Feedback rapido",feedbackPlaceholder:"Qualcosa non va o hai un suggerimento?",feedbackEmailPlaceholder:"La tua e-mail (obbligatoria)",feedbackEmailRequired:"Inserisci la tua e-mail.",feedbackSend:"Invia",feedbackSending:"Invio…",feedbackDone:"Inviato! Grazie.",feedbackFailed:"Invio non riuscito. Riprova.",brainrotOn:"Panoramica rapida",brainrotOff:"Esci dalla panoramica",modeRead:"Leggi",modeExplain:"Spiega",modeBrainrot:"Lettura rapida",openReader:"Leggi un file (PDF / Word / Text)",settings:"Impostazioni",close:"Chiudi",highlightColorTitle:"Colore evidenziazione",explainLangTitle:"Spiega in",explainAuto:"Automatico (la mia lingua)",explainFollow:"Segui la pagina",depthTitle:"Livello di dettaglio",depthOverview:"Panoramica",depthStandard:"Standard",depthDeep:"Esperto",groupReading:"Lettura",groupExplain:"Spiegazione",closeTitle:"Disattivare CastReader su {domain}?",closeSession:"Sì, per questa sessione",closeDomain:"Sì, da ora in poi",closeCancel:"Non disattivare",selectionReaderTitle:"Lettura della selezione",stateOn:"Attivo",stateOff:"Disattivo",ytSourceTitle:"Scegli cosa leggere",ytCaptions:"🎬 Ascolta i sottotitoli",ytRecommended:"Consigliato",ytPage:"📄 Ascolta la pagina",notSignedIn:"Accesso non effettuato",signIn:"Accedi",enablePro:"Attiva Pro",quotaPro:"Spiega · Pro ∞",quotaTip:o=>`Spiega · ${o} rimasti oggi`,listenQuotaPro:"Ascolta · Pro ∞",listenQuotaTip:o=>`Ascolta · ${o} min rimasti oggi`,logout:"↩ Esci",todayUsage:"Utilizzo di oggi",remainingMinutes:o=>`${o} min rimasti`,remainingUses:o=>`${o} rimasti`},hi:{listen:"यह पेज़ पढ़ें",pause:"रोकें",resume:"जारी रखें",loading:"लोड हो रहा है…",hideOnPage:"इस पेज़ पर छिपाएँ",stop:"बंद करें",speed:"प्लेबैक गति",voice:"आवाज़",lang:"भाषा",readingLang:"पढ़ने की भाषा",sendFeedback:"फ़ीडबैक भेजें",stopReading:"पढ़ना बंद करें",feedbackTitle:"त्वरित फ़ीडबैक",feedbackPlaceholder:"कोई समस्या या सुझाव?",feedbackEmailPlaceholder:"आपका ईमेल (आवश्यक)",feedbackEmailRequired:"अपना ईमेल दर्ज करें।",feedbackSend:"भेजें",feedbackSending:"भेजा जा रहा है…",feedbackDone:"भेज दिया! धन्यवाद।",feedbackFailed:"भेजना विफल। फिर कोशिश करें।",brainrotOn:"त्वरित सारांश",brainrotOff:"सारांश बंद करें",modeRead:"पढ़ें",modeExplain:"समझाएँ",modeBrainrot:"तेज़ पठन",openReader:"फ़ाइल पढ़ें (PDF / Word / Text)",settings:"सेटिंग्स",close:"बंद करें",highlightColorTitle:"हाइलाइट का रंग",explainLangTitle:"इस भाषा में समझाएँ",explainAuto:"ऑटो (मेरी भाषा)",explainFollow:"पेज़ का अनुसरण",depthTitle:"विस्तार स्तर",depthOverview:"सारांश",depthStandard:"मानक",depthDeep:"विशेषज्ञ",groupReading:"पठन",groupExplain:"व्याख्या",closeTitle:"{domain} पर CastReader बंद करें?",closeSession:"हाँ, इस सत्र के लिए",closeDomain:"हाँ, अब से",closeCancel:"बंद न करें",selectionReaderTitle:"चयन पढ़ना",stateOn:"चालू",stateOff:"बंद",ytSourceTitle:"क्या पढ़ना है चुनें",ytCaptions:"🎬 कैप्शन सुनें",ytRecommended:"सुझावित",ytPage:"📄 पेज़ सुनें",notSignedIn:"साइन इन नहीं",signIn:"साइन इन",enablePro:"Pro चालू करें",quotaPro:"समझाएँ · Pro ∞",quotaTip:o=>`समझाएँ · आज ${o} बाकी`,listenQuotaPro:"सुनें · Pro ∞",listenQuotaTip:o=>`सुनें · आज ${o} मिनट बाकी`,logout:"↩ साइन आउट",todayUsage:"आज का उपयोग",remainingMinutes:o=>`${o} मिनट बाकी`,remainingUses:o=>`${o} बाकी`}},W=[{code:"en",label:"English"},{code:"zh",label:"中文"},{code:"ja",label:"日本語"},{code:"es",label:"Español"},{code:"fr",label:"Français"},{code:"de",label:"Deutsch"},{code:"pt",label:"Português"},{code:"it",label:"Italiano"},{code:"hi",label:"हिन्दी"}],U=[{code:"auto"},{code:"follow"},{code:"zh",nativeLabel:"中文"},{code:"en",nativeLabel:"English"},{code:"ja",nativeLabel:"日本語"},{code:"es",nativeLabel:"Español"},{code:"fr",nativeLabel:"Français"},{code:"de",nativeLabel:"Deutsch"},{code:"it",nativeLabel:"Italiano"},{code:"pt",nativeLabel:"Português"},{code:"hi",nativeLabel:"हिन्दी"}];class Oe{constructor(e,t){g(this,"host");g(this,"shadow");g(this,"panel");g(this,"primaryBtn");g(this,"primaryTooltip");g(this,"listenHint");g(this,"listenHintTimer",null);g(this,"secondaryRow");g(this,"speedBtn");g(this,"explainBtn");g(this,"settingsBtn");g(this,"settingsPopover");g(this,"currentMode","read");g(this,"brainTooltip");g(this,"stopConfirmPopover");g(this,"feedbackPopover");g(this,"youtubeSourcePopover");g(this,"llmAutoActive",!1);g(this,"onboardingActive",!1);g(this,"hoverExpanded",!1);g(this,"hoverCollapseTimer",null);g(this,"stopBtn");g(this,"speedPopover");g(this,"noticePopover");g(this,"ratingPopover");g(this,"closePopover");g(this,"closePageBtn");g(this,"state","idle");g(this,"callbacks");g(this,"labels");g(this,"uiLanguage","en");g(this,"currentSpeed",se);g(this,"currentVoiceId",null);g(this,"currentExplainLang","auto");g(this,"currentDepth","standard");g(this,"settingsView","root");g(this,"currentHighlightColor",me);g(this,"selectionReaderOn",!0);g(this,"voiceOptions",[]);g(this,"currentDetectedLang","en");g(this,"proEntitled",!0);g(this,"proBannerDismissalLoaded",!1);g(this,"proBannerDismissed",!1);g(this,"proBannerImpressionTracked",!1);g(this,"account",null);g(this,"accountMenuOpen",!1);g(this,"listenQuota",null);g(this,"quickreadQuota",null);g(this,"documentClickHandler",null);g(this,"releaseSettingsSurface",null);g(this,"lastAppliedState",null);g(this,"qrForeignTip",null);const n=j(e);this.uiLanguage=n,this.labels=oe[n]||oe.en,this.callbacks=t,this.host=document.createElement("div"),this.host.id="castreader-page-trigger",this.host.setAttribute("data-castreader","page-trigger"),this.shadow=this.host.attachShadow({mode:"open"});const i=document.createElement("style");i.textContent=J,this.shadow.appendChild(i);const a=document.createElement("div");a.className="host-wrap",this.panel=this.buildPanel(),a.appendChild(this.panel),this.shadow.appendChild(a),this.applyState(),this.loadProBannerDismissal()}attach(e=document.body){this.host.isConnected||e.appendChild(this.host),this.documentClickHandler||(this.documentClickHandler=t=>{t.composedPath().includes(this.host)||this.closeAllPopovers()},document.addEventListener("click",this.documentClickHandler,!0))}detach(){this.documentClickHandler&&(document.removeEventListener("click",this.documentClickHandler,!0),this.documentClickHandler=null),this.host.isConnected&&this.host.remove()}setVisible(e){this.host.style.display=e?"":"none"}setState(e){this.state!==e&&(this.state=e,this.applyState())}setSpeed(e){this.currentSpeed=e,this.refreshSettingsPopover()}setVoiceOptions(e,t){this.voiceOptions=e,this.currentVoiceId=t,this.refreshSettingsPopover()}showVoiceLibrary(e){this.openVoiceLibrary(e)}setProEntitlement(e,t){var a,s,p,h,r;const n=t??null,i=(((a=this.account)==null?void 0:a.id)||"")!==((n==null?void 0:n.id)||"")||(((s=this.account)==null?void 0:s.userId)||"")!==((n==null?void 0:n.userId)||"")||(((p=this.account)==null?void 0:p.name)||"")!==((n==null?void 0:n.name)||"")||(((h=this.account)==null?void 0:h.email)||"")!==((n==null?void 0:n.email)||"")||(((r=this.account)==null?void 0:r.image)||"")!==((n==null?void 0:n.image)||"");this.proEntitled===e&&!i||(this.proEntitled=e,this.account=n,this.refreshSettingsPopover())}setCurrentLang(e){this.currentDetectedLang=e,this.refreshSettingsPopover()}setMode(e){var t;this.currentMode=e,(t=this.explainBtn)==null||t.classList.toggle("active",e==="explain")}setLLMAutoActive(e){this.llmAutoActive=e,this.primaryBtn&&(this.primaryBtn.classList.toggle("llm-auto-on",e),this.applyState())}showNoticePopover(e){this.closeAllPopovers();const t=[];e.secondaryLabel&&t.push(`<button class="popover-notice-btn secondary" data-action="secondary">${e.secondaryLabel}</button>`),e.primaryLabel&&t.push(`<button class="popover-notice-btn primary" data-action="primary">${e.primaryLabel}</button>`),this.noticePopover.innerHTML=`
      <div class="popover-notice-title">${e.title}</div>
      <div class="popover-notice-body">${e.body}</div>
      <div class="popover-notice-actions">${t.join("")}</div>
    `,this.noticePopover.querySelectorAll("button[data-action]").forEach(n=>{n.addEventListener("click",i=>{var s,p;i.preventDefault(),i.stopPropagation();const a=n.dataset.action;this.closeAllPopovers(),a==="primary"&&((s=e.onPrimary)==null||s.call(e)),a==="secondary"&&((p=e.onSecondary)==null||p.call(e))})}),this.noticePopover.classList.add("open")}endExplainOnboarding(){this.onboardingActive&&(this.onboardingActive=!1,this.applyState())}showExplainOnboarding(e){var a;this.closeAllPopovers(),this.onboardingActive=!0,this.applyState();const t=this.currentExplainLang||"auto",n=U.map(s=>{const p=s.code==="auto"?this.labels.explainAuto:s.code==="follow"?this.labels.explainFollow:s.nativeLabel||s.code;return`<option value="${s.code}"${s.code===t?" selected":""}>${p}</option>`}).join("");this.noticePopover.innerHTML=`
      <div class="popover-notice-title">${e.title}</div>
      <div class="popover-notice-body">${e.body}</div>
      <div class="popover-notice-body" style="margin-top:10px;display:flex;align-items:center;gap:8px;">
        <span style="opacity:.85;white-space:nowrap;">${this.labels.explainLangTitle}</span>
        <select class="qr-onboard-lang" style="flex:1;min-width:0;padding:4px 6px;border-radius:6px;border:1px solid rgba(127,127,127,.4);background:rgba(127,127,127,.12);color:inherit;font-size:12px;">${n}</select>
      </div>
      <div class="popover-notice-actions">
        <button class="popover-notice-btn primary" data-action="primary">${e.confirmLabel}</button>
      </div>
    `;const i=this.noticePopover.querySelector("select.qr-onboard-lang");i==null||i.addEventListener("click",s=>s.stopPropagation()),i==null||i.addEventListener("change",s=>s.stopPropagation()),(a=this.noticePopover.querySelector('button[data-action="primary"]'))==null||a.addEventListener("click",s=>{var h,r,d;s.preventDefault(),s.stopPropagation();const p=(i==null?void 0:i.value)||t;this.setExplainLang(p),(r=(h=this.callbacks).onExplainLangChange)==null||r.call(h,p),this.closeAllPopovers(),(d=e.onDone)==null||d.call(e,p)}),this.noticePopover.classList.add("open")}showYouTubeSourcePopover(){this.closeAllPopovers(),this.youtubeSourcePopover.innerHTML=`
      <div class="popover-notice-title">${this.labels.ytSourceTitle}</div>
      <div class="popover-notice-actions" style="flex-direction:column;align-items:stretch;gap:5px;">
        <button class="popover-notice-btn primary" data-action="captions"
          style="display:flex;align-items:center;justify-content:space-between;text-align:left;">
          ${this.labels.ytCaptions}
          <span style="font-size:9px;background:rgba(255,255,255,0.22);border-radius:3px;padding:1px 5px;margin-left:6px;flex-shrink:0;">${this.labels.ytRecommended}</span>
        </button>
        <button class="popover-notice-btn secondary" data-action="page" style="text-align:left;">
          ${this.labels.ytPage}
        </button>
      </div>
    `,this.youtubeSourcePopover.querySelectorAll("button[data-action]").forEach(e=>{e.addEventListener("click",t=>{t.preventDefault(),t.stopPropagation();const n=e.dataset.action;this.closeAllPopovers(),this.callbacks.onStart({youtubeSource:n})})}),this.youtubeSourcePopover.classList.add("open")}showRatingPopover(e){var n;this.closeAllPopovers();const t=[1,2,3,4,5].map(i=>`<span class="popover-rating-star" data-stars="${i}">★</span>`).join("");this.ratingPopover.innerHTML=`
      <div class="popover-rating-title">${e.title}</div>
      <div class="popover-rating-stars">${t}</div>
      <button class="popover-rating-dismiss">${e.dismissLabel}</button>
    `,this.ratingPopover.querySelectorAll(".popover-rating-star").forEach(i=>{i.addEventListener("click",a=>{a.preventDefault(),a.stopPropagation();const s=Number(i.dataset.stars||"0");this.closeAllPopovers(),e.onRate(s)})}),(n=this.ratingPopover.querySelector(".popover-rating-dismiss"))==null||n.addEventListener("click",i=>{var a;i.preventDefault(),i.stopPropagation(),this.closeAllPopovers(),(a=e.onDismiss)==null||a.call(e)}),this.ratingPopover.classList.add("open")}showCloseConfirmToast(e){var s,p;let t=document.getElementById("castreader-toast-host");if(!t){t=document.createElement("div"),t.id="castreader-toast-host",t.setAttribute("data-castreader","toast-host");const h=t.attachShadow({mode:"open"}),r=document.createElement("style");r.textContent=J,h.appendChild(r);const d=document.createElement("div");d.className="toast-host",h.appendChild(d),document.body.appendChild(t)}const n=t.shadowRoot;if(!n)return;const i=n.querySelector(".toast-host");if(!i)return;i.innerHTML=`
      <div class="toast">
        <div class="toast-title">${e.title}</div>
        <div class="toast-body">${e.body}</div>
        <div class="toast-actions">
          <button class="toast-btn secondary" data-action="secondary">${e.secondaryLabel}</button>
          <button class="toast-btn primary" data-action="primary">${e.primaryLabel}</button>
        </div>
      </div>
    `;const a=()=>{i.innerHTML=""};(s=i.querySelector('button[data-action="primary"]'))==null||s.addEventListener("click",h=>{h.preventDefault(),h.stopPropagation(),e.onPrimary(),a()}),(p=i.querySelector('button[data-action="secondary"]'))==null||p.addEventListener("click",h=>{h.preventDefault(),h.stopPropagation(),e.onSecondary(),a()}),setTimeout(()=>a(),6e3)}showClosePopover(){this.closeAllPopovers();const e=(typeof location<"u"?location.hostname:"")||"this site",t=this.labels.closeTitle.replace("{domain}",e);this.closePopover.innerHTML=`
      <div class="popover-close-title">${t}</div>
      <button class="popover-close-btn" data-mode="session">${this.labels.closeSession}</button>
      <button class="popover-close-btn" data-mode="domain">${this.labels.closeDomain}</button>
      <div class="popover-close-divider"></div>
      <button class="popover-close-btn cancel" data-mode="cancel">${this.labels.closeCancel}</button>
    `,this.closePopover.querySelectorAll("button[data-mode]").forEach(n=>{n.addEventListener("click",i=>{var s,p;i.preventDefault(),i.stopPropagation();const a=n.dataset.mode;this.closeAllPopovers(),a!=="cancel"&&((p=(s=this.callbacks).onCloseRequest)==null||p.call(s,a))})}),this.closePopover.classList.add("open")}destroy(){this.closeAllPopovers(),this.detach()}buildPanel(){const e=document.createElement("div");e.className="player-panel",this.closePageBtn=document.createElement("button"),this.closePageBtn.className="close-page-btn",this.closePageBtn.type="button",this.closePageBtn.title=this.labels.hideOnPage,this.closePageBtn.setAttribute("aria-label",this.labels.hideOnPage),this.closePageBtn.innerHTML=Se,this.closePageBtn.addEventListener("click",i=>{i.preventDefault(),i.stopPropagation(),this.showClosePopover()}),e.appendChild(this.closePageBtn);const t=document.createElement("div");t.className="has-tooltip",t.style.position="relative",t.style.display="flex",this.primaryBtn=document.createElement("button"),this.primaryBtn.className="primary-btn",this.primaryBtn.type="button",this.primaryBtn.innerHTML=ee,this.primaryBtn.setAttribute("aria-label",this.labels.listen),this.primaryBtn.addEventListener("click",i=>{i.preventDefault(),i.stopPropagation(),this.dismissListenHint(),this.handlePrimaryClick()}),this.primaryTooltip=document.createElement("div"),this.primaryTooltip.className="tooltip",this.primaryTooltip.textContent=this.labels.listen,this.listenHint=document.createElement("div"),this.listenHint.className="listen-hint",t.appendChild(this.primaryBtn),t.appendChild(this.primaryTooltip),t.appendChild(this.listenHint),e.appendChild(t),this.secondaryRow=document.createElement("div"),this.secondaryRow.style.display="flex",this.secondaryRow.style.flexDirection="column",this.secondaryRow.style.alignItems="center",this.secondaryRow.style.gap="2px";const n=(i,a,s,p)=>{const h=document.createElement("button");h.className="ctrl-btn "+i,h.type="button",h.innerHTML=a,h.setAttribute("aria-label",s),h.addEventListener("click",u=>{u.preventDefault(),u.stopPropagation(),p()});const r=document.createElement("div");r.className="has-tooltip ctrl-wrap";const d=document.createElement("div");return d.className="tooltip",d.textContent=s,r.appendChild(h),r.appendChild(d),this.secondaryRow.appendChild(r),h};return this.explainBtn=n("mode-btn explain-btn",Re,this.labels.modeExplain,()=>{var i,a;this.setMode("explain"),(a=(i=this.callbacks).onExplainMode)==null||a.call(i)}),n("read-doc-btn",Ae,this.labels.openReader,()=>{var i,a;(a=(i=this.callbacks).onOpenReader)==null||a.call(i)}),this.settingsBtn=n("settings-btn",De,this.labels.settings,()=>{this.toggleSettingsPopover()}),e.appendChild(this.secondaryRow),this.settingsPopover=document.createElement("div"),this.settingsPopover.className="popover settings-popover",this.noticePopover=document.createElement("div"),this.noticePopover.className="popover popover-notice",this.ratingPopover=document.createElement("div"),this.ratingPopover.className="popover popover-rating",this.closePopover=document.createElement("div"),this.closePopover.className="popover popover-close",this.stopConfirmPopover=document.createElement("div"),this.stopConfirmPopover.className="popover stop-confirm-popover",this.feedbackPopover=document.createElement("div"),this.feedbackPopover.className="popover feedback-popover",this.youtubeSourcePopover=document.createElement("div"),this.youtubeSourcePopover.className="popover popover-notice",e.appendChild(this.settingsPopover),e.appendChild(this.noticePopover),e.appendChild(this.ratingPopover),e.appendChild(this.closePopover),e.appendChild(this.stopConfirmPopover),e.appendChild(this.feedbackPopover),e.appendChild(this.youtubeSourcePopover),this.refreshSettingsPopover(),e.addEventListener("mouseenter",()=>{this.hoverCollapseTimer&&(clearTimeout(this.hoverCollapseTimer),this.hoverCollapseTimer=null),this.hoverExpanded||(this.hoverExpanded=!0,this.applyState())}),e.addEventListener("mouseleave",()=>{this.hoverCollapseTimer&&clearTimeout(this.hoverCollapseTimer),this.hoverCollapseTimer=setTimeout(()=>{this.hoverCollapseTimer=null,!this.isAnyPopoverOpen()&&this.hoverExpanded&&(this.hoverExpanded=!1,this.applyState())},350)}),e}showListenHint(e,t=!1){this.listenHint&&(this.listenHint.textContent=e,this.listenHint.classList.add("show"),this.listenHintTimer&&clearTimeout(this.listenHintTimer),this.listenHintTimer=t?null:setTimeout(()=>this.dismissListenHint(),5e3))}dismissListenHint(){var e;this.listenHintTimer&&(clearTimeout(this.listenHintTimer),this.listenHintTimer=null),(e=this.listenHint)==null||e.classList.remove("show")}isAnyPopoverOpen(){return[this.settingsPopover,this.noticePopover,this.ratingPopover,this.closePopover,this.stopConfirmPopover,this.feedbackPopover,this.youtubeSourcePopover].some(e=>e==null?void 0:e.classList.contains("open"))}applyState(){const e=this.state,t=e==="idle",n=e==="loading";this.panel.classList.toggle("idle",t);let i,a;n?(i=Te,a=this.labels.loading):e==="playing"?(i=Ee,a=this.labels.pause):e==="paused"?(i=Ce,a=this.labels.resume):(i=ee,a=this.listenTipText()),this.primaryBtn.innerHTML=i,this.primaryBtn.classList.toggle("loading",n),this.primaryTooltip.textContent=a,this.primaryBtn.setAttribute("aria-label",a);const s=!t||this.llmAutoActive||this.onboardingActive||this.hoverExpanded;this.secondaryRow.style.display=s?"flex":"none",this.closePageBtn.style.display=t&&!this.llmAutoActive?"":"none",t&&this.lastAppliedState!=="idle"&&!this.llmAutoActive&&this.closeAllPopovers(),this.lastAppliedState=e}toggleSettingsPopover(){var t,n;const e=!this.settingsPopover.classList.contains("open");this.closeAllPopovers(),e&&(this.settingsView="root",this.refreshSettingsPopover(),this.settingsPopover.classList.add("open"),this.releaseSettingsSurface=be("page-settings",()=>this.closeAllPopovers()),this.trackProBannerImpressionIfVisible(),(n=(t=this.callbacks).onPanelOpen)==null||n.call(t))}openVoiceLibrary(e={}){var n,i;const t=this.currentDetectedLang==="cn"?"zh":this.currentDetectedLang;this.closeAllPopovers(),fe({voices:this.voiceOptions.map(a=>({id:a.id,name:a.name,language:a.language||t,locale:a.locale,accent:a.accent,gender:a.gender||"neutral",tier:a.tier||(a.pro?"pro":"free"),selectable:!0,tags:a.tags||[],collection:a.collection,recommended:a.recommended,qualityGrade:a.qualityGrade,description:a.description,descriptionZh:a.descriptionZh,bestFor:a.bestFor,sampleUrl:a.sampleUrl,avatar:a.avatar})),currentVoiceId:this.currentVoiceId,initialLanguage:t,lockLanguage:e.lockLanguage,proEntitled:this.proEntitled,resolveProEntitlement:this.callbacks.resolveProEntitlement,locale:j(typeof chrome<"u"&&((i=(n=chrome.i18n)==null?void 0:n.getUILanguage)==null?void 0:i.call(n))||"en"),onSelect:a=>{var s,p;(p=(s=this.callbacks).onVoiceChange)==null||p.call(s,a.id,a.language)},onUpgrade:a=>{var s,p;return(p=(s=this.callbacks).onUpgrade)==null?void 0:p.call(s,"voice",a.name)},onPreviewStart:()=>{var a,s;return(s=(a=this.callbacks).onVoicePreviewStart)==null?void 0:s.call(a)},onPreviewEnd:()=>{var a,s;return(s=(a=this.callbacks).onVoicePreviewEnd)==null?void 0:s.call(a)}})}closeAllPopovers(){var e,t,n,i,a,s,p;this.endExplainOnboarding(),this.settingsPopover.classList.remove("open"),(e=this.noticePopover)==null||e.classList.remove("open"),(t=this.ratingPopover)==null||t.classList.remove("open"),(n=this.closePopover)==null||n.classList.remove("open"),(i=this.stopConfirmPopover)==null||i.classList.remove("open"),(a=this.feedbackPopover)==null||a.classList.remove("open"),(s=this.youtubeSourcePopover)==null||s.classList.remove("open"),(p=this.releaseSettingsSurface)==null||p.call(this),this.releaseSettingsSurface=null}shouldShowProBanner(){return this.proBannerDismissalLoaded&&!this.proBannerDismissed&&!this.proEntitled}async loadProBannerDismissal(){try{const e=await chrome.storage.local.get(V);this.proBannerDismissed=e[V]===!0}catch{this.proBannerDismissed=!1}finally{this.proBannerDismissalLoaded=!0,this.refreshSettingsPopover(),this.trackProBannerImpressionIfVisible()}}trackProBannerImpressionIfVisible(){var e;this.proBannerImpressionTracked||!this.shouldShowProBanner()||!((e=this.settingsPopover)!=null&&e.classList.contains("open"))||(this.proBannerImpressionTracked=!0,B("feature_use",{feature:"settings_pro_banner_impression"}))}buildProBanner(){if(!this.shouldShowProBanner())return null;const e=G(this.uiLanguage),t=document.createElement("div");t.className="settings-pro-banner";const n=document.createElement("button");n.type="button",n.className="settings-pro-banner-action",n.setAttribute("aria-label",e.settingsCta);const i=document.createElement("span");i.className="settings-pro-banner-gift",i.setAttribute("aria-hidden","true"),i.textContent="🎁";const a=document.createElement("span");a.className="settings-pro-banner-copy";const s=document.createElement("strong");s.textContent=e.settingsCta;const p=document.createElement("span");p.textContent=e.bannerBody,a.append(s,p);const h=document.createElement("span");h.className="settings-pro-banner-arrow",h.setAttribute("aria-hidden","true"),h.textContent="→",n.append(i,a,h),n.addEventListener("click",d=>{var u,m;d.preventDefault(),d.stopPropagation(),B("feature_use",{feature:"settings_pro_banner_clicked"}),(m=(u=this.callbacks).onUpgrade)==null||m.call(u,"settings","settings_banner")});const r=document.createElement("button");return r.type="button",r.className="settings-pro-banner-dismiss",r.setAttribute("aria-label",e.dismissBanner),r.title=e.dismissBanner,r.textContent="×",r.addEventListener("click",d=>{d.preventDefault(),d.stopPropagation(),this.proBannerDismissed=!0,B("feature_use",{feature:"settings_pro_banner_dismissed"}),chrome.storage.local.set({[V]:!0}).catch(()=>{}),this.refreshSettingsPopover()}),t.append(n,r),t}refreshSettingsPopover(){var h;if(!this.settingsPopover)return;this.settingsPopover.innerHTML="";const e=this.currentDetectedLang==="cn"?"zh":this.currentDetectedLang,t=this.voiceOptions.some(r=>r.language===e);if(this.settingsView==="root"){const r=document.createElement("div");r.className="settings-pro-bar",r.style.cssText="display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 10px;margin:-2px -2px 9px;border-radius:10px;background:rgba(17,24,39,.045);";const d=document.createElement("button");d.type="button",d.style.cssText="display:flex;align-items:center;gap:8px;min-width:0;flex:1 1 auto;border:none;background:transparent;cursor:pointer;padding:0;font:inherit;color:inherit;";const u=document.createElement("div");u.style.cssText="width:26px;height:26px;border-radius:50%;flex:none;overflow:hidden;display:flex;align-items:center;justify-content:center;background:#e7e7ea;color:#77777f;";const m=()=>{u.innerHTML=Le;const c=u.querySelector("svg");c instanceof SVGElement&&(c.style.width="14px",c.style.height="14px",c.style.strokeWidth="2")};if((h=this.account)!=null&&h.image){const c=document.createElement("img");c.src=this.account.image,c.referrerPolicy="no-referrer",c.style.cssText="width:100%;height:100%;object-fit:cover;",c.addEventListener("error",()=>{c.remove(),m()}),u.appendChild(c)}else m();const y=!!this.account,k=document.createElement("span");k.textContent=y?this.account.name||this.account.email.split("@")[0]||"Account":this.labels.signIn,k.style.cssText="font-weight:600;font-size:12px;line-height:1.3;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;text-align:left;"+(y?"":"color:#38383d;"),d.setAttribute("aria-label",y?k.textContent:this.labels.signIn),d.appendChild(u),d.appendChild(k),d.addEventListener("click",c=>{c.preventDefault(),c.stopPropagation(),this.account?(this.accountMenuOpen=!this.accountMenuOpen,this.refreshSettingsPopover()):this.callbacks.onLogin()}),r.appendChild(d);const b=document.createElement("button");if(b.type="button",b.style.cssText="display:flex;align-items:flex-end;justify-content:center;flex-direction:column;gap:1px;flex:none;max-width:170px;border:none;border-left:1px solid rgba(17,24,39,.1);background:transparent;cursor:pointer;padding:2px 0 2px 10px;font:inherit;color:inherit;text-align:right;",this.proEntitled){const c=document.createElement("span");c.textContent="PRO",c.style.cssText="padding:2px 7px;border:1px solid rgba(234,88,12,.22);border-radius:6px;letter-spacing:.3px;background:#fff1eb;color:#d64b16;font-weight:700;font-size:9px;line-height:1.5;",b.appendChild(c)}else{const c=G(this.uiLanguage),P=document.createElement("span");P.textContent=c.freePlan,P.style.cssText="font-weight:500;font-size:9.5px;line-height:1.25;color:#7a7a80;white-space:nowrap;";const T=document.createElement("span");T.textContent=`${c.settingsCta} ›`,T.style.cssText="font-weight:650;font-size:10.5px;line-height:1.3;color:#d64b16;white-space:nowrap;",b.append(P,T)}if(b.addEventListener("click",c=>{var P,T;c.preventDefault(),c.stopPropagation(),this.proEntitled?this.callbacks.onManagePro():(T=(P=this.callbacks).onUpgrade)==null||T.call(P,"settings")}),r.appendChild(b),this.settingsPopover.appendChild(r),this.account&&this.accountMenuOpen){const c=document.createElement("button");c.className="popover-item",c.type="button",c.textContent=this.labels.logout,c.style.cssText="color:#d23f3f;font-weight:600;",c.addEventListener("click",P=>{var T,N;P.preventDefault(),P.stopPropagation(),this.accountMenuOpen=!1,(N=(T=this.callbacks).onLogout)==null||N.call(T),this.closeAllPopovers()}),this.settingsPopover.appendChild(c)}const f=this.buildProBanner();f&&this.settingsPopover.appendChild(f);const C=this.buildUsageCard();C&&this.settingsPopover.appendChild(C);const A=[{key:"speed",group:"read",label:this.labels.speed,value:$(this.currentSpeed)},t?{key:"voice",group:"read",label:this.labels.voice,value:this.currentVoiceValueLabel()}:{key:"language",group:"read",label:this.labels.readingLang,value:this.currentReadingLanguageLabel()},{key:"color",group:"read",label:this.labels.highlightColorTitle,value:this.currentHighlightColorLabel(),swatch:this.currentHighlightColor},{key:"selection",group:"read",label:this.labels.selectionReaderTitle,value:this.selectionReaderOn?this.labels.stateOn:this.labels.stateOff},{key:"explain",group:"explain",label:this.labels.explainLangTitle,value:this.currentExplainValueLabel()},{key:"depth",group:"explain",label:this.labels.depthTitle,value:this.currentDepthValueLabel()}];let z="";for(const c of A){if(c.group!==z){z=c.group;const O=document.createElement("div");O.textContent=c.group==="read"?this.labels.groupReading:this.labels.groupExplain,O.style.cssText="padding:9px 14px 3px;font-size:11px;font-weight:600;opacity:.4;letter-spacing:.03em;",this.settingsPopover.appendChild(O)}const P=document.createElement("button");P.className="popover-item popover-nav-row",P.type="button";const T=document.createElement("span");T.textContent=c.label;const N=document.createElement("span");if(N.className="popover-nav-value",c.swatch){const O=document.createElement("span");O.className="popover-swatch",O.style.background=c.swatch,N.appendChild(O)}N.appendChild(document.createTextNode(c.key==="selection"?c.value:`${c.value} ›`)),P.appendChild(T),P.appendChild(N),P.addEventListener("click",O=>{var _,L;O.preventDefault(),O.stopPropagation(),c.key==="selection"?(this.selectionReaderOn=!this.selectionReaderOn,(L=(_=this.callbacks).onSelectionReaderToggle)==null||L.call(_,this.selectionReaderOn),this.refreshSettingsPopover()):c.key==="voice"?this.openVoiceLibrary():(this.settingsView=c.key,this.refreshSettingsPopover())}),this.settingsPopover.appendChild(P)}const v=document.createElement("button");v.className="popover-item",v.type="button",v.textContent=`↻ ${Z[this.uiLanguage]||Z.en}`,v.addEventListener("click",c=>{c.preventDefault(),c.stopPropagation(),this.closeAllPopovers(),chrome.runtime.sendMessage({type:"ONBOARDING_GET_BOOTSTRAP"}).then(async P=>{if(!(P!=null&&P.state))return;const T=Date.now();await chrome.runtime.sendMessage({type:"ONBOARDING_OPEN",payload:{entryPoint:"settings_replay",transitionId:`${P.state.onboardingId}:settings-replay:${T.toString(36)}`,expectedRevision:P.state.revision,requestedAt:T}})}).catch(()=>{})}),this.settingsPopover.appendChild(v);const x=document.createElement("div");x.className="popover-divider",x.style.margin="6px 0 4px",this.settingsPopover.appendChild(x);const D=document.createElement("button");D.className="popover-item",D.type="button",D.textContent=`✉ ${this.labels.sendFeedback}`,D.addEventListener("click",c=>{c.preventDefault(),c.stopPropagation(),this.closeAllPopovers(),this.openFeedbackPopover()}),this.settingsPopover.appendChild(D),this.trackProBannerImpressionIfVisible();return}const n=this.settingsView==="speed"?this.labels.speed:this.settingsView==="language"?this.labels.lang:this.settingsView==="color"?this.labels.highlightColorTitle:this.settingsView==="depth"?this.labels.depthTitle:this.labels.explainLangTitle,i=document.createElement("button");i.className="popover-item popover-back-row",i.type="button",i.textContent=`‹ ${n}`,i.addEventListener("click",r=>{r.preventDefault(),r.stopPropagation(),this.settingsView="root",this.refreshSettingsPopover()}),this.settingsPopover.appendChild(i);const a=(r,d,u)=>{const m=document.createElement("button");m.className="popover-item",m.type="button",m.textContent=r,d&&m.classList.add("selected"),m.addEventListener("click",y=>{y.preventDefault(),y.stopPropagation(),u(),this.settingsView="root",this.refreshSettingsPopover()}),this.settingsPopover.appendChild(m)},s=(r,d)=>{const u=document.createElement("button");u.className="popover-item popover-item-locked",u.type="button";const m=document.createElement("span");m.textContent=r;const y=document.createElement("span");y.className="popover-pro-badge",y.textContent=G(this.uiLanguage).compactBadge,u.appendChild(m),u.appendChild(y),u.addEventListener("click",k=>{var b,f;k.preventDefault(),k.stopPropagation(),(f=(b=this.callbacks).onUpgrade)==null||f.call(b,d,r)}),this.settingsPopover.appendChild(u)},p=(r,d,u)=>{const m=document.createElement("button");m.className="popover-item popover-item-expert",m.type="button";const y=document.createElement("span");y.className="popover-expert-main";const k=document.createElement("span");k.className="popover-expert-icon",k.textContent="👑";const b=document.createElement("span");if(b.textContent=r,y.appendChild(k),y.appendChild(b),m.appendChild(y),!this.proEntitled){const f=document.createElement("span");f.className="popover-pro-badge",f.textContent="Pro",m.appendChild(f)}d&&m.classList.add("selected"),m.addEventListener("click",f=>{f.preventDefault(),f.stopPropagation(),u(),this.settingsView="root",this.refreshSettingsPopover()}),this.settingsPopover.appendChild(m)};if(this.settingsView==="speed")for(const r of ve)!this.proEntitled&&r>xe?s($(r),"speed"):a($(r),Math.abs(r-this.currentSpeed)<.01,()=>{var d,u;this.currentSpeed=r,(u=(d=this.callbacks).onSpeedChange)==null||u.call(d,r)});else if(this.settingsView==="language")for(const r of W){const d=this.currentDetectedLang===r.code||r.code==="zh"&&["zh","cn"].includes(this.currentDetectedLang);a(r.label,d,()=>{var u,m;this.currentDetectedLang=r.code,(m=(u=this.callbacks).onLanguageChange)==null||m.call(u,r.code)})}else if(this.settingsView==="explain")for(const r of U){const d=r.code==="auto"?this.labels.explainAuto:r.code==="follow"?this.labels.explainFollow:r.nativeLabel||r.code;a(d,r.code===this.currentExplainLang,()=>{var u,m;this.currentExplainLang=r.code,(m=(u=this.callbacks).onExplainLangChange)==null||m.call(u,r.code)})}else if(this.settingsView==="depth")for(const r of te){const d=()=>{var u,m;this.currentDepth=r.code,(m=(u=this.callbacks).onDepthChange)==null||m.call(u,r.code)};r.code==="deep"?p(this.labels[r.labelKey],r.code===this.currentDepth,d):a(this.labels[r.labelKey],r.code===this.currentDepth,d)}else if(this.settingsView==="color"){const r=Y(this.currentHighlightColor).toLowerCase();for(const d of ye){const u=document.createElement("button");u.className="popover-item popover-swatch-item",u.type="button";const m=document.createElement("span");m.className="popover-swatch",m.style.background=d.hex;const y=document.createElement("span");y.textContent=X(d.hex,this.uiLanguage),u.appendChild(m),u.appendChild(y),d.hex.toLowerCase()===r&&u.classList.add("selected"),u.addEventListener("click",k=>{var b,f;k.preventDefault(),k.stopPropagation(),this.currentHighlightColor=d.hex,(f=(b=this.callbacks).onHighlightColorChange)==null||f.call(b,d.hex),this.settingsView="root",this.refreshSettingsPopover()}),this.settingsPopover.appendChild(u)}}}setHighlightColor(e){var t;this.currentHighlightColor=Y(e),(t=this.settingsPopover)!=null&&t.classList.contains("open")&&this.refreshSettingsPopover()}setSelectionReaderEnabled(e){var t;this.selectionReaderOn=e,(t=this.settingsPopover)!=null&&t.classList.contains("open")&&this.refreshSettingsPopover()}currentHighlightColorLabel(){return X(this.currentHighlightColor,this.uiLanguage)}currentVoiceValueLabel(){var e,t,n;if(this.voiceOptions.length>0){const i=this.currentDetectedLang==="cn"?"zh":this.currentDetectedLang;return((e=this.voiceOptions.find(a=>a.id===this.currentVoiceId))==null?void 0:e.name)||((t=this.voiceOptions.find(a=>a.language===i))==null?void 0:t.name)||"—"}return((n=W.find(i=>i.code===this.currentDetectedLang))==null?void 0:n.label)||this.currentDetectedLang||"—"}currentReadingLanguageLabel(){var t;const e=this.currentDetectedLang==="cn"?"zh":this.currentDetectedLang;return((t=W.find(n=>n.code===e))==null?void 0:t.label)||e||"—"}currentExplainValueLabel(){var e;return this.currentExplainLang==="auto"?this.labels.explainAuto:this.currentExplainLang==="follow"?this.labels.explainFollow:((e=U.find(t=>t.code===this.currentExplainLang))==null?void 0:e.nativeLabel)||this.currentExplainLang}setExplainLang(e){var t;this.currentExplainLang=e||"auto",(t=this.settingsPopover)!=null&&t.classList.contains("open")&&this.refreshSettingsPopover()}currentDepthValueLabel(){var e;return this.labels[((e=te.find(t=>t.code===this.currentDepth))==null?void 0:e.labelKey)||"depthStandard"]}setDepth(e){var t;this.currentDepth=e||"standard",(t=this.settingsPopover)!=null&&t.classList.contains("open")&&this.refreshSettingsPopover()}setQuickreadForeignTip(e){this.qrForeignTip=e,this.quickreadQuota&&this.setQuickreadQuota(this.quickreadQuota)}setQuickreadQuota(e){var t,n;if(this.quickreadQuota=e,e){const i=this.explainBtn.parentElement,a=i==null?void 0:i.querySelector(".tooltip");a&&((t=i==null?void 0:i.querySelector(".qr-pro-badge"))==null||t.remove(),a.textContent=this.qrForeignTip?e.pro?`${this.qrForeignTip} · Pro ∞`:`${this.qrForeignTip} · ${Math.max(0,e.remaining)}/${e.max}`:e.pro?this.labels.quotaPro:this.labels.quotaTip(Math.max(0,e.remaining),e.max))}(n=this.settingsPopover)!=null&&n.classList.contains("open")&&this.refreshSettingsPopover()}listenTipText(){const e=this.listenQuota;if(!e)return this.labels.listen;if(e.pro)return this.labels.listenQuotaPro;const t=Math.ceil(Math.max(0,e.remaining)/60),n=Math.round(e.limit/60);return this.labels.listenQuotaTip(t,n)}setListenQuota(e){var t;this.listenQuota=e,this.applyState(),(t=this.settingsPopover)!=null&&t.classList.contains("open")&&this.refreshSettingsPopover()}buildUsageCard(){const e=this.listenQuota,t=this.quickreadQuota;if(!!(e!=null&&e.pro||t!=null&&t.pro||this.proEntitled)||!e&&!t)return null;const i=document.createElement("div");i.style.cssText="margin:8px 14px 4px;padding:11px 12px;border-radius:10px;background:color-mix(in oklab,currentColor 5%,transparent);display:flex;flex-direction:column;gap:9px;";const a=document.createElement("div");a.style.cssText="font-size:11px;font-weight:600;opacity:.5;letter-spacing:.03em;",a.textContent=this.labels.todayUsage,i.appendChild(a);const s=(p,h,r,d,u)=>{const m=d>0?Math.min(1,Math.max(0,r/d)):0,y=document.createElement("div");y.style.cssText="display:flex;flex-direction:column;gap:4px;";const k=document.createElement("div");k.style.cssText="display:flex;align-items:center;justify-content:space-between;font-size:12px;";const b=document.createElement("span");b.style.cssText="display:flex;align-items:center;gap:6px;font-weight:500;",b.textContent=`${p} ${h}`;const f=document.createElement("span");f.style.cssText="opacity:.6;font-variant-numeric:tabular-nums;",f.textContent=u,k.appendChild(b),k.appendChild(f);const C=document.createElement("div");C.style.cssText="height:5px;border-radius:3px;overflow:hidden;background:color-mix(in oklab,currentColor 12%,transparent);";const A=document.createElement("div"),z=m>=.85;A.style.cssText=`height:100%;width:${Math.round(m*100)}%;border-radius:3px;transition:width .3s;background:${z?"#e0533a":"linear-gradient(90deg,#FD5F01,#ff8a3d)"};`,C.appendChild(A),y.appendChild(k),y.appendChild(C),i.appendChild(y)};if(e){const p=Math.max(0,e.limit-e.remaining),h=Math.ceil(Math.max(0,e.remaining)/60);s("🎧",this.labels.groupReading,p,e.limit,this.labels.remainingMinutes(h))}return t&&s("✨",this.labels.groupExplain,t.used,t.max,this.labels.remainingUses(t.remaining)),i}toggleStopConfirmPopover(){const e=!this.stopConfirmPopover.classList.contains("open");if(this.closeAllPopovers(),!e)return;this.stopConfirmPopover.innerHTML="";const t=document.createElement("button");t.className="popover-item",t.type="button",t.textContent=this.labels.stopReading,t.addEventListener("click",i=>{var a,s;i.preventDefault(),i.stopPropagation(),this.closeAllPopovers(),(s=(a=this.callbacks).onStop)==null||s.call(a)});const n=document.createElement("button");n.className="popover-item",n.type="button",n.textContent=`✉ ${this.labels.sendFeedback}`,n.addEventListener("click",i=>{i.preventDefault(),i.stopPropagation(),this.closeAllPopovers(),this.openFeedbackPopover()}),this.stopConfirmPopover.appendChild(t),this.stopConfirmPopover.appendChild(n),this.stopConfirmPopover.classList.add("open")}openFeedbackPopover(){this.feedbackPopover.innerHTML="";const e=document.createElement("button");e.className="popover-item popover-back-row",e.type="button",e.textContent=`‹ ${this.labels.settings}`,e.addEventListener("click",p=>{p.preventDefault(),p.stopPropagation(),this.closeAllPopovers(),this.settingsView="root",this.refreshSettingsPopover(),this.settingsPopover.classList.add("open")}),this.feedbackPopover.appendChild(e);const t=document.createElement("div");t.className="feedback-header",t.textContent=this.labels.feedbackTitle;const n=document.createElement("textarea");n.className="feedback-textarea",n.placeholder=this.labels.feedbackPlaceholder,n.rows=4,n.addEventListener("keydown",p=>p.stopPropagation());const i=document.createElement("input");i.className="feedback-email",i.type="email",i.placeholder=this.labels.feedbackEmailPlaceholder,i.required=!0,i.addEventListener("keydown",p=>p.stopPropagation());const a=document.createElement("div");a.className="feedback-status";const s=document.createElement("button");s.className="feedback-submit",s.type="button",s.textContent=this.labels.feedbackSend,s.addEventListener("click",async p=>{var d,u;p.preventDefault(),p.stopPropagation();const h=n.value.trim(),r=i.value.trim();if(!h){n.focus();return}if(!r){a.className="feedback-status error",a.textContent=this.labels.feedbackEmailRequired,i.focus();return}s.disabled=!0,s.textContent=this.labels.feedbackSending,a.className="feedback-status",a.textContent="";try{const m=await((u=(d=this.callbacks).onFeedbackSubmit)==null?void 0:u.call(d,h,r));if(m!=null&&m.success)a.className="feedback-status success",a.textContent=this.labels.feedbackDone,n.value="",i.value="",s.textContent=this.labels.feedbackSend,s.disabled=!1,setTimeout(()=>this.closeAllPopovers(),1800);else throw new Error("failed")}catch{a.className="feedback-status error",a.textContent=this.labels.feedbackFailed,s.textContent=this.labels.feedbackSend,s.disabled=!1}}),this.feedbackPopover.appendChild(t),this.feedbackPopover.appendChild(n),this.feedbackPopover.appendChild(i),this.feedbackPopover.appendChild(s),this.feedbackPopover.appendChild(a),this.feedbackPopover.classList.add("open"),setTimeout(()=>n.focus(),50)}handlePrimaryClick(){var e,t,n,i;if(this.state==="loading"){(t=(e=this.callbacks).onStop)==null||t.call(e);return}if(this.state==="idle"){const a=window.location.hostname;if(a.includes("youtube.com")||a.includes("youtu.be")){ke()?this.showYouTubeSourcePopover():this.callbacks.onStart({youtubeSource:"page"});return}this.callbacks.onStart()}else(i=(n=this.callbacks).onTogglePause)==null||i.call(n)}}const F=(()=>{const e=(typeof navigator<"u"&&navigator.languages||[])[0]||navigator.language||"";return j(e)})(),Ie={zh:{title:"CastReader",subtitle:"正在为你演示——耳朵听 + 眼睛看段落跟随高亮",ctaIdle:"▶  让我读这一页",ctaLoading:"正在为你准备 Demo…",ctaPlaying:"🔊  正在朗读……",ctaReplay:"↻  再听一次 Demo",ctaError:"出错了，再试一次",nextHint:"感觉怎么样？现在去你想读的内容上试试 →",nextCta:"→  在维基百科「注意」这篇试试",nextUrl:"https://zh.wikipedia.org/wiki/%E6%B3%A8%E6%84%8F",articleTitle:"让我读这一页给你听",paragraphs:["打开任何网页，点页面右边的 🎧 按钮，CastReader 就会把整页读给你听。","每段文字跟着声音高亮、自动滚到眼前——听到哪看到哪，长内容听到一半也不会丢位置。","不止 Kindle。Gmail 长邮件、ChatGPT / Claude 回复、Google Docs 文档——所有需要专注的内容都能听。","可免费开始：每日 20 分钟朗读 + 3 次解读，并提供 9 种语言的自然 AI 音色。"],tipMain:"点我，朗读当前页",tipSub:"段落高亮跟声音走",readTitle:"朗读",readDesc:"读原文——逐句高亮 + 自动滚动，边听边读。",explainTitle:"解读",explainDesc:"AI 用你选的语言把整页讲给你听，并划重点带你读。"},en:{title:"CastReader",subtitle:"Demoing for you — listen as paragraphs highlight in sync",ctaIdle:"▶  Read this page aloud",ctaLoading:"Preparing your demo…",ctaPlaying:"🔊  Reading…",ctaReplay:"↻  Play demo again",ctaError:"Something went wrong — try again",nextHint:"How was that? Now try it on something you actually want to read →",nextCta:"→  Open a real Wikipedia article",nextUrl:"https://en.wikipedia.org/wiki/Deep_work",articleTitle:"Let me read this page to you",paragraphs:["Open any page, click the 🎧 on the right, and CastReader reads it all to you.","Each paragraph highlights as it plays, scrolling into view — never lose your place in long content.","Not just Kindle. Long Gmail emails, ChatGPT and Claude replies, Google Docs — anything that needs focus.","Start free with 20 minutes of listening and 3 Explains daily, with natural AI voices in 9 supported languages."],tipMain:"Tap me to read this page",tipSub:"Highlights each paragraph as it plays",readTitle:"Read aloud",readDesc:"Reads the text verbatim — highlights and auto-scrolls as it goes.",explainTitle:"Explain",explainDesc:"AI walks you through the page in your language, pointing as it reads."},ja:{title:"CastReader",subtitle:"耳で聴き、目でハイライトを追うデモです",ctaIdle:"▶  このページを読み上げる",ctaLoading:"デモを準備中…",ctaPlaying:"🔊  読み上げ中…",ctaReplay:"↻  もう一度聴く",ctaError:"エラーが発生しました—再試行",nextHint:"いかがでしたか？次は読みたいページで試しましょう →",nextCta:"→  Wikipedia の記事を開く",nextUrl:"https://ja.wikipedia.org/wiki/%E6%B3%A8%E6%84%8F",articleTitle:"このページを読み上げます",paragraphs:["どのウェブページでも、右側のヘッドホンボタンを押すと、CastReader がページ全体を読み上げます。","音声に合わせて段落がハイライトされ、自動でスクロールします。長い文章でも読んでいる位置を見失いません。","Kindle だけでなく、長いメール、AI の回答、Google Docs など、集中したい内容に使えます。","毎日読み上げ 20 分と解説 3 回を無料で利用でき、9 言語の自然な AI 音声を選べます。"],tipMain:"タップしてこのページを読む",tipSub:"音声に合わせて段落をハイライト",readTitle:"読み上げ",readDesc:"原文をそのまま読み、ハイライトと自動スクロールで追います。",explainTitle:"解説",explainDesc:"AI が選んだ言語でページを解説し、ポイントを示します。"},es:{title:"CastReader",subtitle:"Escucha mientras los párrafos se resaltan en sincronía",ctaIdle:"▶  Leer esta página en voz alta",ctaLoading:"Preparando la demostración…",ctaPlaying:"🔊  Leyendo…",ctaReplay:"↻  Repetir demostración",ctaError:"Algo salió mal — reintentar",nextHint:"¿Qué te pareció? Pruébalo ahora con algo que quieras leer →",nextCta:"→  Abrir un artículo de Wikipedia",nextUrl:"https://es.wikipedia.org/wiki/Atenci%C3%B3n",articleTitle:"Deja que lea esta página",paragraphs:["Abre cualquier página y pulsa el botón de auriculares de la derecha. CastReader leerá todo el contenido.","Cada párrafo se resalta mientras suena y se desplaza hasta la vista, para que nunca pierdas tu posición en textos largos.","No solo funciona con Kindle: también con correos largos, respuestas de inteligencia artificial y documentos de Google.","Empieza gratis con 20 minutos de escucha y 3 explicaciones al día, con voces naturales en 9 idiomas."],tipMain:"Tócame para leer esta página",tipSub:"Resalta cada párrafo mientras se reproduce",readTitle:"Leer en voz alta",readDesc:"Lee el texto original con resaltado y desplazamiento automático.",explainTitle:"Explicar",explainDesc:"La inteligencia artificial te guía por la página en tu idioma y señala cada idea."},fr:{title:"CastReader",subtitle:"Écoutez pendant que les paragraphes sont surlignés en synchronisation",ctaIdle:"▶  Lire cette page à voix haute",ctaLoading:"Préparation de la démo…",ctaPlaying:"🔊  Lecture…",ctaReplay:"↻  Rejouer la démo",ctaError:"Un problème est survenu — réessayer",nextHint:"Qu’en pensez-vous ? Essayez maintenant sur un contenu qui vous intéresse →",nextCta:"→  Ouvrir un article Wikipédia",nextUrl:"https://fr.wikipedia.org/wiki/Attention_(psychologie)",articleTitle:"Laissez-moi lire cette page",paragraphs:["Ouvrez n’importe quelle page et cliquez sur le bouton casque à droite. CastReader lit tout le contenu.","Chaque paragraphe est surligné pendant la lecture et défile automatiquement pour ne jamais perdre votre position.","Cela fonctionne avec Kindle, les longs e-mails, les réponses d’intelligence artificielle et les documents Google.","Commencez gratuitement avec 20 minutes d’écoute et 3 explications par jour, avec des voix naturelles dans 9 langues."],tipMain:"Cliquez pour lire cette page",tipSub:"Chaque paragraphe est surligné pendant la lecture",readTitle:"Lire à voix haute",readDesc:"Lit le texte original avec surbrillance et défilement automatique.",explainTitle:"Expliquer",explainDesc:"L’intelligence artificielle vous guide dans votre langue et indique chaque idée."},de:{title:"CastReader",subtitle:"Höre zu, während die Absätze synchron hervorgehoben werden",ctaIdle:"▶  Diese Seite vorlesen",ctaLoading:"Demo wird vorbereitet…",ctaPlaying:"🔊  Wird vorgelesen…",ctaReplay:"↻  Demo erneut abspielen",ctaError:"Etwas ist schiefgelaufen — erneut versuchen",nextHint:"Wie war es? Probiere CastReader jetzt mit einem Text aus, den du wirklich lesen möchtest →",nextCta:"→  Einen Wikipedia-Artikel öffnen",nextUrl:"https://de.wikipedia.org/wiki/Aufmerksamkeit",articleTitle:"Lass mich dir diese Seite vorlesen",paragraphs:["Öffne eine beliebige Webseite und klicke rechts auf die Kopfhörer-Schaltfläche. CastReader liest dir den gesamten Inhalt vor.","Jeder Absatz wird beim Vorlesen hervorgehoben und automatisch ins Blickfeld gescrollt, damit du in langen Texten nie die Stelle verlierst.","Nicht nur Kindle: Auch lange E-Mails, KI-Antworten und Google-Dokumente lassen sich vorlesen.","Starte kostenlos mit täglich 20 Minuten Vorlesen und 3 Erklärungen sowie natürlichen KI-Stimmen in 9 Sprachen."],tipMain:"Antippen, um diese Seite vorzulesen",tipSub:"Hebt jeden Absatz synchron hervor",readTitle:"Vorlesen",readDesc:"Liest den Originaltext mit Hervorhebung und automatischem Scrollen.",explainTitle:"Erklären",explainDesc:"Die KI führt dich in deiner Sprache durch die Seite und zeigt jeden wichtigen Gedanken."},pt:{title:"CastReader",subtitle:"Ouça enquanto os parágrafos são destacados em sincronia",ctaIdle:"▶  Ler esta página em voz alta",ctaLoading:"Preparando a demonstração…",ctaPlaying:"🔊  Lendo…",ctaReplay:"↻  Repetir demonstração",ctaError:"Algo deu errado — tentar novamente",nextHint:"Gostou? Agora experimente em algo que você queira ler →",nextCta:"→  Abrir um artigo da Wikipédia",nextUrl:"https://pt.wikipedia.org/wiki/Aten%C3%A7%C3%A3o",articleTitle:"Deixe-me ler esta página",paragraphs:["Abra qualquer página e clique no botão de fones à direita. O CastReader lerá todo o conteúdo.","Cada parágrafo é destacado enquanto toca e rola automaticamente para você nunca perder o ponto em textos longos.","Não é só para Kindle: funciona com e-mails longos, respostas de inteligência artificial e documentos do Google.","Comece grátis com 20 minutos de escuta e 3 explicações por dia, com vozes naturais em 9 idiomas."],tipMain:"Toque para ler esta página",tipSub:"Destaca cada parágrafo durante a leitura",readTitle:"Ler em voz alta",readDesc:"Lê o texto original com destaque e rolagem automática.",explainTitle:"Explicar",explainDesc:"A inteligência artificial guia você pela página no seu idioma e aponta cada ideia."},it:{title:"CastReader",subtitle:"Ascolta mentre i paragrafi vengono evidenziati in sincronia",ctaIdle:"▶  Leggi questa pagina ad alta voce",ctaLoading:"Preparazione della demo…",ctaPlaying:"🔊  Lettura…",ctaReplay:"↻  Riproduci di nuovo la demo",ctaError:"Qualcosa è andato storto — riprova",nextHint:"Com’è andata? Provalo ora su qualcosa che vuoi davvero leggere →",nextCta:"→  Apri un articolo di Wikipedia",nextUrl:"https://it.wikipedia.org/wiki/Attenzione",articleTitle:"Lascia che legga questa pagina",paragraphs:["Apri una pagina e fai clic sul pulsante delle cuffie a destra. CastReader leggerà tutto il contenuto.","Ogni paragrafo viene evidenziato durante la lettura e scorre automaticamente, così non perdi mai il segno.","Non solo Kindle: funziona con e-mail lunghe, risposte dell’intelligenza artificiale e documenti Google.","Inizia gratis con 20 minuti di ascolto e 3 spiegazioni al giorno, con voci naturali in 9 lingue."],tipMain:"Tocca per leggere questa pagina",tipSub:"Evidenzia ogni paragrafo durante la lettura",readTitle:"Leggi ad alta voce",readDesc:"Legge il testo originale con evidenziazione e scorrimento automatico.",explainTitle:"Spiega",explainDesc:"L’intelligenza artificiale ti guida nella tua lingua e indica ogni concetto."},hi:{title:"CastReader",subtitle:"सुनें और साथ-साथ हाइलाइट होते पैराग्राफ़ देखें",ctaIdle:"▶  यह पेज़ पढ़कर सुनाएँ",ctaLoading:"डेमो तैयार हो रहा है…",ctaPlaying:"🔊  पढ़ा जा रहा है…",ctaReplay:"↻  डेमो फिर सुनें",ctaError:"कुछ गलत हुआ — फिर कोशिश करें",nextHint:"कैसा लगा? अब इसे अपनी पसंद की सामग्री पर आज़माएँ →",nextCta:"→  विकिपीडिया लेख खोलें",nextUrl:"https://hi.wikipedia.org/wiki/%E0%A4%A7%E0%A5%8D%E0%A4%AF%E0%A4%BE%E0%A4%A8",articleTitle:"मुझे यह पेज़ पढ़ने दें",paragraphs:["कोई भी वेब पेज़ खोलें और दाईं ओर हेडफ़ोन बटन दबाएँ। CastReader पूरा पेज़ पढ़ेगा।","हर पैराग्राफ़ आवाज़ के साथ हाइलाइट होता है और आपके सामने स्क्रॉल होता है।","यह केवल Kindle नहीं। लंबे ईमेल, AI जवाब और Google Docs भी समर्थित हैं।","रोज़ 20 मिनट सुनने और 3 व्याख्याओं के साथ मुफ़्त शुरू करें। 9 भाषाओं में प्राकृतिक AI आवाज़ें उपलब्ध हैं।"],tipMain:"यह पेज़ पढ़ने के लिए दबाएँ",tipSub:"पढ़ते समय हर पैराग्राफ़ हाइलाइट होता है",readTitle:"पढ़कर सुनाएँ",readDesc:"मूल पाठ को हाइलाइट और ऑटो-स्क्रॉल के साथ पढ़ता है।",explainTitle:"समझाएँ",explainDesc:"AI आपकी भाषा में पेज़ समझाता है और हर बिंदु दिखाता है।"}},R=Ie[F];function ze(){const[o,e]=E.useState("idle"),[t,n]=E.useState(!1),i=E.useRef(null),a=E.useRef(null),s=E.useRef([]),p=E.useRef(se),h=E.useCallback(()=>{var v,x;(v=i.current)==null||v.reset(),i.current=null,(x=a.current)==null||x.setState("idle"),e("idle")},[]),r=E.useCallback(async()=>{var N,O,_;e("loading"),(N=a.current)==null||N.setState("loading");const v=F,x=s.current.filter(L=>!!L).map(L=>({text:L.textContent||"",element:L})),D=x.reduce((L,I)=>L+I.text.length,0);B("session_start",{url_domain:"welcome",language:v,trigger:"welcome_demo",content_origin:"demo"});const c=await chrome.runtime.sendMessage({type:"GET_SETTINGS"}),P=Pe(v,c.voicePreferences);P?c.voice=P:c.voice="",(O=i.current)==null||O.reset(),i.current=null;const T=new we(c,{onPlaybackStateChange:L=>{var I,M;L==="playing"?((I=a.current)==null||I.setState("playing"),e("playing")):L==="paused"&&((M=a.current)==null||M.setState("paused"))},onEnd:()=>{var L;(L=a.current)==null||L.setState("idle"),e("ended"),B("reading_end",{...T.getAnalyticsProperties(),url_domain:"welcome",content_origin:"demo",paragraph_count:x.length,paragraphs_total:x.length,paragraphs_played:T.getPlayedSegmentCount(),char_count:D,completion_rate:1,reason:"completed"})},onError:()=>{var L;(L=a.current)==null||L.setState("idle"),e("error")}},{analyticsSource:"welcome_demo",analyticsDomain:"welcome",analyticsContext:{content_origin:"demo",trigger:"welcome_demo"}});i.current=T,p.current!==1&&T.setPlaybackRate(p.current);try{await T.startReadingWithParagraphs(x,v)}catch(L){const I=L;(I==null?void 0:I.name)==="NotAllowedError"||/play\(\) failed|user gesture|user interact|didn'?t interact/i.test((I==null?void 0:I.message)??"")?(B("feature_use",{feature:"welcome_autoplay_blocked"}),e("idle")):(console.error("[Welcome] startReading failed",L),e("error")),(_=a.current)==null||_.setState("idle")}},[]);E.useEffect(()=>{let v=!1;const x=setTimeout(()=>{v||(B("feature_use",{feature:"welcome_autoplay_attempt"}),u(!0),r())},600);return()=>{v=!0,clearTimeout(x)}},[r]);const[d,u]=E.useState(!1);E.useEffect(()=>{d&&o==="idle"&&chrome.storage.local.get(H.WELCOME_TIP_SHOWN).then(v=>{v[H.WELCOME_TIP_SHOWN]||(n(!0),chrome.storage.local.set({[H.WELCOME_TIP_SHOWN]:!0}))})},[d,o]),E.useEffect(()=>{const v=(()=>{try{return new URLSearchParams(window.location.search).get("from")}catch{return null}})();B("feature_use",{feature:"welcome_view",language:F,from:v||"install"})},[]),E.useEffect(()=>{const v=new Oe(F,{onStart:()=>{n(!1),r()},onTogglePause:()=>{const x=i.current;if(!x){r();return}x.getPlaybackState()==="playing"?x.pause():x.play()},onStop:()=>h(),onSpeedChange:x=>{var D,c;p.current=x,(D=i.current)==null||D.setPlaybackRate(x),(c=i.current)==null||c.updateSpeed(x),chrome.runtime.sendMessage({type:"SAVE_SETTINGS",payload:{speed:x}}).catch(()=>{})},onOpenReader:()=>{chrome.runtime.sendMessage({type:"OPEN_READER"})}});return v.attach(),a.current=v,chrome.runtime.sendMessage({type:"GET_SETTINGS"}).then(x=>{const D=x==null?void 0:x.speed;D&&D>0&&Math.abs(D-p.current)>.01&&(p.current=D,v.setSpeed(D))}).catch(()=>{}),()=>{var x;v.destroy(),a.current=null,(x=i.current)==null||x.destroy(),i.current=null}},[r,h]);const m=E.useCallback(()=>{o==="loading"||o==="playing"||r()},[o,r]),y=E.useCallback(()=>{B("feature_use",{feature:"welcome_demo_to_real_site"}),window.open(R.nextUrl,"_blank")},[]),k=o==="ended",b=k?R.nextCta:o==="idle"?R.ctaIdle:o==="loading"?R.ctaLoading:o==="playing"?R.ctaPlaying:R.ctaError,f=k?y:m,C=o==="idle"||k,A=o==="loading"||o==="playing",z=o==="playing";return l.jsxs("div",{style:S.page,children:[t&&l.jsx("div",{style:S.tipWrap,children:l.jsxs("div",{style:S.tip,children:[l.jsx("div",{style:S.tipMain,children:R.tipMain}),l.jsx("div",{style:S.tipSub,children:R.tipSub}),l.jsx("button",{style:S.tipClose,onClick:()=>n(!1),children:"×"}),l.jsx("div",{style:S.tipArrow})]})}),l.jsxs("div",{style:S.container,children:[l.jsxs("div",{style:S.hero,children:[l.jsx("img",{src:chrome.runtime.getURL("/icon-128.png"),alt:"CastReader",style:S.logo}),R.title?l.jsx("h1",{style:S.title,children:R.title}):null,R.subtitle?l.jsx("p",{style:S.subtitle,children:R.subtitle}):null]}),l.jsx("button",{type:"button",onClick:f,disabled:A,style:{...S.bigCta,...C?S.bigCtaPulsing:{},...A?S.bigCtaDisabled:{},...z?S.bigCtaPlaying:{}},children:b}),k&&l.jsxs("div",{style:S.replayWrap,children:[l.jsx("p",{style:S.replayHint,children:R.nextHint}),l.jsx("button",{type:"button",onClick:m,style:S.replayBtn,children:R.ctaReplay})]}),l.jsxs("article",{style:S.article,children:[l.jsx("h2",{style:S.articleTitle,children:R.articleTitle}),R.paragraphs.map((v,x)=>l.jsx("p",{ref:D=>{s.current[x]=D},style:S.articleP,children:v},x))]}),l.jsx("div",{style:{display:"flex",gap:12,marginTop:28,flexWrap:"wrap",justifyContent:"center"},children:[{icon:"🔊",title:R.readTitle,desc:R.readDesc},{icon:"🎧",title:R.explainTitle,desc:R.explainDesc}].map(v=>l.jsxs("div",{style:{flex:"1 1 220px",maxWidth:300,background:"rgba(255,255,255,0.05)",border:"1px solid rgba(255,255,255,0.08)",borderRadius:12,padding:"14px 16px",textAlign:"left"},children:[l.jsx("div",{style:{fontSize:22},children:v.icon}),l.jsx("div",{style:{fontWeight:700,margin:"6px 0 4px",color:"#fff"},children:v.title}),l.jsx("div",{style:{fontSize:13,lineHeight:1.5,color:"rgba(255,255,255,0.72)"},children:v.desc})]},v.title))})]})]})}const S={page:{minHeight:"100vh",background:"linear-gradient(160deg, #0a0a14 0%, #111827 40%, #0f172a 100%)",color:"#cbd5e1",fontFamily:"-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",padding:"48px 24px 160px"},container:{maxWidth:680,margin:"0 auto"},hero:{textAlign:"center",marginBottom:32},logo:{width:72,height:72,borderRadius:18,marginBottom:16,boxShadow:"0 8px 32px rgba(242, 101, 34, 0.2)"},title:{fontSize:32,fontWeight:700,color:"#f8fafc",margin:"0 0 8px",letterSpacing:"-0.5px"},subtitle:{fontSize:17,color:"#94a3b8",margin:0},bigCta:{display:"block",width:"100%",padding:"24px 32px",marginBottom:40,background:"#F26522",color:"#ffffff",border:"none",borderRadius:16,fontSize:22,fontWeight:700,cursor:"pointer",transition:"transform 0.15s ease, box-shadow 0.15s ease",boxShadow:"0 12px 36px rgba(242, 101, 34, 0.45)",fontFamily:"inherit"},bigCtaPulsing:{animation:"cr-pulse-strong 1.4s ease-in-out infinite"},bigCtaDisabled:{cursor:"wait",opacity:.85},bigCtaPlaying:{background:"rgba(242, 101, 34, 0.35)",boxShadow:"none",color:"rgba(255,255,255,0.92)",cursor:"default"},replayWrap:{marginTop:-24,marginBottom:32,textAlign:"center",animation:"cr-tip-in 0.35s ease-out both"},replayHint:{fontSize:14,color:"#94a3b8",margin:"0 0 10px"},replayBtn:{background:"transparent",color:"#94a3b8",border:"1px solid rgba(148, 163, 184, 0.35)",borderRadius:8,padding:"8px 18px",fontSize:13,fontWeight:500,cursor:"pointer",fontFamily:"inherit"},article:{marginBottom:32,padding:"32px 36px",background:"rgba(255,255,255,0.02)",borderRadius:16,border:"1px solid rgba(255,255,255,0.06)"},articleTitle:{fontSize:22,fontWeight:700,color:"#f1f5f9",margin:"0 0 20px"},articleP:{fontSize:17,lineHeight:1.75,color:"#cbd5e1",margin:"0 0 16px"},tipWrap:{position:"fixed",right:5,bottom:"calc(68% + 8px)",zIndex:2147483647,animation:"cr-tip-in 0.25s ease-out both",pointerEvents:"auto"},tip:{position:"relative",background:"#F26522",color:"#fff",borderRadius:10,padding:"10px 36px 10px 14px",boxShadow:"0 4px 20px rgba(242, 101, 34, 0.5)",lineHeight:1.5,whiteSpace:"nowrap"},tipMain:{fontSize:13.5,fontWeight:600},tipSub:{fontSize:12,color:"rgba(255,255,255,0.82)",marginTop:2},tipClose:{position:"absolute",top:6,right:9,background:"none",border:"none",color:"rgba(255,255,255,0.55)",cursor:"pointer",fontSize:17,lineHeight:1,padding:0,fontFamily:"inherit"},tipArrow:{position:"absolute",bottom:-10,right:19,width:0,height:0,borderLeft:"10px solid transparent",borderRight:"10px solid transparent",borderTop:"10px solid #F26522"}},le={en:{pageTitle:"Welcome to CastReader",loadingLabel:"Loading CastReader…",startupError:"CastReader could not start. Reload this page to try again.",genericError:"We couldn’t open this scene. Try again or choose another scene.",eyebrow:"Your first read-aloud",title:"What would you like to listen to today?",subtitle:"Choose one. We’ll take you to the right place and show you the one button to press.",recommended:"Recommended",openScene:"Start here",opening:"Opening…",handoffTitle:"Your next step is on the page we opened",handoffBody:"Look for the orange CastReader cue, then press Read. You can return here to switch scenes.",skip:"Maybe later",privacy:"No sign-in required. This guide and product analytics never record page text, file names, book titles, email, or conversations.",scenes:{web_email:{icon:"🌐",title:"Web page or long email",description:"News, blogs, newsletters, Gmail and Outlook."},kindle:{icon:"📚",title:"Kindle book",description:"Listen and follow along inside Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF or document",description:"PDF, DOCX, text files and Google Docs."},ai_chat:{icon:"✨",title:"AI response",description:"ChatGPT, Claude, Gemini and other supported chats."}}},zh:{pageTitle:"欢迎使用 CastReader",loadingLabel:"正在加载 CastReader…",startupError:"CastReader 无法启动。请刷新页面后重试。",genericError:"无法打开此场景。请重试或选择其他场景。",eyebrow:"你的第一次朗读",title:"你今天想听什么？",subtitle:"选择一个场景，我们会带你到正确的位置，并告诉你只需点击哪个按钮。",recommended:"推荐",openScene:"从这里开始",opening:"正在打开…",handoffTitle:"下一步已在刚刚打开的页面上",handoffBody:"找到橙色 CastReader 提示，然后点击朗读。你也可以回到这里更换场景。",skip:"稍后再说",privacy:"无需登录。本引导和产品分析不会记录网页正文、文件名、书名、邮件或 AI 对话。",scenes:{web_email:{icon:"🌐",title:"网页 / 长邮件",description:"新闻、博客、新闻通讯、Gmail 和 Outlook。"},kindle:{icon:"📚",title:"Kindle 电子书",description:"在 Kindle Cloud Reader 里边听边看。"},pdf_document:{icon:"📄",title:"PDF / 文档",description:"PDF、DOCX、文本文件和 Google Docs。"},ai_chat:{icon:"✨",title:"AI 回答",description:"ChatGPT、Claude、Gemini 等 AI 对话。"}}},ja:{pageTitle:"CastReaderへようこそ",loadingLabel:"CastReaderを読み込んでいます…",startupError:"CastReaderを起動できませんでした。ページを再読み込みして、もう一度お試しください。",genericError:"この用途を開けませんでした。もう一度試すか、別の用途を選んでください。",eyebrow:"はじめての読み上げ",title:"今日は何を聴きますか？",subtitle:"用途を一つ選ぶと、適切なページへ移動し、押すボタンを一つだけ案内します。",recommended:"おすすめ",openScene:"ここから始める",opening:"開いています…",handoffTitle:"次の手順は開いたページにあります",handoffBody:"オレンジ色の CastReader の目印を探し、「読み上げ」を押してください。別の用途を選ぶ場合は、ここに戻れます。",skip:"あとで",privacy:"ログインは不要です。このガイドと製品分析では、本文、ファイル名、書名、メール、会話の内容を記録しません。",scenes:{web_email:{icon:"🌐",title:"Web ページ / 長いメール",description:"ニュース、ブログ、Gmail、Outlook。"},kindle:{icon:"📚",title:"Kindle 本",description:"Kindle Cloud Reader で聴きながら本文を追えます。"},pdf_document:{icon:"📄",title:"PDF / 文書",description:"PDF、DOCX、テキスト、Google Docs。"},ai_chat:{icon:"✨",title:"AI の回答",description:"ChatGPT、Claude、Gemini など。"}}},es:{pageTitle:"Te damos la bienvenida a CastReader",loadingLabel:"Cargando CastReader…",startupError:"CastReader no pudo iniciarse. Recarga la página para volver a intentarlo.",genericError:"No pudimos abrir esta opción. Inténtalo de nuevo o elige otra.",eyebrow:"Tu primera escucha",title:"¿Qué quieres escuchar hoy?",subtitle:"Elige una opción. Te llevaremos al lugar correcto y te mostraremos un solo botón.",recommended:"Recomendado",openScene:"Empezar aquí",opening:"Abriendo…",handoffTitle:"El siguiente paso está en la página abierta",handoffBody:"Busca la indicación naranja de CastReader y pulsa «Leer». Puedes volver para cambiar.",skip:"Más tarde",privacy:"No es necesario iniciar sesión. Esta guía y las analíticas no guardan texto, nombres de archivos, títulos, correos ni conversaciones.",scenes:{web_email:{icon:"🌐",title:"Página web o correo largo",description:"Noticias, blogs, Gmail y Outlook."},kindle:{icon:"📚",title:"Libro Kindle",description:"Escucha y sigue el texto en Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF o documento",description:"PDF, DOCX, texto y Google Docs."},ai_chat:{icon:"✨",title:"Respuesta de IA",description:"ChatGPT, Claude, Gemini y otros."}}},fr:{pageTitle:"Bienvenue sur CastReader",loadingLabel:"Chargement de CastReader…",startupError:"CastReader n’a pas pu démarrer. Rechargez la page pour réessayer.",genericError:"Impossible d’ouvrir cette option pour le moment. Réessayez ou choisissez-en une autre.",eyebrow:"Votre première écoute",title:"Qu’aimeriez-vous écouter aujourd’hui ?",subtitle:"Choisissez une option. Nous vous conduirons au bon endroit et vous indiquerons le seul bouton à utiliser.",recommended:"Recommandé",openScene:"Commencer ici",opening:"Ouverture…",handoffTitle:"La prochaine étape se trouve sur la page ouverte",handoffBody:"Repérez le bouton orange CastReader, puis cliquez sur « Lire ». Revenez ici pour changer d’option.",skip:"Plus tard",privacy:"Pas besoin de vous connecter. Ce guide et les analyses produit n’enregistrent ni texte, ni nom de fichier, ni titre, ni e-mail, ni conversation.",scenes:{web_email:{icon:"🌐",title:"Page Web ou long e-mail",description:"Actualités, blogs, Gmail et Outlook."},kindle:{icon:"📚",title:"Livre Kindle",description:"Écoutez dans Kindle Cloud Reader en suivant le texte."},pdf_document:{icon:"📄",title:"PDF ou document",description:"PDF, DOCX, texte et Google Docs."},ai_chat:{icon:"✨",title:"Réponse d’IA",description:"ChatGPT, Claude, Gemini et autres."}}},de:{pageTitle:"Willkommen bei CastReader",loadingLabel:"CastReader wird geladen…",startupError:"CastReader konnte nicht gestartet werden. Lade die Seite neu und versuche es noch einmal.",genericError:"Diese Option kann gerade nicht geöffnet werden. Versuche es erneut oder wähle eine andere.",eyebrow:"Dein erstes Vorlesen",title:"Was möchtest du heute hören?",subtitle:"Wähle eine Option. Wir bringen dich zur richtigen Stelle und zeigen dir genau, auf welche Schaltfläche du klicken musst.",recommended:"Empfohlen",openScene:"Hier starten",opening:"Wird geöffnet…",handoffTitle:"Der nächste Schritt ist auf der geöffneten Seite",handoffBody:"Suche den orangefarbenen CastReader-Hinweis und klicke auf „Vorlesen“. Kehre hierher zurück, um eine andere Option zu wählen.",skip:"Später",privacy:"Keine Anmeldung erforderlich. Dieser Leitfaden und die Produktanalyse speichern keine Texte, Dateinamen, Buchtitel, E-Mails oder Gespräche.",scenes:{web_email:{icon:"🌐",title:"Webseite oder lange E-Mail",description:"Nachrichten, Blogs, Gmail und Outlook."},kindle:{icon:"📚",title:"Kindle-Buch",description:"Im Kindle Cloud Reader hören und mitlesen."},pdf_document:{icon:"📄",title:"PDF oder Dokument",description:"PDF, DOCX, Text und Google Docs."},ai_chat:{icon:"✨",title:"KI-Antwort",description:"ChatGPT, Claude, Gemini und weitere."}}},pt:{pageTitle:"Boas-vindas ao CastReader",loadingLabel:"Carregando o CastReader…",startupError:"Não foi possível iniciar o CastReader. Recarregue a página e tente novamente.",genericError:"Não foi possível abrir esta opção agora. Tente novamente ou escolha outra.",eyebrow:"Sua primeira leitura em voz alta",title:"O que você quer ouvir hoje?",subtitle:"Escolha uma opção. Levaremos você à página certa e mostraremos qual botão usar.",recommended:"Recomendado",openScene:"Começar aqui",opening:"Abrindo…",handoffTitle:"O próximo passo está na página aberta",handoffBody:"Procure a indicação laranja do CastReader e clique em “Ler”. Volte aqui para escolher outra opção.",skip:"Mais tarde",privacy:"Não é preciso fazer login. Este guia e a análise do produto não registram textos, nomes de arquivos, títulos, e-mails ou conversas.",scenes:{web_email:{icon:"🌐",title:"Página da web ou e-mail longo",description:"Notícias, blogs, Gmail e Outlook."},kindle:{icon:"📚",title:"Livro Kindle",description:"Ouça e acompanhe no Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF ou documento",description:"PDF, DOCX, texto e Google Docs."},ai_chat:{icon:"✨",title:"Resposta de IA",description:"ChatGPT, Claude, Gemini e outros."}}},it:{pageTitle:"Benvenuto in CastReader",loadingLabel:"Caricamento di CastReader…",startupError:"Impossibile avviare CastReader. Ricarica la pagina e riprova.",genericError:"Al momento non è possibile aprire questa opzione. Riprova o scegline un’altra.",eyebrow:"Il tuo primo ascolto",title:"Cosa vuoi ascoltare oggi?",subtitle:"Scegli un’opzione. Ti porteremo alla pagina giusta e ti indicheremo l’unico pulsante da premere.",recommended:"Consigliato",openScene:"Inizia qui",opening:"Apertura…",handoffTitle:"Il prossimo passo è nella pagina aperta",handoffBody:"Cerca l’indicatore arancione di CastReader e premi «Leggi». Torna qui per scegliere un’altra opzione.",skip:"Più tardi",privacy:"Non è necessario accedere. Questa guida e le analisi del prodotto non registrano testo, nomi file, titoli, e-mail o conversazioni.",scenes:{web_email:{icon:"🌐",title:"Pagina Web o e-mail lunga",description:"Notizie, blog, Gmail e Outlook."},kindle:{icon:"📚",title:"Libro Kindle",description:"Ascolta e segui in Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF o documento",description:"PDF, DOCX, testo e Google Docs."},ai_chat:{icon:"✨",title:"Risposta dell’IA",description:"ChatGPT, Claude, Gemini e altri."}}},hi:{pageTitle:"CastReader में आपका स्वागत है",loadingLabel:"CastReader लोड हो रहा है…",startupError:"CastReader शुरू नहीं हो सका। फिर से कोशिश करने के लिए यह पेज रीलोड करें।",genericError:"यह विकल्प नहीं खुल सका। फिर से कोशिश करें या कोई दूसरा विकल्प चुनें।",eyebrow:"पहली बार सुनें",title:"आज आप क्या सुनना चाहेंगे?",subtitle:"एक विकल्प चुनें। हम सही पेज खोलेंगे और बताएँगे कि कौन-सा बटन दबाना है।",recommended:"सुझाया गया",openScene:"यहाँ से शुरू करें",opening:"खुल रहा है…",handoffTitle:"अगला कदम खोले गए पेज पर है",handoffBody:"नारंगी CastReader संकेत ढूँढें और “पढ़ें” बटन दबाएँ। बदलने के लिए यहाँ लौटें।",skip:"बाद में",privacy:"लॉग इन करने की ज़रूरत नहीं है। यह गाइड और उत्पाद विश्लेषण टेक्स्ट, फ़ाइल नाम, किताब के शीर्षक, ईमेल या बातचीत रिकॉर्ड नहीं करते।",scenes:{web_email:{icon:"🌐",title:"वेब पेज या लंबा ईमेल",description:"समाचार, ब्लॉग, Gmail और Outlook।"},kindle:{icon:"📚",title:"Kindle किताब",description:"Kindle Cloud Reader में सुनें और साथ पढ़ें।"},pdf_document:{icon:"📄",title:"PDF या दस्तावेज़",description:"PDF, DOCX, टेक्स्ट और Google Docs।"},ai_chat:{icon:"✨",title:"AI का जवाब",description:"ChatGPT, Claude, Gemini और अन्य।"}}}};function ae(o){const e=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?crypto.randomUUID():Math.random().toString(36).slice(2);return`${o}:${Date.now().toString(36)}:${e}`}function Ne({bootstrap:o,language:e}){const t=le[e],[n,i]=E.useState(o.state),[a,s]=E.useState(null),[p,h]=E.useState(null),r=n.flow,d=E.useCallback(async b=>{if(!a){s(b),h(null);try{let f=n;for(let C=0;C<2;C+=1){const A=await chrome.runtime.sendMessage({type:"ONBOARDING_ROUTE",payload:{scene:b,transitionId:ae(`${f.onboardingId}:route:${b}`),expectedRevision:f.revision,requestedAt:Date.now()}});if(f=A.state,i(f),!(A.transition.kind==="rejected"&&A.transition.reason==="stale_revision")){A.resolution.kind==="blocked"&&h(A.resolution.code);break}}}catch(f){console.error("[Onboarding] route failed",f),h("route_failed")}finally{s(null)}}},[a,n.onboardingId,n.revision]),u=E.useCallback(async()=>{if(!(!r||a)){h(null);try{let b=n;for(let f=0;f<2;f+=1){const C=await chrome.runtime.sendMessage({type:"ONBOARDING_TRANSITION",payload:{transition:{type:"SKIPPED",transitionId:ae(`${b.onboardingId}:skip`),expectedRevision:b.revision,occurredAt:Date.now(),reason:"not_now"}}});if(b=C.result.state,i(b),!(C.result.kind==="rejected"&&C.result.reason==="stale_revision")){if(C.result.kind==="applied"||C.result.kind==="duplicate"){window.close();return}h(C.result.kind==="rejected"?C.result.reason:"skip_failed");return}}h("stale_revision")}catch(b){console.error("[Onboarding] skip failed",b),h("skip_failed")}}},[r,a,n.onboardingId,n.revision]),m=(r==null?void 0:r.selectedScene)||null,y=(r==null?void 0:r.status)==="handoff_pending"||(r==null?void 0:r.status)==="target_ready"||(r==null?void 0:r.status)==="reading_started",k=(r==null?void 0:r.status)==="blocked";return E.useEffect(()=>{},[o.recommendedScene,o.sceneOrder,n.onboardingId]),l.jsx("main",{style:w.page,children:l.jsxs("section",{style:w.shell,"aria-labelledby":"onboarding-title",children:[l.jsxs("header",{style:w.header,children:[l.jsx("img",{src:chrome.runtime.getURL("/icon-128.png"),alt:"",width:64,height:64,style:w.logo}),l.jsx("p",{style:w.eyebrow,children:t.eyebrow}),l.jsx("h1",{id:"onboarding-title",style:w.title,children:t.title}),l.jsx("p",{style:w.subtitle,children:t.subtitle})]}),y?l.jsxs("div",{style:w.statusCard,role:"status",children:[l.jsx("span",{"aria-hidden":"true",style:w.statusIcon,children:"✓"}),l.jsxs("div",{children:[l.jsx("strong",{style:w.statusTitle,children:t.handoffTitle}),l.jsx("p",{style:w.statusBody,children:t.handoffBody})]})]}):null,k||p?l.jsx("div",{style:w.errorCard,role:"alert",children:l.jsx("strong",{children:t.genericError})}):null,l.jsx("div",{style:w.grid,children:o.sceneOrder.map(b=>{const f=t.scenes[b],C=a===b,A=m===b,z=o.recommendedScene===b,v=C?t.opening:z?t.recommended:null;return l.jsxs("button",{type:"button","data-onboarding-role":"scenario-card","data-onboarding-scene":b,"data-onboarding-recommended":z?"true":"false","aria-pressed":A,"aria-label":[f.title,f.description,v].filter(Boolean).join(". "),disabled:a!==null,onClick:()=>void d(b),style:{...w.sceneCard,...A?w.sceneCardSelected:{},...a&&!C?w.sceneCardMuted:{}},children:[l.jsxs("span",{style:w.sceneTopline,children:[l.jsx("span",{"aria-hidden":"true",style:w.sceneIcon,children:f.icon}),z?l.jsx("span",{style:w.recommended,children:t.recommended}):null]}),l.jsx("strong",{style:w.sceneTitle,children:f.title}),l.jsx("span",{style:w.sceneDescription,children:f.description}),l.jsxs("span",{"aria-live":C?"polite":void 0,style:w.sceneAction,children:[C?t.opening:t.openScene,l.jsx("span",{"aria-hidden":"true",children:" →"})]})]},b)})}),l.jsxs("footer",{style:w.footer,children:[l.jsx("button",{type:"button",onClick:()=>void u(),disabled:a!==null,style:w.skipButton,children:t.skip}),l.jsx("p",{style:w.privacy,children:t.privacy})]})]})})}const w={page:{minHeight:"100vh",boxSizing:"border-box",padding:"42px 24px 72px",color:"#f8fafc",background:"radial-gradient(circle at 50% -10%, rgba(242,101,34,.18), transparent 38%), #090b12",fontFamily:"-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"},shell:{width:"100%",maxWidth:920,margin:"0 auto"},header:{maxWidth:700,margin:"0 auto 34px",textAlign:"center"},logo:{display:"block",margin:"0 auto 14px",borderRadius:16,boxShadow:"0 14px 42px rgba(242,101,34,.22)"},eyebrow:{margin:"0 0 10px",color:"#fb923c",fontSize:13,fontWeight:750,letterSpacing:".1em",textTransform:"uppercase"},title:{margin:0,color:"#fff",fontSize:"clamp(32px, 5vw, 50px)",lineHeight:1.08,letterSpacing:"-.035em"},subtitle:{maxWidth:620,margin:"16px auto 0",color:"#aeb8ca",fontSize:17,lineHeight:1.6},statusCard:{display:"flex",gap:14,alignItems:"flex-start",maxWidth:650,margin:"0 auto 22px",padding:"15px 18px",border:"1px solid rgba(52,211,153,.28)",borderRadius:14,background:"rgba(6,78,59,.22)"},statusIcon:{display:"grid",flex:"0 0 auto",width:25,height:25,placeItems:"center",borderRadius:999,color:"#052e22",background:"#6ee7b7",fontWeight:900},statusTitle:{display:"block",color:"#d1fae5",fontSize:14},statusBody:{margin:"4px 0 0",color:"#a7f3d0",fontSize:13,lineHeight:1.5},errorCard:{display:"flex",justifyContent:"center",gap:10,maxWidth:650,margin:"0 auto 22px",padding:"12px 16px",border:"1px solid rgba(248,113,113,.3)",borderRadius:12,color:"#fecaca",background:"rgba(127,29,29,.22)",fontSize:13},grid:{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(min(100%, 300px), 1fr))",gap:16},sceneCard:{display:"flex",minHeight:224,padding:24,flexDirection:"column",alignItems:"stretch",textAlign:"left",color:"#f8fafc",border:"1px solid rgba(148,163,184,.18)",borderRadius:18,background:"linear-gradient(145deg, rgba(30,41,59,.9), rgba(15,23,42,.78))",boxShadow:"0 16px 44px rgba(0,0,0,.2)",cursor:"pointer",fontFamily:"inherit",transition:"border-color .15s ease, transform .15s ease, opacity .15s ease"},sceneCardSelected:{borderColor:"#fb923c",boxShadow:"0 0 0 1px rgba(251,146,60,.25), 0 18px 50px rgba(0,0,0,.28)"},sceneCardMuted:{opacity:.48},sceneTopline:{display:"flex",minHeight:42,alignItems:"center",justifyContent:"space-between"},sceneIcon:{fontSize:34,lineHeight:1},recommended:{padding:"5px 9px",color:"#ffedd5",border:"1px solid rgba(251,146,60,.28)",borderRadius:999,background:"rgba(194,65,12,.25)",fontSize:11,fontWeight:750},sceneTitle:{marginTop:20,color:"#fff",fontSize:20,lineHeight:1.3},sceneDescription:{marginTop:8,color:"#9eabc0",fontSize:14,lineHeight:1.55},sceneAction:{marginTop:"auto",paddingTop:22,color:"#fb923c",fontSize:14,fontWeight:750},footer:{marginTop:26,textAlign:"center"},skipButton:{padding:"9px 15px",color:"#aeb8ca",border:0,background:"transparent",cursor:"pointer",fontFamily:"inherit",fontSize:14,textDecoration:"underline",textUnderlineOffset:4},privacy:{maxWidth:660,margin:"14px auto 0",color:"#64748b",fontSize:12,lineHeight:1.5}};var ie,ne;const Be=typeof chrome<"u"&&((ie=chrome.i18n)!=null&&ie.getUILanguage)?chrome.i18n.getUILanguage():typeof navigator>"u"?"en":((ne=navigator.languages)==null?void 0:ne[0])||navigator.language||"en",K=j(Be),Q=le[K];var re;const _e=((re=he.find(o=>o.code===K))==null?void 0:re.locale)||"en-US";typeof document<"u"&&(document.documentElement.lang=_e,document.title=Q.pageTitle);function qe(){const[o,e]=E.useState({phase:"loading"});return E.useEffect(()=>{let t=!1;return chrome.runtime.sendMessage({type:"ONBOARDING_GET_BOOTSTRAP"}).then(n=>{if(!t){if(!(n!=null&&n.state)){e({phase:"error"});return}e({phase:"ready",response:n})}}).catch(()=>{t||e({phase:"error"})}),()=>{t=!0}},[]),o.phase==="loading"?l.jsx("main",{style:q.page,"aria-busy":"true","aria-label":Q.loadingLabel,children:l.jsx("img",{src:chrome.runtime.getURL("/icon-128.png"),alt:"",width:64,height:64,style:q.logo})}):o.phase==="error"?l.jsxs("main",{style:q.page,children:[l.jsx("img",{src:chrome.runtime.getURL("/icon-128.png"),alt:"CastReader",width:64,height:64,style:q.logo}),l.jsx("p",{style:q.error,children:Q.startupError})]}):o.response.showGuidedOnboarding?l.jsx(Ne,{bootstrap:o.response,language:K}):l.jsx(ze,{})}const q={page:{display:"grid",minHeight:"100vh",margin:0,placeContent:"center",justifyItems:"center",color:"#e2e8f0",background:"#090b12",fontFamily:"-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"},logo:{borderRadius:16,boxShadow:"0 14px 42px rgba(242,101,34,.22)"},error:{maxWidth:420,margin:"20px 24px 0",color:"#cbd5e1",textAlign:"center",lineHeight:1.6}};pe();ge.createRoot(document.getElementById("root")).render(l.jsx(ue.StrictMode,{children:l.jsx(qe,{})}));
