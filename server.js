#!/usr/bin/env node
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const PORT = 7600;
const HOST = '127.0.0.1';
const HTML_PATH = path.join(__dirname, 'split-view.html');
const SCRIPTS_DIR = path.join(__dirname, 'scripts');

const server = http.createServer((req, res) => {
    const { method, url } = req;

    if (method === 'GET' && url === '/') {
        try {
            const html = fs.readFileSync(HTML_PATH);
            res.writeHead(200, { 'Content-Type': 'text/html' });
            res.end(html);
        } catch (err) {
            res.writeHead(500);
            res.end('Failed to read split-view.html');
        }
        return;
    }

    if (method === 'GET' && url === '/check-bedrock') {
        execFile(path.join(SCRIPTS_DIR, 'check-bedrock.sh'), (err, stdout) => {
            if (err) {
                res.writeHead(500);
                res.end('not-configured');
                return;
            }
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end(stdout.trim());
        });
        return;
    }

    if (method === 'POST' && url === '/configure-bedrock') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            let token;
            try {
                const parsed = JSON.parse(body);
                token = parsed.token;
            } catch {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: false, error: 'Invalid JSON' }));
                return;
            }

            if (!token || typeof token !== 'string' || token.trim() === '') {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: false, error: 'Token is required' }));
                return;
            }

            execFile(path.join(SCRIPTS_DIR, 'configure-bedrock.sh'), [token.trim()], (err, _stdout, stderr) => {
                if (err) {
                    res.writeHead(500, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ ok: false, error: stderr || err.message }));
                    return;
                }
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: true }));
            });
        });
        return;
    }

    res.writeHead(404);
    res.end('Not found');
});

server.listen(PORT, HOST, () => {
    console.log(`flutterly server listening on ${HOST}:${PORT}`);
});
