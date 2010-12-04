require 'rubygems'
require 'eventmachine'
require 'dnsruby'
require 'geoip'

module DNSServer

  RAD_PER_DEG = 0.017453293

  @@GEOIP = nil
  @@ZONEMAP = {}

  def self.init()
    @@GEOIP = GeoIP.new('GeoLiteCity.dat')
    Dir.entries("zones").each do |file|
      if file =~ /^(.*).zone$/
        zonefile = File.read("zones/#{file}")
        @@ZONEMAP[$1] = zonefile.scan(/^(([\w@\-\.]+)\s+(([0-9]+)\s+|)([A-Za-z]+)\s+([A-Za-z]+)\s+(([0-9]+)\s+|)([\w@\-\.]+))/)
      end
    end
  end

  def receive_data(data)
    msg = Dnsruby::Message.decode(data)
    client_ip = get_peername[2,6].unpack("nC4")[1,4].join(".")
    geoip_data = @@GEOIP.country(client_ip)

    domain = nil
    zone_records = []

    msg.question.each do |question|
      query = question.qname.to_s

      @@ZONEMAP.each { |key,value| domain = key if query =~ /#{key}$/ }
      zone_records = @@ZONEMAP[domain] unless domain.nil?

      begin
        puts "Q: #{query}"
        query.gsub!(/#{domain}/,"")
        query = query == "" ? "@" : query.chomp(".")
        match_distance = nil
        match_record = nil
        match_address = nil

        zone_records.each do |rr|
          if rr[1] == query.to_s && rr[4] == question.qclass.to_s && rr[5] == question.qtype.to_s
            rr_geo = @@GEOIP.country(rr.last)
            distance = rr_geo.nil? ? 0 : haversine_distance(geoip_data[9],geoip_data[10],rr_geo[9],rr_geo[10])["mi"].to_i
            if match_record.nil? || match_distance.nil? || match_distance > distance
              match_distance = distance
              match_record = rr[0]
              match_address = rr.last
            end
          elsif rr[1] == query && rr[5] == "CNAME" && question.qtype == "A"
            msg.add_answer(Dnsruby::RR.create(rr[0].gsub(/@/,domain)))
            raise DnsRedirect, rr.last
          end
        end
        unless match_record.nil?
          msg.add_answer(Dnsruby::RR.create(match_record.gsub(/@/,domain)))
          puts "#{question.qclass} #{question.qtype} #{question.qname.to_s} Resolved to #{match_address} -- Distance: #{match_distance}"
        end
      rescue DnsRedirect => redirect
        query = redirect.message
        query += ".#{domain}" if query[-1,1] != "."
        retry
      end
    end

    msg.header.qr = true
    msg.header.rcode = Dnsruby::RCode.NoError
    send_data msg.encode
  end

  protected
  def haversine_distance( lat1, lon1, lat2, lon2 )
    distances = Hash.new
    dlon = lon2 - lon1
    dlat = lat2 - lat1

    dlon_rad = dlon * RAD_PER_DEG
    dlat_rad = dlat * RAD_PER_DEG

    lat1_rad = lat1 * RAD_PER_DEG
    lon1_rad = lon1 * RAD_PER_DEG

    lat2_rad = lat2 * RAD_PER_DEG
    lon2_rad = lon2 * RAD_PER_DEG

    a = Math.sin(dlat_rad/2)**2 + Math.cos(lat1_rad) * Math.cos(lat2_rad) * Math.sin(dlon_rad/2)**2
    c = 2 * Math.asin( Math.sqrt(a))

    dMi = 3956 * c          # delta between the two points in miles
    dKm = 6371 * c             # delta in kilometers
    dFeet = 20887680 * c         # delta in feet
    dMeters = 6371000 * c     # delta in meters

    distances["mi"] = dMi
    distances["km"] = dKm
    distances["ft"] = dFeet
    distances["m"] = dMeters
    distances
  end

  class DnsRedirect < Exception
  end

end

DNSServer.init

EM.run do
  EM.start_server "0.0.0.0", 53, DNSServer
  EM.open_datagram_socket '0.0.0.0', 53, DNSServer
end
