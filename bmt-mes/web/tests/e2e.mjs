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

// 6. Kế hoạch: tạo, thêm dòng, chạy MRP; TP SX gửi duyệt → Giám đốc duyệt → Chủ tịch HĐQT chỉnh, chốt; sinh PR
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(`${BASE}/ke-hoach/moi`);
await page.selectOption('select[name=month]', '11');
await page.selectOption('select[name=year]', String(new Date().getFullYear()));
if (await page.locator('input[name=mode]').count()) fail('Thêm kế hoạch: không còn chế độ sơ bộ');
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
// 27/10/2026: người lập kế hoạch sửa được bảng MRP – đề nghị mua khi kế hoạch còn nháp (migration 4400)
if (!(await page.locator('tr:has-text("CU-024") a[title="Điều chỉnh"]').count())) fail('Kế hoạch SX (người lập) phải thấy nút điều chỉnh MRP khi kế hoạch nháp');
ok('Người lập kế hoạch thấy nút điều chỉnh đề nghị mua khi kế hoạch còn nháp');
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
if (!(await flash(page)).includes('Giám đốc')) fail('Gửi duyệt kế hoạch tháng phải báo chuyển Giám đốc duyệt');
await ctx.close();
await approveAs('bgd@bmt.test', planNo, 'Giám đốc');
// Bước Chủ tịch chốt: sửa dòng có lý do (MRP tự chạy lại), không bỏ được mã cuối cùng, rồi Chốt kế hoạch ngay trên trang kế hoạch
[ctx, page] = await ctxFor();
await login(page, 'ct@bmt.test');
await page.goto(planUrl);
if (!(await page.locator('#chair-turn').count())) fail('Chủ tịch ở bước chốt phải thấy khung chỉnh và nút Chốt kế hoạch');
await clickNav(page, 'a[title="Sửa dòng"]');
if (!(await page.locator('select[name=product_id]').isDisabled())) fail('Chủ tịch không đổi mã của dòng có sẵn');
await page.fill('input[name=reason]', 'Khách đặt nhãn HEIZKA');
await clickNav(page, 'button:has-text("Bỏ mã")');
if (!(await flash(page)).includes('ít nhất một mã')) fail(`Bỏ mã cuối cùng phải bị chặn: ${await flash(page)}`);
await clickNav(page, 'a[title="Sửa dòng"]');
await page.selectOption('select[name=brand]', 'HEIZKA');
await page.fill('input[name=reason]', 'Khách đặt nhãn HEIZKA');
await clickNav(page, 'form:has(input[name=reason]) button:has-text("Lưu")');
await expectOk(page, 'Chủ tịch sửa dòng ở bước chốt');
if (!(await page.textContent('#chair-edits')).includes('Khách đặt nhãn HEIZKA') || await page.locator('#mrp-stale').count()) {
  fail('Sửa của Chủ tịch phải ghi lịch sử, MRP đã chạy lại');
}
await clickNav(page, '#chair-turn button:has-text("Chốt kế hoạch")');
await expectOk(page, 'Chủ tịch chốt kế hoạch tháng');
await ctx.close();
ok('Kế hoạch tháng: TP SX lập → Giám đốc duyệt → Chủ tịch sửa (lý do, lịch sử, MRP chạy lại) và chốt');
{
  const [c, p] = await ctxFor();
  await login(p, 'bgd@bmt.test');
  await p.goto(planUrl);
  const cells = await p.locator('tr:has-text("CU-024") td').allInnerTexts();
  if (cells[14] !== '26.800.000') fail(`BGĐ phải thấy thành tiền CU-024 = 26.800.000: ${cells.join(' | ')}`);
  ok('BGĐ thấy thành tiền CU-024 = 100 kg × 268.000 = 26.800.000 đ');
  await c.close();
}
// 6a'. Chủ tịch chốt → MES tự sinh đơn mua từ MRP; NV mua kiểm tra (NCC, sửa số, giá), duyệt gửi → TP Mua → Giám đốc; MRP khóa
let poUrl = null;
let poNo = '';
{
  const [c, p] = await ctxFor();
  await login(p, 'mua.nv@bmt.test');
  await p.goto(planUrl);
  const hrefs = await p.locator('#don-mua a[href^="/don-mua/"]').evaluateAll((as) => as.map((x) => x.getAttribute('href')));
  if (!hrefs.length) fail('Chủ tịch chốt kế hoạch: MES phải tự sinh đơn mua (khung Đơn mua hàng theo kế hoạch)');
  if (await p.locator('button:has-text("Sinh đề xuất mua (PR)")').count()) fail('Không còn nút sinh đề xuất mua (PR) từ kế hoạch');
  for (const h of hrefs) {
    await p.goto(`${BASE}${h}`);
    if ((await p.textContent('main')).includes('CU-024')) { poUrl = `${BASE}${h}`; break; }
  }
  if (!poUrl) fail('Không thấy đơn mua tự sinh có CU-024');
  ok(`MES tự sinh ${hrefs.length} đơn mua nháp từ MRP khi Chủ tịch chốt kế hoạch`);
  if (!(await p.locator('#buyer-check').count())) fail('Đơn nháp phải nhắc NV mua kiểm tra trước khi gửi');
  if ((await p.inputValue('select[name=supplier_id]')) === '') {
    await p.click('summary:has-text("Thêm nhà cung cấp mới")');
    await p.fill('form:has(input[name=tax_code]) input[name=name]', 'NCC đồng thử E2E');
    await clickNav(p, 'button:has-text("Thêm và chọn cho đơn này")');
    await expectOk(p, 'NV mua thêm NCC mới ngay trên đơn mua');
  }
  await p.fill('tr:has-text("CU-024") input[name=qty]', '120');
  await p.fill('tr:has-text("CU-024") input[name=unit_price]', '268.000');
  await clickNav(p, 'tr:has-text("CU-024") button:has-text("Lưu")');
  await expectOk(p, 'NV mua sửa CU-024 100 → 120 kg, giá 268.000 trên đơn mua');
  const cuRow = await p.locator('tr:has-text("CU-024")').first().innerText();
  if (!cuRow.includes('MES đề nghị 100')) fail(`Dòng đơn mua phải hiện số MES đề nghị: ${cuRow}`);
  for (let i = 0; i < 40; i++) {
    await p.goto(poUrl);
    const empty = p.locator('tr:has(input[name=unit_price][value=""])').first();
    if (!(await empty.count())) break;
    await empty.locator('input[name=unit_price]').fill('1.000');
    await clickNav(p, 'tr:has(input[name=unit_price][value=""]) button:has-text("Lưu")');
  }
  await p.goto(poUrl);
  await clickNav(p, 'button:has-text("Duyệt, gửi TP Mua")');
  await expectOk(p, 'NV mua duyệt, gửi TP Mua');
  poNo = (await p.textContent('main h1')).split(' – ')[0].trim();
  await p.screenshot({ path: `${SHOTS}/05b-don-mua.png`, fullPage: true });
  await c.close();
}
await approveAs('mua.tp@bmt.test', poNo, 'TP Mua');
await approveAs('bgd@bmt.test', poNo, 'Giám đốc');
{
  const [c, p] = await ctxFor();
  await login(p, 'mua.nv@bmt.test');
  await p.goto(poUrl);
  const body = await p.textContent('main');
  if (!body.includes('Đã duyệt, chờ hàng') || !body.includes('120')) fail(`Đơn mua phải Đã duyệt với CU-024 120 kg: ${body.slice(0, 300)}`);
  ok(`Đơn mua ${poNo}: NV mua → TP Mua → Giám đốc duyệt, dùng số NV mua đã sửa (CU-024 120 kg)`);
  await p.goto(`${BASE}/don-mua?tab=cho-hang`);
  if (!(await p.textContent('main')).includes(poNo)) fail('Danh sách Đơn mua hàng phải có đơn đã duyệt chờ hàng');
  await c.close();
}
{
  const [c, p] = await ctxFor();
  await login(p, 'mua.tp@bmt.test');
  await p.goto(planUrl);
  if (await p.locator('a[title="Điều chỉnh"]').count()) fail('Đã sinh đơn mua: không còn nút điều chỉnh MRP');
  if (!(await p.textContent('main')).includes('Kết quả MRP đang khóa')) fail('Phải báo kết quả MRP đang khóa');
  ok('Đã sinh đơn mua: kết quả MRP khóa, sửa số mua trên đơn mua');
  await c.close();
}
// 6a''. Đề xuất hiệu chỉnh kế hoạch tháng: Kế hoạch SX lập (đổi sản lượng 3.500 → 4.000 m), Giám đốc → Chủ tịch HĐQT duyệt, MES áp + MRP hiệu chỉnh
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(planUrl);
await page.fill('#dieu-chinh input[name=reason]', 'Khách đặt thêm 500 m');
await Promise.all([page.waitForURL('**/ke-hoach/dieu-chinh/**'), page.click('#dieu-chinh button:has-text("Lập đề xuất hiệu chỉnh")')]);
await expectOk(page, 'Lập đề xuất hiệu chỉnh kế hoạch tháng');
const adjNo = (await page.textContent('main h1')).split(' ·')[0].trim();
await page.selectOption('select[name=kind_0]', 'QTY');
await page.selectOption('select[name=line_0]', { index: 1 });
await page.fill('input[name=qty_0]', '4.000');
await clickNav(page, 'button:has-text("Lưu nháp")');
await expectOk(page, 'Lưu nháp đề xuất hiệu chỉnh');
if (!(await page.locator('#mrp-hieu-chinh tr:has-text("CU-024")').count())) fail('Bảng MRP hiệu chỉnh (xem trước) phải có CU-024');
ok('Bảng MRP hiệu chỉnh xem trước khi gửi duyệt');
await clickNav(page, 'button:has-text("Lưu và gửi Giám đốc duyệt")');
await expectOk(page, `Gửi ${adjNo} cho Giám đốc duyệt`);
if (!(await page.textContent('main')).includes('3.500 → 4.000')) fail('Đề xuất hiệu chỉnh phải hiện 3.500 → 4.000 m');
await page.screenshot({ path: `${SHOTS}/05c-phieu-dieu-chinh.png`, fullPage: true });
await ctx.close();
await approveAs('bgd@bmt.test', adjNo, 'Giám đốc');
await approveAs('ct@bmt.test', adjNo, 'Chủ tịch HĐQT');
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(planUrl);
if (!(await page.locator('tr:has-text("PFR-2C-1P5")').first().innerText()).includes('4.000')) fail('Duyệt xong: dòng kế hoạch phải thành 4.000 m');
if (await page.locator('#mrp-stale').count()) fail('Duyệt hiệu chỉnh xong MES đã chạy MRP hiệu chỉnh: không còn báo chạy lại');
if (!(await page.textContent('main')).includes('Dự trù nhiều tầng')) fail('Trang kế hoạch phải có bảng dự trù nhiều tầng');
ok('Giám đốc → Chủ tịch duyệt đề xuất hiệu chỉnh: MES áp 4.000 m vào kế hoạch, chạy MRP hiệu chỉnh; dự trù nhiều tầng hiện bảng TP → BTP → NVL');
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
await page.selectOption('select[name=kind]', 'TOI_UU');
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
if (!prBody.includes('Mua tối ưu')) fail('NV mua lập được đề xuất mua tối ưu (loại đề xuất hiện trên phiếu)');
const stageText = await page.locator('ol[aria-label="Các giai đoạn duyệt"]').innerText();
if (!stageText.includes('Hoàng Thu Hà') || !stageText.includes('Giám đốc duyệt đề xuất mua')) fail(`Thanh giai đoạn phải ghi TP Mua duyệt trước, Giám đốc sau: ${stageText}`);
ok(`Đề xuất mua tối ưu: TP Mua (Hoàng Thu Hà) duyệt → Giám đốc duyệt · ${prNo}`);
await page.screenshot({ path: `${SHOTS}/09-de-xuat.png`, fullPage: true });
await ctx.close();
await approveAs('mua.tp@bmt.test', prNo, 'TP Mua');
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
  if (!row.includes('[3/3]')) fail(`Danh sách duyệt phải hiện [3/3] (lập → TP Mua → Giám đốc): ${row}`);
  ok('Hộp duyệt hiện giai đoạn [3/3] kiểu Fastcon (lập → TP Mua → Giám đốc)');
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

