-- =========================================================================
-- Flow 繪製工具 — Supabase schema
-- 在 Supabase 專案的 SQL Editor 貼上整份檔案並執行一次即可。
--
-- 設計說明（給 Jerry）：
-- 1. submissions：每位基層填寫者的完整流程資料。整包 MODEL 物件直接存進
--    jsonb 欄位，不拆成一堆關聯表 —— 因為前端本來就是用這個 JSON 結構在跑，
--    拆表只會增加轉換成本，不會帶來實際好處。
--    以 (submitter_name, submitter_unit, submitter_role) 當作「這是同一個
--    人」的判斷依據，重複存檔會覆蓋（upsert）而不是疊加出新的一筆。
--    已知取捨：如果同單位同角色下真的有兩個人剛好同名，會被誤判成同一人、
--    互相覆蓋彼此的資料 —— 目前的身份設計（只填姓名，不用帳號）就是這樣，
--    如果之後發現真的撞名，可以之後再加一個 email 欄位進 unique key 解決。
-- 2. unit_pins：每個單位一組簡易 PIN，用來給主管檢視頁做「輕量門檻」。
-- 3. RLS 全部設為預設拒絕、只開必要的權限：
--    - submissions 允許 anon 角色寫入（INSERT/UPDATE，基層存檔不需要登入），
--      但不允許 anon 直接 SELECT —— 直接開放 SELECT 的話，任何人打開瀏覽器
--      開發工具都能不經過 PIN 直接把所有單位的資料撈出來，PIN 檢查形同虛設。
--    - unit_pins 完全不開放 anon 存取（連查都不能查），PIN 只透過下面的
--      RPC 函式在資料庫內部比對，不會被前端程式碼讀到。
--    - 真正給主管頁用的讀取路徑是 get_unit_submissions() 這個函式：它用
--      SECURITY DEFINER 執行（用建立者權限跑，不受呼叫者的 RLS 限制），先在
--      資料庫內部核對 PIN 是否正確，PIN 對了才回傳該單位的資料，PIN 錯就回
--      空陣列。這樣「PIN 門檻」是伺服器端真正生效的，不只是前端畫面上擺著看。
-- =========================================================================

create extension if not exists pgcrypto;

create table if not exists submissions (
  id uuid primary key default gen_random_uuid(),
  submitter_name text not null,
  submitter_unit text not null,
  submitter_role text not null,
  model_json jsonb not null,
  updated_at timestamptz not null default now(),
  unique (submitter_name, submitter_unit, submitter_role)
);

create table if not exists unit_pins (
  unit_name text primary key,
  pin text not null
);

alter table submissions enable row level security;
alter table unit_pins enable row level security;

-- 基層填寫者：允許匿名寫入自己的那一筆（新增或更新皆可），但不允許直接讀取
-- 任何一筆（包括自己的），一律透過應用程式自己在 localStorage 記住「我剛存了
-- 什麼」，不倚賴從資料庫讀回來確認。
drop policy if exists "anon can insert submissions" on submissions;
create policy "anon can insert submissions" on submissions
  for insert to anon
  with check (true);

drop policy if exists "anon can update own submission" on submissions;
create policy "anon can update own submission" on submissions
  for update to anon
  using (true)
  with check (true);

-- 刻意不建立任何 "for select" policy 給 anon —— 預設就是拒絕，
-- 這正是我們要的效果（見上方說明）。unit_pins 同樣完全不給 anon 任何政策。

-- =========================================================================
-- 主管檢視唯一的讀取入口：PIN 對了才回傳該單位所有提交的 model_json。
-- 用 SECURITY DEFINER，所以它能在函式內部讀到 submissions / unit_pins，
-- 即使呼叫者（anon）自己完全沒有讀取這兩張表的權限。
-- =========================================================================
create or replace function get_unit_submissions(p_unit text, p_pin text)
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
    where unit_name = p_unit and pin = p_pin
  ) then
    return; -- PIN 錯誤或單位不存在 -> 回傳空集合，前端顯示「PIN錯誤」
  end if;

  return query
    select s.submitter_name, s.submitter_role, s.model_json, s.updated_at
    from submissions s
    where s.submitter_unit = p_unit;
end;
$$;

grant execute on function get_unit_submissions(text, text) to anon;

