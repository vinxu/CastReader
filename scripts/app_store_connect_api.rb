#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

KEY_ID = ENV.fetch("ASC_KEY_ID", "6QN4G1IJDEP1")
KEY_PATH = ENV.fetch(
  "ASC_KEY_PATH",
  File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8")
)
BASE_URL = "https://api.appstoreconnect.apple.com"

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def token
  now = Time.now.to_i
  header = base64url(JSON.generate(alg: "ES256", kid: KEY_ID, typ: "JWT"))
  payload = base64url(JSON.generate(sub: "user", iat: now, exp: now + 1_000, aud: "appstoreconnect-v1"))
  signing_input = "#{header}.#{payload}"
  key = OpenSSL::PKey.read(File.read(KEY_PATH))
  der_signature = key.sign("SHA256", signing_input)
  sequence = OpenSSL::ASN1.decode(der_signature)
  signature = sequence.value.map do |integer|
    bytes = integer.value.to_s(16)
    bytes = "0#{bytes}" if bytes.length.odd?
    [bytes].pack("H*").rjust(32, "\0")
  end.join
  "#{signing_input}.#{base64url(signature)}"
end

method = ARGV.fetch(0, "GET").upcase
path = ARGV.fetch(1)
body_path = ARGV[2]
uri = URI.join(BASE_URL, path)
request_class = Net::HTTP.const_get(method.capitalize)
request = request_class.new(uri)
request["Authorization"] = "Bearer #{token}"
request["Content-Type"] = "application/json"
request.body = File.read(body_path) if body_path

response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
  http.request(request)
end

puts JSON.pretty_generate(JSON.parse(response.body)) unless response.body.nil? || response.body.empty?
exit(response.is_a?(Net::HTTPSuccess) ? 0 : 1)