// 7. Phân quyền theo bộ phận: vận hành chỉ thấy việc tại máy + thông tin chung (kế hoạch sản xuất chung, máy, bảo dưỡng)
[ctx, page] = await ctxFor();
await login(page, 'vh@bmt.test');
const nav = await page.textContent('nav');
if (['Người dùng', 'Kế hoạch & MRP', 'Vật tư', 'Báo cáo hao hụt', 'Tồn kho', 'Phiếu kho', 'Phân quyền', 'Nhận NVL tại máy', 'Quét mã QR', 'Checklist đầu ca', 'Kiểm tra năng lực', 'Thông báo'].some((x) => nav.includes(x))) fail(`Menu của vận hành chỉ có việc tại máy và thông tin chung: ${nav}`);
if (!['Ghi nhận ca', 'Lệnh SX ngày', 'Bảo dưỡng', 'Kế hoạch sản xuất chung', 'Danh sách máy', 'Lịch máy'].every((x) => nav.includes(x))) fail(`Menu của vận hành thiếu việc tại máy / thông tin chung: ${nav}`);
await page.goto(`${BASE}/quan-tri`);
if (!(await flash(page)).includes('không thuộc bộ phận')) fail('Vận hành vào được trang Quản trị');
ok('Vận hành không thấy menu Quản trị/Kế hoạch & MRP và bị chặn khi gõ thẳng URL');
await page.goto(`${BASE}/vat-tu`);
if (!(await flash(page)).includes('không thuộc bộ phận')) fail('Vận hành vào được trang Vật tư (mục của Mua hàng, Kỹ thuật)');
ok('Vận hành bị chặn ở Vật tư (mục của bộ phận khác)');
await page.goto(`${BASE}/`);
if (!(await page.locator('#thong-tin-chung').count())) fail('Tổng quan phải có thông tin chung (sản lượng, máy, bảo dưỡng) cho mọi người');
for (const id of ['gia-tri-ton', 'gia-thanh', 'du-phong', 'qc']) {
  if (await page.locator(`#${id}`).count()) fail(`Vận hành không được thấy khối #${id} trên Tổng quan (giá, mục của bộ phận khác)`);
}
if (!(await page.locator('#so-chinh').count())) fail('Tổng quan phải có dải số chính theo quyền');
await page.goto(`${BASE}/kh-thuc-te`);
if (!(await page.textContent('main h1')).includes('Kế hoạch sản xuất chung')) fail('Vận hành phải xem được Kế hoạch sản xuất chung');
ok('Vận hành xem Tổng quan (thông tin chung) và Kế hoạch sản xuất chung');
await page.goto(`${BASE}/`);
await page.screenshot({ path: `${SHOTS}/06-tong-quan-van-hanh.png` });
await ctx.close();

