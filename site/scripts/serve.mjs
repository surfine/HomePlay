import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { brotliCompressSync, gzipSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../dist/', import.meta.url));
const mime = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.avif': 'image/avif', '.mp4': 'video/mp4', '.xml': 'application/xml', '.txt': 'text/plain; charset=utf-8' };
const port = Number(process.env.PORT || 4321);
// 和 dist/_headers 同一條 CSP（少了 frame-ancestors，方便用 iframe 截手機寬度）：本機預覽就擋下行內樣式與外部資源
const CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'self'";
http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    let file = path.resolve(root, `.${decodeURIComponent(url.pathname)}`);
    if (file !== path.resolve(root) && !file.startsWith(root)) { res.writeHead(403).end(); return; }
    if ((await stat(file)).isDirectory()) file = path.join(file, 'index.html');
    let data = await readFile(file);
    const type = mime[path.extname(file)] || 'application/octet-stream';
    // 文字檔照 Cloudflare Pages 的做法壓縮（br 優先、否則 gzip），本機量到的傳輸大小才接近線上
    const enc = /^(text\/|application\/(xml|json))/.test(type) ? (/\bbr\b/.test(req.headers['accept-encoding'] || '') ? 'br' : /\bgzip\b/.test(req.headers['accept-encoding'] || '') ? 'gzip' : '') : '';
    if (enc) data = enc === 'br' ? brotliCompressSync(data) : gzipSync(data);
    res.writeHead(200, { 'Content-Type': type, 'Content-Length': data.length, 'Content-Security-Policy': CSP, ...(enc ? { 'Content-Encoding': enc, Vary: 'Accept-Encoding' } : {}) });
    res.end(req.method === 'HEAD' ? undefined : data);
  } catch {
    const page = await readFile(path.join(root, '404.html')).catch(() => 'Not found');
    res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(req.method === 'HEAD' ? undefined : page);
  }
}).listen(port, '127.0.0.1', () => console.log(`HomePlay: http://127.0.0.1:${port}`));
