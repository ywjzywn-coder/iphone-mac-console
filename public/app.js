const pairSection = document.querySelector("#pair");
const controlsSection = document.querySelector("#controls");
const pairForm = document.querySelector("#pairForm");
const pairCode = document.querySelector("#pairCode");
const state = document.querySelector("#state");
const touchpad = document.querySelector("#touchpad");
const padHint = document.querySelector("#padHint");
const textInput = document.querySelector("#textInput");
const speedInput = document.querySelector("#speed");
const speedValue = document.querySelector("#speedValue");
const naturalScrollInput = document.querySelector("#naturalScroll");
const defaultLandscapeInput = document.querySelector("#defaultLandscape");
const dragLockEnabledInput = document.querySelector("#dragLockEnabled");
const hapticsInput = document.querySelector("#haptics");
const resetPairButton = document.querySelector("#resetPair");
const resetPairSettingsButton = document.querySelector("#resetPairSettings");
const fullscreenButton = document.querySelector("#fullscreen");
const quickToggle = document.querySelector("#quickToggle");
const quickPanel = document.querySelector("#quickPanel");
const quickBackdrop = document.querySelector("#quickBackdrop");
const quickClose = document.querySelector("#quickClose");
const speedQuick = document.querySelector("#speedQuick");
const speedQuickValue = document.querySelector("#speedQuickValue");
const defaultLandscapeQuick = document.querySelector("#defaultLandscapeQuick");
const dragLockQuick = document.querySelector("#dragLockQuick");
const fullscreenQuick = document.querySelector("#fullscreenQuick");
const rotateHint = document.querySelector("#rotateHint");

const SPEED_MIN = 0.3;
const SPEED_MAX = 4;
const APP_VERSION = "v37";
const TAP_MAX_MS = 420;
const TWO_FINGER_TAP_MAX_MS = 320;
const DRAG_HOLD_MS = 520;
const TAP_MAX_DISTANCE = 14;
const EDGE_SWIPE_ZONE = 54;
const EDGE_SWIPE_DISTANCE = 34;
const DESKTOP_SWIPE_DISTANCE = 22;
const DESKTOP_PINCH_DISTANCE = 16;

let token = localStorage.getItem("mac-console-token") || "";
let rememberToken = localStorage.getItem("mac-console-remember-token") || "";
let ws = null;
let reconnectTimer = null;
let heartbeatTimer = null;
let heartbeatBusy = false;
let heartbeatFailures = 0;
let reconnectAttempts = 0;
let wsGeneration = 0;
let lastSent = 0;
let lastDragSent = 0;
let lastSystemGestureAt = 0;
let pendingMove = { dx: 0, dy: 0 };
let gesture = null;
let pointerGesture = null;
let lastTap = { at: 0, x: 0, y: 0 };
let dragLock = { active: false };
let immersiveFullscreen = false;
let settings = {
  speed: clampSpeed(Number(localStorage.getItem("mac-console-speed") || 1.25)),
  naturalScroll: localStorage.getItem("mac-console-natural-scroll") !== "false",
  defaultLandscape: localStorage.getItem("mac-console-default-landscape") === "true",
  dragLockEnabled: localStorage.getItem("mac-console-drag-lock") === "true",
  haptics: localStorage.getItem("mac-console-haptics") !== "false"
};

if (token || rememberToken) {
  showControls("正在恢复连接");
  restoreSession().then((result) => {
    if (result === "unauthorized") resetPairing("连接过期，请重新配对");
    else resumeConnection("正在恢复连接");
  });
}
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register(`/sw.js?${APP_VERSION}`).catch(() => {});
}
syncSettingsUi();
applyOrientationPreference();
window.addEventListener("orientationchange", applyOrientationPreference);
window.addEventListener("resize", () => {
  applyOrientationPreference();
  if (immersiveFullscreen) keepBrowserChromeHidden();
});
document.addEventListener("fullscreenchange", syncFullscreenUi);
document.addEventListener("webkitfullscreenchange", syncFullscreenUi);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    applyOrientationPreference();
    if (immersiveFullscreen) keepBrowserChromeHidden();
    if (token) resumeConnection("正在恢复连接");
  }
});
window.addEventListener("online", () => {
  if (token) resumeConnection("正在重连");
});
window.addEventListener("offline", () => softDisconnect("网络暂停，解锁后自动重连"));
window.addEventListener("pageshow", () => {
  if (token) resumeConnection("正在恢复连接");
});
window.addEventListener("pagehide", () => {
  releaseDragLock({ message: "", vibrate: false });
  softDisconnect("已暂停，返回后自动重连", { keepSocket: true });
});

pairForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const response = await fetch("/api/pair", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code: pairCode.value.trim() })
  });
  if (!response.ok) {
    pairCode.value = "";
    pairCode.placeholder = "配对码不对";
    return;
  }
  const data = await response.json();
  token = data.token;
  rememberToken = data.rememberToken || rememberToken;
  localStorage.setItem("mac-console-token", token);
  if (rememberToken) localStorage.setItem("mac-console-remember-token", rememberToken);
  reconnectAttempts = 0;
  heartbeatFailures = 0;
  showControls();
});

document.querySelectorAll(".tabs button").forEach((button) => {
  button.addEventListener("click", () => activateTab(button.dataset.tab));
});

document.querySelectorAll("[data-click]").forEach((button) => {
  button.addEventListener("click", () => send({ type: "click", button: button.dataset.click }));
});

document.querySelectorAll("[data-scroll]").forEach((button) => {
  button.addEventListener("click", () => send({ type: "scroll", dy: Number(button.dataset.scroll) }));
});

document.querySelectorAll("[data-key]").forEach((button) => {
  button.addEventListener("click", () => send({ type: "key", key: button.dataset.key }));
});

document.querySelectorAll("[data-shortcut]").forEach((button) => {
  button.addEventListener("click", () => send({ type: "shortcut", combo: button.dataset.shortcut }));
});

document.querySelectorAll("[data-action]").forEach((button) => {
  button.addEventListener("click", () => send({ type: button.dataset.action }));
});

quickToggle.addEventListener("click", (event) => {
  event.stopPropagation();
  setQuickPanelOpen(quickPanel.classList.contains("hidden"));
});

quickToggle.addEventListener("touchstart", (event) => {
  event.preventDefault();
  event.stopPropagation();
  setQuickPanelOpen(quickPanel.classList.contains("hidden"));
}, { passive: false });

quickClose.addEventListener("click", (event) => {
  event.preventDefault();
  event.stopPropagation();
  setQuickPanelOpen(false);
});

quickClose.addEventListener("touchstart", (event) => {
  event.preventDefault();
  event.stopPropagation();
  setQuickPanelOpen(false);
}, { passive: false });

quickPanel.addEventListener("click", (event) => {
  event.stopPropagation();
  const button = event.target.closest("button");
  if (!button) return;
  if (button === quickClose) return;
  if (button.dataset.tab) activateTab(button.dataset.tab);
  setQuickPanelOpen(false);
});

quickPanel.addEventListener("pointerdown", (event) => {
  event.stopPropagation();
});

quickPanel.addEventListener("touchstart", (event) => {
  event.stopPropagation();
}, { passive: true });

quickBackdrop.addEventListener("pointerdown", () => setQuickPanelOpen(false));
quickBackdrop.addEventListener("click", () => setQuickPanelOpen(false));
quickBackdrop.addEventListener("touchstart", (event) => {
  event.preventDefault();
  setQuickPanelOpen(false);
}, { passive: false });

document.addEventListener("pointerdown", (event) => {
  if (quickPanel.classList.contains("hidden")) return;
  if (quickPanel.contains(event.target) || quickToggle.contains(event.target)) return;
  setQuickPanelOpen(false);
}, true);

document.addEventListener("touchstart", (event) => {
  if (quickPanel.classList.contains("hidden")) return;
  if (quickPanel.contains(event.target) || quickToggle.contains(event.target)) return;
  setQuickPanelOpen(false);
}, { capture: true, passive: true });

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") setQuickPanelOpen(false);
});

document.querySelector("#sendText").addEventListener("click", () => {
  if (!textInput.value) return;
  send({ type: "text", value: textInput.value });
  textInput.value = "";
});

document.querySelector("#wake").addEventListener("click", wakeMac);
bindFullscreenButton(fullscreenButton);
bindFullscreenButton(fullscreenQuick);

function wakeMac() {
  send({ type: "move", dx: 1, dy: 0 });
  setTimeout(() => send({ type: "move", dx: -1, dy: 0 }), 60);
}

resetPairButton.addEventListener("click", resetPairing);
resetPairSettingsButton.addEventListener("click", resetPairing);
speedInput.addEventListener("input", () => {
  setSpeed(Number(speedInput.value));
});

speedQuick.addEventListener("input", () => {
  setSpeed(Number(speedQuick.value));
});

naturalScrollInput.addEventListener("change", () => {
  setNaturalScroll(naturalScrollInput.checked);
});

defaultLandscapeInput.addEventListener("change", () => {
  setDefaultLandscape(defaultLandscapeInput.checked);
});

defaultLandscapeQuick.addEventListener("change", () => {
  setDefaultLandscape(defaultLandscapeQuick.checked);
});