// 8. Quản trị → Cài đặt quy trình: giao người, thời hạn; hồ sơ mới dùng cấu hình mới
[ctx, page] = await ctxFor();
await login(page, 'admin@bmt.test', 'Admin@12345');
await page.goto(`${BASE}/quan-tri/quy-trinh?f=PLAN`);
const flowText = await page.textContent('main');
if (!flowText.includes('TP SX lập kế hoạch tháng') || !flowText.includes('Giám đốc duyệt kế hoạch tháng') || !flowText.includes('Chủ tịch HĐQT chốt kế hoạch tháng')) {
  fail('Trang cài đặt phải hiện luồng TP SX lập → Giám đốc duyệt → Chủ tịch HĐQT chốt');
}
// Quy trình 28/10/2026: bước 1 Giám đốc duyệt, bước 2 Chủ tịch HĐQT chốt; chỉnh bước Chủ tịch HĐQT (seq 2)
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
if (poText.includes('giá trị ≥ 20.000.000') || !poText.includes('TP Mua duyệt đơn mua hàng')) fail(`Quy trình PO phải bỏ hạn mức 20/200 triệu: ${poText.slice(0, 300)}`);
if (await page.locator('a:has-text("Thay đổi nhỏ spec")').count()) fail('Không còn quy trình Spec thay đổi nhỏ');
ok('Cài đặt quy trình: PO bỏ hạn mức 20 triệu / 200 triệu (TP Mua → Giám đốc); đã bỏ Spec thay đổi nhỏ');
await page.goto(`${BASE}/bao-cao/hao-hut?tab=dong`);
if (!(await page.textContent('main')).includes('Cân bằng đồng')) fail('Báo cáo hao hụt phải có tab cân bằng đồng');
await page.goto(`${BASE}/kho/phieu?tab=duyet`);
if (await page.locator('text=Application error').count()) fail('Trang phiếu kho chờ Kế toán SX duyệt lỗi');
ok('Báo cáo hao hụt (cân bằng đồng) và phiếu kho chờ Kế toán SX duyệt mở được');
await ctx.close();
[ctx, page] = await ctxFor();
await login(page, 'sx.kh@bmt.test');
await page.goto(`${BASE}/quan-tri/quy-trinh`);
if (!(await flash(page)).includes('không thuộc bộ phận')) fail('Kế hoạch SX không được vào Cài đặt quy trình');
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
  const nav = await page.locator('aside nav').textContent();
  // Menu thu gọn theo nhóm: ở Tổng quan nhóm Sản xuất đóng, bấm tên nhóm thì thả xuống; nhóm đóng hiện tổng số việc của mục con
  const grp = page.locator('aside nav button', { hasText: 'Sản xuất' });
  if ((await grp.getAttribute('aria-expanded')) !== 'false' || await page.locator('aside nav a', { hasText: 'Lịch máy' }).isVisible()) fail('Ở Tổng quan nhóm Sản xuất phải thu gọn');
  await grp.click();
  if ((await grp.getAttribute('aria-expanded')) !== 'true' || !(await page.locator('aside nav a', { hasText: 'Lịch máy' }).isVisible())) fail('Bấm nhóm Sản xuất phải hiện các mục con');
  await grp.click();
  const sums = await page.$$eval('aside nav [data-group]', (gs) => gs.map((g) => {
    const b = g.querySelector('button'); const kids = [...g.querySelectorAll('a span.bg-bad')].reduce((s, x) => s + Number(x.textContent), 0);
    return { g: g.getAttribute('data-group'), open: b.getAttribute('aria-expanded'), head: Number(b.querySelector('span.bg-bad')?.textContent ?? 0), kids };
  }));
  const wrong = sums.filter((x) => (x.open === 'false' ? x.head !== x.kids : x.head !== 0));
  if (wrong.length) fail(`Số trên nhóm thu gọn phải bằng tổng số của mục con: ${JSON.stringify(wrong)}`);
  ok(`Menu thu gọn theo nhóm, số việc hiện ở nhóm khi đóng: ${sums.map((x) => `${x.g}${x.head ? ' ' + x.head : ''}${x.open === 'true' ? ' (mở)' : ''}`).join(', ')}`);
  await page.goto(`${BASE}/lich-may`);
  if ((await page.locator('aside nav button', { hasText: 'Sản xuất' }).getAttribute('aria-expanded')) !== 'true') fail('Mở trang Lịch máy thì nhóm Sản xuất phải tự mở');
  // Rà soát menu 28/10: bỏ Thông báo (chuông), Kiểm tra năng lực, Checklist đầu ca; dời nhóm
  const inGroup = async (g) => (await page.locator(`aside nav [data-group="${g}"]`).textContent()) ?? '';
  if (/Thông báo|Kiểm tra năng lực|Checklist đầu ca|Người dùng & quyền/.test(nav)) fail(`Menu còn mục đã bỏ: ${nav}`);
  if (!(await inGroup('Hệ thống & cài đặt')).includes('Tham số xếp lịch') || !(await inGroup('Hệ thống & cài đặt')).includes('Cài đặt máy')
    || !(await inGroup('Kỹ thuật / QA')).includes('Tốc độ sản xuất') || !(await inGroup('Báo cáo')).includes('Lịch sử vận hành')
    || !(await inGroup('Báo cáo')).includes('Báo cáo bảo trì') || /Tốc độ|Lịch sử|Cài đặt/.test(await inGroup('Quản lý máy'))) fail('Nhóm menu chưa đúng phương án rà soát');
  if (!(await page.locator('header a[href="/thong-bao"]').count())) fail('Chuông thông báo trên đầu trang phải còn');
  const kt = await page.goto(`${BASE}/may/kiem-tra`);
  if (kt?.status() !== 404 && !/404|không tìm thấy|could not be found/i.test(await page.locator('body').innerText())) fail('Trang Kiểm tra năng lực phải bỏ');
  ok('Rà soát menu: bỏ Thông báo, Kiểm tra năng lực, Checklist đầu ca; Tham số, Cài đặt máy ở Hệ thống & cài đặt; Tốc độ ở Kỹ thuật / QA; Lịch sử vận hành, Báo cáo bảo trì ở Báo cáo');
  await page.goto(`${BASE}/`);
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
    '/may/lich-su', '/may/bao-cao', '/bao-cao/hao-hut', '/phieu-hoan-thanh', '/kho/qc',
    '/phieu-xuat-nvl', '/bao-cao/ngay', '/in/phieu-xuat-nvl', '/in/bao-cao-ca', '/de-xuat/du-phong', '/de-xuat/du-phong?tab=phieu', '/ke-hoach/dieu-chinh',
    '/lich-may?tab=toiuu', '/lich-may?tab=toiuu&mode=fastest', '/lich-may?tab=cancu', '/tham-so?sua=flow',
    '/don-mua', '/don-mua?tab=tat-ca', '/kho/xuat-ban', '/kho/thanh-pham', '/in/nhap-kho-tp', '/kho/ton?kho=KTP', '/kho/phe', '/kho/cai-dat?tab=dau-ky', '/nhan-su-xuong'];
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
    if (!(await flash(page)).includes('Giám đốc duyệt')) fail('TP SX xếp lịch phải gửi Giám đốc duyệt');
    if (!(await page.innerText('body')).includes('chờ Giám đốc duyệt')) fail('Lịch máy phải hiện bản đề xuất chờ Giám đốc duyệt');
    await ctx.close();
    [ctx, page] = await ctxFor();
    await login(page, 'bgd@bmt.test');
    await page.goto(`${BASE}/lich-may?tab=lich`);
    if (!(await page.locator('#schedule-review').count())) fail('Giám đốc phải thấy nút duyệt lịch máy');
    await clickNav(page, '#schedule-review button:has-text("Duyệt lịch máy")');
    await expectOk(page, 'Giám đốc duyệt bản lịch TP SX xếp lại');
    if (await page.locator('#schedule-review').count()) fail('Duyệt xong không còn bản chờ duyệt');
    await page.goto(`${BASE}/lich-may?tab=lich`);
    if (!(await page.innerText('body')).includes('EXT-SI-02 hỏng')) fail('Gantt không hiện khối máy hỏng');
  }
  ok('Đợt A: vận hành không báo hỏng trên MES; TP KT/QA báo hỏng bắt buộc giờ chạy lại; Lịch máy hiện máy hỏng, TP SX xếp lại lịch, Giám đốc duyệt');
  await ctx.close();
}

