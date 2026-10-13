require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
require 'fileutils'
ROOT=File.dirname(__FILE__)
CLIENT=ASCClient.new
PLAN=JSON.parse(File.read(File.join(ROOT,'plan.json')))
LIVE=JSON.parse(File.read(File.join(ROOT,'live-localizations.json')))
BASE=JSON.parse(File.read(File.join(ROOT,'baseline-screenshots.json')))
APP='6757636395'
$stdout.sync=true

def save(name,data)
  File.write(File.join(ROOT,name+'.json'),JSON.pretty_generate(data))
end
def journal(method,path,payload,result)
  File.open(File.join(ROOT,'mutations.jsonl'),'a') {|f| f.puts(JSON.generate(time:Time.now.utc.iso8601,method:method,path:path,payload:payload,result:result)) }
end
def mutate(method,path,payload)
  result=CLIENT.request(method,path,payload)
  journal(method,path,payload,result)
  result
rescue ASCError=>e
  journal(method,path,payload,{error:e.message,document:e.document,ambiguous:e.ambiguous_write})
  raise
end
require 'time'
def pages
  CLIENT.request('GET',"/v1/apps/#{APP}/appCustomProductPages?include=appCustomProductPageVersions&limit=200")
end
def page_and_version(key)
  spec=PLAN['pages'].find{|p|p['key']==key}
  collection=pages
  page=collection['data'].find{|p|p.dig('attributes','name')==spec['name']}
  raise "Missing #{key}" unless page
  versions=CLIENT.get_all("/v1/appCustomProductPages/#{page['id']}/appCustomProductPageVersions?limit=200")
  raise 'Expected exactly one page version' unless versions.length==1
  [spec,page,versions.first]
end
def parallel_map(items)
  queue=Queue.new;items.each_with_index{|v,i|queue << [i,v]};out=Array.new(items.length)
  6.times.map do
    Thread.new do
      loop do
        pair=queue.pop(true) rescue break
        i,item=pair;out[i]=yield(item)
      end
    end
  end.each(&:value)
  out
end
def inventory(key)
  spec,page,version=page_and_version(key)
  locs=CLIENT.get_all("/v1/appCustomProductPageVersions/#{version['id']}/appCustomProductPageLocalizations?limit=200")
  details=parallel_map(locs) do |loc|
    sets=CLIENT.request('GET',"/v1/appCustomProductPageLocalizations/#{loc['id']}/appScreenshotSets?include=appScreenshots&limit=200&limit%5BappScreenshots%5D=50")
    keywords=CLIENT.get_all("/v1/appCustomProductPageLocalizations/#{loc['id']}/searchKeywords?limit=200")
    {localization:loc,sets:sets,keywords:keywords}
  end
  data={spec:spec,page:page,version:version,details:details}
  save(key+'-inventory',data)
  JSON.parse(JSON.generate(data))
end
def keywords_for(key,locale)
  available=LIVE['data'].find{|x|x.dig('attributes','locale')==locale}.dig('attributes','keywords').split(',')
  preferred={
    'books'=>%w[kindle epub ebook hörbuch 電子書籍 有声书 有聲書],
    'documents'=>%w[pdf ocr scan article document dokument documentos ओसीआर 網頁閱讀 文件朗讀 网页阅读 文档朗读],
    'study'=>%w[study lernen étude estudio estudo studio 語学学習 英语听力 英語聽力]
  }.fetch(key)
  available.select{|x|preferred.include?(x.downcase)}
