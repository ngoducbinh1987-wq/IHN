// Kiểm thử đọc/ghi số kiểu Việt Nam (không cần database): node --experimental-strip-types web/tests/format.test.ts
import { parseNum, numIn } from '../lib/format.ts';
const cases: [string, number | null][] = [
  ['', null], ['12', 12], ['12,5', 12.5], ['1.234,5', 1234.5], ['3.500', 3500], ['268.000', 268000], ['1.234.567', 1234567],
  ['0.254', 0.254], ['-0.5', -0.5], ['0,75', 0.75], ['1.5', 1.5], ['1234.5', 1234.5], ['1,234.5', 1234.5], ['1,234,567', 1234567],
  ['25.375', 25375], [' 1 234,5 ', 1234.5],
];
let bad = 0;
for (const [s, want] of cases) {
  const got = parseNum(s);
  if (got !== want) { bad++; console.log(`SAI: parseNum("${s}") = ${got}, cần ${want}`); }
}
if (!Number.isNaN(parseNum('abc'))) { bad++; console.log('SAI: parseNum("abc") phải là NaN'); }
// Giá trị điền sẵn đọc lại phải ra đúng số cũ (không làm tròn, không bị hiểu nhầm là nghìn)
for (const v of [12.137, 0.254, 25.375, 12.5, 268000, 1234567.89, 0, -3.25, '12.137', '268000.000']) {
  const back = parseNum(numIn(v));
  if (back !== Number(v)) { bad++; console.log(`SAI: numIn(${v}) = "${numIn(v)}" đọc lại thành ${back}`); }
}
if (numIn(null) !== '' || numIn(undefined) !== '' || numIn('') !== '') { bad++; console.log('SAI: numIn rỗng'); }
if (bad) { console.log(`${bad} trường hợp sai`); process.exit(1); }
console.log('TẤT CẢ ĐẠT');