-- =========================================================================
-- 基層填寫者「讀回自己上次存的資料」用的入口（例如換裝置、換瀏覽器）。
-- 不需要 PIN —— 這裡的「門檻」就是你要精確知道自己當初填的姓名/單位/角色，
-- 跟登入帳號密碼比起來當然不算真正的驗證，但已經比「完全開放讀取整張表」
-- 窄得多：陌生人必須先湊到某個真實存在的 (姓名,單位,角色) 三元組，才能撈到
-- 那一筆，撈不到「全部人的全部資料」。這跟整份工具「不做真登入」的既定範圍
-- 是一致的取捨，值得知道但不需要為了這個現在就導入 Supabase Auth。
-- =========================================================================
create or replace function get_my_submission(p_name text, p_unit text, p_role text)
returns table (model_json jsonb, updated_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select s.model_json, s.updated_at
    from submissions s
    where s.submitter_name = p_name
      and s.submitter_unit = p_unit
      and s.submitter_role = p_role;
end;
$$;

grant execute on function get_my_submission(text, text, text) to anon;

-- =========================================================================
-- 初始化每個單位的 PIN —— 依實際單位名稱增删這幾行（單位名稱建議跟工具內
-- 「組織結構」使用的名稱完全一致，大小寫、空白都要一樣，這樣主管輸入的單位
-- 名稱才能對到基層存檔時選的單位）。之後要換 PIN，直接 UPDATE 這張表即可。
-- =========================================================================
insert into unit_pins (unit_name, pin) values
  ('DIV4', '請改成你自己的PIN')
on conflict (unit_name) do nothing;

-- =========================================================================
-- 帽子（六階段schema）設定 —— **綁在單位上**，不是全公司共用一套。原因：
-- 不同BU的工作流程本來就不一樣（Div4可能6個帽子就cover所有流程，業務BU、
-- 行銷BU的流程可能完全不同），所以帽子要讓「各BU的主管」自己定義，但同一個
-- 單位底下的所有角色/員工要共用同一套，才能在同一個結構下彙整比較。
--
-- 直接加在 unit_pins 表上（多一個 stages 欄位），沿用該單位既有的 PIN 當
-- 門檻 —— 不需要另外一組「全域 admin PIN」，管帽子的人就是管這個單位彙整
-- 檢視的同一個主管。stages 是 nullable：還沒有人特別設定過的單位，欄位是
-- null，前端就退回使用內建預設的那 6 個帽子（跟舊版行為一致，離線使用者
-- 完全不受影響）。
--
-- stages 陣列裡每個元素 { id, title, color }：
--   - id 是穩定不變的識別碼，一旦建立就不會因為改標題而變動（改標題只改
--     title，不動 id）——這樣既有任務裡的 node.stageId 才不會因為主管改個
--     名字就對不到。只有「真的刪除整個帽子」才會讓引用它的舊資料變成孤兒，
--     前端有安全網處理（不會讓資料整個消失不見，見 flow-builder.html 裡
--     computeStageLayout 的註解）。
--   - color 是這個帽子在畫面上的顏色（hex），純視覺。
-- =========================================================================
alter table unit_pins add column if not exists stages jsonb;

-- 任何人都能讀某單位「目前的帽子設定」，不需要 PIN —— 填寫者存檔前就要先
-- 知道自己單位現在有哪些帽子才能畫圖，這不是敏感資訊。回傳 null 代表這個
-- 單位還沒被主管自訂過，前端會自動退回內建預設的 6 個帽子。
create or replace function get_unit_stages(p_unit text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select stages from unit_pins where unit_name = p_unit;
$$;

grant execute on function get_unit_stages(text) to anon;

-- 只有該單位的 PIN 對了才會真的更新；PIN 錯誤回傳 false，不會透露「錯在
-- 哪」。順便做一個最基本的完整性檢查（陣列非空），避免手滑存成空陣列，
-- 讓整個單位瞬間變成沒有帽子可用。
create or replace function update_unit_stages(p_unit text, p_stages jsonb, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from unit_pins where unit_name = p_unit and pin = p_pin) then
    return false;
  end if;
  if p_stages is null or jsonb_typeof(p_stages) <> 'array' or jsonb_array_length(p_stages) = 0 then
    return false;
  end if;
  update unit_pins set stages = p_stages where unit_name = p_unit;
  return true;
end;
$$;

grant execute on function update_unit_stages(text, jsonb, text) to anon;
