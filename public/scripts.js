import { supabaseUrl, supabaseAnonKey } from "./supabase-config.js";

const $ = (selector) => document.querySelector(selector);
const number = (value) => new Intl.NumberFormat("ar-SA").format(value);

const MAX_FILE_SIZE = 5 * 1024 * 1024;
const TYPES = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "application/pdf": "pdf",
};

let supabase, user, profile, channel, poll, previewUrl;
let posts = [];
let voted = new Set();
let voting = new Set();
let ready = false;
let authBusy = false;
let version = 0;
let refreshing = false;
let refreshAgain = false;
let uploadDraft = null;

function notice(text, error = false) {
  $("#notice").textContent = text;
  $("#notice").classList.toggle("error", error);
}

function view(id) {
  for (const name of ["login", "home", "upload", "gallery"]) {
    $("#" + name).hidden = name !== id;
  }

  const signedIn = Boolean(user && profile) && id !== "login";

  $("#pageNav").hidden = !signedIn;
  $("#logout").hidden = !signedIn;
  $("#navHome").hidden = !signedIn || id === "home";
  $("#navUpload").hidden = !signedIn || id !== "gallery";
  $("#navGallery").hidden = !signedIn || id !== "upload";

  window.scrollTo({ top: 0, behavior: "smooth" });
}

function failure(error) {
  const messages = {
    anonymous_provider_disabled:
      "فعّلي Allow anonymous sign-ins في إعدادات Supabase.",
    over_request_rate_limit:
      "طلبات كثيرة. انتظري قليلًا ثم حاولي مجددًا.",
    "23505":
      "الرقم الأكاديمي مسجل مسبقًا، أو سبق حفظ هذه المشاركة.",
    "42501":
      "صلاحيات الحفظ لم تُجهّز بعد. نحتاج إكمال إعداد Supabase.",
    "42P01":
      "جداول الموقع لم تُنشأ بعد. نحتاج إكمال إعداد قاعدة البيانات.",
    PGRST202:
      "إجراءات الحفظ والتصويت لم تُجهّز بعد في قاعدة البيانات.",
    PGRST205:
      "جداول الموقع لم تُجهّز بعد في قاعدة البيانات.",
  };

  notice(
    messages[error.code] ||
      error.message ||
      "تعذر الاتصال. حاولي مجددًا.",
    true,
  );
}

async function busy(form, action) {
  const button = form.querySelector("button[type=submit]");
  button.disabled = true;

  try {
    await action();
  } catch (error) {
    failure(error);
  } finally {
    button.disabled = false;
  }
}

function el(tag, text, className) {
  const element = document.createElement(tag);
  if (text != null) element.textContent = text;
  if (className) element.className = className;
  return element;
}

// إضافة أزرار التنقل إلى رأس الصفحة.
function setupNavigation() {
  const header = document.querySelector("header");
  const logout = $("#logout");
  const nav = el("nav");

  nav.id = "pageNav";
  nav.hidden = true;
  nav.setAttribute("aria-label", "التنقل بين صفحات المسابقة");

  Object.assign(nav.style, {
    display: "flex",
    flexWrap: "wrap",
    gap: "8px",
    alignItems: "center",
  });

  header.style.flexWrap = "wrap";
  header.style.gap = "16px";

  for (const [id, target, label] of [
    ["navGallery", "gallery", "التصويت"],
    ["navUpload", "upload", "إرفاق بوستر"],
    ["navHome", "home", "العودة إلى الصفحة الرئيسية"],
  ]) {
    const button = el("button", label, "quiet");
    button.type = "button";
    button.id = id;
    button.dataset.view = target;
    nav.append(button);
  }

  logout.textContent = "تسجيل الخروج";
  nav.append(logout);
  header.append(nav);

  // زر العودة أصبح موجودًا في رأس الصفحة.
  document.querySelectorAll(".back[data-view='home']").forEach((button) => {
    button.hidden = true;
  });
}

