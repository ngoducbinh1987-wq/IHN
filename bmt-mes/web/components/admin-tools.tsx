import { ShieldAlert } from 'lucide-react';
import { SubmitButton } from '@/components/submit-button';
import { adminCancelRequest, adminDeleteDoc, adminReopenDoc } from '@/app/(app)/quan-tri/doc-actions';

// Loại chứng từ Quản trị được mở lại / xóa (giống app.admin_doc); phiếu kho, lệnh SX dùng phiếu đảo / hủy sẵn có
export const ADMIN_DOC_TYPES = ['PR', 'PO', 'SO', 'PLAN', 'PROPOSAL', 'SPEC_NEW', 'SPEC_MINOR'];

// Khung thao tác của Quản trị hệ thống: hủy quy trình đang chạy, mở lại để sửa, xóa chứng từ (bắt buộc lý do)
export function AdminTools({ docType, docId, docNo, requestId, pending, canReopen = true, back, after }: {
  docType?: string; docId?: string; docNo: string; requestId?: string | null; pending?: boolean;
  canReopen?: boolean; back: string; after: string;
}) {
  const doc = !!docType && !!docId && ADMIN_DOC_TYPES.includes(docType);
  if (!doc && !(requestId && pending)) return null;
  return (
    <details id="admin-tools" className="card mb-4 border-bad/40">
      <summary className="card-h cursor-pointer list-none">
        <h2 className="flex items-center gap-2"><ShieldAlert size={17} className="text-bad" />Quản trị hệ thống</h2>
        <span className="text-[12.5px] text-muted">Hủy quy trình · mở lại để sửa · xóa {docNo}</span>
      </summary>
      <form className="space-y-3 px-4 pb-4">
        <input type="hidden" name="back" value={back} /><input type="hidden" name="after" value={after} />
        {requestId && <input type="hidden" name="request_id" value={requestId} />}
        {doc && <><input type="hidden" name="doc_type" value={docType} /><input type="hidden" name="doc_id" value={docId} /></>}
        <label className="lbl"><span className="req">Lý do</span>
          <textarea className="inp" name="reason" rows={2} required placeholder="Ví dụ: lập nhầm nhà cung cấp, cần sửa số lượng…" />
        </label>
        <ul className="list-disc pl-5 text-[13px] text-muted">
          {requestId && pending && <li><b className="text-ink">Hủy quy trình:</b> dừng duyệt, chứng từ về trạng thái để sửa (thường là Nháp).</li>}
          {doc && canReopen && <li><b className="text-ink">Mở lại để sửa:</b> chứng từ (kể cả đã duyệt) về Nháp; sửa xong người lập gửi duyệt lại.</li>}
          {doc && <li><b className="text-ink">Xóa:</b> xóa hẳn chứng từ. Không xóa được khi đã sinh nghiệp vụ sau (đã lên PO, đã nhận hàng, đã có lệnh SX…).</li>}
          <li>Mọi thao tác ghi nhật ký kèm bản sao nội dung cũ; người lập nhận thông báo.</li>
        </ul>
        {doc && <label className="flex items-center gap-2 text-[13.5px]"><input type="checkbox" name="confirm" />Tôi hiểu chứng từ sẽ bị xóa (chỉ cần khi bấm Xóa)</label>}
        <div className="flex flex-wrap gap-2">
          {requestId && pending && <SubmitButton className="btn btn-bad-o" formAction={adminCancelRequest}>Hủy quy trình</SubmitButton>}
          {doc && canReopen && <SubmitButton className="btn" formAction={adminReopenDoc}>Mở lại để sửa</SubmitButton>}
          {doc && <SubmitButton className="btn btn-bad-o" formAction={adminDeleteDoc}>Xóa chứng từ</SubmitButton>}
        </div>
      </form>
    </details>
  );
}
