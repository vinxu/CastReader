require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
require 'json'
require 'fileutils'
p=File.expand_path(__dir__)
FileUtils.mkdir_p("#{p}/analytics-private")
queue=Queue.new
%w[r3 r14].each do |key|
 JSON.parse(File.read("#{p}/#{key}-instances.json"))['data'].select{|x|x['attributes']['processingDate']>='2026-09-11'}.each{|x|queue << [key,x]}
end
errors=Queue.new
threads=4.times.map do
 Thread.new do
  c=ASCClient.new
  loop do
   begin; key,x=queue.pop(true);rescue ThreadError;break;end
   begin
    file="#{p}/analytics-private/#{key}-#{x['attributes']['processingDate']}.json"
    next if File.exist?(file)
    r=c.request('GET',"/v1/analyticsReportInstances/#{x['id']}/segments?limit=200")
    raise 'Unexpected pagination' if r.dig('links','next')
    File.write(file,JSON.pretty_generate(r))
    File.chmod(0600,file)
   rescue => e
    errors << {key:key,date:x['attributes']['processingDate'],error:e.class.name}
   end
  end
 end
end
threads.each(&:join)
e=[];e<<errors.pop until errors.empty?
puts JSON.generate(segmentIndexes:Dir.glob("#{p}/analytics-private/*.json").size,errors:e)
raise 'Analytics fetch incomplete' unless e.empty?
