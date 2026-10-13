require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
require_relative '../../scripts/aso_metadata'
require 'time'
client=ASCClient.new
catalog=ASOMetadata.catalog
abort ASOMetadata.validate(catalog).join("\n") unless ASOMetadata.validate(catalog).empty?
plan=JSON.parse(File.read('reports/aso-28-languages-20261011/intended-diff.json'))
# Only intended differences on the pending Mac version and pending shared App Info.
parents={'appStoreVersionLocalizations'=>['appStoreVersions','e9065422-ce33-4ff5-81e1-a7b7aef4f7b4'],'appInfoLocalizations'=>['appInfos','988607e7-fe9f-45ad-9432-86fca303d591']}
receipt=[]
parents.each do |type,(parent_type,parent_id)|
 parent=client.request('GET',"/v1/#{parent_type}/#{parent_id}").fetch('data')
 state=parent.dig('attributes','appStoreState')
 unless %w[PREPARE_FOR_SUBMISSION WAITING_FOR_REVIEW].include?(state)
  receipt << {parentId:parent_id,status:'state_not_editable',state:state};next
 end
 plan.select { |r| r['parentId']==parent_id && r['resourceType']==type }.each do |row|
  path="/v1/#{type}/#{row['id']}"
  current=client.request('GET',path).fetch('data').fetch('attributes')
  if row['after'].all? { |k,v| current[k]==v }
   receipt << {locale:row['locale'],resourceType:type,status:'already_matches'};next
  end
  unless row['before'].all? { |k,v| current[k]==v }
   receipt << {locale:row['locale'],resourceType:type,status:'concurrent_change'};break
  end
  begin
   client.request('PATCH',path,{data:{type:type,id:row['id'],attributes:row['after']}})
   readback=client.request('GET',path).fetch('data').fetch('attributes')
   raise 'Readback mismatch' unless row['after'].all? { |k,v| readback[k]==v }
   receipt << {locale:row['locale'],resourceType:type,status:'applied_and_verified',attributes:row['after']}
   puts "Applied #{type} #{row['locale']}"; STDOUT.flush
  rescue ASCError => e
   receipt << {locale:row['locale'],resourceType:type,status:'apple_rejected_or_unknown',httpStatus:e.status,error:e.document,ambiguousWrite:e.ambiguous_write}
   puts "Stopped #{type}: HTTP #{e.status}"
   break
  ensure
   File.write('reports/aso-28-languages-20261011/pending-write-receipt.json',JSON.pretty_generate({checkedAt:Time.now.utc.iso8601,items:receipt}))
  end
 end
end
File.write('reports/aso-28-languages-20261011/pending-write-receipt.json',JSON.pretty_generate({checkedAt:Time.now.utc.iso8601,items:receipt}))
puts JSON.pretty_generate(receipt.select { |r| !%w[applied_and_verified already_matches].include?(r[:status]) })
