var Ae=Object.defineProperty;var Oe=(t,e,a)=>e in t?Ae(t,e,{enumerable:!0,configurable:!0,writable:!0,value:a}):t[e]=a;var s=(t,e,a)=>Oe(t,typeof e!="symbol"?e+"":e,a);import"./_virtual_wxt-html-plugins-DPbbfBKe.js";import{j as u,r as E,R as Be,a as je}from"./client-Sl0RLO-3.js";import{i as Ie}from"./webextension-api-XTY01BBy.js";import{a as Re}from"./voice-clone-dkao_mEI.js";import{a as W,l as Fe}from"./reading-direction-Al7mC7iu.js";import{D as Ee,Q as Me,a2 as le,k as Ge,_ as Ke,t as I,T as Y,a7 as Ne,V as _e,N as X,a4 as Ue,a0 as Ve,M as de,a8 as He,a9 as ce,aa as $e,a5 as qe,a3 as We,Y as Qe,R as Ye}from"./runtime-ui-copy-Bz_MEhK8.js";import{S as J}from"./constants-C2u5Ni4j.js";import"./audio-manager-C4VH5vTy.js";import"./extension-messages-C4eL-GHF.js";const pe=`
.reading-repair { margin: 12px 0; padding: 12px 0; border-block: 1px solid #ffffff25; }
.reading-repair p { margin: 7px 0; font-size: 12px; line-height: 1.5; opacity: .85; }
.reading-repair button { margin: 4px 0; }
:host {
  all: initial;
  display: block;
  position: fixed;
  top: 32%;
  right: 0;
  --cr-safe-area-top: env(safe-area-inset-top, 0px);
  --cr-safe-area-bottom: env(safe-area-inset-bottom, 0px);
  --cr-visual-viewport-height: 100vh;
  z-index: 2147483647;
  pointer-events: none;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif;
}

.host-wrap {
  pointer-events: auto;
  position: relative;
}
:host(.position-pending) .host-wrap {
  visibility: hidden;
}
.host-wrap.is-dragging,
.host-wrap.is-settling {
  will-change: transform;
}
.host-wrap.is-settling {
  transition: transform 260ms cubic-bezier(0.22, 1, 0.36, 1);
}
.position-status {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
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
/* Feedback stays readable after trial playback finishes or focus leaves the rail. */
.player-panel.idle:has(.feedback-popover.open) { opacity: 1; }

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
  touch-action: none;
  user-select: none;
  -webkit-user-select: none;
  -webkit-touch-callout: none;
}
.primary-btn.position-draggable::before {
  content: '';
  position: absolute;
  /* Keep rapid drag → click usable while the 260ms settle animation is still
     moving the visual target. Width remains the intended 44px; the slightly
     taller vertical target follows the control's only movement axis. */
  inset: -12px -8px;
  border-radius: 50%;
}
.primary-btn:hover {
  background: #ff7838;
  box-shadow: 0 3px 8px rgba(242, 101, 34, 0.5);
}
.primary-btn:active {
  transform: scale(0.94);
}
.primary-btn:focus-visible {
  outline: 2px solid rgba(255, 138, 61, 0.95);
  outline-offset: 3px;
}
.host-wrap.drag-armed .primary-btn {
  transform: scale(1.03);
  box-shadow: 0 0 0 4px rgba(242, 101, 34, 0.16), 0 4px 10px rgba(242, 101, 34, 0.5);
}
.host-wrap.is-dragging .primary-btn {
  cursor: grabbing;
  transform: scale(1.06);
  box-shadow: 0 0 0 5px rgba(242, 101, 34, 0.18), 0 6px 14px rgba(242, 101, 34, 0.52);
}
.host-wrap.is-dragging .player-panel {
  opacity: 1;
  box-shadow: -5px 7px 18px rgba(0, 0, 0, 0.3);
}
.host-wrap.is-dragging .tooltip,
.host-wrap.is-dragging .listen-hint {
  opacity: 0 !important;
  pointer-events: none !important;
}
.primary-btn svg {
  width: 12px;
  height: 12px;
}
.primary-btn.loading {
  cursor: progress;
  box-shadow:
    0 2px 5px rgba(242, 101, 34, 0.35),
    0 0 0 3px rgba(255, 255, 255, 0.18);
}
.primary-btn.loading svg {
  width: 16px;
  height: 16px;
  animation: cr-spin 0.72s linear infinite;
}
.primary-btn.loading .loading-spinner-track {
  stroke: rgba(255, 255, 255, 0.34);
  stroke-width: 2.6;
}
.primary-btn.loading .loading-spinner-arc {
  stroke: #fff;
  stroke-width: 3.2;
  stroke-linecap: round;
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
@media (hover: hover) {
  .player-panel.idle:hover .close-page-btn {
    opacity: 1;
    transform: scale(1);
  }
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
.primary-tooltip {
  align-items: flex-start;
}
.primary-tooltip-action,
.primary-tooltip-drag-hint {
  display: block;
}
.primary-tooltip-drag-hint {
  margin-top: 1px;
  color: rgba(255, 255, 255, 0.68);
  font-size: 10px;
  font-weight: 400;
}
@media (hover: hover) {
  .has-tooltip:hover > .tooltip {
    opacity: 1;
    transform: translateY(-50%) translateX(0);
  }
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
.listen-hint.interactive {
  display: flex;
  width: max-content;
  max-width: min(330px, calc(100vw - 104px));
  align-items: center;
  gap: 10px;
  white-space: normal;
  pointer-events: auto;
}
.listen-hint.interactive > span {
  min-width: 0;
}
.listen-hint-action {
  flex: none;
  max-width: min(180px, 50vw);
  padding: 5px 8px;
  color: #9a3412;
  border: 0;
  border-radius: 6px;
  background: #fff7ed;
  cursor: pointer;
  font: inherit;
  font-size: 11px;
  font-weight: 750;
  line-height: 1.3;
  white-space: normal;
}
.listen-hint-action:focus-visible {
  outline: 2px solid #fff;
  outline-offset: 2px;
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
  transform: translateY(-50%) translateY(var(--cr-popover-shift-y, 0px));
  background: rgba(38, 38, 42, 0.97);
  border-radius: 10px;
  padding: 4px;
  min-width: 100px;
  box-sizing: border-box;
  max-height: min(280px, calc(var(--cr-visual-viewport-height, 100vh) - 24px));
  overflow-y: auto;
  box-shadow: -3px 4px 14px rgba(0, 0, 0, 0.4);
  display: none;
  flex-direction: column;
  gap: 1px;
  backdrop-filter: blur(10px);
  z-index: 7;
}
.popover.open { display: flex; }

.popover-select-field {
  display: flex;
  margin-top: 10px;
  flex-direction: column;
  gap: 5px;
  color: rgba(255, 255, 255, 0.82);
  font-size: 11px;
}
.popover-select {
  width: 100%;
  box-sizing: border-box;
  padding: 7px 8px;
  color: #fff;
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 7px;
  background: #27272a;
  font: inherit;
  font-size: 12px;
}
.popover-select-status {
  margin-top: 7px;
  color: #fecaca;
  font-size: 11px;
  line-height: 1.4;
}

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
  /* The trigger is at 32vh. Keep the centered form inside the viewport. */
  max-height: min(440px, calc(64vh - 40px));
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
.feedback-reading-attachment {
  margin: 10px 0;
  font-size: 12px;
  line-height: 1.5;
  overflow-wrap: anywhere;
}
.feedback-reading-attachment label { cursor: pointer; }
.feedback-reading-attachment input { accent-color: #ff8a50; vertical-align: middle; }
.feedback-reading-attachment details { margin-top: 6px; }
.feedback-reading-attachment summary { cursor: pointer; }
.feedback-reading-attachment details > div { max-height: 150px; overflow-y: auto; }

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

@media (prefers-reduced-motion: reduce) {
  .host-wrap.is-settling {
    transition-duration: 1ms;
  }
  .primary-btn,
  .player-panel {
    transition-duration: 1ms;
  }
}
`,ne=2e3,ze=`

[CastReader reading diagnostic v1]
`;function Xe(t,e){const a=t.trim()+(e?ze+e:"");if(a.length>ne)throw new Error("FEEDBACK_TOO_LONG");return a}const ge={en:{attach:"Include reading position and nearby text",preview:"Preview included text",tooLong:"Feedback is too long. Shorten it or remove the reading details."},zh:{attach:"附上阅读位置与附近原文",preview:"预览附带的原文",tooLong:"反馈内容过长，请缩短描述或取消附带阅读信息。"},ja:{attach:"読み上げ位置と前後の原文を添付",preview:"添付する原文を確認",tooLong:"内容が長すぎます。説明を短くするか、読み上げ情報の添付を解除してください。"},es:{attach:"Incluir posición de lectura y texto cercano",preview:"Ver el texto incluido",tooLong:"El comentario es demasiado largo. Acórtalo o elimina los datos de lectura."},fr:{attach:"Joindre la position de lecture et le texte voisin",preview:"Voir le texte joint",tooLong:"Le commentaire est trop long. Raccourcissez-le ou retirez les détails de lecture."},de:{attach:"Leseposition und umliegenden Text anhängen",preview:"Angehängten Text ansehen",tooLong:"Das Feedback ist zu lang. Kürzen Sie es oder entfernen Sie die Lesedetails."},pt:{attach:"Incluir posição de leitura e texto próximo",preview:"Ver o texto incluído",tooLong:"O comentário é muito longo. Reduza-o ou remova os detalhes de leitura."},it:{attach:"Includi posizione di lettura e testo vicino",preview:"Anteprima del testo incluso",tooLong:"Il commento è troppo lungo. Accorcialo o rimuovi i dettagli di lettura."},hi:{attach:"पढ़ने की स्थिति और आसपास का पाठ जोड़ें",preview:"जोड़े गए पाठ का पूर्वावलोकन",tooLong:"प्रतिक्रिया बहुत लंबी है। इसे छोटा करें या पढ़ने का विवरण हटाएँ।"},nl:{attach:"Leespositie en nabijgelegen tekst toevoegen",preview:"Voorbeeld van toegevoegde tekst",tooLong:"Feedback is te lang. Kort het in of verwijder de leesdetails."},ru:{attach:"Включить позицию чтения и соседний текст",preview:"Предпросмотр включенного текста",tooLong:"Отзыв слишком длинный. Сократите его или удалите сведения о чтении."},ko:{attach:"읽기 위치 및 주변 텍스트 포함",preview:"포함된 텍스트 미리보기",tooLong:"피드백 내용이 너무 깁니다. 내용을 줄이거나 읽기 세부 정보를 제외해 주세요."},ar:{attach:"تضمين موضع القراءة والنص المجاور",preview:"معاينة النص المضمن",tooLong:"التعليق طويل جداً. يرجى تقصيره أو إزالة تفاصيل القراءة."},pl:{attach:"Dołącz pozycję czytania i tekst z otoczenia",preview:"Podgląd dołączonego tekstu",tooLong:"Opinia jest zbyt długa. Skróć ją lub usuń szczegóły dotyczące czytania."},sv:{attach:"Inkludera läsplats och närliggande text",preview:"Förhandsgranska inkluderad text",tooLong:"Återkopplingen är för lång. Förkorta den eller ta bort läsdetaljerna."},da:{attach:"Inkluder læseposition og tekst i nærheden",preview:"Forhåndsvis inkluderede tekst",tooLong:"Tilbagemeldingen er for lang. Forkort den, eller fjern læsedetaljerne."},nb:{attach:"Inkluder lesesposisjon og nærliggende tekst",preview:"Forhåndsvis inkludert tekst",tooLong:"Tilbakemeldingen er for lang. Forkort den eller fjern lese Detaljer."},fi:{attach:"Sisällytä lukemisen sijainti ja lähellä oleva teksti",preview:"Esikatsele sisällytetty teksti",tooLong:"Palaute on liian pitkä. Lyhennä sitä tai poista lukemistiedot."},cs:{attach:"Zahrnout pozici čtení a sousední text",preview:"Náhled zahrnutého textu",tooLong:"Zpětná vazba je příliš dlouhá. Zkráťte ji nebo odstraňte podrobnosti o čtení."},el:{attach:"Συμπεριλάβετε θέση ανάγνωσης και γύρω κείμενο",preview:"Προεπισκόπηση συμπεριλαμβανόμενου κειμένου",tooLong:"Το σχόλιο είναι πολύ μεγάλο. Συντομεύστε το ή αφαιρέστε τις λεπτομέρειες ανάγνωσης."},hu:{attach:"Tartalmazza a olvasási pozíciót és a közeli szöveget",preview:"Előnézet a tartalmazott szövegről",tooLong:"A visszajelzés túl hosszú. Rövidítse vagy távolítsa el a olvasási részleteket."},fil:{attach:"Isama ang posisyon sa pagbabasa at kalapit na teksto",preview:"Preview ng kasamang teksto",tooLong:"Masyadong mahaba ang feedback. Paikliin ito o alisin ang mga detalye ng pagbabasa."},he:{attach:"כלול מיקום קריאה וטקסט סמוך",preview:"תצוגה מקדימה של הטקסט הכלול",tooLong:"המשוב ארוך מדי. קצר אותו או הסר את פרטי הקריאה."},id:{attach:"Sertakan posisi baca dan teks terdekat",preview:"Pratinjau teks yang disertakan",tooLong:"Umpan balik terlalu panjang. Pendekkan atau hapus detail pembacaan."},ms:{attach:"Sertakan kedudukan bacaan dan teks berdekatan",preview:"Pratonton teks yang disertakan",tooLong:"Maklum balas terlalu panjang. Pendekkan atau buang butiran bacaan."},ro:{attach:"Include poziția de citire și textul din apropiere",preview:"Previzualizează textul inclus",tooLong:"Feedback-ul este prea lung. Scurtați-l sau eliminați detaliile de citire."},tr:{attach:"Okuma konumunu ve yakındaki metni dahil et",preview:"Dahil edilen metni önizle",tooLong:"Geri bildirim çok uzun. Kısaltın veya okuma ayrıntılarını kaldırın."},vi:{attach:"Bao gồm vị trí đọc và văn bản lân cận",preview:"Xem trước văn bản được bao gồm",tooLong:"Phản hồi quá dài. Hãy rút ngắn hoặc xóa chi tiết phần đọc."}},ue={en:"Start or pause reading to attach reading details.",zh:"请在朗读或暂停朗读时附带阅读信息。",ja:"読み上げ中または一時停止中に情報を添付できます。",es:"Inicia o pausa la lectura para adjuntar los detalles.",fr:"Lancez ou mettez en pause la lecture pour joindre ses détails.",de:"Starten oder pausieren Sie die Wiedergabe, um Lesedetails anzuhängen.",pt:"Inicie ou pause a leitura para anexar os detalhes.",it:"Avvia o metti in pausa la lettura per allegare i dettagli.",hi:"विवरण जोड़ने के लिए पढ़ना शुरू करें या रोकें।",nl:"Start of pauzeer het lezen om leesdetails bij te voegen.",ru:"Запустите или приостановите чтение, чтобы прикрепить сведения о чтении.",ko:"읽기 세부 정보를 첨부하려면 읽기를 시작하거나 일시정지해 주세요.",ar:"ابدأ القراءة أو أوقفها مؤقتاً لإرفاق تفاصيل القراءة.",pl:"Rozpocznij lub pauzuj czytanie, aby dołączyć szczegóły dotyczące czytania.",sv:"Starta eller pausa läsningen för att bifoga läsdetaljer.",da:"Start eller pause læsning for at vedlægge læsedetaljer.",nb:"Start eller sett pause i lesing for å legge til lese detaljer.",fi:"Aloita tai keskeytä lukeminen liittääksesi lukemistiedot.",cs:"Spusťte nebo pozastavte čtení pro připojení podrobností o čtení.",el:"Ξεκινήστε ή πατήστε παύση ανάγνωσης για να προσαρτήσετε λεπτομέρειες ανάγνωσης.",hu:"Indítsa vagy szünettesse az olvasást a olvasási részletek csatolásához.",fil:"Simulan o i-pause ang pagbabasa upang maikabit ang mga detalye ng pagbabasa.",he:"התחל או השהה קריאה כדי לצרף פרטי קריאה.",id:"Mulai atau jeda pembacaan untuk menyertakan detail pembacaan.",ms:"Mulakan atau jeda bacaan untuk melekatkan butiran bacaan.",ro:"Porniți sau întrerupeți citirea pentru a atașa detaliile de citire.",tr:"Okuma ayrıntılarını eklemek için okumayı başlatın veya duraklatın.",vi:"Bắt đầu hoặc tạm dừng đọc để đính kèm chi tiết phần đọc."},oe=1,Je=.32;function G(t,e,a){return Math.min(a,Math.max(e,t))}function Ze(t,e,a){const o=Number.isFinite(t.top)?t.top:0,i=Number.isFinite(t.height)?Math.max(0,t.height):0,n=Number.isFinite(e)?Math.max(0,e):0,r=Number.isFinite(a.topGap)?Math.max(0,a.topGap):0,l=Number.isFinite(a.bottomGap)?Math.max(0,a.bottomGap):0,c=Number.isFinite(a.topOverflow)?Math.max(0,a.topOverflow):0,p=o+r+c,m=o+i-l-n;if(m>=p)return{min:p,max:m};const P=o+Math.max(0,(i-n)/2);return{min:P,max:P}}function he(t,e){const a=G(Number.isFinite(e)?e:0,0,1);return t.max<=t.min?t.min:t.min+(t.max-t.min)*a}function Z(t,e){return t.max<=t.min?.5:(G(Number.isFinite(e)?e:t.min,t.min,t.max)-t.min)/(t.max-t.min)}function et(t,e,a){const o=Number.isFinite(a)?Math.max(0,a):0;if(t<e.min){const i=e.min-t;return e.min-o*(1-Math.exp(-i/Math.max(1,o)))}if(t>e.max){const i=t-e.max;return e.max+o*(1-Math.exp(-i/Math.max(1,o)))}return t}function tt(t,e,a){const o=e.top,i=e.top+e.height,n=Math.max(0,a),r=Math.max(0,e.height-n*2);return t.height>r?o+e.height/2-(t.top+t.height/2):t.top<o+n?o+n-t.top:t.bottom>i-n?i-n-t.bottom:0}function me(t){if(!t||typeof t!="object")return null;const e=t;return e.version!==oe||e.edge!=="right"||!Number.isFinite(e.safeBandRatio)?null:{version:oe,edge:"right",safeBandRatio:G(e.safeBandRatio,0,1)}}const ee="castreader_pro_settings_banner_dismissed",V="castreader_page_trigger_position_v1",be=16,at=12,it=5,nt=24,te=121,ot=260,ae=500,ke={en:t=>`Reader control moved to ${t}% of the page.`,zh:t=>`朗读控件已移动到页面 ${t}% 处。`,ja:t=>`読み上げコントロールをページの${t}%の位置に移動しました。`,es:t=>`El control de lectura se movió al ${t}% de la página.`,fr:t=>`Le contrôle de lecture a été déplacé à ${t}% de la page.`,de:t=>`Das Vorlesesteuerelement wurde auf ${t}% der Seite verschoben.`,pt:t=>`O controle de leitura foi movido para ${t}% da página.`,it:t=>`Il controllo di lettura è stato spostato al ${t}% della pagina.`,hi:t=>`पढ़ने का कंट्रोल पेज के ${t}% स्थान पर ले जाया गया।`,nl:t=>`Lezerbesturing verplaatst naar ${t}% van de pagina.`,ru:t=>`Управление чтением перемещено на ${t}% страницы.`,ko:t=>`리더 제어 위치가 페이지의 ${t}%로 이동했습니다.`,ar:t=>`انتقل التحكم في القارئ إلى ${t}% من الصفحة.`,pl:t=>`Sterowanie czytaniem przeniesiono na ${t}% strony.`,sv:t=>`Läsarkontroll flyttades till ${t}% av sidan.`,da:t=>`Læserkontrol flyttet til ${t}% af siden.`,nb:t=>`Lesekontroll flyttet til ${t}% av siden.`,fi:t=>`Lukijan ohjaus siirretty ${t}%:iin sivusta.`,cs:t=>`Ovládání čtenáře přesunuto na ${t}% stránky.`,el:t=>`Ο έλεγχος του αναγνώστη μεταφέρθηκε στο ${t}% της σελίδας.`,hu:t=>`Az olvasó vezérlő ${t}%-nál helyezkedik el az oldalon.`,fil:t=>`Ang kontrol ng reader ay inilipat sa ${t}% ng pahina.`,he:t=>`בקרת הקורא הועברה ל-${t}% מהעמוד.`,id:t=>`Kontrol pembaca dipindahkan ke ${t}% dari halaman.`,ms:t=>`Kawalan pembaca dialihkan ke ${t}% halaman.`,ro:t=>`Controlul cititorului mutat la ${t}% din pagină.`,tr:t=>`Okuyucu kontrolü sayfanın ${t}% konumuna taşındı.`,vi:t=>`Điều khiển trình đọc đã được di chuyển đến ${t}% của trang.`},fe={en:"Hold and drag to move",zh:"长按拖动位置",ja:"長押ししてドラッグ",es:"Mantén pulsado y arrastra",fr:"Maintenez puis faites glisser",de:"Halten und zum Verschieben ziehen",pt:"Pressione e arraste para mover",it:"Tieni premuto e trascina",hi:"स्थान बदलने के लिए दबाकर खींचें",nl:"Vasthouden en slepen om te verplaatsen",ru:"Зажмите и перетащите для перемещения",ko:"길게 눌러 드래그하여 이동",ar:"اضغط مع السحب للنقل",pl:"Przytrzymaj i przeciągnij, aby przesunąć",sv:"Håll och dra för att flytta",da:"Hold og træk for at flytte",nb:"Hold og dra for å flytte",fi:"Pidä pohjassa ja vedä siirtääksesi",cs:"Podržte a táhněte pro přesunutí",el:"Κρατήστε και σύρετε για μετακίνηση",hu:"Nyomja meg és húzza a mozgatáshoz",fil:"Pindutin at hilahin upang ilipat",he:"החזק וגרור כדי להזיז",id:"Tahan dan seret untuk memindahkan",ms:"Tahan dan seret untuk alihkan",ro:"Ține apăsat și trage pentru a muta",tr:"Taşımak için basılı tutun ve sürükleyin",vi:"Nhấn giữ và kéo để di chuyển"},ve={en:"Run the getting-started guide",zh:"重新体验首次使用引导",ja:"初回ガイドをもう一度見る",es:"Volver a ver la guía inicial",fr:"Revoir le guide de démarrage",de:"Einführung erneut starten",pt:"Rever o guia de início",it:"Rivedi la guida introduttiva",hi:"शुरुआती गाइड फिर से देखें",nl:"Start de handleiding om aan de slag te gaan",ru:"Запустить руководство по началу работы",ko:"시작 가이드 실행",ar:"تشغيل دليل البدء",pl:"Uruchom przewodnik początkujący",sv:"Kör introduktionsguiden",da:"Kør introduktionsguiden",nb:"Kjør introduksjonsveiledningen",fi:"Suorita aloitusopas",cs:"Spustit průvodce začátkem",el:"Εκκίνηση οδηγού εισαγωγής",hu:"Indulási útmutató futtatása",fil:"Patakbuhin ang gabay para sa mga baguhan",he:"הפעל את מדריך ההתחלה",id:"Jalankan panduan memulai",ms:"Jalankan panduan permulaan",ro:"Rulează ghidul de început",tr:"Başlangıç kılavuzunu çalıştır",vi:"Chạy hướng dẫn bắt đầu"},ye='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 18v-6a9 9 0 0 1 18 0v6"/><path d="M21 19a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3z"/><path d="M3 19a2 2 0 0 0 2 2h1a2 2 0 0 0 2-2v-3a2 2 0 0 0-2-2H3z"/></svg>',rt='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" stroke="none"><polygon points="6 4 20 12 6 20 6 4"/></svg>',st='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" stroke="none"><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></svg>',lt='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="20" y1="4" x2="4" y2="20"/><line x1="4" y1="4" x2="20" y2="20"/></svg>',dt='<svg class="loading-spinner" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" aria-hidden="true"><circle class="loading-spinner-track" cx="12" cy="12" r="8.5"/><path class="loading-spinner-arc" d="M12 3.5a8.5 8.5 0 0 1 8.5 8.5"/></svg>',ct='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="4.5"/><path d="M3.5 21v-1.5A5.5 5.5 0 0 1 9 14h6a5.5 5.5 0 0 1 5.5 5.5V21"/></svg>',pt='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2 4h7a3 3 0 0 1 3 3v13a2.5 2.5 0 0 0-2.5-2.5H2z"/><path d="M22 4h-7a3 3 0 0 0-3 3v13a2.5 2.5 0 0 1 2.5-2.5H22z"/></svg>',gt='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>',ut='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="8" y1="13" x2="16" y2="13"/><line x1="8" y1="17" x2="13" y2="17"/></svg>',xe=[{code:"overview",labelKey:"depthOverview"},{code:"standard",labelKey:"depthStandard"},{code:"deep",labelKey:"depthDeep"}],Pe={en:{listen:"Read this page",pause:"Pause",resume:"Resume",loading:"Loading…",hideOnPage:"Hide on this page",stop:"Stop",speed:"Playback speed",voice:"Voice",lang:"Language",readingLang:"Reading language",sendFeedback:"Send feedback",stopReading:"Stop reading",feedbackTitle:"Quick feedback",feedbackPlaceholder:"Something went wrong? Or a suggestion?",feedbackEmailPlaceholder:"Your email (required)",feedbackEmailRequired:"Please enter your email.",feedbackSend:"Send",feedbackSending:"Sending…",feedbackDone:"Sent! Thank you.",feedbackFailed:"Send failed, please try again.",brainrotOn:"Quick Overview",brainrotOff:"Exit Overview",modeRead:"Read",modeExplain:"Explain",modeBrainrot:"Quick Read",openReader:"Read a file (PDF / EPUB / Word / Text)",settings:"Settings",close:"Close",highlightColorTitle:"Highlight color",explainLangTitle:"Explain in",explainAuto:"Auto (my language)",explainFollow:"Follow page",depthTitle:"Detail level",depthOverview:"Overview",depthStandard:"Standard",depthDeep:"Expert",groupReading:"Reading",groupExplain:"Explain",closeTitle:"Turn off CastReader on {domain}?",closeSession:"Yes, for this session",closeDomain:"Yes, from now on",closeCancel:"No, don’t turn it off",selectionReaderTitle:"Selection reading",switchKindleSite:"Switch Amazon site",stateOn:"On",stateOff:"Off",ytSourceTitle:"Choose what to read",ytCaptions:"🎬 Listen to the captions",ytRecommended:"Recommended",ytPage:"📄 Listen to the page",notSignedIn:"Not signed in",signIn:"Sign in",enablePro:"Enable Pro",quotaPro:"Explain · Pro ∞",quotaTip:t=>`Explain · ${t} left today`,listenQuotaPro:"Listen · Pro ∞",listenQuotaTip:t=>`Listen · ${t} min left today`,logout:"↩ Log out",todayUsage:"Today's usage",remainingMinutes:t=>`${t} min left`,remainingUses:t=>`${t} left`},zh:{listen:"朗读当前页",pause:"暂停",resume:"继续",loading:"加载中…",hideOnPage:"本页隐藏",stop:"停止",speed:"播放速度",voice:"音色",lang:"语言",readingLang:"朗读语言",sendFeedback:"发送反馈",stopReading:"停止朗读",feedbackTitle:"留下反馈",feedbackPlaceholder:"遇到问题？或者有建议？",feedbackEmailPlaceholder:"你的邮箱（必填）",feedbackEmailRequired:"请输入邮箱",feedbackSend:"发送",feedbackSending:"发送中…",feedbackDone:"已发送，谢谢！",feedbackFailed:"发送失败，请重试",brainrotOn:"Quick Overview",brainrotOff:"Exit Overview",modeRead:"朗读",modeExplain:"解读",modeBrainrot:"速读",openReader:"读本地文档（PDF / EPUB / Word / Text）",settings:"设置",close:"关闭",highlightColorTitle:"高亮颜色",explainLangTitle:"讲解语言",explainAuto:"自动（跟随我）",explainFollow:"跟随原文",depthTitle:"讲解详略",depthOverview:"速览",depthStandard:"标准",depthDeep:"专家级",groupReading:"朗读",groupExplain:"解读",closeTitle:"在 {domain} 关闭 CastReader？",closeSession:"本次访问关闭",closeDomain:"从现在起一直关闭",closeCancel:"不关闭",selectionReaderTitle:"划词朗读",switchKindleSite:"切换 Amazon 站点",stateOn:"开",stateOff:"关",ytSourceTitle:"选择朗读来源",ytCaptions:"🎬 听视频字幕",ytRecommended:"推荐",ytPage:"📄 听页面内容",notSignedIn:"未登录",signIn:"登录",enablePro:"开启 Pro",quotaPro:"解读 · Pro 无限",quotaTip:t=>`解读 · 今日还剩 ${t} 次`,listenQuotaPro:"朗读 · Pro 无限",listenQuotaTip:t=>`朗读 · 今日还剩 ${t} 分钟`,logout:"↩ 退出登录",todayUsage:"今日用量",remainingMinutes:t=>`还剩 ${t} 分钟`,remainingUses:t=>`还剩 ${t} 次`},ja:{listen:"このページを読む",pause:"一時停止",resume:"再開",loading:"読み込み中…",hideOnPage:"このページで非表示",stop:"停止",speed:"再生速度",voice:"音声",lang:"言語",readingLang:"読み上げ言語",sendFeedback:"フィードバックを送信",stopReading:"読み上げを停止",feedbackTitle:"クイックフィードバック",feedbackPlaceholder:"問題やご要望をお聞かせください",feedbackEmailPlaceholder:"メールアドレス（必須）",feedbackEmailRequired:"メールアドレスを入力してください。",feedbackSend:"送信",feedbackSending:"送信中…",feedbackDone:"送信しました。ありがとうございます。",feedbackFailed:"送信できませんでした。もう一度お試しください。",brainrotOn:"クイック概要",brainrotOff:"概要を終了",modeRead:"読み上げ",modeExplain:"解説",modeBrainrot:"速読",openReader:"ファイルを読む（PDF / EPUB / Word / Text）",settings:"設定",close:"閉じる",highlightColorTitle:"ハイライト色",explainLangTitle:"解説言語",explainAuto:"自動（自分の言語）",explainFollow:"ページに合わせる",depthTitle:"詳細度",depthOverview:"概要",depthStandard:"標準",depthDeep:"専門",groupReading:"読み上げ",groupExplain:"解説",closeTitle:"{domain} で CastReader をオフにしますか？",closeSession:"このセッションだけオフ",closeDomain:"今後このサイトでオフ",closeCancel:"オフにしない",selectionReaderTitle:"選択テキストの読み上げ",switchKindleSite:"Amazon サイトを切り替える",stateOn:"オン",stateOff:"オフ",ytSourceTitle:"読み上げる内容を選択",ytCaptions:"🎬 字幕を聴く",ytRecommended:"おすすめ",ytPage:"📄 ページを聴く",notSignedIn:"未ログイン",signIn:"ログイン",enablePro:"Pro を有効にする",quotaPro:"解説 · Pro 無制限",quotaTip:t=>`解説 · 本日残り ${t} 回`,listenQuotaPro:"読み上げ · Pro 無制限",listenQuotaTip:t=>`読み上げ · 本日残り ${t} 分`,logout:"↩ ログアウト",todayUsage:"本日の利用量",remainingMinutes:t=>`残り ${t} 分`,remainingUses:t=>`残り ${t} 回`},es:{listen:"Leer esta página",pause:"Pausar",resume:"Reanudar",loading:"Cargando…",hideOnPage:"Ocultar en esta página",stop:"Detener",speed:"Velocidad de reproducción",voice:"Voz",lang:"Idioma",readingLang:"Idioma de lectura",sendFeedback:"Enviar comentarios",stopReading:"Detener lectura",feedbackTitle:"Comentario rápido",feedbackPlaceholder:"¿Algo salió mal o tienes una sugerencia?",feedbackEmailPlaceholder:"Tu correo (obligatorio)",feedbackEmailRequired:"Introduce tu correo.",feedbackSend:"Enviar",feedbackSending:"Enviando…",feedbackDone:"¡Enviado! Gracias.",feedbackFailed:"No se pudo enviar. Inténtalo de nuevo.",brainrotOn:"Resumen rápido",brainrotOff:"Salir del resumen",modeRead:"Leer",modeExplain:"Explicar",modeBrainrot:"Lectura rápida",openReader:"Leer un archivo (PDF / EPUB / Word / Text)",settings:"Ajustes",close:"Cerrar",highlightColorTitle:"Color de resaltado",explainLangTitle:"Explicar en",explainAuto:"Automático (mi idioma)",explainFollow:"Seguir la página",depthTitle:"Nivel de detalle",depthOverview:"Resumen",depthStandard:"Estándar",depthDeep:"Experto",groupReading:"Lectura",groupExplain:"Explicación",closeTitle:"¿Desactivar CastReader en {domain}?",closeSession:"Sí, en esta sesión",closeDomain:"Sí, a partir de ahora",closeCancel:"No desactivar",selectionReaderTitle:"Leer al seleccionar",switchKindleSite:"Cambiar sitio de Amazon",stateOn:"Activado",stateOff:"Desactivado",ytSourceTitle:"Elige qué leer",ytCaptions:"🎬 Escuchar los subtítulos",ytRecommended:"Recomendado",ytPage:"📄 Escuchar la página",notSignedIn:"Sesión no iniciada",signIn:"Iniciar sesión",enablePro:"Activar Pro",quotaPro:"Explicar · Pro ∞",quotaTip:t=>`Explicar · ${t} restantes hoy`,listenQuotaPro:"Escuchar · Pro ∞",listenQuotaTip:t=>`Escuchar · ${t} min restantes hoy`,logout:"↩ Cerrar sesión",todayUsage:"Uso de hoy",remainingMinutes:t=>`${t} min restantes`,remainingUses:t=>`${t} restantes`},fr:{listen:"Lire cette page",pause:"Pause",resume:"Reprendre",loading:"Chargement…",hideOnPage:"Masquer sur cette page",stop:"Arrêter",speed:"Vitesse de lecture",voice:"Voix",lang:"Langue",readingLang:"Langue de lecture",sendFeedback:"Envoyer un commentaire",stopReading:"Arrêter la lecture",feedbackTitle:"Commentaire rapide",feedbackPlaceholder:"Un problème ou une suggestion ?",feedbackEmailPlaceholder:"Votre e-mail (obligatoire)",feedbackEmailRequired:"Saisissez votre e-mail.",feedbackSend:"Envoyer",feedbackSending:"Envoi…",feedbackDone:"Envoyé ! Merci.",feedbackFailed:"Échec de l’envoi. Réessayez.",brainrotOn:"Aperçu rapide",brainrotOff:"Quitter l’aperçu",modeRead:"Lire",modeExplain:"Expliquer",modeBrainrot:"Lecture rapide",openReader:"Lire un fichier (PDF / EPUB / Word / Text)",settings:"Paramètres",close:"Fermer",highlightColorTitle:"Couleur de surbrillance",explainLangTitle:"Expliquer en",explainAuto:"Auto (ma langue)",explainFollow:"Suivre la page",depthTitle:"Niveau de détail",depthOverview:"Aperçu",depthStandard:"Standard",depthDeep:"Expert",groupReading:"Lecture",groupExplain:"Explication",closeTitle:"Désactiver CastReader sur {domain} ?",closeSession:"Oui, pour cette session",closeDomain:"Oui, désormais",closeCancel:"Ne pas désactiver",selectionReaderTitle:"Lecture de la sélection",switchKindleSite:"Changer de site Amazon",stateOn:"Activé",stateOff:"Désactivé",ytSourceTitle:"Choisissez le contenu à lire",ytCaptions:"🎬 Écouter les sous-titres",ytRecommended:"Recommandé",ytPage:"📄 Écouter la page",notSignedIn:"Non connecté",signIn:"Se connecter",enablePro:"Activer Pro",quotaPro:"Expliquer · Pro ∞",quotaTip:t=>`Expliquer · ${t} restant(s) aujourd’hui`,listenQuotaPro:"Écouter · Pro ∞",listenQuotaTip:t=>`Écouter · ${t} min restantes aujourd’hui`,logout:"↩ Se déconnecter",todayUsage:"Utilisation du jour",remainingMinutes:t=>`${t} min restantes`,remainingUses:t=>`${t} restantes`},de:{listen:"Diese Seite vorlesen",pause:"Pause",resume:"Fortsetzen",loading:"Wird geladen…",hideOnPage:"Auf dieser Seite ausblenden",stop:"Stopp",speed:"Wiedergabegeschwindigkeit",voice:"Stimme",lang:"Sprache",readingLang:"Vorlesesprache",sendFeedback:"Feedback senden",stopReading:"Vorlesen beenden",feedbackTitle:"Kurzes Feedback",feedbackPlaceholder:"Ist etwas schiefgelaufen oder hast du einen Vorschlag?",feedbackEmailPlaceholder:"Deine E-Mail-Adresse (erforderlich)",feedbackEmailRequired:"Bitte gib deine E-Mail-Adresse ein.",feedbackSend:"Senden",feedbackSending:"Wird gesendet…",feedbackDone:"Gesendet! Vielen Dank.",feedbackFailed:"Senden fehlgeschlagen. Bitte erneut versuchen.",brainrotOn:"Schnellübersicht",brainrotOff:"Übersicht schließen",modeRead:"Vorlesen",modeExplain:"Erklären",modeBrainrot:"Schnelllesen",openReader:"Datei vorlesen (PDF / EPUB / Word / Text)",settings:"Einstellungen",close:"Schließen",highlightColorTitle:"Markierungsfarbe",explainLangTitle:"Erklären auf",explainAuto:"Automatisch (meine Sprache)",explainFollow:"Seitensprache verwenden",depthTitle:"Detailgrad",depthOverview:"Übersicht",depthStandard:"Standard",depthDeep:"Experte",groupReading:"Vorlesen",groupExplain:"Erklären",closeTitle:"CastReader auf {domain} deaktivieren?",closeSession:"Ja, für diese Sitzung",closeDomain:"Ja, ab jetzt immer",closeCancel:"Nicht deaktivieren",selectionReaderTitle:"Auswahl vorlesen",switchKindleSite:"Amazon-Website wechseln",stateOn:"An",stateOff:"Aus",ytSourceTitle:"Wähle den vorzulesenden Inhalt",ytCaptions:"🎬 Untertitel anhören",ytRecommended:"Empfohlen",ytPage:"📄 Seite anhören",notSignedIn:"Nicht angemeldet",signIn:"Anmelden",enablePro:"Pro aktivieren",quotaPro:"Erklären · Pro ∞",quotaTip:t=>`Erklären · heute noch ${t}`,listenQuotaPro:"Anhören · Pro ∞",listenQuotaTip:t=>`Anhören · heute noch ${t} Min.`,logout:"↩ Abmelden",todayUsage:"Heutige Nutzung",remainingMinutes:t=>`${t} Min. übrig`,remainingUses:t=>`${t} übrig`},pt:{listen:"Ler esta página",pause:"Pausar",resume:"Continuar",loading:"Carregando…",hideOnPage:"Ocultar nesta página",stop:"Parar",speed:"Velocidade de reprodução",voice:"Voz",lang:"Idioma",readingLang:"Idioma da leitura",sendFeedback:"Enviar feedback",stopReading:"Parar leitura",feedbackTitle:"Feedback rápido",feedbackPlaceholder:"Algo deu errado ou tem uma sugestão?",feedbackEmailPlaceholder:"Seu e-mail (obrigatório)",feedbackEmailRequired:"Digite seu e-mail.",feedbackSend:"Enviar",feedbackSending:"Enviando…",feedbackDone:"Enviado! Obrigado.",feedbackFailed:"Falha no envio. Tente novamente.",brainrotOn:"Visão geral rápida",brainrotOff:"Sair da visão geral",modeRead:"Ler",modeExplain:"Explicar",modeBrainrot:"Leitura rápida",openReader:"Ler um arquivo (PDF / EPUB / Word / Text)",settings:"Configurações",close:"Fechar",highlightColorTitle:"Cor do destaque",explainLangTitle:"Explicar em",explainAuto:"Automático (meu idioma)",explainFollow:"Seguir a página",depthTitle:"Nível de detalhe",depthOverview:"Visão geral",depthStandard:"Padrão",depthDeep:"Especialista",groupReading:"Leitura",groupExplain:"Explicação",closeTitle:"Desativar o CastReader em {domain}?",closeSession:"Sim, nesta sessão",closeDomain:"Sim, de agora em diante",closeCancel:"Não desativar",selectionReaderTitle:"Leitura da seleção",switchKindleSite:"Trocar o site da Amazon",stateOn:"Ativado",stateOff:"Desativado",ytSourceTitle:"Escolha o que ler",ytCaptions:"🎬 Ouvir as legendas",ytRecommended:"Recomendado",ytPage:"📄 Ouvir a página",notSignedIn:"Não conectado",signIn:"Entrar",enablePro:"Ativar Pro",quotaPro:"Explicar · Pro ∞",quotaTip:t=>`Explicar · ${t} restantes hoje`,listenQuotaPro:"Ouvir · Pro ∞",listenQuotaTip:t=>`Ouvir · ${t} min restantes hoje`,logout:"↩ Sair",todayUsage:"Uso de hoje",remainingMinutes:t=>`${t} min restantes`,remainingUses:t=>`${t} restantes`},it:{listen:"Leggi questa pagina",pause:"Pausa",resume:"Riprendi",loading:"Caricamento…",hideOnPage:"Nascondi in questa pagina",stop:"Interrompi",speed:"Velocità di riproduzione",voice:"Voce",lang:"Lingua",readingLang:"Lingua di lettura",sendFeedback:"Invia feedback",stopReading:"Interrompi lettura",feedbackTitle:"Feedback rapido",feedbackPlaceholder:"Qualcosa non va o hai un suggerimento?",feedbackEmailPlaceholder:"La tua e-mail (obbligatoria)",feedbackEmailRequired:"Inserisci la tua e-mail.",feedbackSend:"Invia",feedbackSending:"Invio…",feedbackDone:"Inviato! Grazie.",feedbackFailed:"Invio non riuscito. Riprova.",brainrotOn:"Panoramica rapida",brainrotOff:"Esci dalla panoramica",modeRead:"Leggi",modeExplain:"Spiega",modeBrainrot:"Lettura rapida",openReader:"Leggi un file (PDF / EPUB / Word / Text)",settings:"Impostazioni",close:"Chiudi",highlightColorTitle:"Colore evidenziazione",explainLangTitle:"Spiega in",explainAuto:"Automatico (la mia lingua)",explainFollow:"Segui la pagina",depthTitle:"Livello di dettaglio",depthOverview:"Panoramica",depthStandard:"Standard",depthDeep:"Esperto",groupReading:"Lettura",groupExplain:"Spiegazione",closeTitle:"Disattivare CastReader su {domain}?",closeSession:"Sì, per questa sessione",closeDomain:"Sì, da ora in poi",closeCancel:"Non disattivare",selectionReaderTitle:"Lettura della selezione",switchKindleSite:"Cambia sito Amazon",stateOn:"Attivo",stateOff:"Disattivo",ytSourceTitle:"Scegli cosa leggere",ytCaptions:"🎬 Ascolta i sottotitoli",ytRecommended:"Consigliato",ytPage:"📄 Ascolta la pagina",notSignedIn:"Accesso non effettuato",signIn:"Accedi",enablePro:"Attiva Pro",quotaPro:"Spiega · Pro ∞",quotaTip:t=>`Spiega · ${t} rimasti oggi`,listenQuotaPro:"Ascolta · Pro ∞",listenQuotaTip:t=>`Ascolta · ${t} min rimasti oggi`,logout:"↩ Esci",todayUsage:"Utilizzo di oggi",remainingMinutes:t=>`${t} min rimasti`,remainingUses:t=>`${t} rimasti`},hi:{listen:"यह पेज़ पढ़ें",pause:"रोकें",resume:"जारी रखें",loading:"लोड हो रहा है…",hideOnPage:"इस पेज़ पर छिपाएँ",stop:"बंद करें",speed:"प्लेबैक गति",voice:"आवाज़",lang:"भाषा",readingLang:"पढ़ने की भाषा",sendFeedback:"फ़ीडबैक भेजें",stopReading:"पढ़ना बंद करें",feedbackTitle:"त्वरित फ़ीडबैक",feedbackPlaceholder:"कोई समस्या या सुझाव?",feedbackEmailPlaceholder:"आपका ईमेल (आवश्यक)",feedbackEmailRequired:"अपना ईमेल दर्ज करें।",feedbackSend:"भेजें",feedbackSending:"भेजा जा रहा है…",feedbackDone:"भेज दिया! धन्यवाद।",feedbackFailed:"भेजना विफल। फिर कोशिश करें।",brainrotOn:"त्वरित सारांश",brainrotOff:"सारांश बंद करें",modeRead:"पढ़ें",modeExplain:"समझाएँ",modeBrainrot:"तेज़ पठन",openReader:"फ़ाइल पढ़ें (PDF / EPUB / Word / Text)",settings:"सेटिंग्स",close:"बंद करें",highlightColorTitle:"हाइलाइट का रंग",explainLangTitle:"इस भाषा में समझाएँ",explainAuto:"ऑटो (मेरी भाषा)",explainFollow:"पेज़ का अनुसरण",depthTitle:"विस्तार स्तर",depthOverview:"सारांश",depthStandard:"मानक",depthDeep:"विशेषज्ञ",groupReading:"पठन",groupExplain:"व्याख्या",closeTitle:"{domain} पर CastReader बंद करें?",closeSession:"हाँ, इस सत्र के लिए",closeDomain:"हाँ, अब से",closeCancel:"बंद न करें",selectionReaderTitle:"चयन पढ़ना",switchKindleSite:"Amazon साइट बदलें",stateOn:"चालू",stateOff:"बंद",ytSourceTitle:"क्या पढ़ना है चुनें",ytCaptions:"🎬 कैप्शन सुनें",ytRecommended:"सुझावित",ytPage:"📄 पेज़ सुनें",notSignedIn:"साइन इन नहीं",signIn:"साइन इन",enablePro:"Pro चालू करें",quotaPro:"समझाएँ · Pro ∞",quotaTip:t=>`समझाएँ · आज ${t} बाकी`,listenQuotaPro:"सुनें · Pro ∞",listenQuotaTip:t=>`सुनें · आज ${t} मिनट बाकी`,logout:"↩ साइन आउट",todayUsage:"आज का उपयोग",remainingMinutes:t=>`${t} मिनट बाकी`,remainingUses:t=>`${t} बाकी`},nl:{listen:"Lees deze pagina",pause:"Pauzeren",resume:"Hervatten",loading:"Laden…",hideOnPage:"Verbergen op deze pagina",stop:"Stoppen",speed:"Afspeelsnelheid",voice:"Stem",lang:"Taal",readingLang:"Voorleestaal",sendFeedback:"Feedback verzenden",stopReading:"Stoppen met lezen",feedbackTitle:"Snelle feedback",feedbackPlaceholder:"Ging er iets mis? Of heb je een suggestie?",feedbackEmailPlaceholder:"Je e-mailadres (verplicht)",feedbackEmailRequired:"Voer je e-mailadres in.",feedbackSend:"Verzenden",feedbackSending:"Verzenden…",feedbackDone:"Verzonden! Bedankt.",feedbackFailed:"Verzenden mislukt, probeer het opnieuw.",brainrotOn:"Snelle weergave",brainrotOff:"Overzicht sluiten",modeRead:"Lezen",modeExplain:"Uitleg",modeBrainrot:"Snel lezen",openReader:"Lees een bestand (PDF / EPUB / Word / Tekst)",settings:"Instellingen",close:"Sluiten",highlightColorTitle:"Markeerkleur",explainLangTitle:"Uitleggen in",explainAuto:"Automatisch (mijn taal)",explainFollow:"Taal van pagina",depthTitle:"Detailniveau",depthOverview:"Overzicht",depthStandard:"Standaard",depthDeep:"Expert",groupReading:"Voorlezen",groupExplain:"Uitleg",closeTitle:"CastReader uitschakelen op {domain}?",closeSession:"Ja, voor deze sessie",closeDomain:"Ja, vanaf nu",closeCancel:"Nee, niet uitschakelen",selectionReaderTitle:"Selectie lezen",switchKindleSite:"Wissel van Amazon-site",stateOn:"Aan",stateOff:"Uit",ytSourceTitle:"Kies wat je wilt lezen",ytCaptions:"🎬 Luister naar de ondertiteling",ytRecommended:"Aanbevolen",ytPage:"📄 Luister naar de pagina",notSignedIn:"Niet aangemeld",signIn:"Aanmelden",enablePro:"Pro activeren",quotaPro:"Uitleggen · Pro ∞",quotaTip:t=>`Uitleggen · nog ${t} vandaag`,listenQuotaPro:"Luisteren · Pro ∞",listenQuotaTip:t=>`Luisteren · nog ${t} min vandaag`,logout:"↩ Uitloggen",todayUsage:"Gebruik vandaag",remainingMinutes:t=>`${t} min. over`,remainingUses:t=>`nog ${t} over`},ru:{listen:"Читать эту страницу",pause:"Пауза",resume:"Продолжить",loading:"Загрузка…",hideOnPage:"Скрыть на этой странице",stop:"Стоп",speed:"Скорость воспроизведения",voice:"Голос",lang:"Язык",readingLang:"Язык чтения",sendFeedback:"Отправить отзыв",stopReading:"Остановить чтение",feedbackTitle:"Быстрый отзыв",feedbackPlaceholder:"Что-то пошло не так? Или есть предложение?",feedbackEmailPlaceholder:"Ваш email (обязательно)",feedbackEmailRequired:"Пожалуйста, введите ваш email.",feedbackSend:"Отправить",feedbackSending:"Отправка…",feedbackDone:"Отправлено! Спасибо.",feedbackFailed:"Ошибка отправки, попробуйте еще раз.",brainrotOn:"Быстрый обзор",brainrotOff:"Выйти из обзора",modeRead:"Читать",modeExplain:"Объяснить",modeBrainrot:"Быстрое чтение",openReader:"Читать файл (PDF / EPUB / Word / Текст)",settings:"Настройки",close:"Закрыть",highlightColorTitle:"Цвет выделения",explainLangTitle:"Объяснить на",explainAuto:"Авто (мой язык)",explainFollow:"Язык страницы",depthTitle:"Уровень детализации",depthOverview:"Обзор",depthStandard:"Стандартный",depthDeep:"Эксперт",groupReading:"Чтение",groupExplain:"Объяснить",closeTitle:"Выключить CastReader на {domain}?",closeSession:"Да, на этот сеанс",closeDomain:"Да, с этого момента",closeCancel:"Нет, не выключать",selectionReaderTitle:"Чтение выделенного",switchKindleSite:"Переключить сайт Amazon",stateOn:"Вкл",stateOff:"Выкл",ytSourceTitle:"Выберите, что читать",ytCaptions:"🎬 Слушать субтитры",ytRecommended:"Рекомендуемое",ytPage:"📄 Слушать страницу",notSignedIn:"Вход не выполнен",signIn:"Войти",enablePro:"Включить Pro",quotaPro:"Объяснение · Pro ∞",quotaTip:t=>`Объяснение · осталось ${t} на сегодня`,listenQuotaPro:"Прослушивание · Pro ∞",listenQuotaTip:t=>`Прослушивание · осталось ${t} мин на сегодня`,logout:"↩ Выйти",todayUsage:"Использование за сегодня",remainingMinutes:t=>`Осталось ${t} мин`,remainingUses:t=>`Осталось: ${t}`},ko:{listen:"이 페이지 읽기",pause:"일시정지",resume:"다시 시작",loading:"불러오는 중…",hideOnPage:"이 페이지에서 숨기기",stop:"정지",speed:"재생 속도",voice:"음성",lang:"언어",readingLang:"낭독 언어",sendFeedback:"의견 보내기",stopReading:"낭독 중지",feedbackTitle:"빠른 피드백",feedbackPlaceholder:"문제가 발생했나요? 아니면 제안하실 내용이 있나요?",feedbackEmailPlaceholder:"이메일 주소 (필수)",feedbackEmailRequired:"이메일을 입력해 주세요.",feedbackSend:"보내기",feedbackSending:"보내는 중…",feedbackDone:"전송 완료! 감사합니다.",feedbackFailed:"전송에 실패했습니다. 다시 시도해 주세요.",brainrotOn:"빠른 요약",brainrotOff:"요약 종료",modeRead:"읽기",modeExplain:"AI 설명",modeBrainrot:"빠른 읽기",openReader:"파일 읽기 (PDF / EPUB / Word / 텍스트)",settings:"설정",close:"닫기",highlightColorTitle:"하이라이트 색상",explainLangTitle:"설명 언어",explainAuto:"자동 (내 언어)",explainFollow:"페이지 언어",depthTitle:"상세 수준",depthOverview:"요약",depthStandard:"기본",depthDeep:"전문가",groupReading:"읽는 중",groupExplain:"AI 설명",closeTitle:"{domain}에서 CastReader를 끌까요?",closeSession:"예, 이번 세션만",closeDomain:"예, 앞으로 계속",closeCancel:"아니요, 끄지 마세요",selectionReaderTitle:"선택 영역 읽기",switchKindleSite:"아마존 사이트 전환",stateOn:"켜짐",stateOff:"꺼짐",ytSourceTitle:"읽을 내용 선택",ytCaptions:"🎬 자막 듣기",ytRecommended:"추천",ytPage:"📄 페이지 듣기",notSignedIn:"로그인하지 않음",signIn:"로그인",enablePro:"Pro 활성화",quotaPro:"설명 · Pro ∞",quotaTip:t=>`설명 · 오늘 ${t}회 남음`,listenQuotaPro:"듣기 · Pro ∞",listenQuotaTip:t=>`듣기 · 오늘 ${t}분 남음`,logout:"↩ 로그아웃",todayUsage:"오늘 사용량",remainingMinutes:t=>`${t}분 남음`,remainingUses:t=>`${t} 남음`},ar:{listen:"اقرأ هذه الصفحة",pause:"إيقاف مؤقت",resume:"استئناف",loading:"جاري التحميل...",hideOnPage:"إخفاء في هذه الصفحة",stop:"إيقاف",speed:"سرعة التشغيل",voice:"الصوت",lang:"اللغة",readingLang:"لغة القراءة",sendFeedback:"إرسال الملاحظات",stopReading:"إيقاف القراءة",feedbackTitle:"ملاحظات سريعة",feedbackPlaceholder:"هل حدث خطأ ما؟ أو لديك اقتراح؟",feedbackEmailPlaceholder:"بريدك الإلكتروني (مطلوب)",feedbackEmailRequired:"يرجى إدخال بريدك الإلكتروني.",feedbackSend:"إرسال",feedbackSending:"جاري الإرسال…",feedbackDone:"تم الإرسال! شكراً لك.",feedbackFailed:"فشل الإرسال، يرجى المحاولة مرة أخرى.",brainrotOn:"نظرة عامة سريعة",brainrotOff:"خروج من النظرة العامة",modeRead:"قراءة",modeExplain:"شرح",modeBrainrot:"قراءة سريعة",openReader:"قراءة ملف (PDF / EPUB / Word / نص)",settings:"الإعدادات",close:"إغلاق",highlightColorTitle:"لون التظليل",explainLangTitle:"الشرح بـ",explainAuto:"تلقائي (لغتي)",explainFollow:"لغة الصفحة",depthTitle:"مستوى التفاصيل",depthOverview:"نظرة عامة",depthStandard:"قياسي",depthDeep:"خبير",groupReading:"قراءة",groupExplain:"شرح",closeTitle:"هل تريد إيقاف CastReader على {domain}؟",closeSession:"نعم، لهذه الجلسة",closeDomain:"نعم، من الآن فصاعداً",closeCancel:"لا، لا تقم بإيقافه",selectionReaderTitle:"قراءة النص المحدد",switchKindleSite:"تبديل موقع Amazon",stateOn:"تشغيل",stateOff:"إيقاف",ytSourceTitle:"اختر ما تريد قراءته",ytCaptions:"🎬 الاستماع إلى الشرح النصي",ytRecommended:"موصى به",ytPage:"📄 الاستماع إلى الصفحة",notSignedIn:"لم يتم تسجيل الدخول",signIn:"تسجيل الدخول",enablePro:"تفعيل Pro",quotaPro:"شرح · Pro ∞",quotaTip:t=>`شرح · متبقي ${t} اليوم`,listenQuotaPro:"استماع · Pro ∞",listenQuotaTip:t=>`استماع · متبقي ${t} دقيقة اليوم`,logout:"↩ تسجيل الخروج",todayUsage:"استخدام اليوم",remainingMinutes:t=>`متبقي ${t} دقيقة`,remainingUses:t=>`متبقي ${t}`},pl:{listen:"Przeczytaj tę stronę",pause:"Wstrzymaj",resume:"Wznów",loading:"Ładowanie…",hideOnPage:"Ukryj na tej stronie",stop:"Stop",speed:"Prędkość odtwarzania",voice:"Głos",lang:"Język",readingLang:"Język czytania",sendFeedback:"Wyślij opinię",stopReading:"Zatrzymaj czytanie",feedbackTitle:"Szybka opinia",feedbackPlaceholder:"Coś poszło nie tak? A może masz sugestię?",feedbackEmailPlaceholder:"Twój e-mail (wymagany)",feedbackEmailRequired:"Wpisz swój adres e-mail.",feedbackSend:"Wyślij",feedbackSending:"Wysyłanie…",feedbackDone:"Wysłano! Dziękujemy.",feedbackFailed:"Błąd wysyłania, spróbuj ponownie.",brainrotOn:"Szybkie podsumowanie",brainrotOff:"Wyjdź z podsumowania",modeRead:"Czytaj",modeExplain:"Wyjaśnij",modeBrainrot:"Szybkie czytanie",openReader:"Czytaj plik (PDF / EPUB / Word / Tekst)",settings:"Ustawienia",close:"Zamknij",highlightColorTitle:"Kolor podkreślenia",explainLangTitle:"Wyjaśniaj w języku",explainAuto:"Automatycznie (mój język)",explainFollow:"Podążaj za stroną",depthTitle:"Poziom szczegółowości",depthOverview:"Podsumowanie",depthStandard:"Standardowy",depthDeep:"Ekspercki",groupReading:"Czytam",groupExplain:"Wyjaśnij",closeTitle:"Wyłączyć CastReader na {domain}?",closeSession:"Tak, tylko w tej sesji",closeDomain:"Tak, od teraz",closeCancel:"Nie, nie wyłączaj",selectionReaderTitle:"Czytanie zaznaczenia",switchKindleSite:"Przełącz stronę Amazon",stateOn:"Włączone",stateOff:"Wyłączone",ytSourceTitle:"Wybierz, co czytać",ytCaptions:"🎬 Słuchaj napisów",ytRecommended:"Polecane",ytPage:"📄 Słuchaj strony",notSignedIn:"Nie zalogowano",signIn:"Zaloguj się",enablePro:"Aktywuj Pro",quotaPro:"Wyjaśniaj · Pro ∞",quotaTip:t=>`Wyjaśniaj · ${t} min pozostało dzisiaj`,listenQuotaPro:"Słuchaj · Pro ∞",listenQuotaTip:t=>`Słuchaj · ${t} min pozostało dzisiaj`,logout:"↩ Wyloguj się",todayUsage:"Dzisiejsze użycie",remainingMinutes:t=>`Pozostało ${t} min`,remainingUses:t=>`${t} min pozostało`},sv:{listen:"Läs denna sida",pause:"Pausa",resume:"Fortsätt",loading:"Laddar…",hideOnPage:"Dölj på denna sida",stop:"Stoppa",speed:"Upptagningshastighet",voice:"Röst",lang:"Språk",readingLang:"Lässpråk",sendFeedback:"Skicka feedback",stopReading:"Stoppa uppläsning",feedbackTitle:"Snabb feedback",feedbackPlaceholder:"Något gick fel? Eller en förslag?",feedbackEmailPlaceholder:"Din e-post (krävs)",feedbackEmailRequired:"Vänligen ange din e-post.",feedbackSend:"Skicka",feedbackSending:"Skickar…",feedbackDone:"Skickat! Tack.",feedbackFailed:"Misslyckades, försök igen.",brainrotOn:"Snabb översikt",brainrotOff:"Avsluta översikt",modeRead:"Läs",modeExplain:"Förklara",modeBrainrot:"Snabbläsning",openReader:"Läs en fil (PDF / EPUB / Word / Text)",settings:"Inställningar",close:"Stäng",highlightColorTitle:"Markeringsfärg",explainLangTitle:"Förklara på",explainAuto:"Auto (mitt språk)",explainFollow:"Följ sidan",depthTitle:"Detaljnivå",depthOverview:"Översikt",depthStandard:"Standard",depthDeep:"Expert",groupReading:"Läser",groupExplain:"Förklara",closeTitle:"Inaktivera CastReader på {domain}?",closeSession:"Ja, för den här sessionen",closeDomain:"Ja, från och med nu",closeCancel:"Nej, stäng inte av det",selectionReaderTitle:"Urvalsuppläsning",switchKindleSite:"Byt Amazon-sida",stateOn:"På",stateOff:"Av",ytSourceTitle:"Välj vad som ska läsas",ytCaptions:"🎬 Lyssna på undertexter",ytRecommended:"Rekommenderat",ytPage:"📄 Lyssna på sidan",notSignedIn:"Inte inloggad",signIn:"Logga in",enablePro:"Aktivera Pro",quotaPro:"Förklara · Pro ∞",quotaTip:t=>`Förklara · ${t} kvar idag`,listenQuotaPro:"Lyssna · Pro ∞",listenQuotaTip:t=>`Lyssna · ${t} min kvar idag`,logout:"↩ Logga ut",todayUsage:"Användning idag",remainingMinutes:t=>`${t} minuter kvar`,remainingUses:t=>`${t} kvar`},da:{listen:"Læs denne side",pause:"Pause",resume:"Fortsæt",loading:"Indlæser…",hideOnPage:"Skjul på denne side",stop:"Stop",speed:"Afspilningshastighed",voice:"Stemme",lang:"Sprog",readingLang:"Læsesprog",sendFeedback:"Send feedback",stopReading:"Stop reading",feedbackTitle:"Quick feedback",feedbackPlaceholder:"Noget gik galt? Eller har du et forslag?",feedbackEmailPlaceholder:"Din e-mail (påkrævet)",feedbackEmailRequired:"Indtast venligst din e-mail.",feedbackSend:"Send",feedbackSending:"Sender...",feedbackDone:"Sendt! Tak.",feedbackFailed:"Sendning mislykkedes, prøv igen.",brainrotOn:"Hurtig oversigt",brainrotOff:"Afslut oversigt",modeRead:"Læs",modeExplain:"Forklar",modeBrainrot:"Hurtig læsning",openReader:"Læs en fil (PDF / EPUB / Word / Tekst)",settings:"Indstillinger",close:"Luk",highlightColorTitle:"Markeringens farve",explainLangTitle:"Forklar på",explainAuto:"Auto (mit sprog)",explainFollow:"Følg siden",depthTitle:"Detaljeringsgrad",depthOverview:"Oversigt",depthStandard:"Standard",depthDeep:"Ekspert",groupReading:"Læser",groupExplain:"Forklar",closeTitle:"Slå CastReader fra på {domain}?",closeSession:"Ja, til denne session",closeDomain:"Ja, fra nu af",closeCancel:"Nej, slå den ikke fra",selectionReaderTitle:"Læs udvalgt tekst",switchKindleSite:"Skift Amazon-side",stateOn:"Til",stateOff:"Fra",ytSourceTitle:"Vælg hvad der skal læses",ytCaptions:"🎬 Lyt til underteksterne",ytRecommended:"Anbefalet",ytPage:"📄 Lyt til siden",notSignedIn:"Ikke logget ind",signIn:"Log ind",enablePro:"Aktiver Pro",quotaPro:"Forklar · Pro ∞",quotaTip:t=>`Forklar · ${t} tilbage i dag`,listenQuotaPro:"Lytt · Pro ∞",listenQuotaTip:t=>`Lytt · ${t} min tilbage i dag`,logout:"↩ Log ud",todayUsage:"Brug i dag",remainingMinutes:t=>`${t} min tilbage`,remainingUses:t=>`${t} tilbage`},nb:{listen:"Les denne siden",pause:"Pause",resume:"Fortsett",loading:"Laster inn…",hideOnPage:"Skjul på denne siden",stop:"Stopp",speed:"Avspillingshastighet",voice:"Stemme",lang:"Språk",readingLang:"Lesespråk",sendFeedback:"Send tilbakemelding",stopReading:"Stopp lesing",feedbackTitle:"Hurtig tilbakemelding",feedbackPlaceholder:"Noe gikk galt? Eller en forslag?",feedbackEmailPlaceholder:"Din e-post (påkrevd)",feedbackEmailRequired:"Vennligst skriv inn din e-post.",feedbackSend:"Send",feedbackSending:"Sender…",feedbackDone:"Sendt! Takk.",feedbackFailed:"Sending feilet, vennligst prøv igjen.",brainrotOn:"Hurtigoversikt",brainrotOff:"Avslutt oversikt",modeRead:"Les",modeExplain:"Forklar",modeBrainrot:"Hurtiglesing",openReader:"Les en fil (PDF / EPUB / Word / Tekst)",settings:"Innstillinger",close:"Lukk",highlightColorTitle:"Farge for utheving",explainLangTitle:"Forklar på",explainAuto:"Auto (mitt språk)",explainFollow:"Følg siden",depthTitle:"Detaljeringsnivå",depthOverview:"Oversikt",depthStandard:"Standard",depthDeep:"Ekspert",groupReading:"Lese",groupExplain:"Forklar",closeTitle:"Skru av CastReader på {domain}?",closeSession:"Ja, for denne økten",closeDomain:"Ja, fra nå av",closeCancel:"Nei, ikke skru den av",selectionReaderTitle:"Utvalgslesing",switchKindleSite:"Bytt Amazon-nettside",stateOn:"På",stateOff:"Av",ytSourceTitle:"Velg hva som skal leses",ytCaptions:"🎬 Lytt til undertekster",ytRecommended:"Anbefalt",ytPage:"📄 Lytt til siden",notSignedIn:"Ikke logget inn",signIn:"Logg inn",enablePro:"Aktiver Pro",quotaPro:"Forklar · Pro ∞",quotaTip:t=>`Forklar · ${t} igjen i dag`,listenQuotaPro:"Lytt · Pro ∞",listenQuotaTip:t=>`Lytt · ${t} min igjen i dag`,logout:"↩ Logg ut",todayUsage:"Bruk i dag",remainingMinutes:t=>`${t} min igjen`,remainingUses:t=>`${t} igjen`},fi:{listen:"Lue tämä sivu",pause:"Tauko",resume:"Jatka",loading:"Ladataan…",hideOnPage:"Piilota tältä sivulta",stop:"Pysäytä",speed:"Toistonopeus",voice:"Ääni",lang:"Kieli",readingLang:"Lukukieli",sendFeedback:"Lähetä palautetta",stopReading:"Pysäytä lukeminen",feedbackTitle:"Nopea palaute",feedbackPlaceholder:"Jokin meni pieleen? Tai ehdotus?",feedbackEmailPlaceholder:"Sähköpostisi (vaadittu)",feedbackEmailRequired:"Anna sähköpostiosoitteesi.",feedbackSend:"Lähetä",feedbackSending:"Lähetetään…",feedbackDone:"Lähetetty! Kiitos.",feedbackFailed:"Lähetys epäonnistui, yritä uudelleen.",brainrotOn:"Nopea katsaus",brainrotOff:"Poistu katsauksesta",modeRead:"Lue",modeExplain:"Selitä",modeBrainrot:"Nopealuku",openReader:"Lue tiedosto (PDF / EPUB / Word / Teksti)",settings:"Asetukset",close:"Sulje",highlightColorTitle:"Korostuksen väri",explainLangTitle:"Selitä kielellä",explainAuto:"Automaattinen (omalla kielelläni)",explainFollow:"Seuraa sivua",depthTitle:"Tarkkuustaso",depthOverview:"Yleiskatsaus",depthStandard:"Vakio",depthDeep:"Asiantuntija",groupReading:"Luetaan",groupExplain:"Selitä",closeTitle:"Sammutetaanko CastReader kohteessa {domain}?",closeSession:"Kyllä, tälle istunnolle",closeDomain:"Kyllä, tästä lähtien",closeCancel:"Ei, älä sammuta sitä",selectionReaderTitle:"Valinnan lukeminen",switchKindleSite:"Vaihda Amazon-sivusto",stateOn:"Päällä",stateOff:"Pois päältä",ytSourceTitle:"Valitse, mitä luetaan",ytCaptions:"🎬 Kuuntele tekstitykset",ytRecommended:"Suositeltu",ytPage:"📄 Kuuntele sivua",notSignedIn:"Et ole kirjautunut sisään",signIn:"Kirjaudu sisään",enablePro:"Ota käyttöön Pro",quotaPro:"Selitä · Pro ∞",quotaTip:t=>`Selitä · ${t} jäljellä tänään`,listenQuotaPro:"Kuuntele · Pro ∞",listenQuotaTip:t=>`Kuuntele · ${t} min jäljellä tänään`,logout:"↩ Kirjaudu ulos",todayUsage:"Tänään käytetty",remainingMinutes:t=>`${t} min jäljellä`,remainingUses:t=>`${t} jäljellä`},cs:{listen:"Přečíst tuto stránku",pause:"Pozastavit",resume:"Pokračovat",loading:"Načítání…",hideOnPage:"Skrýt na této stránce",stop:"Zastavit",speed:"Rychlost přehrávání",voice:"Hlas",lang:"Jazyk",readingLang:"Jazyk čtení",sendFeedback:"Odeslat zpětnou vazbu",stopReading:"Přestat číst",feedbackTitle:"Rychlá zpětná vazba",feedbackPlaceholder:"Něco se pokazilo? Nebo máte návrh?",feedbackEmailPlaceholder:"Váš e-mail (vyžadováno)",feedbackEmailRequired:"Zadejte svůj e-mail.",feedbackSend:"Odeslat",feedbackSending:"Odesílání…",feedbackDone:"Odesláno! Děkuji.",feedbackFailed:"Odeslání selhalo, zkuste to znovu.",brainrotOn:"Rychlý přehled",brainrotOff:"Opustit přehled",modeRead:"Číst",modeExplain:"Vysvětlit",modeBrainrot:"Rychlé čtení",openReader:"Číst soubor (PDF / EPUB / Word / Text)",settings:"Nastavení",close:"Zavřít",highlightColorTitle:"Barva zvýraznění",explainLangTitle:"Vysvětlit v",explainAuto:"Automaticky (můj jazyk)",explainFollow:"Sledovat stránku",depthTitle:"Úroveň detailu",depthOverview:"Přehled",depthStandard:"Standardní",depthDeep:"Expertní",groupReading:"Čtení",groupExplain:"Vysvětlit",closeTitle:"Vypnout CastReader pro {domain}?",closeSession:"Ano, pro tuto relaci",closeDomain:"Ano, odteď",closeCancel:"Ne, nevypínat",selectionReaderTitle:"Čtení výběru",switchKindleSite:"Přepnout na Amazon",stateOn:"Zapnuto",stateOff:"Vypnuto",ytSourceTitle:"Vyberte, co číst",ytCaptions:"🎬 Poslechnout titulky",ytRecommended:"Doporučené",ytPage:"📄 Poslechnout stránku",notSignedIn:"Nepřihlášeno",signIn:"Přihlásit se",enablePro:"Aktivovat Pro",quotaPro:"Vysvětlit · Pro ∞",quotaTip:t=>`Vysvětlit · ${t} zbývá dnes`,listenQuotaPro:"Poslouchat · Pro ∞",listenQuotaTip:t=>`Poslouchat · ${t} min zbývá dnes`,logout:"↩ Odhlásit se",todayUsage:"Dnešní využití",remainingMinutes:t=>`${t} min zbývá`,remainingUses:t=>`${t} zbývá`},el:{listen:"Διαβάστε αυτή τη σελίδα",pause:"Παύση",resume:"Συνέχεια",loading:"Φόρτωση…",hideOnPage:"Απόκρυψη σε αυτή τη σελίδα",stop:"Διακοπή",speed:"Ταχύτητα αναπαραγωγής",voice:"Φωνή",lang:"Γλώσσα",readingLang:"Γλώσσα ανάγνωσης",sendFeedback:"Αποστολή σχολίων",stopReading:"Διακοπή ανάγνωσης",feedbackTitle:"Γρήγορα σχόλια",feedbackPlaceholder:"Κάτι πήγε στραβά; Ή έχετε μια πρόταση;",feedbackEmailPlaceholder:"Το email σας (απαιτείται)",feedbackEmailRequired:"Παρακαλώ εισάγετε το email σας.",feedbackSend:"Αποστολή",feedbackSending:"Αποστολή…",feedbackDone:"Απεστάλη! Ευχαριστούμε.",feedbackFailed:"Η αποστολή απέτυχε, παρακαλώ δοκιμάστε ξανά.",brainrotOn:"Γρήγορη επισκόπηση",brainrotOff:"Έξοδος από την επισκόπηση",modeRead:"Ανάγνωση",modeExplain:"Εξήγηση",modeBrainrot:"Γρήγορη ανάγνωση",openReader:"Ανάγνωση αρχείου (PDF / EPUB / Word / Κείμενο)",settings:"Ρυθμίσεις",close:"Κλείσιμο",highlightColorTitle:"Χρώμα υπογράμμισης",explainLangTitle:"Επεξήγηση στα",explainAuto:"Αυτόματα (η γλώσσα μου)",explainFollow:"Ακολουθεί τη σελίδα",depthTitle:"Επίπεδο λεπτομέρειας",depthOverview:"Επισκόπηση",depthStandard:"Βασικό",depthDeep:"Ειδικού επιπέδου",groupReading:"Ανάγνωση",groupExplain:"Εξήγηση",closeTitle:"Να απενεργοποιηθεί το CastReader στο {domain};",closeSession:"Ναι, για αυτή τη συνεδρία",closeDomain:"Ναι, από τώρα και στο εξής",closeCancel:"Όχι, μην το απενεργοποιήσετε",selectionReaderTitle:"Ανάγνωση επιλογής",switchKindleSite:"Εναλλαγή στον ιστότοπο της Amazon",stateOn:"Σε λειτουργία",stateOff:"Απενεργοποιημένο",ytSourceTitle:"Επιλέξτε τι να διαβαστεί",ytCaptions:"🎬 Ακρόαση των υπότιτλων",ytRecommended:"Συνιστάται",ytPage:"📄 Ακρόαση της σελίδας",notSignedIn:"Δεν είστε συνδεδεμένοι",signIn:"Σύνδεση",enablePro:"Ενεργοποίηση Pro",quotaPro:"Επεξήγηση · Pro ∞",quotaTip:t=>`Επεξήγηση · ${t} σήμερα`,listenQuotaPro:"Ακρόαση · Pro ∞",listenQuotaTip:t=>`Ακρόαση · ${t} λεπτά σήμερα`,logout:"↩ Έξοδος",todayUsage:"Χρήση σήμερα",remainingMinutes:t=>`${t} λεπτά απομένουν`,remainingUses:t=>`${t} απομένουν`},hu:{listen:"Ennek az oldalnak a felolvasása",pause:"Szünet",resume:"Folytatás",loading:"Betöltés…",hideOnPage:"Elrejtés ezen az oldalon",stop:"Megállítás",speed:"Lejátszási sebesség",voice:"Hang",lang:"Nyelv",readingLang:"Olvasási nyelv",sendFeedback:"Visszajelzés küldése",stopReading:"Olvasás leállítása",feedbackTitle:"Gyors visszajelzés",feedbackPlaceholder:"Hiba történt? Vagy van javaslat?",feedbackEmailPlaceholder:"E-mail címe (kötelező)",feedbackEmailRequired:"Kérjük, adja meg az e-mail címét.",feedbackSend:"Küldés",feedbackSending:"Küldés…",feedbackDone:"Elküldve! Köszönjük.",feedbackFailed:"A küldés sikertelen, kérjük, próbálja újra.",brainrotOn:"Gyors áttekintés",brainrotOff:"Áttekintés bezárása",modeRead:"Olvasson fel",modeExplain:"Magyarázat",modeBrainrot:"Gyors olvasás",openReader:"Fájl olvasása felolvasva (PDF / EPUB / Word / Szöveg)",settings:"Beállítások",close:"Bezárás",highlightColorTitle:"Kiemelés színe",explainLangTitle:"Magyarázat nyelve",explainAuto:"Automatikus (az Ön nyelve)",explainFollow:"Követi a oldalt",depthTitle:"Részletesség szintje",depthOverview:"Áttekintés",depthStandard:"Szabványos",depthDeep:"Haladó",groupReading:"Olvasás",groupExplain:"Magyarázat",closeTitle:"Kikapcsolja a CastReader-t a(z) {domain} oldalon?",closeSession:"Igen, erre a munkamenetre",closeDomain:"Igen, mostantól",closeCancel:"Nem, ne kapcsolja ki",selectionReaderTitle:"Kijelölés felolvasása",switchKindleSite:"Amazon oldal váltása",stateOn:"Bekapcsolva",stateOff:"Kikapcsolva",ytSourceTitle:"Válassza ki, mit olvasson fel",ytCaptions:"🎬 Feliratok felolvasása",ytRecommended:"Ajánlott",ytPage:"📄 Oldal felolvasása",notSignedIn:"Nincs bejelentkezve",signIn:"Bejelentkezés",enablePro:"Pro engedélyezése",quotaPro:"Magyarázat · Pro ∞",quotaTip:t=>`Magyarázat · ${t} maradt ma`,listenQuotaPro:"Felolvasás · Pro ∞",listenQuotaTip:t=>`Felolvasás · ${t} perc maradt ma`,logout:"↩ Kijelentkezés",todayUsage:"Mai használat",remainingMinutes:t=>`${t} perc maradt`,remainingUses:t=>`${t} maradt`},fil:{listen:"Basahin ang pahinang ito",pause:"I-pause",resume:"Ipagpatuloy",loading:"Naglo-load…",hideOnPage:"Itago sa pahinang ito",stop:"Itigil",speed:"Bilis ng playback",voice:"Boses",lang:"Wika",readingLang:"Wika ng pagbabasa",sendFeedback:"Magpadala ng puna",stopReading:"Itigil ang pagbabasa",feedbackTitle:"Mabilis na puna",feedbackPlaceholder:"May naging problema? O may mungkahi?",feedbackEmailPlaceholder:"Iyong email (kinakailangan)",feedbackEmailRequired:"Pakilagay ang iyong email.",feedbackSend:"Ipadala",feedbackSending:"Ipinapadala…",feedbackDone:"Naipadala! Salamat.",feedbackFailed:"Nabigo ang pagpapadala, subukan muli.",brainrotOn:"Mabilis na Buod",brainrotOff:"Lumabas sa Buod",modeRead:"Basahin",modeExplain:"Ipaliwanag",modeBrainrot:"Mabilis na Pagbasa",openReader:"Magbasa ng file (PDF / EPUB / Word / Text)",settings:"Mga Setting",close:"Isara",highlightColorTitle:"Kulay ng highlight",explainLangTitle:"Ipaliwanag sa",explainAuto:"Auto (aking wika)",explainFollow:"Sundan ang pahina",depthTitle:"Antas ng detalye",depthOverview:"Pangkalahatan",depthStandard:"Karaniwan",depthDeep:"Eksperto",groupReading:"Binabasa",groupExplain:"Ipaliwanag",closeTitle:"I-off ang CastReader sa {domain}?",closeSession:"Oo, para sa sesyong ito",closeDomain:"Oo, mula ngayon",closeCancel:"Hindi, huwag i-off",selectionReaderTitle:"Pagbasa ng napili",switchKindleSite:"Lumipat ng site ng Amazon",stateOn:"Naka-on",stateOff:"Naka-off",ytSourceTitle:"Piliin kung ano ang babasahin",ytCaptions:"🎬 Pakinggan ang mga subtitle",ytRecommended:"Inirerekomenda",ytPage:"📄 Pakinggan ang pahina",notSignedIn:"Hindi naka-sign in",signIn:"Mag-sign in",enablePro:"I-enable ang Pro",quotaPro:"Ipaliwanag · Pro ∞",quotaTip:t=>`Ipaliwanag · ${t} natitira ngayon`,listenQuotaPro:"Pakinggan · Pro ∞",listenQuotaTip:t=>`Makinig · ${t} min natitira ngayon`,logout:"↩ Mag-log out",todayUsage:"Paggamit ngayong araw",remainingMinutes:t=>`${t} min natitira`,remainingUses:t=>`${t} natitira`},he:{listen:"קרא עמוד זה",pause:"השהה",resume:"המשך",loading:"טוען…",hideOnPage:"הסתר בעמוד זה",stop:"עצור",speed:"מהירות השמעה",voice:"קול",lang:"שפה",readingLang:"שפת קריאה",sendFeedback:"שלח משוב",stopReading:"הפסק קריאה",feedbackTitle:"משוב מהיר",feedbackPlaceholder:"משהו השתבש? או יש לך הצעה?",feedbackEmailPlaceholder:"האימייל שלך (חובה)",feedbackEmailRequired:"נא להזין את האימייל שלך.",feedbackSend:"שלח",feedbackSending:"שולח…",feedbackDone:"נשלח! תודה.",feedbackFailed:"השליחה נכשלה, נסה שוב.",brainrotOn:"סקירה מהירה",brainrotOff:"יציאה מסקירה",modeRead:"קרא",modeExplain:"הסבר",modeBrainrot:"קריאה מהירה",openReader:"קרא קובץ (PDF / EPUB / Word / טקסט)",settings:"הגדרות",close:"סגור",highlightColorTitle:"צבע הדגשה",explainLangTitle:"הסבר ב",explainAuto:"אוטומטי (השפה שלי)",explainFollow:"עקוב אחר העמוד",depthTitle:"רמת פירוט",depthOverview:"סקירה כללית",depthStandard:"סטנדרטי",depthDeep:"מומחה",groupReading:"קורא",groupExplain:"הסבר",closeTitle:"להשבית את CastReader ב-{domain}?",closeSession:"כן, להפעלה זו",closeDomain:"כן, מעתה והלאה",closeCancel:"לא, אל תשבית",selectionReaderTitle:"קריאת בחירה",switchKindleSite:"החלף אתר אמזון",stateOn:"מופעל",stateOff:"כבוי",ytSourceTitle:"בחר מה לקרוא",ytCaptions:"🎬 האזן לכתוביות",ytRecommended:"מומלץ",ytPage:"📄 האזן לדף",notSignedIn:"לא מחובר",signIn:"כניסה",enablePro:"הפעל Pro",quotaPro:"הסבר · Pro ∞",quotaTip:t=>`הסבר · נותרו ${t} היום`,listenQuotaPro:"האזנה · Pro ∞",listenQuotaTip:t=>`האזנה · נותרו ${t} דקות היום`,logout:"↩ התנתק",todayUsage:"שימוש היום",remainingMinutes:t=>`${t} דקות נותרו`,remainingUses:t=>`נותרו ${t}`},id:{listen:"Baca halaman ini",pause:"Jeda",resume:"Lanjutkan",loading:"Memuat…",hideOnPage:"Sembunyikan di halaman ini",stop:"Berhenti",speed:"Kecepatan pemutaran",voice:"Suara",lang:"Bahasa",readingLang:"Bahasa pembacaan",sendFeedback:"Kirim umpan balik",stopReading:"Hentikan pembacaan",feedbackTitle:"Umpan balik cepat",feedbackPlaceholder:"Ada yang salah? Atau ada saran?",feedbackEmailPlaceholder:"Email Anda (wajib)",feedbackEmailRequired:"Silakan masukkan email Anda.",feedbackSend:"Kirim",feedbackSending:"Mengirim…",feedbackDone:"Terkirim! Terima kasih.",feedbackFailed:"Gagal mengirim, silakan coba lagi.",brainrotOn:"Ringkasan Cepat",brainrotOff:"Keluar dari Ringkasan",modeRead:"Baca",modeExplain:"Jelaskan",modeBrainrot:"Baca Cepat",openReader:"Baca file (PDF / EPUB / Word / Teks)",settings:"Pengaturan",close:"Tutup",highlightColorTitle:"Warna sorotan",explainLangTitle:"Jelaskan dalam",explainAuto:"Otomatis (bahasa saya)",explainFollow:"Ikuti halaman",depthTitle:"Tingkat detail",depthOverview:"Ringkasan",depthStandard:"Standar",depthDeep:"Ahli",groupReading:"Membaca",groupExplain:"Jelaskan",closeTitle:"Nonaktifkan CastReader di {domain}?",closeSession:"Ya, untuk sesi ini",closeDomain:"Ya, mulai sekarang",closeCancel:"Tidak, jangan nonaktifkan",selectionReaderTitle:"Baca pilihan teks",switchKindleSite:"Ganti situs Amazon",stateOn:"Aktif",stateOff:"Nonaktif",ytSourceTitle:"Pilih yang akan dibaca",ytCaptions:"🎬 Dengarkan teks tertutup",ytRecommended:"Direkomendasikan",ytPage:"📄 Dengarkan halaman",notSignedIn:"Belum masuk",signIn:"Masuk",enablePro:"Aktifkan Pro",quotaPro:"Jelaskan · Pro ∞",quotaTip:t=>`Jelaskan · sisa ${t} hari ini`,listenQuotaPro:"Dengarkan · Pro ∞",listenQuotaTip:t=>`Dengarkan · sisa ${t} menit hari ini`,logout:"↩ Keluar",todayUsage:"Penggunaan hari ini",remainingMinutes:t=>`${t} mnt tersisa`,remainingUses:t=>`Sisa ${t}`},ms:{listen:"Baca halaman ini",pause:"Jeda",resume:"Sambung semula",loading:"Memuatkan…",hideOnPage:"Sembunyikan pada halaman ini",stop:"Henti",speed:"Kelajuan main balik",voice:"Suara",lang:"Bahasa",readingLang:"Bahasa pembacaan",sendFeedback:"Hantar maklum balas",stopReading:"Hentikan bacaan",feedbackTitle:"Maklum balas pantas",feedbackPlaceholder:"Ada masalah? Atau ada cadangan?",feedbackEmailPlaceholder:"E-mel anda (wajib)",feedbackEmailRequired:"Sila masukkan e-mel anda.",feedbackSend:"Hantar",feedbackSending:"Menghantar…",feedbackDone:"Dihantar! Terima kasih.",feedbackFailed:"Gagal dihantar, sila cuba lagi.",brainrotOn:"Ringkasan Pantas",brainrotOff:"Keluar daripada Ringkasan",modeRead:"Baca",modeExplain:"Terangkan",modeBrainrot:"Bacaan Pantas",openReader:"Baca fail (PDF / EPUB / Word / Teks)",settings:"Tetapan",close:"Tutup",highlightColorTitle:"Warna sorotan",explainLangTitle:"Terangkan dalam",explainAuto:"Auto (bahasa saya)",explainFollow:"Ikuti halaman",depthTitle:"Tahap perincian",depthOverview:"Gambaran keseluruhan",depthStandard:"Piawai",depthDeep:"Pakar",groupReading:"Membaca",groupExplain:"Terangkan",closeTitle:"Matikan CastReader di {domain}?",closeSession:"Ya, untuk sesi ini",closeDomain:"Ya, mulai sekarang",closeCancel:"Tidak, jangan matikan",selectionReaderTitle:"Bacaan pilihan",switchKindleSite:"Tukar tapak Amazon",stateOn:"Hidup",stateOff:"Mati",ytSourceTitle:"Pilih apa yang hendak dibaca",ytCaptions:"🎬 Dengar kapsyen",ytRecommended:"Disyorkan",ytPage:"📄 Dengar halaman",notSignedIn:"Belum log masuk",signIn:"Log masuk",enablePro:"Dayakan Pro",quotaPro:"Terangkan · Pro ∞",quotaTip:t=>`Terangkan · ${t} baki hari ini`,listenQuotaPro:"Dengar · Pro ∞",listenQuotaTip:t=>`Dengar · ${t} min tinggal hari ini`,logout:"↩ Log keluar",todayUsage:"Penggunaan hari ini",remainingMinutes:t=>`${t} minit tinggal`,remainingUses:t=>`${t} tinggal`},ro:{listen:"Citește această pagină",pause:"Pauză",resume:"Reia",loading:"Se încarcă…",hideOnPage:"Ascunde pe această pagină",stop:"Oprește",speed:"Viteza de redare",voice:"Voce",lang:"Limbă",readingLang:"Limba de lectură",sendFeedback:"Trimite feedback",stopReading:"Oprește citirea",feedbackTitle:"Feedback rapid",feedbackPlaceholder:"Ceva nu a funcționat? Sau ai o sugestie?",feedbackEmailPlaceholder:"E-mailul tău (obligatoriu)",feedbackEmailRequired:"Te rugăm să introduci e-mailul.",feedbackSend:"Trimite",feedbackSending:"Se trimite…",feedbackDone:"Trimis! Mulțumim.",feedbackFailed:"Trimiterea a eșuat, te rugăm să încerci din nou.",brainrotOn:"Prezentare generală rapidă",brainrotOff:"Ieși din prezentarea generală",modeRead:"Citește",modeExplain:"Explică",modeBrainrot:"Citire rapidă",openReader:"Citește un fișier (PDF / EPUB / Word / Text)",settings:"Setări",close:"Închide",highlightColorTitle:"Culoarea evidențierii",explainLangTitle:"Explică în",explainAuto:"Automat (limba mea)",explainFollow:"Urmărește pagina",depthTitle:"Nivel de detaliu",depthOverview:"Prezentare generală",depthStandard:"Standard",depthDeep:"Expert",groupReading:"Se citește",groupExplain:"Explică",closeTitle:"Dezactivați CastReader pe {domain}?",closeSession:"Da, pentru această sesiune",closeDomain:"Da, de acum înainte",closeCancel:"Nu, nu îl dezactivați",selectionReaderTitle:"Citirea selecției",switchKindleSite:"Comutați site-ul Amazon",stateOn:"Activat",stateOff:"Dezactivat",ytSourceTitle:"Alegeți ce să citiți",ytCaptions:"🎬 Ascultați subtitrările",ytRecommended:"Recomandat",ytPage:"📄 Ascultați pagina",notSignedIn:"Neconectat",signIn:"Conectează-te",enablePro:"Activați Pro",quotaPro:"Explică · Pro ∞",quotaTip:t=>`Explică · ${t} rămase astăzi`,listenQuotaPro:"Ascultă · Pro ∞",listenQuotaTip:t=>`Ascultă · ${t} min rămase astăzi`,logout:"↩ Deconectare",todayUsage:"Utilizarea de astăzi",remainingMinutes:t=>`${t} min rămase`,remainingUses:t=>`${t} rămase`},tr:{listen:"Bu sayfayı oku",pause:"Duraklat",resume:"Devam et",loading:"Yükleniyor…",hideOnPage:"Bu sayfada gizle",stop:"Durdur",speed:"Oynatma hızı",voice:"Ses",lang:"Dil",readingLang:"Okuma dili",sendFeedback:"Geri bildirim gönder",stopReading:"Okumayı durdur",feedbackTitle:"Hızlı geri bildirim",feedbackPlaceholder:"Bir sorun mu oluştu? Yoksa bir öneriniz mi var?",feedbackEmailPlaceholder:"E-posta adresiniz (zorunlu)",feedbackEmailRequired:"Lütfen e-posta adresinizi girin.",feedbackSend:"Gönder",feedbackSending:"Gönderiliyor…",feedbackDone:"Gönderildi! Teşekkürler.",feedbackFailed:"Gönderme başarısız, lütfen tekrar deneyin.",brainrotOn:"Hızlı Genel Bakış",brainrotOff:"Genel Bakıştan Çık",modeRead:"Oku",modeExplain:"Açıkla",modeBrainrot:"Hızlı Oku",openReader:"Bir dosya oku (PDF / EPUB / Word / Metin)",settings:"Ayarlar",close:"Kapat",highlightColorTitle:"Vurgu rengi",explainLangTitle:"Şu dilde açıkla:",explainAuto:"Otomatik (benim dilim)",explainFollow:"Sayfayı takip et",depthTitle:"Ayrıntı düzeyi",depthOverview:"Genel bakış",depthStandard:"Standart",depthDeep:"Uzman",groupReading:"Okunuyor",groupExplain:"Açıkla",closeTitle:"CastReader {domain} üzerinde kapatılsın mı?",closeSession:"Evet, bu oturum için",closeDomain:"Evet, bundan sonra",closeCancel:"Hayır, kapatma",selectionReaderTitle:"Seçili metni oku",switchKindleSite:"Amazon sitesini değiştir",stateOn:"Açık",stateOff:"Kapalı",ytSourceTitle:"Okunacak içeriği seç",ytCaptions:"🎬 Altyazıları dinle",ytRecommended:"Önerilen",ytPage:"📄 Sayfayı dinle",notSignedIn:"Oturum açılmadı",signIn:"Giriş yap",enablePro:"Pro'yu etkinleştir",quotaPro:"Açıkla · Pro ∞",quotaTip:t=>`Açıkla · bugün ${t} kaldı`,listenQuotaPro:"Dinle · Pro ∞",listenQuotaTip:t=>`Dinle · Bugün ${t} dk kaldı`,logout:"↩ Çıkış yap",todayUsage:"Bugünkü kullanım",remainingMinutes:t=>`${t} dk kaldı`,remainingUses:t=>`${t} kaldı`},vi:{listen:"Đọc trang này",pause:"Tạm dừng",resume:"Tiếp tục",loading:"Đang tải…",hideOnPage:"Ẩn trên trang này",stop:"Dừng",speed:"Tốc độ phát",voice:"Giọng đọc",lang:"Ngôn ngữ",readingLang:"Ngôn ngữ đọc",sendFeedback:"Gửi phản hồi",stopReading:"Dừng đọc",feedbackTitle:"Phản hồi nhanh",feedbackPlaceholder:"Có sự cố xảy ra? Hay bạn có gợi ý?",feedbackEmailPlaceholder:"Email của bạn (bắt buộc)",feedbackEmailRequired:"Vui lòng nhập email của bạn.",feedbackSend:"Gửi",feedbackSending:"Đang gửi…",feedbackDone:"Đã gửi! Cảm ơn bạn.",feedbackFailed:"Gửi thất bại, vui lòng thử lại.",brainrotOn:"Tổng quan nhanh",brainrotOff:"Thoát chế độ xem tổng quan",modeRead:"Đọc",modeExplain:"Giải thích",modeBrainrot:"Đọc nhanh",openReader:"Đọc tệp (PDF / EPUB / Word / Văn bản)",settings:"Cài đặt",close:"Đóng",highlightColorTitle:"Màu đánh dấu",explainLangTitle:"Giải thích bằng",explainAuto:"Tự động (ngôn ngữ của tôi)",explainFollow:"Theo dõi trang",depthTitle:"Mức độ chi tiết",depthOverview:"Tổng quan",depthStandard:"Tiêu chuẩn",depthDeep:"Chuyên gia",groupReading:"Đang đọc",groupExplain:"Giải thích",closeTitle:"Tắt CastReader trên {domain}?",closeSession:"Có, cho phiên này",closeDomain:"Có, từ bây giờ",closeCancel:"Không, không tắt",selectionReaderTitle:"Đọc phần đã chọn",switchKindleSite:"Chuyển trang Amazon",stateOn:"Bật",stateOff:"Tắt",ytSourceTitle:"Chọn nội dung cần đọc",ytCaptions:"🎬 Nghe phụ đề",ytRecommended:"Đề xuất",ytPage:"📄 Nghe trang web",notSignedIn:"Chưa đăng nhập",signIn:"Đăng nhập",enablePro:"Kích hoạt Pro",quotaPro:"Giải thích · Pro ∞",quotaTip:t=>`Giải thích · còn ${t} hôm nay`,listenQuotaPro:"Nghe · Pro ∞",listenQuotaTip:t=>`Nghe · còn ${t} phút hôm nay`,logout:"↩ Đăng xuất",todayUsage:"Mức sử dụng hôm nay",remainingMinutes:t=>`Còn lại ${t} phút`,remainingUses:t=>`Còn lại ${t}`}};function $(){return qe()}function ie(){return[{code:"auto"},{code:"follow"},...$().map(({code:t,label:e})=>({code:t,nativeLabel:e}))]}class ht{constructor(e,a,o={}){s(this,"host");s(this,"shadow");s(this,"wrap");s(this,"panel");s(this,"primaryBtn");s(this,"primaryTooltip");s(this,"positionStatus",null);s(this,"listenHint");s(this,"listenHintTimer",null);s(this,"secondaryRow");s(this,"speedBtn");s(this,"explainBtn");s(this,"settingsBtn");s(this,"settingsPopover");s(this,"currentMode","read");s(this,"brainTooltip");s(this,"stopConfirmPopover");s(this,"feedbackPopover");s(this,"youtubeSourcePopover");s(this,"llmAutoActive",!1);s(this,"onboardingActive",!1);s(this,"hoverExpanded",!1);s(this,"hoverCollapseTimer",null);s(this,"stopBtn");s(this,"speedPopover");s(this,"noticePopover");s(this,"ratingPopover");s(this,"closePopover");s(this,"closePageBtn");s(this,"state","idle");s(this,"callbacks");s(this,"labels");s(this,"uiLanguage","en");s(this,"currentSpeed",Ee);s(this,"currentVoiceId",null);s(this,"currentExplainLang","auto");s(this,"currentDepth","standard");s(this,"settingsView","root");s(this,"currentHighlightColor",Me);s(this,"selectionReaderOn",!0);s(this,"voiceOptions",[]);s(this,"currentDetectedLang","en");s(this,"proEntitled",!1);s(this,"proStatusKnown",!1);s(this,"proBannerDismissalLoaded",!1);s(this,"proBannerDismissed",!1);s(this,"proBannerImpressionTracked",!1);s(this,"draggable");s(this,"persistPosition");s(this,"positionInitialized",!1);s(this,"positionInitGeneration",0);s(this,"safeBandRatio",.5);s(this,"expandedPanelHeight",te);s(this,"activePointerId",null);s(this,"activePointerType","");s(this,"pointerStartX",0);s(this,"pointerStartY",0);s(this,"latestPointerX",0);s(this,"latestPointerY",0);s(this,"dragStartTop",0);s(this,"dragVisualTop",0);s(this,"dragVisibleBounds",{min:0,max:0});s(this,"dragIntent",{holdMs:180,moveThreshold:6,armedMoveThreshold:2});s(this,"dragArmed",!1);s(this,"dragging",!1);s(this,"longPressTimer",null);s(this,"dragFrame",null);s(this,"settleFrame",null);s(this,"settleTimer",null);s(this,"viewportFrame",null);s(this,"popoverFrame",null);s(this,"suppressPrimaryClickUntil",0);s(this,"popoverMutationObserver",null);s(this,"popoverResizeObserver",null);s(this,"positionLifecycleBound",!1);s(this,"pointerFallbackBound",!1);s(this,"account",null);s(this,"accountMenuOpen",!1);s(this,"accountSession",null);s(this,"listenQuota",null);s(this,"quickreadQuota",null);s(this,"documentClickHandler",null);s(this,"releaseSettingsSurface",null);s(this,"handleFallbackPointerMove",e=>{this.handlePositionPointerMove(e)});s(this,"handleFallbackPointerUp",e=>{this.handlePositionPointerUp(e)});s(this,"handleFallbackPointerCancel",e=>{e.pointerId===this.activePointerId&&this.cancelPositionGesture(!0)});s(this,"handleViewportChange",()=>{this.syncVisualViewportCssVariable(),this.draggable?this.scheduleViewportCorrection():this.schedulePopoverPositioning()});s(this,"handleVisibilityChange",()=>{document.visibilityState==="hidden"&&this.activePointerId!==null&&this.cancelPositionGesture(!0)});s(this,"handlePositionStorageChange",(e,a)=>{var i;if(a!=="local"||this.activePointerId!==null)return;const o=me((i=e[V])==null?void 0:i.newValue);!o||Math.abs(o.safeBandRatio-this.safeBandRatio)<1e-4||(this.safeBandRatio=o.safeBandRatio,this.positionInitialized&&this.applyStoredPosition(!0))});s(this,"lastAppliedState",null);s(this,"qrForeignTip",null);const i=W(e);this.uiLanguage=i,this.labels=Pe[i]||Pe.en,this.callbacks=a,this.draggable=o.draggable!==!1,this.persistPosition=o.persistPosition!==!1,this.host=document.createElement("div"),this.host.id="castreader-page-trigger",Re(this.host,i),this.host.setAttribute("data-castreader","page-trigger"),this.shadow=this.host.attachShadow({mode:"open"});const n=document.createElement("style");n.textContent=pe,this.shadow.appendChild(n),this.wrap=document.createElement("div"),this.wrap.className="host-wrap",this.panel=this.buildPanel(),this.wrap.appendChild(this.panel),this.shadow.appendChild(this.wrap),this.draggable&&(this.positionStatus=document.createElement("div"),this.positionStatus.className="position-status",this.positionStatus.setAttribute("aria-live","polite"),this.positionStatus.setAttribute("aria-atomic","true"),this.shadow.appendChild(this.positionStatus)),this.applyState(),this.loadProBannerDismissal(),le().then(()=>this.refreshSettingsPopover())}setAccountSession(e){this.accountSession=e,e.status!=="authenticated"&&(this.accountMenuOpen=!1),this.refreshSettingsPopover()}attach(e=document.body){this.host.isConnected||e.appendChild(this.host),this.bindPositionLifecycle(),this.draggable?this.positionInitialized?this.applyStoredPosition(!1):(this.host.classList.add("position-pending"),this.initializePosition()):(this.syncVisualViewportCssVariable(),this.schedulePopoverPositioning()),this.documentClickHandler||(this.documentClickHandler=a=>{a.composedPath().includes(this.host)||this.closeAllPopovers()},document.addEventListener("click",this.documentClickHandler,!0))}detach(){this.unbindPositionLifecycle(),this.cancelPositionGesture(!1),this.cancelSettlementAtCurrentPosition(),this.positionInitGeneration+=1,this.documentClickHandler&&(document.removeEventListener("click",this.documentClickHandler,!0),this.documentClickHandler=null),this.host.isConnected&&this.host.remove()}setVisible(e){!e&&this.activePointerId!==null&&this.cancelPositionGesture(!0),this.host.style.display=e?"":"none",e&&this.draggable&&this.positionInitialized&&this.scheduleViewportCorrection()}setState(e){this.state!==e&&(this.state=e,this.applyState())}setSpeed(e){this.currentSpeed=e,this.refreshSettingsPopover()}setVoiceOptions(e,a){this.voiceOptions=e,this.currentVoiceId=a,this.refreshSettingsPopover()}showVoiceLibrary(e){this.openVoiceLibrary(e)}setProEntitlement(e,a,o=!0){var r,l,c,p,m;const i=a??null,n=(((r=this.account)==null?void 0:r.id)||"")!==((i==null?void 0:i.id)||"")||(((l=this.account)==null?void 0:l.userId)||"")!==((i==null?void 0:i.userId)||"")||(((c=this.account)==null?void 0:c.name)||"")!==((i==null?void 0:i.name)||"")||(((p=this.account)==null?void 0:p.email)||"")!==((i==null?void 0:i.email)||"")||(((m=this.account)==null?void 0:m.image)||"")!==((i==null?void 0:i.image)||"");this.proEntitled===e&&this.proStatusKnown===o&&!n||(this.proStatusKnown=o,o||(this.listenQuota=null,this.quickreadQuota=null),this.proEntitled=e,this.account=i,this.applyState(),this.refreshSettingsPopover())}setCurrentLang(e){this.currentDetectedLang=e,this.refreshSettingsPopover()}setMode(e){var a;this.currentMode=e,(a=this.explainBtn)==null||a.classList.toggle("active",e==="explain")}setLLMAutoActive(e){this.llmAutoActive=e,this.primaryBtn&&(this.primaryBtn.classList.toggle("llm-auto-on",e),this.applyState())}showNoticePopover(e){this.closeAllPopovers();const a=[];e.secondaryLabel&&a.push(`<button class="popover-notice-btn secondary" data-action="secondary">${e.secondaryLabel}</button>`),e.primaryLabel&&a.push(`<button class="popover-notice-btn primary" data-action="primary">${e.primaryLabel}</button>`),this.noticePopover.innerHTML=`
      <div class="popover-notice-title">${e.title}</div>
      <div class="popover-notice-body">${e.body}</div>
      <div class="popover-notice-actions">${a.join("")}</div>
    `,this.noticePopover.querySelectorAll("button[data-action]").forEach(o=>{o.addEventListener("click",i=>{var r,l;i.preventDefault(),i.stopPropagation();const n=o.dataset.action;this.closeAllPopovers(),n==="primary"&&((r=e.onPrimary)==null||r.call(e)),n==="secondary"&&((l=e.onSecondary)==null||l.call(e))})}),this.noticePopover.classList.add("open")}showSelectPopover(e){this.closeAllPopovers(),this.noticePopover.replaceChildren();const a=document.createElement("div");a.className="popover-notice-title",a.textContent=e.title;const o=document.createElement("div");o.className="popover-notice-body",o.textContent=e.body;const i=document.createElement("label");i.className="popover-select-field";const n=document.createElement("span");n.textContent=e.fieldLabel;const r=document.createElement("select");r.className="popover-select";for(const d of e.options){const b=document.createElement("option");b.value=d.value,b.textContent=d.label,b.selected=d.value===e.selectedValue,r.appendChild(b)}i.append(n,r);const l=document.createElement("div");l.className="popover-select-status",l.setAttribute("role","alert"),l.hidden=!0;const c=document.createElement("div");c.className="popover-notice-actions";const p=document.createElement("button");p.type="button",p.className="popover-notice-btn secondary",p.textContent=e.cancelLabel;const m=document.createElement("button");m.type="button",m.className="popover-notice-btn primary",m.textContent=e.confirmLabel,c.append(p,m);const P=d=>d.stopPropagation();r.addEventListener("click",P),r.addEventListener("change",P),p.addEventListener("click",d=>{d.preventDefault(),d.stopPropagation(),this.closeAllPopovers()}),m.addEventListener("click",async d=>{if(d.preventDefault(),d.stopPropagation(),m.disabled)return;m.disabled=!0,p.disabled=!0,r.disabled=!0,l.hidden=!0,m.textContent=e.loadingLabel;let b=!1;try{b=await e.onConfirm(r.value)}catch{b=!1}if(b){this.closeAllPopovers();return}m.disabled=!1,p.disabled=!1,r.disabled=!1,m.textContent=e.confirmLabel,l.textContent=e.errorText,l.hidden=!1}),this.noticePopover.append(a,o,i,l,c),this.noticePopover.classList.add("open"),r.focus()}endExplainOnboarding(){this.onboardingActive&&(this.onboardingActive=!1,this.applyState())}showExplainOnboarding(e){var n;this.closeAllPopovers(),this.onboardingActive=!0,this.applyState();const a=this.currentExplainLang||"auto",o=ie().map(r=>{const l=r.code==="auto"?this.labels.explainAuto:r.code==="follow"?this.labels.explainFollow:r.nativeLabel||r.code;return`<option value="${r.code}"${r.code===a?" selected":""}>${l}</option>`}).join("");this.noticePopover.innerHTML=`
      <div class="popover-notice-title">${e.title}</div>
      <div class="popover-notice-body">${e.body}</div>
      <div class="popover-notice-body" style="margin-top:10px;display:flex;align-items:center;gap:8px;">
        <span style="opacity:.85;white-space:nowrap;">${this.labels.explainLangTitle}</span>
        <select class="qr-onboard-lang" style="flex:1;min-width:0;padding:4px 6px;border-radius:6px;border:1px solid rgba(127,127,127,.4);background:rgba(127,127,127,.12);color:inherit;font-size:12px;">${o}</select>
      </div>
      <div class="popover-notice-actions">
        <button class="popover-notice-btn primary" data-action="primary">${e.confirmLabel}</button>
      </div>
    `;const i=this.noticePopover.querySelector("select.qr-onboard-lang");i==null||i.addEventListener("click",r=>r.stopPropagation()),i==null||i.addEventListener("change",r=>r.stopPropagation()),(n=this.noticePopover.querySelector('button[data-action="primary"]'))==null||n.addEventListener("click",r=>{var c,p,m;r.preventDefault(),r.stopPropagation();const l=(i==null?void 0:i.value)||a;this.setExplainLang(l),(p=(c=this.callbacks).onExplainLangChange)==null||p.call(c,l),this.closeAllPopovers(),(m=e.onDone)==null||m.call(e,l)}),this.noticePopover.classList.add("open")}showYouTubeSourcePopover(){this.closeAllPopovers(),this.youtubeSourcePopover.innerHTML=`
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
    `,this.youtubeSourcePopover.querySelectorAll("button[data-action]").forEach(e=>{e.addEventListener("click",a=>{a.preventDefault(),a.stopPropagation();const o=e.dataset.action;this.closeAllPopovers(),this.beginStart({youtubeSource:o})})}),this.youtubeSourcePopover.classList.add("open")}showRatingPopover(e){var o;this.closeAllPopovers();const a=[1,2,3,4,5].map(i=>`<span class="popover-rating-star" data-stars="${i}">★</span>`).join("");this.ratingPopover.innerHTML=`
      <div class="popover-rating-title">${e.title}</div>
      <div class="popover-rating-stars">${a}</div>
      <button class="popover-rating-dismiss">${e.dismissLabel}</button>
    `,this.ratingPopover.querySelectorAll(".popover-rating-star").forEach(i=>{i.addEventListener("click",n=>{n.preventDefault(),n.stopPropagation();const r=Number(i.dataset.stars||"0");this.closeAllPopovers(),e.onRate(r)})}),(o=this.ratingPopover.querySelector(".popover-rating-dismiss"))==null||o.addEventListener("click",i=>{var n;i.preventDefault(),i.stopPropagation(),this.closeAllPopovers(),(n=e.onDismiss)==null||n.call(e)}),this.ratingPopover.classList.add("open")}showCloseConfirmToast(e){var r,l;let a=document.getElementById("castreader-toast-host");if(!a){a=document.createElement("div"),a.id="castreader-toast-host",a.setAttribute("data-castreader","toast-host");const c=a.attachShadow({mode:"open"}),p=document.createElement("style");p.textContent=pe,c.appendChild(p);const m=document.createElement("div");m.className="toast-host",c.appendChild(m),document.body.appendChild(a)}const o=a.shadowRoot;if(!o)return;const i=o.querySelector(".toast-host");if(!i)return;i.innerHTML=`
      <div class="toast">
        <div class="toast-title">${e.title}</div>
        <div class="toast-body">${e.body}</div>
        <div class="toast-actions">
          <button class="toast-btn secondary" data-action="secondary">${e.secondaryLabel}</button>
          <button class="toast-btn primary" data-action="primary">${e.primaryLabel}</button>
        </div>
      </div>
    `;const n=()=>{i.innerHTML=""};(r=i.querySelector('button[data-action="primary"]'))==null||r.addEventListener("click",c=>{c.preventDefault(),c.stopPropagation(),e.onPrimary(),n()}),(l=i.querySelector('button[data-action="secondary"]'))==null||l.addEventListener("click",c=>{c.preventDefault(),c.stopPropagation(),e.onSecondary(),n()}),setTimeout(()=>n(),6e3)}showClosePopover(){this.closeAllPopovers();const e=(typeof location<"u"?location.hostname:"")||"this site",a=this.labels.closeTitle.replace("{domain}",e);this.closePopover.innerHTML=`
      <div class="popover-close-title">${a}</div>
      <button class="popover-close-btn" data-mode="session">${this.labels.closeSession}</button>
      <button class="popover-close-btn" data-mode="domain">${this.labels.closeDomain}</button>
      <div class="popover-close-divider"></div>
      <button class="popover-close-btn cancel" data-mode="cancel">${this.labels.closeCancel}</button>
    `,this.closePopover.querySelectorAll("button[data-mode]").forEach(o=>{o.addEventListener("click",i=>{var r,l;i.preventDefault(),i.stopPropagation();const n=o.dataset.mode;this.closeAllPopovers(),n!=="cancel"&&((l=(r=this.callbacks).onCloseRequest)==null||l.call(r,n))})}),this.closePopover.classList.add("open")}destroy(){this.closeAllPopovers(),this.detach()}buildPanel(){const e=document.createElement("div");e.className="player-panel",this.closePageBtn=document.createElement("button"),this.closePageBtn.className="close-page-btn",this.closePageBtn.type="button",this.closePageBtn.title=this.labels.hideOnPage,this.closePageBtn.setAttribute("aria-label",this.labels.hideOnPage),this.closePageBtn.innerHTML=lt,this.closePageBtn.addEventListener("click",i=>{i.preventDefault(),i.stopPropagation(),this.showClosePopover()}),e.appendChild(this.closePageBtn);const a=document.createElement("div");a.className="has-tooltip",a.style.position="relative",a.style.display="flex",this.primaryBtn=document.createElement("button"),this.primaryBtn.className="primary-btn",this.draggable&&this.primaryBtn.classList.add("position-draggable"),this.primaryBtn.type="button",this.primaryBtn.innerHTML=ye,this.primaryBtn.setAttribute("aria-label",this.labels.listen),this.draggable&&this.primaryBtn.setAttribute("aria-keyshortcuts","Alt+ArrowUp Alt+ArrowDown Alt+Home Alt+End"),this.primaryBtn.addEventListener("click",i=>{if(i.preventDefault(),i.stopPropagation(),Date.now()<this.suppressPrimaryClickUntil){this.suppressPrimaryClickUntil=0;return}this.dismissListenHint(),this.handlePrimaryClick()}),this.draggable&&this.bindPrimaryDragEvents(),this.primaryTooltip=document.createElement("div"),this.primaryTooltip.className="tooltip primary-tooltip",this.updatePrimaryTooltip(this.labels.listen),this.listenHint=document.createElement("div"),this.listenHint.className="listen-hint",a.appendChild(this.primaryBtn),a.appendChild(this.primaryTooltip),a.appendChild(this.listenHint),e.appendChild(a),this.secondaryRow=document.createElement("div"),this.secondaryRow.style.display="flex",this.secondaryRow.style.flexDirection="column",this.secondaryRow.style.alignItems="center",this.secondaryRow.style.gap="2px";const o=(i,n,r,l)=>{const c=document.createElement("button");c.className="ctrl-btn "+i,c.type="button",c.innerHTML=n,c.setAttribute("aria-label",r),c.addEventListener("click",P=>{P.preventDefault(),P.stopPropagation(),l()});const p=document.createElement("div");p.className="has-tooltip ctrl-wrap";const m=document.createElement("div");return m.className="tooltip",m.textContent=r,p.appendChild(c),p.appendChild(m),this.secondaryRow.appendChild(p),c};return this.explainBtn=o("mode-btn explain-btn",pt,this.labels.modeExplain,()=>{var i,n;this.setMode("explain"),(n=(i=this.callbacks).onExplainMode)==null||n.call(i)}),o("read-doc-btn",ut,this.labels.openReader,()=>{var i,n;(n=(i=this.callbacks).onOpenReader)==null||n.call(i)}),this.settingsBtn=o("settings-btn",gt,this.labels.settings,()=>{this.toggleSettingsPopover()}),e.appendChild(this.secondaryRow),this.settingsPopover=document.createElement("div"),this.settingsPopover.className="popover settings-popover",this.noticePopover=document.createElement("div"),this.noticePopover.className="popover popover-notice",this.ratingPopover=document.createElement("div"),this.ratingPopover.className="popover popover-rating",this.closePopover=document.createElement("div"),this.closePopover.className="popover popover-close",this.stopConfirmPopover=document.createElement("div"),this.stopConfirmPopover.className="popover stop-confirm-popover",this.feedbackPopover=document.createElement("div"),this.feedbackPopover.className="popover feedback-popover",this.youtubeSourcePopover=document.createElement("div"),this.youtubeSourcePopover.className="popover popover-notice",e.appendChild(this.settingsPopover),e.appendChild(this.noticePopover),e.appendChild(this.ratingPopover),e.appendChild(this.closePopover),e.appendChild(this.stopConfirmPopover),e.appendChild(this.feedbackPopover),e.appendChild(this.youtubeSourcePopover),this.refreshSettingsPopover(),e.addEventListener("pointerenter",i=>{i.pointerType==="mouse"&&(this.dragging||this.activePointerId!==null||(this.hoverCollapseTimer&&(clearTimeout(this.hoverCollapseTimer),this.hoverCollapseTimer=null),this.hoverExpanded||(this.hoverExpanded=!0,this.applyState())))}),e.addEventListener("pointerleave",i=>{i.pointerType==="mouse"&&(this.dragging||this.activePointerId!==null||(this.hoverCollapseTimer&&clearTimeout(this.hoverCollapseTimer),this.hoverCollapseTimer=setTimeout(()=>{this.hoverCollapseTimer=null,!(this.dragging||this.activePointerId!==null)&&(this.isAnyPopoverOpen()||this.hoverExpanded&&(this.hoverExpanded=!1,this.applyState()))},350)))}),e}updatePrimaryTooltip(e){const a=document.createElement("span");if(a.className="primary-tooltip-action",a.textContent=e,this.primaryTooltip.replaceChildren(a),!this.draggable)return;const o=document.createElement("span");o.className="primary-tooltip-drag-hint",o.textContent=fe[this.uiLanguage]||fe.en,this.primaryTooltip.appendChild(o)}bindPrimaryDragEvents(){this.primaryBtn.addEventListener("pointerdown",e=>{this.handlePositionPointerDown(e)}),this.primaryBtn.addEventListener("pointermove",e=>{this.handlePositionPointerMove(e)}),this.primaryBtn.addEventListener("pointerup",e=>{this.handlePositionPointerUp(e)}),this.primaryBtn.addEventListener("pointercancel",e=>{e.pointerId===this.activePointerId&&this.cancelPositionGesture(!0)}),this.primaryBtn.addEventListener("lostpointercapture",e=>{e.pointerId===this.activePointerId&&this.cancelPositionGesture(!0)}),this.primaryBtn.addEventListener("contextmenu",e=>{this.activePointerId!==null&&e.preventDefault()}),this.primaryBtn.addEventListener("keydown",e=>{if(e.key==="Escape"&&this.activePointerId!==null){e.preventDefault(),e.stopPropagation(),this.cancelPositionGesture(!0);return}this.handlePositionKeyboard(e)})}handlePositionKeyboard(e){if(!e.altKey||e.ctrlKey||e.metaKey||this.activePointerId!==null||!this.positionInitialized)return;const a=this.resolveSafeTopBounds(),o=this.panel.getBoundingClientRect().top,i=e.shiftKey?8:24;let n=null;if(e.key==="ArrowUp"?n=o-i:e.key==="ArrowDown"?n=o+i:e.key==="Home"?n=a.min:e.key==="End"&&(n=a.max),n===null)return;e.preventDefault(),e.stopPropagation(),this.cancelSettlementAtCurrentPosition();const r=this.panel.getBoundingClientRect().top,l=G(n,a.min,a.max);this.safeBandRatio=Z(a,l),this.settleToTop(r,l,!0),this.savePositionPreference(),this.announcePosition(l)}announcePosition(e){if(!this.positionStatus)return;const a=this.currentViewport(),o=this.primaryBtn.getBoundingClientRect(),i=this.panel.getBoundingClientRect(),n=o.top-i.top+o.height/2,r=Math.round(G((e+n-a.top)/Math.max(1,a.height),0,1)*100),l=ke[this.uiLanguage]||ke.en;this.positionStatus.textContent="",requestAnimationFrame(()=>{this.positionStatus&&(this.positionStatus.textContent=l(r))})}handlePositionPointerDown(e){var a;if(!(!this.positionInitialized||this.activePointerId!==null||e.pointerType==="mouse"&&e.button!==0||e.pointerType!=="mouse"&&!e.isPrimary||(a=this.feedbackPopover)!=null&&a.classList.contains("open"))){this.suppressPrimaryClickUntil=0,this.activePointerId=e.pointerId,this.activePointerType=e.pointerType,this.pointerStartX=e.clientX,this.pointerStartY=e.clientY,this.latestPointerX=e.clientX,this.latestPointerY=e.clientY,this.dragStartTop=this.panel.getBoundingClientRect().top,this.dragVisualTop=this.dragStartTop,this.dragIntent=e.pointerType==="touch"?{holdMs:300,moveThreshold:10,armedMoveThreshold:3}:{holdMs:180,moveThreshold:6,armedMoveThreshold:2};try{this.primaryBtn.setPointerCapture(e.pointerId)}catch{this.bindPointerFallback()}this.longPressTimer=setTimeout(()=>{if(this.longPressTimer=null,this.activePointerId!==e.pointerId||this.dragging)return;this.dragArmed=!0,this.wrap.classList.add("drag-armed");const o=this.latestPointerX-this.pointerStartX,i=this.latestPointerY-this.pointerStartY,n=this.activePointerType!=="touch"||Math.abs(i)>=Math.abs(o)*.75;Math.hypot(o,i)>=this.dragIntent.armedMoveThreshold&&n&&this.startPositionDrag()},this.dragIntent.holdMs),e.stopPropagation()}}handlePositionPointerMove(e){if(e.pointerId!==this.activePointerId)return;this.latestPointerX=e.clientX,this.latestPointerY=e.clientY;const a=e.clientX-this.pointerStartX,o=e.clientY-this.pointerStartY,i=Math.hypot(a,o),n=this.dragArmed?this.dragIntent.armedMoveThreshold:this.dragIntent.moveThreshold,r=this.activePointerType!=="touch"||Math.abs(o)>=Math.abs(a)*.75;!this.dragging&&i>=n&&r&&this.startPositionDrag(),this.dragging&&(e.preventDefault(),e.stopPropagation(),this.scheduleDragFrame())}handlePositionPointerUp(e){if(e.pointerId===this.activePointerId){if(this.latestPointerX=e.clientX,this.latestPointerY=e.clientY,!this.dragging){const a=this.latestPointerX-this.pointerStartX,o=this.latestPointerY-this.pointerStartY,i=this.dragArmed?this.dragIntent.armedMoveThreshold:this.dragIntent.moveThreshold,n=this.activePointerType!=="touch"||Math.abs(o)>=Math.abs(a)*.75;Math.hypot(a,o)>=i&&n&&this.startPositionDrag()}this.dragging?(e.preventDefault(),e.stopPropagation(),this.finishPositionDrag()):(this.clearLongPressTimer(),this.dragArmed=!1,this.wrap.classList.remove("drag-armed"),this.releaseActivePointer())}}startPositionDrag(){this.dragging||this.activePointerId===null||(this.cancelSettlementAtCurrentPosition(),this.clearLongPressTimer(),this.dragArmed=!1,this.dragging=!0,this.suppressPrimaryClickUntil=Date.now()+ae,this.wrap.classList.remove("drag-armed","is-settling"),this.wrap.classList.add("is-dragging"),this.dismissListenHint(),this.hoverCollapseTimer&&(clearTimeout(this.hoverCollapseTimer),this.hoverCollapseTimer=null),this.hoverExpanded=!1,this.applyState(),this.dragStartTop=this.panel.getBoundingClientRect().top,this.dragVisualTop=this.dragStartTop,this.dragVisibleBounds=this.resolveVisibleHandleBounds(),this.scheduleDragFrame())}scheduleDragFrame(){this.dragFrame===null&&(this.dragFrame=requestAnimationFrame(()=>{this.dragFrame=null,this.applyLatestDragPosition()}))}applyLatestDragPosition(){if(!this.dragging)return;const e=this.dragStartTop+(this.latestPointerY-this.pointerStartY);this.dragVisualTop=et(e,this.dragVisibleBounds,nt),this.wrap.style.transform=`translate3d(0, ${this.dragVisualTop-this.dragStartTop}px, 0)`}finishPositionDrag(){if(!this.dragging)return;this.dragFrame!==null&&(cancelAnimationFrame(this.dragFrame),this.dragFrame=null),this.applyLatestDragPosition();const e=this.dragStartTop+(this.latestPointerY-this.pointerStartY),a=this.resolveSafeTopBounds(),o=G(e,a.min,a.max),i=this.dragVisualTop;this.safeBandRatio=Z(a,o),this.dragging=!1,this.dragArmed=!1,this.wrap.classList.remove("drag-armed","is-dragging"),this.releaseActivePointer(),this.suppressPrimaryClickUntil=Date.now()+ae,this.settleToTop(i,o,!0),this.savePositionPreference()}cancelPositionGesture(e){var n,r;const a=this.activePointerId!==null,o=this.dragging,i=o?this.dragVisualTop:((n=this.panel)==null?void 0:n.getBoundingClientRect().top)||0;if(this.clearLongPressTimer(),this.dragFrame!==null&&(cancelAnimationFrame(this.dragFrame),this.dragFrame=null),this.dragging=!1,this.dragArmed=!1,(r=this.wrap)==null||r.classList.remove("drag-armed","is-dragging"),this.releaseActivePointer(),(o||a)&&(this.suppressPrimaryClickUntil=Date.now()+ae),e&&this.positionInitialized&&this.host.isConnected){const l=he(this.resolveSafeTopBounds(),this.safeBandRatio);this.settleToTop(i,l,!0)}}releaseActivePointer(){const e=this.activePointerId;if(this.activePointerId=null,this.activePointerType="",this.unbindPointerFallback(),e!==null)try{this.primaryBtn.hasPointerCapture(e)&&this.primaryBtn.releasePointerCapture(e)}catch{}}bindPointerFallback(){this.pointerFallbackBound||(this.pointerFallbackBound=!0,window.addEventListener("pointermove",this.handleFallbackPointerMove,!0),window.addEventListener("pointerup",this.handleFallbackPointerUp,!0),window.addEventListener("pointercancel",this.handleFallbackPointerCancel,!0))}unbindPointerFallback(){this.pointerFallbackBound&&(this.pointerFallbackBound=!1,window.removeEventListener("pointermove",this.handleFallbackPointerMove,!0),window.removeEventListener("pointerup",this.handleFallbackPointerUp,!0),window.removeEventListener("pointercancel",this.handleFallbackPointerCancel,!0))}clearLongPressTimer(){this.longPressTimer&&(clearTimeout(this.longPressTimer),this.longPressTimer=null)}resolveVisibleHandleBounds(){const e=this.currentViewport(),a=this.host.getBoundingClientRect(),o=this.primaryBtn.getBoundingClientRect(),i=o.top-a.top,n=o.bottom-a.top,r=e.top+8-i,l=e.top+e.height-8-n;if(l>=r)return{min:r,max:l};const c=e.top+e.height/2-i-o.height/2;return{min:c,max:c}}async initializePosition(){var r,l;const e=++this.positionInitGeneration;this.syncVisualViewportCssVariable(),this.expandedPanelHeight=this.measureExpandedPanelHeight();const a=this.resolveSafeTopBounds(),o=this.currentViewport(),i=o.top+o.height*Je;let n=Z(a,i);if(this.persistPosition&&typeof chrome<"u"&&((r=chrome.storage)!=null&&r.local))try{const c=await chrome.storage.local.get(V);n=((l=me(c==null?void 0:c[V]))==null?void 0:l.safeBandRatio)??n}catch{}e!==this.positionInitGeneration||!this.host.isConnected||(this.safeBandRatio=n,this.positionInitialized=!0,this.applyStoredPosition(!1),this.host.classList.remove("position-pending"),this.schedulePopoverPositioning())}measureExpandedPanelHeight(){if(!this.secondaryRow||!this.panel||!this.host.isConnected)return te;const e=this.secondaryRow.style.display;this.secondaryRow.style.display="flex";const a=Math.ceil(this.panel.getBoundingClientRect().height);return this.secondaryRow.style.display=e,a>0?a:te}currentViewport(){const e=window.visualViewport,a=(e==null?void 0:e.height)||window.innerHeight||document.documentElement.clientHeight;return{top:(e==null?void 0:e.offsetTop)||0,height:Math.max(0,a)}}syncVisualViewportCssVariable(){this.host.style.setProperty("--cr-visual-viewport-height",`${Math.max(24,this.currentViewport().height)}px`)}resolveSafeTopBounds(){const e=getComputedStyle(this.host),a=parseFloat(e.getPropertyValue("--cr-safe-area-top"))||0,o=parseFloat(e.getPropertyValue("--cr-safe-area-bottom"))||0;return Ze(this.currentViewport(),this.expandedPanelHeight,{topGap:Math.max(be,a+8),bottomGap:Math.max(be,o+8),topOverflow:it})}applyStoredPosition(e){if(!this.positionInitialized||!this.host.isConnected)return;const a=he(this.resolveSafeTopBounds(),this.safeBandRatio);if(e&&this.host.style.display!=="none"){this.settleToTop(this.panel.getBoundingClientRect().top,a,!0);return}this.finishSettlement(),this.host.style.top=`${a}px`,this.wrap.style.transform="",this.schedulePopoverPositioning()}settleToTop(e,a,o){this.finishSettlement(),this.host.style.top=`${a}px`;const i=e-a;this.wrap.style.transform=`translate3d(0, ${i}px, 0)`,this.wrap.offsetWidth;const n=typeof window.matchMedia=="function"&&window.matchMedia("(prefers-reduced-motion: reduce)").matches;if(!o||n||Math.abs(i)<.5){this.wrap.style.transform="",this.schedulePopoverPositioning();return}this.wrap.classList.add("is-settling"),this.settleFrame=requestAnimationFrame(()=>{this.settleFrame=null,this.wrap.style.transform="translate3d(0, 0, 0)"}),this.settleTimer=setTimeout(()=>{this.settleTimer=null,this.finishSettlement(),this.schedulePopoverPositioning()},ot+80)}finishSettlement(){var e;this.settleFrame!==null&&(cancelAnimationFrame(this.settleFrame),this.settleFrame=null),this.settleTimer&&(clearTimeout(this.settleTimer),this.settleTimer=null),(e=this.wrap)==null||e.classList.remove("is-settling"),this.wrap&&(this.wrap.style.transform="")}cancelSettlementAtCurrentPosition(){var a;if(!((a=this.wrap)!=null&&a.classList.contains("is-settling"))&&this.settleFrame===null&&!this.settleTimer)return;const e=this.panel.getBoundingClientRect().top;this.finishSettlement(),this.host.style.top=`${e}px`}savePositionPreference(){var e;!this.persistPosition||typeof chrome>"u"||!((e=chrome.storage)!=null&&e.local)||chrome.storage.local.set({[V]:{version:oe,edge:"right",safeBandRatio:this.safeBandRatio}}).catch(()=>{})}bindPositionLifecycle(){var e,a,o;if(!this.positionLifecycleBound&&(this.positionLifecycleBound=!0,this.syncVisualViewportCssVariable(),window.addEventListener("resize",this.handleViewportChange,{passive:!0}),(e=window.visualViewport)==null||e.addEventListener("resize",this.handleViewportChange,{passive:!0}),(a=window.visualViewport)==null||a.addEventListener("scroll",this.handleViewportChange,{passive:!0}),document.addEventListener("visibilitychange",this.handleVisibilityChange),this.draggable&&this.persistPosition&&typeof chrome<"u"&&((o=chrome.storage)!=null&&o.onChanged)&&chrome.storage.onChanged.addListener(this.handlePositionStorageChange),this.popoverMutationObserver=new MutationObserver(()=>{this.schedulePopoverPositioning()}),this.popoverMutationObserver.observe(this.panel,{attributes:!0,attributeFilter:["class"],childList:!0,characterData:!0,subtree:!0}),typeof ResizeObserver<"u")){this.popoverResizeObserver=new ResizeObserver(()=>{this.schedulePopoverPositioning()}),this.popoverResizeObserver.observe(this.panel);for(const i of this.allPopovers())this.popoverResizeObserver.observe(i)}}unbindPositionLifecycle(){var e,a,o,i,n;this.positionLifecycleBound&&(this.positionLifecycleBound=!1,window.removeEventListener("resize",this.handleViewportChange),(e=window.visualViewport)==null||e.removeEventListener("resize",this.handleViewportChange),(a=window.visualViewport)==null||a.removeEventListener("scroll",this.handleViewportChange),document.removeEventListener("visibilitychange",this.handleVisibilityChange),this.draggable&&this.persistPosition&&typeof chrome<"u"&&((o=chrome.storage)!=null&&o.onChanged)&&chrome.storage.onChanged.removeListener(this.handlePositionStorageChange),(i=this.popoverMutationObserver)==null||i.disconnect(),this.popoverMutationObserver=null,(n=this.popoverResizeObserver)==null||n.disconnect(),this.popoverResizeObserver=null,this.viewportFrame!==null&&(cancelAnimationFrame(this.viewportFrame),this.viewportFrame=null),this.popoverFrame!==null&&(cancelAnimationFrame(this.popoverFrame),this.popoverFrame=null))}scheduleViewportCorrection(){!this.draggable||this.viewportFrame!==null||(this.viewportFrame=requestAnimationFrame(()=>{this.viewportFrame=null,!(!this.host.isConnected||!this.positionInitialized||this.host.style.display==="none")&&(this.activePointerId!==null&&this.cancelPositionGesture(!0),this.cancelSettlementAtCurrentPosition(),this.syncVisualViewportCssVariable(),this.expandedPanelHeight=this.measureExpandedPanelHeight(),this.applyStoredPosition(!1),this.schedulePopoverPositioning())}))}schedulePopoverPositioning(){!this.host.isConnected||this.popoverFrame!==null||(this.popoverFrame=requestAnimationFrame(()=>{this.popoverFrame=null,this.positionOpenPopovers()}))}positionOpenPopovers(){const e=this.currentViewport();for(const a of this.allPopovers()){if(a.style.removeProperty("--cr-popover-shift-y"),!a.classList.contains("open"))continue;const o=tt(a.getBoundingClientRect(),e,at);Math.abs(o)>=.5&&a.style.setProperty("--cr-popover-shift-y",`${o}px`)}}allPopovers(){return[this.settingsPopover,this.noticePopover,this.ratingPopover,this.closePopover,this.stopConfirmPopover,this.feedbackPopover,this.youtubeSourcePopover].filter(e=>!!e)}showListenHint(e,a=!1){this.listenHint&&(this.listenHint.classList.remove("interactive"),this.listenHint.textContent=e,this.listenHint.classList.add("show"),this.listenHintTimer&&clearTimeout(this.listenHintTimer),this.listenHintTimer=a?null:setTimeout(()=>this.dismissListenHint(),5e3))}showActionListenHint(e){if(!this.listenHint)return;this.listenHint.replaceChildren(),this.listenHint.classList.add("interactive");const a=document.createElement("span");a.textContent=e.text;const o=document.createElement("button");o.type="button",o.className="listen-hint-action",o.textContent=e.actionLabel,o.addEventListener("click",i=>{i.preventDefault(),i.stopPropagation(),e.onAction()}),this.listenHint.append(a,o),this.listenHint.classList.add("show"),this.listenHintTimer&&clearTimeout(this.listenHintTimer),this.listenHintTimer=null}hasOpenPopover(){return this.isAnyPopoverOpen()}dismissListenHint(){var e;this.listenHintTimer&&(clearTimeout(this.listenHintTimer),this.listenHintTimer=null),(e=this.listenHint)==null||e.classList.remove("show","interactive")}isAnyPopoverOpen(){return[this.settingsPopover,this.noticePopover,this.ratingPopover,this.closePopover,this.stopConfirmPopover,this.feedbackPopover,this.youtubeSourcePopover].some(e=>e==null?void 0:e.classList.contains("open"))}applyState(){var l;const e=this.state,a=e==="idle",o=e==="loading";this.panel.classList.toggle("idle",a);let i,n;o?(i=dt,n=this.labels.loading):e==="playing"?(i=st,n=this.labels.pause):e==="paused"?(i=rt,n=this.labels.resume):(i=ye,n=this.listenTipText()),this.primaryBtn.innerHTML=i,this.primaryBtn.classList.toggle("loading",o),this.primaryBtn.setAttribute("aria-busy",o?"true":"false"),this.updatePrimaryTooltip(n),this.primaryBtn.setAttribute("aria-label",n);const r=!a||this.llmAutoActive||this.onboardingActive||this.isAnyPopoverOpen()||this.hoverExpanded&&!this.dragging;this.secondaryRow.style.display=r?"flex":"none",this.closePageBtn.style.display=a&&!this.llmAutoActive?"":"none",a&&this.lastAppliedState!=="idle"&&!this.llmAutoActive&&!((l=this.feedbackPopover)!=null&&l.classList.contains("open"))&&this.closeAllPopovers(),this.lastAppliedState=e,this.schedulePopoverPositioning()}toggleSettingsPopover(){var a,o;const e=!this.settingsPopover.classList.contains("open");this.closeAllPopovers(),e&&(this.settingsView="root",le().then(()=>this.refreshSettingsPopover()),this.refreshSettingsPopover(),this.settingsPopover.classList.add("open"),this.releaseSettingsSurface=Ge("page-settings",()=>this.closeAllPopovers()),this.trackProBannerImpressionIfVisible(),(o=(a=this.callbacks).onPanelOpen)==null||o.call(a))}openVoiceLibrary(e={}){var o,i;const a=this.currentDetectedLang==="cn"?"zh":this.currentDetectedLang;this.closeAllPopovers(),Ke({voices:this.voiceOptions.map(n=>({id:n.id,name:n.name,language:n.language||a,locale:n.locale,accent:n.accent,gender:n.gender||"neutral",tier:n.tier||(n.pro?"pro":"free"),selectable:!0,tags:n.tags||[],collection:n.collection,recommended:n.recommended,qualityGrade:n.qualityGrade,description:n.description,descriptionZh:n.descriptionZh,bestFor:n.bestFor,sampleUrl:n.sampleUrl,avatar:n.avatar})),currentVoiceId:this.currentVoiceId,initialLanguage:a,lockLanguage:e.lockLanguage,proEntitled:this.proEntitled,resolveProEntitlement:this.callbacks.resolveProEntitlement,locale:W(typeof chrome<"u"&&((i=(o=chrome.i18n)==null?void 0:o.getUILanguage)==null?void 0:i.call(o))||"en"),onSelect:n=>{var r,l;(l=(r=this.callbacks).onVoiceChange)==null||l.call(r,n.id,n.language)},onUpgrade:n=>{var r,l;return(l=(r=this.callbacks).onUpgrade)==null?void 0:l.call(r,"voice",n.name)},onCloneUpgrade:()=>{var n,r;return(r=(n=this.callbacks).onCloneUpgrade)==null?void 0:r.call(n)},onCloneQuotaExhausted:n=>{var r,l;return(l=(r=this.callbacks).onCloneQuotaExhausted)==null?void 0:l.call(r,n)},onPreviewStart:()=>{var n,r;return(r=(n=this.callbacks).onVoicePreviewStart)==null?void 0:r.call(n)},onPreviewEnd:()=>{var n,r;return(r=(n=this.callbacks).onVoicePreviewEnd)==null?void 0:r.call(n)}})}closeAllPopovers(){var e,a,o,i,n,r,l;this.endExplainOnboarding(),this.settingsPopover.classList.remove("open"),(e=this.noticePopover)==null||e.classList.remove("open"),(a=this.ratingPopover)==null||a.classList.remove("open"),(o=this.closePopover)==null||o.classList.remove("open"),(i=this.stopConfirmPopover)==null||i.classList.remove("open"),(n=this.feedbackPopover)==null||n.classList.remove("open"),(r=this.youtubeSourcePopover)==null||r.classList.remove("open"),(l=this.releaseSettingsSurface)==null||l.call(this),this.releaseSettingsSurface=null}shouldShowProBanner(){return this.proStatusKnown&&this.proBannerDismissalLoaded&&!this.proBannerDismissed&&!this.proEntitled}async loadProBannerDismissal(){try{const e=await chrome.storage.local.get(ee);this.proBannerDismissed=e[ee]===!0}catch{this.proBannerDismissed=!0}finally{this.proBannerDismissalLoaded=!0,this.refreshSettingsPopover(),this.trackProBannerImpressionIfVisible()}}trackProBannerImpressionIfVisible(){var e;this.proBannerImpressionTracked||!this.shouldShowProBanner()||!((e=this.settingsPopover)!=null&&e.classList.contains("open"))||(this.proBannerImpressionTracked=!0,I("feature_use",{feature:"settings_pro_banner_impression"}))}buildProBanner(){if(!this.shouldShowProBanner())return null;const e=Y(this.uiLanguage),a=document.createElement("div");a.className="settings-pro-banner";const o=document.createElement("button");o.type="button",o.className="settings-pro-banner-action",o.setAttribute("aria-label",e.settingsCta);const i=document.createElement("span");i.className="settings-pro-banner-gift",i.setAttribute("aria-hidden","true"),i.textContent="🎁";const n=document.createElement("span");n.className="settings-pro-banner-copy";const r=document.createElement("strong");r.textContent=e.settingsCta;const l=document.createElement("span");l.textContent=e.bannerBody,n.append(r,l);const c=document.createElement("span");c.className="settings-pro-banner-arrow",c.setAttribute("aria-hidden","true"),c.textContent="→",o.append(i,n,c),o.addEventListener("click",m=>{var P,d;m.preventDefault(),m.stopPropagation(),I("feature_use",{feature:"settings_pro_banner_clicked"}),(d=(P=this.callbacks).onUpgrade)==null||d.call(P,"settings","settings_banner")});const p=document.createElement("button");return p.type="button",p.className="settings-pro-banner-dismiss",p.setAttribute("aria-label",e.dismissBanner),p.title=e.dismissBanner,p.textContent="×",p.addEventListener("click",m=>{m.preventDefault(),m.stopPropagation(),this.proBannerDismissed=!0,I("feature_use",{feature:"settings_pro_banner_dismissed"}),chrome.storage.local.set({[ee]:!0}).catch(()=>{}),this.refreshSettingsPopover()}),a.append(o,p),a}refreshSettingsPopover(){var c,p,m,P;if(!this.settingsPopover)return;this.settingsPopover.innerHTML="";const e=this.currentDetectedLang==="cn"?"zh":this.currentDetectedLang,a=this.voiceOptions.some(d=>d.language===e);if(this.settingsView==="root"){const d=document.createElement("div");d.className="settings-pro-bar",d.style.cssText="display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 10px;margin:-2px -2px 9px;border-radius:10px;background:rgba(17,24,39,.045);";const b=this.accountSession?this.accountSession.status==="authenticated"?this.accountSession.account:null:this.account,k=Ne(((p=(c=chrome.i18n)==null?void 0:c.getUILanguage)==null?void 0:p.call(c))||navigator.language),g=document.createElement("button");g.type="button",g.style.cssText="display:flex;align-items:center;gap:8px;min-width:0;flex:1 1 auto;border:none;background:transparent;cursor:pointer;padding:0;font:inherit;color:inherit;";const f=document.createElement("div");f.style.cssText="width:26px;height:26px;border-radius:50%;flex:none;overflow:hidden;display:flex;align-items:center;justify-content:center;background:#e7e7ea;color:#77777f;";const y=()=>{f.innerHTML=ct;const h=f.querySelector("svg");h instanceof SVGElement&&(h.style.width="14px",h.style.height="14px",h.style.strokeWidth="2")};if(b!=null&&b.image){const h=document.createElement("img");h.src=b.image,h.referrerPolicy="no-referrer",h.style.cssText="width:100%;height:100%;object-fit:cover;",h.addEventListener("error",()=>{h.remove(),y()}),f.appendChild(h)}else y();const T=!!b,S=document.createElement("span");S.textContent=T?b.name||b.email.split("@")[0]||"Account":((m=this.accountSession)==null?void 0:m.status)==="checking"?k.checking:((P=this.accountSession)==null?void 0:P.status)==="unavailable"?k.unavailable:this.labels.signIn,S.style.cssText="font-weight:600;font-size:12px;line-height:1.3;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;text-align:left;"+(T?"":"color:#38383d;"),g.setAttribute("aria-label",S.textContent),g.appendChild(f),g.appendChild(S),g.addEventListener("click",h=>{h.preventDefault(),h.stopPropagation(),b?(this.accountMenuOpen=!this.accountMenuOpen,this.refreshSettingsPopover()):this.callbacks.onLogin()}),d.appendChild(g);const x=document.createElement("button");if(x.type="button",x.style.cssText="display:flex;align-items:flex-end;justify-content:center;flex-direction:column;gap:1px;flex:none;max-width:170px;border:none;border-left:1px solid rgba(17,24,39,.1);background:transparent;cursor:pointer;padding:2px 0 2px 10px;font:inherit;color:inherit;text-align:right;",x.dataset.membershipState=this.proStatusKnown?this.proEntitled?"pro":"free":"unavailable",this.proStatusKnown)if(this.proEntitled){const h=document.createElement("span");h.textContent="PRO",h.style.cssText="padding:2px 7px;border:1px solid rgba(234,88,12,.22);border-radius:6px;letter-spacing:.3px;background:#fff1eb;color:#d64b16;font-weight:700;font-size:9px;line-height:1.5;",x.appendChild(h)}else{const h=Y(this.uiLanguage),v=document.createElement("span");v.textContent=h.freePlan,v.style.cssText="font-weight:500;font-size:9.5px;line-height:1.25;color:#7a7a80;white-space:nowrap;";const C=document.createElement("span");C.textContent=`${h.settingsCta} ›`,C.style.cssText="font-weight:650;font-size:10.5px;line-height:1.3;color:#d64b16;white-space:nowrap;",x.appendChild(v),x.appendChild(C)}else{const h=_e(this.uiLanguage);x.textContent=`${h.unavailable} · ${h.retry}`,x.style.fontSize="11px",x.setAttribute("aria-label",`${h.unavailable}. ${h.retry}`)}if(x.addEventListener("click",h=>{var v,C,D,O;h.preventDefault(),h.stopPropagation(),this.proStatusKnown?this.proEntitled?this.callbacks.onManagePro():(O=(D=this.callbacks).onUpgrade)==null||O.call(D,"settings"):(C=(v=this.callbacks).onPanelOpen)==null||C.call(v)}),d.appendChild(x),this.settingsPopover.appendChild(d),b&&this.accountMenuOpen){const h=document.createElement("button");h.className="popover-item",h.type="button",h.textContent=this.labels.logout,h.style.cssText="color:#d23f3f;font-weight:600;",h.addEventListener("click",v=>{var C,D;v.preventDefault(),v.stopPropagation(),this.accountMenuOpen=!1,(D=(C=this.callbacks).onLogout)==null||D.call(C),this.closeAllPopovers()}),this.settingsPopover.appendChild(h)}const w=this.buildProBanner();w&&this.settingsPopover.appendChild(w);const A=this.buildUsageCard();A&&this.settingsPopover.appendChild(A);const j=[{key:"speed",group:"read",label:this.labels.speed,value:X(this.currentSpeed)},{key:"language",group:"read",label:this.labels.readingLang,value:this.currentReadingLanguageLabel()},...a?[{key:"voice",group:"read",label:this.labels.voice,value:this.currentVoiceValueLabel()}]:[],{key:"color",group:"read",label:this.labels.highlightColorTitle,value:this.currentHighlightColorLabel(),swatch:this.currentHighlightColor},{key:"selection",group:"read",label:this.labels.selectionReaderTitle,value:this.selectionReaderOn?this.labels.stateOn:this.labels.stateOff},{key:"explain",group:"explain",label:this.labels.explainLangTitle,value:this.currentExplainValueLabel()},{key:"depth",group:"explain",label:this.labels.depthTitle,value:this.currentDepthValueLabel()}];let K="";for(const h of j){if(h.group!==K){K=h.group;const O=document.createElement("div");O.textContent=h.group==="read"?this.labels.groupReading:this.labels.groupExplain,O.style.cssText="padding:9px 14px 3px;font-size:11px;font-weight:600;opacity:.4;letter-spacing:.03em;",this.settingsPopover.appendChild(O)}const v=document.createElement("button");v.className="popover-item popover-nav-row",v.type="button";const C=document.createElement("span");C.textContent=h.label;const D=document.createElement("span");if(D.className="popover-nav-value",h.swatch){const O=document.createElement("span");O.className="popover-swatch",O.style.background=h.swatch,D.appendChild(O)}D.appendChild(document.createTextNode(h.key==="selection"?h.value:`${h.value} ›`)),v.appendChild(C),v.appendChild(D),v.addEventListener("click",O=>{var re,se;O.preventDefault(),O.stopPropagation(),h.key==="selection"?(this.selectionReaderOn=!this.selectionReaderOn,(se=(re=this.callbacks).onSelectionReaderToggle)==null||se.call(re,this.selectionReaderOn),this.refreshSettingsPopover()):h.key==="voice"?this.openVoiceLibrary():(this.settingsView=h.key,this.refreshSettingsPopover())}),this.settingsPopover.appendChild(v)}if(this.callbacks.onSwitchKindleStorefront){const h=document.createElement("button");h.className="popover-item",h.type="button",h.textContent=`🌐 ${this.labels.switchKindleSite}`,h.addEventListener("click",v=>{var C,D;v.preventDefault(),v.stopPropagation(),this.closeAllPopovers(),(D=(C=this.callbacks).onSwitchKindleStorefront)==null||D.call(C)}),this.settingsPopover.appendChild(h)}const B=document.createElement("button");B.className="popover-item",B.type="button",B.textContent=`↻ ${ve[this.uiLanguage]||ve.en}`,B.addEventListener("click",h=>{h.preventDefault(),h.stopPropagation(),this.closeAllPopovers(),chrome.runtime.sendMessage({type:"ONBOARDING_GET_BOOTSTRAP"}).then(async v=>{if(!(v!=null&&v.state))return;const C=Date.now();await chrome.runtime.sendMessage({type:"ONBOARDING_OPEN",payload:{entryPoint:"settings_replay",transitionId:`${v.state.onboardingId}:settings-replay:${C.toString(36)}`,expectedRevision:v.state.revision,requestedAt:C}})}).catch(()=>{})}),this.settingsPopover.appendChild(B);const M=document.createElement("div");M.className="popover-divider",M.style.margin="6px 0 4px",this.settingsPopover.appendChild(M);const F=document.createElement("button");F.className="popover-item",F.type="button",F.textContent=`✉ ${this.labels.sendFeedback}`,F.addEventListener("click",h=>{h.preventDefault(),h.stopPropagation(),this.closeAllPopovers(),this.openFeedbackPopover()}),this.settingsPopover.appendChild(F),this.trackProBannerImpressionIfVisible();return}const o=this.settingsView==="speed"?this.labels.speed:this.settingsView==="language"?this.labels.lang:this.settingsView==="color"?this.labels.highlightColorTitle:this.settingsView==="depth"?this.labels.depthTitle:this.labels.explainLangTitle,i=document.createElement("button");i.className="popover-item popover-back-row",i.type="button",i.textContent=`‹ ${o}`,i.addEventListener("click",d=>{d.preventDefault(),d.stopPropagation(),this.settingsView="root",this.refreshSettingsPopover()}),this.settingsPopover.appendChild(i);const n=(d,b,k)=>{const g=document.createElement("button");g.className="popover-item",g.type="button",g.textContent=d,b&&g.classList.add("selected"),g.addEventListener("click",f=>{f.preventDefault(),f.stopPropagation(),k(),this.settingsView="root",this.refreshSettingsPopover()}),this.settingsPopover.appendChild(g)},r=(d,b)=>{const k=document.createElement("button");k.className="popover-item popover-item-locked",k.type="button";const g=document.createElement("span");g.textContent=d;const f=document.createElement("span");f.className="popover-pro-badge",f.textContent=Y(this.uiLanguage).compactBadge,k.appendChild(g),k.appendChild(f),k.addEventListener("click",y=>{var T,S;y.preventDefault(),y.stopPropagation(),(S=(T=this.callbacks).onUpgrade)==null||S.call(T,b,d)}),this.settingsPopover.appendChild(k)},l=(d,b,k)=>{const g=document.createElement("button");g.className="popover-item popover-item-expert",g.type="button";const f=document.createElement("span");f.className="popover-expert-main";const y=document.createElement("span");y.className="popover-expert-icon",y.textContent="👑";const T=document.createElement("span");if(T.textContent=d,f.appendChild(y),f.appendChild(T),g.appendChild(f),!this.proEntitled){const S=document.createElement("span");S.className="popover-pro-badge",S.textContent="Pro",g.appendChild(S)}b&&g.classList.add("selected"),g.addEventListener("click",S=>{S.preventDefault(),S.stopPropagation(),k(),this.settingsView="root",this.refreshSettingsPopover()}),this.settingsPopover.appendChild(g)};if(this.settingsView==="speed")for(const d of Ue)!this.proEntitled&&d>Ve?r(X(d),"speed"):n(X(d),Math.abs(d-this.currentSpeed)<.01,()=>{var b,k;this.currentSpeed=d,(k=(b=this.callbacks).onSpeedChange)==null||k.call(b,d)});else if(this.settingsView==="language")for(const d of $()){const b=this.currentDetectedLang===d.code||d.code==="zh"&&["zh","cn"].includes(this.currentDetectedLang);n(d.label,b,()=>{var k,g;this.currentDetectedLang=d.code,(g=(k=this.callbacks).onLanguageChange)==null||g.call(k,d.code)})}else if(this.settingsView==="explain")for(const d of ie()){const b=d.code==="auto"?this.labels.explainAuto:d.code==="follow"?this.labels.explainFollow:d.nativeLabel||d.code;n(b,d.code===this.currentExplainLang,()=>{var k,g;this.currentExplainLang=d.code,(g=(k=this.callbacks).onExplainLangChange)==null||g.call(k,d.code)})}else if(this.settingsView==="depth")for(const d of xe){const b=()=>{var k,g;this.currentDepth=d.code,(g=(k=this.callbacks).onDepthChange)==null||g.call(k,d.code)};d.code==="deep"?l(this.labels[d.labelKey],d.code===this.currentDepth,b):n(this.labels[d.labelKey],d.code===this.currentDepth,b)}else if(this.settingsView==="color"){const d=de(this.currentHighlightColor).toLowerCase();for(const b of He){const k=document.createElement("button");k.className="popover-item popover-swatch-item",k.type="button";const g=document.createElement("span");g.className="popover-swatch",g.style.background=b.hex;const f=document.createElement("span");f.textContent=ce(b.hex,this.uiLanguage),k.appendChild(g),k.appendChild(f),b.hex.toLowerCase()===d&&k.classList.add("selected"),k.addEventListener("click",y=>{var T,S;y.preventDefault(),y.stopPropagation(),this.currentHighlightColor=b.hex,(S=(T=this.callbacks).onHighlightColorChange)==null||S.call(T,b.hex),this.settingsView="root",this.refreshSettingsPopover()}),this.settingsPopover.appendChild(k)}}}setHighlightColor(e){var a;this.currentHighlightColor=de(e),(a=this.settingsPopover)!=null&&a.classList.contains("open")&&this.refreshSettingsPopover()}setSelectionReaderEnabled(e){var a;this.selectionReaderOn=e,(a=this.settingsPopover)!=null&&a.classList.contains("open")&&this.refreshSettingsPopover()}currentHighlightColorLabel(){return ce(this.currentHighlightColor,this.uiLanguage)}currentVoiceValueLabel(){var e,a,o;if(this.voiceOptions.length>0){const i=this.currentDetectedLang==="cn"?"zh":this.currentDetectedLang;return((e=this.voiceOptions.find(n=>n.id===this.currentVoiceId))==null?void 0:e.name)||((a=this.voiceOptions.find(n=>n.language===i))==null?void 0:a.name)||"—"}return((o=$().find(i=>i.code===this.currentDetectedLang))==null?void 0:o.label)||this.currentDetectedLang||"—"}currentReadingLanguageLabel(){var a;const e=this.currentDetectedLang==="cn"?"zh":this.currentDetectedLang;return((a=$().find(o=>o.code===e))==null?void 0:a.label)||e||"—"}currentExplainValueLabel(){var e;return this.currentExplainLang==="auto"?this.labels.explainAuto:this.currentExplainLang==="follow"?this.labels.explainFollow:((e=ie().find(a=>a.code===this.currentExplainLang))==null?void 0:e.nativeLabel)||this.currentExplainLang}setExplainLang(e){var a;this.currentExplainLang=e||"auto",(a=this.settingsPopover)!=null&&a.classList.contains("open")&&this.refreshSettingsPopover()}currentDepthValueLabel(){var e;return this.labels[((e=xe.find(a=>a.code===this.currentDepth))==null?void 0:e.labelKey)||"depthStandard"]}setDepth(e){var a;this.currentDepth=e||"standard",(a=this.settingsPopover)!=null&&a.classList.contains("open")&&this.refreshSettingsPopover()}setQuickreadForeignTip(e){this.qrForeignTip=e,this.quickreadQuota&&this.setQuickreadQuota(this.quickreadQuota)}setQuickreadQuota(e){var a,o;if(this.quickreadQuota=e,e){const i=this.explainBtn.parentElement,n=i==null?void 0:i.querySelector(".tooltip");n&&((a=i==null?void 0:i.querySelector(".qr-pro-badge"))==null||a.remove(),n.textContent=this.qrForeignTip?e.pro?`${this.qrForeignTip} · Pro ∞`:`${this.qrForeignTip} · ${Math.max(0,e.remaining)}/${e.max}`:e.pro?this.labels.quotaPro:this.labels.quotaTip(Math.max(0,e.remaining),e.max))}(o=this.settingsPopover)!=null&&o.classList.contains("open")&&this.refreshSettingsPopover()}listenTipText(){if(this.proStatusKnown&&this.proEntitled)return this.labels.listenQuotaPro;const e=this.listenQuota;if(!e||e.pro)return this.labels.listen;const a=Math.ceil(Math.max(0,e.remaining)/60),o=Math.round(e.limit/60);return this.labels.listenQuotaTip(a,o)}setListenQuota(e){var a;this.proStatusKnown||(e=null),this.listenQuota=e,this.applyState(),(a=this.settingsPopover)!=null&&a.classList.contains("open")&&this.refreshSettingsPopover()}buildUsageCard(){const e=this.listenQuota,a=this.quickreadQuota,o=!!(e!=null&&e.pro||a!=null&&a.pro||this.proEntitled);if(!this.proStatusKnown||o||!e&&!a)return null;const i=document.createElement("div");i.style.cssText="margin:8px 14px 4px;padding:11px 12px;border-radius:10px;background:color-mix(in oklab,currentColor 5%,transparent);display:flex;flex-direction:column;gap:9px;";const n=document.createElement("div");n.style.cssText="font-size:11px;font-weight:600;opacity:.5;letter-spacing:.03em;",n.textContent=this.labels.todayUsage,i.appendChild(n);const r=(l,c,p,m,P)=>{const d=m>0?Math.min(1,Math.max(0,p/m)):0,b=document.createElement("div");b.style.cssText="display:flex;flex-direction:column;gap:4px;";const k=document.createElement("div");k.style.cssText="display:flex;align-items:center;justify-content:space-between;font-size:12px;";const g=document.createElement("span");g.style.cssText="display:flex;align-items:center;gap:6px;font-weight:500;",g.textContent=`${l} ${c}`;const f=document.createElement("span");f.style.cssText="opacity:.6;font-variant-numeric:tabular-nums;",f.textContent=P,k.appendChild(g),k.appendChild(f);const y=document.createElement("div");y.style.cssText="height:5px;border-radius:3px;overflow:hidden;background:color-mix(in oklab,currentColor 12%,transparent);";const T=document.createElement("div"),S=d>=.85;T.style.cssText=`height:100%;width:${Math.round(d*100)}%;border-radius:3px;transition:width .3s;background:${S?"#e0533a":"linear-gradient(90deg,#FD5F01,#ff8a3d)"};`,y.appendChild(T),b.appendChild(k),b.appendChild(y),i.appendChild(b)};if(e){const l=Math.max(0,e.limit-e.remaining),c=Math.ceil(Math.max(0,e.remaining)/60);r("🎧",this.labels.groupReading,l,e.limit,this.labels.remainingMinutes(c))}return a&&r("✨",this.labels.groupExplain,a.used,a.max,this.labels.remainingUses(a.remaining)),i}toggleStopConfirmPopover(){const e=!this.stopConfirmPopover.classList.contains("open");if(this.closeAllPopovers(),!e)return;this.stopConfirmPopover.innerHTML="";const a=document.createElement("button");a.className="popover-item",a.type="button",a.textContent=this.labels.stopReading,a.addEventListener("click",i=>{var n,r;i.preventDefault(),i.stopPropagation(),this.closeAllPopovers(),(r=(n=this.callbacks).onStop)==null||r.call(n)});const o=document.createElement("button");o.className="popover-item",o.type="button",o.textContent=`✉ ${this.labels.sendFeedback}`,o.addEventListener("click",i=>{i.preventDefault(),i.stopPropagation(),this.closeAllPopovers(),this.openFeedbackPopover()}),this.stopConfirmPopover.appendChild(a),this.stopConfirmPopover.appendChild(o),this.stopConfirmPopover.classList.add("open")}openFeedbackPopover(){this.feedbackPopover.innerHTML="";const e=document.createElement("button");e.className="popover-item popover-back-row",e.type="button",e.textContent=`‹ ${this.labels.settings}`,e.addEventListener("click",P=>{P.preventDefault(),P.stopPropagation(),this.closeAllPopovers(),this.settingsView="root",this.refreshSettingsPopover(),this.settingsPopover.classList.add("open")}),this.feedbackPopover.appendChild(e);const a=document.createElement("div");a.className="feedback-header",a.textContent=this.labels.feedbackTitle;const o=document.createElement("textarea");o.className="feedback-textarea",o.placeholder=this.labels.feedbackPlaceholder,o.rows=4,o.maxLength=ne,o.addEventListener("keydown",P=>P.stopPropagation());const i=document.createElement("input");i.className="feedback-email",i.type="email",i.placeholder=this.labels.feedbackEmailPlaceholder,i.required=!0,i.addEventListener("keydown",P=>P.stopPropagation());const n=document.createElement("div");n.className="feedback-status";const r=ge[this.uiLanguage]||ge.en,l=document.createElement("div");l.className="feedback-reading-attachment";const c=document.createElement("input");c.type="checkbox",c.checked=!1;let p=null;if(this.callbacks.onReadingDiagnostics){const P=document.createElement("label");P.append(c,document.createTextNode(` ${r.attach}`));const d=document.createElement("details");d.hidden=!0;const b=document.createElement("summary");b.textContent=r.preview;const k=document.createElement("div");d.append(b,k),l.append(P,d),c.addEventListener("change",()=>{var g,f;if(c.checked&&!p){try{p=((f=(g=this.callbacks).onReadingDiagnostics)==null?void 0:f.call(g))||null}catch{p=null}p||(n.className="feedback-status error",n.textContent=ue[this.uiLanguage]||ue.en)}c.checked=c.checked&&!!p,d.hidden=!c.checked,p&&(k.textContent=JSON.parse(p).rows.map(y=>`${y.index+1}. ${y.text}`).join(`
`),k.style.whiteSpace="pre-wrap"),o.maxLength=ne-(c.checked?ze.length+p.length:0)})}const m=document.createElement("button");m.className="feedback-submit",m.type="button",m.textContent=this.labels.feedbackSend,m.addEventListener("click",async P=>{var g,f;P.preventDefault(),P.stopPropagation();const d=o.value.trim(),b=i.value.trim();if(!d){o.focus();return}let k;try{k=Xe(d,c.checked?p:null)}catch{n.className="feedback-status error",n.textContent=r.tooLong;return}if(!b){n.className="feedback-status error",n.textContent=this.labels.feedbackEmailRequired,i.focus();return}m.disabled=!0,m.textContent=this.labels.feedbackSending,n.className="feedback-status",n.textContent="";try{const y=await((f=(g=this.callbacks).onFeedbackSubmit)==null?void 0:f.call(g,k,b));if(y!=null&&y.success)n.className="feedback-status success",n.textContent=this.labels.feedbackDone,o.value="",i.value="",m.textContent=this.labels.feedbackSend,m.disabled=!1,setTimeout(()=>this.closeAllPopovers(),1800);else throw new Error("failed")}catch{n.className="feedback-status error",n.textContent=this.labels.feedbackFailed,m.textContent=this.labels.feedbackSend,m.disabled=!1}}),this.feedbackPopover.appendChild(a),this.feedbackPopover.appendChild(o),this.feedbackPopover.appendChild(i),this.feedbackPopover.appendChild(l),this.feedbackPopover.appendChild(m),this.feedbackPopover.appendChild(n),this.feedbackPopover.classList.add("open"),setTimeout(()=>o.focus(),50)}handlePrimaryClick(){var e,a,o,i;if(this.state==="loading"){(a=(e=this.callbacks).onStop)==null||a.call(e);return}if(this.state==="idle"){const n=window.location.hostname;if(n.includes("youtube.com")||n.includes("youtu.be")){$e()?this.showYouTubeSourcePopover():this.beginStart({youtubeSource:"page"});return}this.beginStart()}else(i=(o=this.callbacks).onTogglePause)==null||i.call(o)}beginStart(e){this.setState("loading"),this.callbacks.onStart(e)}}const mt={en:{title:"Listen to books from your library",description:"CastReader supports TTS reading in these web readers. Open a book and click CastReader’s Read aloud button to listen with synchronized text highlighting."},zh:{title:"书架里的书，也能听",description:"支持以下平台网页版的书籍 TTS 朗读。打开一本书，点击 CastReader 的朗读按钮，边听边跟随原文高亮。"},ja:{title:"本棚の本も、音声で楽しめます",description:"CastReader は以下のウェブリーダーで本の TTS 読み上げに対応しています。本を開いて CastReader の読み上げボタンを押すと、音声に合わせて本文がハイライトされます。"},es:{title:"Escucha los libros de tu biblioteca",description:"CastReader permite leer libros en voz alta con TTS en estos lectores web. Abre un libro y pulsa Leer en voz alta en CastReader para escuchar con el texto resaltado en sincronía."},fr:{title:"Écoutez les livres de votre bibliothèque",description:"CastReader prend en charge la lecture des livres par synthèse vocale (TTS) dans ces lecteurs web. Ouvrez un livre et cliquez sur Lire à voix haute dans CastReader pour écouter avec le texte surligné en synchronisation."},de:{title:"Lass dir Bücher aus deiner Bibliothek vorlesen",description:"CastReader unterstützt das Vorlesen von Büchern per TTS in diesen Webreadern. Öffne ein Buch und klicke in CastReader auf Vorlesen. Der Text wird dabei synchron hervorgehoben."},pt:{title:"Ouça os livros da sua biblioteca",description:"O CastReader oferece leitura de livros em voz alta com TTS nestes leitores web. Abra um livro e clique em Ler em voz alta no CastReader para ouvir com o texto destacado em sincronia."},it:{title:"Ascolta i libri della tua biblioteca",description:"CastReader supporta la lettura dei libri con sintesi vocale (TTS) in questi lettori web. Apri un libro e fai clic su Leggi ad alta voce in CastReader per ascoltare con il testo evidenziato in sincronia."},hi:{title:"अपनी लाइब्रेरी की किताबें सुनें",description:"CastReader इन वेब रीडर में किताबों को TTS से पढ़कर सुनाता है। किताब खोलें और CastReader का पढ़कर सुनाएँ बटन दबाएँ। सुनते समय पाठ भी साथ-साथ हाइलाइट होगा।"},nl:{title:"Luister naar boeken uit je bibliotheek",description:"CastReader ondersteunt TTS-lezen in deze webreaders. Open een boek en klik op de knop 'Voorlezen' van CastReader om te luisteren met gesynchroniseerde tekstmarkering."},ru:{title:"Слушайте книги из вашей библиотеки",description:"CastReader поддерживает чтение TTS в этих веб-читалках. Откройте книгу и нажмите кнопку «Читать вслух» в CastReader, чтобы слушать с синхронным выделением текста."},ko:{title:"내 서재의 책 듣기",description:"CastReader는 다음 웹 리더에서 TTS 읽기를 지원합니다. 책을 열고 CastReader의 '소리 내어 읽기' 버튼을 클릭하면 텍스트 하이라이트가 동기화된 상태로 들을 수 있습니다."},ar:{title:"استمع إلى الكتب من مكتبتك",description:'يدعم CastReader القراءة بتحويل النص إلى كلام (TTS) في قارئي الويب هؤلاء. افتح كتابًا وانقر على زر "القراءة بصوت عالٍ" الخاص بـ CastReader للاستماع مع تظليل متزامن للنص.'},pl:{title:"Słuchaj książek z biblioteki",description:"CastReader obsługuje czytanie TTS w tych czytnikach internetowych. Otwórz książkę i kliknij przycisk Czytaj na głos CastReader, aby słuchać z synchronizowanym podświetlaniem tekstu."},sv:{title:"Lyssna på böcker från ditt bibliotek",description:'CastReader stödjer TTS-läsning i dessa webbläsare. Öppna en bok och klicka på CastReaders knapp "Läs högt" för att lyssna med synkroniserad textmarkering.'},da:{title:"Lyt til bøger fra dit bibliotek",description:"CastReader understøtter TTS-læsning i disse weblæsere. Åbn en bog, og klik på CastReaders knap 'Læs højt' for at lytte med synkroniseret tekstfremhævning."},nb:{title:"Lytt til bøker fra biblioteket ditt",description:"CastReader støtter TTS-lesing i disse nettleserne. Åpne en bok og klikk på CastReaders «Les høyt»-knapp for å lytte med synkronisert tekstfremheving."},fi:{title:"Kuuntele kirjoja kirjastostasi",description:"CastReader tukee TTS-lukemista näissä verkkolukijoissa. Avaa kirja ja napsauta CastReaderin Lue ääneen -painiketta kuunnellaksesi synkronoituna tekstin korostuksena."},cs:{title:"Poslouchejte knihy ze své knihovny",description:"CastReader podporuje čtení TTS v těchto webových čtečkách. Otevřete knihu a klikněte na tlačítko Přečíst nahlas od CastReaderu pro poslech s synchronním zvýrazněním textu."},el:{title:"Ακούστε βιβλία από τη βιβλιοθήκη σας",description:"Το CastReader υποστηρίζει ανάγνωση TTS σε αυτούς τους διαδικτυακούς αναγνώστες βιβλίων. Ανοίξτε ένα βιβλίο και πατήστε το κουμπί Ανάγνωση με φωνή του CastReader για να ακούσετε με συγχρονισμένη επισήμανση κειμένου."},hu:{title:"Hallgassa könyveit a könyvtárából",description:"A CastReader támogatja a TTS olvasást ezekben a webes olvasókban. Nyisson meg egy könyvet, és kattintson a CastReader Olvasás hangosan gombjára a szinkronizált szövegkiemeléssel történő hallgatáshoz."},fil:{title:"Makinig sa mga aklat mula sa iyong library",description:"Sinusuportahan ng CastReader ang TTS na pagbabasa sa mga web reader na ito. Magbukas ng aklat at i-click ang Read aloud button ng CastReader upang makinig na may synchronized na text highlighting."},he:{title:"האזינו לספרים מהספרייה שלכם",description:"CastReader תומך בקריאת TTS בקוראי אינטרנט אלה. פתחו ספר ולחצו על כפתור 'הקראה בקול רם' של CastReader כדי להאזין עם הדגשת טקסט מסונכרנת."},id:{title:"Dengarkan buku dari perpustakaan Anda",description:"CastReader mendukung pembacaan TTS di pembaca web ini. Buka buku dan klik tombol Baca dengan lantang CastReader untuk mendengarkan dengan penyorotan teks yang tersinkronisasi."},ms:{title:"Dengar buku dari pustaka anda",description:"CastReader menyokong pembacaan TTS dalam pembaca web ini. Buka buku dan klik butang Baca kuat CastReader untuk mendengar dengan penyorotan teks yang disegerakkan."},ro:{title:"Ascultați cărți din biblioteca dumneavoastră",description:"CastReader suportă citirea TTS în aceste cititoare web. Deschideți o carte și faceți clic pe butonul „Citește cu voce tare” al CastReader pentru a asculta cu evidențierea sincronizată a textului."},tr:{title:"Kitaplığınızdan kitap dinleyin",description:"CastReader, bu web okuyucularda TTS ile okumayı destekler. Bir kitap açın ve senkronize metin vurgulama ile dinlemek için CastReader’ın Sesli Oku düğmesine tıklayın."},vi:{title:"Nghe sách từ thư viện của bạn",description:"CastReader hỗ trợ đọc TTS trong các trình đọc web này. Mở một cuốn sách và nhấp vào nút Đọc to của CastReader để nghe với văn bản được đánh dấu đồng bộ."}};function Le({language:t}){const e=mt[t],a=["Kindle",t==="zh"?"微信读书":"WeRead","Google Play Books","Kobo"];return u.jsxs("section",{"aria-labelledby":"book-reading-support-title",style:N.section,children:[u.jsx("h2",{id:"book-reading-support-title",style:N.title,children:e.title}),u.jsx("ul",{style:N.platforms,children:a.map(o=>u.jsx("li",{style:N.platform,children:o},o))}),u.jsx("p",{style:N.description,children:e.description})]})}const N={section:{margin:"28px 0",padding:"20px 24px",borderRadius:16,border:"1px solid rgba(251,146,60,.24)",background:"rgba(251,146,60,.06)"},title:{margin:0,color:"#f8fafc",fontSize:20,fontWeight:700,lineHeight:1.4,overflowWrap:"anywhere"},platforms:{display:"flex",flexWrap:"wrap",gap:8,listStyle:"none",margin:"14px 0",padding:0},platform:{padding:"5px 11px",borderRadius:8,background:"rgba(251,146,60,.12)",color:"#fdba74",fontSize:14,fontWeight:600,lineHeight:1.5},description:{margin:0,color:"#cbd5e1",fontSize:14,lineHeight:1.7}};var H,Ce;const U=W(((Ce=(H=chrome.i18n)==null?void 0:H.getUILanguage)==null?void 0:Ce.call(H))||navigator.language||"en"),bt={zh:{title:"CastReader",subtitle:"正在为你演示——耳朵听 + 眼睛看段落跟随高亮",ctaIdle:"▶  让我读这一页",ctaLoading:"正在为你准备 Demo…",ctaPlaying:"🔊  正在朗读……",ctaReplay:"↻  再听一次 Demo",ctaError:"出错了，再试一次",nextHint:"感觉怎么样？现在去你想读的内容上试试 →",nextCta:"→  在维基百科「注意」这篇试试",nextUrl:"https://zh.wikipedia.org/wiki/%E5%9B%BE%E4%B9%A6%E9%A6%86",articleTitle:"让我读这一页给你听",paragraphs:["打开任何网页，点页面右边的 🎧 按钮，CastReader 就会把整页读给你听。","每段文字跟着声音高亮、自动滚到眼前——听到哪看到哪，长内容听到一半也不会丢位置。","支持 Kindle、微信读书、Google Play Books 和 Kobo 网页版书籍的朗读，也支持长邮件、AI 回复和 Google Docs 文档。","可免费开始：每日 20 分钟朗读 + 3 次解读，并提供 多种语言的自然 AI 音色。"],tipMain:"点我，朗读当前页",tipSub:"段落高亮跟声音走",readTitle:"朗读",readDesc:"读原文——逐句高亮 + 自动滚动，边听边读。",explainTitle:"解读",explainDesc:"AI 用你选的语言把整页讲给你听，并划重点带你读。"},en:{title:"CastReader",subtitle:"Demoing for you — listen as paragraphs highlight in sync",ctaIdle:"▶  Read this page aloud",ctaLoading:"Preparing your demo…",ctaPlaying:"🔊  Reading…",ctaReplay:"↻  Play demo again",ctaError:"Something went wrong — try again",nextHint:"How was that? Now try it on something you actually want to read →",nextCta:"→  Open a real Wikipedia article",nextUrl:"https://en.wikipedia.org/wiki/Education",articleTitle:"Let me read this page to you",paragraphs:["Open any page, click the 🎧 on the right, and CastReader reads it all to you.","Each paragraph highlights as it plays, scrolling into view — never lose your place in long content.","Read books aloud in Kindle, WeRead, Google Play Books and Kobo web readers, as well as long emails, AI replies and Google Docs.","Start free with 20 minutes of listening and 3 Explains daily, with natural AI voices in multiple languages."],tipMain:"Tap me to read this page",tipSub:"Highlights each paragraph as it plays",readTitle:"Read aloud",readDesc:"Reads the text verbatim — highlights and auto-scrolls as it goes.",explainTitle:"Explain",explainDesc:"AI walks you through the page in your language, pointing as it reads."},ja:{title:"CastReader",subtitle:"耳で聴き、目でハイライトを追うデモです",ctaIdle:"▶  このページを読み上げる",ctaLoading:"デモを準備中…",ctaPlaying:"🔊  読み上げ中…",ctaReplay:"↻  もう一度聴く",ctaError:"エラーが発生しました—再試行",nextHint:"いかがでしたか？次は読みたいページで試しましょう →",nextCta:"→  Wikipedia の記事を開く",nextUrl:"https://ja.wikipedia.org/wiki/%E5%9B%B3%E6%9B%B8%E9%A4%A8",articleTitle:"このページを読み上げます",paragraphs:["どのウェブページでも、右側のヘッドホンボタンを押すと、CastReader がページ全体を読み上げます。","音声に合わせて段落がハイライトされ、自動でスクロールします。長い文章でも読んでいる位置を見失いません。","Kindle、WeRead、Google Play Books、Kobo のウェブリーダーで本を読み上げられます。長いメール、AI の回答、Google Docs にも対応しています。","毎日読み上げ 20 分と解説 3 回を無料で利用でき、複数の言語の自然な AI 音声を選べます。"],tipMain:"タップしてこのページを読む",tipSub:"音声に合わせて段落をハイライト",readTitle:"読み上げ",readDesc:"原文をそのまま読み、ハイライトと自動スクロールで追います。",explainTitle:"解説",explainDesc:"AI が選んだ言語でページを解説し、ポイントを示します。"},es:{title:"CastReader",subtitle:"Escucha mientras los párrafos se resaltan en sincronía",ctaIdle:"▶  Leer esta página en voz alta",ctaLoading:"Preparando la demostración…",ctaPlaying:"🔊  Leyendo…",ctaReplay:"↻  Repetir demostración",ctaError:"Algo salió mal — reintentar",nextHint:"¿Qué te pareció? Pruébalo ahora con algo que quieras leer →",nextCta:"→  Abrir un artículo de Wikipedia",nextUrl:"https://es.wikipedia.org/wiki/Biblioteca",articleTitle:"Deja que lea esta página",paragraphs:["Abre cualquier página y pulsa el botón de auriculares de la derecha. CastReader leerá todo el contenido.","Cada párrafo se resalta mientras suena y se desplaza hasta la vista, para que nunca pierdas tu posición en textos largos.","Lee libros en voz alta en los lectores web de Kindle, WeRead, Google Play Books y Kobo, además de correos largos, respuestas de inteligencia artificial y Google Docs.","Empieza gratis con 20 minutos de escucha y 3 explicaciones al día, con voces naturales en varios idiomas."],tipMain:"Tócame para leer esta página",tipSub:"Resalta cada párrafo mientras se reproduce",readTitle:"Leer en voz alta",readDesc:"Lee el texto original con resaltado y desplazamiento automático.",explainTitle:"Explicar",explainDesc:"La inteligencia artificial te guía por la página en tu idioma y señala cada idea."},fr:{title:"CastReader",subtitle:"Écoutez pendant que les paragraphes sont surlignés en synchronisation",ctaIdle:"▶  Lire cette page à voix haute",ctaLoading:"Préparation de la démo…",ctaPlaying:"🔊  Lecture…",ctaReplay:"↻  Rejouer la démo",ctaError:"Un problème est survenu — réessayer",nextHint:"Qu’en pensez-vous ? Essayez maintenant sur un contenu qui vous intéresse →",nextCta:"→  Ouvrir un article Wikipédia",nextUrl:"https://fr.wikipedia.org/wiki/Biblioth%C3%A8que",articleTitle:"Laissez-moi lire cette page",paragraphs:["Ouvrez n’importe quelle page et cliquez sur le bouton casque à droite. CastReader lit tout le contenu.","Chaque paragraphe est surligné pendant la lecture et défile automatiquement pour ne jamais perdre votre position.","Écoutez vos livres dans les lecteurs web Kindle, WeRead, Google Play Books et Kobo, ainsi que vos longs e-mails, les réponses d’intelligence artificielle et Google Docs.","Commencez gratuitement avec 20 minutes d’écoute et 3 explications par jour, avec des voix naturelles dans plusieurs langues."],tipMain:"Cliquez pour lire cette page",tipSub:"Chaque paragraphe est surligné pendant la lecture",readTitle:"Lire à voix haute",readDesc:"Lit le texte original avec surbrillance et défilement automatique.",explainTitle:"Expliquer",explainDesc:"L’intelligence artificielle vous guide dans votre langue et indique chaque idée."},de:{title:"CastReader",subtitle:"Höre zu, während die Absätze synchron hervorgehoben werden",ctaIdle:"▶  Diese Seite vorlesen",ctaLoading:"Demo wird vorbereitet…",ctaPlaying:"🔊  Wird vorgelesen…",ctaReplay:"↻  Demo erneut abspielen",ctaError:"Etwas ist schiefgelaufen — erneut versuchen",nextHint:"Wie war es? Probiere CastReader jetzt mit einem Text aus, den du wirklich lesen möchtest →",nextCta:"→  Einen Wikipedia-Artikel öffnen",nextUrl:"https://de.wikipedia.org/wiki/Biologie",articleTitle:"Lass mich dir diese Seite vorlesen",paragraphs:["Öffne eine beliebige Webseite und klicke rechts auf die Kopfhörer-Schaltfläche. CastReader liest dir den gesamten Inhalt vor.","Jeder Absatz wird beim Vorlesen hervorgehoben und automatisch ins Blickfeld gescrollt, damit du in langen Texten nie die Stelle verlierst.","Lass dir Bücher in den Webreadern von Kindle, WeRead, Google Play Books und Kobo vorlesen, ebenso wie lange E-Mails, KI-Antworten und Google Docs.","Starte kostenlos mit täglich 20 Minuten Vorlesen und 3 Erklärungen sowie natürlichen KI-Stimmen in mehreren Sprachen."],tipMain:"Antippen, um diese Seite vorzulesen",tipSub:"Hebt jeden Absatz synchron hervor",readTitle:"Vorlesen",readDesc:"Liest den Originaltext mit Hervorhebung und automatischem Scrollen.",explainTitle:"Erklären",explainDesc:"Die KI führt dich in deiner Sprache durch die Seite und zeigt jeden wichtigen Gedanken."},pt:{title:"CastReader",subtitle:"Ouça enquanto os parágrafos são destacados em sincronia",ctaIdle:"▶  Ler esta página em voz alta",ctaLoading:"Preparando a demonstração…",ctaPlaying:"🔊  Lendo…",ctaReplay:"↻  Repetir demonstração",ctaError:"Algo deu errado — tentar novamente",nextHint:"Gostou? Agora experimente em algo que você queira ler →",nextCta:"→  Abrir um artigo da Wikipédia",nextUrl:"https://pt.wikipedia.org/wiki/Biblioteca",articleTitle:"Deixe-me ler esta página",paragraphs:["Abra qualquer página e clique no botão de fones à direita. O CastReader lerá todo o conteúdo.","Cada parágrafo é destacado enquanto toca e rola automaticamente para você nunca perder o ponto em textos longos.","Ouça livros nos leitores web do Kindle, WeRead, Google Play Books e Kobo, além de e-mails longos, respostas de inteligência artificial e Google Docs.","Comece grátis com 20 minutos de escuta e 3 explicações por dia, com vozes naturais em vários idiomas."],tipMain:"Toque para ler esta página",tipSub:"Destaca cada parágrafo durante a leitura",readTitle:"Ler em voz alta",readDesc:"Lê o texto original com destaque e rolagem automática.",explainTitle:"Explicar",explainDesc:"A inteligência artificial guia você pela página no seu idioma e aponta cada ideia."},it:{title:"CastReader",subtitle:"Ascolta mentre i paragrafi vengono evidenziati in sincronia",ctaIdle:"▶  Leggi questa pagina ad alta voce",ctaLoading:"Preparazione della demo…",ctaPlaying:"🔊  Lettura…",ctaReplay:"↻  Riproduci di nuovo la demo",ctaError:"Qualcosa è andato storto — riprova",nextHint:"Com’è andata? Provalo ora su qualcosa che vuoi davvero leggere →",nextCta:"→  Apri un articolo di Wikipedia",nextUrl:"https://it.wikipedia.org/wiki/Biblioteca",articleTitle:"Lascia che legga questa pagina",paragraphs:["Apri una pagina e fai clic sul pulsante delle cuffie a destra. CastReader leggerà tutto il contenuto.","Ogni paragrafo viene evidenziato durante la lettura e scorre automaticamente, così non perdi mai il segno.","Ascolta i libri nei lettori web di Kindle, WeRead, Google Play Books e Kobo, oltre a e-mail lunghe, risposte dell’intelligenza artificiale e Google Docs.","Inizia gratis con 20 minuti di ascolto e 3 spiegazioni al giorno, con voci naturali in più lingue."],tipMain:"Tocca per leggere questa pagina",tipSub:"Evidenzia ogni paragrafo durante la lettura",readTitle:"Leggi ad alta voce",readDesc:"Legge il testo originale con evidenziazione e scorrimento automatico.",explainTitle:"Spiega",explainDesc:"L’intelligenza artificiale ti guida nella tua lingua e indica ogni concetto."},hi:{title:"CastReader",subtitle:"सुनें और साथ-साथ हाइलाइट होते पैराग्राफ़ देखें",ctaIdle:"▶  यह पेज़ पढ़कर सुनाएँ",ctaLoading:"डेमो तैयार हो रहा है…",ctaPlaying:"🔊  पढ़ा जा रहा है…",ctaReplay:"↻  डेमो फिर सुनें",ctaError:"कुछ गलत हुआ — फिर कोशिश करें",nextHint:"कैसा लगा? अब इसे अपनी पसंद की सामग्री पर आज़माएँ →",nextCta:"→  विकिपीडिया लेख खोलें",nextUrl:"https://hi.wikipedia.org/wiki/%E0%A4%AA%E0%A5%81%E0%A4%B8%E0%A5%8D%E0%A4%A4%E0%A4%95%E0%A4%BE%E0%A4%B2%E0%A4%AF",articleTitle:"मुझे यह पेज़ पढ़ने दें",paragraphs:["कोई भी वेब पेज़ खोलें और दाईं ओर हेडफ़ोन बटन दबाएँ। CastReader पूरा पेज़ पढ़ेगा।","हर पैराग्राफ़ आवाज़ के साथ हाइलाइट होता है और आपके सामने स्क्रॉल होता है।","Kindle, WeRead, Google Play Books और Kobo के वेब रीडर में किताबें सुनें। लंबे ईमेल, AI जवाब और Google Docs भी सुन सकते हैं।","रोज़ 20 मिनट सुनने और 3 व्याख्याओं के साथ मुफ़्त शुरू करें। कई भाषाओं में प्राकृतिक AI आवाज़ें उपलब्ध हैं।"],tipMain:"यह पेज़ पढ़ने के लिए दबाएँ",tipSub:"पढ़ते समय हर पैराग्राफ़ हाइलाइट होता है",readTitle:"पढ़कर सुनाएँ",readDesc:"मूल पाठ को हाइलाइट और ऑटो-स्क्रॉल के साथ पढ़ता है।",explainTitle:"समझाएँ",explainDesc:"AI आपकी भाषा में पेज़ समझाता है और हर बिंदु दिखाता है।"},nl:{title:"CastReader",subtitle:"Demo voor jou — luister terwijl alinea's synchroon worden gemarkeerd",ctaIdle:"▶  Lees deze pagina voor",ctaLoading:"Je demo voorbereiden…",ctaPlaying:"🔊  Voorlezen…",ctaReplay:"↻  Demo opnieuw afspelen",ctaError:"Er is iets misgegaan — probeer het opnieuw",nextHint:"Hoe was dat? Probeer het nu op iets dat je echt wilt lezen →",nextCta:"→  Open een echt Wikipedia-artikel",nextUrl:"https://nl.wikipedia.org/wiki/Biologie",articleTitle:"Laat me deze pagina aan je voorlezen",paragraphs:["Open een willekeurige pagina, klik op de 🎧 aan de rechterkant en CastReader leest alles aan je voor.","Elke alinea wordt gemarkeerd terwijl deze wordt afgespeeld en schuift in beeld — raak nooit de draad kwijt in lange teksten.","Lees boeken hardop in Kindle, WeRead, Google Play Books en Kobo-weblezers, evenals lange e-mails, AI-antwoorden en Google Docs.","Start gratis met 20 minuten luisteren en 3 Explains per dag, met natuurlijke AI-stemmen in meerdere talen."],tipMain:"Tik op mij om deze pagina te lezen",tipSub:"Markeert elke paragraaf tijdens het afspelen",readTitle:"Hardop lezen",readDesc:"Leest de tekst letterlijk voor — markeert en scrolt automatisch mee.",explainTitle:"Uitleg",explainDesc:"AI loodst je door de pagina in je eigen taal en wijst aan tijdens het lezen."},ru:{title:"CastReader",subtitle:"Демонстрация — слушайте, как абзацы выделяются при чтении",ctaIdle:"▶  Прочитать эту страницу вслух",ctaLoading:"Подготовка демо-версии…",ctaPlaying:"🔊  Чтение…",ctaReplay:"↻  Воспроизвести демо еще раз",ctaError:"Что-то пошло не так — попробуйте еще раз",nextHint:"Как вам? Теперь попробуйте на том, что вы действительно хотите прочитать →",nextCta:"→  Открыть настоящую статью в Википедии",nextUrl:"https://ru.wikipedia.org/wiki/%D0%91%D0%B8%D0%B1%D0%BB%D0%B8%D0%BE%D1%82%D0%B5%D0%BA%D0%B0",articleTitle:"Позвольте мне прочитать эту страницу для вас",paragraphs:["Откройте любую страницу, нажмите на значок 🎧 справа, и CastReader прочитает ее целиком.","Каждый абзац подсвечивается при воспроизведении и плавно прокручивается на экране — вы никогда не потеряете место при чтении длинных текстов.","Читайте вслух книги в веб-ридерах Kindle, WeRead, Google Play Книги и Kobo, а также длинные письма, ответы ИИ и Google Документы.","Начните бесплатно с 20 минутами прослушивания и 3 Объяснениями в день с естественными голосами ИИ на разных языках."],tipMain:"Нажмите здесь, чтобы прочитать эту страницу",tipSub:"Подсвечивает каждый абзац во время воспроизведения",readTitle:"Читать вслух",readDesc:"Читает текст дословно — подсвечивает и автоматически прокручивает по ходу чтения.",explainTitle:"Объяснить",explainDesc:"ИИ проведет вас по странице на вашем языке, указывая на текст по мере чтения."},ko:{title:"CastReader",subtitle:"데모 진행 중 — 단락이 동기화되어 하이라이트되는 것을 들으며 확인해 보세요",ctaIdle:"▶  이 페이지 소리 내어 읽기",ctaLoading:"데모 준비 중…",ctaPlaying:"🔊  읽는 중…",ctaReplay:"↻  데모 다시 재생",ctaError:"문제가 발생했습니다 — 다시 시도해 주세요",nextHint:"어떠셨나요? 이제 실제로 읽고 싶은 콘텐츠에서 시도해 보세요 →",nextCta:"→  실제 Wikipedia 문서 열기",nextUrl:"https://ko.wikipedia.org/wiki/%EA%B5%90%EC%9C%A1",articleTitle:"이 페이지를 읽어 드릴게요",paragraphs:["아무 페이지나 열고 오른쪽의 🎧를 클릭하면 CastReader가 모두 읽어 드립니다.","재생되는 동안 각 단락이 하이라이트되며 화면에 맞춰 스크롤되므로, 긴 콘텐츠에서도 읽던 위치를 놓치지 않습니다.","Kindle, WeRead, Google Play Books, Kobo 웹 리더의 도서는 물론 긴 이메일, AI 답변, Google Docs를 소리 내어 읽어보세요.","여러 언어의 자연스러운 AI 목소리와 함께 매일 20분의 듣기 및 3회의 AI 설명으로 무료로 시작하세요."],tipMain:"이 페이지를 읽으려면 저를 탭하세요",tipSub:"재생되는 동안 각 단락을 하이라이트합니다",readTitle:"소리 내어 읽기",readDesc:"텍스트를 있는 그대로 읽어주며, 진행에 맞춰 하이라이트 및 자동 스크롤이 적용됩니다.",explainTitle:"AI 설명",explainDesc:"AI가 사용자의 언어로 페이지를 읽어주며 가리키면서 안내합니다."},ar:{title:"CastReader",subtitle:"عرض تجريبي لك — استمع بينما يتم تظليل الفقرات بشكل متزامن",ctaIdle:"▶  اقرأ هذه الصفحة بصوت عالٍ",ctaLoading:"جاري إعداد العرض التجريبي الخاص بك…",ctaPlaying:"🔊  جاري القراءة…",ctaReplay:"↻  شغّل العرض التجريبي مجددًا",ctaError:"حدث خطأ ما — حاول مجددًا",nextHint:"كيف كان ذلك؟ جربه الآن على شيء تريد قراءته بالفعل ←",nextCta:"←  افتح مقال ويكيبيديا حقيقي",nextUrl:"https://ar.wikipedia.org/wiki/%D8%AA%D8%B9%D9%84%D9%8A%D9%85",articleTitle:"دعني أقرأ هذه الصفحة لك",paragraphs:["افتح أي صفحة، وانقر على رمز 🎧 على اليمين، وسيقوم CastReader بقراءتها بالكامل لك.","يتم تظليل كل فقرة أثناء تشغيلها، مع التمرير لتظهر أمامك — لن تفقد مكانك أبدًا في المحتوى الطويل.","اقرأ الكتب بصوت عالٍ في قارئات الويب Kindle وWeRead وGoogle Play Books وKobo، بالإضافة إلى رسائل البريد الإلكتروني الطويلة وردود الذكاء الاصطناعي ومستندات Google Docs.","ابدأ مجانًا مع 20 دقيقة من الاستماع و3 شروحات يوميًا، بأصوات ذكاء اصطناعي طبيعية بلغات متعددة."],tipMain:"اضغط عليّ لقراءة هذه الصفحة",tipSub:"تظليل كل فقرة أثناء تشغيلها",readTitle:"قراءة بصوت عالٍ",readDesc:"يقرأ النص حرفيًا — مع التظليل والتمرير التلقائي أثناء القراءة.",explainTitle:"شرح",explainDesc:"يصحبك الذكاء الاصطناعي عبر الصفحة بلغتك، ويشير إليها أثناء القراءة."},pl:{title:"CastReader",subtitle:"Demo — słuchaj, podczas gdy akapity są synchronicznie podświetlane",ctaIdle:"▶ Czytaj tę stronę na głos",ctaLoading:"Przygotowywanie demo…",ctaPlaying:"🔊 Czytanie…",ctaReplay:"↻ Odtwórz demo ponownie",ctaError:"Coś poszło nie tak — spróbuj ponownie",nextHint:"Jak było? Teraz wypróbuj to na czymś, co naprawdę chcesz przeczytać ←",nextCta:"← Otwórz prawdziwy artykuł Wikipedii",nextUrl:"https://pl.wikipedia.org/wiki/Biblioteka",articleTitle:"Pozwól mi przeczytać Ci tę stronę",paragraphs:["Otwórz dowolną stronę, kliknij 🎧 po prawej stronie, a CastReader przeczyta Ci wszystko.","Każdy akapit jest podświetlany podczas odtwarzania i przewija się do widoku — nigdy nie zgubisz miejsca w długiej treści.","Czytaj książki na głos w Kindle, WeRead, Google Play Books i czytnikach Kobo, a także w długich e-mailach, odpowiedziach AI i Google Docs.","Zacznij za darmo z 20 minutami słuchania i 3 wyjaśnieniami dziennie, z naturalnymi głosami AI w wielu językach."],tipMain:"Stuknij mnie, aby przeczytać tę stronę",tipSub:"Podświetla każdy akapit podczas odtwarzania",readTitle:"Czytaj na głos",readDesc:"Czyta tekst dosłownie — podświetla i automatycznie przewija w trakcie.",explainTitle:"Wyjaśnij",explainDesc:"AI przeprowadzi Cię przez stronę w Twoim języku, wskazując elementy podczas czytania."},sv:{title:"CastReader",subtitle:"Demonstrerar för dig – lyssna medan stycken markeras i takt",ctaIdle:"▶ Läs denna sida högt",ctaLoading:"Förbereder din demo…",ctaPlaying:"🔊 Läser…",ctaReplay:"↻ Spela upp demo igen",ctaError:"Något gick fel – försök igen",nextHint:"Hur var det? Prova nu på något du faktiskt vill läsa ←",nextCta:"← Öppna en riktig Wikipedia-artikel",nextUrl:"https://sv.wikipedia.org/wiki/Astronomi",articleTitle:"Låt mig läsa denna sida åt dig",paragraphs:["Öppna vilken sida som helst, klicka på 🎧 till höger, så läser CastReader allt åt dig.","Varje stycke markeras när det spelas upp och rullas in i vy – förlora aldrig platsen i långt innehåll.","Läs böcker högt i Kindle, WeRead, Google Play Books och Kobo-webbläsare, samt långa e-postmeddelanden, AI-svar och Google Docs.","Börja gratis med 20 minuters lyssnande och 3 förklaringar dagligen, med naturliga AI-röster på flera språk."],tipMain:"Tryck här för att läsa denna sida",tipSub:"Markerar varje stycke när det spelas upp",readTitle:"Läs högt",readDesc:"Läser texten ordagrant – markerar och rullar automatiskt framåt.",explainTitle:"Förklara",explainDesc:"AI guidar dig genom sidan på ditt språk, pekandes medan den läser."},da:{title:"CastReader",subtitle:"Demo for dig – lyt, mens afsnit fremhæves synkront",ctaIdle:"▶ Læs denne side op",ctaLoading:"Forbereder din demo…",ctaPlaying:"🔊 Læser…",ctaReplay:"↻ Afspil demo igen",ctaError:"Noget gik galt – prøv igen",nextHint:"Hvordan var det? Prøv nu på noget, du faktisk vil læse ←",nextCta:"← Åbn en rigtig Wikipedia-artikel",nextUrl:"https://da.wikipedia.org/wiki/Astronomi",articleTitle:"Lad mig læse denne side op for dig",paragraphs:["Åbn enhver side, klik på 🎧 til højre, så læser CastReader alt op for dig.","Hvert afsnit fremhæves, mens det afspilles, og ruller ind i udsigten – tab aldrig tråden i langt indhold.","Læs bøger højt i Kindle, WeRead, Google Play Books og Kobo-weblæsere samt lange e-mails, AI-svar og Google Docs.","Start gratis med 20 minutters lytning og 3 forklaringer dagligt med naturlige AI-stemmer på flere sprog."],tipMain:"Tryk på mig for at læse denne side op",tipSub:"Fremhæver hvert afsnit, mens det afspilles",readTitle:"Læs højt",readDesc:"Læser teksten ordret – fremhæver og ruller automatisk med.",explainTitle:"Forklar",explainDesc:"AI guider dig igennem siden på dit sprog og peger, mens den læser."},nb:{title:"CastReader",subtitle:"Viser demo for deg — lytt mens paragrafer fremheves synkront",ctaIdle:"▶ Les denne siden høyt",ctaLoading:"Forbereder demoen din…",ctaPlaying:"🔊 Leser…",ctaReplay:"↻ Spill demoen på nytt",ctaError:"Noe gikk galt — prøv igjen",nextHint:"Hvordan var det? Nå kan du prøve det på noe du faktisk vil lese ←",nextCta:"← Åpne en ekte Wikipedia-artikkel",nextUrl:"https://no.wikipedia.org/wiki/Biologi",articleTitle:"La meg lese denne siden til deg",paragraphs:["Åpne hvilken som helst side, klikk på 🎧 til høyre, så leser CastReader den hele til deg.","Hver paragraf fremheves mens den spilles, og ruller inn i visning — du mister aldri plassen i langt innhold.","Les bøker høyt i Kindle, WeRead, Google Play Books og Kobo-nettlesere, samt lange e-poster, AI-svar og Google Docs.","Start gratis med 20 minutters lytting og 3 forklaringer daglig, med naturlige AI-stemmer på flere språk."],tipMain:"Trykk på meg for å lese denne siden",tipSub:"Fremhever hver paragraf mens den spilles",readTitle:"Les høyt",readDesc:"Lester teksten ordrett — fremhever og ruller automatisk mens det går.",explainTitle:"Forklar",explainDesc:"AI tar deg gjennom siden på ditt språk, og peker mens den leser."},fi:{title:"CastReader",subtitle:"Demo sinulle – kuuntele, kun kappaleet korostuvat synkronoituina",ctaIdle:"▶ Lue tämä sivu ääneen",ctaLoading:"Valmistellaan demoasi…",ctaPlaying:"🔊 Luetaan…",ctaReplay:"↻ Toista demo uudelleen",ctaError:"Jotain meni pieleen – yritä uudelleen",nextHint:"Miltä se kuulosti? Kokeile nyt jotain, mitä todella haluat lukea ←",nextCta:"← Avaa oikea Wikipedia-artikkeli",nextUrl:"https://fi.wikipedia.org/wiki/Biologia",articleTitle:"Luen tämän sivun sinulle",paragraphs:["Avaa mikä tahansa sivu, napsauta oikealla olevaa 🎧-merkkiä, ja CastReader lukee sen sinulle.","Jokainen kappale korostuu soiton aikana ja vieritetään näkyviin – et koskaan eksy pitkässä sisällössä.","Lue kirjoja ääneen Kindle-, WeRead-, Google Play Books- ja Kobo-verkkolukijoissa sekä pitkissä sähköposteissa, tekoälyvastauksissa ja Google Docs -dokumenteissa.","Aloita ilmaiseksi 20 minuutin kuuntelulla ja 3 selityksellä päivässä, luonnollisilla tekoälyäänillä useilla kielillä."],tipMain:"Napauta minua lukeaksesi tämän sivun",tipSub:"Korostaa jokaisen kappaleen soiton aikana",readTitle:"Lue ääneen",readDesc:"Lukee tekstin sanasta sanaan – korostaa ja vierittää automaattisesti matkan varrella.",explainTitle:"Selitä",explainDesc:"Tekeäsi kuljettaa sinut sivun läpi omalla kielelläsi osoittaen lukemisen aikana."},cs:{title:"CastReader",subtitle:"Ukázka pro vás – poslouchejte, jak se odstavce synchronně zvýrazňují",ctaIdle:"▶ Přečíst tuto stránku nahlas",ctaLoading:"Příprava vaší ukázky…",ctaPlaying:"🔊 Čtení…",ctaReplay:"↻ Přehrát ukázku znovu",ctaError:"Něco se pokazilo – zkuste to znovu",nextHint:"Jak se vám to líbilo? Nyní to vyzkoušejte na něčem, co skutečně chcete číst ←",nextCta:"← Otevřít skutečný článek na Wikipedii",nextUrl:"https://cs.wikipedia.org/wiki/Astronomie",articleTitle:"Přečtu vám tuto stránku",paragraphs:["Otevřete libovolnou stránku, klikněte na 🎧 vpravo a CastReader vám ji přečte celou.","Každý odstavec se při přehrávání zvýrazní a posune do zorného pole – nikdy neztratíte místo v dlouhém obsahu.","Čtěte knihy nahlas v čtečkách Kindle, WeRead, Google Play Books a Kobo, stejně jako dlouhé e-maily, odpovědi AI a dokumenty Google Docs.","Začněte zdarma s 20 minutami poslechu a třemi vysvětleními denně, s přirozenými hlasy AI v různých jazycích."],tipMain:"Klikněte pro přečtení této stránky",tipSub:"Zvýrazní každý odstavec při přehrávání",readTitle:"Přečíst nahlas",readDesc:"Čte text doslovně – zvýrazňuje a automaticky scroluje podle postupu.",explainTitle:"Vysvětlit",explainDesc:"AI vás provede stránkou ve vašem jazyce a ukazuje, jak čte."},el:{title:"CastReader",subtitle:"Παρουσιάζουμε — ακούστε καθώς τα παράγραφοι επισημαίνονται συγχρονισμένα",ctaIdle:"▶ Ανάγνωση με φωνή αυτής της σελίδας",ctaLoading:"Προετοιμασία της παρουσίασής σας…",ctaPlaying:"🔊 Ανάγνωση…",ctaReplay:"↻ Αναπαραγωγή παρουσίασης ξανά",ctaError:"Κάτι πήγε στραβά — δοκιμάστε ξανά",nextHint:"Πώς ήταν; Τώρα δοκιμάστε το σε κάτι που πραγματικά θέλετε να διαβάσετε ←",nextCta:"← Άνοιγμα πραγματικού άρθρου Wikipedia",nextUrl:"https://el.wikipedia.org/wiki/%CE%95%CE%BB%CE%BB%CE%B7%CE%BD%CE%B9%CE%BA%CE%AE_%CE%B3%CE%BB%CF%8E%CF%83%CF%83%CE%B1",articleTitle:"Ας διαβάσω αυτή τη σελίδα για εσάς",paragraphs:["Ανοίξτε οποιαδήποτε σελίδα, πατήστε το 🎧 στα δεξιά και το CastReader θα το διαβάσει όλο για εσάς.","Κάθε παράγραφος επισημαίνεται καθώς παίζει, κυλώντας στην οθόνη — μην χάνετε ποτέ τη θέση σας σε μακροσκελή περιεχόμενο.","Ανάγνωση με φωνή βιβλίων στο Kindle, WeRead, Google Play Books και Kobo web readers, καθώς και σε μακριά emails, απαντήσεις AI και Google Docs.","Ξεκινήστε δωρεάν με 20 λεπτά ακρόασης και 3 εξηγήσεις καθημερινά, με φυσικές φωνές AI σε πολλές γλώσσες."],tipMain:"Πατήστε με για να διαβάσω αυτή τη σελίδα",tipSub:"Επισημαίνει κάθε παράγραφο καθώς παίζει",readTitle:"Ανάγνωση με φωνή",readDesc:"Διαβάζει το κείμενο λέξη προς λέξη — επισημαίνει και κάνει αυτόματη κύλιση καθώς προχωρά.",explainTitle:"Εξήγηση",explainDesc:"Το AI σας οδηγεί στη σελίδα στη γλώσσα σας, δείχνοντας καθώς διαβάζει."},hu:{title:"CastReader",subtitle:"Demó az Ön számára – figyelje, ahogy a bekezdések szinkronban kiemelődnek",ctaIdle:"▶ Olvassa fel ezt az oldalt",ctaLoading:"Előkészítjük a demót…",ctaPlaying:"🔊 Olvasás…",ctaReplay:"↻ Demó lejátszása újra",ctaError:"Hiba történt – próbálja újra",nextHint:"Hogyan tetszett? Most próbálja ki valami olyasmivel, amit valóban szeretne olvasni ←",nextCta:"← Valós Wikipedia-cikk megnyitása",nextUrl:"https://hu.wikipedia.org/wiki/Magyarorsz%C3%A1g",articleTitle:"Olvasom fel neked ezt az oldalt",paragraphs:["Nyisson meg bármelyik oldalt, kattintson a jobb oldali 🎧 ikonra, és a CastReader felolvassa neked mindent.","Minden bekezdés kiemelődik lejátszás közben, és automatikusan megjelenik a képernyőn – soha nem veszíti el a helyét hosszú tartalmaknál.","Olvassa fel könyveket Kindle, WeRead, Google Play Books és Kobo webes olvasókban, valamint hosszú e-mailekben, AI-válaszokban és Google Docs dokumentumokban.","Kezdje ingyen 20 perc hallgatással és napi 3 magyarázattal természetes AI hangokkal több nyelven."],tipMain:"Koppints rám az oldal felolvasásához",tipSub:"Kiemeled minden bekezdést lejátszás közben",readTitle:"Felolvasás",readDesc:"Szóról szóra olvassa fel a szöveget – kiemeli és automatikusan görgeti a sorokat.",explainTitle:"Magyarázat",explainDesc:"Az AI végigvezeti Önt az oldalon az Ön nyelvén, miközben mutat és olvas."},fil:{title:"CastReader",subtitle:"Demo para sa iyo — makinig habang naka-highlight ang mga talata nang sabay",ctaIdle:"▶  Basahin ang pahinang ito nang malakas",ctaLoading:"Inihahanda ang iyong demo…",ctaPlaying:"🔊  Binabasa…",ctaReplay:"↻  I-play muli ang demo",ctaError:"May naging problema — subukan muli",nextHint:"Paano? Ngayon, subukan ito sa bagay na gusto mo talagang basahin →",nextCta:"→  Magbukas ng tunay na artikulo sa Wikipedia",nextUrl:"https://tl.wikipedia.org/wiki/Pilosopiya",articleTitle:"Hayaan akong basahin ang pahinang ito para sa iyo",paragraphs:["Magbukas ng anumang pahina, i-click ang 🎧 sa kanan, at babasahin ng CastReader ang lahat para sa iyo.","Nai-highlight ang bawat talata habang binabasa, at awtomatikong nag-i-scroll — hindi ka na maliligaw sa mahahabang nilalaman.","Basahin nang malakas ang mga libro sa Kindle, WeRead, Google Play Books at Kobo web readers, pati na rin ang mahahabang email, sagot ng AI, at Google Docs.","Magsimula nang libre sa 20 minutong pakikinig at 3 Paliwanag araw-araw, gamit ang natural na boses ng AI sa maraming wika."],tipMain:"Pindutin ako para basahin ang pahinang ito",tipSub:"Nai-highlight ang bawat talata habang binabasa",readTitle:"Basahin nang malakas",readDesc:"Binabasa ang teksto nang eksakto — nai-highlight at awtomatikong nag-i-scroll habang tumutugtog.",explainTitle:"Ipaliwanag",explainDesc:"Ginagabayan ka ng AI sa pahina sa iyong wika, at tinuturo ang binabasa."},he:{title:"CastReader",subtitle:"מדגימים עבורך — האזני בעוד פסקאות מודגשות בסנכרון",ctaIdle:"▶ הקרא עמוד זה בקול רם",ctaLoading:"מכינים את ההדגמה שלך…",ctaPlaying:"🔊 קורא…",ctaReplay:"↻ נגן את ההדגמה שוב",ctaError:"משהו השתבש — נסה שוב",nextHint:"איך היה? עכשיו נסה זאת על משהו שבאמת בא לך לקרוא →",nextCta:"→ פתח מאמר אמיתי בוויקיפדיה",nextUrl:"https://he.wikipedia.org/wiki/%D7%9E%D7%AA%D7%9E%D7%98%D7%99%D7%A7%D7%94",articleTitle:"תן לי להקריא לך את העמוד הזה",paragraphs:["פתח כל עמוד, לחץ על 🎧 בצד ימין, ו-CastReader יקריא לך הכל.","כל פסקה מודגשת בזמן ההשמעה וגוללת לתצוגה — לעולם לא תאבדו את מקומכם בתוכן ארוך.","הקריאו ספרים בקוראי Kindle, WeRead, Google Play Books ו-Kobo ברשת, כמו גם מיילים ארוכים, תשובות בינה מלאכותית ומסמכי Google Docs.","התחילו בחינם עם 20 דקות האזנה ו-3 הסברים ביום, באמצעות קולות AI טבעיים במגוון שפות."],tipMain:"לחצו עליי כדי להקריא דף זה",tipSub:"מדגיש כל פסקה בזמן ההשמעה",readTitle:"הקראה בקול רם",readDesc:"קורא את הטקסט ככתבו וכלשונו — מדגיש וגולל אוטומטית תוך כדי קריאה.",explainTitle:"הסבר",explainDesc:"בינה מלאכותית מלווה אתכם בדף בשפה שלכם, ומצביעה תוך כדי קריאה."},id:{title:"CastReader",subtitle:"Demo untuk Anda — dengarkan saat paragraf disorot secara sinkron",ctaIdle:"▶  Bacakan halaman ini dengan lantang",ctaLoading:"Menyiapkan demo Anda…",ctaPlaying:"🔊  Membaca…",ctaReplay:"↻  Putar demo lagi",ctaError:"Terjadi kesalahan — coba lagi",nextHint:"Bagaimana hasilnya? Sekarang coba pada konten yang benar-benar ingin Anda baca →",nextCta:"→  Buka artikel Wikipedia asli",nextUrl:"https://id.wikipedia.org/wiki/Biologi",articleTitle:"Biarkan saya membacakan halaman ini untuk Anda",paragraphs:["Buka halaman apa saja, klik 🎧 di sebelah kanan, dan CastReader akan membacakannya seluruhnya untuk Anda.","Setiap paragraf disorot saat diputar, menggulir ke tampilan — jangan pernah kehilangan posisi Anda dalam konten panjang.","Bacakan buku dengan suara di pembaca web Kindle, WeRead, Google Play Books, dan Kobo, serta email panjang, balasan AI, dan Google Docs.","Mulai gratis dengan 20 menit mendengarkan dan 3 Penjelasan harian, dengan suara AI alami dalam berbagai bahasa."],tipMain:"Ketuk saya untuk membacakan halaman ini",tipSub:"Menyorot setiap paragraf saat diputar",readTitle:"Bacakan dengan suara",readDesc:"Membaca teks secara verbatim — menyorot dan menggulir otomatis saat berjalan.",explainTitle:"Jelaskan",explainDesc:"AI memandu Anda melalui halaman dalam bahasa Anda, menunjuk saat membaca."},ms:{title:"CastReader",subtitle:"Demo untuk anda — dengar semasa perenggan disorot secara segerak",ctaIdle:"▶  Baca halaman ini dengan kuat",ctaLoading:"Menyediakan demo anda…",ctaPlaying:"🔊  Membaca…",ctaReplay:"↻  Mainkan demo semula",ctaError:"Ada masalah — cuba lagi",nextHint:"Bagaimana hasilnya? Sekarang cuba pada kandungan yang benar-benar ingin anda baca →",nextCta:"→  Buka artikel Wikipedia sebenar",nextUrl:"https://ms.wikipedia.org/wiki/Bumi",articleTitle:"Biarkan saya membaca halaman ini untuk anda",paragraphs:["Buka mana-mana halaman, klik 🎧 di sebelah kanan, dan CastReader akan membacanya untuk anda.","Setiap perenggan diserlahkan semasa dimainkan, menatal ke dalam pandangan — jangan pernah kehilangan tempat anda dalam kandungan panjang.","Baca buku dengan kuat dalam pembaca web Kindle, WeRead, Google Play Books dan Kobo, serta e-mel panjang, balasan AI dan Google Docs.","Mulakan secara percuma dengan 20 minit pendengaran dan 3 Penjelasan setiap hari, dengan suara AI semula jadi dalam pelbagai bahasa."],tipMain:"Ketuk saya untuk membaca halaman ini",tipSub:"Menyerlahkan setiap perenggan semasa dimainkan",readTitle:"Baca dengan kuat",readDesc:"Membaca teks secara verbatim — menyerlahkan dan menatal automatik semasa berjalan.",explainTitle:"Terangkan",explainDesc:"AI membimbing anda melalui halaman dalam bahasa anda, menunjuk semasa membaca."},ro:{title:"CastReader",subtitle:"Demonstrație pentru dumneavoastră — ascultați în timp ce paragrafele sunt evidențiate sincron",ctaIdle:"▶ Citește această pagină cu voce tare",ctaLoading:"Se pregătește demonstrația…",ctaPlaying:"🔊 Se citește…",ctaReplay:"↻ Redă din nou demonstrația",ctaError:"Ceva nu a mers bine — încercați din nou",nextHint:"Cum a fost? Acum încercați pe ceva ce chiar doriți să citiți →",nextCta:"→ Deschideți un articol real Wikipedia",nextUrl:"https://ro.wikipedia.org/wiki/Muzic%C4%83",articleTitle:"Permiteți-mi să vă citesc această pagină",paragraphs:["Deschideți orice pagină, faceți clic pe 🎧 din dreapta, iar CastReader vi-o va citi în întregime.","Fiecare paragraf este evidențiat pe măsură ce este redat, derulând automat în vizual — nu îți vei pierde niciodată locul în conținutul lung.","Citește cărți cu voce tare în Kindle, WeRead, Google Play Books și Kobo, precum și e-mailuri lungi, răspunsuri AI și documente Google Docs.","Începe gratuit cu 20 de minute de ascultare și 3 Explicații zilnic, cu voci AI naturale în mai multe limbi."],tipMain:"Apasă-mă pentru a citi această pagină",tipSub:"Evidențiază fiecare paragraf pe măsură ce este redat",readTitle:"Citește cu voce tare",readDesc:"Citește textul cuvânt cu cuvânt — evidențiază și derulează automat pe măsură ce avansează.",explainTitle:"Explică",explainDesc:"AI te ghidează prin pagină în limba ta, indicând elementele pe măsură ce citește."},tr:{title:"CastReader",subtitle:"Sizin için demo — paragrafların senkronize şekilde vurgulanmasını dinleyin",ctaIdle:"▶  Bu sayfayı sesli oku",ctaLoading:"Demonuz hazırlanıyor…",ctaPlaying:"🔊  Okunuyor…",ctaReplay:"↻  Demoyu tekrar oynat",ctaError:"Bir sorun oluştu — tekrar deneyin",nextHint:"Nasıl oldu? Şimdi gerçekten okumak istediğiniz bir şeyde deneyin →",nextCta:"→  Gerçek bir Wikipedia makalesi aç",nextUrl:"https://tr.wikipedia.org/wiki/Bilgisayar",articleTitle:"Bu sayfayı sizin için okumama izin verin",paragraphs:["Herhangi bir sayfayı açın, sağdaki 🎧 simgesine tıklayın ve CastReader hepsini size sesli okusun.","Her paragraf okunurken vurgulanır ve görünür alana kaydırılır — uzun içeriklerde yerinizi asla kaybetmezsiniz.","Kindle, WeRead, Google Play Books ve Kobo web okuyucularında kitapları sesli okuyun; ayrıca uzun e-postaları, yapay zeka yanıtlarını ve Google Docs belgelerini dinleyin.","Çeşitli dillerde doğal yapay zeka sesleriyle günlük 20 dakika dinleme ve 3 Açıklama hakkıyla ücretsiz başlayın."],tipMain:"Bu sayfayı okumak için bana dokunun",tipSub:"Okurken her paragrafı vurgular",readTitle:"Sesli oku",readDesc:"Metni kelimesi kelimesine okur — ilerledikçe vurgulama ve otomatik kaydırma yapar.",explainTitle:"Açıkla",explainDesc:"Yapay zeka, okurken işaret ederek sayfayı dilinizde adım adım anlatır."},vi:{title:"CastReader",subtitle:"Đang chạy demo cho bạn — hãy nghe khi các đoạn văn được đánh dấu đồng bộ",ctaIdle:"▶  Đọc trang này to",ctaLoading:"Đang chuẩn bị bản demo của bạn…",ctaPlaying:"🔊  Đang đọc…",ctaReplay:"↻  Phát lại demo",ctaError:"Đã xảy ra lỗi — hãy thử lại",nextHint:"Bạn thấy thế nào? Bây giờ hãy thử với nội dung bạn thực sự muốn đọc →",nextCta:"→  Mở một bài viết Wikipedia thực tế",nextUrl:"https://vi.wikipedia.org/wiki/H%C3%B3a_h%E1%BB%8Dc",articleTitle:"Để tôi đọc trang này cho bạn nghe",paragraphs:["Mở bất kỳ trang nào, nhấp vào biểu tượng 🎧 ở bên phải và CastReader sẽ đọc toàn bộ trang cho bạn.","Mỗi đoạn văn được tô sáng khi phát, tự động cuộn vào khung nhìn — không bao giờ bị mất vị trí trong nội dung dài.","Đọc sách thành tiếng trên trình đọc web của Kindle, WeRead, Google Play Books và Kobo, cũng như email dài, phản hồi từ AI và Google Docs.","Bắt đầu miễn phí với 20 phút nghe và 3 lượt Giải thích mỗi ngày, với giọng nói AI tự nhiên bằng nhiều ngôn ngữ."],tipMain:"Nhấn vào đây để đọc trang này",tipSub:"Tô sáng từng đoạn văn khi phát",readTitle:"Đọc to",readDesc:"Đọc nguyên văn văn bản — tô sáng và tự động cuộn khi đọc.",explainTitle:"Giải thích",explainDesc:"AI hướng dẫn bạn qua trang bằng ngôn ngữ của bạn, chỉ vào từng phần khi đọc."}},L=bt[U];function kt(){const[t,e]=E.useState("idle"),[a,o]=E.useState(!1),i=E.useRef(null),n=E.useRef(null),r=E.useRef([]),l=E.useRef(Ee),c=E.useCallback(()=>{var x,w;(x=i.current)==null||x.reset(),i.current=null,(w=n.current)==null||w.setState("idle"),e("idle")},[]),p=E.useCallback(async()=>{var M,F,h;e("loading"),(M=n.current)==null||M.setState("loading");const x=U,w=r.current.filter(v=>!!v).map(v=>({text:v.textContent||"",element:v})),A=w.reduce((v,C)=>v+C.text.length,0);I("session_start",{url_domain:"welcome",language:x,trigger:"welcome_demo",content_origin:"demo"});const j=await chrome.runtime.sendMessage({type:"GET_SETTINGS"}),K=We(x,j.voicePreferences);K?j.voice=K:j.voice="",(F=i.current)==null||F.reset(),i.current=null;const B=new Qe(j,{onPlaybackStateChange:v=>{var C,D;v==="playing"?((C=n.current)==null||C.setState("playing"),e("playing")):v==="paused"&&((D=n.current)==null||D.setState("paused"))},onEnd:()=>{var v;(v=n.current)==null||v.setState("idle"),e("ended"),I("reading_end",{...B.getAnalyticsProperties(),url_domain:"welcome",content_origin:"demo",paragraph_count:w.length,paragraphs_total:w.length,paragraphs_played:B.getPlayedSegmentCount(),char_count:A,completion_rate:1,reason:"completed"})},onError:()=>{var v;(v=n.current)==null||v.setState("idle"),e("error")}},{analyticsSource:"welcome_demo",analyticsDomain:"welcome",analyticsContext:{content_origin:"demo",trigger:"welcome_demo"}});i.current=B,l.current!==1&&B.setPlaybackRate(l.current);try{await B.startReadingWithParagraphs(w,x)}catch(v){const C=v;(C==null?void 0:C.name)==="NotAllowedError"||/play\(\) failed|user gesture|user interact|didn'?t interact/i.test((C==null?void 0:C.message)??"")?(I("feature_use",{feature:"welcome_autoplay_blocked"}),e("idle")):(console.error("[Welcome] startReading failed",v),e("error")),(h=n.current)==null||h.setState("idle")}},[]);E.useEffect(()=>{let x=!1;const w=setTimeout(()=>{x||(I("feature_use",{feature:"welcome_autoplay_attempt"}),P(!0),p())},600);return()=>{x=!0,clearTimeout(w)}},[p]);const[m,P]=E.useState(!1);E.useEffect(()=>{if(!m||t!=="idle")return;let x=!1;return(async()=>{try{if((await chrome.storage.local.get(J.WELCOME_TIP_SHOWN))[J.WELCOME_TIP_SHOWN])return;await chrome.storage.local.set({[J.WELCOME_TIP_SHOWN]:!0}),x||o(!0)}catch{}})(),()=>{x=!0}},[m,t]),E.useEffect(()=>{const x=(()=>{try{return new URLSearchParams(window.location.search).get("from")}catch{return null}})();I("feature_use",{feature:"welcome_view",language:U,from:x||"install"})},[]),E.useEffect(()=>{const x=new ht(U,{onStart:()=>{o(!1),p()},onTogglePause:()=>{const w=i.current;if(!w){p();return}w.getPlaybackState()==="playing"?w.pause():w.play()},onStop:()=>c(),onSpeedChange:w=>{var A,j;l.current=w,(A=i.current)==null||A.setPlaybackRate(w),(j=i.current)==null||j.updateSpeed(w),chrome.runtime.sendMessage({type:"SAVE_SETTINGS",payload:{speed:w}}).catch(()=>{})},onOpenReader:()=>{chrome.runtime.sendMessage({type:"OPEN_READER"})}},{draggable:!1,persistPosition:!1});return x.attach(),n.current=x,chrome.runtime.sendMessage({type:"GET_SETTINGS"}).then(w=>{const A=w==null?void 0:w.speed;A&&A>0&&Math.abs(A-l.current)>.01&&(l.current=A,x.setSpeed(A))}).catch(()=>{}),()=>{var w;x.destroy(),n.current=null,(w=i.current)==null||w.destroy(),i.current=null}},[p,c]);const d=E.useCallback(()=>{t==="loading"||t==="playing"||p()},[t,p]),b=E.useCallback(()=>{I("feature_use",{feature:"welcome_demo_to_real_site"}),window.open(L.nextUrl,"_blank")},[]),k=t==="ended",g=k?L.nextCta:t==="idle"?L.ctaIdle:t==="loading"?L.ctaLoading:t==="playing"?L.ctaPlaying:L.ctaError,f=k?b:d,y=t==="idle"||k,T=t==="loading"||t==="playing",S=t==="playing";return u.jsxs("div",{style:z.page,children:[a&&u.jsx("div",{style:z.tipWrap,children:u.jsxs("div",{style:z.tip,children:[u.jsx("div",{style:z.tipMain,children:L.tipMain}),u.jsx("div",{style:z.tipSub,children:L.tipSub}),u.jsx("button",{style:z.tipClose,onClick:()=>o(!1),children:"×"}),u.jsx("div",{style:z.tipArrow})]})}),u.jsxs("div",{style:z.container,children:[u.jsxs("div",{style:z.hero,children:[u.jsx("img",{src:chrome.runtime.getURL("/icon-128.png"),alt:"CastReader",style:z.logo}),L.title?u.jsx("h1",{style:z.title,children:L.title}):null,L.subtitle?u.jsx("p",{style:z.subtitle,children:L.subtitle}):null]}),u.jsx(Le,{language:U}),u.jsx("button",{type:"button",onClick:f,disabled:T,style:{...z.bigCta,...y?z.bigCtaPulsing:{},...T?z.bigCtaDisabled:{},...S?z.bigCtaPlaying:{}},children:g}),k&&u.jsxs("div",{style:z.replayWrap,children:[u.jsx("p",{style:z.replayHint,children:L.nextHint}),u.jsx("button",{type:"button",onClick:d,style:z.replayBtn,children:L.ctaReplay})]}),u.jsxs("article",{style:z.article,children:[u.jsx("h2",{style:z.articleTitle,children:L.articleTitle}),L.paragraphs.map((x,w)=>u.jsx("p",{ref:A=>{r.current[w]=A},style:z.articleP,children:x},w))]}),u.jsx("div",{style:{display:"flex",gap:12,marginTop:28,flexWrap:"wrap",justifyContent:"center"},children:[{icon:"🔊",title:L.readTitle,desc:L.readDesc},{icon:"🎧",title:L.explainTitle,desc:L.explainDesc}].map(x=>u.jsxs("div",{"data-welcome-feature":"true",style:{flex:"1 1 220px",maxWidth:300,background:"rgba(255,255,255,0.05)",border:"1px solid rgba(255,255,255,0.08)",borderRadius:12,padding:"14px 16px",textAlign:"start"},children:[u.jsx("div",{style:{fontSize:22},children:x.icon}),u.jsx("div",{style:{fontWeight:700,margin:"6px 0 4px",color:"#fff"},children:x.title}),u.jsx("div",{style:{fontSize:13,lineHeight:1.5,color:"rgba(255,255,255,0.72)"},children:x.desc})]},x.title))})]})]})}const z={page:{minHeight:"100vh",background:"linear-gradient(160deg, #0a0a14 0%, #111827 40%, #0f172a 100%)",color:"#cbd5e1",fontFamily:"-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",padding:"48px 24px 160px"},container:{maxWidth:680,margin:"0 auto"},hero:{textAlign:"center",marginBottom:32},logo:{width:72,height:72,borderRadius:18,marginBottom:16,boxShadow:"0 8px 32px rgba(242, 101, 34, 0.2)"},title:{fontSize:32,fontWeight:700,color:"#f8fafc",margin:"0 0 8px",letterSpacing:"-0.5px"},subtitle:{fontSize:17,color:"#94a3b8",margin:0},bigCta:{display:"block",width:"100%",padding:"24px 32px",marginBottom:40,background:"#F26522",color:"#ffffff",border:"none",borderRadius:16,fontSize:22,fontWeight:700,cursor:"pointer",transition:"transform 0.15s ease, box-shadow 0.15s ease",boxShadow:"0 12px 36px rgba(242, 101, 34, 0.45)",fontFamily:"inherit"},bigCtaPulsing:{animation:"cr-pulse-strong 1.4s ease-in-out infinite"},bigCtaDisabled:{cursor:"wait",opacity:.85},bigCtaPlaying:{background:"rgba(242, 101, 34, 0.35)",boxShadow:"none",color:"rgba(255,255,255,0.92)",cursor:"default"},replayWrap:{marginTop:-24,marginBottom:32,textAlign:"center",animation:"cr-tip-in 0.35s ease-out both"},replayHint:{fontSize:14,color:"#94a3b8",margin:"0 0 10px"},replayBtn:{background:"transparent",color:"#94a3b8",border:"1px solid rgba(148, 163, 184, 0.35)",borderRadius:8,padding:"8px 18px",fontSize:13,fontWeight:500,cursor:"pointer",fontFamily:"inherit"},article:{marginBottom:32,padding:"32px 36px",background:"rgba(255,255,255,0.02)",borderRadius:16,border:"1px solid rgba(255,255,255,0.06)"},articleTitle:{fontSize:22,fontWeight:700,color:"#f1f5f9",margin:"0 0 20px"},articleP:{fontSize:17,lineHeight:1.75,color:"#cbd5e1",margin:"0 0 16px"},tipWrap:{position:"fixed",right:5,bottom:"calc(68% + 8px)",zIndex:2147483647,animation:"cr-tip-in 0.25s ease-out both",pointerEvents:"auto"},tip:{position:"relative",background:"#F26522",color:"#fff",borderRadius:10,paddingBlock:10,paddingInlineStart:14,paddingInlineEnd:36,boxShadow:"0 4px 20px rgba(242, 101, 34, 0.5)",lineHeight:1.5,whiteSpace:"nowrap"},tipMain:{fontSize:13.5,fontWeight:600},tipSub:{fontSize:12,color:"rgba(255,255,255,0.82)",marginTop:2},tipClose:{position:"absolute",top:6,insetInlineEnd:9,background:"none",border:"none",color:"rgba(255,255,255,0.55)",cursor:"pointer",fontSize:17,lineHeight:1,padding:0,fontFamily:"inherit"},tipArrow:{position:"absolute",bottom:-10,right:19,width:0,height:0,borderLeft:"10px solid transparent",borderRight:"10px solid transparent",borderTop:"10px solid #F26522"}},De={en:{pageTitle:"Welcome to CastReader",loadingLabel:"Loading CastReader…",startupError:"CastReader could not connect. Please try again.",genericError:"We couldn’t open this scene. Try again or choose another scene.",eyebrow:"Your first read-aloud",title:"What would you like to listen to today?",subtitle:"Choose one. We’ll take you to the right place and show you the one button to press.",recommended:"Recommended",openScene:"Start here",opening:"Opening…",handoffTitle:"Your next step is on the page we opened",handoffBody:"Look for the orange CastReader cue, then press Read. You can return here to switch scenes.",skip:"Maybe later",privacy:"No sign-in required. This guide and product analytics never record page text, file names, book titles, email, or conversations.",scenes:{web_email:{icon:"🌐",title:"Web page or long email",description:"News, blogs, newsletters, Gmail and Outlook."},kindle:{icon:"📚",title:"Kindle book",description:"Listen and follow along inside Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF or document",description:"PDF, EPUB, DOCX, text files and Google Docs."},ai_chat:{icon:"✨",title:"AI response",description:"ChatGPT, Claude, Gemini and other supported chats."}}},zh:{pageTitle:"欢迎使用 CastReader",loadingLabel:"正在加载 CastReader…",startupError:"暂时无法连接 CastReader，请重试。",genericError:"无法打开此场景。请重试或选择其他场景。",eyebrow:"你的第一次朗读",title:"你今天想听什么？",subtitle:"选择一个场景，我们会带你到正确的位置，并告诉你只需点击哪个按钮。",recommended:"推荐",openScene:"从这里开始",opening:"正在打开…",handoffTitle:"下一步已在刚刚打开的页面上",handoffBody:"找到橙色 CastReader 提示，然后点击朗读。你也可以回到这里更换场景。",skip:"稍后再说",privacy:"无需登录。本引导和产品分析不会记录网页正文、文件名、书名、邮件或 AI 对话。",scenes:{web_email:{icon:"🌐",title:"网页 / 长邮件",description:"新闻、博客、新闻通讯、Gmail 和 Outlook。"},kindle:{icon:"📚",title:"Kindle 电子书",description:"在 Kindle Cloud Reader 里边听边看。"},pdf_document:{icon:"📄",title:"PDF / 文档",description:"PDF、EPUB、DOCX、文本文件和 Google Docs。"},ai_chat:{icon:"✨",title:"AI 回答",description:"ChatGPT、Claude、Gemini 等 AI 对话。"}}},ja:{pageTitle:"CastReaderへようこそ",loadingLabel:"CastReaderを読み込んでいます…",startupError:"CastReaderに接続できませんでした。もう一度お試しください。",genericError:"この用途を開けませんでした。もう一度試すか、別の用途を選んでください。",eyebrow:"はじめての読み上げ",title:"今日は何を聴きますか？",subtitle:"用途を一つ選ぶと、適切なページへ移動し、押すボタンを一つだけ案内します。",recommended:"おすすめ",openScene:"ここから始める",opening:"開いています…",handoffTitle:"次の手順は開いたページにあります",handoffBody:"オレンジ色の CastReader の目印を探し、「読み上げ」を押してください。別の用途を選ぶ場合は、ここに戻れます。",skip:"あとで",privacy:"ログインは不要です。このガイドと製品分析では、本文、ファイル名、書名、メール、会話の内容を記録しません。",scenes:{web_email:{icon:"🌐",title:"Web ページ / 長いメール",description:"ニュース、ブログ、Gmail、Outlook。"},kindle:{icon:"📚",title:"Kindle 本",description:"Kindle Cloud Reader で聴きながら本文を追えます。"},pdf_document:{icon:"📄",title:"PDF / 文書",description:"PDF、EPUB、DOCX、テキスト、Google Docs。"},ai_chat:{icon:"✨",title:"AI の回答",description:"ChatGPT、Claude、Gemini など。"}}},es:{pageTitle:"Te damos la bienvenida a CastReader",loadingLabel:"Cargando CastReader…",startupError:"No se pudo conectar con CastReader. Vuelve a intentarlo.",genericError:"No pudimos abrir esta opción. Inténtalo de nuevo o elige otra.",eyebrow:"Tu primera escucha",title:"¿Qué quieres escuchar hoy?",subtitle:"Elige una opción. Te llevaremos al lugar correcto y te mostraremos un solo botón.",recommended:"Recomendado",openScene:"Empezar aquí",opening:"Abriendo…",handoffTitle:"El siguiente paso está en la página abierta",handoffBody:"Busca la indicación naranja de CastReader y pulsa «Leer». Puedes volver para cambiar.",skip:"Más tarde",privacy:"No es necesario iniciar sesión. Esta guía y las analíticas no guardan texto, nombres de archivos, títulos, correos ni conversaciones.",scenes:{web_email:{icon:"🌐",title:"Página web o correo largo",description:"Noticias, blogs, Gmail y Outlook."},kindle:{icon:"📚",title:"Libro Kindle",description:"Escucha y sigue el texto en Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF o documento",description:"PDF, EPUB, DOCX, texto y Google Docs."},ai_chat:{icon:"✨",title:"Respuesta de IA",description:"ChatGPT, Claude, Gemini y otros."}}},fr:{pageTitle:"Bienvenue sur CastReader",loadingLabel:"Chargement de CastReader…",startupError:"Impossible de se connecter à CastReader. Veuillez réessayer.",genericError:"Impossible d’ouvrir cette option pour le moment. Réessayez ou choisissez-en une autre.",eyebrow:"Votre première écoute",title:"Qu’aimeriez-vous écouter aujourd’hui ?",subtitle:"Choisissez une option. Nous vous conduirons au bon endroit et vous indiquerons le seul bouton à utiliser.",recommended:"Recommandé",openScene:"Commencer ici",opening:"Ouverture…",handoffTitle:"La prochaine étape se trouve sur la page ouverte",handoffBody:"Repérez le bouton orange CastReader, puis cliquez sur « Lire ». Revenez ici pour changer d’option.",skip:"Plus tard",privacy:"Pas besoin de vous connecter. Ce guide et les analyses produit n’enregistrent ni texte, ni nom de fichier, ni titre, ni e-mail, ni conversation.",scenes:{web_email:{icon:"🌐",title:"Page Web ou long e-mail",description:"Actualités, blogs, Gmail et Outlook."},kindle:{icon:"📚",title:"Livre Kindle",description:"Écoutez dans Kindle Cloud Reader en suivant le texte."},pdf_document:{icon:"📄",title:"PDF ou document",description:"PDF, EPUB, DOCX, texte et Google Docs."},ai_chat:{icon:"✨",title:"Réponse d’IA",description:"ChatGPT, Claude, Gemini et autres."}}},de:{pageTitle:"Willkommen bei CastReader",loadingLabel:"CastReader wird geladen…",startupError:"Die Verbindung zu CastReader ist fehlgeschlagen. Bitte versuche es erneut.",genericError:"Diese Option kann gerade nicht geöffnet werden. Versuche es erneut oder wähle eine andere.",eyebrow:"Dein erstes Vorlesen",title:"Was möchtest du heute hören?",subtitle:"Wähle eine Option. Wir bringen dich zur richtigen Stelle und zeigen dir genau, auf welche Schaltfläche du klicken musst.",recommended:"Empfohlen",openScene:"Hier starten",opening:"Wird geöffnet…",handoffTitle:"Der nächste Schritt ist auf der geöffneten Seite",handoffBody:"Suche den orangefarbenen CastReader-Hinweis und klicke auf „Vorlesen“. Kehre hierher zurück, um eine andere Option zu wählen.",skip:"Später",privacy:"Keine Anmeldung erforderlich. Dieser Leitfaden und die Produktanalyse speichern keine Texte, Dateinamen, Buchtitel, E-Mails oder Gespräche.",scenes:{web_email:{icon:"🌐",title:"Webseite oder lange E-Mail",description:"Nachrichten, Blogs, Gmail und Outlook."},kindle:{icon:"📚",title:"Kindle-Buch",description:"Im Kindle Cloud Reader hören und mitlesen."},pdf_document:{icon:"📄",title:"PDF oder Dokument",description:"PDF, EPUB, DOCX, Text und Google Docs."},ai_chat:{icon:"✨",title:"KI-Antwort",description:"ChatGPT, Claude, Gemini und weitere."}}},pt:{pageTitle:"Boas-vindas ao CastReader",loadingLabel:"Carregando o CastReader…",startupError:"Não foi possível conectar ao CastReader. Tente novamente.",genericError:"Não foi possível abrir esta opção agora. Tente novamente ou escolha outra.",eyebrow:"Sua primeira leitura em voz alta",title:"O que você quer ouvir hoje?",subtitle:"Escolha uma opção. Levaremos você à página certa e mostraremos qual botão usar.",recommended:"Recomendado",openScene:"Começar aqui",opening:"Abrindo…",handoffTitle:"O próximo passo está na página aberta",handoffBody:"Procure a indicação laranja do CastReader e clique em “Ler”. Volte aqui para escolher outra opção.",skip:"Mais tarde",privacy:"Não é preciso fazer login. Este guia e a análise do produto não registram textos, nomes de arquivos, títulos, e-mails ou conversas.",scenes:{web_email:{icon:"🌐",title:"Página da web ou e-mail longo",description:"Notícias, blogs, Gmail e Outlook."},kindle:{icon:"📚",title:"Livro Kindle",description:"Ouça e acompanhe no Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF ou documento",description:"PDF, EPUB, DOCX, texto e Google Docs."},ai_chat:{icon:"✨",title:"Resposta de IA",description:"ChatGPT, Claude, Gemini e outros."}}},it:{pageTitle:"Benvenuto in CastReader",loadingLabel:"Caricamento di CastReader…",startupError:"Impossibile connettersi a CastReader. Riprova.",genericError:"Al momento non è possibile aprire questa opzione. Riprova o scegline un’altra.",eyebrow:"Il tuo primo ascolto",title:"Cosa vuoi ascoltare oggi?",subtitle:"Scegli un’opzione. Ti porteremo alla pagina giusta e ti indicheremo l’unico pulsante da premere.",recommended:"Consigliato",openScene:"Inizia qui",opening:"Apertura…",handoffTitle:"Il prossimo passo è nella pagina aperta",handoffBody:"Cerca l’indicatore arancione di CastReader e premi «Leggi». Torna qui per scegliere un’altra opzione.",skip:"Più tardi",privacy:"Non è necessario accedere. Questa guida e le analisi del prodotto non registrano testo, nomi file, titoli, e-mail o conversazioni.",scenes:{web_email:{icon:"🌐",title:"Pagina Web o e-mail lunga",description:"Notizie, blog, Gmail e Outlook."},kindle:{icon:"📚",title:"Libro Kindle",description:"Ascolta e segui in Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF o documento",description:"PDF, EPUB, DOCX, testo e Google Docs."},ai_chat:{icon:"✨",title:"Risposta dell’IA",description:"ChatGPT, Claude, Gemini e altri."}}},hi:{pageTitle:"CastReader में आपका स्वागत है",loadingLabel:"CastReader लोड हो रहा है…",startupError:"CastReader से जुड़ नहीं पाए। कृपया फिर कोशिश करें।",genericError:"यह विकल्प नहीं खुल सका। फिर से कोशिश करें या कोई दूसरा विकल्प चुनें।",eyebrow:"पहली बार सुनें",title:"आज आप क्या सुनना चाहेंगे?",subtitle:"एक विकल्प चुनें। हम सही पेज खोलेंगे और बताएँगे कि कौन-सा बटन दबाना है।",recommended:"सुझाया गया",openScene:"यहाँ से शुरू करें",opening:"खुल रहा है…",handoffTitle:"अगला कदम खोले गए पेज पर है",handoffBody:"नारंगी CastReader संकेत ढूँढें और “पढ़ें” बटन दबाएँ। बदलने के लिए यहाँ लौटें।",skip:"बाद में",privacy:"लॉग इन करने की ज़रूरत नहीं है। यह गाइड और उत्पाद विश्लेषण टेक्स्ट, फ़ाइल नाम, किताब के शीर्षक, ईमेल या बातचीत रिकॉर्ड नहीं करते।",scenes:{web_email:{icon:"🌐",title:"वेब पेज या लंबा ईमेल",description:"समाचार, ब्लॉग, Gmail और Outlook।"},kindle:{icon:"📚",title:"Kindle किताब",description:"Kindle Cloud Reader में सुनें और साथ पढ़ें।"},pdf_document:{icon:"📄",title:"PDF या दस्तावेज़",description:"PDF, EPUB, DOCX, टेक्स्ट और Google Docs।"},ai_chat:{icon:"✨",title:"AI का जवाब",description:"ChatGPT, Claude, Gemini और अन्य।"}}},nl:{pageTitle:"Welkom bij CastReader",loadingLabel:"CastReader laden…",startupError:"CastReader kon niet starten. Vernieuw deze pagina om het opnieuw te proberen.",genericError:"We konden deze scène niet openen. Probeer het opnieuw of kies een andere scène.",eyebrow:"Je eerste keer hardop lezen",title:"Waar wil je vandaag naar luisteren?",subtitle:"Kies er een. We brengen je naar de juiste plek en tonen je de knop waar je op moet drukken.",recommended:"Aanbevolen",openScene:"Start hier",opening:"Openen…",handoffTitle:"Je volgende stap staat op de geopende pagina",handoffBody:"Zoek naar de oranje CastReader-aanwijzing en druk op Lezen. Je kunt hier terugkeren om van scène te wisselen.",skip:"Misschien later",privacy:"Inloggen niet vereist. Deze gids en productstatistieken registreren nooit paginatekst, bestandsnamen, boektitels, e-mails of gesprekken.",scenes:{web_email:{icon:"🌐",title:"Webpagina of lange e-mail",description:"Nieuws, blogs, nieuwsbrieven, Gmail en Outlook."},kindle:{icon:"📚",title:"Kindle-boek",description:"Luister en lees mee binnen Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"Pdf of document",description:"PDF, EPUB, DOCX, tekstbestanden en Google Docs."},ai_chat:{icon:"✨",title:"AI-antwoord",description:"ChatGPT, Claude, Gemini en andere ondersteunde chats."}}},ru:{pageTitle:"Добро пожаловать в CastReader",loadingLabel:"Загрузка CastReader…",startupError:"Не удалось запустить CastReader. Перезагрузите страницу, чтобы попробовать снова.",genericError:"Не удалось открыть этот раздел. Попробуйте еще раз или выберите другой.",eyebrow:"Ваше первое чтение вслух",title:"Что бы вы хотели послушать сегодня?",subtitle:"Выберите один вариант. Мы перенаправим вас в нужное место и покажем, какую кнопку нажать.",recommended:"Рекомендуемое",openScene:"Начать здесь",opening:"Открытие…",handoffTitle:"Ваш следующий шаг — на открытой странице",handoffBody:"Найдите оранжевую подсказку CastReader, затем нажмите «Читать». Вы можете вернуться сюда, чтобы сменить раздел.",skip:"Возможно, позже",privacy:"Регистрация не требуется. Это руководство и аналитика продукта никогда не записывают текст страниц, имена файлов, названия книг, электронную почту или переписку.",scenes:{web_email:{icon:"🌐",title:"Веб-страница или длинное письмо",description:"Новости, блоги, рассылки, Gmail and Outlook."},kindle:{icon:"📚",title:"Книга Kindle",description:"Слушайте и следите за текстом прямо в Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF или документ",description:"PDF, EPUB, DOCX, текстовые файлы и Google Документы."},ai_chat:{icon:"✨",title:"Ответ ИИ",description:"ChatGPT, Claude, Gemini и другие поддерживаемые чаты."}}},ko:{pageTitle:"CastReader에 오신 것을 환영합니다",loadingLabel:"CastReader 로딩 중…",startupError:"CastReader를 시작할 수 없습니다. 이 페이지를 새로고침하여 다시 시도해 주세요.",genericError:"이 화면을 열 수 없습니다. 다시 시도하거나 다른 화면을 선택해 주세요.",eyebrow:"첫 소리 내어 읽기",title:"오늘은 어떤 글을 듣고 싶으신가요?",subtitle:"하나를 선택해 주세요. 올바른 위치로 이동하여 눌러야 할 버튼을 안내해 드립니다.",recommended:"추천",openScene:"여기서 시작하기",opening:"여는 중…",handoffTitle:"다음 단계는 새로 열린 페이지에서 진행됩니다",handoffBody:"주황색 CastReader 표시를 찾은 다음 '읽기'를 누르세요. 여기로 돌아와 화면을 전환할 수 있습니다.",skip:"나중에 하기",privacy:"로그인이 필요하지 않습니다. 이 가이드와 제품 분석은 페이지 텍스트, 파일 이름, 도서 제목, 이메일 또는 대화 내용을 절대 기록하지 않습니다.",scenes:{web_email:{icon:"🌐",title:"웹 페이지 또는 긴 이메일",description:"뉴스, 블로그, 뉴스레터, Gmail 및 Outlook."},kindle:{icon:"📚",title:"Kindle 도서",description:"Kindle Cloud Reader에서 들으며 함께 읽어보세요."},pdf_document:{icon:"📄",title:"PDF 또는 문서",description:"PDF, EPUB, DOCX, 텍스트 파일 및 Google Docs."},ai_chat:{icon:"✨",title:"AI 답변",description:"ChatGPT, Claude, Gemini 및 기타 지원되는 채팅."}}},ar:{pageTitle:"مرحبًا بك في CastReader",loadingLabel:"جاري تحميل CastReader…",startupError:"تعذر بدء CastReader. أعد تحميل هذه الصفحة للمحاولة مرة أخرى.",genericError:"لم نتمكن من فتح هذا المشهد. حاول مرة أخرى أو اختر مشهدًا آخر.",eyebrow:"قراءتك الأولى بصوت عالٍ",title:"ما الذي تود الاستماع إليه اليوم؟",subtitle:"اختر واحدًا. سنأخذك إلى المكان الصحيح ونوضح لك الزر الوحيد الذي يجب الضغط عليه.",recommended:"موصى به",openScene:"ابدأ من هنا",opening:"جاري الفتح…",handoffTitle:"خطوتك التالية موجودة في الصفحة التي فتحناها",handoffBody:"ابحث عن إشارة CastReader البرتقالية، ثم اضغط على 'اقرأ'. يمكنك العودة إلى هنا لتغيير المشاهد.",skip:"ربما لاحقًا",privacy:"لا يتطلب تسجيل الدخول. لا يسجل هذا الدليل وتحليلات المنتج أبدًا نصوص الصفحات، أو أسماء الملفات، أو عناوين الكتب، أو البريد الإلكتروني، أو المحادثات.",scenes:{web_email:{icon:"🌐",title:"صفحة ويب أو بريد إلكتروني طويل",description:"الأخبار، والمدونات، والنشرات الإخبارية، وGmail، وOutlook."},kindle:{icon:"📚",title:"كتاب Kindle",description:"استمع وتابع القراءة داخل Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"ملف PDF أو مستند",description:"ملفات PDF، وEPUB، وDOCX، والملفات النصية، ومستندات Google Docs."},ai_chat:{icon:"✨",title:"رد الذكاء الاصطناعي",description:"ChatGPT، وClaude، وGemini، والمحادثات الأخرى المدعومة."}}},pl:{pageTitle:"Witamy w CastReader",loadingLabel:"Ładowanie CastReader…",startupError:"CastReader nie mógł się uruchomić. Odśwież tę stronę, aby spróbować ponownie.",genericError:"Nie mogliśmy otworzyć tej sceny. Spróbuj ponownie lub wybierz inną scenę.",eyebrow:"Twoje pierwsze czytanie na głos",title:"Co chciałbyś dzisiaj posłuchać?",subtitle:"Wybierz jedno. Przekierujemy Cię we właściwe miejsce i pokażemy jeden przycisk do naciśnięcia.",recommended:"Polecane",openScene:"Zacznij stąd",opening:"Otwieranie…",handoffTitle:"Twój następny krok znajduje się na stronie, którą otworzyliśmy",handoffBody:"Szukaj pomarańczowego wskaźnika CastReader, a następnie naciśnij Czytaj. Możesz wrócić tutaj, aby przełączyć scenę.",skip:"Może później",privacy:"Brak wymogu logowania. Ten przewodnik i analityka produktu nigdy nie rejestrują tekstu strony, nazw plików, tytułów książek, e-maili ani rozmów.",scenes:{web_email:{icon:"🌐",title:"Strona internetowa lub długi e-mail",description:"Wiadomości, blogi, newslettery, Gmail i Outlook."},kindle:{icon:"📚",title:"Książka Kindle",description:"Słuchaj i śledź treść wewnątrz Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF lub dokument",description:"Pliki PDF, EPUB, DOCX, pliki tekstowe i Google Docs."},ai_chat:{icon:"✨",title:"Odpowiedź AI",description:"ChatGPT, Claude, Gemini i inne obsługiwane czaty."}}},sv:{pageTitle:"Välkommen till CastReader",loadingLabel:"Laddar CastReader…",startupError:"CastReader kunde inte startas. Ladda om sidan för att försöka igen.",genericError:"Vi kunde inte öppna denna scen. Försök igen eller välj en annan scen.",eyebrow:"Din första läsning högt",title:"Vad vill du lyssna på idag?",subtitle:"Välj en. Vi tar dig rätt och visar dig den enda knappen du behöver trycka på.",recommended:"Rekommenderat",openScene:"Börja här",opening:"Öppnar…",handoffTitle:"Ditt nästa steg finns på sidan vi öppnade",handoffBody:"Sök efter den orangea CastReader-pekaren, tryck sedan på Läs. Du kan återvända hit för att byta scen.",skip:"Kanske senare",privacy:"Ingen inloggning krävs. Denna guide och produktanalys sparar aldrig sidtext, filnamn, boktitlar, e-post eller samtal.",scenes:{web_email:{icon:"🌐",title:"Webbsida eller långt e-postmeddelande",description:"Nyheter, bloggar, nyhetsbrev, Gmail och Outlook."},kindle:{icon:"📚",title:"Kindle-bok",description:"Lyssna och följ med inuti Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF eller dokument",description:"PDF, EPUB, DOCX, textfiler och Google Docs."},ai_chat:{icon:"✨",title:"AI-svar",description:"ChatGPT, Claude, Gemini och andra stödda chattar."}}},da:{pageTitle:"Velkommen til CastReader",loadingLabel:"Indlæser CastReader…",startupError:"CastReader kunne ikke starte. Genindlæs denne side for at prøve igen.",genericError:"Vi kunne ikke åbne dette scenarie. Prøv igen, eller vælg et andet scenarie.",eyebrow:"Din første oplæsning",title:"Hvad vil du gerne lytte til i dag?",subtitle:"Vælg én. Vi tager dig til det rigtige sted, og viser dig den ene knap, du skal trykke på.",recommended:"Anbefalet",openScene:"Start her",opening:"Åbner…",handoffTitle:"D næste skridt er på siden, vi åbnede",handoffBody:"Kig efter den orange CastReader-vejledning, og tryk derefter på Læs. Du kan vende tilbage her for at skifte scenarie.",skip:"Måske senere",privacy:"Ingen log ind krævet. Denne guide og produktanalyser optager aldrig sides tekst, filnavne, bogtitler, e-mail eller samtaler.",scenes:{web_email:{icon:"🌐",title:"Webside eller lang e-mail",description:"Nyheder, blogs, nyhedsbreve, Gmail og Outlook."},kindle:{icon:"📚",title:"Kindle-bog",description:"Lyt og følg med inde i Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF eller dokument",description:"PDF, EPUB, DOCX, tekstfiler og Google Docs."},ai_chat:{icon:"✨",title:"AI-svar",description:"ChatGPT, Claude, Gemini og andre understøttede chats."}}},nb:{pageTitle:"Velkommen til CastReader",loadingLabel:"Laster inn CastReader…",startupError:"CastReader kunne ikke starte. Last inn denne siden på nytt for å prøve igjen.",genericError:"Vi kunne ikke åpne denne scenen. Prøv igjen eller velg en annen scene.",eyebrow:"Din første lesing høyt",title:"Hva vil du lytte til i dag?",subtitle:"Velg én. Vi tar deg til rett sted og viser deg den ene knappen du må trykke på.",recommended:"Anbefalt",openScene:"Start her",opening:"Åpner…",handoffTitle:"Neste steg er på siden vi åpnet",handoffBody:"Se etter den oransje CastReader-indikatoren, og trykk deretter på Les. Du kan komme tilbake hit for å bytte scene.",skip:"Kanskje senere",privacy:"Ingen innlogging kreves. Denne guiden og produktanalyser registrerer aldri sidetekst, filnavn, bokens tittel, e-post eller samtaler.",scenes:{web_email:{icon:"🌐",title:"Nettside eller lang e-post",description:"Nyheter, bloggar, nyhetsbrev, Gmail og Outlook."},kindle:{icon:"📚",title:"Kindle-bok",description:"Lytt og følg med inne i Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF eller dokument",description:"PDF, EPUB, DOCX, tekstfiler og Google Docs."},ai_chat:{icon:"✨",title:"AI-svar",description:"ChatGPT, Claude, Gemini og andre støttede chats."}}},fi:{pageTitle:"Tervetuloa CastReaderiin",loadingLabel:"Ladataan CastReaderia…",startupError:"CastReader ei voinut käynnistyä. Lataa sivu uudelleen ja yritä taas.",genericError:"Emme voineet avata tätä kohtaa. Yritä uudelleen tai valitse toinen kohta.",eyebrow:"Ensimmäinen ääneenluentosi",title:"Mitä haluaisit kuunnella tänään?",subtitle:"Valitse yksi. Ohjaamme sinut oikeaan paikkaan ja näytämme yhden painettavan painikkeen.",recommended:"Suositeltu",openScene:"Aloita tästä",opening:"Avataan…",handoffTitle:"Seuraava askel on avatulla sivulla",handoffBody:"Etsi oranssi CastReader-ilmoitus ja paina Lue. Voit palata tähän vaihtaaksesi kohtaa.",skip:"Ehkä myöhemmin",privacy:"Ei vaadi kirjautumista. Tämä opas ja tuoteanalytiikka eivät koskaan tallenna sivujen tekstiä, tiedostonimiä, kirjojen nimiä, sähköposteja tai keskusteluja.",scenes:{web_email:{icon:"🌐",title:"Verkkosivu tai pitkä sähköposti",description:"Uutiset, blogit, uutiskirjeet, Gmail ja Outlook."},kindle:{icon:"📚",title:"Kindle-kirja",description:"Kuuntele ja seuraa mukana Kindle Cloud Readerin sisällä."},pdf_document:{icon:"📄",title:"PDF tai dokumentti",description:"PDF, EPUB, DOCX, tekstiedostot ja Google Docs."},ai_chat:{icon:"✨",title:"Tekeäsvastaus",description:"ChatGPT, Claude, Gemini ja muut tuetut chatit."}}},cs:{pageTitle:"Vítejte v CastReaderu",loadingLabel:"Načítání CastReaderu…",startupError:"CastReader se nepodařilo spustit. Obnovte tuto stránku a zkuste to znovu.",genericError:"Tuto scénu se nám nepodařilo otevřít. Zkuste to znovu nebo vyberte jinou scénu.",eyebrow:"Vaše první čtení nahlas",title:"Co byste si dnes chtěli poslechnout?",subtitle:"Vyberte jednu možnost. Přesměrujeme vás na správné místo a ukážeme vám jedno tlačítko k stisku.",recommended:"Doporučené",openScene:"Začněte zde",opening:"Otevírání…",handoffTitle:"Vaším dalším krokem je stránka, kterou jsme otevřeli",handoffBody:"Hledejte oranžový podnět CastReaderu, pak stiskněte Přečíst. Můžete se vrátit sem a přepnout scénu.",skip:"Možná později",privacy:"Žádné přihlášení není vyžadováno. Tento průvodce a analytika produktu nikdy nezaznamenávají text stránky, názvy souborů, názvy knih, e-maily ani konverzace.",scenes:{web_email:{icon:"🌐",title:"Webová stránka nebo dlouhý e-mail",description:"Novinky, blogy, newslettery, Gmail a Outlook."},kindle:{icon:"📚",title:"Kniha Kindle",description:"Poslouchejte a sledujte průběh uvnitř Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF nebo dokument",description:"PDF, EPUB, DOCX, textové soubory a Google Docs."},ai_chat:{icon:"✨",title:"Odpověď AI",description:"ChatGPT, Claude, Gemini a další podporované chaty."}}},el:{pageTitle:"Καλώς ήρθατε στο CastReader",loadingLabel:"Φόρτωση CastReader…",startupError:"Το CastReader δεν μπόρεσε να ξεκινήσει. Ανανεώστε αυτή τη σελίδα για να δοκιμάσετε ξανά.",genericError:"Δεν μπορέσαμε να ανοίξουμε αυτή τη σκηνή. Δοκιμάστε ξανά ή επιλέξτε άλλη σκηνή.",eyebrow:"Η πρώτη σας ανάγνωση με φωνή",title:"Τι θα θέλατε να ακούσετε σήμερα;",subtitle:"Επιλέξτε ένα. Θα σας οδηγήσουμε στον σωστό χώρο και θα σας δείξουμε το ένα κουμπί που πρέπει να πατήσετε.",recommended:"Συνιστάται",openScene:"Ξεκινήστε从这里",opening:"Άνοιγμα…",handoffTitle:"Το επόμενο βήμα σας είναι στη σελίδα που ανοίξαμε",handoffBody:"Ψάξτε για την πορτοκαλί ένδειξη CastReader, μετά πατήστε Ανάγνωση. Μπορείτε να επιστρέψετε εδώ για εναλλαγή σκηνών.",skip:"Ίσως αργότερα",privacy:"Δεν απαιτείται σύνδεση. Οδηγός και αναλυτικά προϊόντος δεν καταγράφουν ποτέ κείμενο σελίδας, ονόματα αρχείων, τίτλους βιβλίων, email ή συνομιλίες.",scenes:{web_email:{icon:"🌐",title:"Ιστοσελίδα ή μακρύ email",description:"Νέα, blogs, newsletters, Gmail και Outlook."},kindle:{icon:"📚",title:"Βιβλίο Kindle",description:"Ακούστε και ακολουθήστε μέσα στο Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF ή έγγραφο",description:"PDF, EPUB, DOCX, αρχεία κειμένου και Google Docs."},ai_chat:{icon:"✨",title:"Απάντηση AI",description:"ChatGPT, Claude, Gemini και άλλες υποστηριζόμενες συνομιλίες."}}},hu:{pageTitle:"Üdvözöljük a CastReaderen",loadingLabel:"CastReader betöltése…",startupError:"A CastReader nem tudott elindulni. Frissítse az oldalt a próbálkozáshoz.",genericError:"Nem sikerült megnyitni ezt a jelenetet. Próbálja újra, vagy válasszon másik jelenetet.",eyebrow:"Az első felolvasása",title:"Mit szeretne ma meghallgatni?",subtitle:"Válasszon egyet. Megmutatjuk a megfelelő helyet és azt az egyetlen gombot, amelyet meg kell nyomnia.",recommended:"Ajánlott",openScene:"Kezdje itt",opening:"Megnyitás…",handoffTitle:"A következő lépés a megnyitott oldalon van",handoffBody:"Keresse a narancssárga CastReader jelzést, majd nyomja meg az Olvasás gombot. Itt visszatérhet a jelenetek váltásához.",skip:"Talán később",privacy:"Nincs szükség bejelentkezésre. Ez az útmutató és a termékanalitika soha nem rögzít oldalszöveget, fájlnévvel, könyvcímmel, e-maillel vagy beszélgetésekkel.",scenes:{web_email:{icon:"🌐",title:"Weboldal vagy hosszú e-mail",description:"Hírek, blogok, hírlevelek, Gmail és Outlook."},kindle:{icon:"📚",title:"Kindle-könyv",description:"Hallgassa és kövesse a Kindle Cloud Readeren belül."},pdf_document:{icon:"📄",title:"PDF vagy dokumentum",description:"PDF, EPUB, DOCX, szöveges fájlok és Google Docs."},ai_chat:{icon:"✨",title:"AI-válasz",description:"ChatGPT, Claude, Gemini és más támogatott csevegések."}}},fil:{pageTitle:"Maligayang pagdating sa CastReader",loadingLabel:"Nilo-load ang CastReader…",startupError:"Hindi nasimulan ang CastReader. I-reload ang pahinang ito para subukan muli.",genericError:"Hindi namin maibukas ang eksena na ito. Subukan muli o pumili ng ibang eksena.",eyebrow:"Ang iyong unang pagbasa nang malakas",title:"Ano ang gusto mong pakinggan ngayon?",subtitle:"Pumili ng isa. Dadalhin ka namin sa tamang lugar at ipapakita ang isang pindutan na dapat pindutin.",recommended:"Inirerekomenda",openScene:"Magsimula dito",opening:"Binubuksan…",handoffTitle:"Ang susunod mong hakbang ay nasa pahinang binuksan namin",handoffBody:"Hanapin ang kahel na CastReader cue, pagkatapos ay pindutin ang Basahin. Maaari kang bumalik dito upang lumipat ng mga eksena.",skip:"Baka mamaya",privacy:"Hindi kailangan ng pag-sign in. Ang gabay na ito at analytics ng produkto ay hindi kailanman nagre-record ng teksto sa pahina, mga pangalan ng file, pamagat ng libro, email, o mga usapan.",scenes:{web_email:{icon:"🌐",title:"Web page o mahabang email",description:"Balita, blog, newsletter, Gmail at Outlook."},kindle:{icon:"📚",title:"Libro sa Kindle",description:"Makinig at sumabay sa loob ng Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF o dokumento",description:"PDF, EPUB, DOCX, mga text file at Google Docs."},ai_chat:{icon:"✨",title:"Tugon ng AI",description:"ChatGPT, Claude, Gemini at iba pang suportadong chat."}}},he:{pageTitle:"ברוכים הבאים ל-CastReader",loadingLabel:"טוען את CastReader…",startupError:"לא ניתן היה להפעיל את CastReader. טענו מחדש את הדף כדי לנסות שוב.",genericError:"לא הצלחנו לפתוח סצנה זו. נסו שוב או בחרו סצנה אחרת.",eyebrow:"ההקראה הראשונה שלכם",title:"מה תרצו להאזין לו היום?",subtitle:"בחרו אפשרות אחת. אנו נפנה אתכם למקום המתאים ונראה לכם את הכפתור היחיד שיש ללחוץ עליו.",recommended:"מומלץ",openScene:"התחילו כאן",opening:"פותח…",handoffTitle:"הצעד הבא שלכם נמצא בדף שפתחנו",handoffBody:'חפש את הסמן הכתום של CastReader, ואז לחץ על "קרא". תוכל לחזור לכאן כדי להחליף סצנות.',skip:"אולי מאוחר יותר",privacy:'לא נדרשת הרשמה. המדריך הזה וניתוחי המוצר לעולם אינם מתעדים טקסט מהדף, שמות קבצים, כותרות ספרים, דוא"ל או שיחות.',scenes:{web_email:{icon:"🌐",title:"דף אינטרנט או מייל ארוך",description:"חדשות, בלוגים, ניוזלטרים, Gmail ו-Outlook."},kindle:{icon:"📚",title:"ספר Kindle",description:"האזן ועקוב בתוך Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF או מסמך",description:"PDF, EPUB, DOCX, קבצי טקסט ו-Google Docs."},ai_chat:{icon:"✨",title:"תגובת AI",description:"ChatGPT, Claude, Gemini וצ'אטים נתמכים אחרים."}}},id:{pageTitle:"Selamat datang di CastReader",loadingLabel:"Memuat CastReader…",startupError:"CastReader tidak dapat dimulai. Muat ulang halaman ini untuk mencoba lagi.",genericError:"Kami tidak dapat membuka adegan ini. Coba lagi atau pilih adegan lain.",eyebrow:"Bacaan suara pertama Anda",title:"Apa yang ingin Anda dengarkan hari ini?",subtitle:"Pilih satu. Kami akan membawa Anda ke tempat yang tepat dan menunjukkan satu tombol untuk ditekan.",recommended:"Direkomendasikan",openScene:"Mulai dari sini",opening:"Membuka…",handoffTitle:"Langkah berikutnya Anda ada di halaman yang kami buka",handoffBody:"Cari petunjuk CastReader berwarna oranye, lalu tekan Baca. Anda dapat kembali ke sini untuk mengganti adegan.",skip:"Mungkin nanti",privacy:"Tidak perlu masuk. Panduan ini dan analitik produk tidak pernah merekam teks halaman, nama file, judul buku, email, atau percakapan.",scenes:{web_email:{icon:"🌐",title:"Halaman web atau email panjang",description:"Berita, blog, buletin, Gmail, dan Outlook."},kindle:{icon:"📚",title:"Buku Kindle",description:"Dengarkan dan ikuti di dalam Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF atau dokumen",description:"PDF, EPUB, DOCX, file teks, dan Google Docs."},ai_chat:{icon:"✨",title:"Respons AI",description:"ChatGPT, Claude, Gemini, dan obrolan lain yang didukung."}}},ms:{pageTitle:"Selamat datang ke CastReader",loadingLabel:"Memuatkan CastReader…",startupError:"CastReader tidak dapat dimulakan. Muat semula halaman ini untuk mencuba lagi.",genericError:"Kami tidak dapat membuka babak ini. Cuba lagi atau pilih babak lain.",eyebrow:"Bacaan kuat pertama anda",title:"Apakah yang anda ingin dengar hari ini?",subtitle:"Pilih satu. Kami akan membawa anda ke tempat yang betul dan menunjukkan butang tunggal untuk ditekan.",recommended:"Disyorkan",openScene:"Mulakan di sini",opening:"Membuka…",handoffTitle:"Langkah seterusnya anda berada pada halaman yang kami buka",handoffBody:"Cari isyarat CastReader berwarna oren, kemudian tekan Baca. Anda boleh kembali ke sini untuk menukar adegan.",skip:"Mungkin nanti",privacy:"Tidak perlu log masuk. Panduan ini dan analitik produk tidak pernah merekod teks halaman, nama fail, tajuk buku, e-mel atau perbualan.",scenes:{web_email:{icon:"🌐",title:"Halaman web atau e-mel panjang",description:"Berita, blog, buletin, Gmail dan Outlook."},kindle:{icon:"📚",title:"Buku Kindle",description:"Dengar dan ikuti di dalam Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF atau dokumen",description:"PDF, EPUB, DOCX, fail teks dan Google Docs."},ai_chat:{icon:"✨",title:"Respons AI",description:"ChatGPT, Claude, Gemini dan sembang lain yang disokong."}}},ro:{pageTitle:"Bine ai venit la CastReader",loadingLabel:"Se încarcă CastReader…",startupError:"CastReader nu a putut porni. Reîncarcă această pagină pentru a încerca din nou.",genericError:"Nu am putut deschide acest scenariu. Încearcă din nou sau alege alt scenariu.",eyebrow:"Prima ta lectură cu voce tare",title:"Ce ai dori să asculți astăzi?",subtitle:"Alege una. Te vom direcționa către locul potrivit și îți vom arăta butonul pe care trebuie să îl apeși.",recommended:"Recomandat",openScene:"Începe aici",opening:"Se deschide…",handoffTitle:"Următorul pas se află pe pagina pe care am deschis-o",handoffBody:"Caută indicatorul portocaliu CastReader, apoi apasă pe Redare. Te poți întoarce aici pentru a schimba scenele.",skip:"Poate mai târziu",privacy:"Nu este necesară autentificarea. Acest ghid și analizele produsului nu înregistrează niciodată textul paginii, numele fișierelor, titlurile cărților, e-mailurile sau conversațiile.",scenes:{web_email:{icon:"🌐",title:"Pagină web sau e-mail lung",description:"Știri, bloguri, newslettere, Gmail și Outlook."},kindle:{icon:"📚",title:"Carte Kindle",description:"Ascultă și urmărește în Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF sau document",description:"PDF, EPUB, DOCX, fișiere text și Google Docs."},ai_chat:{icon:"✨",title:"Răspuns AI",description:"ChatGPT, Claude, Gemini și alte chat-uri suportate."}}},tr:{pageTitle:"CastReader'a hoş geldiniz",loadingLabel:"CastReader yükleniyor…",startupError:"CastReader başlatılamadı. Tekrar denemek için bu sayfayı yenileyin.",genericError:"Bu sahneyi açamadık. Tekrar deneyin veya başka bir sahne seçin.",eyebrow:"İlk sesli okumanız",title:"Bugün ne dinlemek istersiniz?",subtitle:"Birini seçin. Sizi doğru yere götürelim ve basmanız gereken tek düğmeyi gösterelim.",recommended:"Önerilen",openScene:"Buradan başlayın",opening:"Açılıyor…",handoffTitle:"Bir sonraki adımınız, açtığımız sayfadadır",handoffBody:"Turuncu CastReader simgesini bulun, ardından Oku'ya basın. Sahne değiştirmek için buraya dönebilirsiniz.",skip:"Belki daha sonra",privacy:"Oturum açma gerekmez. Bu kılavuz ve ürün analitiği asla sayfa metnini, dosya adlarını, kitap başlıklarını, e-postayı veya konuşmaları kaydetmez.",scenes:{web_email:{icon:"🌐",title:"Web sayfası veya uzun e-posta",description:"Haberler, bloglar, bültenler, Gmail ve Outlook."},kindle:{icon:"📚",title:"Kindle kitabı",description:"Kindle Cloud Reader içinde dinleyin ve takip edin."},pdf_document:{icon:"📄",title:"PDF veya belge",description:"PDF, EPUB, DOCX, metin dosyaları ve Google Docs."},ai_chat:{icon:"✨",title:"Yapay zeka yanıtı",description:"ChatGPT, Claude, Gemini ve diğer desteklenen sohbetler."}}},vi:{pageTitle:"Chào mừng đến với CastReader",loadingLabel:"Đang tải CastReader…",startupError:"CastReader không thể khởi động. Hãy tải lại trang này để thử lại.",genericError:"Chúng tôi không thể mở cảnh này. Vui lòng thử lại hoặc chọn cảnh khác.",eyebrow:"Lần đọc to đầu tiên của bạn",title:"Hôm nay bạn muốn nghe gì?",subtitle:"Chọn một mục. Chúng tôi sẽ đưa bạn đến đúng nơi và chỉ cho bạn nút cần nhấn.",recommended:"Đề xuất",openScene:"Bắt đầu tại đây",opening:"Đang mở…",handoffTitle:"Bước tiếp theo của bạn nằm trên trang chúng tôi đã mở",handoffBody:"Tìm dấu hiệu CastReader màu cam, sau đó nhấn Đọc. Bạn có thể quay lại đây để chuyển cảnh.",skip:"Có lẽ để sau",privacy:"Không cần đăng nhập. Hướng dẫn này và phân tích sản phẩm không bao giờ ghi lại văn bản trang, tên tệp, tiêu đề sách, email hoặc cuộc trò chuyện.",scenes:{web_email:{icon:"🌐",title:"Trang web hoặc email dài",description:"Tin tức, blog, bản tin, Gmail và Outlook."},kindle:{icon:"📚",title:"Sách Kindle",description:"Nghe và theo dõi bên trong Kindle Cloud Reader."},pdf_document:{icon:"📄",title:"PDF hoặc tài liệu",description:"PDF, EPUB, DOCX, tệp văn bản và Google Docs."},ai_chat:{icon:"✨",title:"Phản hồi AI",description:"ChatGPT, Claude, Gemini và các cuộc trò chuyện được hỗ trợ khác."}}}};function we(t){const e=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?crypto.randomUUID():Math.random().toString(36).slice(2);return`${t}:${Date.now().toString(36)}:${e}`}function ft({bootstrap:t,language:e}){const a=De[e],[o,i]=E.useState(t.state),[n,r]=E.useState(null),[l,c]=E.useState(null),p=o.flow,m=E.useCallback(async g=>{if(!n){r(g),c(null);try{let f=o;for(let y=0;y<2;y+=1){const T=await chrome.runtime.sendMessage({type:"ONBOARDING_ROUTE",payload:{scene:g,transitionId:we(`${f.onboardingId}:route:${g}`),expectedRevision:f.revision,requestedAt:Date.now()}});if(f=T.state,i(f),!(T.transition.kind==="rejected"&&T.transition.reason==="stale_revision")){T.resolution.kind==="blocked"&&c(T.resolution.code);break}}}catch(f){console.error("[Onboarding] route failed",f),c("route_failed")}finally{r(null)}}},[n,o.onboardingId,o.revision]),P=E.useCallback(async()=>{if(!(!p||n)){c(null);try{let g=o;for(let f=0;f<2;f+=1){const y=await chrome.runtime.sendMessage({type:"ONBOARDING_TRANSITION",payload:{transition:{type:"SKIPPED",transitionId:we(`${g.onboardingId}:skip`),expectedRevision:g.revision,occurredAt:Date.now(),reason:"not_now"}}});if(g=y.result.state,i(g),!(y.result.kind==="rejected"&&y.result.reason==="stale_revision")){if(y.result.kind==="applied"||y.result.kind==="duplicate"){window.close();return}c(y.result.kind==="rejected"?y.result.reason:"skip_failed");return}}c("stale_revision")}catch(g){console.error("[Onboarding] skip failed",g),c("skip_failed")}}},[p,n,o.onboardingId,o.revision]),d=(p==null?void 0:p.selectedScene)||null,b=(p==null?void 0:p.status)==="handoff_pending"||(p==null?void 0:p.status)==="target_ready"||(p==null?void 0:p.status)==="reading_started",k=(p==null?void 0:p.status)==="blocked";return E.useEffect(()=>{},[t.recommendedScene,t.sceneOrder,o.onboardingId]),u.jsx("main",{style:R.page,children:u.jsxs("section",{style:R.shell,"aria-labelledby":"onboarding-title",children:[u.jsxs("header",{style:R.header,children:[u.jsx("img",{src:chrome.runtime.getURL("/icon-128.png"),alt:"",width:64,height:64,style:R.logo}),u.jsx("p",{style:R.eyebrow,children:a.eyebrow}),u.jsx("h1",{id:"onboarding-title",style:R.title,children:a.title}),u.jsx("p",{style:R.subtitle,children:a.subtitle})]}),b?u.jsxs("div",{style:R.statusCard,role:"status",children:[u.jsx("span",{"aria-hidden":"true",style:R.statusIcon,children:"✓"}),u.jsxs("div",{children:[u.jsx("strong",{style:R.statusTitle,children:a.handoffTitle}),u.jsx("p",{style:R.statusBody,children:a.handoffBody})]})]}):null,k||l?u.jsx("div",{style:R.errorCard,role:"alert",children:u.jsx("strong",{children:a.genericError})}):null,u.jsx("div",{style:R.grid,children:t.sceneOrder.map(g=>{const f=a.scenes[g],y=n===g,T=d===g,S=t.recommendedScene===g,x=y?a.opening:S?a.recommended:null;return u.jsxs("button",{type:"button","data-onboarding-role":"scenario-card","data-onboarding-scene":g,"data-onboarding-recommended":S?"true":"false","aria-pressed":T,"aria-label":[f.title,f.description,x].filter(Boolean).join(". "),disabled:n!==null,onClick:()=>void m(g),style:{...R.sceneCard,...T?R.sceneCardSelected:{},...n&&!y?R.sceneCardMuted:{}},children:[u.jsxs("span",{style:R.sceneTopline,children:[u.jsx("span",{"aria-hidden":"true",style:R.sceneIcon,children:f.icon}),S?u.jsx("span",{style:R.recommended,children:a.recommended}):null]}),u.jsx("strong",{style:R.sceneTitle,children:f.title}),u.jsx("span",{style:R.sceneDescription,children:f.description}),u.jsxs("span",{"aria-live":y?"polite":void 0,style:R.sceneAction,children:[y?a.opening:a.openScene,u.jsx("span",{"aria-hidden":"true",children:Fe(e)==="rtl"?" ←":" →"})]})]},g)})}),u.jsx(Le,{language:e}),u.jsxs("footer",{style:R.footer,children:[u.jsx("button",{type:"button",onClick:()=>void P(),disabled:n!==null,style:R.skipButton,children:a.skip}),u.jsx("p",{style:R.privacy,children:a.privacy})]})]})})}const R={page:{minHeight:"100vh",boxSizing:"border-box",padding:"42px 24px 72px",color:"#f8fafc",background:"radial-gradient(circle at 50% -10%, rgba(242,101,34,.18), transparent 38%), #090b12",fontFamily:"-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"},shell:{width:"100%",maxWidth:920,margin:"0 auto"},header:{maxWidth:700,margin:"0 auto 34px",textAlign:"center"},logo:{display:"block",margin:"0 auto 14px",borderRadius:16,boxShadow:"0 14px 42px rgba(242,101,34,.22)"},eyebrow:{margin:"0 0 10px",color:"#fb923c",fontSize:13,fontWeight:750,letterSpacing:".1em",textTransform:"uppercase"},title:{margin:0,color:"#fff",fontSize:"clamp(32px, 5vw, 50px)",lineHeight:1.08,letterSpacing:"-.035em"},subtitle:{maxWidth:620,margin:"16px auto 0",color:"#aeb8ca",fontSize:17,lineHeight:1.6},statusCard:{display:"flex",gap:14,alignItems:"flex-start",maxWidth:650,margin:"0 auto 22px",padding:"15px 18px",border:"1px solid rgba(52,211,153,.28)",borderRadius:14,background:"rgba(6,78,59,.22)"},statusIcon:{display:"grid",flex:"0 0 auto",width:25,height:25,placeItems:"center",borderRadius:999,color:"#052e22",background:"#6ee7b7",fontWeight:900},statusTitle:{display:"block",color:"#d1fae5",fontSize:14},statusBody:{margin:"4px 0 0",color:"#a7f3d0",fontSize:13,lineHeight:1.5},errorCard:{display:"flex",justifyContent:"center",gap:10,maxWidth:650,margin:"0 auto 22px",padding:"12px 16px",border:"1px solid rgba(248,113,113,.3)",borderRadius:12,color:"#fecaca",background:"rgba(127,29,29,.22)",fontSize:13},grid:{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(min(100%, 300px), 1fr))",gap:16},sceneCard:{display:"flex",minHeight:224,padding:24,flexDirection:"column",alignItems:"stretch",textAlign:"start",color:"#f8fafc",border:"1px solid rgba(148,163,184,.18)",borderRadius:18,background:"linear-gradient(145deg, rgba(30,41,59,.9), rgba(15,23,42,.78))",boxShadow:"0 16px 44px rgba(0,0,0,.2)",cursor:"pointer",fontFamily:"inherit",transition:"border-color .15s ease, transform .15s ease, opacity .15s ease"},sceneCardSelected:{borderColor:"#fb923c",boxShadow:"0 0 0 1px rgba(251,146,60,.25), 0 18px 50px rgba(0,0,0,.28)"},sceneCardMuted:{opacity:.48},sceneTopline:{display:"flex",minHeight:42,alignItems:"center",justifyContent:"space-between"},sceneIcon:{fontSize:34,lineHeight:1},recommended:{padding:"5px 9px",color:"#ffedd5",border:"1px solid rgba(251,146,60,.28)",borderRadius:999,background:"rgba(194,65,12,.25)",fontSize:11,fontWeight:750},sceneTitle:{marginTop:20,color:"#fff",fontSize:20,lineHeight:1.3},sceneDescription:{marginTop:8,color:"#9eabc0",fontSize:14,lineHeight:1.55},sceneAction:{marginTop:"auto",paddingTop:22,color:"#fb923c",fontSize:14,fontWeight:750},footer:{marginTop:26,textAlign:"center"},skipButton:{padding:"9px 15px",color:"#aeb8ca",border:0,background:"transparent",cursor:"pointer",fontFamily:"inherit",fontSize:14,textDecoration:"underline",textUnderlineOffset:4},privacy:{maxWidth:660,margin:"14px auto 0",color:"#64748b",fontSize:12,lineHeight:1.5}};var Te,Se;const vt=typeof chrome<"u"&&((Te=chrome.i18n)!=null&&Te.getUILanguage)?chrome.i18n.getUILanguage():typeof navigator>"u"?"en":((Se=navigator.languages)==null?void 0:Se[0])||navigator.language||"en",Q=W(vt),q=De[Q],yt=Ye(Q).floating.retry,xt=8e3;typeof document<"u"&&(Re(document.documentElement,Q),document.title=q.pageTitle);function Pt(){const[t,e]=E.useState({phase:"loading"}),[a,o]=E.useState(0),i=_.page,n=_.error;return E.useEffect(()=>{let r=!1,l=!1;const c=m=>{r||l||(l=!0,clearTimeout(p),e(m))},p=setTimeout(()=>c({phase:"error"}),xt);return Promise.resolve().then(()=>chrome.runtime.sendMessage({type:"ONBOARDING_GET_BOOTSTRAP"})).then(m=>{if(!(m!=null&&m.state)){c({phase:"error"});return}c({phase:"ready",response:m})}).catch(()=>{c({phase:"error"})}),()=>{r=!0,clearTimeout(p)}},[a]),t.phase==="loading"?u.jsxs("main",{style:i,"aria-busy":"true","aria-label":q.loadingLabel,children:[u.jsx("img",{src:chrome.runtime.getURL("/icon-128.png"),alt:"",width:64,height:64,style:_.logo}),u.jsx("p",{style:n,role:"status",children:q.loadingLabel})]}):t.phase==="error"?u.jsxs("main",{style:i,children:[u.jsx("img",{src:chrome.runtime.getURL("/icon-128.png"),alt:"CastReader",width:64,height:64,style:_.logo}),u.jsx("p",{style:n,role:"alert",children:q.startupError}),u.jsx("button",{type:"button",style:_.retryButton,onClick:()=>{e({phase:"loading"}),o(r=>r+1)},children:yt})]}):t.response.showGuidedOnboarding?u.jsx(ft,{bootstrap:t.response,language:Q}):u.jsx(kt,{})}const _={page:{display:"grid",minHeight:"100vh",margin:0,placeContent:"center",justifyItems:"center",color:"#e2e8f0",background:"#090b12",fontFamily:"-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"},logo:{borderRadius:16,boxShadow:"0 14px 42px rgba(242,101,34,.22)"},retryButton:{marginTop:22,minHeight:44,padding:"11px 26px",border:"1px solid #d44505",borderRadius:10,color:"#fff",background:"#ef5108",font:"inherit",fontWeight:650,cursor:"pointer"},error:{maxWidth:420,margin:"20px 24px 0",color:"#cbd5e1",textAlign:"center",lineHeight:1.6}};Ie();Be.createRoot(document.getElementById("root")).render(u.jsx(je.StrictMode,{children:u.jsx(Pt,{})}));
