#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'net/http'
require 'uri'
require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
ROOT = File.dirname(__FILE__)
CLIENT = ASCClient.new
def save(name, value)
  File.write(File.join(ROOT, "#{name}.json"), JSON.pretty_generate(value))
end
def load_saved(name)
  path=File.join(ROOT,"#{name}.json")
  File.file?(path) ? JSON.parse(File.read(path)) : nil
end
def ref(type,id)
  {'data'=>{'type'=>type,'id'=>id}}
end
def request(method,path,payload=nil)
  CLIENT.request(method,path,payload)
rescue ASCError=>e
  save('last-error',{'method'=>method,'path'=>path,'status'=>e.status,'ambiguous'=>e.ambiguous_write,'document'=>e.document,'message'=>e.message})
  raise
end
def upload(resource,path,prefix)
  operations=resource.fetch('attributes').fetch('uploadOperations')
  data=File.binread(path)
  operations.each_with_index do |op,index|
    uri=URI(op.fetch('url'))
    raise 'Non-HTTPS upload refused' unless uri.scheme=='https'
    klass=Net::HTTP.const_get(op.fetch('method').capitalize)
    req=klass.new(uri)
    op.fetch('requestHeaders',[]).each{|h|req[h.fetch('name')]=h.fetch('value')}
    req.body=data.byteslice(op.fetch('offset'),op.fetch('length'))
    response=Net::HTTP.start(uri.hostname,uri.port,use_ssl:true,open_timeout:20,read_timeout:120){|h|h.request(req)}
    save("#{prefix}-part-#{index}",{'status'=>response.code,'bytes'=>req.body.bytesize})
    raise "Upload part #{index}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  end
end

case ARGV.fetch(0)
when 'yearly-version'
  before=request('GET','/v1/subscriptions/6802002910/versions?include=localizations,image')
  save('yearly-versions-precreate',before)
  draft=before.fetch('data').find{|x|['PREPARE_FOR_SUBMISSION','READY_FOR_REVIEW'].include?(x.dig('attributes','state'))}
  raise 'Unexpected existing draft; inspect manually' if draft && !load_saved('yearly-version-created')
  result=load_saved('yearly-version-created') || request('POST','/v1/subscriptionVersions',{'data'=>{'type'=>'subscriptionVersions','relationships'=>{'subscription'=>ref('subscriptions','6802002910')}}})
  save('yearly-version-created',result)
  puts JSON.generate(result['data'].slice('id','attributes'))
when 'yearly-image'
  version=load_saved('yearly-version-created').fetch('data').fetch('id')
  path=File.join(ROOT,'pro-subscription-1024x1024.png')
  result=load_saved('yearly-image-created')
  if result && result.dig('data','attributes','fileName') != File.basename(path)
    old_id=result.fetch('data').fetch('id')
    old=request('GET',"/v2/subscriptionImages/#{old_id}")
    raise 'Do not remove an uploaded image' unless old.dig('data','attributes','assetDeliveryState','state')=='AWAITING_UPLOAD'
    save('yearly-image-retired-unuploaded',old)
    request('DELETE',"/v2/subscriptionImages/#{old_id}")
    File.rename(File.join(ROOT,'yearly-image-created.json'),File.join(ROOT,'yearly-image-created-retired.json'))
    result=nil
  end
  unless result
    result=request('POST','/v2/subscriptionImages',{'data'=>{'type'=>'subscriptionImages','attributes'=>{'fileName'=>File.basename(path),'fileSize'=>File.size(path)},'relationships'=>{'version'=>ref('subscriptionVersions',version)}}})
    save('yearly-image-created',result)
  end
  id=result.fetch('data').fetch('id')
  current=request('GET',"/v2/subscriptionImages/#{id}")
  if current.dig('data','attributes','assetDeliveryState','state')=='AWAITING_UPLOAD'
    upload(current.fetch('data'),path,'yearly-image')
    current=request('PATCH',"/v2/subscriptionImages/#{id}",{'data'=>{'type'=>'subscriptionImages','id'=>id,'attributes'=>{'uploaded'=>true}}})
    save('yearly-image-uploaded',current)
  end
  asset=current.fetch('data')
  puts JSON.generate({'id'=>asset['id'],'attributes'=>asset['attributes'].slice('assetDeliveryState','fileName','imageAsset')})
when 'creative'
  kind=ARGV.fetch(1)
  files={'search'=>'search-listen-follow-1920x1280.png','header'=>'header-listen-follow-3840x1646.png'}
  path=File.join(ROOT,files.fetch(kind))
  prefix="creative-#{kind}"
  result=load_saved("#{prefix}-created")
  unless result
    before=CLIENT.get_all('/v1/appAssetLibraries/6757636395/images?limit=200')
    save("#{prefix}-before",before)
    existing=before.find{|x|x.dig('attributes','fileName')==File.basename(path)}
    raise "Existing file found; inspect #{existing['id']}" if existing
    result=request('POST','/v1/appAssetLibraryImages',{'data'=>{'type'=>'appAssetLibraryImages','attributes'=>{'category'=>'CREATIVE_ASSETS','fileName'=>File.basename(path),'fileSize'=>File.size(path),'referenceName'=>"Listen Follow Understand - #{kind.capitalize} - 2026-10"},'relationships'=>{'assetLibrary'=>ref('appAssetLibraries','6757636395')}}})
    save("#{prefix}-created",result)
  end
  id=result.fetch('data').fetch('id')
  current=request('GET',"/v1/appAssetLibraryImages/#{id}")
  if current.dig('data','attributes','state')=='AWAITING_UPLOAD'
    upload(current.fetch('data'),path,prefix)
    current=request('PATCH',"/v1/appAssetLibraryImages/#{id}",{'data'=>{'type'=>'appAssetLibraryImages','id'=>id,'attributes'=>{'uploaded'=>true}}})
    save("#{prefix}-uploaded",current)
  end
  asset=current.fetch('data')
  puts JSON.generate({'id'=>asset['id'],'attributes'=>asset['attributes'].slice('state','fileName','imageAsset','stateDetails')})
