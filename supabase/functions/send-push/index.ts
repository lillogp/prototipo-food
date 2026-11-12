import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type", "Access-Control-Allow-Methods": "GET,POST,OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));

async function cfg() {
  const { data } = await db.from("push_config").select("key,value");
  const m: Record<string, string> = {};
  (data || []).forEach((r: { key: string; value: string }) => (m[r.key] = r.value));
  return m;
}
async function vapid() {
  let m = await cfg();
  if (!m.vapid_public) {
    const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
    const jwk = await crypto.subtle.exportKey("jwk", kp.privateKey);
    const pub = new Uint8Array(65);
    pub[0] = 4; pub.set(unb(jwk.x!), 1); pub.set(unb(jwk.y!), 33);
    await db.from("push_config").upsert([{ key: "vapid_public", value: b64u(pub) }, { key: "vapid_private", value: jwk.d! }]);
    m = await cfg();
  }
  return m;
}

const NOTIF: Record<string, [string, string]> = {
  follow: ["follows", "ha iniziato a seguirti"],
  follow_request: ["follows", "ha chiesto di seguirti"],
  follow_accepted: ["follows", "ha accettato la tua richiesta"],
  like: ["likes", "ha messo mi piace a un tuo piatto"],
  comment_like: ["likes", "ha messo mi piace al tuo commento"],
  comment: ["comments", "ha commentato un tuo piatto"],
  client_joined: ["pro", "è ora tuo cliente"],
  plan: ["pro", "ti ha inviato un nuovo piano"],
  secret_request: ["follows", "vuole vedere i segreti di una tua ricetta"],
  secret_accepted: ["follows", "ti ha sbloccato i segreti di una ricetta"],
  tag: ["follows", "ti ha taggato in un piatto"],
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  const m = await vapid();
  if (req.method === "GET") return json({ key: m.vapid_public });
  if (req.headers.get("x-hook-secret") !== m.hook_secret) return json({ error: "non autorizzato" }, 401);

  const { table, record } = await req.json();
  let to = "", actor = "", cat = "", text = "", tag = "", url = "./index.html";
  if (table === "dm_messages") {
    const { data: c } = await db.from("conversations").select("user_a,user_b,status").eq("id", record.conv_id).maybeSingle();
    if (!c || c.status === "declined") return json({ ok: true });
    actor = record.sender_id; to = actor === c.user_a ? c.user_b : c.user_a; cat = "messages";
    const t = String(record.body || "").replace(/\[\[rid?:.+?\]\]/, "").trim();
    text = t || "Ti ha inviato una ricetta";
    if (c.status === "pending") text = "Richiesta di messaggio: " + text;
    tag = "dm-" + record.conv_id; url = "./index.html?go=dm:" + record.conv_id;
  } else if (table === "notifications") {
    const n = NOTIF[record.type]; if (!n) return json({ ok: true });
    to = record.user_id; actor = record.actor_id; cat = n[0]; text = n[1]; tag = "n-" + record.id; url = "./index.html?go=notifs";
  } else return json({ ok: true });
  if (!to || !actor || to === actor) return json({ ok: true });

  const { data: prof } = await db.from("profiles").select("push_prefs").eq("id", to).maybeSingle();
  if (!prof || (prof.push_prefs && prof.push_prefs[cat] === false)) return json({ ok: true });
  const { data: who } = await db.from("profiles").select("display_name,handle,avatar_url").eq("id", actor).maybeSingle();
  const name = who?.display_name || (who?.handle ? "@" + who.handle : "Frog’s");
  const title = table === "dm_messages" ? name : "Frog’s";
  const body = table === "dm_messages" ? text : name + " " + text;

  const { data: subs } = await db.from("push_subscriptions").select("id,endpoint,p256dh,auth").eq("user_id", to);
  if (!subs || !subs.length) return json({ ok: true });
  webpush.setVapidDetails("https://frogsapp.com/", m.vapid_public, m.vapid_private);
  const ORIGIN = "https://frogsapp.com/";
  const payload = JSON.stringify({ title, body, tag, url, icon: who?.avatar_url || ORIGIN + "icon-192.png", badge: ORIGIN + "badge-96.png" });
  await Promise.all(subs.map(async (s: { id: number; endpoint: string; p256dh: string; auth: string }) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400 });
    } catch (e) {
      const sc = (e as { statusCode?: number }).statusCode;
      if (sc === 404 || sc === 410) await db.from("push_subscriptions").delete().eq("id", s.id);
    }
  }));
  return json({ ok: true });
});
