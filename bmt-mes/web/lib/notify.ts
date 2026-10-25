import nodemailer from 'nodemailer';
import { after } from 'next/server';
import { createAdminClient, createClient } from './supabase/server';

type Outbox = { id: number; email: string; full_name: string; title: string; body: string | null; link: string | null };

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));

// Gửi email cho các thông báo chưa gửi (người duyệt tiếp theo, người lập khi được duyệt/trả lại).
// Chỉ chạy khi đã cấu hình SMTP (ví dụ Zoho Mail của công ty); thiếu cấu hình thì chỉ có thông báo trong app.
// Hàng đợi nhận theo lô (claim) nên hai lần gửi chạy cùng lúc không gửi trùng; gửi lỗi thì 10 phút sau thử lại.
export async function flushEmailOutbox(): Promise<{ sent: number; failed: number; skipped?: string }> {
  const { SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM, APP_URL, SUPABASE_SERVICE_ROLE_KEY } = process.env;
  if (!SMTP_HOST || !(SMTP_FROM || SMTP_USER) || !SUPABASE_SERVICE_ROLE_KEY) return { sent: 0, failed: 0, skipped: 'Chưa cấu hình SMTP' };
  const admin = createAdminClient();
  const { data, error } = await admin.schema('app').rpc('notification_outbox', { p_limit: 50 });
  if (error) return { sent: 0, failed: 0, skipped: error.message };
  if (!data?.length) return { sent: 0, failed: 0 };
  const port = Number(SMTP_PORT ?? 465);
  const mail = nodemailer.createTransport({ host: SMTP_HOST, port, secure: port === 465, auth: SMTP_USER && SMTP_PASS ? { user: SMTP_USER, pass: SMTP_PASS } : undefined });
  const sent: number[] = [];
  for (const n of data as Outbox[]) {
    const url = n.link && APP_URL ? new URL(n.link, APP_URL).toString() : null;
    try {
      await mail.sendMail({
        from: SMTP_FROM || `BMT MES <${SMTP_USER}>`,
        to: n.email,
        subject: `[BMT MES] ${n.title}`,
        text: `Chào ${n.full_name},\n\n${n.title}\n${n.body ?? ''}\n\n${url ?? ''}`,
        html: `<div style="font-family:Arial,sans-serif;font-size:14px;color:#212529">
          <p>Chào ${esc(n.full_name)},</p>
          <p style="font-size:16px;font-weight:bold;color:#059B42">${esc(n.title)}</p>
          ${n.body ? `<p>${esc(n.body)}</p>` : ''}
          ${url ? `<p><a href="${url}" style="background:#059B42;color:#fff;padding:9px 16px;border-radius:4px;text-decoration:none">Mở trên BMT MES</a></p>` : ''}
          <p style="color:#68717a;font-size:12px">Email tự động từ BMT MES. Không trả lời email này.</p></div>`,
      });
      sent.push(n.id);
    } catch (e) {
      console.error('Gửi email thông báo lỗi', n.id, e);
    }
  }
  if (sent.length) await admin.schema('app').rpc('mark_emailed', { p_ids: sent });
  return { sent: sent.length, failed: data.length - sent.length };
}

// Gửi duyệt một chứng từ; thông báo cho người giữ bước đầu được tạo trong database, email gửi sau khi phản hồi
export async function submitForApproval(docType: string, docId: string, docNo: string, summary: string) {
  const supabase = await createClient();
  const res = await supabase.schema('wf').rpc('submit', { p_doc_type: docType, p_doc_id: docId, p_doc_no: docNo, p_summary: summary });
  if (!res.error) after(async () => { await flushEmailOutbox(); });
  return res;
}
