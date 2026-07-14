-- =========================================================================
-- Flow 繪製工具 — Master（跨單位總覽）支援
-- 在 supabase-schema.sql 之後執行這份（同樣在 Supabase 的 SQL Editor 貼上
-- 整份執行一次）。
--
-- 設計說明：帽子（六階段schema）是綁在各單位自己身上的（見 supabase-schema.sql
-- 的 unit_pins.stages），Master 沒有一套獨立的schema，也不會把四個單位的
-- 資料攤平混在同一組帽子欄位下顯示——而是「一次只看一個Div，切換Div時
-- 連同該Div自己的帽子一起換過去」，跟一般主管模式看自己單位時完全同一套
-- 規則，只是門檻換成Master自己的PIN、而且能任意切換去看別的Div。所以這裡
-- 只需要一個新函式：用MASTER自己的PIN當門檻，但可以指定「查哪個單位」。
-- =========================================================================

-- MASTER 的 PIN 存在跟一般單位一樣的 unit_pins 表裡，只是這個「單位」不會
-- 有任何員工真的存資料進去（submitter_unit 永遠不會是 'MASTER'），純粹借
-- 用同一張表存一組密碼，判斷邏輯跟其他單位一致，不用另外建表。
insert into unit_pins (unit_name, pin) values
  ('MASTER', '8888!')
on conflict (unit_name) do update set pin = excluded.pin;

-- 如果先前跑過舊版的 get_master_submissions（一次撈全部單位攤平混在一起
-- 的版本），這裡清掉，避免留著沒人用的舊函式。
drop function if exists get_master_submissions(text);

-- 跟 get_unit_submissions(unit, pin) 幾乎一樣，差別只是 PIN 檢查對象換成
-- unit_pins 裡的 'MASTER' 那一列，而不是 p_unit 那一列——也就是「用master
-- 密碼，看任何一個你指定的單位」。PIN對了才回傳資料，PIN錯誤回傳空集合，
-- 跟其他PIN檢查函式同一套安全邏輯。
create or replace function get_master_unit_submissions(p_unit text, p_pin text)
returns table (
  submitter_name text,
  submitter_role text,
  model_json jsonb,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from unit_pins
    where unit_name = 'MASTER' and pin = p_pin
  ) then
    return;
  end if;

  return query
    select s.submitter_name, s.submitter_role, s.model_json, s.updated_at
    from submissions s
    where s.submitter_unit = p_unit;
end;
$$;

grant execute on function get_master_unit_submissions(text, text) to anon;
