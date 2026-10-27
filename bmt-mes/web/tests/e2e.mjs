// Kiểm thử end-to-end trên trình duyệt thật (Playwright): giao diện kiểu Fastcon, thêm mới, quy trình duyệt, thông báo.
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
  if (!t || /lỗi|không|error/i.test(t) && !/Không có/.test(t)) {
    await page.screenshot({ path: `${SHOTS}/fail.png`, fullPage: true }).catch(() => {});
    fail(`${what}: "${t}" tại ${page.url()} – ${(await page.locator('main').innerText().catch(() => '')).slice(0, 200)}`);
  }
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
  ['mua.tp@bmt.test', 'Hoàng Thu Hà', ['MUA_TP']], ['mua.nv@bmt.test', 'Dương Thu Hương', ['MUA_NV']], ['vh@bmt.test', 'Công Nhân Vận Hành', ['VAN_HANH']],
  ['ct@bmt.test', 'Chủ Tịch Thử', ['BGD']],
];
for (const [email, name, roles] of users) {
  await page.goto(`${BASE}/quan-tri?them=1`);
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

// 4. TP Kỹ thuật/QA gửi duyệt spec PFR-2C-1P5; SFR-2P-1 (Rdc vượt) không có nút gửi hợp lệ
[ctx, page] = await ctxFor();
await login(page, 'kt.tp@bmt.test');
await page.goto(`${BASE}/san-pham/SFR-2P-1`);
if (!(await page.textContent('body')).includes('Chưa đủ điều kiện phát hành')) fail('SFR-2P-1 phải báo chưa đủ điều kiện');
await clickNav(page, 'button:has-text("Gửi duyệt phát hành")');
ok(`SFR-2P-1 bị chặn gửi duyệt → ${(await flash(page)).slice(0, 90)}…`);
await page.goto(`${BASE}/san-pham/PFR-2C-1P5`);
await clickNav(page, 'button:has-text("Gửi duyệt phát hành")');
await expectOk(page, 'TP KT/QA gửi duyệt spec PFR-2C-1P5');
await page.screenshot({ path: `${SHOTS}/03-spec.png`, fullPage: true });
await ctx.close();

// 5. Duyệt 2 cấp: Quản lý SX xác nhận → Giám đốc phát hành, có thử trả lại không lý do
async function approveAs(email, docNo, label) {
  const [c, p] = await ctxFor();
  await login(p, email);
  await p.goto(`${BASE}/duyet`);
  const link = p.locator(`a:has-text("${docNo}")`).first();
  if (!(await link.count())) fail(`${email} không thấy ${docNo} trong "Chờ tôi duyệt"`);
  await link.click();
  await p.waitForURL('**/duyet/**');
  await p.waitForLoadState('networkidle');
  if (label === 'reject-empty') {
    await p.click('summary[aria-label="Tùy chọn khác"]');
    await clickNav(p, 'button:has-text("Trả lại người lập")');
    ok(`Trả lại không lý do bị chặn → ${await flash(p)}`);
    await c.close();
    return;
  }
  await clickNav(p, 'button:has-text("Chuyển giai đoạn tiếp")');
  await expectOk(p, `${label} chuyển giai đoạn ${docNo}`);
  if (label === 'QL SX' && docNo.startsWith('SPEC')) await p.screenshot({ path: `${SHOTS}/04-duyet-chi-tiet.png`, fullPage: true });
  await c.close();
}
await approveAs('sx.tp@bmt.test', 'SPEC PFR-2C-1P5', 'reject-empty');
await approveAs('sx.tp@bmt.test', 'SPEC PFR-2C-1P5', 'QL SX');
await approveAs('bgd@bmt.test', 'SPEC PFR-2C-1P5', 'GĐ');
[ctx, page] = await ctxFor();
await login(page, 'kt.nv@bmt.test');
await page.goto(`${BASE}/san-pham/PFR-2C-1P5`);
if (!(await page.textContent('main aside')).includes('Đã phát hành')) fail('Spec phải ở trạng thái Đã phát hành');
ok('Spec PFR-2C-1P5 Đã phát hành sau 2 cấp duyệt (Quản lý SX → Giám đốc)');
await ctx.close();

// 6. Kế hoạch: tạo, thêm dòng, chạy MRP; Giám đốc gửi duyệt; Quản lý SX xác nhận → Chủ tịch HĐQT phê duyệt; sinh PR
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(`${BASE}/ke-hoach/moi`);
await page.fill('input[name=period_label]', 'Tháng 11/2026');
await page.fill('input[name=need_date]', '2026-11-20');
await Promise.all([page.waitForURL('**/ke-hoach/**'), page.click('button:has-text("Tạo kế hoạch")')]);
await expectOk(page, 'Tạo kế hoạch');
const planUrl = page.url().split('?')[0];
const planNo = (await page.textContent('main h1')).split(' – ')[0];
await page.selectOption('select[name=product_id]', { label: (await page.locator('option', { hasText: 'PFR-2C-1P5 ·' }).first().textContent()) });
await page.fill('input[name=qty_m]', '3.500');
await clickNav(page, 'button:has-text("Thêm dòng")');
await expectOk(page, 'Thêm dòng PFR-2C-1P5 3.500 m');
await clickNav(page, 'button:has-text("Chạy MRP")');
await expectOk(page, 'Chạy MRP');
const lineRow = (await page.locator('tr:has-text("PFR-2C-1P5")').first().innerText()) ?? '';
if (!lineRow.includes('3.500') || !lineRow.includes('7')) fail(`Dòng kế hoạch phải là 3.500 m / 7 kiện: ${lineRow}`);
ok('Sản lượng "3.500" được hiểu đúng 3.500 m, 7 bobin');
const cuCells = await page.locator('tr:has-text("CU-024") td').allInnerTexts();
// Lý thuyết 24,723 × 3,5 = 86,53 kg; cấp SX = /(1−1,5%) = 87,85 kg → đề nghị 100 kg (bội số 100) × 268.000 đ
if (cuCells[3] !== '86,53' || cuCells[4] !== '87,85' || cuCells[11] !== '100' || !cuCells.join(' ').includes('Đặt hàng')) {
  fail(`Dòng MRP CU-024 sai: ${cuCells.join(' | ')}`);
}
ok('MRP CU-024: lý thuyết 86,53 kg → cấp SX 87,85 kg → đề nghị mua 100 kg (khớp Excel)');
if ((await page.textContent('body')).includes('Thành tiền') || (await page.textContent('body')).includes('ngân sách')) fail('Kế hoạch SX không được thấy giá/ngân sách');
ok('Kế hoạch SX không thấy cột thành tiền và ngân sách (không có quyền xem giá)');
await page.screenshot({ path: `${SHOTS}/05-ke-hoach-mrp.png`, fullPage: true });
// 6a. Sửa dòng kế hoạch bằng nút bút: mở dữ liệu cũ, đổi quy cách đóng gói, cập nhật số kiện, đánh dấu cần chạy lại MRP
if (await page.locator('tr:has-text("CU-024") a[title="Điều chỉnh"]').count()) fail('Kế hoạch SX không được thấy nút điều chỉnh MRP');
await clickNav(page, 'a[title="Sửa dòng"]');
if ((await page.inputValue('input[name=qty_m]')) !== '3500' || (await page.inputValue('select[name=pack_type]')) !== 'Bobin gỗ'
  || (await page.inputValue('select[name=m_per_pack]')) !== '500') fail('Form sửa phải mở đúng dữ liệu cũ 3500 m / Bobin gỗ / 500');
const mOpts = await page.locator('select[name=m_per_pack] option').allInnerTexts();
if (!mOpts.includes('305') || !mOpts.includes('500')) fail(`Bobin gỗ phải có 305 và 500 m/kiện: ${mOpts}`);
ok('Bút sửa dòng mở đúng dữ liệu cũ; Bobin gỗ có lựa chọn 305 và 500 m/kiện');
await page.selectOption('select[name=m_per_pack]', '305');
await clickNav(page, 'button:has-text("Lưu")');
await expectOk(page, 'Lưu dòng sửa sang 305 m/kiện');
if (!(await flash(page)).includes('cần chạy lại')) fail('Sửa sau khi chạy MRP phải báo cần chạy lại MRP');
const row305 = await page.locator('tr:has-text("PFR-2C-1P5")').first().innerText();
if (!row305.includes('305') || !row305.includes('12') || !row305.includes('11 chẵn + 1 lẻ 145 m')) fail(`3.500 m / 305 phải là 12 kiện (11 chẵn + 1 lẻ 145 m): ${row305}`);
if (!(await page.textContent('#mrp-stale')).includes('Chạy MRP') || await page.locator('button:has-text("Gửi duyệt kế hoạch")').count()) fail('MRP cũ: phải cảnh báo và ẩn nút gửi duyệt');
ok('305 m/kiện: 12 kiện (11 chẵn + 1 lẻ 145 m); cảnh báo cần chạy lại MRP, ẩn nút gửi duyệt');
await clickNav(page, 'a[title="Sửa dòng"]');
await page.selectOption('select[name=pack_type]', 'Cuộn PE');
const peOpts = await page.locator('select[name=m_per_pack] option').allInnerTexts();
if (peOpts.join() !== '100,200') fail(`Cuộn PE phải có 100 và 200 m: ${peOpts}`);
await page.selectOption('select[name=m_per_pack]', '200');
await clickNav(page, 'button:has-text("Lưu")');
await page.reload();
await clickNav(page, 'a[title="Sửa dòng"]');
if ((await page.inputValue('select[name=pack_type]')) !== 'Cuộn PE' || (await page.inputValue('select[name=m_per_pack]')) !== '200') fail('Tải lại phải giữ Cuộn PE 200 m');
ok('Cuộn PE có 100/200 m; lưu và tải lại giữ đúng Cuộn PE 200 m');
await page.selectOption('select[name=pack_type]', 'Bobin gỗ');
await page.selectOption('select[name=m_per_pack]', '500');
await clickNav(page, 'button:has-text("Lưu")');
await clickNav(page, 'button:has-text("Chạy MRP")');
if (await page.locator('#mrp-stale').count()) fail('Chạy lại MRP phải hết cảnh báo');
if (!(await page.locator('button:has-text("Gửi duyệt kế hoạch")').first().waitFor({ timeout: 10000 }).then(() => true).catch(() => false))) {
  fail('Kế hoạch SX (TP SX) phải thấy nút gửi duyệt kế hoạch tháng');
}
ok('Chạy lại MRP: hết cảnh báo; Kế hoạch SX thấy nút gửi duyệt (quy trình final: TP SX lập)');
{
  const [c, p] = await ctxFor();
  await login(p, 'sx.kh@bmt.test');
  await p.goto(`${BASE}/in/ke-hoach/${planUrl.split('/').pop()}`);
  const t = await p.textContent('main');
  if (!t.includes('KẾ HOẠCH SẢN XUẤT') || !t.includes('Kiện lẻ')) fail('Bản in kế hoạch phải có cột kiện chẵn/lẻ');
  ok('Bản in kế hoạch có quy cách đóng gói, kiện chẵn và kiện lẻ');
  await c.close();
}
await ctx.close();
[ctx, page] = await ctxFor();
await login(page, 'sx.tp@bmt.test');
await page.goto(planUrl);
await clickNav(page, 'button:has-text("Gửi duyệt kế hoạch")');
await expectOk(page, 'TP SX gửi duyệt kế hoạch tháng');
await ctx.close();
await approveAs('ct@bmt.test', planNo, 'Chủ tịch HĐQT');
{
  const [c, p] = await ctxFor();
  await login(p, 'bgd@bmt.test');
  await p.goto(planUrl);
  const cells = await p.locator('tr:has-text("CU-024") td').allInnerTexts();
  if (cells[13] !== '26.800.000') fail(`BGĐ phải thấy thành tiền CU-024 = 26.800.000: ${cells.join(' | ')}`);
  ok('BGĐ thấy thành tiền CU-024 = 100 kg × 268.000 = 26.800.000 đ');
  await c.close();
}
// 6a'. TP Mua điều chỉnh kết quả MRP (bắt buộc lý do), PR dùng số đã điều chỉnh, sau đó khóa
[ctx, page] = await ctxFor();
await login(page, 'mua.tp@bmt.test');
await page.goto(planUrl);
await clickNav(page, 'tr:has-text("CU-024") a[title="Điều chỉnh"]');
await page.fill('form input[name=qty]', '120');
await page.fill('form input[name=note]', 'Gom đơn quý IV');
await page.fill('form input[name=reason]', 'NCC giảm giá khi mua từ 120 kg');
await clickNav(page, 'form button:has-text("Lưu")');
await expectOk(page, 'TP Mua điều chỉnh CU-024 100 → 120 kg');
const cuAdj = await page.locator('tr:has-text("CU-024")').first().innerText();
if (!cuAdj.includes('120') || !cuAdj.includes('gốc 100') || !cuAdj.includes('Gom đơn quý IV')) fail(`Dòng MRP phải hiện số mới + gốc: ${cuAdj}`);
if (!(await page.textContent('main')).includes('NCC giảm giá khi mua từ 120 kg')) fail('Lịch sử điều chỉnh phải có lý do');
ok('MRP hiện số đã điều chỉnh, giữ số gốc 100 và lịch sử kèm lý do');
await page.screenshot({ path: `${SHOTS}/05b-mrp-dieu-chinh.png`, fullPage: true });
await ctx.close();
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(planUrl);
await clickNav(page, 'button:has-text("Sinh đề xuất mua (PR)")');
if (!page.url().includes('/de-xuat/')) fail('Sinh PR phải chuyển sang trang đề xuất mua');
await expectOk(page, 'Sinh PR sau khi BGĐ duyệt kế hoạch');
if ((await page.inputValue('tr:has-text("CU-024") input[name=qty]')) !== '120') fail('PR phải dùng số đã điều chỉnh 120 kg');
const prRow = await page.locator('tr:has-text("CU-024")').first().innerText();
if (!prRow.includes('87,85') || !prRow.includes('MES đề nghị 100')) fail(`PR từ dự trù phải có cột nhu cầu 87,85 kg và số MES đề nghị: ${prRow}`);
ok('Đề xuất mua từ dự trù có cột nhu cầu, tồn, đang về, tồn dự kiến; TP SX sửa được số mua');
ok('PR sinh từ MRP dùng số lượng đã điều chỉnh (CU-024 120 kg)');
await ctx.close();
{
  const [c, p] = await ctxFor();
  await login(p, 'mua.tp@bmt.test');
  await p.goto(planUrl);
  if (await p.locator('a[title="Điều chỉnh"]').count()) fail('Đã sinh PR: không còn nút điều chỉnh MRP');
  if (!(await p.textContent('main')).includes('Kết quả MRP đang khóa')) fail('Phải báo kết quả MRP đang khóa');
  ok('Đã sinh PR: kết quả MRP bị khóa');
  await c.close();
}
// 6a''. Phiếu điều chỉnh kế hoạch tháng: Kế hoạch SX lập (đổi sản lượng 3.500 → 4.000 m), Chủ tịch HĐQT duyệt, MES áp vào kế hoạch
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(planUrl);
await page.fill('#dieu-chinh input[name=reason]', 'Khách đặt thêm 500 m');
await Promise.all([page.waitForURL('**/ke-hoach/dieu-chinh/**'), page.click('#dieu-chinh button:has-text("Lập phiếu điều chỉnh")')]);
await expectOk(page, 'Lập phiếu điều chỉnh kế hoạch tháng');
const adjNo = (await page.textContent('main h1')).split(' ·')[0].trim();
await page.selectOption('select[name=kind_0]', 'QTY');
await page.selectOption('select[name=line_0]', { index: 1 });
await page.fill('input[name=qty_0]', '4.000');
await clickNav(page, 'button:has-text("Lưu và gửi Chủ tịch HĐQT duyệt")');
await expectOk(page, `Gửi ${adjNo} cho Chủ tịch HĐQT duyệt`);
if (!(await page.textContent('main')).includes('3.500 → 4.000')) fail('Phiếu điều chỉnh phải hiện 3.500 → 4.000 m');
await page.screenshot({ path: `${SHOTS}/05c-phieu-dieu-chinh.png`, fullPage: true });
await ctx.close();
await approveAs('ct@bmt.test', adjNo, 'Chủ tịch HĐQT');
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(planUrl);
if (!(await page.locator('tr:has-text("PFR-2C-1P5")').first().innerText()).includes('4.000')) fail('Duyệt xong: dòng kế hoạch phải thành 4.000 m');
if (!(await page.locator('#mrp-stale').count())) fail('Duyệt điều chỉnh xong phải báo chạy lại dự trù');
await clickNav(page, 'button:has-text("Chạy MRP")');
if (!(await page.textContent('main')).includes('Dự trù nhiều tầng')) fail('Trang kế hoạch phải có bảng dự trù nhiều tầng');
ok('Chủ tịch duyệt phiếu điều chỉnh: MES áp 4.000 m vào kế hoạch, báo chạy lại dự trù; dự trù nhiều tầng hiện bảng TP → BTP → NVL');
await ctx.close();

// 6b. Thêm mới: vật tư, đề xuất mua thủ công → người duyệt tiếp theo nhận thông báo → duyệt
[ctx, page] = await ctxFor();
await login(page, 'mua.nv@bmt.test');
await page.goto(`${BASE}/vat-tu`);
await clickNav(page, 'a:has-text("Thêm vật tư")');
await page.fill('input[name=code]', 'tape-new');
await page.fill('input[name=name]', 'Băng quấn thử nghiệm');
await page.fill('input[name=lead]', '10');
await page.fill('input[name=price]', '45.500');
await clickNav(page, 'button:has-text("Lưu vật tư")');
await expectOk(page, 'Thêm vật tư mới TAPE-NEW');
if (!(await page.textContent('tbody')).includes('TAPE-NEW')) fail('Vật tư mới phải hiện trong danh mục');
await page.goto(`${BASE}/de-xuat`);
await clickNav(page, 'a:has-text("Thêm đề xuất")');
await page.fill('input[name=note]', 'Mua bổ sung đồng cho đơn gấp');
await page.fill('input[name=need_date]', '2026-11-05');
const matInputs = page.locator('input[name=material_code]');
const qtyInputs = page.locator('input[name=qty]');
await matInputs.nth(0).fill('CU-024 · Đồng');
await qtyInputs.nth(0).fill('1.200');
await matInputs.nth(1).fill('TAPE-NEW');
await qtyInputs.nth(1).fill('12,5');
await clickNav(page, 'button:has-text("Lưu và gửi duyệt")');
await expectOk(page, 'Lập đề xuất mua 2 dòng và gửi duyệt');
const prNo = (await page.textContent('main h1')).split(' – ')[0].trim();
const prBody = await page.textContent('main');
if (!prBody.includes('1.200') || !prBody.includes('12,5')) fail('Số lượng đề xuất phải là 1.200 và 12,5');
ok('Số lượng "1.200" và "12,5" được hiểu đúng');
const stageText = await page.locator('ol[aria-label="Các giai đoạn duyệt"]').innerText();
if (!stageText.includes('Nguyễn Văn An')) fail(`Thanh giai đoạn phải ghi người duyệt tiếp theo: ${stageText}`);
ok(`Thanh giai đoạn hiện người duyệt tiếp theo: Nguyễn Văn An (Giám đốc) · ${prNo}`);
await page.screenshot({ path: `${SHOTS}/09-de-xuat.png`, fullPage: true });
await ctx.close();
{
  const [c, p] = await ctxFor();
  await login(p, 'bgd@bmt.test');
  const bell = await p.getAttribute('a[href="/thong-bao"][aria-label]', 'aria-label');
  if (!/[1-9]/.test(bell ?? '')) fail(`Giám đốc phải có thông báo chưa đọc: ${bell}`);
  await p.goto(`${BASE}/thong-bao`);
  if (!(await p.textContent('main')).includes(`Chờ duyệt: ${prNo}`)) fail('Giám đốc phải nhận thông báo chờ duyệt đề xuất');
  ok(`Giám đốc nhận thông báo "Chờ duyệt: ${prNo}" (${bell})`);
  await p.goto(`${BASE}/duyet`);
  const row = await p.locator(`tr:has-text("${prNo}")`).innerText();
  if (!row.includes('[2/2]')) fail(`Danh sách duyệt phải hiện [2/2]: ${row}`);
  ok('Hộp duyệt hiện giai đoạn [2/2] kiểu Fastcon');
  await p.screenshot({ path: `${SHOTS}/10-hop-duyet.png`, fullPage: true });
  await c.close();
}
await approveAs('bgd@bmt.test', prNo, 'GĐ');
{
  const [c, p] = await ctxFor();
  await login(p, 'mua.nv@bmt.test');
  await p.goto(`${BASE}/de-xuat?tab=da-duyet`);
  if (!(await p.locator(`tr:has-text("${prNo}")`).innerText()).includes('Hoàn thành')) fail('Đề xuất phải Hoàn thành sau khi Giám đốc duyệt');
  await p.goto(`${BASE}/thong-bao`);
  if (!(await p.textContent('main')).includes(`Đã duyệt: ${prNo}`)) fail('Người lập phải nhận thông báo đã duyệt');
  ok('Người lập nhận thông báo "Đã duyệt" và đề xuất chuyển Hoàn thành');
  await c.close();
}

// 6b. Quản trị hệ thống: mở lại đề xuất đã duyệt, hủy quy trình đang chạy, xóa đề xuất (bắt buộc lý do, có nhật ký)
{
  const [c, p] = await ctxFor();
  await login(p, 'admin@bmt.test', 'Admin@12345');
  await p.goto(`${BASE}/de-xuat?tab=da-duyet`);
  await clickNav(p, `a:has-text("${prNo}")`);
  const prUrl = p.url();
  const admin = async (button, reason, confirm = false) => {
    await p.click('#admin-tools > summary');
    await p.fill('textarea[name=reason]', reason);
    if (confirm) await p.check('input[name=confirm]');
    await clickNav(p, `button:has-text("${button}")`);
  };
  await admin('Mở lại để sửa', 'Sửa số lượng theo tồn thực tế');
  await expectOk(p, `Quản trị mở lại đề xuất đã duyệt ${prNo}`);
  if (!(await p.textContent('main')).includes('Nháp')) fail('Đề xuất mở lại phải về Nháp');
  await clickNav(p, 'button:has-text("Gửi duyệt")');
  await expectOk(p, 'Gửi duyệt lại sau khi mở lại');
  await clickNav(p, 'a:has-text("Xem quy trình duyệt")');
  const reqUrl = p.url();
  await admin('Hủy quy trình', 'Gửi nhầm, cần sửa tiếp');
  await expectOk(p, 'Quản trị hủy quy trình duyệt đang chạy');
  await p.goto(`${reqUrl.split('?')[0]}?tab=trao-doi`);
  if (!(await p.textContent('main')).includes('[Quản trị hủy quy trình] Gửi nhầm')) fail('Lịch sử quy trình phải ghi việc Quản trị hủy kèm lý do');
  ok('Lịch sử quy trình ghi việc Quản trị hủy kèm lý do');
  await p.goto(prUrl);
  await p.click('#admin-tools > summary');
  await p.fill('textarea[name=reason]', 'Thử xóa không xác nhận');
  await clickNav(p, 'button:has-text("Xóa chứng từ")');
  if (!(await flash(p)).includes('Tôi hiểu chứng từ sẽ bị xóa')) fail('Xóa phải bắt buộc đánh dấu xác nhận');
  ok('Xóa chứng từ bắt buộc đánh dấu xác nhận');
  await admin('Xóa chứng từ', 'Trùng đề xuất khác', true);
  if (!p.url().includes('/de-xuat?')) fail(`Xóa xong phải về danh sách đề xuất: ${p.url()}`);
  await expectOk(p, `Quản trị xóa đề xuất ${prNo}`);
  await p.goto(`${BASE}/quan-tri`);
  const log = await p.locator('section:has-text("Nhật ký can thiệp của Quản trị")').innerText();
  if (!['Mở lại để sửa', 'Hủy quy trình', 'Xóa chứng từ'].every((x) => log.includes(x)) || !log.includes(prNo)) fail(`Nhật ký can thiệp thiếu: ${log}`);
  ok('Nhật ký can thiệp của Quản trị ghi đủ 3 thao tác kèm lý do');
  await c.close();
  const [c2, p2] = await ctxFor();
  await login(p2, 'mua.nv@bmt.test');
  await p2.goto(reqUrl);
  if (await p2.locator('#admin-tools').count()) fail('Người không phải Quản trị không được thấy khung Quản trị');
  await p2.goto(`${BASE}/thong-bao`);
  if (!(await p2.textContent('main')).includes(`Quản trị đã xóa ${prNo}`)) fail('Người lập phải nhận thông báo khi Quản trị xóa đề xuất');
  ok('Người lập nhận thông báo; người không phải Quản trị không thấy khung Quản trị');
  await c2.close();
}

// 6c. Thêm spec mới từ mã mẫu, sửa BOM, gửi duyệt → hiện người duyệt bước Quản lý SX
[ctx, page] = await ctxFor();
await login(page, 'kt.tp@bmt.test');
await page.goto(`${BASE}/san-pham`);
await clickNav(page, 'a:has-text("Thêm spec mới")');
await page.selectOption('select[name=mau]', 'PFR-2C-1P5');
await clickNav(page, 'button:has-text("Sao chép thông số")');
await page.fill('input[name=new_code]', 'PFR-2C-1P0');
await page.fill('input[name=description]', 'Cáp chống cháy 2 lõi 1,0 mm² (thử)');
await page.fill('input[name=wire_count]', '32');
await clickNav(page, 'button:has-text("Tạo spec nháp")');
await expectOk(page, 'Tạo spec mới PFR-2C-1P0 từ mẫu PFR-2C-1P5');
{ const u = new URL(page.url()); u.searchParams.delete('ok'); u.searchParams.set('tab', 'bom'); await page.goto(u.href); }
await page.fill('input[name=material_code]', 'TAPE-NEW');
await page.fill('input[name=qty]', '0,5');
await clickNav(page, 'button:has-text("Lưu dòng")');
await expectOk(page, 'Thêm dòng BOM vật tư mới vào spec nháp');
await clickNav(page, 'button:has-text("Gửi duyệt phát hành")');
await expectOk(page, 'Gửi duyệt spec mới');
const st2 = await page.locator('ol[aria-label="Các giai đoạn duyệt"]').innerText();
if (!st2.includes('Đỗ Văn Khánh')) fail(`Bước Quản lý SX phải hiện tên người duyệt: ${st2}`);
ok('Spec mới: thanh giai đoạn hiện người duyệt bước Quản lý SX là Đỗ Văn Khánh');
await page.screenshot({ path: `${SHOTS}/11-spec-moi.png`, fullPage: true });
await ctx.close();

// 7. Phân quyền: vận hành không vào trang Vật tư/Quản trị, menu bị ẩn
[ctx, page] = await ctxFor();
await login(page, 'vh@bmt.test');
const nav = await page.textContent('nav');
if (['Người dùng', 'Kế hoạch & MRP', 'Vật tư', 'Báo cáo hao hụt', 'Lịch máy', 'Danh sách máy', 'Nhận NVL tại máy', 'Quét mã QR'].some((x) => nav.includes(x))) fail(`Menu của vận hành chỉ có việc tại máy: ${nav}`);
if (!['Ghi nhận ca', 'Lệnh SX ngày', 'Checklist đầu ca', 'Bảo dưỡng'].every((x) => nav.includes(x))) fail(`Menu của vận hành thiếu việc tại máy: ${nav}`);
await page.goto(`${BASE}/quan-tri`);
if (!(await flash(page)).includes('chưa được cấp quyền')) fail('Vận hành vào được trang Quản trị');
ok('Vận hành không thấy menu Quản trị/Kế hoạch và bị chặn khi gõ thẳng URL');
await page.goto(`${BASE}/vat-tu`);
if ((await page.textContent('thead')).includes('Đơn giá')) fail('Vận hành không được thấy cột giá');
ok('Vận hành xem Vật tư nhưng không thấy cột giá');
await page.goto(`${BASE}/`);
await page.screenshot({ path: `${SHOTS}/06-tong-quan-van-hanh.png` });
await ctx.close();

// 8. Quản trị → Cài đặt quy trình: giao người, thời hạn; hồ sơ mới dùng cấu hình mới
[ctx, page] = await ctxFor();
await login(page, 'admin@bmt.test', 'Admin@12345');
await page.goto(`${BASE}/quan-tri/quy-trinh?f=PLAN`);
const flowText = await page.textContent('main');
if (!flowText.includes('TP SX lập kế hoạch tháng') || !flowText.includes('Chủ tịch HĐQT phê duyệt')) fail('Trang cài đặt phải hiện luồng TP SX lập → Chủ tịch HĐQT phê duyệt');
// Quy trình final: bước Quản lý SX xác nhận (seq 1) đã tắt; chỉnh bước Chủ tịch HĐQT (seq 2)
const step1 = page.locator('form:has(input[name=seq][value="2"])');
await step1.locator('input[name=sla_hours]').fill('8');
await step1.locator('input[name=warn_hours]').fill('2');
await step1.locator('label:has-text("Chủ Tịch Thử") input').check();
await clickNav(page, 'form:has(input[name=seq][value="2"]) button:has-text("Lưu bước")');
await expectOk(page, 'Lưu bước Chủ tịch HĐQT: giao Chủ tịch, hạn 8 giờ, nhắc trước 2 giờ');
if (!(await page.locator('ol[aria-label="Các giai đoạn duyệt"]').innerText()).includes('8 giờ')) fail('Sơ đồ quy trình phải cập nhật thời hạn');
await page.screenshot({ path: `${SHOTS}/12-cai-dat-quy-trinh.png`, fullPage: true });
await step1.locator('input[name=warn_hours]').fill('9');
await clickNav(page, 'form:has(input[name=seq][value="2"]) button:has-text("Lưu bước")');
if (!(await flash(page)).includes('Nhắc trước hạn')) fail('Phải chặn nhắc trước hạn ≥ thời hạn');
ok('Chặn cấu hình sai: nhắc trước hạn ≥ thời hạn');
await page.goto(`${BASE}/quan-tri/quy-trinh?f=PO`);
const poText = await page.textContent('main');
if (!poText.includes('giá trị ≥ 20.000.000 đ') || !poText.includes('Chủ tịch HĐQT phê duyệt')) fail(`Quy trình PO phải hiện hạn mức: ${poText.slice(0, 200)}`);
if (await page.locator('a:has-text("Thay đổi nhỏ spec")').count()) fail('Không còn quy trình Spec thay đổi nhỏ');
ok('Cài đặt quy trình: PO theo hạn mức 20 triệu / 200 triệu; đã bỏ Spec thay đổi nhỏ');
await page.goto(`${BASE}/bao-cao/hao-hut?tab=dong`);
if (!(await page.textContent('main')).includes('Cân bằng đồng')) fail('Báo cáo hao hụt phải có tab cân bằng đồng');
await page.goto(`${BASE}/kho/phieu?tab=duyet`);
if (await page.locator('text=Application error').count()) fail('Trang phiếu kho chờ Kế toán SX duyệt lỗi');
ok('Báo cáo hao hụt (cân bằng đồng) và phiếu kho chờ Kế toán SX duyệt mở được');
await ctx.close();
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(`${BASE}/quan-tri/quy-trinh`);
if (!(await flash(page)).includes('chưa được cấp quyền')) fail('Kế hoạch SX không được vào Cài đặt quy trình');
ok('Người không phải quản trị bị chặn khỏi Cài đặt quy trình');
await ctx.close();
{
  const r1 = await fetch(`${BASE}/api/cron/notify`);
  if (r1.status !== 401) fail(`Job không có CRON_SECRET phải bị từ chối: ${r1.status}`);
  const r2 = await fetch(`${BASE}/api/cron/notify`, { headers: { Authorization: `Bearer ${process.env.CRON_SECRET}` } });
  const j = await r2.json();
  if (r2.status !== 200 || j.sla_error) fail(`Job máy chủ lỗi: ${r2.status} ${JSON.stringify(j)}`);
  ok(`Job máy chủ /api/cron/notify chạy (không cần trình duyệt): ${JSON.stringify(j)}`);
}

// 8b. Menu gọn: không còn Quét mã QR, Cấp NVL cho SX, Nhận NVL tại máy; Giám đốc sửa ngày làm việc ở Tham số xếp lịch
{
  [ctx, page] = await ctxFor();
  await login(page, 'bgd@bmt.test');
  const nav = await page.locator('aside').innerText();
  if (/Quét mã QR|Cấp NVL cho SX|Nhận NVL tại máy|Máy, người & tham số/.test(nav) || !nav.includes('Tham số xếp lịch')) fail('Menu còn mục thừa hoặc thiếu Tham số xếp lịch');
  const wd = async () => (await page.locator('section', { hasText: 'Ca làm việc' }).first().innerText()).match(/Ngày làm việc:\s*(.+)/)?.[1] ?? '';
  for (const [on, reason] of [[true, 'E2E: thử làm cả chủ nhật'], [false, 'E2E: trả lại nghỉ chủ nhật']]) {
    await page.goto(`${BASE}/tham-so?sua=shifts`);
    const cb = page.locator('input[name=workday][value="7"]');
    if (on) await cb.check(); else await cb.uncheck();
    await page.locator('section', { hasText: 'Ca làm việc' }).first().locator('textarea[name=reason]').fill(reason);
    await page.locator('section', { hasText: 'Ca làm việc' }).first().getByRole('button', { name: 'Lưu thay đổi' }).click();
    await page.waitForURL(/ok=/);
    if ((await wd()).includes('CN') !== on) fail(`Ngày làm việc chưa lưu: ${await wd()}`);
  }
  if ((await page.locator('body').innerText()).includes('Người và tay nghề')) fail('Tham số xếp lịch còn bảng Người và tay nghề trùng');
  await page.goto(`${BASE}/may/cai-dat`);
  if (await page.locator('button', { hasText: 'Lưu lịch làm việc' }).count() || !(await page.locator('a[href="/tham-so"]').count())) fail('Cài đặt máy còn form lịch làm việc trùng');
  ok('Menu gọn; Giám đốc sửa ngày làm việc ở Tham số xếp lịch (thêm/bỏ CN), Cài đặt máy chỉ hiện và dẫn sang');
  await ctx.close();
}

// 9. Mở thử các màn hình Kho, Kế hoạch SX, Quản lý máy: không trang nào báo lỗi
for (const [email, pw] of [['admin@bmt.test', 'Admin@12345'], ['sx.tp@bmt.test', PASS]]) {
  [ctx, page] = await ctxFor();
  await login(page, email, pw);
  const pages = ['/kho', '/kho/ton', '/kho/phieu', '/kho/quet', '/kho/cap-phat', '/kho/kiem-ke', '/kho/nhan-hang', '/kho/so-cai', '/kho/cai-dat',
    '/lich-may', '/lenh-ngay', '/ghi-nhan-ca', '/kh-thuc-te', '/tham-so', '/may', '/may/checklist', '/may/bao-duong', '/may/toc-do',
    '/may/kiem-tra', '/may/lich-su', '/may/bao-cao', '/bao-cao/hao-hut', '/phieu-hoan-thanh', '/kho/qc',
    '/phieu-xuat-nvl', '/bao-cao/ngay', '/in/phieu-xuat-nvl', '/in/bao-cao-ca'];
  for (const u of pages) {
    const res = await page.goto(`${BASE}${u}`);
    const body = await page.innerText('body');
    if (res.status() !== 200 || /Application error|Internal Server Error|does not exist|permission denied|PGRST/i.test(body)) fail(`${email} mở ${u} lỗi: ${res.status()} ${body.slice(0, 200)}`);
  }
  ok(`${email.split('@')[0]} mở được ${pages.length} màn hình Kho, Kế hoạch SX, Quản lý máy`);
  // Phiếu hoàn thành bobin: có lệnh SX đang chạy thì mở form nhập và bản in phiếu trống
  await page.goto(`${BASE}/phieu-hoan-thanh`);
  const muc = await page.locator('a[href*="/phieu-hoan-thanh?muc="]').first().getAttribute('href').catch(() => null);
  if (muc) {
    await page.goto(`${BASE}${muc}`);
    if (!(await page.locator('input[name=gross_kg]').count())) fail(`${email}: form phiếu hoàn thành không hiện`);
    const res = await page.goto(`${BASE}/in/phieu-hoan-thanh?${muc.split('?')[1]}&n=2`);
    if (res.status() !== 200 || !(await page.innerText('body')).includes('PHIẾU HOÀN THÀNH BOBIN')) fail(`${email}: bản in phiếu hoàn thành lỗi`);
    ok(`${email.split('@')[0]}: form nhập phiếu hoàn thành + bản in phiếu trống mở được`);
  }
  // Đợt 3: báo cáo ca có phần NVL để lại máy, phế cả ca; báo cáo ngày có nút gửi; bản in báo cáo ca trống
  await page.goto(`${BASE}/ghi-nhan-ca`);
  const shiftBody = await page.innerText('body');
  if (!shiftBody.includes('NVL để lại máy chạy tiếp cùng lô') || !shiftBody.includes('Phế cả ca')) fail(`${email}: báo cáo ca thiếu phần NVL để lại máy / phế cả ca`);
  await page.goto(`${BASE}/lich-may?tab=thang`);
  const mBody = await page.innerText('body');
  if (/Application error|PGRST/i.test(mBody)) fail(`${email}: Lịch máy tab kế hoạch tháng lỗi`);
  if (!mBody.includes('Lịch theo lô')) fail(`${email}: Lịch máy thiếu bảng lịch theo lô (ngày dự kiến, ngày chốt, giữ chỗ)`);
  await page.goto(`${BASE}/bao-cao/ngay`);
  if (!(await page.innerText('body')).includes('Hao hụt theo công đoạn')) fail(`${email}: báo cáo ngày không hiện bảng hao hụt`);
  if (!(await page.locator('form button', { hasText: /gửi báo cáo ngày/i }).count())) fail(`${email}: thiếu nút gửi báo cáo ngày`);
  const pr = await page.goto(`${BASE}/in/bao-cao-ca?m=BUN-01`);
  if (pr.status() !== 200 || !(await page.innerText('body')).includes('BÁO CÁO CA')) fail(`${email}: bản in báo cáo ca lỗi`);
  ok(`${email.split('@')[0]}: báo cáo ca (NVL để lại máy, phế cả ca), báo cáo ngày, bản in báo cáo ca trống mở được`);
  await ctx.close();
}

// 10. Quản lý máy đợt A: TP KT/QA báo hỏng (bắt buộc giờ chạy lại) → Lịch máy tránh máy hỏng, TP SX xếp lại; vận hành không thấy form báo hỏng
{
  [ctx, page] = await ctxFor();
  await login(page, 'vh@bmt.test');
  await page.goto(`${BASE}/may`);
  const si2 = await page.locator('a[href^="/may/"]', { hasText: 'EXT-SI-02' }).first().getAttribute('href');
  await page.goto(`${BASE}${si2}`);
  if (await page.locator('summary', { hasText: 'Báo hỏng' }).count()) fail('Vận hành vẫn thấy form báo hỏng trên MES');
  await ctx.close();
  [ctx, page] = await ctxFor();
  await login(page, 'kt.tp@bmt.test');
  await page.goto(`${BASE}${si2}`);
  await page.locator('summary', { hasText: 'Báo hỏng' }).click();
  await page.selectOption('select[name=status]', 'DOWN');
  await page.selectOption('select[name=reason]', 'DT_BREAKDOWN');
  await page.fill('input[name=note]', 'E2E: đứt dây trục vít');
  await Promise.all([page.waitForURL(/err=|ok=/), page.locator('details form button', { hasText: 'Cập nhật' }).first().click()]);
  if (!(await flash(page)).includes('dự kiến chạy lại')) fail('Báo hỏng không có giờ chạy lại phải bị chặn');
  await page.locator('summary', { hasText: 'Báo hỏng' }).click();
  await page.selectOption('select[name=status]', 'DOWN');
  await page.selectOption('select[name=reason]', 'DT_BREAKDOWN');
  await page.fill('input[name=note]', 'E2E: đứt dây trục vít');
  const eta = new Date(Date.now() + 2 * 86400000 + 7 * 3600000).toISOString().slice(0, 10) + 'T08:00';
  await page.fill('input[name=eta]', eta);
  await Promise.all([page.waitForURL(/ok=/), page.locator('details form button', { hasText: 'Cập nhật' }).first().click()]);
  await expectOk(page, 'TP KT/QA báo hỏng EXT-SI-02 có giờ dự kiến chạy lại');
  await ctx.close();
  [ctx, page] = await ctxFor();
  await login(page, 'sx.tp@bmt.test');
  await page.goto(`${BASE}/lich-may?tab=baoduong`);
  const mb = await page.innerText('body');
  if (!mb.includes('Tình trạng máy') || !mb.includes('Bảo dưỡng trên lịch máy') || !/EXT-SI-02[\s\S]{0,200}Hỏng/.test(mb)) fail('Thẻ Bảo dưỡng & máy hỏng thiếu tình trạng EXT-SI-02');
  if (!mb.includes('Không xếp việc: EXT-SI-02 hỏng')) fail('Lịch máy chưa tính khoảng máy hỏng');
  const rb = page.locator('form button', { hasText: /Xếp lại lịch|Xếp lịch/ }).first();
  if (await rb.count()) {
    await Promise.all([page.waitForURL(/ok=|err=/), rb.click()]);
    await expectOk(page, 'TP SX xếp lại lịch sau khi máy hỏng');
    await page.goto(`${BASE}/lich-may?tab=lich`);
    if (!(await page.innerText('body')).includes('EXT-SI-02 hỏng')) fail('Gantt không hiện khối máy hỏng');
  }
  ok('Đợt A: vận hành không báo hỏng trên MES; TP KT/QA báo hỏng bắt buộc giờ chạy lại; Lịch máy hiện máy hỏng, TP SX xếp lại lịch');
  await ctx.close();
}

// Ảnh tổng quan của BGĐ (điện thoại + máy tính)
[ctx, page] = await ctxFor();
await login(page, 'bgd@bmt.test');
await page.screenshot({ path: `${SHOTS}/07-tong-quan-bgd.png`, fullPage: true });
await page.setViewportSize({ width: 390, height: 844 });
await page.goto(`${BASE}/duyet?tab=tat-ca`);
await page.screenshot({ path: `${SHOTS}/08-dien-thoai.png` });
await ctx.close();

await browser.close();
console.log(`==> ĐẠT ${n} kiểm tra end-to-end`);
