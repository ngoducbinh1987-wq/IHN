// Kiểm thử end-to-end giai đoạn 1 trên trình duyệt thật (Playwright).
// Chạy với môi trường thử cục bộ (dev/local_stack.sh up) và `next start -p 3000`.
// node tests/e2e.mjs [thư_mục_ảnh]
import { createRequire } from 'node:module';

// Playwright cài sẵn toàn cục trên máy thử (không đưa vào dependencies của app)
const { chromium } = createRequire(import.meta.url)('playwright');

const BASE = process.env.BASE_URL || 'http://localhost:3000';
const SHOTS = process.argv[2] || '.';
const PASS = 'Bmt@2026test';
let n = 0;
const ok = (msg) => console.log(`PASS ${++n}: ${msg}`);
const fail = (msg) => { console.error(`FAIL: ${msg}`); process.exit(1); };

const browser = await chromium.launch();
const ctxFor = async () => {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'vi-VN' });
  return [ctx, await ctx.newPage()];
};
async function login(page, email, password = PASS) {
  await page.goto(`${BASE}/login`);
  await page.fill('#email', email);
  await page.fill('#password', password);
  await Promise.all([page.waitForURL((u) => !u.pathname.startsWith('/login')), page.click('button[type=submit]')]);
  await page.waitForLoadState('networkidle');
}
// Bấm và chờ URL đổi (server action chuyển hướng kèm ?ok= / ?err=)
async function clickNav(page, selector) {
  const before = page.url();
  await Promise.all([page.waitForURL((u) => u.href !== before), page.click(selector)]);
  await page.waitForLoadState('networkidle');
}
const flash = async (page) => (await page.locator('[role=status]').first().textContent().catch(() => '')) ?? '';
async function expectOk(page, what) {
  const t = await flash(page);
  if (!t || /lỗi|không|error/i.test(t) && !/Không có/.test(t)) fail(`${what}: "${t}"`);
  ok(`${what} → ${t.trim()}`);
}

// 1. Quản trị viên đầu tiên
let [ctx, page] = await ctxFor();
await login(page, 'admin@bmt.test', 'Admin@12345');
await page.waitForURL('**/khoi-tao**').catch(() => {});
if (!page.url().includes('/khoi-tao')) fail('Tài khoản chưa có hồ sơ phải vào trang khởi tạo');
await page.fill('#full_name', 'Ngô Đức Bình');
await Promise.all([page.waitForURL('**/quan-tri**'), page.click('button:has-text("Nhận vai trò quản trị")')]);
await expectOk(page, 'Nhận vai trò quản trị đầu tiên');

// 2. Tạo tài khoản các phòng ban
const users = [
  ['kt.nv@bmt.test', 'Lê Văn Kỹ', ['KT_NV']], ['qc@bmt.test', 'Trần Thị QC', ['QC']], ['kt.tp@bmt.test', 'Lê Minh Châu', ['KT_TP']],
  ['bgd@bmt.test', 'Nguyễn Văn An', ['BGD']], ['sx.kh@bmt.test', 'Phạm Kế Hoạch', ['SX_KH']], ['sx.tp@bmt.test', 'Đỗ Văn Khánh', ['SX_TP']],
  ['mua.tp@bmt.test', 'Hoàng Thu Hà', ['MUA_TP']], ['vh@bmt.test', 'Công Nhân Vận Hành', ['VAN_HANH']],
];
for (const [email, name, roles] of users) {
  await page.goto(`${BASE}/quan-tri`);
  await page.fill('input[name=full_name]', name);
  await page.fill('input[name=email]', email);
  await page.fill('input[name=password]', PASS);
  for (const r of roles) await page.check(`#n-${r}`);
  await Promise.all([page.waitForURL('**/quan-tri?**'), page.click('button:has-text("Tạo tài khoản")')]);
  await expectOk(page, `Tạo ${email}`);
}
await page.screenshot({ path: `${SHOTS}/01-quan-tri.png`, fullPage: true });
await ctx.close();