// 11. Tồn dự phòng: TP Mua lập phiếu mức dự phòng → Giám đốc sửa khi duyệt → dưới mức: NV mua lập đề xuất mua bổ sung
{
  [ctx, page] = await ctxFor();
  await login(page, 'mua.tp@bmt.test');
  await page.goto(`${BASE}/de-xuat/du-phong`);
  await page.fill('#lap-phieu input[name=reason]', 'Dự phòng 1 tháng sản xuất');
  await page.locator('#lap-phieu input[name^=code_]').first().fill('TAPE-NEW');
  await page.locator('#lap-phieu input[name^=qty_]').first().fill('500');
  await clickNav(page, '#lap-phieu button:has-text("Lập phiếu")');
  await expectOk(page, 'TP Mua lập phiếu điều chỉnh mức dự phòng');
  const ssUrl = page.url().split('?')[0];
  const ssNo = (await page.textContent('main h1')).split(' · ')[0].trim();
  await clickNav(page, 'button:has-text("Gửi Giám đốc duyệt")');
  await expectOk(page, `Gửi ${ssNo} cho Giám đốc duyệt`);
  await ctx.close();
  [ctx, page] = await ctxFor();
  await login(page, 'bgd@bmt.test');
  await page.goto(ssUrl);
  if (!(await page.locator('#review-edit').count())) fail('Giám đốc đang duyệt phải sửa được phiếu dự phòng');
  await page.locator('input[name=qty_0]').fill('400');
  await clickNav(page, 'button:has-text("Lưu")');
  await expectOk(page, 'Giám đốc sửa mức dự phòng TAPE-NEW 500 → 400 khi duyệt');
  await ctx.close();
  await approveAs('bgd@bmt.test', ssNo, 'Giám đốc');
  [ctx, page] = await ctxFor();
  await login(page, 'mua.nv@bmt.test');
  await page.goto(`${BASE}/de-xuat/du-phong`);
  const ssBody = await page.innerText('main');
  if (!/TAPE-NEW[\s\S]{0,300}400/.test(ssBody)) fail(`TAPE-NEW phải dưới mức dự phòng 400: ${ssBody.slice(0, 400)}`);
  await clickNav(page, '#pr-from-safety button:has-text("Lập đề xuất mua bổ sung")');
  await expectOk(page, 'NV mua lập đề xuất mua bổ sung bù tồn dự phòng');
  const sb = await page.innerText('main');
  if (!sb.includes('Mua bổ sung') || !sb.includes('TAPE-NEW')) fail('Đề xuất mua bù dự phòng phải là loại Mua bổ sung, có TAPE-NEW');
  ok('Dưới mức dự phòng: NV mua lập đề xuất mua bổ sung một lần bấm');
  await ctx.close();
  [ctx, page] = await ctxFor();
  await login(page, 'sx.kh@bmt.test');
  await page.goto(`${BASE}/ke-hoach/dieu-chinh?tab=tat-ca`);
  const adjBody = await page.innerText('main');
  if (!adjBody.includes('Lập phiếu đề xuất thay đổi kế hoạch tháng') || !/PDC-\d/.test(adjBody)) fail('Màn hình Điều chỉnh kế hoạch tháng phải có form lập phiếu và danh sách phiếu');
  ok('Màn hình riêng Điều chỉnh kế hoạch tháng: lập phiếu, danh sách phiếu (Chủ tịch HĐQT duyệt)');
  await ctx.close();
}


