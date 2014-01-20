#!/usr/bin/env ruby
require "uri"
require "json"
require "shellwords"
require "twitter-text"

require "addressable/uri"
require "httpclient"

IMG_CACHE_PATH = File.expand_path "./image_cache"
# `mkdir -p #{Shellwords.escape IMG_CACHE_PATH}"`

tweets = []
hashtagged_tweets = []
shared_media = []
shared_hashtags = []
shared_urls = []
media_by_hostname = {}
urls_by_hostname = {}
urls_by_http_code = {}

%w(INT TERM).each {|s| trap(s){puts "\ntake care out there \u{1f44b}"; abort}}

@client = HTTPClient.new

def expand_url(url, depth=0)
  depth += 1
  begin
    puts "==============" if depth == 1
    puts "[#{depth}] Expanding #{url}"

    uri = Addressable::URI.parse(url)
    res = @client.get(url)

    if res.status_code == 200
      puts "200 #{url}"
      return url
    elsif res.status_code.to_s =~ /^30\d$/ #&& res.header["Location"]
      unless url == res.header["Location"][0]
        location = res.header["Location"][0]
        unless location =~ /^https?:\/\//
          puts "  - 'Location' did not include path"
          location = "#{uri.scheme}://#{uri.host}/#{location.gsub(/^\//,"")}"
        end
        return expand_url location, depth
      else
        puts "200 #{url}"
        return url
      end
    else
      puts "#{res.status_code} #{url}"
    end
  rescue SystemExit, Interrupt
    raise
  rescue SocketError
    # DNS resolution error
    puts "  - DNS failed to resolve"
    return nil
  end
end

Dir.chdir("./tweets/data/js/tweets")
Dir.glob("*.js") do |p|
  # get JSON
  tweets_by_month = JSON.parse(IO.read(p).lines.to_a[1..-1].join)

  # concat media items
  tweets_by_month.reverse.each do |v|
    shared_hashtags.concat v["entities"]["hashtags"]
    if v["entities"]["hashtags"].length > 0
      hashtagged_tweets.push "#{v["created_at"]}: #{v["text"]}"
    end
    if v["entities"]["urls"].length == 0
      shared_urls.concat Twitter::Extractor.extract_urls(v["text"])
    else
      shared_urls.concat v["entities"]["urls"].map {|u| u["expanded_url"]}
    end
    shared_media.concat v["entities"]["media"]
  end

  # puts "#{p}: #{tweets_by_month.length} tweets"
  tweets.concat tweets_by_month
end

puts
puts "#{tweets.length} tweets in total"
puts "#{shared_media.length} media shits in total"
puts "#{shared_hashtags.length} hashtags in total"
puts "#{shared_urls.length} URLs in total"

Dir.chdir IMG_CACHE_PATH
puts "","Let’s get this party started!",""

# Build array of shared URLs
shared_urls.each do |s|
  begin
    url = "#{s}"
    url = "http://#{url}" unless url =~ /^https?:\/\//

    # Filter out invalid URLs
    raise "nope" unless expanded_url = expand_url(url)

    # Using addressable to deal with IDNs
    u = Addressable::URI.parse(expanded_url).normalize
    hostname = u.host.to_s.downcase

    # Pretty dumb regex but whatever idgaf
    if hostname =~ /(?<url>[\w\-]+(?:\.\w{2,3}){1,2})$/
      hostname = $~[:url]
    end

    urls_by_hostname[hostname] ||= []
    urls_by_hostname[hostname].push expanded_url

    puts "[x] #{expanded_url}"
  rescue SystemExit, Interrupt
    raise
  rescue
    puts "[ ] #{url}"
  end
end

puts "\nShared URLs"

Hash[urls_by_hostname.sort].each do |k,v|
  puts "#{k}: (#{v.length})"
  v.each do |d|
    puts " - #{d}\n"
  end
end