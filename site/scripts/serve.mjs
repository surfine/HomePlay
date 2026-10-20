import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../dist/', import.meta.url));
const mime = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.xml': 'application/xml', '.txt': 'text/plain; charset=utf-8' };
const port = Number(process.env.PORT || 4321);
http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    let file = path.resolve(root, `.${decodeURIComponent(url.pathname)}`);
    if (file !== path.resolve(root) && !file.startsWith(root)) { res.writeHead(403).end(); return; }
    if ((await stat(file)).isDirectory()) file = path.join(file, 'index.html');
    const data = await readFile(file);
    res.writeHead(200, { 'Content-Type': mime[path.extname(file)] || 'application/octet-stream', 'Content-Length': data.length });
    res.end(req.method === 'HEAD' ? undefined : data);
  } catch {
    const page = await readFile(path.join(root, '404.html')).catch(() => 'Not found');
    res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(req.method === 'HEAD' ? undefined : page);
  }
}).listen(port, '127.0.0.1', () => console.log(`HomePlay: http://127.0.0.1:${port}`));
