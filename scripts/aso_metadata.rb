# frozen_string_literal: true
require 'json'
require 'uri'
# These checks detect omissions and regressions, not search demand.
module ASOMetadata
  ROOT = File.expand_path('..', __dir__)
  CATALOG = File.join(ROOT, 'docs/aso/search-localizations.json')
  IOS_DESCRIPTIONS = File.join(ROOT, 'docs/aso/ios-description-localizations.json')
  FIELDS = %w[name subtitle keywords].freeze
  SCRIPTS = {'zh'=>/\p{Han}/,'ja'=>/[\p{Han}\p{Hiragana}\p{Katakana}]/,'ko'=>/\p{Hangul}/,'ar'=>/\p{Arabic}/,'he'=>/\p{Hebrew}/,'hi'=>/\p{Devanagari}/,'el'=>/\p{Greek}/,'ru'=>/\p{Cyrillic}/}.freeze
  GENERIC = %w[kindle pdf epub tts ocr ai web text voice reader scan audiobook].freeze
  def self.catalog
    JSON.parse(File.read(CATALOG))
  end
  def self.descriptions
    JSON.parse(File.read(IOS_DESCRIPTIONS))
  end
  def self.validate_descriptions(data, search_catalog: catalog)
    errors = []
    rows = data.fetch('localizations')
    expected = search_catalog.fetch('localizations')
    errors << 'Description catalog must target IOS' unless data['platform'] == 'IOS'
    errors << 'Description locale coverage differs from search catalog' unless rows.keys.sort == expected.keys.sort
    rows.each do |locale, row|
      value = row['description']
      unless value.is_a?(String) && !value.strip.empty?
        errors << "#{locale}/description: missing or empty"
        next
      end
      errors << "#{locale}/description: exceeds 4000 characters" if value.length > 4000
      errors << "#{locale}/description: English fallback" if locale != 'en-US' && value == rows.dig('en-US', 'description')
      pattern = SCRIPTS[expected.dig(locale, 'language')]
      errors << "#{locale}/description: expected native script" if pattern && !value.match?(pattern)
      errors << "#{locale}/description: missing review note" if row['reviewNote'].to_s.strip.empty?
      errors << "#{locale}/description: rejected platform reference" if value.match?(/google[\s-]*play|play[\s-]*books|play\.google\.com/i)
    end
    rows.group_by { |_, row| row['description'] }.each_value do |group|
      errors << "Identical descriptions: #{group.map(&:first).join(',')}" if group.size > 1
    end
    errors
  end
  def self.compare_descriptions(data, version_localizations:)
    errors = []
    actual = index(version_localizations, 'iOS descriptions', errors)
    expected = data.fetch('localizations')
    errors << 'iOS description locale set differs from reviewed catalog' unless expected.keys.sort == actual.keys.sort
    (expected.keys & actual.keys).each do |locale|
      errors << "#{locale}/description: differs from reviewed catalog" unless actual[locale]['description'] == expected[locale]['description']
    end
    errors
  end
  def self.validate(data, languages: nil, approved: nil)
    errors = []
    rows = data.fetch('localizations')
    if languages
      covered = (rows.values.map { |r| r.fetch('language') } + data.fetch('unsupportedStoreLanguages').keys).uniq.sort
      errors << 'App language coverage differs from ios-language-capabilities.json' unless covered == languages.sort
    end
    %w[zh-Hant es-MX].each { |locale| errors << "Missing regional locale #{locale}" unless rows.key?(locale) }
    if approved
      expected = rows.transform_values { |r| r.fetch('keywords') }
      actual = approved.reject { |k, _| k.start_with?('_') }
      errors << 'approved-keywords.json differs from search-localizations.json' unless expected == actual
    end
    rows.each do |locale, r|
      FIELDS.each do |field|
        value = r[field]
        unless value.is_a?(String) && !value.strip.empty? && !value.include?("\n")
          errors << "#{locale}/#{field}: missing, empty or multiline"
          next
        end
        limit = field == 'keywords' ? 100 : 30
        size = field == 'keywords' ? value.bytesize : value.length
        errors << "#{locale}/#{field}: #{size} exceeds #{limit}" if size > limit
        if r['language'] != 'en' && field != 'keywords' && value == rows.dig('en-US', field)
          errors << "#{locale}/#{field}: English fallback"
        end
        pattern = SCRIPTS[r['language']]
        errors << "#{locale}/#{field}: expected native script" if pattern && !value.match?(pattern)
      end
      next unless r['keywords'].is_a?(String)
      tokens = r['keywords'].split(',', -1)
      errors << "#{locale}/keywords: empty token or comma whitespace" if tokens.any? { |t| t.empty? || t != t.strip }
      normalized = tokens.map(&:downcase)
      errors << "#{locale}/keywords: duplicate token" if normalized.uniq.size != normalized.size
      errors << "#{locale}/keywords: generic English placeholder" if (normalized - GENERIC).empty?
      errors << "#{locale}/keywords: third-party brand" if r['keywords'].match?(/\b(?:kindle|audible|speechify|naturalreader|elevenlabs|google|apple)\b/i)
      errors << "#{locale}: missing search hypotheses" unless r['searchQueries'].is_a?(Array) && r['searchQueries'].size >= 3
    end
    rows.group_by { |_, r| r['keywords'].to_s.downcase }.each_value do |group|
      errors << "Unrelated languages share keywords: #{group.map(&:first).join(',')}" if group.map { |_, r| r['language'] }.uniq.size > 1
    end
    errors
  end
  def self.index(items, label, errors)
    grouped = items.group_by { |i| i.dig('attributes', 'locale') }
    grouped.each { |locale, values| errors << "#{label}: duplicate locale #{locale}" if values.size != 1 }
    grouped.transform_values { |values| values.first.fetch('attributes') }
  end
  def self.compare(data, version_localizations:, app_info_localizations: nil)
    errors = []
    expected = data.fetch('localizations')
    checks = [['version', version_localizations, %w[keywords]]]
    checks << ['App Info', app_info_localizations, %w[name subtitle]] if app_info_localizations
    checks.each do |label, items, fields|
      actual = index(items, label, errors)
      missing, extra = expected.keys - actual.keys, actual.keys - expected.keys
      errors << "#{label}: missing locales #{missing.join(',')}" unless missing.empty?
      errors << "#{label}: uncatalogued locales #{extra.join(',')}" unless extra.empty?
      (expected.keys & actual.keys).sort.each do |locale|
        fields.each do |field|
          errors << "#{locale}/#{field}: differs from reviewed catalog" unless expected[locale][field] == actual[locale][field]
        end
      end
    end
    errors
  end
  def self.get_all(path)
    result, visited = [], []
    while path
      raise 'ASC pagination loop' if visited.include?(path)
      visited << path
      page = yield(path)
      result.concat(page.fetch('data'))
      next_url = page.dig('links', 'next')
      path = next_url && URI(next_url).request_uri
    end
    result
  end
  def self.select_version(versions, platform:, number: nil, id: nil)
    candidates = versions.select { |v| v.dig('attributes', 'platform') == platform }
    return candidates.find { |v| v['id'] == id } if id
    return candidates.find { |v| v.dig('attributes', 'versionString') == number } if number
    candidates.select { |v| %w[READY_FOR_SALE READY_FOR_DISTRIBUTION].include?(v.dig('attributes', 'appStoreState')) }
      .max_by { |v| v.dig('attributes', 'versionString').split('.').map(&:to_i) }
  end
end
