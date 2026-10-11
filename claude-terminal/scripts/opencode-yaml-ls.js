#!/usr/bin/env node
// opencode-yaml-ls — run yaml-language-server for OpenCode so that Home
// Assistant's YAML tags (!secret, !include, ...) are understood.
//
// Why a wrapper rather than OpenCode's built-in yaml-ls entry: OpenCode does
// pass the `initialization` block from its config to the server as settings,
// which is where customTags lives -- but the server never gets as far as
// listening for them. Its `initialized` handler first subscribes to workspace
// folder changes, and that subscription throws ("Client doesn't support
// sending workspace folder change events") because OpenCode names a workspace
// folder without declaring the matching client capability. The handler aborts,
// the settings listeners after it are never registered, and every `!secret`
// line in /config is reported as an unresolved tag.
//
// So this declares that one capability in the client's `initialize` request.
// Nothing ever has to honour it: the folder is /config for the life of the
// session. Everything after that first message is passed through untouched.
//
// The server itself is the copy OpenCode downloads for its built-in entry,
// reused when present and installed to the same place when not, so there is
// one copy either way and it sits in a cache directory that is excluded from
// Home Assistant backups.

"use strict";

const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const cacheHome = process.env.XDG_CACHE_HOME || path.join(process.env.HOME || "/root", ".cache");
const prefix = path.join(cacheHome, "opencode", "packages", "yaml-language-server");
const server = path.join(prefix, "node_modules", "yaml-language-server", "bin", "yaml-language-server");

if (!fs.existsSync(server)) {
    // stdout belongs to the LSP stream, so npm's output must never reach it.
    fs.mkdirSync(prefix, { recursive: true });
    const install = spawnSync(
        "npm",
        ["install", "--prefix", prefix, "--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=error", "yaml-language-server"],
        { stdio: ["ignore", "ignore", "inherit"], timeout: 180000 }
    );
    if (install.status !== 0 || !fs.existsSync(server)) {
        process.stderr.write("opencode-yaml-ls: could not install yaml-language-server\n");
        process.exit(1);
    }
}

const child = spawn(process.execPath, [server, "--stdio"], { stdio: ["pipe", "inherit", "inherit"] });
child.on("exit", (code) => process.exit(code === null ? 1 : code));
child.on("error", () => process.exit(1));
child.stdin.on("error", () => {});
process.stdin.on("end", () => child.stdin.end());

// Rewrite the first framed message, then get out of the way.
let pending = Buffer.alloc(0);
let rewritten = false;

function passthrough() {
    rewritten = true;
    if (pending.length) child.stdin.write(pending);
    pending = null;
    process.stdin.removeListener("data", onData);
    process.stdin.pipe(child.stdin);
}

function onData(chunk) {
    pending = Buffer.concat([pending, chunk]);
    const headerEnd = pending.indexOf("\r\n\r\n");
    if (headerEnd === -1) return;

    const match = /content-length:\s*(\d+)/i.exec(pending.slice(0, headerEnd).toString("ascii"));
    if (!match) return passthrough();

    const bodyStart = headerEnd + 4;
    const bodyEnd = bodyStart + Number(match[1]);
    if (pending.length < bodyEnd) return;

    let body = pending.slice(bodyStart, bodyEnd);
    try {
        const message = JSON.parse(body.toString("utf8"));
        const workspace = message && message.params && message.params.capabilities
            && message.params.capabilities.workspace;
        if (message.method === "initialize" && workspace) {
            workspace.workspaceFolders = true;
            body = Buffer.from(JSON.stringify(message), "utf8");
        }
    } catch (_) {
        // Not JSON we understand: forward it exactly as received.
    }

    child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    child.stdin.write(body);
    pending = pending.slice(bodyEnd);
    passthrough();
}

process.stdin.on("data", onData);