bindDragLockToggle(dragLockEnabledInput);
bindDragLockToggle(dragLockQuick);

hapticsInput.addEventListener("change", () => {
  settings.haptics = hapticsInput.checked;
  localStorage.setItem("mac-console-haptics", String(settings.haptics));
});

touchpad.addEventListener("touchstart", (event) => {
  event.preventDefault();
  setQuickPanelOpen(false);
  touchpad.classList.add("active");
  if (dragLock.active && event.touches.length === 1) {
    cancelDragTimer();
    gesture = makeGesture(event.touches);
    gesture.mode = "drag-lock";
    gesture.lockOrigin = "continued";
    touchpad.classList.add("dragging");
    padHint.textContent = "拖拽锁定";
    return;
  }
  if (dragLock.active && event.touches.length > 1) {
    releaseDragLock({ message: "已释放" });
  }
  if (!gesture || event.touches.length >= 3 || gesture.count !== event.touches.length) {
    releaseDragLock({ message: "", vibrate: false });
    cancelDragTimer();
    gesture = makeGesture(event.touches);
  }
  gesture.maxCount = Math.max(gesture.maxCount, event.touches.length);
  if (gesture.count === 1 && event.touches.length === 1) armDragTimer();
  else cancelDragTimer();
  updatePadHint(event.touches.length);
}, { passive: false });

touchpad.addEventListener("touchmove", (event) => {
  event.preventDefault();
  if (gesture && gesture.endedAfterMultiTouch) {
    updatePadHint(event.touches.length);
    return;
  }
  if (!gesture || gesture.count !== event.touches.length) {
    gesture = makeGesture(event.touches);
    updatePadHint(event.touches.length);
    return;
  }
  handleGestureMove(event.touches);
}, { passive: false });

touchpad.addEventListener("touchend", (event) => {
  event.preventDefault();
  const now = Date.now();
  if (gesture && event.touches.length === 0) {
    cancelDragTimer();
    if (gesture.mode === "drag-lock") {
      if (gesture.lockOrigin === "continued" && now - gesture.startedAt < TAP_MAX_MS && gesture.totalDistance < TAP_MAX_DISTANCE) {
        releaseDragLock({ message: "已释放" });
      } else {
        touchpad.classList.remove("active");
        touchpad.classList.add("dragging");
        padHint.textContent = "拖拽锁定，轻点释放";
        haptic(6);
      }
    } else if (gesture.mode === "drag") {
      send({ type: "mouseUp", button: "left" });
      touchpad.classList.remove("dragging");
      haptic(8);
    } else if (gesture.maxCount === 1 && gesture.count === 1 && now - gesture.startedAt < TAP_MAX_MS && gesture.totalDistance < TAP_MAX_DISTANCE) {
      send({ type: "click", button: "left" });
      if (now - lastTap.at < 320 && distanceBetween(gesture.startCenter, lastTap) < 24) {
        flashHint("双击");
        haptic(12);
      } else {
        haptic(8);
      }
      lastTap = { at: now, x: gesture.startCenter.x, y: gesture.startCenter.y };
    } else if (gesture.maxCount === 2 && gesture.count === 2 && !gesture.mode && now - gesture.startedAt < TWO_FINGER_TAP_MAX_MS && gesture.totalDistance < TAP_MAX_DISTANCE) {
      send({ type: "click", button: "right" });
      haptic(10);
    }
    touchpad.classList.remove("active");
    if (!dragLock.active) padHint.textContent = "一指移动";
    gesture = null;
  } else if (event.touches.length > 0) {
    cancelDragTimer();
    if (gesture) {
      gesture.endedAfterMultiTouch = true;
      gesture.maxCount = Math.max(gesture.maxCount, event.touches.length);
    }
    updatePadHint(event.touches.length);
  }
}, { passive: false });

touchpad.addEventListener("touchcancel", () => {
  cancelDragTimer();
  releaseDragLock({ message: "", vibrate: false });
  touchpad.classList.remove("active");
  padHint.textContent = "一指移动";
  gesture = null;
});

touchpad.addEventListener("pointerdown", (event) => {
  if (event.pointerType === "touch") return;
  event.preventDefault();
  touchpad.setPointerCapture(event.pointerId);
  touchpad.classList.add("active");
  pointerGesture = {
    pointerId: event.pointerId,
    startedAt: Date.now(),
    last: { x: event.clientX, y: event.clientY },
    start: { x: event.clientX, y: event.clientY },
    totalDistance: 0
  };
  padHint.textContent = "本机指针";
});