when 'review-prepare'
  # Ensure this remains an artwork-only change to the already approved product.
  version=load_saved('yearly-version-created').fetch('data').fetch('id')
  current=request('GET',"/v1/subscriptionVersions/#{version}?include=localizations,image")
  prior=load_saved('yearly-versions-precreate')
  localizations=lambda{|doc|doc.fetch('included',[]).select{|x|x['type']=='subscriptionLocalizations'}.map{|x|x.fetch('attributes')}.sort_by{|x|x['locale']}}
  raise 'Subscription copy unexpectedly changed' unless localizations.call(prior)==localizations.call(current)
  image=current.fetch('included',[]).find{|x|x['type']=='subscriptionImages'}
  raise 'Subscription image not ready' unless image&.dig('attributes','assetDeliveryState','state')=='COMPLETE' && image.dig('attributes','imageAsset','width')==1024 && image.dig('attributes','imageAsset','height')==1024
  refs=%w[search header].map do |kind|
    id=load_saved("creative-#{kind}-created").fetch('data').fetch('id')
    doc=request('GET',"/v1/appAssetLibraryImages/#{id}")
    save("creative-#{kind}-pre-review",doc)
    raise 'Creative not ready' unless ['PREPARE_FOR_SUBMISSION','READY_FOR_REVIEW'].include?(doc.dig('data','attributes','state'))
    ["creative-#{kind}",'appAssetLibraryImage','appAssetLibraryImages',id]
  end
  refs << ['yearly-version','subscriptionVersion','subscriptionVersions',version]
  review=load_saved('review-created')
  unless review
    before=CLIENT.get_all('/v1/apps/6757636395/reviewSubmissions?limit=200')
    save('reviews-precreate',before)
    draft=before.find{|x|x.dig('attributes','platform')=='IOS' && x.dig('attributes','state')=='READY_FOR_REVIEW'}
    raise "Existing review draft #{draft['id']} needs inspection" if draft
    review=request('POST','/v1/reviewSubmissions',{'data'=>{'type'=>'reviewSubmissions','attributes'=>{'platform'=>'IOS'},'relationships'=>{'app'=>ref('apps','6757636395')}}})
    save('review-created',review)
  end
  review_id=review.fetch('data').fetch('id')
  refs.each do |name,relationship,type,id|
    next if load_saved("review-item-#{name}")
    result=request('POST','/v1/reviewSubmissionItems',{'data'=>{'type'=>'reviewSubmissionItems','relationships'=>{'reviewSubmission'=>ref('reviewSubmissions',review_id),relationship=>ref(type,id)}}})
    save("review-item-#{name}",result)
    puts JSON.generate({'added'=>name,'id'=>result.fetch('data').fetch('id')})
  end
  result=request('GET',"/v1/reviewSubmissions/#{review_id}?include=items")
  save('review-prepared',result)
  puts JSON.generate(result.fetch('data').slice('id','attributes'))
when 'review-submit'
  review_id=load_saved('review-created').fetch('data').fetch('id')
  before=request('GET',"/v1/reviewSubmissions/#{review_id}?include=items")
  save('review-pre-submit',before)
  actual=before.fetch('data').dig('relationships','items','data').map{|x|x['id']}.sort
  expected=%w[creative-search creative-header yearly-version].map{|x|load_saved("review-item-#{x}").fetch('data').fetch('id')}.sort
  raise 'Review items differ from prepared scope' unless actual==expected
  state=before.dig('data','attributes','state')
  if state=='READY_FOR_REVIEW'
    result=request('PATCH',"/v1/reviewSubmissions/#{review_id}",{'data'=>{'type'=>'reviewSubmissions','id'=>review_id,'attributes'=>{'submitted'=>true}}})
    save('review-submit-result',result)
  elsif !['WAITING_FOR_REVIEW','IN_REVIEW','COMPLETE'].include?(state)
    raise "Unexpected review state #{state}"
  end
  result=request('GET',"/v1/reviewSubmissions/#{review_id}?include=items")
  save('review-submitted-readback',result)
  puts JSON.generate(result.fetch('data').slice('id','attributes','relationships'))
when 'readback'
  %w[search header].each do |kind|
    prefix="creative-#{kind}"
    saved=load_saved("#{prefix}-created")
    next unless saved
    result=request('GET',"/v1/appAssetLibraryImages/#{saved.fetch('data').fetch('id')}")
    save("#{prefix}-readback",result)
    puts JSON.generate(result.fetch('data').slice('id','attributes').tap{|x|x['attributes']=x['attributes'].slice('state','stateDetails','fileName','imageAsset')})
  end
  version=load_saved('yearly-version-created').fetch('data').fetch('id')
  result=request('GET',"/v1/subscriptionVersions/#{version}?include=localizations,image")
  save('yearly-version-readback',result)
  puts JSON.generate(result.fetch('data').slice('id','attributes'))
  result.fetch('included',[]).each{|x| puts JSON.generate(x.slice('type','id','attributes').tap{|a|a['attributes']=a['attributes'].reject{|k,v|k=='uploadOperations'}})}
else
  raise 'Unknown action'
end
