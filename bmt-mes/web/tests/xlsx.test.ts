// Kiểm thử bộ ghi .xlsx tối giản: node --experimental-strip-types web/tests/xlsx.test.ts [tệp ra]
import { writeFileSync } from 'node:fs';
import { buildXlsx, xlsxDisposition } from '../lib/xlsx.ts';
const out = process.argv[2] ?? '/tmp/xlsx-test.xlsx';
const b = buildXlsx([
  { name: 'Bảng MRP hiệu chỉnh', title: 'Bảng MRP hiệu chỉnh PDC-2611-001 · <thử> & "nháy"', rows: [['Mã', 'Tên', 'Số'], ['CU-025', 'Đồng trần BC Ø0,25', 5535.06], ['LS-O', null, -12.5]], widths: [12, 30, 12] },
  { name: 'Đơn: giảm/?', rows: [['A', 'B'], [1, 2]] },
]);
writeFileSync(out, b);
if (!xlsxDisposition('MRP hieu chinh PDC-2611-001.xlsx').includes("filename*=UTF-8''")) throw new Error('disposition');
console.log('đã ghi', out, b.length, 'byte');
