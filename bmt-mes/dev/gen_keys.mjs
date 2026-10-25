// Sinh khóa JWT cho môi trường thử cục bộ (KHÔNG dùng cho Supabase thật)
import crypto from 'node:crypto';
const secret = process.env.JWT_SECRET || 'local-dev-jwt-secret-at-least-32-characters-long';
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const sign = (role) => {
  const h = b64({ alg: 'HS256', typ: 'JWT' });
  const p = b64({ role, iss: 'supabase-local', iat: 1761350400, exp: 2076710400 });
  const s = crypto.createHmac('sha256', secret).update(`${h}.${p}`).digest('base64url');
  return `${h}.${p}.${s}`;
};
console.log(`JWT_SECRET=${secret}\nANON_KEY=${sign('anon')}\nSERVICE_ROLE_KEY=${sign('service_role')}`);