end
def validate_inventory(inv,ordered:)
  spec=inv['spec'];details=inv['details']
  raise 'Locales differ from plan' unless details.map{|d|d.dig('localization','attributes','locale')}.sort==spec['copy'].keys.sort
  count=0
  details.each do |d|
    locale=d.dig('localization','attributes','locale')
    raise "Copy mismatch #{locale}" unless d.dig('localization','attributes','promotionalText')==spec['copy'][locale]
    baseline_loc=LIVE['data'].find{|x|x.dig('attributes','locale')==locale}
    baseline_sets=baseline_loc.dig('relationships','appScreenshotSets','data').map{|x|BASE[x['id']]}
    sets=d['sets']['data'];raise "Set count #{locale}" unless sets.length==baseline_sets.length
    sets.each do |s|
      baseline=baseline_sets.find{|b|b.dig('set','attributes','screenshotDisplayType')==s.dig('attributes','screenshotDisplayType')}
      raise 'Unknown display type' unless baseline
      shots=s.dig('relationships','appScreenshots','data').map{|ref|d['sets']['included'].find{|x|x['id']==ref['id']}}
      raise "Missing screenshots #{locale}" unless shots.length==5 && shots.all?
      raise "Incomplete screenshot #{locale}" unless shots.all?{|x|x.dig('attributes','assetDeliveryState','state')=='COMPLETE'}
      checksums=shots.map{|x|x.dig('attributes','sourceFileChecksum')}
      expected=baseline['screenshots'].map{|x|x.dig('attributes','sourceFileChecksum')}
      raise "Different image bytes #{locale}" unless checksums.sort==expected.sort
      if ordered
        expected=spec['order'].map{|n|expected[n-1]}
        raise "Order mismatch #{locale}" unless checksums==expected
      end
      count+=shots.length
    end
    if ordered
      actual=d['keywords'].map{|k|k['id']}.sort
      raise "Keyword mismatch #{locale}" unless actual==keywords_for(spec['key'],locale).sort
    end
  end
  {page:spec['key'],locales:details.length,screenshotSets:details.sum{|d|d['sets']['data'].length},screenshots:count,keywordAssignments:details.sum{|d|d['keywords'].length},state:inv.dig('version','attributes','state'),visible:inv.dig('page','attributes','visible'),url:inv.dig('page','attributes','url')}
end

