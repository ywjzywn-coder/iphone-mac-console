const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");
const https = require("https");

const root = __dirname;
const publicDir = path.join(root, "public");
const helperPath = path.join(root, "bin", "mac-control");
const helperSource = path.join(root, "native", "MacControl.swift");
const runtimeDir = path.join(root, ".runtime");
const statusPath = path.join(runtimeDir, "status.json");
const port = Number(process.env.PORT || 8787);
const httpsPort = Number(process.env.HTTPS_PORT || 8788);
const useHttps = process.argv.includes("--https") || process.env.HTTPS === "1";
const pairCode = process.env.PAIR_CODE || String(Math.floor(100000 + Math.random() * 900000));
const sessionToken = crypto.randomBytes(24).toString("hex");
let helperProcess = null;
let lastProtocol = useHttps ? "https" : "http";
let lastListenPort = useHttps ? httpsPort : port;

function ensureHelper() {
  fs.mkdirSync(path.dirname(helperPath), { recursive: true });
  const needsBuild =
    !fs.existsSync(helperPath) ||
    fs.statSync(helperPath).mtimeMs < fs.statSync(helperSource).mtimeMs;

  if (!needsBuild) return;

  console.log("Building mac-control helper...");
  const result = spawnSync("swiftc", [helperSource, "-o", helperPath], {
    stdio: "inherit"
  });
  if (result.status !== 0) {
    throw new Error("Could not build native helper with swiftc.");
  }
}

function contentType(filePath) {
  if (filePath.endsWith(".html")) return "text/html; charset=utf-8";
  if (filePath.endsWith(".css")) return "text/css; charset=utf-8";
  if (filePath.endsWith(".js")) return "application/javascript; charset=utf-8";
  if (filePath.endsWith(".webmanifest")) return "application/manifest+json; charset=utf-8";
  if (filePath.endsWith(".svg")) return "image/svg+xml; charset=utf-8";
  if (filePath.endsWith(".png")) return "image/png";
  if (filePath.endsWith(".json")) return "application/json; charset=utf-8";
  return "application/octet-stream";
}

function localAddresses() {
  const addresses = [];
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (entry.family === "IPv4" && !entry.internal) {
        addresses.push(entry.address);
      }
    }
  }
  return addresses;
}

function phoneURLs(protocol = lastProtocol, listenPort = lastListenPort) {
  return localAddresses().map((address) => `${protocol}://${address}:${listenPort}`);
}

function writeStatus(running, protocol = lastProtocol, listenPort = lastListenPort) {
  fs.mkdirSync(runtimeDir, { recursive: true });
  const payload = {
    running,
    pairCode,
    phoneURLs: phoneURLs(protocol, listenPort),
    updatedAt: new Date().toISOString()
  };
  fs.writeFileSync(statusPath, `${JSON.stringify(payload, null, 2)}\n`);
}

function sendJson(res, status, body) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store"
  });
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > 65536) {
        req.destroy();
        reject(new Error("Request body too large."));
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function ensureCertificate() {
  const certDir = path.join(root, "certs");
  const keyPath = path.join(certDir, "localhost-key.pem");
  const certPath = path.join(certDir, "localhost-cert.pem");
  if (fs.existsSync(keyPath) && fs.existsSync(certPath)) {
    return { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) };
  }
  fs.mkdirSync(certDir, { recursive: true });
  const addresses = ["127.0.0.1", ...localAddresses()];
  const configPath = path.join(certDir, "openssl.cnf");
  const altNames = addresses.map((address, index) => `IP.${index + 1} = ${address}`).join("\n");
  fs.writeFileSync(configPath, [
    "[req]",
    "distinguished_name = dn",
    "x509_extensions = v3_req",
    "prompt = no",
    "[dn]",
    "CN = Mac Console Local",
    "[v3_req]",
    "subjectAltName = @alt_names",
    "[alt_names]",
    altNames
  ].join("\n"));
  const result = spawnSync("openssl", [
    "req",
    "-x509",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-sha256",
    "-days",
    "825",
    "-keyout",
    keyPath,
    "-out",
    certPath,
    "-config",
    configPath
  ], { stdio: "ignore" });
  if (result.status !== 0) {
    throw new Error("Could not generate HTTPS certificate with openssl.");
  }
  return { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) };
}

