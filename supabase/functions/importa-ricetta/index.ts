// Importa una ricetta da un link: legge i dati strutturati (schema.org Recipe) della pagina e li restituisce
// gia' nel formato dell'app (nome, minuti, porzioni, ingredienti {n,q,u}, passaggi). Non salva nulla:
// il salvataggio lo fa l'app, nel ricettario privato, dopo il controllo dell'utente.
// Richiede un utente loggato (verify_jwt attivo, come da default Supabase).

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST,OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

function urlNonAmmesso(u: URL): boolean {
  if (u.protocol !== "https:" && u.protocol !== "http:") return true;
  const h = u.hostname.toLowerCase();
  if (h === "localhost" || h.endsWith(".local") || h.endsWith(".internal") || !h.includes(".")) return true;
  if (/^[0-9.]+$/.test(h) || h.includes(":") || h.startsWith("[")) return true;
  return false;
}

function pulisci(t: unknown): string {
  return String(t ?? "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;/g, "'")
    .replace(/&egrave;/g, "è").replace(/&eacute;/g, "é").replace(/&agrave;/g, "à")
    .replace(/\s+/g, " ")
    .trim();
}

function minuti(iso?: unknown): number | null {
  if (typeof iso !== "string") return null;
  const m = /^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?/.exec(iso);
  if (!m) return null;
  const tot = Number(m[1] || 0) * 1440 + Number(m[2] || 0) * 60 + Number(m[3] || 0);
  return tot > 0 ? tot : null;
}

function porzioni(y: unknown): number | null {
  const s = Array.isArray(y) ? String(y[0]) : String(y ?? "");
  const m = /\d+/.exec(s);
  const n = m ? Number(m[0]) : 0;
  return n >= 1 && n <= 50 ? n : null;
}

// ---- ingredienti: "Riso 320 g" / "320 g di riso" / "2 uova" / "sale q.b." -> { n, q, u } ----
const UNITA: Record<string, string> = {
  g: "g", gr: "g", grammo: "g", grammi: "g", kg: "kg", chilo: "kg", chili: "kg", ml: "ml", l: "l", lt: "l", litro: "l", litri: "l",
  cucchiaio: "cucchiaio", cucchiai: "cucchiaio", cucchiaino: "cucchiaino", cucchiaini: "cucchiaino",
  pizzico: "pizzico", pizzichi: "pizzico", pezzo: "pezzi", pezzi: "pezzi", spicchio: "spicchio", spicchi: "spicchio",
  mazzetto: "mazzetto", mazzetti: "mazzetto", rametto: "rametto", rametti: "rametto", foglia: "foglie", foglie: "foglie",
  foglio: "fogli", fogli: "fogli", bustina: "pezzi", bustine: "pezzi",
};
const NUM = "(\\d+(?:[.,]\\d+)?(?:\\s*\\/\\s*\\d+)?|½|¼|¾)";
const UN = "([a-zA-Zàèéìòù]+)?\\.?";

function numero(s: string): number | null {
  s = s.trim();
  if (s === "½") return 0.5;
  if (s === "¼") return 0.25;
  if (s === "¾") return 0.75;
  if (s.includes("/")) {
    const [a, b] = s.split("/").map((x) => parseFloat(x.replace(",", ".")));
    return b ? Math.round((a / b) * 100) / 100 : null;
  }
  const n = parseFloat(s.replace(",", "."));
  return n > 0 ? n : null;
}

function ingrediente(riga: string): { n: string; q: number | null; u: string } {
  const r = riga.replace(/\(.*?\)/g, " ").replace(/\s+/g, " ").trim();
  let nome = r, q: number | null = null, u = "g";
  let m = new RegExp("^" + NUM + "\\s*" + UN + "\\s+(?:di\\s+|d')?(.+)$", "i").exec(r);
  if (m) {
    q = numero(m[1]);
    const un = (m[2] || "").toLowerCase();
    if (un && UNITA[un]) { u = UNITA[un]; nome = m[3]; }
    else { u = "pezzi"; nome = ((m[2] ? m[2] + " " : "") + m[3]).trim(); }
  } else {
    m = new RegExp("^(.+?)\\s+" + NUM + "\\s*" + UN + "$", "i").exec(r);
    if (m) {
      q = numero(m[2]);
      const un = (m[3] || "").toLowerCase();
      if (un && UNITA[un]) { u = UNITA[un]; nome = m[1]; }
      else if (!un) { u = "pezzi"; nome = m[1]; }
      else { q = null; nome = r; }
    }
  }
  nome = nome.replace(/\bq\.?\s?b\.?$/i, "").replace(/[,;:\s]+$/, "").trim();
  if (!nome) nome = r;
  return { n: nome.charAt(0).toUpperCase() + nome.slice(1, 40), q, u };
}

function passaggi(inst: unknown): string[] {
  if (!inst) return [];
  if (typeof inst === "string") return inst.split(/\n+/).map(pulisci).filter(Boolean);
  if (Array.isArray(inst)) return inst.flatMap(passaggi);
  const o = inst as Record<string, unknown>;
  if (o.itemListElement) return passaggi(o.itemListElement);
  if (o.text) return [pulisci(o.text)].filter(Boolean);
  if (o.name) return [pulisci(o.name)].filter(Boolean);
  return [];
}

function cercaRicetta(nodo: unknown): Record<string, unknown> | null {
  if (!nodo || typeof nodo !== "object") return null;
  if (Array.isArray(nodo)) {
    for (const n of nodo) { const r = cercaRicetta(n); if (r) return r; }
    return null;
  }
  const o = nodo as Record<string, unknown>;
  const tipo = o["@type"];
  if (tipo === "Recipe" || (Array.isArray(tipo) && tipo.includes("Recipe"))) return o;
  return o["@graph"] ? cercaRicetta(o["@graph"]) : null;
}

async function scarica(start: URL): Promise<string | null> {
  let u = start;
  for (let i = 0; i < 4; i++) {
    if (urlNonAmmesso(u)) return null;
    const r = await fetch(u.toString(), {
      redirect: "manual",
      headers: { "User-Agent": "Mozilla/5.0 (compatible; FrogsApp/1.0; +https://frogsapp.com)", "Accept": "text/html" },
      signal: AbortSignal.timeout(8000),
    });
    if (r.status >= 300 && r.status < 400 && r.headers.get("location")) {
      u = new URL(r.headers.get("location")!, u);
      continue;
    }
    if (!r.ok) return null;
    return (await r.text()).slice(0, 2_000_000);
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  let pagina: URL;
  try {
    const { url } = await req.json();
    pagina = new URL(String(url).trim());
  } catch {
    return json({ ok: false, motivo: "link_non_valido" });
  }
  if (urlNonAmmesso(pagina)) return json({ ok: false, motivo: "link_non_valido" });

  let html: string | null = null;
  try { html = await scarica(pagina); } catch { html = null; }
  if (!html) return json({ ok: false, motivo: "pagina_non_raggiungibile" });

  const blocchi = [...html.matchAll(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)];
  let ricetta: Record<string, unknown> | null = null;
  for (const b of blocchi) {
    try { ricetta = cercaRicetta(JSON.parse(b[1].trim())); if (ricetta) break; } catch { /* blocco rovinato */ }
  }
  if (!ricetta) return json({ ok: false, motivo: "nessun_dato_strutturato" });

  const righe = ((ricetta.recipeIngredient as unknown[]) ?? []).map(pulisci).filter(Boolean).slice(0, 60);
  const steps = passaggi(ricetta.recipeInstructions).slice(0, 40);
  if (!righe.length || !steps.length) return json({ ok: false, motivo: "nessun_dato_strutturato" });

  return json({
    ok: true,
    ricetta: {
      nome: pulisci(ricetta.name).slice(0, 60),
      ingredienti: righe.map(ingrediente),
      passaggi: steps,
      minuti: minuti(ricetta.totalTime) ?? minuti(ricetta.cookTime) ?? minuti(ricetta.prepTime),
      porzioni: porzioni(ricetta.recipeYield),
      fonte_url: pagina.toString().slice(0, 2000),
      fonte_sito: pagina.hostname.replace(/^www\./, "").slice(0, 120),
    },
  });
});