function render() {
  const grid = $("#grid");
  grid.replaceChildren();

  $("#postCount").textContent = number(posts.length);
  $("#voteCount").textContent = number(
    posts.reduce((total, post) => total + Number(post.vote_count || 0), 0),
  );

  if (!posts.length) {
    const empty = el("div", null, "empty");
    empty.append(
      el("h2", "بانتظار أول إبداع"),
      el("p", "لا توجد بوسترات بعد."),
    );
    grid.append(empty);
    return;
  }

  for (const post of posts) {
    const title = "مشاركة رقم " + number(post.display_number);
    const url = supabase.storage
      .from("posters")
      .getPublicUrl(post.path).data.publicUrl;

    const card = el("article", null, "work");

    if (post.mime_type.startsWith("image/")) {
      const image = el("img");
      image.src = url;
      image.alt = title;
      image.loading = "lazy";
      card.append(image);
    } else {
      card.append(el("div", "PDF", "empty"));
    }

    const details = el("div", null, "details");
    details.append(el("h2", title));

    const link = el("a", "عرض البوستر");
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    details.append(link);

    const count = el("div", null, "count");
    count.append(
      el("span", "عدد الأصوات"),
      el("strong", number(post.vote_count || 0)),
    );
    details.append(count);

    const button = el(
      "button",
      voted.has(post.id) ? "تم التصويت ✓" : "تصويت",
      "primary",
    );

    button.type = "button";
    button.disabled = voted.has(post.id) || voting.has(post.id);

    button.onclick = async () => {
      if (!user || !profile || voting.has(post.id)) return;

      const currentVersion = version;
      voting.add(post.id);
      button.disabled = true;

      try {
        const { error } = await supabase.rpc("cast_vote", {
          p_post_id: post.id,
        });

        if (error) throw error;
        if (currentVersion !== version) return;

        voted.add(post.id);
        notice("تم حفظ صوتك بنجاح.");
        await refresh();
      } catch (error) {
        if (currentVersion === version) failure(error);
      } finally {
        voting.delete(post.id);
        render();
      }
    };

    details.append(button);
    card.append(details);
    grid.append(card);
  }
}

async function readAll(query) {
  const rows = [];

  for (let start = 0; ; start += 200) {
    const { data, error } = await query().range(start, start + 199);
    if (error) throw error;

    rows.push(...data);
    if (data.length < 200) return rows;
  }
}

async function refresh() {
  if (!user || !profile) return;

  if (refreshing) {
    refreshAgain = true;
    return;
  }

  refreshing = true;
  const currentVersion = version;

  try {
    const [items, votes] = await Promise.all([
      readAll(() =>
        supabase
          .from("posts")
          .select("id,display_number,path,mime_type,vote_count,created_at")
          .order("display_number", { ascending: false }),
      ),
      readAll(() => supabase.rpc("my_ballots")),
    ]);

    if (version !== currentVersion) return;

    posts = items;
    voted = new Set(votes.map((vote) => vote.post_id));
    render();
  } finally {
    refreshing = false;

    if (refreshAgain) {
      refreshAgain = false;
      void refresh().catch(failure);
    }
  }
}

function stopLive() {
  clearInterval(poll);

  if (channel) {
    const previous = channel;
    channel = null;
    void supabase.removeChannel(previous);
  }
}

function startLive() {
  stopLive();
  const currentVersion = version;

  channel = supabase
    .channel("posters-" + crypto.randomUUID())
    .on(
      "postgres_changes",
      {
        event: "*",
        schema: "public",
        table: "posts",
      },
      () => {
        if (version === currentVersion) {
          void refresh().catch(failure);
        }
      },
    )
    .subscribe((status) => {
      if (version !== currentVersion) return;

      $("#live").textContent =
        status === "SUBSCRIBED"
          ? "● نتائج مباشرة"
          : "جارٍ الاتصال • تحديث دوري";

      if (status === "SUBSCRIBED") {
        void refresh().catch(failure);
      }
    });

  poll = setInterval(() => {
    if (!document.hidden) {
      void refresh().catch(failure);
    }
  }, 30000);
}