// 3. Mua hàng nhập điều kiện mua CU-024
[ctx, page] = await ctxFor();
await login(page, 'mua.tp@bmt.test');
await page.goto(`${BASE}/vat-tu?q=CU-024`);
await page.fill('input[aria-label="Lead time CU-024"]', '14');
await page.fill('input[aria-label="Đơn giá CU-024"]', '268.000');
await Promise.all([page.waitForURL('**/vat-tu?ok=**'), page.click('tr:has-text("CU-024") button:has-text("Lưu")')]);
await expectOk(page, 'Mua hàng lưu giá + lead time CU-024 (nhập kiểu VN "268.000")');
if (!(await page.inputValue('input[aria-label="Đơn giá CU-024"]').catch(() => '')).startsWith('268000')) {
  await page.goto(`${BASE}/vat-tu?q=CU-024`);
  const v = await page.inputValue('input[aria-label="Đơn giá CU-024"]');
  if (Number(v) !== 268000) fail(`Giá CU-024 phải lưu 268000, đang là ${v}`);
}
ok('Giá "268.000" được lưu đúng 268.000 đồng');
await page.goto(`${BASE}/vat-tu`);
await page.screenshot({ path: `${SHOTS}/02-vat-tu.png`, fullPage: false });
await ctx.close();

// 4. Kỹ thuật gửi duyệt spec PFR-2C-1p5; SFR-2P-1 (Rdc vượt) không có nút gửi hợp lệ
[ctx, page] = await ctxFor();
await login(page, 'kt.nv@bmt.test');
await page.goto(`${BASE}/san-pham/SFR-2P-1`);
if (!(await page.textContent('body')).includes('Chưa đủ điều kiện phát hành')) fail('SFR-2P-1 phải báo chưa đủ điều kiện');
await clickNav(page, 'button:has-text("Gửi duyệt phát hành")');
ok(`SFR-2P-1 bị chặn gửi duyệt → ${(await flash(page)).slice(0, 90)}…`);
await page.goto(`${BASE}/san-pham/PFR-2C-1p5`);
await clickNav(page, 'button:has-text("Gửi duyệt phát hành")');
await expectOk(page, 'KT gửi duyệt spec PFR-2C-1p5');
await page.screenshot({ path: `${SHOTS}/03-spec.png`, fullPage: true });
await ctx.close();

// 5. Duyệt 3 cấp: QC → TP KT → BGĐ, có thử trả lại không lý do
async function approveAs(email, docNo, label) {
  const [c, p] = await ctxFor();
  await login(p, email);
  await p.goto(`${BASE}/duyet`);
  const link = p.locator(`a:has-text("${docNo}")`).first();
  if (!(await link.count())) fail(`${email} không thấy ${docNo} trong hộp duyệt`);
  await link.click();
  await p.waitForURL('**/duyet/**');
  if (label === 'reject-empty') {
    await clickNav(p, 'button:has-text("Trả lại")');
    ok(`Trả lại không lý do bị chặn → ${await flash(p)}`);
    await c.close();
    return;
  }
  await p.fill('#comment', `${label} đồng ý`);
  await clickNav(p, 'button:has-text("Phê duyệt")');
  await expectOk(p, `${label} phê duyệt ${docNo}`);
  if (label === 'BGĐ' && docNo.startsWith('SPEC')) await p.screenshot({ path: `${SHOTS}/04-duyet.png`, fullPage: true });
  await c.close();
}
await approveAs('qc@bmt.test', 'SPEC PFR-2C-1p5', 'reject-empty');
await approveAs('qc@bmt.test', 'SPEC PFR-2C-1p5', 'QC');
await approveAs('kt.tp@bmt.test', 'SPEC PFR-2C-1p5', 'TP KT');
await approveAs('bgd@bmt.test', 'SPEC PFR-2C-1p5', 'BGĐ');
[ctx, page] = await ctxFor();
await login(page, 'kt.nv@bmt.test');
await page.goto(`${BASE}/san-pham/PFR-2C-1p5`);
if (!(await page.textContent('h1 + div')).includes('Đã phát hành')) fail('Spec phải ở trạng thái Đã phát hành');
ok('Spec PFR-2C-1p5 Đã phát hành sau 3 cấp duyệt');
await ctx.close();

