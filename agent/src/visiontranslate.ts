/**
 * Vision translator: lets a chat on a model that cannot read pictures still take one. A vision model reads the picture
 * into text (a description, every readable text copied as is, the layout), and that text goes to the chat's model in
 * the user's turn, labelled, with a note that the model does not see the picture itself.
 *
 * The picture itself stays in the chat (pi keeps it in the session file, and pi replaces it with a placeholder before
 * any request to a model whose metadata does not list image input: pi-ai transform-messages.js), so it is never sent to
 * the non-vision model, and is there again for a follow-up question or for a later switch to a vision model.
 *
 * The translator is picked with the same filter as the smart router (modelcaps.ts candidates): vision stated by
 * /v1/models, a live price, not blocked, available. Among the models on the approved list (the quality floor; Settings,
 * or by default the vision models out of the cheapest price third), the cheapest wins; a model the user chose
 * themselves always wins over that.
 */

import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { candidates, type ModelMeta, requestCost } from "./modelcaps.js";
import { bandOf, priceBands } from "./smartrouter.js";
import { atomicWrite } from "./state.js";

export type VisionMode = "auto" | "ask" | "off";

/** Whether the chat's model reads pictures itself, by the metadata (vision stated true). Unknown counts as no. */
export function readsImages(m: Pick<ModelMeta, "vision"> | undefined): boolean {
	return m?.vision === true;
}

/**
 * The approved translators by default: vision models with a live price outside the cheapest third of all prices, so
 * a translation is not left to the weakest models. When no vision model is above that third, all vision models count.
 */
export function defaultAllowed(models: ModelMeta[]): string[] {
	const vision = models.filter((m) => m.vision === true && m.credits !== undefined);
	const bands = priceBands(models);
	const above = bands ? vision.filter((m) => bandOf(m, bands) >= 1) : [];
	return (above.length ? above : vision).map((m) => m.id);
}

export type TranslatorPick = { ok: true; model: ModelMeta; manual: boolean } | { ok: false; reason: string };

/**
 * The translator for a picture: the user's own choice when it still qualifies, else the cheapest approved vision model
 * that is a candidate. Never a model outside the router's metadata.
 */
export function pickTranslator(
	models: ModelMeta[],
	opts: { manual?: string; allowed?: string[]; blocked?: ReadonlySet<string>; images: number },
): TranslatorPick {
	const need = { vision: true, tools: false, minContext: 4_000 + opts.images * 2_000 };
	const fit = candidates(models, need, opts.blocked ?? new Set());
	if (opts.manual) {
		const own = fit.find((m) => m.id === opts.manual);
		if (own) return { ok: true, model: own, manual: true };
	}
	const allowed = new Set(opts.allowed?.length ? opts.allowed : defaultAllowed(models));
	const pool = fit.filter((m) => allowed.has(m.id));
	if (!pool.length) return { ok: false, reason: "No approved vision model is available" };
	const best = [...pool].sort((a, b) => (estimateRead(a, opts.images) ?? Infinity) - (estimateRead(b, opts.images) ?? Infinity) || a.id.localeCompare(b.id))[0];
	return { ok: true, model: best, manual: false };
}

/** Rough tokens of one reading: the instruction, about 1 500 per picture in, about 1 200 out. */
export function estimateRead(m: ModelMeta, images: number): number | null {
	return requestCost(m, 400 + images * 1_500, 1_200);
}

// ---------------------------------------------------------------------------
// What the translator is asked, and what the chat's model is given

/** The fixed instruction for a full reading (Fitur 6 butir 3). */
export const FULL_INSTRUCTION = [
	"Baca gambar terlampir untuk model lain yang tidak bisa melihatnya. Tulis teks biasa, tanpa basa-basi:",
	"1. Deskripsi isi gambar sedetail yang berguna.",
	"2. Salinan SEMUA teks yang terbaca, persis apa adanya (angka, ejaan, tanda baca), di bawah judul \"Teks terbaca:\".",
	"3. Struktur atau tata letak bila relevan (tabel sebagai baris dan kolom, UI, diagram).",
	"Jangan menebak bagian yang tidak terbaca: tulis [tidak terbaca].",
].join("\n");

/** The instruction for a follow-up about a picture read earlier: only what the question needs, copied exactly. */
export function targetedInstruction(question: string): string {
	return [
		"Model lain tidak bisa melihat gambar terlampir dan pengguna bertanya tentang detailnya:",
		`"${question.trim().slice(0, 1_000)}"`,
		"Jawab hanya dari gambar: salin persis teks atau angka yang relevan dan jelaskan letaknya. Jangan menebak; tulis [tidak terbaca] bila tidak terbaca.",
	].join("\n");
}

export interface Reading {
	model: string;
	name: string;
	credits: number | null;
	kind: "full" | "targeted";
	text: string;
}

const attr = (v: string) => v.replace(/[&"<>]/g, (c) => ({ "&": "&amp;", '"': "&quot;", "<": "&lt;", ">": "&gt;" })[c]!);

/**
 * The block added to the user's turn. The app hides it from the bubble and shows "Gambar dibaca oleh <name>" under the
 * answer (lib/agent/models.dart visionReadsOf); the chat's model reads it.
 */
export function readingBlock(r: Reading): string {
	const label = r.kind === "full" ? `Isi gambar menurut model vision ${r.name}` : `Detail gambar menurut model vision ${r.name}`;
	return [
		`<griphub-vision model="${attr(r.model)}" name="${attr(r.name)}" kind="${r.kind}" credits="${r.credits === null ? "" : r.credits.toFixed(6)}">`,
		`[${label}:`,
		r.text.replace(/<\/griphub-vision>/gi, "</ griphub-vision>").trim(),
		"]",
		"[Catatan: model utama tidak melihat gambar asli. Jawab berdasarkan uraian di atas dan katakan terus terang bila detail yang ditanya tidak tercakup.]",
		"</griphub-vision>",
	].join("\n");
}

/** A message's text without the readings added to it: what the user wrote, for titles and summaries. */
export function stripReadings(text: string): string {
	return text.replace(/\n*<griphub-vision\b[^>]*>[\s\S]*?<\/griphub-vision>/g, "").trimEnd();
}

/** A question that is about a picture sent earlier in the chat (Fitur 6 butir 5). */
const ABOUT_PICTURE =
	/\b(gambar(nya)?|foto(nya)?|struk(nya)?|nota(nya)?|kuitansi|screenshot|tangkapan layar|lampiran|image|picture|photo|receipt|screenshot|tabel(nya)? (itu|tadi|di)|tulisan(nya)?|teks (di|pada)|angka (di|pada|yang)|pojok|sudut)\b/i;

export function asksAboutPicture(text: string): boolean {
	return ABOUT_PICTURE.test(text);
}

// ---------------------------------------------------------------------------
// Per-chat consent ("Tanya dulu"), on disk beside the routing state

export class VisionConsent {
	constructor(private readonly dir: string) {}

	private file(sessionId: string) {
		return join(this.dir, `${sessionId.replace(/[^\w.-]/g, "_")}.json`);
	}

	given(sessionId: string): boolean {
		try {
			const f = this.file(sessionId);
			return existsSync(f) && JSON.parse(readFileSync(f, "utf8"))?.consent === true;
		} catch {
			return false;
		}
	}

	give(sessionId: string) {
		mkdirSync(this.dir, { recursive: true });
		atomicWrite(this.file(sessionId), JSON.stringify({ consent: true, at: Date.now() }));
	}
}
