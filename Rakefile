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

PWD = Dir.pwd
ARCHIVE_PATH = File.expand_path "./archive"
TWEET_PATH = File.join ARCHIVE_PATH, "tweets"
MEDIA_PATH = File.join ARCHIVE_PATH, "media"
DATA_PATH = File.join ARCHIVE_PATH, "data"

KNOWN_MEDIA_HOSTNAMES = YAML.load_file "media_hostnames.yaml"
KNOWN_DEAD_HOSTNAMES = YAML.load_file "dead_hostnames.yaml"
KNOWN_404_URLS = YAML.load_file "404_urls.yaml"

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
class Weird404Error < StandardError; end

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
    raise Weird404Error if KNOWN_404_URLS.include? "#{uri.host}#{uri.path}"

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
    puts " -- Connection refused"
  rescue SocketError
    puts " -- DNS failed to resolve"
  rescue OpenSSL::SSL::SSLError
    puts " -- SSL error (probably a self-signed certificate)"
  rescue HTTPClient::ConnectTimeoutError
    puts " -- Connection timed out"
  rescue HTTPClient::SendTimeoutError
    puts " -- Send timed out (problematic)"
  rescue HTTPClient::ReceiveTimeoutError
    puts " -- Receive timed out (problematic)"

  # Custom errors
  rescue TooManyRedirectsError
    puts " -- Too many redirects (#{urls.length})"
  rescue DeadHostnameError
    status = "xxx"
    puts " -- '#{uri.host}' is a known dead hostname"
  rescue Weird404Error
    status = "404"
    puts " (404) -- '#{uri.host}#{uri.path}' is a known 404 page"

  # Catch-all
  rescue
    puts " -- Mystery error"

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

namespace :archive do
  desc "Parse Twitter archive in #{TWEET_PATH.sub PWD, ""}"
  task :parse do
    all_tweets = []

    hashtags_shared = []
    hashtagged_tweets = []

    media_shared = {}
    media_by_hostname = {}
    media_url_count_total = 0

    urls_shared = []
    urls_by_hostname = {}
    urls_by_http_code = {}
    urls_expanded = {}

    Dir.chdir File.join(TWEET_PATH, "data/js/tweets")

    puts "", "Parsing tweet JSON", "=================="
    Dir.glob("*.js") do |p|
      print "#{p}"

      media_url_count = 0

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
          hashtags_shared.concat v["entities"]["hashtags"].map{|h| h["text"]}
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

        found_urls.delete_if do |u|
          uri = Addressable::URI.parse(u).normalize
          if KNOWN_MEDIA_HOSTNAMES.include? uri.host
            media_url = "BROKEN" # uri.to_s

            media_url_count += 1

            begin

              next if uri.path == "/" or uri.path.empty?

              case uri.host

              when "cl.ly"
                contents = HTTPClient.get(uri.to_s, {}, {"Accept" => "application/json"}).body
                media_url = JSON::parse(contents)["download_url"]

              when "twitpic.com"
                if uri.to_s =~ /\/(?<url_key>[^\/]+)$/
                  # media_url = "http://twitpic.com/show/full/#{$~[:url_key]}"
                  media_url = HTTPClient.get("http://twitpic.com/show/full/#{$~[:url_key]}").header["Location"][0]
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
                else
                  raise MediaURLError
                end
              else
                raise UnimplementedMediaURLError
              end

            rescue MediaURLError
              media_url = "ERROR"

            rescue UnimplementedMediaURLError
              media_url = "UNIMPLEMENTED"

            rescue
              media_url = "ERROR_OTHER"
            end

            media_by_hostname[uri.host] ||= {}
            media_by_hostname[uri.host]["#{uri.host}#{uri.path}"] = media_url

            true
          end
        end

        urls_shared.concat found_urls

        # media_shared.concat v["entities"]["media"]

        media_by_hostname["pic.twitter.com"] ||= {} unless v["entities"]["media"].empty?
        v["entities"]["media"].each do |m|
          media_url_count += 1
          media_shared[m["display_url"]] = m["media_url"]
          media_by_hostname["pic.twitter.com"][m["display_url"]] = m["media_url"]
        end

      end

      puts " -- #{tweets_by_month.length} tweets, #{media_url_count} media URLs"
      # puts ignored_tweets.map {|t| " - Ignored #{t}"[0..60]}.join("\n") unless ignored_tweets.empty?

      media_url_count_total += media_url_count

      all_tweets.concat tweets_by_month
    end

    puts
    puts "#{all_tweets.length} tweets in total"
    puts "#{media_url_count_total} media URLs in total"
    puts "#{hashtags_shared.length} hashtags in total"
    puts "#{urls_shared.length} URLs in total"

    time do
      # Build array of shared URLs
      urls_shared.each_with_index do |s, idx|
        url = "#{s}"
        url = "http://#{url}" unless url =~ /^https?:\/\//i

        puts "", "=== #{idx+1} of #{urls_shared.length} ==========="

        urls = expand_url(url)
        next if urls.empty?

        # urls.each do |u|
        #   all_urls_by_http_code[u[0]] ||= []
        #   all_urls_by_http_code[u[0]].push u[1]
        # end

        (urls_by_http_code[urls[0][0]] ||= []).push urls[0][1]

        # Using addressable to deal with IDNs
        u = Addressable::URI.parse(urls[0][1]).normalize
        hostname = u.host.to_s.downcase

        # Pretty dumb regex but whatever idgaf
        hostname = $~[:url] if hostname =~ /(?<url>[\w\-]+(?:\.\w{2,3}){1,2})$/

        (urls_by_hostname[hostname] ||= {}).merge!({urls.last[1] => urls})
        urls_expanded[urls.last[1]] = urls

        puts ">>> #{urls[0][1]}"
      end
    end

    # Sort by key
    urls_by_hostname = Hash[urls_by_hostname.sort]
    media_by_hostname = Hash[media_by_hostname.sort]

    {
      "urls.json" => urls_by_hostname,
      "hashtags.json" => hashtags_shared,
      "urls_expanded.json" => urls_expanded,
      "urls_by_http_code.json" => urls_by_http_code,
      "media.json" => media_shared,
      "media_by_hostname.json" => media_by_hostname
    }.each do |filename, data|
      File.open(File.join(DATA_PATH, filename), "w") do |f|
        f.write(JSON.pretty_generate data)
      end
    end

  end

  desc "Download shared media to #{MEDIA_PATH.sub PWD, ""}"
  task :download_media do
    Dir.chdir MEDIA_PATH

    media = JSON::parse IO.read(File.join(MEDIA_PATH, "media.json"))

    # puts "", "Shared URLs", urls_by_hostname.to_yaml
    # puts "", "Shared media", media_by_hostname.to_yaml
  end
end

