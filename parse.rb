#!/usr/bin/env ruby
require "uri"
require "json"
require "yaml"
require "shellwords"

require "twitter-text"
require "addressable/uri"
require "httpclient"
require "openssl"

# OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

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
expanded_urls = {}

KNOWN_MEDIA_HOSTNAMES = YAML.load_file "media_hostnames.yaml"
KNOWN_DEAD_HOSTNAMES = YAML.load_file "dead_hostnames.yaml"

# Cap max redirects at 20 (same as Chrome)
MAX_REDIRECTS = 20

%w(INT TERM).each {|s| trap(s){puts "\ntake care out there \u{1f44b}"; abort}}

@client = HTTPClient.new

# Timeouts, in seconds
@client.send_timeout = 2
# @client.receive_timeout = 2
@client.connect_timeout = 4
@client.keep_alive_timeout = 2

# Kill SSL errors, speed up resolution
@client.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_NONE

# Custom exceptions
class DeadHostnameError < StandardError; end
class TooManyRedirectsError < StandardError; end
class MediaURLError < StandardError; end
class UnimplementedMediaURLError < StandardError; end

# Start/stop timer
def time
  start = Time.now
yield
  mm, ss = (Time.now - start).divmod(60)
  hh, mm = mm.divmod(60)
  puts "Time elapsed: %d hours, %d minutes and %d seconds" % [hh, mm, ss]
end

# Follow redirects to their final value
# Returns an array of [status, url, normalised_url] arrays
def expand_url(url, urls=[])
  status = "---"
  uri = Addressable::URI.parse(url).normalize

  # print "[#{(urls.length+1).to_s.rjust(2,"0")}] #{uri.to_s}"
  # print "[#{urls.length+1}] #{uri.to_s}"
  print "[#{urls.length+1}] #{uri.to_s.length > 80 ? "#{uri.to_s[0...80]}..." : uri.to_s}"

  begin
    # Exclude known dead hostnames
    raise DeadHostnameError if KNOWN_DEAD_HOSTNAMES.include? uri.host

    raise TooManyRedirectsError if urls.length >= MAX_REDIRECTS

    # Get response
    res = @client.head(uri.to_s) # HTTPClient.head(uri.to_s)

    # secrets.blacktree.com returns 405 for HEAD requests
    # See it in action: curl -I http://secrets.blacktree.com
    res = @client.get(uri.to_s) if res.status_code.to_s == "405"

    # Status is empty on search.twitter.com URLs for some reason
    status = res.status_code.to_s.empty? ? "???" : res.status_code.to_s

    puts " (#{status})"

  # Allow interrupt
  rescue SystemExit, Interrupt
    raise

  # Connection issues
  rescue Errno::ECONNREFUSED
    puts " - Connection refused"
  rescue SocketError
    puts " - DNS failed to resolve"
  rescue OpenSSL::SSL::SSLError
    puts " - SSL error (probably a self-signed certificate)"
  rescue HTTPClient::ConnectTimeoutError
    puts " - Connection timed out"
  rescue HTTPClient::SendTimeoutError
    puts " - Send timed out (problematic)"
  rescue HTTPClient::ReceiveTimeoutError
    puts " - Receive timed out (problematic)"

  # Custom errors
  rescue TooManyRedirectsError
    puts " - Too many redirects (#{urls.length})"
  rescue DeadHostnameError
    status = "xxx"
    puts " - '#{uri.host}' is a known dead hostname"

  # Catch-all
  rescue
    puts " - Mystery error"

  # Always build url array
  ensure
    urls.unshift ["#{status}", "#{uri.to_s}", "#{url}"]
  end

  # Redirect status code?
  if res && res.status_code.to_s =~ /^30\d$/
    # Recurse if we have a Location header
    unless url == res.header["Location"][0]
      location = res.header["Location"][0]

      # Protocol-less URL
      if location[0..1] == "//"
        puts " |  Relative URL scheme: #{location}"
        location = "#{uri.scheme}:#{location}"
      else
        # Append hostname if not present
        unless location =~ /^https?:\/\//i
          puts " |  URL missing hostname: #{location}"
          location = "#{uri.scheme}://#{uri.host}/#{location.gsub(/^\//,"")}"
        end
      end

      # Roll that beautiful bean footage
      urls = expand_url(location, urls)

    else
      # Weird.
      puts "--- Redirect loop"
    end
  end

  urls
end

Dir.chdir("./tweets/data/js/tweets")

