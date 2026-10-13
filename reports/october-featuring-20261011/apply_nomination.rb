require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
require 'json'
require 'time'
ROOT=File.expand_path(__dir__)
ID='e12dea24-c8b4-45b6-828b-061d97d5d459'
def save(name,x); File.write(File.join(ROOT,name),JSON.pretty_generate(x)+"\n");end
c=ASCClient.new
before=JSON.parse(File.read(File.join(ROOT,'nomination-before.json')))['data']
a=JSON.parse(File.read(File.join(ROOT,'proposed-attributes.json')))
a['supplementalMaterialsUris']=[
 'https://press.castreader.com/',
 'https://press.castreader.com/assets/castreader-approved-preview.mp4',
 'https://press.castreader.com/castreader-screenshots.zip',
 'https://castreader.com/castreader-app',
 'https://apps.apple.com/app/id6757636395'
]
a['submitted']=true
ids=JSON.parse(File.read(File.join(ROOT,'available-territory-ids.json')))
raise 'Invalid field lengths' unless a['name'].length<=60&&a['description'].length<=1000&&a['notes'].length<=500
raise 'Wrong devices/locales/territories' unless a['deviceFamilies']==['IPHONE','IPAD'] && a['locales'].uniq.length==29 && ids.uniq.length==175
payload={data:{type:'nominations',id:ID,attributes:a,relationships:{supportedTerritories:{data:ids.map{|id|{type:'territories',id:id}}}}}}
save('nomination-payload.json',payload)
unless ARGV.include?('--execute') || ARGV.include?('--audit-only')
 puts JSON.pretty_generate(status:'VALIDATED_NOT_APPLIED',name:a['name'],description_chars:a['description'].length,notes_chars:a['notes'].length,links:a['supplementalMaterialsUris'],regions:ids.length)
 exit
end
verification=JSON.parse(File.read(File.join(ROOT,'public-verification.json')))
raise 'Public media must be verified first' unless verification['pageMatchesLocal'] && verification['baseUrl']=='https://press.castreader.com'
current=c.request('GET',"/v1/nominations/#{ID}")['data']
unless ARGV.include?('--audit-only')
raise 'Nomination changed since snapshot' unless current['attributes']==before['attributes']
begin
 result=c.request('PATCH',"/v1/nominations/#{ID}",payload)
 save('nomination-update-response.json',result)
rescue ASCError=>e
 save('nomination-update-error.json',{status:e.status,document:e.document,ambiguous:e.ambiguous_write})
 raise unless e.ambiguous_write
end
end
after=c.request('GET',"/v1/nominations/#{ID}?include=relatedApps,inAppEvents,supportedTerritories&limit[supportedTerritories]=200")
save('nomination-after.json',after)
d=after['data'];expected=a.reject{|k,_|k=='submitted'}
expected.each{|k,v| actual=d['attributes'][k];raise "Mismatch in #{k}" unless %w[locales supplementalMaterialsUris].include?(k) ? actual.sort==v.sort : actual==v}
%w[type publishStartDate publishEndDate createdDate].each{|k|raise "Unexpected change: #{k}" unless d['attributes'][k]==before['attributes'][k]}
raise 'Wrong submission state' unless d['attributes']['state']=='SUBMITTED'
raise 'Wrong app' unless d.dig('relationships','relatedApps','data')==before.dig('relationships','relatedApps','data')
actual_regions=d.dig('relationships','supportedTerritories','data').map{|x|x['id']}.sort
raise 'Region mismatch' unless actual_regions==ids.sort
receipt={verifiedAt:Time.now.utc.iso8601,id:ID,state:d['attributes']['state'],name:d['attributes']['name'],lastModifiedDate:d['attributes']['lastModifiedDate'],submittedDate:d['attributes']['submittedDate'],publishStartDate:d['attributes']['publishStartDate'],publishEndDate:d['attributes']['publishEndDate'],devices:d['attributes']['deviceFamilies'],localizations:d['attributes']['locales'].length,regions:actual_regions.length,links:d['attributes']['supplementalMaterialsUris'],preservedOriginalNomination:true}
save('receipt.json',receipt);puts JSON.pretty_generate(receipt)
