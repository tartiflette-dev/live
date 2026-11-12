module ChaptersHelper
  # Ce que le dernier passage du LLM local a donné, en une phrase pour
  # l'animation (WebinarChaptersController).
  def chapter_llm_status(chapter_set)
    at = chapter_set.generated_at && l(chapter_set.generated_at, format: :long)
    case chapter_set.llm_outcome
    when "ok" then "Proposition du LLM local (#{chapter_set.llm_model}) du #{at}."
    when "partial"
      "Proposition du LLM local (#{chapter_set.llm_model}) du #{at} : une partie de la transcription n'a pas pu " \
        "être lue, vérifie les longs passages sans chapitre."
    when "invalid" then "Le LLM local n'a rien produit d'exploitable (#{at}) : saisis les chapitres à la main ou redemande une proposition."
    when "unreachable" then "LLM local injoignable au dernier essai : redemande une proposition plus tard, ou saisis les chapitres à la main."
    when "llm_disabled", "llm_unconfigured" then "LLM local coupé sur ce serveur : saisis les chapitres à la main."
    when "no_transcript" then "Pas de transcription pour ce café : saisis les chapitres à la main."
    else "Pas encore de proposition du LLM local : elle arrive quelques minutes après la fin du direct ou à la publication du replay."
    end
  end
end
