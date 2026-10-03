-- مسابقة تصويت البوسترات | كلية الغد
-- نسخة إعداد حالية مستخرجة من تعريفات قاعدة البيانات بتاريخ 2026-10-03.
-- للحفظ في GitHub باسم supabase/01-current-schema.sql.
-- تستخدم مرة واحدة في مشروع Supabase جديد وفارغ، بحساب postgres في SQL Editor.
-- لا تشغليها على مشروعك الحالي؛ الإعدادات موجودة فيه بالفعل.
-- تتضمن تعديل التسجيل والتصويت: لا يلزم تشغيل 02-register-and-voting.sql بعدها.
-- ملف 02 محفوظ للتاريخ فقط، وليس خطوة إضافية لإعداد هذه النسخة.
-- لا تحتوي على المشاركين أو الأصوات أو ملفات البوسترات أو مفاتيح الاتصال.
-- بعد إعداد مشروع جديد: فعّلي Allow new users to sign up وAllow anonymous sign-ins،
-- ثم حدّثي public/supabase-config.js بعنوان المشروع ومفتاحه العام.
-- لا تنشئ هذه النسخة إعدادات Auth أو Netlify تلقائياً.
-- مصدر إعداد Auth: https://supabase.com/docs/guides/auth/auth-anonymous
-- هذه إعادة بناء للإعداد الحالي، وليست النص الأصلي لتاريخ إنشاء المشروع.
-- جرى التحقق من مطابقة مكوناتها لملف التصدير، ولم تُختبر على Supabase جديد.
-- الملكية والدوال تفترض دور postgres القياسي. صلاحيات sequences الافتراضية
-- وإعدادات المشروع العامة غير مشمولة بالتصدير؛ تسلسل الترقيم يبدأ من 1.
-- تظل قواعد التحقق الحالية كما هي: البريد بصيغة صحيحة فقط، دون تحقق ملكيته
-- أو نطاق الجامعة؛ ومنع تكرار التصويت يعتمد على الرقم الأكاديمي المُدخل.


-- Source SHA-256: 8e28fde9624340243ee6ea8a8c2a3bba666f677e29a93cd81bbcd2ee78cb83ac

BEGIN;
SET LOCAL search_path = public, pg_catalog;

DO $guard$
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Run this setup as postgres in a new Supabase project.';
  END IF;
  IF to_regclass('public.profiles') IS NOT NULL
     OR to_regclass('public.posts') IS NOT NULL
     OR to_regclass('public.votes') IS NOT NULL
     OR to_regnamespace('ghad_private') IS NOT NULL
     OR EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'posters') THEN
    RAISE EXCEPTION 'Project objects already exist. This file is for a new project only.';
  END IF;
END;
$guard$;

CREATE SCHEMA ghad_private AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA ghad_private FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

CREATE TABLE "public"."profiles" (
  "id" uuid NOT NULL,
  "full_name" text NOT NULL,
  "academic_number" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "email" text,
  "gender" text
);

CREATE TABLE "public"."posts" (
  "id" uuid NOT NULL,
  "display_number" bigint GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 NO CYCLE) NOT NULL,
  "path" text NOT NULL,
  "mime_type" text NOT NULL,
  "vote_count" bigint DEFAULT 0 NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE "public"."votes" (
  "user_id" uuid NOT NULL,
  "post_id" uuid NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE "ghad_private"."poster_owners" (
  "post_id" uuid NOT NULL,
  "user_id" uuid NOT NULL
);

ALTER TABLE "ghad_private"."poster_owners" ADD CONSTRAINT "poster_owners_pkey" PRIMARY KEY (post_id);

ALTER TABLE "public"."posts" ADD CONSTRAINT "posts_display_number_key" UNIQUE (display_number);

ALTER TABLE "public"."posts" ADD CONSTRAINT "posts_mime_type_check" CHECK (mime_type = ANY (ARRAY['image/jpeg'::text, 'image/png'::text, 'image/webp'::text, 'application/pdf'::text]));

ALTER TABLE "public"."posts" ADD CONSTRAINT "posts_path_key" UNIQUE (path);

ALTER TABLE "public"."posts" ADD CONSTRAINT "posts_pkey" PRIMARY KEY (id);

ALTER TABLE "public"."posts" ADD CONSTRAINT "posts_vote_count_check" CHECK (vote_count >= 0);

ALTER TABLE "public"."profiles" ADD CONSTRAINT "profiles_academic_number_check" CHECK (academic_number ~ '^[A-Z0-9-]{2,30}$'::text);

ALTER TABLE "public"."profiles" ADD CONSTRAINT "profiles_full_name_check" CHECK (char_length(full_name) >= 3 AND char_length(full_name) <= 100);

ALTER TABLE "public"."profiles" ADD CONSTRAINT "profiles_pkey" PRIMARY KEY (id);

ALTER TABLE "public"."votes" ADD CONSTRAINT "votes_pkey" PRIMARY KEY (user_id, post_id);

ALTER TABLE "ghad_private"."poster_owners" ADD CONSTRAINT "poster_owners_post_id_fkey" FOREIGN KEY (post_id) REFERENCES public.posts(id);

ALTER TABLE "ghad_private"."poster_owners" ADD CONSTRAINT "poster_owners_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id);

ALTER TABLE "public"."profiles" ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id);

