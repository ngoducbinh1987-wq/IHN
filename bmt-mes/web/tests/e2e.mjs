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

// 4. TP Kỹ thuật/QA gửi duyệt spec PFR-2C-1p5; SFR-2P-1 (Rdc vượt) không có nút gửi hợp lệ
[ctx, page] = await ctxFor();
await login(page, 'kt.tp@bmt.test');
await page.goto(`${BASE}/san-pham/SFR-2P-1`);
if (!(await page.textContent('body')).includes('Chưa đủ điều kiện phát hành')) fail('SFR-2P-1 phải báo chưa đủ điều kiện');
await clickNav(page, 'button:has-text("Gửi duyệt phát hành")');
ok(`SFR-2P-1 bị chặn gửi duyệt → ${(await flash(page)).slice(0, 90)}…`);
await page.goto(`${BASE}/san-pham/PFR-2C-1p5`);
await clickNav(page, 'button:has-text("Gửi duyệt phát hành")');
await expectOk(page, 'TP KT/QA gửi duyệt spec PFR-2C-1p5');
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
await approveAs('sx.tp@bmt.test', 'SPEC PFR-2C-1p5', 'reject-empty');
await approveAs('sx.tp@bmt.test', 'SPEC PFR-2C-1p5', 'QL SX');
await approveAs('bgd@bmt.test', 'SPEC PFR-2C-1p5', 'GĐ');
[ctx, page] = await ctxFor();
await login(page, 'kt.nv@bmt.test');
await page.goto(`${BASE}/san-pham/PFR-2C-1p5`);
if (!(await page.textContent('main aside')).includes('Đã phát hành')) fail('Spec phải ở trạng thái Đã phát hành');
ok('Spec PFR-2C-1p5 Đã phát hành sau 2 cấp duyệt (Quản lý SX → Giám đốc)');
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
const row305 = await page.locator('tr:has-text("PFR-2C-1p5")').first().innerText();
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
if (await page.locator('button:has-text("Gửi duyệt kế hoạch")').count()) fail('Chỉ Giám đốc thấy nút gửi duyệt kế hoạch tháng');
ok('Chạy lại MRP: hết cảnh báo; Kế hoạch SX không thấy nút gửi duyệt (chỉ Giám đốc)');
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
await login(page, 'bgd@bmt.test');
await page.goto(planUrl);
await clickNav(page, 'button:has-text("Gửi duyệt kế hoạch")');
await expectOk(page, 'Giám đốc gửi duyệt kế hoạch tháng');
await ctx.close();
await approveAs('sx.tp@bmt.test', planNo, 'QL SX');
await approveAs('ct@bmt.test', planNo, 'Chủ tịch HĐQT');
{
  const [c, p] = await ctxFor();
  await login(p, 'bgd@bmt.test');
  await p.goto(planUrl);
  const cells = await p.locator('tr:has-text("CU-024") td').allInnerTexts();
  if (cells[11] !== '26.800.000') fail(`BGĐ phải thấy thành tiền CU-024 = 26.800.000: ${cells.join(' | ')}`);
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
if (!(await page.locator('tr:has-text("CU-024")').first().innerText()).includes('120')) fail('PR phải dùng số đã điều chỉnh 120 kg');
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

// 6c. Thêm spec mới từ mã mẫu, sửa BOM, gửi duyệt → hiện người duyệt bước Quản lý SX
[ctx, page] = await ctxFor();
await login(page, 'kt.tp@bmt.test');
await page.goto(`${BASE}/san-pham`);
await clickNav(page, 'a:has-text("Thêm spec mới")');
await page.selectOption('select[name=mau]', 'PFR-2C-1p5');
await clickNav(page, 'button:has-text("Sao chép thông số")');
await page.fill('input[name=new_code]', 'PFR-2C-1p0');
await page.fill('input[name=description]', 'Cáp chống cháy 2 lõi 1,0 mm² (thử)');
await page.fill('input[name=wire_count]', '32');
await clickNav(page, 'button:has-text("Tạo spec nháp")');
await expectOk(page, 'Tạo spec mới PFR-2C-1p0 từ mẫu PFR-2C-1p5');
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

// 8. Quản trị → Cài đặt quy trình: giao người, thời hạn; hồ sơ mới dùng cấu hình mới
[ctx, page] = await ctxFor();
await login(page, 'admin@bmt.test', 'Admin@12345');
await page.goto(`${BASE}/quan-tri/quy-trinh?f=PLAN`);
const flowText = await page.textContent('main');
if (!flowText.includes('Giám đốc lập kế hoạch') || !flowText.includes('Chủ tịch HĐQT phê duyệt')) fail('Trang cài đặt phải hiện luồng Giám đốc lập → Quản lý SX xác nhận → Chủ tịch HĐQT phê duyệt');
const step1 = page.locator('form:has(input[name=seq][value="1"])');
await step1.locator('input[name=sla_hours]').fill('8');
await step1.locator('input[name=warn_hours]').fill('2');
await step1.locator('label:has-text("Đỗ Văn Khánh") input').check();
await clickNav(page, 'form:has(input[name=seq][value="1"]) button:has-text("Lưu bước")');
await expectOk(page, 'Lưu bước Duyệt: giao Đỗ Văn Khánh, hạn 8 giờ, nhắc trước 2 giờ');
if (!(await page.locator('ol[aria-label="Các giai đoạn duyệt"]').innerText()).includes('8 giờ')) fail('Sơ đồ quy trình phải cập nhật thời hạn');
await page.screenshot({ path: `${SHOTS}/12-cai-dat-quy-trinh.png`, fullPage: true });
await step1.locator('input[name=warn_hours]').fill('9');
await clickNav(page, 'form:has(input[name=seq][value="1"]) button:has-text("Lưu bước")');
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
