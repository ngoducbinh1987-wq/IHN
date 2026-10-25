-- BMT MES · Dữ liệu khởi tạo từ Excel bản 3.0 — sinh bởi tools/gen_seed.py

-- Tính lại phần lõi bằng bộ tính trong DB (phải khớp file)
select master.calc_spec(id) from master.product_specs where version = 1;