ALTER TABLE "public"."votes" ADD CONSTRAINT "votes_post_id_fkey" FOREIGN KEY (post_id) REFERENCES public.posts(id);

ALTER TABLE "public"."votes" ADD CONSTRAINT "votes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id);

CREATE INDEX profiles_academic_lookup ON public.profiles USING btree (academic_number);

ALTER TABLE "ghad_private"."poster_owners" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE "ghad_private"."poster_owners" FROM PUBLIC, anon, authenticated, service_role;

ALTER TABLE "public"."posts" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE "public"."posts" FROM PUBLIC, anon, authenticated, service_role;

GRANT TRUNCATE, REFERENCES, TRIGGER ON TABLE "public"."posts" TO "service_role";

DO $maintain$ BEGIN IF current_setting('server_version_num')::int >= 170000 THEN EXECUTE 'GRANT MAINTAIN ON TABLE "public"."posts" TO "service_role"'; END IF; END; $maintain$;

GRANT SELECT ON TABLE "public"."posts" TO "authenticated";

ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE "public"."profiles" FROM PUBLIC, anon, authenticated, service_role;

GRANT TRUNCATE, REFERENCES, TRIGGER ON TABLE "public"."profiles" TO "service_role";

DO $maintain$ BEGIN IF current_setting('server_version_num')::int >= 170000 THEN EXECUTE 'GRANT MAINTAIN ON TABLE "public"."profiles" TO "service_role"'; END IF; END; $maintain$;

GRANT SELECT ON TABLE "public"."profiles" TO "authenticated";

ALTER TABLE "public"."votes" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE "public"."votes" FROM PUBLIC, anon, authenticated, service_role;

GRANT TRUNCATE, REFERENCES, TRIGGER ON TABLE "public"."votes" TO "service_role";

DO $maintain$ BEGIN IF current_setting('server_version_num')::int >= 170000 THEN EXECUTE 'GRANT MAINTAIN ON TABLE "public"."votes" TO "service_role"'; END IF; END; $maintain$;

GRANT SELECT ON TABLE "public"."votes" TO "authenticated";

