﻿# TODO maybe activate raise_on_failure optional FastImage param

# require "json"
# require "nethttputils"
require "imgur2array"
require "fastimage"

module URL2Dimensions
  class Error404 < RuntimeError
    def initialize url
      # Module.nesting[1].logger.error url
      super "URL2Dimensions: NotFound error for #{url}"
    end
  end
  class ErrorUnknown < RuntimeError
    def initialize url
      # Module.nesting[1].logger.error url
      super "URL2Dimensions: fastimage can't get dimensions for unknown url #{url}"
    end
  end

  def self.get_dimensions url
    fail "env var missing -- IMGUR_CLIENT_ID" unless ENV["IMGUR_CLIENT_ID"]
    fail "env var missing -- FLICKR_API_KEY" unless ENV["FLICKR_API_KEY"]
    fail "env var missing -- _500PX_CONSUMER_KEY" unless ENV["_500PX_CONSUMER_KEY"]

    return :skipped if [
      %r{^https://www\.youtube\.com/},
      %r{^http://gfycat\.com/},
      %r{^https?://(i\.)?imgur\.com/.+\.gifv$}, # TODO: o'rly?!
      %r{^https?://www\.reddit\.com/},
      %r{^http://vimeo\.com/},
    ].any?{ |r| r =~ url }

    begin
      URI url
    rescue URI::InvalidURIError
      return :skipped
    end
    # return :skipped if %w{ minus com } == .host.split(?.).last(2)

    fi = lambda do |url|
      _ = FastImage.size url, http_header: {"User-Agent" => "Mozilla"}
      _ ? [*_, url] : fail
    end
    [
      ->_{
        timeout = 1
        # _ = begin
          _ = FastImage.size url, http_header: {"User-Agent" => "Mozilla"}
        # rescue OpenSSL::SSL::SSLError => e
        #   puts "#{e} at #{__LINE__}"
        #   sleep timeout *= 2
        #   retry
        # end
        [*_, url] if _
      },
      ->_{ if %w{ imgur com } == URI(_).host.split(?.).last(2)
        dimensions = begin
          Imgur::imgur_to_array _
        rescue Imgur::Error => e
          raise Error404.new _ if e.to_s.start_with? "Imgur error: bad link pattern \""
          raise
        end
        raise Error404.new _ if !dimensions || dimensions.empty?    # TODO test case about .empty?
        if dimensions.size == 1
          dimensions.first.take(3).rotate(1)
        else
          [
            *dimensions.max_by{ |u, x, y, t| x * y }.take(3).rotate(1),
            *dimensions.map(&:first),
          ]
        end
      end },
      ->_{ if %r{^https://www\.flickr\.com/photos/[^/]+/(?<id>[^/]+)} =~ _ ||
              %r{^https://flic\.kr/p/(?<id>[^/]+)$} =~ _
        json = JSON.parse NetHTTPUtils.request_data "https://api.flickr.com/services/rest/", form: {
          method: "flickr.photos.getSizes",
          api_key: ENV["FLICKR_API_KEY"],
          photo_id: id,
          format: "json",
          nojsoncallback: 1,
        }
        raise Error404.new _ if json == {"stat"=>"fail", "code"=>1, "message"=>"Photo not found"}
        if json["stat"] != "ok"
          fail [json, _].inspect
        else
          json["sizes"]["size"].map do |_|
            x, y, u = _.values_at("width", "height", "source")
            [x.to_i, y.to_i, u]
          end.max_by{ |x, y, u| x * y }
        end
      end },
      ->_{ if %r{https?://[^.]+.wiki[mp]edia\.org/wiki(/[^/]+)*/(?<id>File:.+)} =~ _
        imageinfo = JSON.parse( NetHTTPUtils.request_data "https://commons.wikimedia.org/w/api.php", form: {
          format: "json",
          action: "query",
          prop: "imageinfo",
          iiprop: "url",
          titles: id,
        } )["query"]["pages"].values.first["imageinfo"]
        raise ErrorUnknown.new _ unless imageinfo
        fi[imageinfo.first["url"]]
      end },
      ->_{ if %r{^https://500px\.com/photo/(?<id>[^/]+)/[^/]+$} =~ _
        (JSON.parse NetHTTPUtils.request_data "https://api.500px.com/v1/photos/#{id}", form: {
          image_size: 2048,
          consumer_key: ENV["_500PX_CONSUMER_KEY"],
        } )["photo"].values_at("width", "height", "image_url")
      end },
      ->_{
        raise Error404.new _ if "404" == begin
          NetHTTPUtils.get_response _, header: {"User-Agent" => "Mozilla"}
        rescue SocketError, OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ETIMEDOUT => e
          raise Error404.new _
        end.code
      },
      ->_{ raise ErrorUnknown.new _ },
    ].lazy.map{ |_| _[url] }.find{ |_| _ }
  end
end


if $0 == __FILE__
  require "pp"
  STDOUT.sync = true
  puts "self testing..."

  require "minitest/mock"
  ANY_IMGUR_IMAGE_URL = "https://imgur.com/smth"
  begin
    fail (( Imgur.stub :imgur_to_array, ->*{ raise Imgur::Error.new "bad link pattern #{ANY_IMGUR_IMAGE_URL.inspect}" } do
      URL2Dimensions::get_dimensions ANY_IMGUR_IMAGE_URL
    end ))
  rescue URL2Dimensions::Error404
  end
  begin
    fail (( Imgur.stub :imgur_to_array, ->*{ nil } do
      URL2Dimensions::get_dimensions ANY_IMGUR_IMAGE_URL
    end ))
  rescue URL2Dimensions::Error404
  end
  begin
    fail (( NetHTTPUtils.stub :get_response, ->*{ raise SocketError.new } do
      URL2Dimensions::get_dimensions "http://example.com/"
    end ))
  rescue URL2Dimensions::Error404
  end
  begin
    fail (( NetHTTPUtils.stub :get_response, ->*{ raise OpenSSL::SSL::SSLError.new } do
      URL2Dimensions::get_dimensions "http://example.com/"
    end ))
  rescue URL2Dimensions::Error404
  end

  [
    ["http://www.aeronautica.difesa.it/organizzazione/REPARTI/divolo/PublishingImages/6%C2%B0%20Stormo/2013-decollo%20al%20tramonto%20REX%201280.jpg", [1280, 853, "http://www.aeronautica.difesa.it/organizzazione/REPARTI/divolo/PublishingImages/6%C2%B0%20Stormo/2013-decollo%20al%20tramonto%20REX%201280.jpg"]],
    ["http://minus.com/lkP3hgRJd9npi", URL2Dimensions::Error404],
    ["http://example.com", URL2Dimensions::ErrorUnknown],
    ["http://i.imgur.com/7xcxxkR.gifv", :skipped],
    ["http://imgur.com/HQHBBBD", [1024, 768, "https://i.imgur.com/HQHBBBD.jpg"]],
    ["http://imgur.com/a/AdJUK", [1456, 2592, "https://i.imgur.com/Yunpxnx.jpg",
                                              "https://i.imgur.com/Yunpxnx.jpg",
                                              "https://i.imgur.com/3afw2aF.jpg",
                                              "https://i.imgur.com/2epn2nT.jpg"]],
    # TODO maybe we should do smth else with video -- maybe raise?
    ["https://imgur.com/9yaMdJq", [720, 404, "https://i.imgur.com/9yaMdJq.mp4"]],
    ["http://imgur.com/gallery/dCQprEq/new", [5760, 3840, "https://i.imgur.com/dCQprEq.jpg"]],
    ["https://www.flickr.com/photos/tomas-/17220613278/", URL2Dimensions::Error404],
    ["https://www.flickr.com/photos/16936123@N07/18835195572", URL2Dimensions::Error404],
    ["https://www.flickr.com/photos/44133687@N00/17380073505/", [3000, 2000, "https://farm8.staticflickr.com/7757/17380073505_ed5178cc6a_o.jpg"]],                            # trailing slash
    ["https://www.flickr.com/photos/jacob_schmidt/18414267018/in/album-72157654235845651/", URL2Dimensions::Error404],                                                            # username in-album
    ["https://www.flickr.com/photos/tommygi/5291099420/in/dateposted-public/", [1600, 1062, "https://farm6.staticflickr.com/5249/5291099420_3bf8f43326_o.jpg"]],              # username in-public
    ["https://www.flickr.com/photos/132249412@N02/18593786659/in/album-72157654521569061/", URL2Dimensions::Error404],
    ["https://www.flickr.com/photos/130019700@N03/18848891351/in/dateposted-public/", [4621, 3081, "https://farm4.staticflickr.com/3796/18848891351_f751b35aeb_o.jpg"]],      # userid   in-public
    ["https://www.flickr.com/photos/frank3/3778768209/in/photolist-6KVb92-eCDTCr-ur8K-7qbL5z-c71afh-c6YvXW-7mHG2L-c71ak9-c71aTq-c71azf-c71aq5-ur8Q-6F6YkR-eCDZsD-eCEakg-eCE6DK-4ymYku-7ubEt-51rUuc-buujQE-ur8x-9fuNu7-6uVeiK-qrmcC6-ur8D-eCEbei-eCDY9P-eCEhCk-eCE5a2-eCH457-eCHrcq-eCEdZ4-eCH6Sd-c71b5o-c71auE-eCHa8m-eCDSbz-eCH1dC-eCEg3v-7JZ4rh-9KwxYL-6KV9yR-9tUSbU-p4UKp7-eCHfwS-6KVbAH-5FrdbP-eeQ39v-eeQ1UR-4jHAGN", [1024, 681, "https://farm3.staticflickr.com/2499/3778768209_280f82abab_b.jpg"]],
    ["https://www.flickr.com/photos/patricksloan/18230541413/sizes/l", [2048, 491, "https://farm6.staticflickr.com/5572/18230541413_fec4783d79_k.jpg"]],
    ["https://flic.kr/p/vPvCWJ", [2048, 1365, "https://farm1.staticflickr.com/507/19572004110_d44d1b4ead_k.jpg"]],
    ["https://en.wikipedia.org/wiki/Prostitution_by_country#/media/File:Prostitution_laws_of_the_world.PNG", [1427, 628, "https://upload.wikimedia.org/wikipedia/commons/e/e8/Prostitution_laws_of_the_world.PNG"]],
    ["https://en.wikipedia.org/wiki/Third_Party_System#/media/File:United_States_presidential_election_results,_1876-1892.svg", URL2Dimensions::ErrorUnknown],
    ["http://commons.wikimedia.org/wiki/File:Eduard_Bohlen_anagoria.jpg", [4367, 2928, "https://upload.wikimedia.org/wikipedia/commons/0/0d/Eduard_Bohlen_anagoria.jpg"]],
    ["https://500px.com/photo/112134597/milky-way-by-tom-hall", [4928, 2888, "https://drscdn.500px.org/photo/112134597/m%3D2048_k%3D1_a%3D1/v2?client_application_id=18857&webp=true&sig=c0d31cf9395d7849fbcce612ca9909225ec16fd293a7f460ea15d9e6a6c34257"]],
    ["https://i.redd.it/si758zk7r5xz.jpg", URL2Dimensions::Error404],
    ["http://www.cutehalloweencostumeideas.org/wp-content/uploads/2017/10/Niagara-Falls_04.jpg", URL2Dimensions::Error404],
  ].each do |input, expectation|
    puts "testing #{input}"
    if expectation.is_a? Class
      begin
        p URL2Dimensions::get_dimensions input
        fail
      rescue expectation
      end
    else
      abort "unable to inspect #{input}" unless result = URL2Dimensions::get_dimensions(input)
      abort "#{input} :: #{result.inspect} != #{expectation.inspect}" if result != expectation
    end
  end

  puts "OK #{__FILE__}"
  exit
end






__END__

  ["http://discobleach.com/wp-content/uploads/2015/06/spy-comic.png", []],
  ["http://spaceweathergallery.com/indiv_upload.php?upload_id=113462", []],
  ["http://livelymorgue.tumblr.com/post/121189724125/may-27-1956-in-an-eighth-floor-loft-of-an#notes", [0, 0]],
http://mobi900.deviantart.com/art/Sea-Sunrise-Wallpaper-545266270
http://mobi900.deviantart.com/art/Sunrise-Field-Wallpaper-545126742


 http://boxtail.deviantart.com/art/Celtic-Water-Orbs-548986856 from http://redd.it/3en92j
http://imgur.com/OXCVSj7&amp;k82U3Qj#0 from http://redd.it/3ee7j1

unable to size http://hubblesite.org/newscenter/archive/releases/2015/02/image/a/format/zoom/ from http://redd.it/2rhm8w
unable to size http://www.deviantart.com/art/Tree-swing-437944764 from http://redd.it/3fnia2

unable to size http://imgur.com/gallery/AsJ3N7x/new from http://redd.it/3fmzdg





found this to be already submitted
[4559, 2727] got from 3foerr: 'https://upload.wikimedia.org/wikipedia/commons/4/47/2009-09-19-helsinki-by-RalfR-062.jpg'
retry download 'https://www.reddit.com/r/LargeImages/search.json?q=url%3Ahttps%3A%2F%2Fupload.wikimedia.org%2Fwikipedia%2Fcommons%2F4%2F47%2F2009-09-19-helsinki-by-RalfR-062.jpg&restrict_sr=on' in 1 seconds because of 503 Service Unavailable

unable to size http://www.flickr.com/photos/dmacs_photos/12027867364/ from http://redd.it/1vqlgk
unable to size https://dl.dropboxusercontent.com/u/52357713/16k.png from http://redd.it/1vomwy

unable to size http://www.flickr.com/photos/dmacs_photos/12027867364/ from http://redd.it/1vqlgk
unable to size https://dl.dropboxusercontent.com/u/52357713/16k.png from http://redd.it/1vomwy

unable http://imgur.com/r/wallpaper/rZ37ZYN from http://redd.it/3knh3g

unable http://www.flickr.com/photos/dmacs_photos/12027867364/ from http://redd.it/1vqlgk


unable http://imgur.com/gallery/jm0OKQM from http://redd.it/3ukg4t
unable http://imgur.com/gallery/oZXfZ from http://redd.it/3ulz2i


