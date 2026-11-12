# frozen_string_literal: true

require "test_helper"

# Le nom de l'organisation qui opère l'instance vient de BRAND_ORGANIZATION,
# sa série de BRAND_SERIES_*. Pour l'instance d'origine (undust, nom à voyelle
# initiale : « qu'undust », série tartiflette.dev), les libellés figés comme preuve d'un consentement et les mails qui le
# demandent restent ceux d'avant, à l'octet. Référence :
# test/fixtures/files/organisation_undust/, rendue par le code qui écrivait le
# nom en dur. Changer un libellé de preuve demande une nouvelle version de la
# politique (PrivacyPolicy::VERSION), pas une mise à jour de la référence.
class OrganizationRenderingTest < ActiveSupport::TestCase
  REFERENCE = Rails.root.join("test/fixtures/files/organisation_undust")
  ORIGIN_SERIES = { "BRAND_SERIES_URL" => "https://tartiflette.dev", "BRAND_SERIES_CO_ORGANIZERS" => "tartiflette.dev" }.freeze
  MAILS = {
    RegistrationMailerPreview => %w[confirmation_cafe_ia confirmation_par_defaut marketing_consent_confirmed_cafe_ia
                                    marketing_consent_confirmed_par_defaut]
  }.freeze

  # Les aperçus datent leurs webinaires depuis maintenant.
  setup { travel_to Time.utc(2026, 11, 20, 9) }

  test "libellés de consentement figés comme preuve : identiques pour undust" do
    with_organization("undust", ORIGIN_SERIES) do
      assert_equal REFERENCE.join("consentements.txt").read, consent_labels
    end
  end

  MAILS.each do |preview, emails|
    emails.each do |email|
      test "mail #{email} : identique pour undust" do
        with_organization("undust", ORIGIN_SERIES) do
          assert_equal REFERENCE.join("#{email}.txt").read, rendered(preview, email)
        end
      end
    end
  end

  test "un nom à consonne initiale ne s'élide pas" do
    with_organization("Studio Exemple") do
      assert_includes ParticipantConsent.labels_for(Brand.organization)[:excerpts], "publiés par Studio Exemple sur"
      assert_includes rendered(RegistrationMailerPreview, "confirmation_cafe_ia"), "J'accepte que Studio Exemple me recontacte"
      assert_equal "Je confirme, et Studio Exemple peut me recontacter",
                   Voice.t("registration_requests.show.button_with_marketing", voice: "cafe_ia")
    end
  end

  # Nom piégé : apostrophe, esperluette, balise. Partie texte = texte brut
  # intact ; partie HTML = échappée, sans double échappement.
  TRAPPED = "L'Atelier & Co <script>"
  TRAPPED_HTML = "L&#39;Atelier &amp; Co &lt;script&gt;"
  TRAPPED_MAILS = {
    "confirmation_cafe_ia" => "J'accepte que %s me recontacte",
    "confirmation_par_defaut" => "J'accepte que %s me recontacte",
    "request_confirmation_cafe_ia" => "Ok pour que %s me recontacte",
    "request_confirmation_par_defaut" => "Ok pour que %s me recontacte",
    "marketing_consent_confirmed_par_defaut" => "recontacté·e par %s",
    "marketing_consent_confirmed_cafe_ia" => "C'est noté : %s peut"
  }.freeze

  TRAPPED_MAILS.each do |email, phrase|
    test "mail #{email} : nom piégé brut dans le texte, échappé dans le HTML" do
      with_organization(TRAPPED) do
        mail = trapped_mail(email)
        text = mail.text_part.decoded
        html = mail.html_part.decoded

        assert_includes text, format(phrase, TRAPPED)
        assert_no_match(/&amp;|&#39;|&lt;/, text)
        assert_includes html, format(phrase, TRAPPED_HTML)
        assert_not_includes html, "<script>"
        assert_not_includes html, "&amp;amp;"
      end
    end
  end

  test "constante figée dans les preuves = libellés de l'organisation de l'instance" do
    assert_equal ParticipantConsent.labels_for(Brand.organization, co_organizers: Brand.series.co_organizers),
                 ParticipantConsent::LABELS
  end

  test "sans co-organisateurs de série, l'organisation publie seule les extraits" do
    assert_equal "J'accepte que des extraits soient publiés par Studio Exemple sur ses sites et réseaux sociaux",
                 ParticipantConsent.labels_for("Studio Exemple")[:excerpts]
    assert_equal "J'accepte que des extraits soient publiés par Studio Exemple et les co-organisateurs de la série " \
                 "(Collectif Exemple) sur leurs sites et réseaux sociaux",
                 ParticipantConsent.labels_for("Studio Exemple", co_organizers: "Collectif Exemple")[:excerpts]
  end

  private

  # Demande groupée à case cochée : le mail annonce alors le choix de recontact.
  def trapped_mail(email)
    return RegistrationMailerPreview.call(email) unless email.start_with?("request_confirmation_")

    kind = email.end_with?("cafe_ia") ? "cafe_ia" : "bootcamp"
    request = RegistrationMailerPreview.new.send(:preview_request, kind, "Café")
    request.define_singleton_method(:marketing_choice_offered?) { true }
    RegistrationMailer.request_confirmation(request)
  end

  # Ce que figent les preuves : libellés de la salle, boutons d'accord des
  # pages /mc et /confirmer dans chaque tonalité, note CRM de l'accord.
  def consent_labels
    lines = ParticipantConsent.labels_for(Brand.organization, co_organizers: Brand.series.co_organizers).map { |key, label| "participant_consent.#{key}: #{label}" }
    %w[default cafe_ia].each do |voice|
      lines << "#{voice}.marketing_consents.show.accept: #{Voice.t("marketing_consents.show.accept", voice: voice)}"
      lines << "#{voice}.registration_requests.show.button_with_marketing: " \
               "#{Voice.t("registration_requests.show.button_with_marketing", voice: voice)}"
    end
    lines << "crm: #{Crm.marketing_consent_note(at: Time.current, path: "/mc", source: "live", policy_version: "1.8", label: "Oui")}"
    lines.join("\n") + "\n"
  end

  def rendered(preview, email)
    mail = preview.call(email)
    parts = mail.all_parts.reject(&:multipart?).presence || [ mail ]
    ([ "subject: #{mail.subject}" ] + parts.map { |part| "--- #{part.mime_type}\n#{part.decoded}" }).join("\n") + "\n"
  end

  def with_organization(name, env = {}, &block)
    with_brand(env.merge("BRAND_ORGANIZATION" => name), &block)
  end
end