CREATE OR REPLACE FUNCTION public.cast_vote(p_post_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

REVOKE ALL ON FUNCTION "public"."cast_vote"(uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION "public"."cast_vote"(uuid) TO "authenticated";

CREATE OR REPLACE FUNCTION public.my_ballots()
 RETURNS TABLE(post_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

REVOKE ALL ON FUNCTION "public"."my_ballots"() FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION "public"."my_ballots"() TO "authenticated";

CREATE OR REPLACE FUNCTION public.publish_poster(p_post_id uuid, p_path text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_metadata jsonb;
  v_type text;
  v_size numeric;
  v_extension text;
begin
  if v_uid is null then
    raise exception 'سجّلي الدخول أولًا.';
  end if;

  if p_post_id is null or p_path is null then
    raise exception 'بيانات المشاركة ناقصة.';
  end if;

  if not exists (
    select 1 from public.profiles where id = v_uid
  ) then
    raise exception 'أكملي بيانات الحساب أولًا.';
  end if;

  -- يمنع إنشاء مشاركتين عند إعادة نفس الطلب.
  perform pg_advisory_xact_lock(
    hashtextextended(p_post_id::text, 0)
  );

  select user_id
    into v_owner
    from ghad_private.poster_owners
    where post_id = p_post_id;

  if found then
    if v_owner <> v_uid or not exists (
      select 1 from public.posts
      where id = p_post_id and path = p_path
    ) then
      raise exception 'هذه المشاركة لا تخص الحساب.';
    end if;

    return jsonb_build_object('ok', true);
  end if;

  select metadata
    into v_metadata
    from storage.objects
    where bucket_id = 'posters'
      and name = p_path
      and owner_id = v_uid::text
    for share;

  if not found then
    raise exception 'لم نجد الملف المرفوع لهذا الحساب.';
  end if;

  v_type := v_metadata ->> 'mimetype';
  v_size := coalesce(
    nullif(v_metadata ->> 'size', '')::numeric,
    0
  );

  v_extension := case v_type
    when 'image/jpeg' then 'jpg'
    when 'image/png' then 'png'
    when 'image/webp' then 'webp'
    when 'application/pdf' then 'pdf'
    else null
  end;

  if v_extension is null then
    raise exception 'نوع الملف غير مسموح.';
  end if;

  if v_size <= 0 or v_size > 5242880 then
    raise exception 'حجم الملف يجب ألا يتجاوز 5 ميجابايت.';
  end if;

  if p_path <> (
    v_uid::text || '/' ||
    p_post_id::text || '.' || v_extension
  ) then
    raise exception 'مسار الملف غير صالح.';
  end if;

  insert into public.posts (
    id,
    path,
    mime_type
  )
  values (
    p_post_id,
    p_path,
    v_type
  );

  insert into ghad_private.poster_owners (
    post_id,
    user_id
  )
  values (
    p_post_id,
    v_uid
  );

  return jsonb_build_object('ok', true);
end;
$function$;

REVOKE ALL ON FUNCTION "public"."publish_poster"(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION "public"."publish_poster"(uuid, text) TO "authenticated";

CREATE OR REPLACE FUNCTION public.register_profile(p_full_name text, p_academic_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_name text;
  v_academic text;
  v_existing text;
begin
  if v_uid is null then
    raise exception 'سجّلي الدخول أولًا.';
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

  if char_length(v_name) > 100
     or cardinality(regexp_split_to_array(v_name, '\s+')) < 3
  then
    raise exception 'اكتبي الاسم الثلاثي كاملًا.';
  end if;

  if v_academic !~ '^[A-Z0-9-]{2,30}$' then
    raise exception 'الرقم الأكاديمي غير صالح.';
  end if;

  insert into public.profiles (
    id,
    full_name,
    academic_number
  )
  values (
    v_uid,
    v_name,
    v_academic
  )
  on conflict (id) do nothing;

  select academic_number
    into v_existing
    from public.profiles
    where id = v_uid;

  if v_existing is distinct from v_academic then
    raise exception 'الحساب مرتبط برقم أكاديمي آخر.';
  end if;

  return jsonb_build_object('ok', true);
end;
$function$;

REVOKE ALL ON FUNCTION "public"."register_profile"(text, text) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.register_visitor(p_full_name text, p_academic_number text, p_email text, p_gender text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

REVOKE ALL ON FUNCTION "public"."register_visitor"(text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION "public"."register_visitor"(text, text, text, text) TO "authenticated";

CREATE POLICY "ghad_posts_read" ON "public"."posts" AS PERMISSIVE FOR SELECT TO "authenticated"
  USING (true);

CREATE POLICY "ghad_profile_read_own" ON "public"."profiles" AS PERMISSIVE FOR SELECT TO "authenticated"
  USING ((id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "ghad_votes_read_own" ON "public"."votes" AS PERMISSIVE FOR SELECT TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "ghad_posters_upload_own" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated"
  WITH CHECK (((bucket_id = 'posters'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text) AND (EXISTS ( SELECT 1
   FROM public.profiles
  WHERE (profiles.id = ( SELECT auth.uid() AS uid))))));

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types) VALUES ('posters', 'posters', true, 5242880, ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']::text[]);

ALTER PUBLICATION "supabase_realtime" ADD TABLE "public"."posts";

NOTIFY pgrst, 'reload schema';
COMMIT;
