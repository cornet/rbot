#-- vim:sw=2:et
#++
#
# :title: lastfm plugin for rbot
#
# Author:: Jeremy Voorhis
# Author:: Giuseppe "Oblomov" Bilotta <giuseppe.bilotta@gmail.com>
# Author:: Casey Link <unnamedrambler@gmail.com>
#
# Copyright:: (C) 2005 Jeremy Voorhis
# Copyright:: (C) 2007 Giuseppe Bilotta
# Copyright:: (C) 2008 Casey Link
#
# License:: GPL v2

require 'rexml/document'
require 'cgi'

class ::LastFmEvent
  def initialize(hash)
    @url = hash[:url]
    @date = hash[:date]
    @location = hash[:location]
    @description = hash[:description]
    @attendance = hash[:attendance]

    @artists = hash[:artists]

    if @artists.length > 10 #more than 10 artists and it floods
      diff = @artists.length - 10
      @artist_string = Bold + @artists[0..10].join(', ') + Bold
      @artist_string << _(" and %{n} more...") % {:n => diff}
    else
      @artist_string = Bold + @artists.join(', ') + Bold
    end
  end

  def compact_display
   if @attendance
     return "%s %s @ %s (%s attending) %s" % [@date.strftime("%a %b, %d %Y"), @artist_string, @location, @attendance, @url]
   end
   return "%s %s @ %s %s" % [@date.strftime("%a %b, %d %Y"), @artist_string, @location, @url]
  end
  alias :to_s :compact_display

end

