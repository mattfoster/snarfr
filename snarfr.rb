#! /usr/local/bin/ruby
# = snarfr.rb 
# Download flickr images, saving metadata and geotags as EXIF tags. 
# 
# == Arguments 
# None! Just follow the instructions to get going.
#
# == Author
# Matt Foster <matt.p.foster@gmail.com>

require 'rubygems'
require 'cgi'
require 'flickraw'
require 'open-uri'
require 'ostruct'
require 'progressbar'
require 'mini_exiftool'
require 'digest/md5'
require 'facets/ostruct'
require 'zlib'

# Save process into file. This prevents files being downloaded unnecessarily.
def dump_progress(done, dumpfile)
  dump = Marshal.dump(done)
  open(dumpfile, 'wb') do |file|
    gzip = Zlib::GzipWriter.new(file)
    gzip.write(dump)
    gzip.close
  end
end

# Read in progress file. Contains the names of images already snarfed.
def read_progress(dumpfile)
  dump = []
  if File.exist?(dumpfile)
    dump = Zlib::GzipReader.open(dumpfile) do |gzip|
      dump = Marshal.load(gzip.read)
    end
  end
  dump
end

# Maps from the <tt>info</tt> struct to EXIF fields.
def map_info_to_exif
  map = OpenStruct.new
  map.title = 'Title'
  map.description = 'Caption-Abstract'
  map.tags = 'Subject'
  map.latitude = 'GPSLatitude'
  map.longitude = 'GPSLongitude'
  map.location = 'Location'
  map.country = 'Country'
  map.url = 'UserComment'

  map
end

# Write info to the image 'filename' using MiniExiftool
# Mapping is set up using <tt>map_info_to_exif</tt>
def write_info_tags(filename, info, map)
  photo = MiniExiftool.new(filename)
  tags = MiniExiftool.writable_tags

  info.to_h.each do |key, val|
    tag = map[key]
    if tags.find {|x| x == tag} and tag != nil
      photo[tag] = val
    end
  end

  state = photo.save
end

# Load various bits of metadata into the <tt>info</tt> structure.
def load_info_struct(photo, location = true)
  info = OpenStruct.new
  sizes = flickr.photos.getSizes(:photo_id => photo.id)
  url = eval("\"#{sizes[-1].source}\"").gsub(' ', '')
  info.url = CGI.unescape("#{url}")
  inf = flickr.photos.getInfo(:photo_id => photo.id)

  %w{title description tags}.each do |key|
    info.send("#{key}=", fetch_and_unescape(inf, key))
  end

  if location == true
    geo = flickr.photos.geo.getLocation(:photo_id => photo.id).location

    %w{latitude, longitude, country, locality, region}.each do |key|
      info.send("#{key}=", fetch_and_unescape(geo, key))
    end

    info.location = [info.locality, info.region, info.country].join(', ')
  end

  info
end

# Send <tt>meth</tt> to <tt>obj</tt> and unescape the result.  
def fetch_and_unescape(obj, meth)
  CGI.unescape(call_if_defined(obj, meth).to_a.join(' '))
end

# Send <tt>obj</tt> the method <tt>meth</tt>
def call_if_defined(obj, meth)
  if obj.respond_to?(meth)
    v = obj.send(meth)
  else
    v = nil
  end
  v
end

# Download a file, and display a progress bar.
def download_with_progbar(uri, filename, disp = '')
  pbar = nil
  file = File.new(filename, 'w')
  begin 
    open(uri,
         :content_length_proc => lambda {|t|
      if t && 0 < t
        pbar = ProgressBar.new(disp, t)
        pbar.file_transfer_mode
      end
    },
      :progress_proc => lambda {|s|
      pbar.set s if pbar
    }) do |f|
      file.write(f.read)
    end
  rescue
    puts 'Error downloading file ' + $!
  end
end

if __FILE__ == $0

  # This is for debugging.
  only_auth = false

  # Application setings:
  APP_KEY = 'b78e61ba5fe4d2bed4e28826d7cb13ef'
  SECRET  = '99c89c3a598e2bf3'
  token_cache_file = File.expand_path('~/.snarfr')

  # Where to save the outputs:
  dir = ARGV.shift || 'output'
  dir = File.expand_path(dir)

  unless File.exist?(dir)
    Dir.mkdir(dir)
  end

  FlickRaw.api_key = APP_KEY
  FlickRaw.shared_secret = SECRET

  # Check if we've got a token in a file, if not, authorise, and get one.
  if File.exist?(token_cache_file) 
    token = File.read(token_cache_file).chomp
  else
    frob = flickr.auth.getFrob
    auth_url = FlickRaw.auth_url :frob => frob, :perms => 'read'
    puts "snarfr.rb needs read access to your photostream. Please:"
    puts " * Open this url: #{auth_url}"
    puts " * Then press enter."
    puts "Thanks!"
    STDIN.getc
    begin
      token = flickr.auth.getToken(:frob => frob).token
    rescue
      puts "There was a problem getting the authentication token."
      puts "The problem was " + $!
      exit
    end
   
    File.open(token_cache_file, 'w') do |f|
      f.write(token)
      f.close
    end
  end
 
  # Try and login
  begin
    flickr.auth.checkToken(:auth_token => token)
    login = flickr.test.login
    puts "You're logged in as #{login.username}"
  rescue FlickRaw::FailedResponse => e
    puts "Sorry: authentication failed: #{e.msg}"
    exit
  end

  if only_auth == true
    exit
  end

  # MD5 Hash the auth token to create a unique filename for the dumpfile
  # (for each user)
  hash = Digest::MD5.hexdigest(open(token_cache_file).readlines.join).hex
  # Save a list of what's been downloaded:
  dumpfile = File.expand_path("~/.snarfr_dump_#{hash}")

  info = []

  # Geotagged photos
  geotagged = flickr.photos.getWithGeoData
  geotagged.each do |photo|
    perms = flickr.photos.getPerms(:photo_id => photo.id)
    if perms.ispublic == 1
      info.push(load_info_struct(photo))
    end
  end

  # Non-geotagged photos
  ungeotagged = flickr.photos.getWithoutGeoData
  ungeotagged.each do |photo|
    perms = flickr.photos.getPerms(:photo_id => photo.id)
    if perms.ispublic == 1
      info.push(load_info_struct(photo, false))
    end
  end

  # Info to Exif mapping 
  map = map_info_to_exif

  # Load progress from previous run. If there was one.
  done = read_progress(dumpfile)

  info.each_with_index do |image, ind|
    fileext = File.extname(image.url)
    name = File.join(dir, "#{image.title}#{fileext}")
    unless File.exist?("#{image.title}.jpg") or 
      done.find {|x| x == image.title }
      download_with_progbar(image.url, name, "#{ind+1}/#{info.length}")
      write_info_tags(name, image, map)
      done.push(image.title)
    end
  end

  # Write what we've downloaded, and exit.
  dump_progress(done, dumpfile)

 # FIXME: this breaks if the users is without growl.
 # Use growl to notify the user of completion.
  if require 'ruby-growl'
    growl = Growl.new "127.0.0.1", "ruby-growl", ["ruby-growl Notification"], 
    nil, 'pass'
    growl.notify "ruby-growl Notification", "Snarfr operation complete", 
  "Downloaded #{info.length} images."
  end

end