function clearPreview() {
  if (previewUrl) URL.revokeObjectURL(previewUrl);
  previewUrl = null;
  $("#preview").replaceChildren();
}

function clearState() {
  version++;
  stopLive();

  user = null;
  profile = null;
  posts = [];
  voted.clear();
  voting.clear();
  uploadDraft = null;

  clearPreview();
  $("#uploadForm").reset();
  $("#loginForm").reset();
  $("#progress").hidden = true;
  $("#logout").hidden = true;
  $("#welcome").textContent = "";

  render();
  view("login");
}

async function enter(currentUser) {
  const currentVersion = ++version;
  stopLive();

  user = currentUser;
  profile = null;

  const { data, error } = await supabase
    .from("profiles")
    .select("full_name,academic_number,email,gender")
    .eq("id", user.id)
    .maybeSingle();

  if (error) throw error;
  if (currentVersion !== version) return;

  if (!data?.email || !data?.gender) {
    view("login");
    return;
  }

  profile = data;
  $("#welcome").textContent = "أهلًا، " + profile.full_name;
  $("#logout").hidden = false;

  view("home");
  startLive();
  await refresh();
}

setupNavigation();

$("#loginForm").onsubmit = (event) => {
  event.preventDefault();

  if (!ready) {
    notice("الاتصال غير جاهز. انتظري قليلًا أو حدّثي الصفحة.", true);
    return;
  }

  if (authBusy) return;

  void busy(event.target, async () => {
    authBusy = true;

    try {
      const values = Object.fromEntries(new FormData(event.target));

      const name = values.name.trim().replace(/\s+/g, " ");
      const academic = values.academic
        .trim()
        .normalize("NFKC")
        .replace(/[٠-٩]/g, (c) => String(c.charCodeAt(0) - 1632))
        .replace(/[۰-۹]/g, (c) => String(c.charCodeAt(0) - 1776))
        .toUpperCase();

      const email = values.email.trim().toLowerCase();
      const gender = values.gender;

      if (name.split(" ").length < 3) {
        throw new Error("اكتبي الاسم الثلاثي كاملًا.");
      }

      if (!/^[A-Z0-9-]{2,30}$/.test(academic)) {
        throw new Error("الرقم الأكاديمي غير صالح.");
      }

      if (!["طالب", "طالبة"].includes(gender)) {
        throw new Error("اختاري طالب أو طالبة.");
      }

      notice("جارٍ حفظ البيانات…");

      const sessionResult = await supabase.auth.getSession();
      if (sessionResult.error) throw sessionResult.error;

      let currentUser = sessionResult.data.session?.user;

      if (!currentUser) {
        const result = await supabase.auth.signInAnonymously();
        if (result.error) throw result.error;
        currentUser = result.data.user;
      }

      const { error } = await supabase.rpc("register_visitor", {
        p_full_name: name,
        p_academic_number: academic,
        p_email: email,
        p_gender: gender,
      });

      if (error) throw error;

      await enter(currentUser);
      notice("");
    } finally {
      authBusy = false;
    }
  });
};

$("#logout").onclick = async () => {
  if (!supabase) return;

  const button = $("#logout");
  button.disabled = true;

  try {
    const { error } = await supabase.auth.signOut({
      scope: "local",
    });

    if (error) throw error;

    clearState();
    notice("تم تسجيل الخروج.");
  } catch (error) {
    failure(error);
  } finally {
    button.disabled = false;
  }
};

document.querySelectorAll("[data-view]").forEach((button) => {
  button.onclick = () => {
    if (!profile) {
      notice("سجّلي الدخول أولًا.", true);
      view("login");
      return;
    }

    notice("");
    view(button.dataset.view);

    if (button.dataset.view === "gallery") {
      void refresh().catch(failure);
    }
  };
});

