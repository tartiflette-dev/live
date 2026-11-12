# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Crm
  # Adaptateur CRM générique : client HTTP d'un CRM de contacts que
  # l'opérateur de l'instance fournit (CRM_BASE_URL, auth Bearer
  # CRM_API_TOKEN). Ce fichier EST l'interface : un CRM branché ici
  # implémente les quatre appels ci-dessous, détaillés avec les corps
  # exacts dans docs/registrations-api.md §Contrat HTTP du CRM.
  #
  # Corps À PLAT, exactement ces clés ; le CRM refuse toute autre clé
  # (422) :
  # - `search_by_email(email)` -> `GET /api/v1/contacts/lookup?email=` seul
  #   (email principal ou secondaire, casse ignorée) : hash `{"id", …}`, ou
  #   `nil` sur 404 `{"error":"not_found"}` (pas de fiche : à créer). Tout
  #   autre 404 = TransientError `unexpected_404`. 422 = permanent.
  # - `create_contact(attrs)` -> first_name, last_name, email.
  # - `add_segment(contact_id, email:, realm:, segment:)` -> corps
  #   `{"email": …, "segment": {realm, segment}}`, professional/participant
  #   seul (201 créé / 200 déjà présent : idempotent).
  # - `create_interaction(attrs)` -> contact_id, email, kind (= "form"),
  #   occurred_at, title, notes, source `<Brand.host>:<x>[:<y>]`,
  #   source_path (`/w/<slug>`, `/mc`, `/mc/withdraw`, `/confirmer`).
  # `email` de segment / interaction = PREUVE : celui de la fiche visée.
  # Réponses minimales : seul `id` est lu. Un 404 `{"error":"not_found"}`
  # sur segment / interaction (fiche introuvable, ou email non concordant
  # après fusion) lève `Crm::ContactNotFoundError` : l'appelant refait un
  # lookup et réessaie une fois (Crm::ParticipantSync#on_contact).
  # Un écart au contrat lève `Crm::ContractError` AVANT tout appel HTTP.
  #
  # Toute 5xx / timeout -> `Crm::TransientError` ; 429 -> `Crm::RateLimitedError`
  # (transitoire, porte le Retry-After).
  # Toute 4xx (hors 429) -> `Crm::PermanentError`.
  # Appelants : les jobs CRM (`CrmSyncJob`, `CrmNotifyNextJob`,
  # `CrmMarketingWithdrawalJob`) via `Crm::ParticipantSync`.
  #
  # Logs & exceptions : la discipline impose
  # - zéro PII (email, nom, corps de réponse) dans logs ou messages ;
  # - zéro jeton (Authorization n'est jamais logué, même en debug) ;
  # - log d'un libellé fixe + méthode + chemin (sans query) + code HTTP +
  #   durée en ms, rien de plus.
  class HttpContactsClient
    OPEN_TIMEOUT     = 3
    READ_TIMEOUT     = 5

    # Aucun hôte par défaut : CRM_BASE_URL vient de la configuration de l'instance.
    def initialize(base_url: ENV["CRM_BASE_URL"], token: ENV["CRM_API_TOKEN"], logger: nil)
      @base_url = base_url.to_s.chomp("/")
      @token    = token.to_s
      @logger   = logger || Rails.logger
      raise UnconfiguredError, "CRM_API_TOKEN" if @token.empty?
      raise UnconfiguredError, "CRM_BASE_URL" if @base_url.empty?
    end

    CONTACT_FIELDS     = %i[first_name last_name email].freeze
    INTERACTION_FIELDS = %i[contact_id email kind occurred_at title notes source source_path].freeze
    INTERACTION_KIND   = "form"
    # Grammaire du contrat, ancrée (le CRM applique la même).
    # La source commence par l'hôte public de l'instance (Brand.host).
    SLUG                = "[a-z0-9][a-z0-9_-]*"
    SOURCE_PATTERN      = /\A#{Regexp.escape(Brand.host)}(?::#{SLUG}){1,2}\z/
    SOURCE_PATH_PATTERN = %r{\A/(?:w/#{SLUG}|mc|mc/withdraw|confirmer)\z}
    PARTICIPANT_SEGMENT = { realm: "professional", segment: "participant" }.freeze

    def search_by_email(email)
      request(:get, "/api/v1/contacts/lookup", query: { email: email }, not_found: nil)
    end

    def create_contact(attrs)
      request(:post, "/api/v1/contacts", json: flat_body(attrs, CONTACT_FIELDS))
    end

    def create_interaction(attrs)
      body = flat_body(attrs, INTERACTION_FIELDS)
      check_interaction_policy(body)
      request(:post, "/api/v1/interactions", json: body, not_found: :contact)
    end

    def add_segment(contact_id, email:, realm:, segment:)
      unless { realm: realm, segment: segment } == PARTICIPANT_SEGMENT
        raise ContractError, "segment hors contrat CRM"
      end
      raise ContractError, "preuve par email absente" if email.blank?

      request(:post, "/api/v1/contacts/#{Integer(contact_id)}/segments",
              json: { email: email, segment: { realm: realm, segment: segment } }, not_found: :contact)
    end

    private

    def flat_body(attrs, allowed)
      unknown = attrs.keys.map(&:to_sym) - allowed
      raise ContractError, "champ(s) hors contrat CRM : #{unknown.join(", ")}" if unknown.any?

      attrs
    end

    def check_interaction_policy(body)
      raise ContractError, "preuve par email absente" if body[:email].blank?
      raise ContractError, "kind hors contrat CRM" unless body[:kind] == INTERACTION_KIND
      raise ContractError, "source hors contrat CRM" unless body[:source].to_s.match?(SOURCE_PATTERN)
      raise ContractError, "source_path hors contrat CRM" unless body[:source_path].to_s.match?(SOURCE_PATH_PATTERN)
    end

    # Logué : méthode, chemin (SANS query — « search=<email> » en ferait
    # fuiter l'email) et, après exécution, code HTTP + durée.
    # `not_found:` — `:raise` (défaut) : PermanentError http_404 ;
    # `:contact` : ContactNotFoundError (segment, interaction) ; toute autre
    # valeur est rendue telle quelle (lookup : nil = pas de fiche).
    def request(method, path, query: nil, json: nil, not_found: :raise)
      uri = URI.join(@base_url + "/", path.sub(%r{\A/}, ""))
      uri.query = URI.encode_www_form(query) if query

      req = build_request(method, uri, json)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        response = perform(uri, req)
        if response.code.to_i == 404 && not_found != :raise
          # Seul le 404 du contrat (`{"error":"not_found"}`) dit « pas
          # de fiche ». Un autre 404 (CRM sans cette recherche, route absente, page
          # d'erreur HTML) est une panne de contrat : transitoire, jamais
          # « absent » — sinon chaque job créerait une fiche en double.
          raise_transient(404, "unexpected_404") unless contract_not_found?(response)
          raise_contact_not_found if not_found == :contact
          log("crm_http not_found", method: method, path: path, http_status: 404, started: started)
          return not_found
        end
        parse_response(response, method: method, path: path, started: started)
      rescue TransientError, PermanentError => e
        log("crm_http error", method: method, path: path, http_status: e.http_status,
                               started: started, outcome: e.class.name.split("::").last)
        raise
      end
    end

    def build_request(method, uri, json)
      req = case method
      when :get  then Net::HTTP::Get.new(uri)
      when :post then Net::HTTP::Post.new(uri)
      else raise ArgumentError, "verb non supporté: #{method}"
      end

      req["Authorization"] = "Bearer #{@token}"
      req["Accept"]        = "application/json"
      if json
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(json)
      end
      req
    end

    def perform(uri, req)
      Net::HTTP.start(
        uri.hostname, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) { |http| http.request(req) }
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
           Errno::EHOSTUNREACH, SocketError
      # Classe réseau : jamais une erreur permanente, et JAMAIS l'exception
      # d'origine dans le message (certains backends y fourrent une URL).
      raise_transient(0, "network")
    end

    def parse_response(response, method:, path:, started:)
      code = response.code.to_i
      case code
      when 200..299
        log("crm_http ok", method: method, path: path, http_status: code, started: started)
        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      when 429
        raise RateLimitedError.new("crm:rate_limited", retry_after: retry_after_seconds(response))
      when 500..599
        raise_transient(code, "http_#{code}")
      else
        raise_permanent(code, "http_#{code}")
      end
    rescue JSON::ParserError
      raise_transient(code, "invalid_json")
    end

    # Retry-After en secondes (forme émise par le CRM), ou date HTTP ; à
    # défaut, une fenêtre d'une minute. Borné à [1 s, 24 h].
    def retry_after_seconds(response)
      raw = response["Retry-After"].to_s.strip
      seconds = if raw.match?(/\A\d+\z/) then raw.to_i
      elsif raw.present? then (Time.httpdate(raw) - Time.current).ceil
      end
      (seconds || RateLimitedError::MINUTE_WINDOW).clamp(1, 1.day.to_i)
    rescue ArgumentError
      RateLimitedError::MINUTE_WINDOW
    end

    def raise_transient(code, tag)
      err = TransientError.new("crm:#{tag}")
      err.http_status = code
      raise err
    end

    def contract_not_found?(response)
      JSON.parse(response.body.to_s) == { "error" => "not_found" }
    rescue JSON::ParserError
      false
    end

    def raise_contact_not_found
      err = ContactNotFoundError.new("crm:contact_not_found")
      err.http_status = 404
      raise err
    end

    def raise_permanent(code, tag)
      err = PermanentError.new("crm:#{tag}")
      err.http_status = code
      raise err
    end

    def log(label, method:, path:, http_status:, started:, outcome: "ok")
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      @logger.info(
        "[Crm::HttpContactsClient] #{label} method=#{method} path=#{sanitized_path(path)} " \
          "http_status=#{http_status} outcome=#{outcome} duration_ms=#{elapsed_ms}"
      )
    end

    # Garantit qu'aucune query sensible n'arrive au logger, même si un
    # appelant poste accidentellement `/api/v1/contacts?search=…`.
    def sanitized_path(path)
      path.to_s.split("?", 2).first
    end
  end
end