touchpad.addEventListener("pointermove", (event) => {
  if (!pointerGesture || event.pointerId !== pointerGesture.pointerId || event.pointerType === "touch") return;
  event.preventDefault();
  const dx = event.clientX - pointerGesture.last.x;
  const dy = event.clientY - pointerGesture.last.y;
  pointerGesture.totalDistance += Math.hypot(dx, dy);
  pointerGesture.last = { x: event.clientX, y: event.clientY };
  queueMove(dx * settings.speed, dy * settings.speed);
});

touchpad.addEventListener("pointerup", (event) => {
  if (!pointerGesture || event.pointerId !== pointerGesture.pointerId || event.pointerType === "touch") return;
  event.preventDefault();
  const now = Date.now();
  if (now - pointerGesture.startedAt < TAP_MAX_MS && pointerGesture.totalDistance < TAP_MAX_DISTANCE) {
    send({ type: "click", button: "left" });
    haptic(8);
  }
  pointerGesture = null;
  touchpad.classList.remove("active");
  padHint.textContent = "一指移动";
});

touchpad.addEventListener("pointercancel", (event) => {
  if (!pointerGesture || event.pointerId !== pointerGesture.pointerId) return;
  pointerGesture = null;
  touchpad.classList.remove("active");
  padHint.textContent = "一指移动";
});

function showControls(message = "连接中") {
  pairSection.classList.add("hidden");
  controlsSection.classList.remove("hidden");
  state.textContent = message;
  applyOrientationPreference();
  connectWs();
  startHeartbeat();
}

function connectWs() {
  if (!token) return;
  if (document.hidden || navigator.onLine === false) {
    scheduleReconnect("等待手机恢复网络");
    return;
  }
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    ws.close();
  }
  window.clearTimeout(reconnectTimer);
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const generation = ++wsGeneration;
  ws = new WebSocket(`${protocol}//${location.host}/ws?token=${encodeURIComponent(token)}`);
  ws.addEventListener("open", () => {
    if (generation !== wsGeneration) return;
    reconnectAttempts = 0;
    heartbeatFailures = 0;
    state.textContent = "已连接";
  });
  ws.addEventListener("close", () => {
    if (!token || generation !== wsGeneration) return;
    scheduleReconnect("连接暂停，正在重连");
  });
  ws.addEventListener("error", () => {
    if (!token || generation !== wsGeneration) return;
    scheduleReconnect("连接暂停，正在重连");
  });
}

function resumeConnection(message = "正在重连") {
  if (!token && !rememberToken) return;
  pairSection.classList.add("hidden");
  controlsSection.classList.remove("hidden");
  state.textContent = message;
  applyOrientationPreference();
  startHeartbeat();
  restoreSession().then((result) => {
    if (!token && !rememberToken) return;
    if (result === "unauthorized") {
      resetPairing("连接过期，请重新配对");
      return;
    }
    connectWs();
  });
}

function softDisconnect(message = "连接暂停，正在重连", options = {}) {
  if (!token && !rememberToken) return;
  state.textContent = message;
  heartbeatBusy = false;
  if (!options.keepSocket && ws) {
    wsGeneration += 1;
    ws.close();
    ws = null;
  }
  window.clearTimeout(reconnectTimer);
}

function scheduleReconnect(message = "正在重连") {
  if (!token && !rememberToken) return;
  state.textContent = message;
  if (document.hidden || navigator.onLine === false) return;
  window.clearTimeout(reconnectTimer);
  const delay = Math.min(8000, 450 + reconnectAttempts * 650);
  reconnectAttempts += 1;
  reconnectTimer = window.setTimeout(() => {
    if (!token && !rememberToken) return;
    resumeConnection(message);
  }, delay);
}

function queueMove(dx, dy) {
  pendingMove.dx += dx;
  pendingMove.dy += dy;
  const now = performance.now();
  if (now - lastSent < 8) return;
  lastSent = now;
  const payload = {
    type: "move",
    dx: Math.round(pendingMove.dx),
    dy: Math.round(pendingMove.dy)
  };
  pendingMove = { dx: 0, dy: 0 };
  if (payload.dx || payload.dy) send(payload);
}

function sendDrag(dx, dy) {
  pendingMove.dx += dx;
  pendingMove.dy += dy;
  const now = performance.now();
  if (now - lastDragSent < 3) return;
  lastDragSent = now;
  const payload = {
    type: "drag",
    dx: Math.round(pendingMove.dx),
    dy: Math.round(pendingMove.dy)
  };
  pendingMove = { dx: 0, dy: 0 };
  if (payload.dx || payload.dy) send(payload);
}

