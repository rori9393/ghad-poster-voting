begin;

-- إضافة البريد الجامعي والفئة لبيانات المشارك.
alter table public.profiles
  add column if not exists email text,
  add column if not exists gender text;

-- السماح بعودة نفس الرقم الأكاديمي من جلسة جديدة.
-- منع تكرار التصويت سيُطبّق داخل إجراء التصويت.
alter table public.profiles
  drop constraint if exists profiles_academic_number_key;

create index if not exists profiles_academic_lookup
  on public.profiles (academic_number);

-- إيقاف إجراء التسجيل القديم.
revoke execute
  on function public.register_profile(text, text)
  from public, anon, authenticated;

-- تسجيل البيانات الأربعة.
create or replace function public.register_visitor(
  p_full_name text,
  p_academic_number text,
  p_email text,
  p_gender text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_name text;
  v_academic text;
  v_email text;
  v_gender text;
  v_existing public.profiles%rowtype;
begin
  if v_uid is null then
    raise exception 'يلزم تسجيل الدخول أولًا.';
  end if;

  v_name := regexp_replace(
    btrim(coalesce(p_full_name, '')),
    '\s+',
    ' ',
    'g'
  );

  v_academic := upper(
    translate(
      btrim(coalesce(p_academic_number, '')),
      '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
      '01234567890123456789'
    )
  );

  v_email := lower(btrim(coalesce(p_email, '')));
  v_gender := btrim(coalesce(p_gender, ''));

  if char_length(v_name) > 100
     or cardinality(regexp_split_to_array(v_name, '\s+')) < 3
  then
    raise exception 'اكتبي الاسم الثلاثي كاملًا.';
  end if;

  if v_academic !~ '^[A-Z0-9-]{2,30}$' then
    raise exception 'الرقم الأكاديمي غير صالح.';
  end if;

  if char_length(v_email) > 254
     or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  then
    raise exception 'اكتبي بريدًا جامعيًا بصيغة صحيحة.';
  end if;

  if v_gender not in ('طالب', 'طالبة') then
    raise exception 'اختاري طالب أو طالبة.';
  end if;

  -- منع تعارض طلبين لتسجيل نفس الجلسة.
  perform pg_advisory_xact_lock(
    hashtextextended('visitor:' || v_uid::text, 0)
  );

  select *
  into v_existing
  from public.profiles
  where id = v_uid
  for update;

  if found then
    -- الرقم الأكاديمي ثابت داخل الجلسة.
    if v_existing.academic_number is distinct from v_academic then
      raise exception
        'هذه الجلسة مرتبطة برقم أكاديمي آخر. سجّلي الخروج أولًا.';
    end if;

    -- استكمال الحسابات القديمة فقط.
    if v_existing.email is null or v_existing.gender is null then
      update public.profiles
      set
        full_name = v_name,
        email = v_email,
        gender = v_gender
      where id = v_uid;
    elsif v_existing.full_name is distinct from v_name
       or v_existing.email is distinct from v_email
       or v_existing.gender is distinct from v_gender
    then
      raise exception
        'البيانات تختلف عن بيانات هذه الجلسة. سجّلي الخروج ثم أدخلي بياناتك.';
    end if;
  else
    insert into public.profiles (
      id,
      full_name,
      academic_number,
      email,
      gender
    )
    values (
      v_uid,
      v_name,
      v_academic,
      v_email,
      v_gender
    );
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- جلب البوسترات التي صوّت لها الرقم الأكاديمي الحالي.
create or replace function public.my_ballots()
returns table (post_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct v.post_id
  from public.votes as v
  join public.profiles as voter
    on voter.id = v.user_id
  join public.profiles as me
    on me.academic_number = voter.academic_number
  where me.id = auth.uid()
    and me.email is not null
    and me.gender in ('طالب', 'طالبة')
  order by v.post_id;
$$;

-- حفظ صوت واحد لكل رقم أكاديمي لكل بوستر.
create or replace function public.cast_vote(
  p_post_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_academic text;
  v_count bigint;
  v_inserted integer;
begin
  if v_uid is null then
    raise exception 'يلزم تسجيل الدخول أولًا.';
  end if;

  select academic_number
  into v_academic
  from public.profiles
  where id = v_uid
    and email is not null
    and gender in ('طالب', 'طالبة');

  if not found then
    raise exception 'أكملي بيانات الدخول أولًا.';
  end if;

  -- تسلسل عمليات التصويت على نفس البوستر.
  select vote_count
  into v_count
  from public.posts
  where id = p_post_id
  for update;

  if not found then
    raise exception 'البوستر غير موجود.';
  end if;

  -- يشمل الأصوات المسجلة في جلسات سابقة.
  if exists (
    select 1
    from public.votes as v
    join public.profiles as p
      on p.id = v.user_id
    where v.post_id = p_post_id
      and p.academic_number = v_academic
  ) then
    return jsonb_build_object(
      'ok', true,
      'already_voted', true,
      'vote_count', v_count
    );
  end if;

  insert into public.votes (user_id, post_id)
  values (v_uid, p_post_id)
  on conflict (user_id, post_id) do nothing;

  get diagnostics v_inserted = row_count;

  if v_inserted = 1 then
    update public.posts
    set vote_count = vote_count + 1
    where id = p_post_id
    returning vote_count into v_count;
  end if;

  return jsonb_build_object(
    'ok', true,
    'vote_count', v_count
  );
end;
$$;

-- إتاحة الإجراءات للجلسات المسجّلة فقط.
revoke all
  on function public.register_visitor(text, text, text, text)
  from public, anon, authenticated;

revoke all
  on function public.my_ballots()
  from public, anon, authenticated;

revoke all
  on function public.cast_vote(uuid)
  from public, anon, authenticated;

grant execute
  on function public.register_visitor(text, text, text, text)
  to authenticated;

grant execute
  on function public.my_ballots()
  to authenticated;

grant execute
  on function public.cast_vote(uuid)
  to authenticated;

-- تحديث تعريفات الإجراءات لدى واجهة الاتصال.
notify pgrst, 'reload schema';

commit;                                         
