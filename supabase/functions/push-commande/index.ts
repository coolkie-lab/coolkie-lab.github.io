// Coolkie : notification push sur les téléphones des admins à chaque nouvelle commande.
// Appelée par la base (trigger orders_push) avec {order_id}, ou par gestion avec {action:'key'|'test'}.
// Les clés VAPID sont créées ici au premier appel et rangées dans push_keys (inaccessible au site).
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (d: unknown, s = 200) => new Response(JSON.stringify(d), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

let K: { public_key: string; private_key: string } | null = null;
async function keys() {
  if (K) return K;
  let { data } = await sb.from("push_keys").select("public_key,private_key").eq("id", 1).maybeSingle();
  if (!data) {
    const k = webpush.generateVAPIDKeys();
    await sb.from("push_keys").upsert({ id: 1, public_key: k.publicKey, private_key: k.privateKey }, { onConflict: "id", ignoreDuplicates: true });
    ({ data } = await sb.from("push_keys").select("public_key,private_key").eq("id", 1).single());
  }
  K = data!;
  webpush.setVapidDetails("https://coolkie-lab.be", K.public_key, K.private_key);
  return K;
}

type Sub = { endpoint: string; p256dh: string; auth: string };
async function send(subs: Sub[], msg: Record<string, unknown>) {
  await keys();
  let ok = 0, ko = 0;
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(msg), { TTL: 86400, urgency: "high" });
      ok++;
    } catch (e) {
      ko++;
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint);
      console.error("push", code, (e as Error).message);
    }
  }));
  return { envoyes: ok, echecs: ko };
}

async function adminSubs(uid?: string) {
  let q = sb.from("push_subscriptions").select("endpoint,p256dh,auth,user_id,profiles!inner(is_admin)").eq("profiles.is_admin", true);
  if (uid) q = q.eq("user_id", uid);
  const { data } = await q;
  return (data || []) as Sub[];
}

const eur = (n: number) => (Math.round(n * 100) / 100).toFixed(2).replace(".", ",") + " €";
const JOURS = ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."];
const POINTS: Record<string, string> = { uccle: "Uccle", woluwe: "Woluwe", livraison: "Livraison", autre: "Autre" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* vide */ }

  if (body.action === "key") return json({ key: (await keys()).public_key });

  if (body.action === "test") {
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await sb.auth.getUser(token);
    if (!u?.user) return json({ error: "Connecte-toi" }, 401);
    const { data: p } = await sb.from("profiles").select("is_admin").eq("id", u.user.id).maybeSingle();
    if (!p?.is_admin) return json({ error: "Réservé aux admins" }, 403);
    const subs = await adminSubs(u.user.id);
    if (!subs.length) return json({ envoyes: 0, echecs: 0 });
    return json(await send(subs, { title: "🍪 Test Coolkie", body: "Les notifications de commande fonctionnent sur cet appareil.", url: "gestion.html#commandes", tag: "test" }));
  }

  const id = Number(body.order_id);
  if (!id) return json({ error: "order_id manquant" }, 400);
  // Une seule notification par commande, seulement pour une commande en ligne toute récente.
  const since = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const { data: o } = await sb.from("orders").update({ push_envoye: true })
    .eq("id", id).eq("push_envoye", false).eq("source", "en_ligne").gte("created_at", since)
    .select("id,lignes,total,point,date_retrait,user_id").maybeSingle();
  if (!o) return json({ skip: true });
  const lignes = (o.lignes || []) as { nom: string; qte: number }[];
  const boites = lignes.reduce((a, l) => a + (+l.qte || 0), 0);
  const d = new Date(o.date_retrait + "T12:00:00Z");
  const quand = JOURS[d.getUTCDay()] + " " + String(d.getUTCDate()).padStart(2, "0") + "/" + String(d.getUTCMonth() + 1).padStart(2, "0");
  const detail = lignes.map((l) => l.qte + " " + String(l.nom).replace(/^coolkie\s+/i, "")).join(", ");
  const subs = await adminSubs();
  const r = subs.length ? await send(subs, {
    title: "🍪 Nouvelle commande #" + o.id,
    body: boites + " boîte" + (boites > 1 ? "s" : "") + " · " + eur(+o.total) + " · " + (POINTS[o.point] || o.point) + ", " + quand + (detail ? "\n" + detail.slice(0, 120) : ""),
    url: "gestion.html#commandes",
    tag: "cmd-" + o.id,
  }) : { envoyes: 0, echecs: 0 };
  return json(r);
});
