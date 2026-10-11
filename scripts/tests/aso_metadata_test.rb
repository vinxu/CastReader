require 'minitest/autorun'
require_relative '../aso_metadata'
class ASOMetadataTest < Minitest::Test
  def setup
    @data = ASOMetadata.catalog
    @languages = JSON.parse(File.read(File.join(ASOMetadata::ROOT, 'config/ios-language-capabilities.json'))).dig('serviceRegions','global')
    @localizations = @data['localizations'].map { |locale, r| {'attributes'=>r.merge('locale'=>locale)} }
  end
  def test_current_catalog_accounts_for_every_app_language
    assert_empty ASOMetadata.validate(@data, languages: @languages)
    assert_equal 29, @localizations.size
  end
  def test_english_placeholder_is_rejected
    @data['localizations']['ar-SA'].merge!('name'=>@data['localizations']['en-US']['name'],'keywords'=>'Kindle,PDF,EPUB,TTS,OCR')
    errors = ASOMetadata.validate(@data)
    assert errors.any? { |e| e.include?('English fallback') }
    assert errors.any? { |e| e.include?('generic English placeholder') }
    assert errors.any? { |e| e.include?('native script') }
  end
  def test_missing_app_language_and_regional_locale_are_rejected
    @data['localizations'].delete('cs')
    @data['localizations'].delete('zh-Hant')
    errors = ASOMetadata.validate(@data, languages: @languages)
    assert errors.any? { |e| e.include?('App language coverage') }
    assert errors.any? { |e| e.include?('zh-Hant') }
  end
  def test_unsupported_filipino_cannot_be_silently_omitted
    @data['unsupportedStoreLanguages'].clear
    refute_empty ASOMetadata.validate(@data, languages: @languages)
  end
  def test_multibyte_limit_is_bytes_not_characters
    @data['localizations']['ja']['keywords'] = '読' * 34
    assert ASOMetadata.validate(@data).any? { |e| e.include?('102 exceeds 100') }
  end
  def test_truncated_twenty_locale_snapshot_fails
    errors = ASOMetadata.compare(@data,version_localizations:@localizations.first(20))
    assert errors.any? { |e| e.include?('missing locales') }
  end
  def test_extra_and_duplicate_locales_fail
    extras = @localizations + [@localizations.first, {'attributes'=>{'locale'=>'uk','keywords'=>'test'}}]
    errors = ASOMetadata.compare(@data,version_localizations:extras)
    assert errors.any? { |e| e.include?('duplicate locale') }
    assert errors.any? { |e| e.include?('uncatalogued locales') }
  end
  def test_subtitle_drift_fails_even_when_keywords_match
    info = Marshal.load(Marshal.dump(@localizations))
    info.first['attributes']['subtitle'] = 'Old subtitle'
    errors = ASOMetadata.compare(@data,version_localizations:@localizations,app_info_localizations:info)
    assert_equal ['en-US/subtitle: differs from reviewed catalog'],errors
  end
  def test_pagination_follows_second_page
    requested=[]
    pages={'/first'=>{'data'=>(1..20).to_a,'links'=>{'next'=>'https://api.appstoreconnect.apple.com/second'}},'/second'=>{'data'=>(21..29).to_a,'links'=>{}}}
    result=ASOMetadata.get_all('/first') { |path| requested << path; pages.fetch(path) }
    assert_equal 29,result.size
    assert_equal ['/first','/second'],requested
  end
  def test_pagination_cycle_stops
    assert_raises(RuntimeError) { ASOMetadata.get_all('/first') { {'data'=>[],'links'=>{'next'=>'https://api.appstoreconnect.apple.com/first'}} } }
  end
  def test_mac_same_version_cannot_be_selected_for_ios
    versions=[{'id'=>'mac','attributes'=>{'platform'=>'MAC_OS','versionString'=>'1.2.48','appStoreState'=>'READY_FOR_SALE'}},{'id'=>'ios','attributes'=>{'platform'=>'IOS','versionString'=>'1.2.48','appStoreState'=>'READY_FOR_SALE'}}]
    assert_equal 'ios',ASOMetadata.select_version(versions,platform:'IOS',number:'1.2.48')['id']
    assert_nil ASOMetadata.select_version(versions,platform:'IOS',id:'mac')
  end
  def test_keyword_mirror_cannot_drift
    refute_empty ASOMetadata.validate(@data,approved:{'en-US'=>'old'})
  end
  def test_complete_description_catalog_is_valid
    assert_empty ASOMetadata.validate_descriptions(ASOMetadata.descriptions)
  end
  def test_missing_or_english_description_cannot_pass
    data = ASOMetadata.descriptions
    data['localizations'].delete('cs')
    data['localizations']['ar-SA']['description'] = data['localizations']['en-US']['description']
    errors = ASOMetadata.validate_descriptions(data)
    assert errors.any? { |e| e.include?('coverage') }
    assert errors.any? { |e| e.include?('English fallback') }
    assert errors.any? { |e| e.include?('native script') }
  end
  def test_overlength_description_and_rejected_platform_fail
    data = ASOMetadata.descriptions
    data['localizations']['en-US']['description'] = 'x' * 4001 + ' Google Play Books'
    errors = ASOMetadata.validate_descriptions(data)
    assert errors.any? { |e| e.include?('4000') }
    assert errors.any? { |e| e.include?('rejected platform') }
  end
  def test_old_description_fails_even_when_search_fields_pass
    data = ASOMetadata.descriptions
    items = data['localizations'].map { |locale, row| {'attributes'=>row.merge('locale'=>locale)} }
    assert_empty ASOMetadata.compare_descriptions(data, version_localizations: items)
    items.first['attributes']['description'] = 'Old description'
    assert_equal ['en-US/description: differs from reviewed catalog'], ASOMetadata.compare_descriptions(data, version_localizations: items)
  end
  def test_duplicate_and_truncated_description_pages_fail
    data = ASOMetadata.descriptions
    items = data['localizations'].map { |locale, row| {'attributes'=>row.merge('locale'=>locale)} }
    items = items.first(20) + [items.first]
    errors = ASOMetadata.compare_descriptions(data, version_localizations: items)
    assert errors.any? { |e| e.include?('duplicate locale') }
    assert errors.any? { |e| e.include?('locale set') }
  end
end