function startHelper() {
  if (
    helperProcess &&
    helperProcess.exitCode === null &&
    helperProcess.signalCode === null &&
    helperProcess.stdin &&
    helperProcess.stdin.writable &&
    !helperProcess.stdin.destroyed
  ) {
    return helperProcess;
  }
  helperProcess = null;
  helperProcess = spawn(helperPath, ["serve"], {
    stdio: ["pipe", "ignore", "pipe"]
  });
  helperProcess.stderr.on("data", (data) => {
    const text = String(data).trim();
    if (text) console.warn(text);
  });
  helperProcess.on("exit", () => {
    helperProcess = null;
  });
  helperProcess.on("error", (error) => {
    console.warn("mac-control helper error:", error.message);
    helperProcess = null;
  });
  return helperProcess;
}

function runHelper(payload) {
  const child = startHelper();
  if (!child.stdin.writable || child.stdin.destroyed) {
    helperProcess = null;
    const retry = startHelper();
    if (!retry.stdin.writable || retry.stdin.destroyed) return;
    retry.stdin.write(`${JSON.stringify(payload)}\n`);
    return;
  }
  child.stdin.write(`${JSON.stringify(payload)}\n`, (error) => {
    if (error) helperProcess = null;
  });
}

function handleAction(payload) {
  if (!payload || typeof payload !== "object") return;
  const type = payload.type;

  if (type === "move") {
    runHelper({ type, dx: Number(payload.dx || 0), dy: Number(payload.dy || 0) });
  } else if (type === "mouseDown") {
    runHelper({ type, button: payload.button === "right" ? "right" : "left" });
  } else if (type === "mouseUp") {
    runHelper({ type, button: payload.button === "right" ? "right" : "left" });
  } else if (type === "drag") {
    runHelper({ type, dx: Number(payload.dx || 0), dy: Number(payload.dy || 0) });
  } else if (type === "click") {
    runHelper({ type, button: payload.button === "right" ? "right" : "left" });
  } else if (type === "scroll") {
    runHelper({ type, dy: Number(payload.dy || 0) });
  } else if (type === "text") {
    runHelper({ type, value: String(payload.value || "").slice(0, 500) });
  } else if (type === "key") {
    runHelper({ type, key: String(payload.key || "") });
  } else if (type === "shortcut") {
    runHelper({ type, combo: String(payload.combo || "") });
  } else if (type === "mission") {
    runHelper({ type });
  }
}

const requestHandler = async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);

  if (req.method === "POST" && url.pathname === "/api/pair") {
    const body = JSON.parse((await readBody(req)) || "{}");
    if (String(body.code || "") !== pairCode) {
      sendJson(res, 403, { ok: false });
      return;
    }
    sendJson(res, 200, { ok: true, token: sessionToken });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/action") {
    if (req.headers.authorization !== `Bearer ${sessionToken}`) {
      sendJson(res, 401, { ok: false });
      return;
    }
    handleAction(JSON.parse((await readBody(req)) || "{}"));
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/session") {
    const ok = req.headers.authorization === `Bearer ${sessionToken}`;
    sendJson(res, ok ? 200 : 401, { ok });
    return;
  }

  let requestPath = decodeURIComponent(url.pathname);
  if (requestPath === "/") requestPath = "/index.html";
  const filePath = path.normalize(path.join(publicDir, requestPath));

  if (!filePath.startsWith(publicDir) || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("Not found");
    return;
  }

  res.writeHead(200, {
    "content-type": contentType(filePath),
    "cache-control": "no-store"
  });
  fs.createReadStream(filePath).pipe(res);
};

