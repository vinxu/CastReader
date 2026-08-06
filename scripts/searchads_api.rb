#!/usr/bin/env ruby
# frozen_string_literal: true

# Apple Search Ads API 客户端（对齐 app_store_connect_api.rb 的用法）。
#
#   ruby scripts/searchads_api.rb GET  /api/v5/acls
#   ruby scripts/searchads_api.rb GET  /api/v5/campaigns
#   ruby scripts/searchads_api.rb POST /api/v5/campaigns body.json
#
# 凭据在 ~/.searchads/config.json：{"clientId":"SEARCHADS.…","teamId":"SEARCHADS.…","keyId":"…","orgId":123}
# 私钥在 ~/.searchads/private-key.pem（本机生成，公钥已上传 ASA 后台）。
# orgId 未填时自动从 /acls 取第一个组织并回写 config。access token 缓存 50 分钟。

require "base64"
require "json"
require "net/http"
require "openssl"
require "thread"
require "timeout"
require "uri"

CONFIG_DIR = File.expand_path("~/.searchads")
CONFIG_PATH = File.join(CONFIG_DIR, "config.json")
KEY_PATH = File.join(CONFIG_DIR, "private-key.pem")
TOKEN_CACHE = File.join(CONFIG_DIR, "token-cache.json")
API_BASE = "https://api.searchads.apple.com"
SEARCHADS_TOKEN_MUTEX = Mutex.new
SEARCHADS_OPEN_TIMEOUT = ENV.fetch("SEARCHADS_OPEN_TIMEOUT", "10").to_f
SEARCHADS_READ_TIMEOUT = ENV.fetch("SEARCHADS_READ_TIMEOUT", "30").to_f
SEARCHADS_WRITE_TIMEOUT = ENV.fetch("SEARCHADS_WRITE_TIMEOUT", "15").to_f

def secure_write(path, contents)
  File.chmod(0o600, path) if File.exist?(path)
  File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    file.write(contents)
  end
  File.chmod(0o600, path)
end

def config
  @config ||= JSON.parse(File.read(CONFIG_PATH))
rescue Errno::ENOENT
  abort "缺少 #{CONFIG_PATH}（需要 clientId/teamId/keyId）"
end

def b64(v)
  Base64.urlsafe_encode64(v, padding: false)
end

# client_secret：ES256 JWT，iss=teamId、sub=clientId、aud=appleid.apple.com
def client_secret
  now = Time.now.to_i
  header = b64(JSON.generate(alg: "ES256", kid: config.fetch("keyId")))
  payload = b64(JSON.generate(
    sub: config.fetch("clientId"),
    aud: "https://appleid.apple.com",
    iat: now,
    exp: now + 3600,
    iss: config.fetch("teamId")
  ))
  input = "#{header}.#{payload}"
  key = OpenSSL::PKey.read(File.read(KEY_PATH))
  seq = OpenSSL::ASN1.decode(key.sign("SHA256", input))
  sig = seq.value.map { |i| h = i.value.to_s(16); h = "0#{h}" if h.length.odd?; [h].pack("H*").rjust(32, "\0") }.join
  "#{input}.#{b64(sig)}"
end

def fetch_access_token
  uri = URI("https://appleid.apple.com/auth/oauth2/token")
  req = Net::HTTP::Post.new(uri)
  req.set_form_data({
    "grant_type" => "client_credentials",
    "client_id" => config.fetch("clientId"),
    "client_secret" => client_secret,
    "scope" => "searchadsorg"
  })
  res = bounded_http_request(uri, req)
  body = JSON.parse(res.body)
  raise "换取 access token 失败：#{res.code} #{body}" unless res.is_a?(Net::HTTPSuccess)
  expires_at = Time.now.to_i + 3000
  secure_write(
    TOKEN_CACHE,
    JSON.generate(token: body.fetch("access_token"), expiresAt: expires_at)
  )
  @searchads_access_token = body.fetch("access_token")
  @searchads_access_token_expires_at = expires_at
  @searchads_access_token
end

def access_token
  now = Time.now.to_i
  if @searchads_access_token && @searchads_access_token_expires_at.to_i > now
    return @searchads_access_token
  end

  SEARCHADS_TOKEN_MUTEX.synchronize do
    now = Time.now.to_i
    if @searchads_access_token && @searchads_access_token_expires_at.to_i > now
      return @searchads_access_token
    end

    cache = JSON.parse(File.read(TOKEN_CACHE)) rescue nil
    if cache && cache["expiresAt"].to_i > now
      @searchads_access_token = cache.fetch("token")
      @searchads_access_token_expires_at = cache.fetch("expiresAt").to_i
      return @searchads_access_token
    end

    fetch_access_token
  end
end

def bounded_http_request(uri, req)
  http = Net::HTTP.new(uri.hostname, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = SEARCHADS_OPEN_TIMEOUT
  http.read_timeout = SEARCHADS_READ_TIMEOUT
  http.write_timeout = SEARCHADS_WRITE_TIMEOUT if http.respond_to?(:write_timeout=)
  http.start { |client| client.request(req) }
end

def request(method, path, body_path = nil, with_org: true)
  uri = URI.join(API_BASE, path)
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{access_token}"
  req["Content-Type"] = "application/json"
  req["X-AP-Context"] = "orgId=#{org_id}" if with_org
  req.body = File.read(body_path) if body_path
  bounded_http_request(uri, req)
end

def org_id
  return config["orgId"] if config["orgId"]
  res = request("GET", "/api/v5/acls", with_org: false)
  body = JSON.parse(res.body)
  orgs = body.fetch("data", [])
  abort "取不到组织：#{res.code} #{body}" if orgs.empty?
  @config["orgId"] = orgs.first.fetch("orgId")
  secure_write(CONFIG_PATH, JSON.pretty_generate(@config))
  warn "orgId=#{@config['orgId']}（#{orgs.first['orgName']}）已写入 config"
  @config["orgId"]
end

if $PROGRAM_NAME == __FILE__
  method = ARGV.fetch(0, "GET").upcase
  path = ARGV.fetch(1)
  body_path = ARGV[2]

  response = request(method, path, body_path)
  puts JSON.pretty_generate(JSON.parse(response.body)) unless response.body.to_s.empty?
  exit(response.is_a?(Net::HTTPSuccess) ? 0 : 1)
end