// 6. Kế hoạch: tạo, thêm dòng, chạy MRP, gửi duyệt, duyệt 2 cấp, sinh PR
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(`${BASE}/ke-hoach`);
await page.fill('input[name=period_label]', 'Tháng 11/2026');
await page.fill('input[name=need_date]', '2026-11-20');
await Promise.all([page.waitForURL('**/ke-hoach/**'), page.click('button:has-text("Tạo kế hoạch")')]);
await expectOk(page, 'Tạo kế hoạch');
const planUrl = page.url().split('?')[0];
const planNo = (await page.textContent('h1')).split(' · ')[0];
await page.selectOption('select[name=product_id]', { label: (await page.locator('option', { hasText: 'PFR-2C-1p5 ·' }).first().textContent()) });
await page.fill('input[name=qty_m]', '3.500');
await clickNav(page, 'button:has-text("Thêm dòng")');
await expectOk(page, 'Thêm dòng PFR-2C-1p5 3.500 m');
await clickNav(page, 'button:has-text("Chạy MRP")');
await expectOk(page, 'Chạy MRP');
const lineRow = (await page.locator('tr:has-text("PFR-2C-1p5")').first().innerText()) ?? '';
if (!lineRow.includes('3.500') || !lineRow.includes('7')) fail(`Dòng kế hoạch phải là 3.500 m / 7 kiện: ${lineRow}`);
ok('Sản lượng "3.500" được hiểu đúng 3.500 m, 7 bobin');
const cuCells = await page.locator('tr:has-text("CU-024") td').allInnerTexts();
// Lý thuyết 24,723 × 3,5 = 86,53 kg; cấp SX = /(1−1,5%) = 87,85 kg → đề nghị 100 kg (bội số 100) × 268.000 đ
if (cuCells[3] !== '86,53' || cuCells[4] !== '87,85' || cuCells[10] !== '100' || !cuCells.join(' ').includes('Đặt hàng')) {
  fail(`Dòng MRP CU-024 sai: ${cuCells.join(' | ')}`);
}
ok('MRP CU-024: lý thuyết 86,53 kg → cấp SX 87,85 kg → đề nghị mua 100 kg (khớp Excel)');
if ((await page.textContent('body')).includes('Thành tiền') || (await page.textContent('body')).includes('ngân sách')) fail('Kế hoạch SX không được thấy giá/ngân sách');
ok('Kế hoạch SX không thấy cột thành tiền và ngân sách (không có quyền xem giá)');
await page.screenshot({ path: `${SHOTS}/05-ke-hoach-mrp.png`, fullPage: true });
await clickNav(page, 'button:has-text("Gửi duyệt kế hoạch")');
await expectOk(page, 'Gửi duyệt kế hoạch');
await ctx.close();
await approveAs('sx.tp@bmt.test', planNo, 'TP SX');
await approveAs('bgd@bmt.test', planNo, 'BGĐ');
{
  const [c, p] = await ctxFor();
  await login(p, 'bgd@bmt.test');
  await p.goto(planUrl);
  const cells = await p.locator('tr:has-text("CU-024") td').allInnerTexts();
  if (cells[11] !== '26.800.000') fail(`BGĐ phải thấy thành tiền CU-024 = 26.800.000: ${cells.join(' | ')}`);
  ok('BGĐ thấy thành tiền CU-024 = 100 kg × 268.000 = 26.800.000 đ');
  await c.close();
}
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(planUrl);
await clickNav(page, 'button:has-text("Sinh PR")');
await expectOk(page, 'Sinh PR sau khi BGĐ duyệt kế hoạch');
await ctx.close();

// 7. Phân quyền: vận hành không vào trang Vật tư/Quản trị, menu bị ẩn
[ctx, page] = await ctxFor();
await login(page, 'vh@bmt.test');
const nav = await page.textContent('nav');
if (nav.includes('Người dùng') || nav.includes('Kế hoạch')) fail(`Menu của vận hành không được có Quản trị/Kế hoạch: ${nav}`);
await page.goto(`${BASE}/quan-tri`);
if (!(await flash(page)).includes('chưa được cấp quyền')) fail('Vận hành vào được trang Quản trị');
ok('Vận hành không thấy menu Quản trị/Kế hoạch và bị chặn khi gõ thẳng URL');
await page.goto(`${BASE}/vat-tu`);
if ((await page.textContent('thead')).includes('Đơn giá')) fail('Vận hành không được thấy cột giá');
ok('Vận hành xem Vật tư nhưng không thấy cột giá');
await page.goto(`${BASE}/`);
await page.screenshot({ path: `${SHOTS}/06-tong-quan-van-hanh.png` });
await ctx.close();

// Ảnh tổng quan của BGĐ (điện thoại + máy tính)
[ctx, page] = await ctxFor();
await login(page, 'bgd@bmt.test');
await page.screenshot({ path: `${SHOTS}/07-tong-quan-bgd.png`, fullPage: true });
await page.setViewportSize({ width: 390, height: 844 });
await page.goto(`${BASE}/san-pham`);
await page.screenshot({ path: `${SHOTS}/08-dien-thoai.png` });
await ctx.close();

await browser.close();
console.log(`==> ĐẠT ${n} kiểm tra end-to-end`);
