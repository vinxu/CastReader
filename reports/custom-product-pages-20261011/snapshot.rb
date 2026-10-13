require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
require 'fileutils'
ROOT=File.dirname(__FILE__)
client=ASCClient.new
live=JSON.parse(File.read(File.join(ROOT,'live-localizations.json')))
queue=Queue.new
live.fetch('included').each { |s| queue << s if s['type']=='appScreenshotSets' }
mutex=Mutex.new
results={}
threads=6.times.map do
  Thread.new do
    loop do
      s=queue.pop(true) rescue break
      items=client.get_all("/v1/appScreenshotSets/#{s['id']}/appScreenshots?limit=200")
      mutex.synchronize { results[s['id']]={set:s, screenshots:items} }
    end
  end
end
threads.each(&:value)
File.write(File.join(ROOT,'baseline-screenshots.json'),JSON.pretty_generate(results))
states=results.values.flat_map{|x|x[:screenshots].map{|s|s.dig('attributes','assetDeliveryState','state')}}
puts JSON.generate(sets:results.length,screenshots:results.values.sum{|x|x[:screenshots].length},states:states.group_by{|s|s}.transform_values(&:length))
