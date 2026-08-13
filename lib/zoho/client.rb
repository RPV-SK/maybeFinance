require "net/http"
require "uri"
require "json"

module Zoho
  # Minimal Zoho CRM v8 REST client.
  #
  # Stdlib only (Net::HTTP + JSON) — this is an occasional back-office chore, not
  # a product surface, so it does not earn a new gem dependency.
  #
  # Credentials come from the environment:
  #
  #   ZOHO_CLIENT_ID
  #   ZOHO_CLIENT_SECRET
  #   ZOHO_REFRESH_TOKEN
  #   ZOHO_ACCOUNTS_DOMAIN  (default https://accounts.zoho.eu)
  #   ZOHO_API_DOMAIN       (default https://www.zohoapis.eu)
  #
  # The defaults point at the EU datacenter. Set both domains explicitly if the
  # org lives in another one (.com, .in, .com.au, ...).
  class Client
    class Error < StandardError; end
    class AuthError < Error; end

    DEFAULT_ACCOUNTS_DOMAIN = "https://accounts.zoho.eu"
    DEFAULT_API_DOMAIN = "https://www.zohoapis.eu"

    # nil is Zoho's default (approved only). Web-form leads awaiting approval sit
    # in `webform_unapproved` and are invisible to an ordinary search.
    APPROVAL_STATES = [ nil, "webform_unapproved", "approval_process_pending" ].freeze

    def initialize(client_id: ENV["ZOHO_CLIENT_ID"],
                   client_secret: ENV["ZOHO_CLIENT_SECRET"],
                   refresh_token: ENV["ZOHO_REFRESH_TOKEN"],
                   accounts_domain: ENV["ZOHO_ACCOUNTS_DOMAIN"].presence || DEFAULT_ACCOUNTS_DOMAIN,
                   api_domain: ENV["ZOHO_API_DOMAIN"].presence || DEFAULT_API_DOMAIN)
      @client_id = client_id
      @client_secret = client_secret
      @refresh_token = refresh_token
      @accounts_domain = accounts_domain.chomp("/")
      @api_domain = api_domain.chomp("/")
    end

    def find_record(module_name, id, fields: nil)
      params = fields ? { fields: Array(fields).join(",") } : {}
      response = get("/crm/v8/#{module_name}/#{id}", params)
      Array(response["data"]).first
    end

    # Two Zoho search defaults will hide records from you if you let them:
    #
    #   converted       — defaults to false, so converted leads vanish
    #   approval_state  — defaults to approved, so a lead sitting in
    #                     `webform_unapproved` vanish too
    #
    # Both are opt-in and only take one value at a time, so `search_all_records`
    # below unions across states rather than trusting a single call.
    def search_records(module_name, criteria:, fields: nil, converted: nil, approval_state: nil)
      params = { criteria: criteria }
      params[:fields] = Array(fields).join(",") if fields
      params[:converted] = converted unless converted.nil?
      params[:approval_state] = approval_state unless approval_state.nil?

      response = get("/crm/v8/#{module_name}/search", params)
      Array(response["data"])
    end

    # Every record matching the criteria regardless of conversion or approval
    # state, de-duplicated by id.
    def search_all_records(module_name, criteria:, fields: nil, approval_states: APPROVAL_STATES)
      approval_states.flat_map { |state|
        search_records(module_name, criteria: criteria, fields: fields, converted: "both", approval_state: state)
      }.uniq { |record| record["id"] }
    end

    # COQL, for the `like` searches the search endpoint cannot express.
    # Note: beyond two conditions, COQL requires explicit parenthesised nesting.
    def query(coql)
      response = post("/crm/v8/coql", { select_query: coql })
      Array(response["data"])
    end

    def create_record(module_name, attributes)
      response = post("/crm/v8/#{module_name}", { data: [ attributes ] })
      first_record_detail(response)
    end

    def update_record(module_name, id, attributes)
      response = put("/crm/v8/#{module_name}/#{id}", { data: [ attributes.merge("id" => id) ] })
      first_record_detail(response)
    end

    private
      attr_reader :client_id, :client_secret, :refresh_token, :accounts_domain, :api_domain

      def first_record_detail(response)
        record = Array(response["data"]).first
        raise Error, "Zoho returned no record detail: #{response.inspect}" if record.nil?
        raise Error, "Zoho rejected the write: #{record["message"]} (#{record["code"]})" unless record["status"] == "success"

        record["details"]
      end

      def get(path, params = {})
        uri = URI.join(api_domain, path)
        uri.query = URI.encode_www_form(params) if params.any?
        request(Net::HTTP::Get.new(uri), uri)
      end

      def post(path, body)
        uri = URI.join(api_domain, path)
        request(json_request(Net::HTTP::Post.new(uri), body), uri)
      end

      def put(path, body)
        uri = URI.join(api_domain, path)
        request(json_request(Net::HTTP::Put.new(uri), body), uri)
      end

      def json_request(req, body)
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
        req
      end

      def request(req, uri)
        req["Authorization"] = "Zoho-oauthtoken #{access_token}"

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(req)
        end

        # 204 is Zoho's "no matching records", which is a normal empty result.
        return { "data" => [] } if response.code == "204"

        # Parse only after the status check — error bodies are not always JSON.
        raise Error, "Zoho #{req.method} #{uri.path} failed (#{response.code}): #{response.body}" unless response.is_a?(Net::HTTPSuccess)

        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      end

      def access_token
        @access_token ||= begin
          missing = { ZOHO_CLIENT_ID: client_id, ZOHO_CLIENT_SECRET: client_secret, ZOHO_REFRESH_TOKEN: refresh_token }
            .select { |_, value| value.blank? }.keys
          raise AuthError, "Missing Zoho credentials: #{missing.join(", ")}" if missing.any?

          uri = URI.join(accounts_domain, "/oauth/v2/token")
          uri.query = URI.encode_www_form(
            refresh_token: refresh_token,
            client_id: client_id,
            client_secret: client_secret,
            grant_type: "refresh_token"
          )

          response = Net::HTTP.post(uri, "")
          body = JSON.parse(response.body.to_s.presence || "{}")
          token = body["access_token"]
          raise AuthError, "Could not refresh Zoho access token: #{response.body}" if token.blank?

          token
        end
      end
  end
end