class LastFmPlugin < Plugin
  include REXML
  Config.register Config::IntegerValue.new('lastfm.max_events',
    :default => 25, :validate => Proc.new{|v| v > 1},
    :desc => "Maximum number of events to display.")
  Config.register Config::IntegerValue.new('lastfm.default_events',
    :default => 3, :validate => Proc.new{|v| v > 1},
    :desc => "Default number of events to display.")

  APIKEY = "b25b959554ed76058ac220b7b2e0a026"
  APIURL = "http://ws.audioscrobbler.com/2.0/?api_key=#{APIKEY}&"

  def initialize
    super
    class << @registry
      def store(val)
        val
      end
      def restore(val)
        val
      end
    end
  end

  def help(plugin, topic="")
    case (topic.intern rescue nil)
    when :event, :events
      _("lastfm [<num>] events in <location> => show information on events in or near <location>. lastfm [<num>] events by <artist/group> => show information on events by <artist/group>. The number of events <num> that can be displayed is optional, defaults to %{d} and cannot be higher than %{m}") % {:d => @bot.config['lastfm.default_events'], :m => @bot.config['lastfm.max_events']}
    when :artist
      _("lastfm artist <name> => show information on artist <name> from last.fm")
    when :album
      _("lastfm album <name> => show information on album <name> from last.fm [not implemented yet]")
    when :track
      _("lastfm track <name> => search tracks matching <name> on last.fm")
    when :now, :np
      _("lastfm now [<user>] => show the now playing track from last.fm.  np [<user>] does the same.")
    when :set
      _("lastfm set user <user> => associate your current irc nick with a last.fm user. lastfm set verb <present>, <past> => set your preferred now playing/just played verbs. default \"is listening to\" and \"listened to\".")
    when :who
      _("lastfm who [<nick>] => show who <nick> is on last.fm. if <nick> is empty, show who you are on lastfm.")
    when :compare
      _("lastfm compare [<nick1>] <nick2> => show musical taste compatibility between nick1 (or user if omitted) and nick2")
    else
      _("lastfm [<user>] => show your or <user>'s now playing track on lastfm. np [<user>] => same as 'lastfm'. other topics: events, artist, album, track, now, set, who, compare")
    end
  end

  def find_events(m, params)
    num = params[:num] || @bot.config['lastfm.default_events']
    num = num.to_i.clip(1, @bot.config['lastfm.max_events'])

    location = artist = nil
    location = params[:location].to_s if params[:location]
    artist = params[:who].to_s if params[:who]

    uri = nil
    if artist == nil
      uri = "#{APIURL}method=geo.getevents&location=#{CGI.escape location}"
    else
      uri = "#{APIURL}method=artist.getevents&artist=#{CGI.escape artist}"
    end
    xml = @bot.httputil.get_response(uri)

    doc = Document.new xml.body
    if xml.class == Net::HTTPInternalServerError
      if doc.root and doc.root.attributes["status"] == "failed"
        m.reply doc.root.elements["error"].text
      else
        m.reply _("could not retrieve events")
      end
    end
    disp_events = Array.new
    events = Array.new
    doc.root.elements.each("events/event"){ |e|
      h = {}
      h[:title] = e.elements["title"].text
      venue = e.elements["venue"].elements["name"].text
      city = e.elements["venue"].elements["location"].elements["city"].text
      country =  e.elements["venue"].elements["location"].elements["country"].text
      h[:location] = Underline + venue + Underline + " #{Bold + city + Bold}, #{country}"
      date = e.elements["startDate"].text.split
      h[:date] = Time.utc(date[3].to_i, date[2], date[1].to_i)
      h[:desc] = e.elements["description"].text
      h[:url] = e.elements["url"].text
      e.detect {|node|
        if node.kind_of? Element and node.attributes["name"] == "attendance" then
          h[:attendance] = node.text
        end
      }
      artists = Array.new
      e.elements.each("artists/artist"){ |a|
        artists << a.text
      }
      h[:artists] = artists
      events << LastFmEvent.new(h)
    }
    events[0...num].each { |event|
      disp_events << event.to_s
    }
    m.reply disp_events.join(' | '), :split_at => /\s+\|\s+/

  end

  def tasteometer(m, params)
    opts = { :cache => false }
    user1 = resolve_username(m, params[:user1])
    user2 = resolve_username(m, params[:user2])
    xml = @bot.httputil.get_response("#{APIURL}method=tasteometer.compare&type1=user&type2=user&value1=#{CGI.escape user1}&value2=#{CGI.escape user2}", opts)
    doc = Document.new xml.body
    unless doc
      m.reply _("last.fm parsing failed")
      return
    end
    if xml.class == Net::HTTPBadRequest
      if doc.root.elements["error"].attributes["code"] == "7" then
        error = doc.root.elements["error"].text
        error.match(/Invalid username: \[(.*)\]/);
        baduser = $1

        m.reply _("%{u} doesn't exist on last.fm") % {:u => baduser}
        return
      else
        m.reply _("error: %{e}") % {:e => doc.root.element["error"].text}
        return
      end
    end
    now = artist = track = albumtxt = date = nil
    score = doc.root.elements["comparison/result/score"].text.to_f
    rating = nil
    case
      when score >= 0.9
        rating = _("Super")
      when score >= 0.7
        rating = _("Very High")
      when score >= 0.5
        rating = _("High")
      when score >= 0.3
        rating = _("Medium")
      when score >= 0.1
        rating = _("Low")
      else
        rating = _("Very Low")
    end
    m.reply _("%{a}'s and %{b}'s musical compatibility rating is: %{r}") % {:a => user1, :b => user2, :r => rating}
  end

  def now_playing(m, params)
    opts = { :cache => false }
    user = resolve_username(m, params[:who])
    xml = @bot.httputil.get_response("#{APIURL}method=user.getrecenttracks&user=#{CGI.escape user}", opts)
    doc = Document.new xml.body
    unless doc
      m.reply _("last.fm parsing failed")
      return
    end
    if xml.class == Net::HTTPBadRequest
      if doc.root.elements["error"].text == "Invalid user name supplied" then
        m.reply _("%{user} doesn't exist on last.fm, perhaps they need to: lastfm 2 <username>") % {
          :user => user
        }
        return
      else
        m.reply _("error: %{e}") % {:e => doc.root.element["error"].text}
        return
      end
    end
    now = artist = track = albumtxt = date = nil
    unless doc.root.elements[1].has_elements?
     m.reply _("%{u} hasn't played anything recently") % {:u => user}
     return
    end
    first = doc.root.elements[1].elements[1]
    now = first.attributes["nowplaying"]
    artist = first.elements["artist"].text
    track = first.elements["name"].text
    albumtxt = first.elements["album"].text
    album = ""
    if albumtxt
      year = get_album(artist, albumtxt)[2]
      album = "[#{albumtxt}, #{year}] " if year
    end
    past = nil
    date = XPath.first(first, "//date")
    if date != nil
      time = date.attributes["uts"]
      past = Time.at(time.to_i)
    end
    if now == "true"
       verb = _("is listening to")
       if @registry.has_key? "#{m.sourcenick}_verb_present"
         verb = @registry["#{m.sourcenick}_verb_present"]
       end
       m.reply _("%{u} %{v} \"%{t}\" by %{a} %{b}") % {:u => user, :v => verb, :t => track, :a => artist, :b => album}
    else
      verb = _("listened to")
       if @registry.has_key? "#{m.sourcenick}_verb_past"
         verb = @registry["#{m.sourcenick}_verb_past"]
       end
      ago = Utils.timeago(past)
      m.reply _("%{u} %{v} \"%{t}\" by %{a} %{b}%{p}") % {:u => user, :v => verb, :t => track, :a => artist, :b => album, :p => ago}
    end
  end

  def find_artist(m, params)
    xml = @bot.httputil.get("#{APIURL}method=artist.getinfo&artist=#{CGI.escape params[:artist].to_s}")
    unless xml
      m.reply _("I had problems getting info for %{a}") % {:a => params[:artist]}
      return
    end
    doc = Document.new xml
    unless doc
      m.reply _("last.fm parsing failed")
      return
    end
    first = doc.root.elements["artist"]
    artist = first.elements["name"].text
    playcount = first.elements["stats"].elements["playcount"].text
    listeners = first.elements["stats"].elements["listeners"].text
    summary = first.elements["bio"].elements["summary"].text
    m.reply _("%{b}%{a}%{b} has been played %{c} times and is being listened to by %{l} people") % {:b => Bold, :a => artist, :c => playcount, :l => listeners}
    m.reply summary.ircify_html
  end

  def find_track(m, params)
    track = params[:track].to_s
    xml = @bot.httputil.get("#{APIURL}method=track.search&track=#{CGI.escape track}")
    unless xml
      m.reply _("I had problems getting info for %{a}") % {:a => track}
      return
    end
    debug xml
    doc = Document.new xml
    unless doc
      m.reply _("last.fm parsing failed")
      return
    end
    debug doc.root
    results = doc.root.elements["results/opensearch:totalResults"].text.to_i rescue 0
    if results > 0
      begin
        hits = []
        doc.root.each_element("results/trackmatches/track") do |track|
          hits << _("%{bold}%{t}%{bold} by %{bold}%{a}%{bold} (%{n} listeners)") % {
            :t => track.elements["name"].text,
            :a => track.elements["artist"].text,
            :n => track.elements["listeners"].text,
            :bold => Bold
          }
        end
        m.reply hits.join(' -- '), :split_at => ' -- '
      rescue
        error $!
        m.reply _("last.fm parsing failed")
      end
    else
      m.reply _("track %{a} not found") % {:a => track}
    end
  end

  def get_album(artist, album)
    xml = @bot.httputil.get("#{APIURL}method=album.getinfo&artist=#{CGI.escape artist}&album=#{CGI.escape album}")
    unless xml
      return [_("I had problems getting album info")]
    end
    doc = Document.new xml
    unless doc
      return [_("last.fm parsing failed")]
    end
    album = date = playcount = artist = date = year = nil
    first = doc.root.elements["album"]
    artist = first.elements["artist"].text
    playcount = first.elements["playcount"].text
    album = first.elements["name"].text
    date = first.elements["releasedate"].text
    unless date.strip.length < 2
      year = date.strip.split[2].chop
    end
    result = [artist, album, year, playcount]
    return result
  end

  def find_album(m, params)
    album = get_album(params[:artist].to_s, params[:album].to_s)
    if album.length == 1
      m.reply _("I couldn't locate: \"%{a}\" by %{r}") % {:a => params[:album], :r => params[:artist]}
      return
    end
    year = "(#{album[2]}) " unless album[2] == nil
    m.reply _("the album \"%{a}\" by %{r} %{y}has been played %{c} times") % {:a => album[1], :r => album[0], :y => year, :c => album[3]}
  end

  def set_user(m, params)
    user = params[:who].to_s
    nick = m.sourcenick
    @registry[ nick ] = user
    m.reply _("okay, I'll remember that %{n} is %{u} on last.fm") % {:n => nick, :u => user}
  end

  def set_verb(m, params)
    past = params[:past].to_s
    present = params[:present].to_s
    key = "#{m.sourcenick}_verb_"
    @registry[ "#{key}past" ] = past
    @registry[ "#{key}present" ] = present
    m.reply _("okay, I'll remember that %{n} prefers \"%{r}\" and \"%{p}\"") % {:n => m.sourcenick, :p => past, :r => present}
  end

  def get_user(m, params)
    nick = ""
    if params[:who]
      nick = params[:who].to_s
    else
      nick = m.sourcenick
    end
    if @registry.has_key? nick
      user = @registry[ nick ]
      m.reply _("%{nick} is %{user} on last.fm") % {
        :nick => nick,
        :user => user
      }
    else
      m.reply _("sorry, I don't know who %{n} is on last.fm, perhaps they need to: lastfm set user <username>") % {:n => nick}
    end
  end

  # TODO this user data retrieval should be upgraded to API 2.0 but it would need separate parsing
  # for each dataset, or almost
  def lastfm(m, params)
    action = params[:action].intern
    action = :neighbours if action == :neighbors
    action = :recenttracks if action == :recentracks
    action = :topalbums if action == :topalbum
    action = :topartists if action == :topartist
    action = :toptags if action == :toptag
    user = resolve_username(m, params[:user])
    begin
      data = @bot.httputil.get("http://ws.audioscrobbler.com/1.0/user/#{user}/#{action}.txt")
      m.reply "#{action} for #{user}:"
      m.reply data.to_a[0..3].map{|l| l.split(',',2)[-1].chomp}.join(", ")
    rescue
      m.reply "could not find #{action} for #{user} (is #{user} a user?). perhaps you need to: lastfm set <username>"
    end
  end

  def resolve_username(m, name)
    name = m.sourcenick if name.nil?
    @registry[name] or name
  end
