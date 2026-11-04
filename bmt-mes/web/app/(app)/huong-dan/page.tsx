import Link from 'next/link';
import { ChevronRight } from 'lucide-react';
import { DeptLegend } from '@/components/guide-flow';
import { Toolbar } from '@/components/ui';
import { DEPTS, GROUPS, GUIDES } from '@/lib/huong-dan';
import { requireMe } from '@/lib/session';

export const metadata = { title: 'Hướng dẫn sử dụng' };

// Mọi tài khoản đều vào được (không qua phân quyền bộ phận)
export default async function GuideIndex() {
  await requireMe();
  const main = GUIDES.find((g) => g.slug === 'quy-trinh-chung')!;
  const phases = main.steps.filter((s) => s.phase).map((s) => s.phase!.replace(/^\d+\.\s*/, ''));
  return (
    <>
      <Toolbar title="Hướng dẫn sử dụng MES" />
      <p className="mt-2 max-w-3xl text-[14px] text-muted">
        Mỗi quy trình có lưu đồ: các khâu theo thứ tự, ai phụ trách, thời gian xử lý, kết quả và màn hình MES để làm. Bấm tên màn hình để mở ngay.
      </p>

      <Link href={`/huong-dan/${main.slug}`} id="quy-trinh-chung" className="card mt-4 block p-4 hover:border-brand">
        <div className="flex items-center gap-2 text-[16px] font-semibold text-brand-dark">{main.title}<ChevronRight size={18} /></div>
        <p className="mt-1 text-[13.5px] text-muted">{main.intro}</p>
        <ol className="mt-3 flex flex-wrap items-center gap-1.5 text-[13px]">
          {phases.map((p, i) => (
            <li key={p} className="flex items-center gap-1.5">
              <span className="rounded bg-brand-soft px-2.5 py-1 font-medium text-brand-dark">{i + 1}. {p}</span>
              {i < phases.length - 1 && <ChevronRight size={14} className="text-muted" aria-hidden />}
            </li>
          ))}
        </ol>
      </Link>

      <div className="mt-4 grid gap-4 md:grid-cols-2">
        {GROUPS.filter((g) => g !== 'Quy trình chung').map((g) => (
          <section key={g} className="card">
            <div className="card-h"><h2>{g}</h2></div>
            <ul className="divide-y divide-line">
              {GUIDES.filter((x) => x.group === g).map((x) => (
                <li key={x.slug}>
                  <Link href={`/huong-dan/${x.slug}`} className="flex items-start gap-2 px-4 py-2.5 hover:bg-sunk">
                    <span className="min-w-0 flex-1">
                      <span className="block text-[14.5px] font-medium">{x.title}</span>
                      <span className="block text-[12.5px] text-muted">{x.steps.length} khâu · {[...new Set(x.steps.map((s) => DEPTS[s.dept].name))].filter((n) => n !== 'MES tự động').join(', ')}</span>
                    </span>
                    <ChevronRight size={16} className="mt-1 shrink-0 text-muted" />
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>

      <section className="card mt-4 p-4 text-[13.5px]">
        <h2 className="text-[15px] font-semibold">Cách đọc</h2>
        <div className="mt-2"><DeptLegend /></div>
        <ul className="mt-3 list-disc space-y-1 pl-5 text-muted">
          <li><b className="text-ink">TP SX</b> = Quản lý sản xuất (kiêm thủ kho NVL); <b className="text-ink">TP KT/QA</b> = Trưởng phòng Kỹ thuật/QA; <b className="text-ink">Kế toán SX</b> = Kế toán kho; <b className="text-ink">D−1</b> = ngày trước ngày sản xuất, <b className="text-ink">D+1</b> = ngày sau.</li>
          <li>Thời gian ghi "(đề xuất)" là mức của quy trình final, MES chưa nhắc tự động; còn lại MES nhắc hoặc cảnh báo khi quá hạn.</li>
          <li>Dòng chữ đỏ dưới khâu là nhánh trả lại / không đạt.</li>
        </ul>
      </section>
    </>
  );
}
