// Filtre d'AFFICHAGE de la transcription en direct (« les transcriptions ne sont pas nettoyées »).
//
// Whisper produit en français deux sortes de bruit :
//   - des phrases « fantômes » apprises sur des génériques de sous-titrage,
//     émises sur du silence ou de la musique (« Sous-titrage Société
//     Radio-Canada », « Merci d'avoir regardé cette vidéo »…) ;
//   - des segments faits uniquement d'hésitations (« Euh… », « Hum. »).
//
// Le transcripteur applique le MÊME filtre à la source (transcriber/noise.py :
// un segment de bruit n'est ni diffusé ni archivé). Les listes vivent dans
// UN seul fichier, `transcriber/transcript_noise.json`, lu par les deux : ce
// module reste utile pour les segments archivés avant le filtre à la source.
//
// Comparaison sur le texte NORMALISÉ : minuscules, accents retirés,
// ponctuation (apostrophes, tirets, points de suspension…) ramenée à des
// espaces. Les listes du fichier sont donc écrites sous cette forme.
import noise from "../../../transcriber/transcript_noise.json";

// Début de segment reconnu comme phrase fantôme (« Sous-titrage Société
// Radio-Canada », « Merci d'avoir regardé cette vidéo »…).
export const WHISPER_PHANTOM_PREFIXES = noise.phantom_prefixes;

// Mots d'hésitation. Un segment fait UNIQUEMENT de ces mots est masqué ;
// les lettres répétées sont réduites avant comparaison (« euhhh », « hmmm »).
export const HESITATION_WORDS = noise.hesitation_words;

// En tête d'un segment plus long, seules les vraies hésitations sont
// retirées (« Euh, donc… » → « Donc… ») ; « Ben oui » reste tel quel.
const LEADING_FILLER = new RegExp(noise.leading_filler_pattern, "i");

export function normalize(text) {
  return text
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function isPhantom(normalized) {
  return WHISPER_PHANTOM_PREFIXES.some(
    (prefix) => normalized === prefix || normalized.startsWith(`${prefix} `),
  );
}

function isHesitationOnly(normalized) {
  return normalized.split(" ").every((word) => HESITATION_WORDS.includes(word.replace(/(.)\1+/g, "$1")));
}

// Texte à afficher pour un segment, ou null s'il ne doit pas l'être.
// L'hésitation de tête est retirée AVANT les contrôles, pour qu'un
// « Euh, sous-titrage… » soit reconnu comme fantôme.
export function displayableTranscript(text) {
  const raw = text || "";
  const rest = raw.replace(LEADING_FILLER, "");
  const normalized = normalize(rest);
  if (normalized === "" || isPhantom(normalized) || isHesitationOnly(normalized)) return null;
  if (rest === raw) return raw;
  return rest.charAt(0).toUpperCase() + rest.slice(1);
}
