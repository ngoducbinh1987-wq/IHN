// Proxy đơn giản thay Kong: /auth/v1 → GoTrue, /rest/v1 → PostgREST (chỉ dùng thử cục bộ)
import http from 'node:http';
const routes = [['/auth/v1', 9999], ['/rest/v1', 3001]];
http.createServer((req, res) => {
  const r = routes.find(([p]) => req.url.startsWith(p));
  if (!r) { res.writeHead(404); return res.end('not found'); }
  const up = http.request({ host: '127.0.0.1', port: r[1], path: req.url.slice(r[0].length) || '/', method: req.method, headers: req.headers },
    (u) => { res.writeHead(u.statusCode, u.headers); u.pipe(res); });
  up.on('error', (e) => { res.writeHead(502); res.end(String(e)); });
  req.pipe(up);
}).listen(54321, () => console.log('proxy :54321'));