# puts "", "Tweets by month:", "================"
Dir.glob("*.js") do |p|
  # get JSON
  tweets_by_month = JSON.parse(IO.read(p).lines.to_a[1..-1].join)

  ignored_tweets = []
  # concat media items
  tweets_by_month.reverse.each do |v|

    # Ignore retweets
    if v["text"][0...4] == "RT @"
      ignored_tweets.push "#{v["id_str"]}: #{v["text"]}".gsub("\n", "\\n")
      next
    end

    # Extract hashtags
    if v["entities"]["hashtags"].length == 0
      v["entities"]["hashtags"] = Twitter::Extractor.extract_hashtags v["text"]
    end

    if v["entities"]["hashtags"].length > 0
      shared_hashtags.concat v["entities"]["hashtags"]
      hashtagged_tweets.push "#{v["created_at"]}: #{v["text"]}"
    end

    # Extract URLs
    if v["entities"]["urls"].length == 0
      # TODO: Enabled this only for pre-entities tweets.
      found_urls = Twitter::Extractor.extract_urls(v["text"])
      # Remove t.co URLs--they should already be in v["entities"]["urls"]
      found_urls.reject! {|u| u.match "://t.co/"}
    else
      found_urls = v["entities"]["urls"].map {|u| u["expanded_url"]}
    end

    found_urls.each do |u|
      uri = Addressable::URI.parse(u).normalize
      if KNOWN_MEDIA_HOSTNAMES.include? uri.host
        media_url = "BROKEN" # uri.to_s

        begin

          case uri.host

          when "cl.ly"
            contents = HTTPClient.get(uri.to_s, {}, {"Accept" => "application/json"}).body
            media_url = JSON::parse(contents)["download_url"]

          when "twitpic.com"
            if uri.to_s =~ /\/(?<url_key>[^\/]+)$/
              media_url = "http://twitpic.com/show/full/#{$~[:url_key]}"
              # media_url = HTTPClient.get("http://twitpic.com/show/full/#{$~[:url_key]}").header["Location"][0]
            else
              raise MediaURLError
            end

          when "yfrog.com", "yfrog.us"
            if uri.to_s =~ /\/(?<url_key>[^\/]+)$/
              api_url = "http://yfrog.com/api/xmlInfo?path=#{$~[:url_key]}"
              if @client.get(api_url).header["Location"][0] =~ /(?<host>https?:\/\/.+?\/).*?l=(?<img_url>.+?)&xml/
                media_url = "#{$~[:host]}#{$~[:img_url]}"
              else
                raise MediaURLError
              end
            end
          else
            raise UnimplementedMediaURLError
          end

        rescue MediaURLError
          media_url = "ERROR"

        rescue UnimplementedMediaURLError
          media_url = "UNIMPLEMENTED"

        rescue
          media_url = "ERROR2"
        end

        media_by_hostname[uri.host] ||= {}
        media_by_hostname[uri.host]["#{uri.host}#{uri.path}"] = media_url
      end
    end

    shared_urls.concat found_urls

    # shared_media.concat v["entities"]["media"]

    media_by_hostname["pic.twitter.com"] ||= {}
    v["entities"]["media"].each do |m|
      media_by_hostname["pic.twitter.com"][m["display_url"]] = m["media_url"]
    end

  end

  # puts "#{p}: #{tweets_by_month.length} tweets"
  # puts ignored_tweets.map {|t| " - Ignored #{t}"[0..60]}.join("\n") unless ignored_tweets.empty?

  tweets.concat tweets_by_month
end

puts
puts "#{tweets.length} tweets in total"
puts "#{shared_media.length} media shits in total"
puts "#{shared_hashtags.length} hashtags in total"
puts "#{shared_urls.length} URLs in total"

Dir.chdir IMG_CACHE_PATH
puts "", "Let’s get this party started!"

=begin
time do
  # Build array of shared URLs
  shared_urls.each_with_index do |s, idx|
    url = "#{s}"
    url = "http://#{url}" unless url =~ /^https?:\/\//i

    puts "", "=== #{idx+1} of #{shared_urls.length} ==========="

    # Filter out invalid URLs
    urls = expand_url(url)
    next if urls.empty?

    # Using addressable to deal with IDNs
    u = Addressable::URI.parse(urls[0][1]).normalize
    hostname = u.host.to_s.downcase

    # Pretty dumb regex but whatever idgaf
    hostname = $~[:url] if hostname =~ /(?<url>[\w\-]+(?:\.\w{2,3}){1,2})$/

    urls_by_hostname[hostname] ||= []
    urls_by_hostname[hostname].push urls[0][1]

    puts ">>> #{urls[0][1]}"
  end
end

puts "", "Shared URLs", "==========="

Hash[urls_by_hostname.sort].each do |k,v|
  puts "#{k} (#{v.length})"
  v.each do |d|
    puts " - #{d}"
  end
end

=end

puts "", "Shared media", "==========="

Hash[media_by_hostname.sort].each do |k,v|
  puts "#{k} (#{v.length})"
  v.each do |k,v|
    puts " - #{k}: #{v}"
  end
end