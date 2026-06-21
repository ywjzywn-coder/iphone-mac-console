import http from "node:http";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const base = "http://localhost:8787";
const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const viewports = [
  { name: "iphone-se", width: 375, height: 667 },
  { name: "iphone-plus", width: 414, height: 736 },
  { name: "tall-phone", width: 390, height: 844 },
  { name: "android-small", width: 360, height: 760 },
  { name: "landscape-small", width: 667, height: 375 },
  { name: "landscape-wide", width: 844, height: 390 }
];

function request(url, options = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(url, options, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => body += chunk);
      res.on("end", () => resolve({ statusCode: res.statusCode, body }));
    });
    req.on("error", reject);
    if (options.body) req.write(options.body);
    req.end();
  });
}

async function pair(code) {
  const response = await request(`${base}/api/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code })
  });
  if (response.statusCode !== 200) {
    throw new Error(`Pairing failed with status ${response.statusCode}`);
  }
  return JSON.parse(response.body).token;
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function getVersion(port) {
  for (let i = 0; i < 40; i += 1) {
    try {
      const response = await request(`http://127.0.0.1:${port}/json/version`);
      if (response.statusCode === 200) return JSON.parse(response.body);
    } catch {}
    await wait(100);
  }
  throw new Error(`Chrome DevTools did not start on port ${port}`);
}

async function getPage(port) {
  for (let i = 0; i < 40; i += 1) {
    try {
      const response = await request(`http://127.0.0.1:${port}/json/list`);
      if (response.statusCode === 200) {
        const pages = JSON.parse(response.body);
        const page = pages.find((item) => item.type === "page");
        if (page) return page;
      }
    } catch {}
    await wait(100);
  }
  throw new Error(`Chrome page target did not start on port ${port}`);
}

function connect(url) {
  const ws = new WebSocket(url);
  let id = 0;
  const pending = new Map();
  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result);
    }
  });
  return new Promise((resolve, reject) => {
    ws.addEventListener("open", () => {
      resolve({
        send(method, params = {}) {
          const messageId = ++id;
          ws.send(JSON.stringify({ id: messageId, method, params }));
          return new Promise((res, rej) => pending.set(messageId, { resolve: res, reject: rej }));
        },
        close() {
          ws.close();
        }
      });
    });
    ws.addEventListener("error", reject);
  });
}

async function inspectViewport(token, viewport, index, rootDir) {
  const port = 9310 + index;
  const profile = join(rootDir, viewport.name);
  const chrome = spawn(chromePath, [
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    "--no-first-run",
    "--no-default-browser-check",
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    "about:blank"
  ], { stdio: "ignore" });

  let client;
  try {
    await getVersion(port);
    const page = await getPage(port);
    client = await connect(page.webSocketDebuggerUrl);
    await client.send("Page.enable");
    await client.send("Runtime.enable");
    await client.send("Emulation.setDeviceMetricsOverride", {
      width: viewport.width,
      height: viewport.height,
      deviceScaleFactor: 2,
      mobile: true
    });
    await client.send("Page.navigate", { url: base });
    await wait(350);
    await client.send("Runtime.evaluate", {
      expression: `localStorage.setItem("mac-console-token", ${JSON.stringify(token)}); location.reload();`,
      awaitPromise: false
    });
    await wait(900);
    const result = await client.send("Runtime.evaluate", {
      returnByValue: true,
      expression: `(() => {
        const rect = (selector) => {
          const el = document.querySelector(selector);
          if (!el) return null;
          const r = el.getBoundingClientRect();
          return {
            x: Math.round(r.x), y: Math.round(r.y),
            width: Math.round(r.width), height: Math.round(r.height),
            right: Math.round(r.right), bottom: Math.round(r.bottom),
            display: getComputedStyle(el).display
          };
        };
        return {
          viewport: { width: innerWidth, height: innerHeight },
          document: {
            scrollWidth: document.documentElement.scrollWidth,
            scrollHeight: document.documentElement.scrollHeight
          },
          pair: rect("#pair"),
          controls: rect("#controls"),
          touchpad: rect("#touchpad"),
          quickToggle: rect("#quickToggle"),
          quickPanel: rect("#quickPanel"),
          activePanel: rect(".tab.active:not(#pad)"),
          state: document.querySelector("#state")?.textContent || ""
        };
      })()`
    });
    const value = result.result.value;
    return {
      name: viewport.name,
      viewport,
      value,
      ok: value.pair?.display === "none" &&
        value.touchpad?.width > 250 &&
        value.touchpad?.height > 300 &&
        value.document.scrollWidth <= value.viewport.width + 1 &&
        value.document.scrollHeight <= value.viewport.height + 1
    };
  } finally {
    if (client) client.close();
    chrome.kill("SIGTERM");
  }
}

async function main() {
  const code = process.argv[2];
  if (!code) throw new Error("Usage: node tools/responsive_check.mjs <pair-code>");
  const token = await pair(code);
  const rootDir = mkdtempSync(join(tmpdir(), "mac-console-check-"));
  try {
    const results = [];
    for (let i = 0; i < viewports.length; i += 1) {
      results.push(await inspectViewport(token, viewports[i], i, rootDir));
    }
    console.log(JSON.stringify(results, null, 2));
    if (results.some((result) => !result.ok)) process.exit(1);
  } finally {
    try {
      rmSync(rootDir, { recursive: true, force: true, maxRetries: 3, retryDelay: 150 });
    } catch {}
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