$("#file").onchange = () => {
  clearPreview();

  const file = $("#file").files[0];
  if (!file) return;

  if (file.type.startsWith("image/")) {
    previewUrl = URL.createObjectURL(file);
    const image = el("img");
    image.src = previewUrl;
    image.alt = "معاينة البوستر";
    $("#preview").append(image);
  } else {
    $("#preview").append(el("p", "الملف المختار: " + file.name));
  }
};

$("#uploadForm").onsubmit = (event) => {
  event.preventDefault();

  void busy(event.target, async () => {
    if (!user || !profile) {
      throw new Error("سجّلي الدخول أولًا.");
    }

    const file = $("#file").files[0];

    if (!file || !TYPES[file.type]) {
      throw new Error("اختاري صورة JPG أو PNG أو WEBP أو ملف PDF.");
    }

    if (!file.size || file.size > MAX_FILE_SIZE) {
      throw new Error("اختاري ملفًا غير فارغ، بحجم لا يتجاوز 5 ميجابايت.");
    }

    if (
      uploadDraft &&
      (uploadDraft.file.name !== file.name ||
        uploadDraft.file.size !== file.size ||
        uploadDraft.file.lastModified !== file.lastModified)
    ) {
      throw new Error(
        "هناك ملف رُفع ولم يكتمل نشره. أعيدي اختيار نفس الملف وحاولي نشره مجددًا، أو حدّثي الصفحة لبدء مشاركة أخرى.",
      );
    }

    if (!uploadDraft) {
      const id = crypto.randomUUID();

      uploadDraft = {
        id,
        file,
        uid: user.id,
        path: user.id + "/" + id + "." + TYPES[file.type],
        uploaded: false,
      };
    }

    const draft = uploadDraft;

    $("#progress").hidden = false;
    $("#progress").removeAttribute("value");
    notice("جارٍ رفع البوستر وحفظ المشاركة…");

    try {
      if (!draft.uploaded) {
        const { error } = await supabase.storage
          .from("posters")
          .upload(draft.path, file, {
            contentType: file.type,
            upsert: false,
          });

        if (error) throw error;
        draft.uploaded = true;
      }

      const { error } = await supabase.rpc("publish_poster", {
        p_post_id: draft.id,
        p_path: draft.path,
      });

      if (error) throw error;
      if (user?.id !== draft.uid) return;

      uploadDraft = null;
      event.target.reset();
      clearPreview();

      view("gallery");
      notice("تم حفظ البوستر ونشره بنجاح.");
      await refresh();
    } catch (error) {
      if (!draft.uploaded) {
        uploadDraft = null;
      }

      if (draft.uploaded && uploadDraft) {
        throw new Error(
          "تم رفع الملف، لكن لم يكتمل نشر المشاركة. اضغطي نشر البوستر مجددًا. " +
            (error.message || ""),
        );
      }

      throw error;
    } finally {
      $("#progress").hidden = true;
    }
  });
};

async function boot() {
  view("login");

  if (!supabaseUrl || !supabaseAnonKey) {
    notice("أكملي إعدادات supabase-config.js أولًا.", true);
    return;
  }

  try {
    const { createClient } = await import(
      "https://esm.sh/@supabase/supabase-js@2"
    );

    supabase = createClient(
      supabaseUrl.trim(),
      supabaseAnonKey.trim(),
    );

    const { data, error } = await supabase.auth.getSession();
    if (error) throw error;

    supabase.auth.onAuthStateChange((event, session) => {
      if (event === "SIGNED_OUT") {
        setTimeout(() => clearState(), 0);
      }

      if (event === "SIGNED_IN") {
        setTimeout(() => {
          if (
            !authBusy &&
            session &&
            session.user.id !== user?.id
          ) {
            void enter(session.user).catch(failure);
          }
        }, 0);
      }
    });

    ready = true;

    if (data.session) {
      await enter(data.session.user);
    } else {
      notice("");
    }
  } catch (error) {
    failure(error);
  }
}

window.addEventListener("online", () => {
  if (profile) {
    void refresh().catch(failure);
  }
});

void boot();