const server = useHttps
  ? https.createServer(ensureCertificate(), requestHandler)
  : http.createServer(requestHandler);

server.on("clientError", (error, socket) => {
  if (error.code !== "ECONNRESET") {
    console.warn("Client connection error:", error.message);
  }
  socket.destroy();
});

server.on("error", (error) => {
  console.error("Server error:", error.message);
  if (error.code === "EADDRINUSE" || error.code === "EACCES") {
    writeStatus(false);
    process.exit(1);
  }
});

server.on("upgrade", (req, socket) => {
  socket.on("error", (error) => {
    if (error.code !== "ECONNRESET") {
      console.warn("Websocket socket error:", error.message);
    }
  });

  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  if (url.pathname !== "/ws" || url.searchParams.get("token") !== sessionToken) {
    socket.destroy();
    return;
  }

  const key = req.headers["sec-websocket-key"];
  const accept = crypto
    .createHash("sha1")
    .update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    .digest("base64");

  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
  );

  socket.on("data", (buffer) => {
    try {
      const messages = decodeWebSocketMessages(buffer);
      for (const message of messages) handleAction(JSON.parse(message));
    } catch (error) {
      console.warn("Bad websocket message:", error.message);
    }
  });
});

function decodeWebSocketMessages(buffer) {
  const messages = [];
  let offset = 0;
  while (offset + 2 <= buffer.length) {
    const first = buffer[offset++];
    const second = buffer[offset++];
    const opcode = first & 0x0f;
    let length = second & 0x7f;
    if (opcode === 8) break;
    if (length === 126) {
      if (offset + 2 > buffer.length) break;
      length = buffer.readUInt16BE(offset);
      offset += 2;
    } else if (length === 127) {
      if (offset + 8 > buffer.length) break;
      length = Number(buffer.readBigUInt64BE(offset));
      offset += 8;
    }
    const masked = Boolean(second & 0x80);
    let mask;
    if (masked) {
      if (offset + 4 > buffer.length) break;
      mask = buffer.subarray(offset, offset + 4);
      offset += 4;
    }
    if (offset + length > buffer.length) break;
    const payload = buffer.subarray(offset, offset + length);
    offset += length;
    if (opcode === 1) {
      if (masked) {
        const unmasked = Buffer.alloc(payload.length);
        for (let i = 0; i < payload.length; i += 1) {
          unmasked[i] = payload[i] ^ mask[i % 4];
        }
        messages.push(unmasked.toString("utf8"));
      } else {
        messages.push(payload.toString("utf8"));
      }
    }
  }
  return messages;
}

function announce(protocol, listenPort) {
  lastProtocol = protocol;
  lastListenPort = listenPort;
  console.log("");
  console.log(`iPhone Mac Console is running over ${protocol.toUpperCase()}.`);
  console.log(`Pair code: ${pairCode}`);
  console.log(`Mac: ${protocol}://localhost:${listenPort}`);
  for (const url of phoneURLs(protocol, listenPort)) {
    console.log(`Phone: ${url}`);
  }
  writeStatus(true, protocol, listenPort);
  console.log("");
  console.log("If controls do nothing, allow this terminal app in System Settings > Privacy & Security > Accessibility.");
  if (protocol === "https") {
    console.log("For Android installable PWA, the phone must trust certs/localhost-cert.pem or use a trusted HTTPS tunnel.");
  }
}

ensureHelper();
startHelper();

server.listen(useHttps ? httpsPort : port, "0.0.0.0", () => {
  announce(useHttps ? "https" : "http", useHttps ? httpsPort : port);
  setInterval(() => writeStatus(true), 5000);
});

function shutdown() {
  if (helperProcess) helperProcess.kill();
  writeStatus(false);
}

process.on("exit", shutdown);
process.on("SIGINT", () => {
  shutdown();
  process.exit(130);
});
process.on("SIGTERM", () => {
  shutdown();
  process.exit(143);
});