end

plugin = LastFmPlugin.new
plugin.map 'lastfm [:num] event[s] in *location', :action => :find_events, :requirements => { :num => /\d+/ }, :thread => true
plugin.map 'lastfm [:num] event[s] by *who', :action => :find_events, :requirements => { :num => /\d+/ }, :thread => true
plugin.map 'lastfm [:num] event[s] [for] *who', :action => :find_events, :requirements => { :num => /\d+/ }, :thread => true
plugin.map 'lastfm [now] [:who]', :action => :now_playing, :thread => true
plugin.map 'np :who', :action => :now_playing, :thread => true
plugin.map 'lastfm artist *artist', :action => :find_artist, :thread => true
plugin.map 'lastfm album *album [by *artist]', :action => :find_album
plugin.map 'lastfm track *track', :action => :find_track, :thread => true
plugin.map 'lastfm set user[name] :who', :action => :set_user, :thread => true
plugin.map 'lastfm set verb *present, *past', :action => :set_verb, :thread => true
plugin.map 'lastfm who [:who]', :action => :get_user, :thread => true
plugin.map 'lastfm compare to :user2', :action => :tasteometer, :thread => true
plugin.map 'lastfm compare [:user1] [to] :user2', :action => :tasteometer, :thread => true
plugin.map 'np', :action => :now_playing, :thread => true
plugin.map "lastfm [user] :action [:user]", :thread => true,
  :requirements => { :action =>
    /^(?:events|friends|neighbou?rs|playlists|recent?tracks|top(?:album|artist|tag)s?|weekly(?:album|artist|track)chart|weeklychartlist)$/
}