function send(payload) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(payload));
    return;
  }
  if (payload.type === "move" || payload.type === "scroll" || payload.type === "drag") return;
  fetch("/api/action", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${token}`
    },
    body: JSON.stringify(payload)
  }).then((response) => {
    if (response && response.status === 401) {
      resumeTrustedSession().then((result) => {
        if (result === "ok") send(payload);
        else if (result === "unauthorized") resetPairing("连接过期，请重新配对");
        else scheduleReconnect("连接暂停，正在重连");
      });
    }
    else if (response && response.status === 403) state.textContent = "Mac 需要辅助功能权限";
    else if (response && response.ok) heartbeatFailures = 0;
  }).catch(() => scheduleReconnect("连接暂停，正在重连"));
}

async function restoreSession() {
  if (token) {
    const result = await validateSession();
    if (result === "ok" || result === "offline") return result;
  }
  return resumeTrustedSession();
}

async function resumeTrustedSession() {
  if (!rememberToken) return "unauthorized";
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 2500);
  try {
    const response = await fetch("/api/resume", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ rememberToken }),
      cache: "no-store",
      signal: controller.signal
    });
    if (!response.ok) return response.status === 401 || response.status === 403 ? "unauthorized" : "offline";
    const data = await response.json();
    token = data.token;
    localStorage.setItem("mac-console-token", token);
    return "ok";
  } catch {
    return "offline";
  } finally {
    window.clearTimeout(timeout);
  }
}

async function validateSession() {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 2500);
  try {
    const response = await fetch("/api/session", {
      headers: { authorization: `Bearer ${token}` },
      cache: "no-store",
      signal: controller.signal
    });
    if (response.ok) return "ok";
    if (response.status === 401 || response.status === 403) return "unauthorized";
    return "offline";
  } catch {
    return "offline";
  } finally {
    window.clearTimeout(timeout);
  }
}

function resetPairing(message = "配对码") {
  releaseDragLock({ message: "", vibrate: false });
  token = "";
  rememberToken = "";
  reconnectAttempts = 0;
  heartbeatFailures = 0;
  heartbeatBusy = false;
  wsGeneration += 1;
  window.clearTimeout(reconnectTimer);
  window.clearInterval(heartbeatTimer);
  heartbeatTimer = null;
  if (ws) ws.close();
  ws = null;
  localStorage.removeItem("mac-console-token");
  localStorage.removeItem("mac-console-remember-token");
  controlsSection.classList.add("hidden");
  pairSection.classList.remove("hidden");
  applyOrientationPreference();
  pairCode.value = "";
  pairCode.placeholder = message;
  pairCode.focus();
}

function bindFullscreenButton(button) {
  if (!button) return;
  let lastTouchAt = 0;
  const request = (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (event.type === "click" && Date.now() - lastTouchAt < 650) return;
    if (event.type === "touchend") lastTouchAt = Date.now();
    toggleFullscreenMode();
  };
  button.addEventListener("click", request);
  button.addEventListener("touchend", request, { passive: false });
}

async function toggleFullscreenMode() {
  if (isNativeFullscreen() || immersiveFullscreen) {
    await exitFullscreenMode();
    return;
  }
  await enterFullscreenMode();
}

async function enterFullscreenMode() {
  setQuickPanelOpen(false);
  immersiveFullscreen = true;
  document.documentElement.classList.add("immersive");
  syncFullscreenUi();
  keepBrowserChromeHidden();

  const target = document.documentElement;
  const requestFullscreen = target.requestFullscreen ||
    target.webkitRequestFullscreen ||
    target.msRequestFullscreen;
  if (requestFullscreen) {
    try {
      await requestFullscreen.call(target);
    } catch {}
  }

  if (settings.defaultLandscape) applyOrientationPreference();
  keepBrowserChromeHidden();
  flashHint(isNativeFullscreen() ? "全屏" : "沉浸模式");
}

async function exitFullscreenMode() {
  immersiveFullscreen = false;
  document.documentElement.classList.remove("immersive");
  document.body.style.minHeight = "";

  const exitFullscreen = document.exitFullscreen ||
    document.webkitExitFullscreen ||
    document.msExitFullscreen;
  if (isNativeFullscreen() && exitFullscreen) {
    try {
      await exitFullscreen.call(document);
    } catch {}
  }

  syncFullscreenUi();
  flashHint("已退出全屏");
}

function isNativeFullscreen() {
  return Boolean(document.fullscreenElement || document.webkitFullscreenElement || document.msFullscreenElement);
}

function syncFullscreenUi() {
  const active = isNativeFullscreen() || immersiveFullscreen;
  document.documentElement.classList.toggle("immersive", active);
  [fullscreenButton, fullscreenQuick].forEach((button) => {
    if (!button) return;
    button.textContent = active ? "退出全屏" : "全屏";
    button.classList.toggle("active", active);
  });
  if (active) keepBrowserChromeHidden();
}

function keepBrowserChromeHidden() {
  document.body.style.minHeight = `${Math.max(window.innerHeight, screen.height || window.innerHeight) + 2}px`;
  window.setTimeout(() => window.scrollTo(0, 1), 0);
  window.setTimeout(() => window.scrollTo(0, 1), 180);
}

function startHeartbeat() {
  window.clearInterval(heartbeatTimer);
  heartbeatTimer = window.setInterval(async () => {
    if ((!token && !rememberToken) || heartbeatBusy) return;
    if (document.hidden || navigator.onLine === false) return;
    heartbeatBusy = true;
    const result = await restoreSession();
    heartbeatBusy = false;
    if (result === "ok") {
      heartbeatFailures = 0;
      if (!ws || ws.readyState === WebSocket.CLOSED) scheduleReconnect("正在重连");
      return;
    }
    if (result === "unauthorized") {
      resetPairing("连接过期，请重新配对");
      return;
    }
    heartbeatFailures += 1;
    if (heartbeatFailures >= 3) scheduleReconnect("连接暂停，正在重连");
  }, 3500);
}

function makeGesture(touches) {
  const points = getPoints(touches);
  const center = getCenter(points);
  return {
    count: touches.length,
    maxCount: touches.length,
    startedAt: Date.now(),
    startCenter: center,
    lastCenter: center,
    startDistance: getAverageDistance(points, center),
    lastDistance: getAverageDistance(points, center),
    totalDistance: 0,
    cumulativeDx: 0,
    cumulativeDy: 0,
    mode: "",
    endedAfterMultiTouch: false,
    lastPinchAt: 0,
    dragTimer: null,
    fired: false
  };
}

function handleGestureMove(touches) {
  const points = getPoints(touches);
  const center = getCenter(points);
  const dx = center.x - gesture.lastCenter.x;
  const dy = center.y - gesture.lastCenter.y;
  const totalDx = center.x - gesture.startCenter.x;
  const totalDy = center.y - gesture.startCenter.y;
  gesture.totalDistance += Math.hypot(dx, dy);
  gesture.cumulativeDx += dx;
  gesture.cumulativeDy += dy;
  gesture.lastCenter = center;

  if (gesture.count === 1) {
    if (gesture.mode === "drag-lock" || gesture.mode === "drag") {
      sendDrag(dx * settings.speed, dy * settings.speed);
      return;
    }
    if (gesture.totalDistance > TAP_MAX_DISTANCE) cancelDragTimer();
    queueMove(dx * settings.speed, dy * settings.speed);
    return;
  }

  if (gesture.count === 2) {
    const distance = getAverageDistance(points, center);
    const pinchDelta = distance - gesture.lastDistance;
    gesture.lastDistance = distance;
    const now = performance.now();

    if (!gesture.mode) {
      const horizontalIntent = Math.abs(gesture.cumulativeDx);
      const verticalIntent = Math.abs(gesture.cumulativeDy);
      if (isRightEdgeSwipe(gesture)) {
        gesture.mode = "notification";
        gesture.fired = true;
        fireSystemGesture({ type: "notification" }, "通知中心");
        return;
      }
      if (horizontalIntent > 34 && horizontalIntent > verticalIntent * 1.35) {
        gesture.mode = "page";
        gesture.fired = true;
        send({ type: "shortcut", combo: gesture.cumulativeDx > 0 ? "cmd+[" : "cmd+]" });
        flashHint(gesture.cumulativeDx > 0 ? "返回" : "前进");
        haptic(14);
        return;
      }
      const scrollIntent = verticalIntent + horizontalIntent * 0.35;
      const pinchIntent = Math.abs(distance - gesture.startDistance);
      if (pinchIntent > 9 && pinchIntent > scrollIntent * 0.65) {
        gesture.mode = "pinch";
        haptic(5);
      } else if (scrollIntent > 8) {
        gesture.mode = "scroll";
      } else {
        return;
      }
    }

    if (gesture.mode === "pinch") {
      if (now - gesture.lastPinchAt < 190 || Math.abs(pinchDelta) < 2.4) return;
      gesture.lastPinchAt = now;
      send({ type: "shortcut", combo: pinchDelta > 0 ? "cmd+=" : "cmd+-" });
      haptic(6);
      return;
    }

    if (gesture.mode === "page") return;

    const direction = settings.naturalScroll ? -1 : 1;
    send({ type: "scroll", dy: Math.round(dy * direction * 2.8) });
    return;
  }

  if (gesture.count >= 3 && !gesture.fired) {
    const gestureDx = Math.abs(gesture.cumulativeDx) > Math.abs(totalDx) ? gesture.cumulativeDx : totalDx;
    const gestureDy = Math.abs(gesture.cumulativeDy) > Math.abs(totalDy) ? gesture.cumulativeDy : totalDy;
    const absX = Math.abs(gestureDx);
    const absY = Math.abs(gestureDy);
    if (gesture.count >= 4) {
      const distance = getAverageDistance(points, center);
      const pinchDistance = distance - gesture.startDistance;
      const absPinch = Math.abs(pinchDistance);
      const travel = Math.hypot(gesture.cumulativeDx, gesture.cumulativeDy);
      if (absPinch > DESKTOP_PINCH_DISTANCE && absPinch > travel * 0.42) {
        fireSystemGesture({ type: pinchDistance > 0 ? "showDesktop" : "restoreDesktop" }, pinchDistance > 0 ? "显示桌面" : "恢复桌面");
        return;
      }
    }

    if (absX > DESKTOP_SWIPE_DISTANCE && absX > absY * 1.15) {
      fireSystemGesture({ type: "shortcut", combo: gestureDx < 0 ? "ctrl+right" : "ctrl+left" }, gestureDx < 0 ? "右桌面" : "左桌面");
      return;
    }

    if (gestureDy < -7 && absY >= Math.max(5, absX * 0.22)) {
      fireSystemGesture({ type: "mission" }, "调度中心");
      return;
    }

    if (Math.max(absX, absY) < 18) return;
    if (absY >= absX * 0.5 && gestureDy < 0) {
      fireSystemGesture({ type: "mission" }, "调度中心");
    } else if (absY >= absX * 0.6 && gestureDy > 0) {
      fireSystemGesture({ type: "shortcut", combo: "ctrl+down" }, "App Expose");
    } else if (gestureDx < 0) {
      fireSystemGesture({ type: "shortcut", combo: "ctrl+right" }, "右桌面");
    } else {
      fireSystemGesture({ type: "shortcut", combo: "ctrl+left" }, "左桌面");
    }
  }
}

function fireSystemGesture(payload, hint) {
  const now = performance.now();
  gesture.fired = true;
  if (now - lastSystemGestureAt < 360) return;
  lastSystemGestureAt = now;
  send(payload);
  flashHint(hint);
  haptic(18);
}

function armDragTimer() {
  cancelDragTimer();
  gesture.dragTimer = window.setTimeout(() => {
    if (!gesture || gesture.count !== 1 || gesture.maxCount !== 1 || gesture.totalDistance > TAP_MAX_DISTANCE || gesture.endedAfterMultiTouch) return;
    pendingMove = { dx: 0, dy: 0 };
    gesture.mode = settings.dragLockEnabled ? "drag-lock" : "drag";
    gesture.lockOrigin = "initial";
    dragLock.active = settings.dragLockEnabled;
    touchpad.classList.add("dragging");
    send({ type: "mouseDown", button: "left" });
    flashHint(settings.dragLockEnabled ? "拖拽锁定" : "拖拽");
    haptic(14);
  }, DRAG_HOLD_MS);
}

function cancelDragTimer() {
  if (!gesture || !gesture.dragTimer) return;
  window.clearTimeout(gesture.dragTimer);
  gesture.dragTimer = null;
}

function releaseDragLock(options = {}) {
  if (!dragLock.active) return;
  send({ type: "mouseUp", button: "left" });
  dragLock.active = false;
  touchpad.classList.remove("dragging");
  if (gesture && gesture.mode === "drag-lock") gesture.mode = "drag-ended";
  if (options.message !== "") padHint.textContent = options.message || "一指移动";
  if (options.vibrate !== false) haptic(8);
}

function getPoints(touches) {
  return Array.from(touches, (touch) => ({ x: touch.clientX, y: touch.clientY }));
}

function getCenter(points) {
  const sum = points.reduce((acc, point) => ({ x: acc.x + point.x, y: acc.y + point.y }), { x: 0, y: 0 });
  return { x: sum.x / points.length, y: sum.y / points.length };
}

function getAverageDistance(points, center) {
  if (points.length < 2) return 0;
  const total = points.reduce((sum, point) => sum + Math.hypot(point.x - center.x, point.y - center.y), 0);
  return total / points.length;
}

function distanceBetween(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function isRightEdgeSwipe(activeGesture) {
  const rect = touchpad.getBoundingClientRect();
  const startedAtRightEdge = activeGesture.startCenter.x >= rect.right - EDGE_SWIPE_ZONE;
  const horizontalIntent = Math.abs(activeGesture.cumulativeDx);
  const verticalIntent = Math.abs(activeGesture.cumulativeDy);
  return startedAtRightEdge &&
    activeGesture.cumulativeDx < -EDGE_SWIPE_DISTANCE &&
    horizontalIntent > verticalIntent * 1.35;
}

function updatePadHint(count) {
  if (dragLock.active) padHint.textContent = "拖拽锁定，轻点释放";
  else if (count === 1) padHint.textContent = settings.dragLockEnabled ? "一指移动/长按锁定拖拽" : "一指移动/长按拖拽";
  else if (count === 2) padHint.textContent = "两指滚动/缩放/边缘通知";
  else if (count === 3) padHint.textContent = "三指上滑调度中心";
  else padHint.textContent = "四指切换/张开桌面";
}

function flashHint(text) {
  padHint.textContent = text;
  setTimeout(() => {
    if (gesture) updatePadHint(gesture.count);
  }, 700);
}

function syncSettingsUi() {
  const speedLabel = formatSpeed(settings.speed);
  speedInput.value = String(settings.speed);
  speedQuick.value = String(settings.speed);
  speedValue.textContent = speedLabel;
  speedQuickValue.textContent = speedLabel;
  naturalScrollInput.checked = settings.naturalScroll;
  defaultLandscapeInput.checked = settings.defaultLandscape;
  defaultLandscapeQuick.checked = settings.defaultLandscape;
  dragLockEnabledInput.checked = settings.dragLockEnabled;
  dragLockQuick.checked = settings.dragLockEnabled;
  hapticsInput.checked = settings.haptics;
}

function setSpeed(value) {
  settings.speed = clampSpeed(value);
  localStorage.setItem("mac-console-speed", String(settings.speed));
  syncSettingsUi();
}

function clampSpeed(value) {
  if (!Number.isFinite(value)) return 1.25;
  return Math.min(SPEED_MAX, Math.max(SPEED_MIN, Math.round(value * 20) / 20));
}

function formatSpeed(value) {
  return `${value.toFixed(2).replace(/0$/, "").replace(/\.0$/, "")}x`;
}

function setNaturalScroll(value) {
  settings.naturalScroll = value;
  naturalScrollInput.checked = value;
  localStorage.setItem("mac-console-natural-scroll", String(value));
}

function setDefaultLandscape(value) {
  settings.defaultLandscape = value;
  defaultLandscapeInput.checked = value;
  defaultLandscapeQuick.checked = value;
  localStorage.setItem("mac-console-default-landscape", String(value));
  applyOrientationPreference();
}

function setDragLockEnabled(value) {
  settings.dragLockEnabled = value;
  dragLockEnabledInput.checked = value;
  dragLockQuick.checked = value;
  localStorage.setItem("mac-console-drag-lock", String(value));
  if (!value) releaseDragLock({ message: "拖拽锁定已关闭" });
}

function bindDragLockToggle(input) {
  const sync = () => setDragLockEnabled(input.checked);
  const syncAfterNativeToggle = () => window.setTimeout(sync, 0);
  input.addEventListener("change", sync);
  input.addEventListener("input", sync);
  input.addEventListener("click", syncAfterNativeToggle);
  input.addEventListener("touchend", syncAfterNativeToggle, { passive: true });
}

async function applyOrientationPreference() {
  const isPortrait = window.matchMedia("(orientation: portrait)").matches;
  rotateHint.classList.toggle("hidden", !settings.defaultLandscape || !isPortrait || controlsSection.classList.contains("hidden"));
  document.body.classList.toggle("prefer-landscape", settings.defaultLandscape);

  if (!settings.defaultLandscape) {
    if (screen.orientation && screen.orientation.unlock) {
      try {
        screen.orientation.unlock();
      } catch {}
    }
    return;
  }

  if (!screen.orientation || !screen.orientation.lock) return;
  try {
    await screen.orientation.lock("landscape");
  } catch {}
}

function haptic(duration) {
  if (settings.haptics && navigator.vibrate) {
    navigator.vibrate(duration);
  }
}

function activateTab(tabName) {
  document.querySelectorAll("[data-tab]").forEach((item) => item.classList.toggle("active", item.dataset.tab === tabName));
  document.querySelectorAll(".tab").forEach((item) => item.classList.remove("active"));
  document.querySelector(`#${tabName}`).classList.add("active");
}

function setQuickPanelOpen(open) {
  quickPanel.classList.toggle("hidden", !open);
  quickBackdrop.classList.toggle("hidden", !open);
  quickToggle.classList.toggle("open", open);
  quickToggle.setAttribute("aria-expanded", String(open));
  quickToggle.textContent = open ? "×" : "...";
}

document.addEventListener("contextmenu", (event) => {
  event.preventDefault();
});
