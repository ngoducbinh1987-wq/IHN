// Kiểm thử đọc danh sách dài và gom lỗi tải trang Kho (không cần database):
// node --experimental-strip-types web/tests/kho-load.test.ts
import { LoadErrors, fetchAll } from '../lib/kho.ts';

let bad = 0;
const ok = (cond: boolean, msg: string) => { if (!cond) { bad++; console.log('SAI: ' + msg); } };

// Giả lập máy chủ trả tối đa `cap` dòng mỗi lần (PostgREST max-rows), bảng có `n` dòng
function server(n: number, cap: number, failAt = -1) {
  const calls: [number, number][] = [];
  const page = async (from: number, to: number) => {
    calls.push([from, to]);
    if (failAt >= 0 && from >= failAt) return { data: null, error: { message: 'mất kết nối' } };
    const end = Math.min(n, to + 1, from + cap);
    const data = Array.from({ length: Math.max(0, end - from) }, (_, i) => from + i);
    return { data, error: null };
  };
  return { page, calls };
}

for (const [n, cap] of [[0, 1000], [999, 1000], [1000, 1000], [1001, 1000], [2500, 1000], [2500, 500], [1700, 250]] as const) {
  const s = server(n, cap);
  const r = await fetchAll<number>(s.page);
  ok(r.data.length === n, `${n} dòng, máy chủ ${cap}/lần: đọc được ${r.data.length}`);
  ok(r.data.every((v, i) => v === i), `${n} dòng, ${cap}/lần: không trùng, không sót`);
  ok(!r.truncated && r.error === null, `${n} dòng: không báo cắt, không lỗi`);
}

{
  const s = server(5000, 1000);
  const r = await fetchAll<number>(s.page, 2500);
  ok(r.truncated && r.data.length === 2500, 'vượt giới hạn an toàn thì báo cắt, đúng số dòng tối đa');
}
{
  const s = server(3000, 1000, 2000);
  const r = await fetchAll<number>(s.page);
  ok(r.error?.message === 'mất kết nối' && r.data.length === 2000, 'lỗi giữa chừng trả lỗi kèm phần đã đọc');
}

{
  const le = new LoadErrors();
  const [a, b] = le.all([{ data: [1], error: null }, { data: null, error: { message: 'permission denied for table x' } }] as const);
  ok(a.data?.[0] === 1 && b.data === null, 'le.all trả lại đúng kết quả');
  le.one({ data: null, error: { message: 'permission denied for table x' } });
  ok(le.has, 'có lỗi thì le.has');
  ok((le.text ?? '').includes('Bạn không có quyền') && (le.text ?? '').split('Bạn không có quyền').length === 2, 'lỗi quyền đổi sang câu dễ hiểu, không lặp');
  const le2 = new LoadErrors();
  le2.all([{ data: [] }, { data: null, error: null }]);
  ok(!le2.has && le2.text === undefined, 'không lỗi thì không hiện gì');
}

console.log(bad ? `${bad} kiểm tra SAI` : 'Đạt hết: fetchAll + LoadErrors');
if (bad) process.exit(1);