begin
  command=ARGV.fetch(0)
  case command
  when 'create'
    key=ARGV.fetch(1);spec=PLAN['pages'].find{|p|p['key']==key}
    existing=pages['data'].find{|p|p.dig('attributes','name')==spec['name']}
    if existing
      puts JSON.generate(resumed:existing)
    else
      begin
        response=mutate('POST','/v1/appCustomProductPages',JSON.parse(File.read(File.join(ROOT,'create-'+key+'.json'))))
        save('created-'+key,response);puts JSON.generate(created:response['data'])
      rescue ASCError=>e
        raise unless e.ambiguous_write || e.status.to_i>=500
        recovered=pages
        found=recovered['data'].find{|p|p.dig('attributes','name')==spec['name']}
        raise unless found
        save('created-'+key+'-recovered',recovered)
        puts JSON.generate(recovered:found)
      end
    end
  when 'configure'
    key=ARGV.fetch(1);inv=inventory(key);puts JSON.generate(validate_inventory(inv,ordered:false))
    raise 'Page not editable' unless inv.dig('version','attributes','state')=='PREPARE_FOR_SUBMISSION'
    spec=inv['spec']
    inv['details'].each_with_index do |d,index|
      locale=d.dig('localization','attributes','locale')
      d['sets']['data'].each do |s|
        shots=s.dig('relationships','appScreenshots','data').map{|ref|d['sets']['included'].find{|x|x['id']==ref['id']}}
        by_number=shots.to_h{|x|[x.dig('attributes','fileName').match(/-(\d\d)-/)[1].to_i,x]}
        desired=spec['order'].map{|n|{'type'=>'appScreenshots','id'=>by_number.fetch(n)['id']}}
        unless shots.map{|x|x['id']}==desired.map{|x|x['id']}
          mutate('PATCH',"/v1/appScreenshotSets/#{s['id']}/relationships/appScreenshots",{data:desired})
        end
      end
      wanted=keywords_for(key,locale);current=d['keywords'].map{|k|k['id']}
      raise 'Unexpected preexisting keyword assignment' unless (current-wanted).empty?
      missing=wanted-current
      unless missing.empty?
        mutate('POST',"/v1/appCustomProductPageLocalizations/#{d['localization']['id']}/relationships/searchKeywords",{data:missing.map{|k|{type:'appKeywords',id:k}}})
      end
      puts "#{key}: #{index+1}/#{inv['details'].length} #{locale} configured"
    end
  when 'audit'
    results=PLAN['pages'].map do |p|
      result=validate_inventory(inventory(p['key']),ordered:true);puts JSON.generate(result);result
    end
    save('audit',results)
  when 'submit'
    audited=JSON.parse(File.read(File.join(ROOT,'audit.json')))
    raise 'Audit incomplete' unless audited.length==3 && audited.all?{|a|a['locales']==29 && a['screenshots']==290 && a['visible']==true}
    versions=PLAN['pages'].map{|p|page_and_version(p['key'])[2]}
    version_ids=versions.map{|v|v['id']}
    active=CLIENT.get_all("/v1/apps/#{APP}/reviewSubmissions?filter%5Bplatform%5D=IOS&limit=200").reject{|s|s.dig('attributes','state')=='COMPLETE'}
    saved_path=File.join(ROOT,'submission-created.json')
    if File.exist?(saved_path)
      submission=CLIENT.request('GET',"/v1/reviewSubmissions/#{JSON.parse(File.read(saved_path)).dig('data','id')}")['data']
    else
      raise 'Unrelated active iOS review exists' unless active.empty?
      raise 'Page not ready' unless versions.all?{|v|v.dig('attributes','state')=='PREPARE_FOR_SUBMISSION'}
      response=mutate('POST','/v1/reviewSubmissions',{data:{type:'reviewSubmissions',attributes:{platform:'IOS'},relationships:{app:{data:{type:'apps',id:APP}}}}})
      save('submission-created',response);submission=response['data']
    end
    sid=submission['id']
    items=CLIENT.get_all("/v1/reviewSubmissions/#{sid}/items?include=appCustomProductPageVersion&limit=200")
    raise 'Unexpected review item' unless items.all?{|i|version_ids.include?(i.dig('relationships','appCustomProductPageVersion','data','id'))}
    if submission.dig('attributes','state')=='READY_FOR_REVIEW'
      version_ids.each do |vid|
        next if items.any?{|i|i.dig('relationships','appCustomProductPageVersion','data','id')==vid}
        response=mutate('POST','/v1/reviewSubmissionItems',{data:{type:'reviewSubmissionItems',relationships:{reviewSubmission:{data:{type:'reviewSubmissions',id:sid}},appCustomProductPageVersion:{data:{type:'appCustomProductPageVersions',id:vid}}}}})
        save('submission-item-'+vid,response)
      end
      final_items=CLIENT.get_all("/v1/reviewSubmissions/#{sid}/items?include=appCustomProductPageVersion&limit=200")
      raise 'Review item identity mismatch' unless final_items.map{|i|i.dig('relationships','appCustomProductPageVersion','data','id')}.sort==version_ids.sort
      save('submission-items-before-submit',final_items)
      context=CLIENT.request('GET',"/v1/reviewSubmissions/#{sid}?include=appStoreVersionForReview")
      save('submission-context-before-submit',context)
      associated=context.dig('data','relationships','appStoreVersionForReview','data','id')
      raise 'Review context does not match approved 1.2.48 baseline' if associated && associated!=PLAN['baselineVersionId']
      response=mutate('PATCH',"/v1/reviewSubmissions/#{sid}",{data:{type:'reviewSubmissions',id:sid,attributes:{submitted:true}}})
      save('submission-submit-response',response)
    end
    result=CLIENT.request('GET',"/v1/reviewSubmissions/#{sid}?include=items,appStoreVersionForReview")
    page_states=version_ids.map{|vid|CLIENT.request('GET',"/v1/appCustomProductPageVersions/#{vid}")['data']}
    save('submission-final',result);save('page-states-final',page_states)
    raise 'Submission not waiting' unless %w[WAITING_FOR_REVIEW IN_REVIEW COMPLETE].include?(result.dig('data','attributes','state'))
    raise 'Pages not waiting' unless page_states.all?{|v|%w[WAITING_FOR_REVIEW IN_REVIEW APPROVED].include?(v.dig('attributes','state'))}
    puts JSON.generate(submission:result['data'],pageStates:page_states.map{|v|{id:v['id'],state:v.dig('attributes','state')}})
  else
    raise 'Unknown command'
  end
rescue ASCError=>e
  warn JSON.pretty_generate(error:e.message,document:e.document,ambiguous_write:e.ambiguous_write)
  exit 1
end
