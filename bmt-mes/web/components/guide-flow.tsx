import Link from 'next/link';
import { ArrowDown, CornerDownLeft } from 'lucide-react';
import { DEPTS, SCREENS, type Dept, type Step } from '@/lib/huong-dan';

export function DeptChip({ dept, who }: { dept: Dept; who?: string }) {
  const d = DEPTS[dept];
  const sub = who && who !== d.name && dept !== 'MES';
  return (
    <span className="inline-flex max-w-full items-start gap-1.5 text-[13.5px] leading-snug">
      <span className="mt-[5px] h-2.5 w-2.5 shrink-0 rounded-full" style={{ background: d.color }} aria-hidden />
      <span><b className="font-medium">{who ?? d.name}</b>{sub && <span className="block text-[12px] text-muted">{d.name}</span>}</span>
    </span>
  );
}

// Lưu đồ dọc: mỗi khâu một ô, mũi tên nối; cột Phụ trách – Thời gian – Kết quả (điện thoại: xếp chồng)
export function GuideFlow({ steps }: { steps: Step[] }) {
  return (
    <div className="guide-flow">
      <div className="hidden grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)_minmax(0,0.8fr)_minmax(0,1.3fr)] gap-3 border-b border-line px-3 pb-2 pl-[52px] text-[12.5px] font-medium uppercase tracking-wide text-muted md:grid">
        <span>Khâu</span><span>Phụ trách</span><span>Thời gian</span><span>Kết quả</span>
      </div>
      <ol className="mt-2">
        {steps.map((s, i) => {
          const color = DEPTS[s.dept].color;
          const last = i === steps.length - 1;
          return (
            <li key={i} className="break-inside-avoid">
              {s.phase && <h3 className={`${i ? 'mt-5' : 'mt-1'} mb-2 text-[15px] font-semibold text-brand-dark`}>{s.phase}</h3>}
              <div className="flex gap-3">
                <div className="flex w-10 shrink-0 flex-col items-center">
                  <span className="grid h-8 w-8 place-items-center rounded-full text-[13px] font-semibold text-white" style={{ background: color }}>{i + 1}</span>
                  {!last && <span className="w-px flex-1 bg-line" aria-hidden />}
                </div>
                <div className="min-w-0 flex-1 pb-1">
                  <div className="grid gap-x-3 gap-y-2 rounded border border-line border-l-4 bg-surface px-3 py-2.5 md:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)_minmax(0,0.8fr)_minmax(0,1.3fr)]"
                    style={{ borderLeftColor: color }}>
                    <div className="min-w-0">
                      <div className="text-[14.5px] font-medium leading-snug">{s.k}</div>
                      {s.at && (
                        <Link href={s.at} className="link mt-1 inline-block text-[12.5px] print:no-underline">{SCREENS[s.at] ?? s.at}</Link>
                      )}
                    </div>
                    <Cell label="Phụ trách"><DeptChip dept={s.dept} who={s.who} /></Cell>
                    <Cell label="Thời gian"><span className="text-[13.5px]">{s.time}</span></Cell>
                    <Cell label="Kết quả"><span className="text-[13.5px]">{s.out || '–'}</span></Cell>
                    {s.back && (
                      <div className="flex items-start gap-1.5 text-[12.5px] text-bad md:col-span-4">
                        <CornerDownLeft size={14} className="mt-0.5 shrink-0" />{s.back}
                      </div>
                    )}
                  </div>
                  {!last && !steps[i + 1].phase && <ArrowDown size={16} className="mx-auto my-0.5 text-muted/60 md:ml-8" aria-hidden />}
                  {!last && steps[i + 1].phase && <div className="h-1" />}
                </div>
              </div>
            </li>
          );
        })}
      </ol>
    </div>
  );
}

function Cell({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="min-w-0">
      <div className="text-[11.5px] uppercase tracking-wide text-muted md:hidden">{label}</div>
      {children}
    </div>
  );
}

export function DeptLegend() {
  return (
    <div className="flex flex-wrap gap-x-4 gap-y-1.5">
      {(Object.keys(DEPTS) as Dept[]).map((k) => <DeptChip key={k} dept={k} />)}
    </div>
  );
}