// 12. Thuật toán xếp lịch theo thông số: thẻ Tối ưu & tăng ca, TP KT/QA sửa thông số dòng chảy, TP SX đề xuất tăng ca → Giám đốc duyệt / kết thúc
{
  [ctx, page] = await ctxFor();
  await login(page, 'kt.tp@bmt.test');
  await page.goto(`${BASE}/tham-so?sua=flow`);
  const flowSec = page.locator('section', { hasText: 'Dòng chảy, máy trộn, tăng ca' }).first();
  if (await flowSec.locator('input[name=ot_max_min]').count()) fail('TP KT/QA không được sửa giới hạn tăng ca');
  await flowSec.locator('input[name=pot_life_h]').fill('6');
  await flowSec.locator('input[name=qc_min]').fill('90');
  await flowSec.locator('textarea[name=reason]').fill('E2E: đo thực tế hạn dùng 6 giờ, QC 90 phút');
  await clickNav(page, 'section:has-text("Dòng chảy, máy trộn, tăng ca") button:has-text("Lưu thay đổi")');
  await page.screenshot({ path: `${SHOTS}/21-tham-so-dong-chay.png`, fullPage: true });
  await expectOk(page, 'TP KT/QA sửa hạn dùng silicone, thời gian QC');
  const fb = await page.innerText('main');
  if (!/Hạn dùng silicone đã pha lưu hóa\s*6/.test(fb)) fail('Hạn dùng silicone chưa lưu 6 giờ');
  if (!fb.includes('Hạn dùng silicone đã pha lưu hóa (giờ)')) fail('Nhật ký tham số thiếu dòng hạn dùng silicone');
  await ctx.close();
  [ctx, page] = await ctxFor();
  await login(page, 'sx.tp@bmt.test');
  await page.goto(`${BASE}/lich-may?tab=toiuu&mode=fastest`);
  const ob = await page.innerText('main');
  for (const t of ['Máy cổ chai', 'Nếu thêm giờ', 'Thứ tự lô và ngày xong', 'Tăng ca / trộn sớm', 'Thông số đang dùng']) if (!ob.includes(t)) fail(`Thẻ Tối ưu & tăng ca thiếu "${t}"`);
  if (!ob.includes('hạn dùng silicone 6 giờ') || !ob.includes('90 phút')) fail('Thẻ Tối ưu không hiện thông số mới (hạn dùng 6 giờ, QC 90 phút)');
  await page.screenshot({ path: `${SHOTS}/20-toi-uu-tang-ca.png`, fullPage: true });
  ok('Thẻ Tối ưu & tăng ca: máy cổ chai, nếu thêm giờ, thứ tự lô, thông số đang dùng');
  const form = page.locator('form:has(input[name=date_from])');
  if (!(await form.count())) fail('TP SX phải thấy form đề xuất tăng ca');
  {
    const filled = await form.locator('input[name^=ot_]').evaluateAll((els) => els.some((e) => e.value));
    if (!filled) await form.locator('input[name^=ot_]').first().fill('60');
    await form.locator('input[name=reason]').fill('E2E: rút ngắn kế hoạch');
    await Promise.all([page.waitForURL(/ok=|err=/), form.locator('button', { hasText: 'Đề xuất Giám đốc duyệt' }).click()]);
    const msg = await flash(page);
    if (!msg.includes('Giám đốc duyệt')) fail(`Đề xuất tăng ca: ${msg}`);
    ok('TP SX đề xuất tăng ca theo MES, gửi Giám đốc duyệt');
    await ctx.close();
    [ctx, page] = await ctxFor();
    await login(page, 'bgd@bmt.test');
    await page.goto(`${BASE}/lich-may?tab=toiuu`);
    await clickNav(page, 'form:has(input[name=note]) button:has-text("Duyệt")');
    await expectOk(page, 'Giám đốc duyệt tăng ca');
    if (!(await page.innerText('main')).includes('Đang áp dụng')) fail('Tăng ca đã duyệt phải hiện Đang áp dụng');
    await page.locator('form:has(button:has-text("Kết thúc sớm")) input[name=note]').first().fill('E2E: đủ năng lực');
    await clickNav(page, 'button:has-text("Kết thúc sớm")');
    await expectOk(page, 'Giám đốc kết thúc tăng ca sớm');
  }
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

// 12. Phân quyền theo bộ phận + ô tick phân quyền (chỉ Quản trị hệ thống)
{
  const [c, p] = await ctxFor();
  await login(p, 'mua.tp@bmt.test');
  const navMua = await p.textContent('nav');
  if (['Lịch máy', 'Ghi nhận ca', 'Phiếu kho', 'Kiểm kê', 'Phân quyền'].some((x) => navMua.includes(x)) || !['Đề xuất mua hàng', 'Tồn kho', 'Kế hoạch sản xuất chung', 'Danh sách máy'].every((x) => navMua.includes(x))) {
    fail(`Menu TP Mua phải theo bộ phận Mua hàng + thông tin chung: ${navMua}`);
  }
  await p.goto(`${BASE}/ghi-nhan-ca`);
  if (!(await flash(p)).includes('không thuộc bộ phận')) fail('TP Mua vào được Ghi nhận ca');
  await c.close();
  ok('TP Mua: menu theo bộ phận (không còn Lịch máy, Ghi nhận ca, Phiếu kho), gõ thẳng URL bị chặn');
}
{
  const [c, p] = await ctxFor();
  await login(p, 'bgd@bmt.test');
  if ((await p.textContent('nav')).includes('Phân quyền')) fail('Giám đốc không được thấy Phân quyền');
  await p.goto(`${BASE}/quan-tri/phan-quyen`);
  if (!(await flash(p)).includes('Chỉ Quản trị hệ thống')) fail('Giám đốc vào được Phân quyền');
  await c.close();
  ok('Phân quyền: chỉ Quản trị hệ thống thấy và vào được');
}
{
  const [c, p] = await ctxFor();
  await login(p, 'admin@bmt.test', 'Admin@12345');
  await p.goto(`${BASE}/quan-tri/phan-quyen`);
  const box = p.locator('input[name=g][value="VAN_HANH|lich-may"]');
  if (!(await box.isChecked())) fail('Mặc định vận hành được xem Lịch máy');
  await box.uncheck();
  await clickNav(p, 'button:has-text("Lưu quyền vào mục")');
  await expectOk(p, 'Quản trị bỏ tick Vận hành → Lịch máy');
  const [c2, p2] = await ctxFor();
  await login(p2, 'vh@bmt.test');
  if ((await p2.textContent('nav')).includes('Lịch máy')) fail('Bỏ tick thì vận hành không còn thấy Lịch máy');
  await p2.goto(`${BASE}/lich-may`);
  if (!(await flash(p2)).includes('không thuộc bộ phận')) fail('Bỏ tick thì vận hành bị chặn ở Lịch máy');
  await c2.close();
  await p.locator('input[name=g][value="VAN_HANH|lich-may"]').check();
  await clickNav(p, 'button:has-text("Lưu quyền vào mục")');
  await expectOk(p, 'Quản trị tick lại Vận hành → Lịch máy');
  await p.goto(`${BASE}/quan-tri/phan-quyen?tab=thao-tac&role=KD_NV`);
  if (!(await p.locator('input[name=p][value="machine:view"]').isChecked())) fail('Kinh doanh phải có quyền xem máy (thông tin chung)');
  await p.screenshot({ path: `${SHOTS}/13-phan-quyen.png`, fullPage: true });
  await c.close();
  ok('Quản trị tick/bỏ tick quyền vào mục có hiệu lực ngay; quyền thao tác theo vai trò hiện đúng');
}

// 13. Trang tổng quan theo phân quyền: Giám đốc thấy đủ khối giám sát; TP SX không thấy giá
{
  const [c, p] = await ctxFor();
  await login(p, 'bgd@bmt.test');
  await p.goto(`${BASE}/`);
  for (const id of ['so-chinh', 'san-luong', 'lo-ke-hoach', 'hieu-suat', 'hao-hut', 'qc', 'du-phong', 'gia-tri-ton', 'gia-thanh']) {
    if (!(await p.locator(`#${id}`).count())) fail(`Giám đốc phải thấy khối #${id} trên Tổng quan`);
  }
  if (!(await p.textContent('#so-chinh')).includes('Giá trị tồn kho')) fail('Dải số chính của Giám đốc phải có Giá trị tồn kho');
  await p.screenshot({ path: `${SHOTS}/14-tong-quan-giam-doc.png`, fullPage: true });
  await c.close();
  const [c2, p2] = await ctxFor();
  await login(p2, 'sx.tp@bmt.test');
  await p2.goto(`${BASE}/`);
  if (!(await p2.locator('#san-luong').count()) || !(await p2.locator('#hieu-suat').count())) fail('TP SX phải thấy sản lượng, hiệu suất máy');
  if ((await p2.locator('#gia-tri-ton').count()) || (await p2.locator('#gia-thanh').count())) fail('TP SX không được xem giá: không có khối giá trị tồn kho, giá thành');
  await c2.close();
  ok('Tổng quan theo phân quyền: Giám đốc đủ 9 khối; TP SX có sản lượng, hiệu suất máy, không có giá; vận hành không thấy giá, dự phòng, QC');
}

// 14. Người đứng máy, máy dừng (quyết định 28/10/2026): Nhân sự xưởng, máy Dừng bắt buộc giờ chạy lại, thông số người đứng máy
{
  const [c, p] = await ctxFor();
  await login(p, 'vh@bmt.test');
  await p.goto(`${BASE}/nhan-su-xuong`);
  if (!(await flash(p)).includes('không thuộc bộ phận')) fail('Vận hành không được vào Nhân sự xưởng');
  await c.close();
}
{
  const [c, p] = await ctxFor();
  await login(p, 'kt.tp@bmt.test');
  await p.goto(`${BASE}/may`);
  const tp2 = await p.locator('a[href^="/may/"]', { hasText: 'EXT-TP-02' }).first().getAttribute('href');
  await p.goto(`${BASE}${tp2}`);
  await p.locator('summary', { hasText: 'Báo hỏng' }).click();
  await p.selectOption('select[name=status]', 'STOP');
  await p.selectOption('select[name=reason]', 'DT_MATERIAL').catch(() => {});
  await p.fill('input[name=note]', 'E2E: chờ hạt nhựa');
  await Promise.all([p.waitForURL(/err=|ok=/), p.locator('details form button', { hasText: 'Cập nhật' }).first().click()]);
  if (!(await flash(p)).includes('dự kiến chạy lại')) fail('Báo máy Dừng không có giờ chạy lại phải bị chặn');
  await p.goto(`${BASE}/tham-so?sua=people`);
  const sec = p.locator('#nguoi-dung-may');
  await sec.locator('input[name=start_min]').fill('25');
  await sec.locator('textarea[name=reason]').fill('E2E: bấm giờ khởi động thực tế');
  await clickNav(p, '#nguoi-dung-may button:has-text("Lưu thay đổi")');
  await expectOk(p, 'TP KT/QA sửa phút khởi động máy tự chạy');
  if (!/khởi động, cộng phút đổi máy\s*25/.test(await p.innerText('#nguoi-dung-may'))) fail('Phút khởi động chưa lưu 25');
  if (await p.locator('#ty-le-rieng a', { hasText: 'Sửa' }).count()) fail('TP KT/QA không được sửa tỷ lệ xếp lịch riêng');
  await c.close();
  ok('Máy Dừng bắt buộc giờ chạy lại; TP KT/QA sửa thông số người đứng máy, không sửa tỷ lệ riêng');
}
{
  const [c, p] = await ctxFor();
  await login(p, 'sx.tp@bmt.test');
  if (!(await p.textContent('nav')).includes('Nhân sự xưởng')) fail('TP SX phải thấy mục Nhân sự xưởng');
  await p.goto(`${BASE}/nhan-su-xuong`);
  const nb = await p.innerText('main');
  for (const t of ['Người', 'Người × máy', 'Lịch vắng', 'Kiêm nhiệm tạm', 'Tổ đóng gói', 'Cảnh báo & gợi ý']) if (!nb.includes(t)) fail(`Nhân sự xưởng thiếu thẻ ${t}`);
  // Thêm người
  const add = p.locator('#them-nguoi');
  await add.locator('input[name=name]').fill('Người thử E2E');
  await add.locator('input[name=job]').fill('Đóng gói');
  await clickNav(p, '#them-nguoi button:has-text("Thêm người")');
  await expectOk(p, 'TP SX thêm người đứng máy');
  if (!(await p.innerText('main')).includes('Người thử E2E')) fail('Người mới không hiện trong danh sách');
  // Lịch vắng NV5 ngày mai
  const tom = new Date(Date.now() + 7 * 3600000 + 86400000).toISOString().slice(0, 10);
  await p.goto(`${BASE}/nhan-su-xuong?tab=vang`);
  const fa = p.locator('form:has(select[name=part])');
  await fa.locator('select[name=operator]').selectOption('NV5');
  await fa.locator('input[name=from]').fill(tom);
  await clickNav(p, 'form:has(select[name=part]) button:has-text("Lưu lịch vắng")');
  await expectOk(p, 'TP SX nhập lịch vắng NV5');
  // Kiêm nhiệm tạm NV3 đứng EXT-SI-01 ngày mai
  await p.goto(`${BASE}/nhan-su-xuong?tab=kiem-nhiem`);
  const fc = p.locator('form:has(button:has-text("Phân công"))');
  await fc.locator('select[name=operator]').selectOption('NV3');
  await fc.locator('select[name=machine]').selectOption('EXT-SI-01');
  await fc.locator('input[name=from]').fill(tom);
  await fc.locator('input[name=reason]').fill('E2E: NV5 nghỉ phép');
  await clickNav(p, 'form:has(button:has-text("Phân công")) button:has-text("Phân công")');
  await expectOk(p, 'TP SX phân công kiêm nhiệm tạm');
  if (!(await p.innerText('main')).includes('kiêm nhiệm tạm')) fail('Kiêm nhiệm người chưa có tay nghề phải ghi "kiêm nhiệm tạm"');
  // Tổ đóng gói 1 người ngày đầu tiên trong danh sách
  await p.goto(`${BASE}/nhan-su-xuong?tab=dong-goi`);
  const fk = p.locator('form:has(select[name=crew])').first();
  if (await fk.count()) {
    await fk.locator('select[name=crew]').selectOption('1');
    await Promise.all([p.waitForURL(/ok=|err=/), fk.locator('button', { hasText: 'Lưu' }).click()]);
    await expectOk(p, 'TP SX đặt tổ đóng gói 1 người');
  }
  await p.goto(`${BASE}/nhan-su-xuong?tab=canh-bao`);
  if (/Application error|PGRST/i.test(await p.innerText('body'))) fail('Thẻ Cảnh báo & gợi ý lỗi');
  await p.screenshot({ path: `${SHOTS}/15-nhan-su-xuong.png`, fullPage: true });
  // Lịch máy: thông số người đứng máy đổi → cần xếp lại; bảng người có mặt
  await p.goto(`${BASE}/lich-may?tab=lich`);
  const lb = await p.innerText('main');
  if (/Application error|PGRST/i.test(lb)) fail('Lịch máy lỗi sau khi đổi nhân sự');
  if (!/cần xếp lại|Xếp lại lịch/i.test(lb)) fail('Đổi lịch vắng / kiêm nhiệm / thông số người: lịch máy phải nhắc xếp lại');
  const rb = p.locator('form button', { hasText: /Xếp lại lịch|Xếp lịch/ }).first();
  if (await rb.count()) {
    await Promise.all([p.waitForURL(/ok=|err=/), rb.click()]);
    const fm = await flash(p);
    if (!fm.includes('Giám đốc duyệt')) fail(`TP SX xếp lại lịch theo người đứng máy: ${fm}`);
    ok(`TP SX xếp lại lịch theo người đứng máy → ${fm.trim().slice(0, 120)}`);
  }
  await p.goto(`${BASE}/lich-may?tab=toiuu`);
  if (!(await p.innerText('main')).includes('thêm người')) fail('Thẻ Tối ưu phải có mục Nếu thêm người');
  await c.close();
  ok('Nhân sự xưởng: thêm người, lịch vắng, kiêm nhiệm tạm (ghi chưa có tay nghề), tổ đóng gói; lịch máy nhắc xếp lại, xếp lại theo người');
}

await browser.close();
console.log(`==> ĐẠT ${n} kiểm tra end-to-end`);
