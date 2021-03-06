# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2021 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>.

require("./bass.rb")

def cryptmessage(msg)
  buf = "\0" * (msg.bytesize + 18)
  begin
    $cryptmessage.call(msg, buf, buf.bytesize)
    return buf
  rescue Exception
    return ""
  end
end

def unicode(str)
  return nil if str == nil
  buf = "\0" * $multibytetowidechar.call(65001, 0, str, str.bytesize, nil, 0) * 2
  $multibytetowidechar.call(65001, 0, str, str.bytesize, buf, buf.bytesize / 2)
  return buf << "\0"
end

def deunicode(str)
  return "" if str == nil
  str << "\0\0"
  buf = "\0" * $widechartomultibyte.call(65001, 0, str, -1, nil, 0, 0, nil)
  $widechartomultibyte.call(65001, 0, str, -1, buf, buf.bytesize, nil, nil)
  return buf[0..buf.index("\0") - 1]
end

def readini(file, group, key, default = "")
  r = "\0" * 16384
  sz = $getprivateprofilestring.call(unicode(group), unicode(key), unicode(default), r, r.bytesize, unicode(file))
  return deunicode(r[0..(sz * 2)]).delete("\0")
end

def readconfig(group, key, val = "")
  r = readini($eltendata + "\\elten.ini", group, key, val.to_s)
  return r.to_i if val.is_a?(Integer)
  return r
end

def speak(text, method = 0)
  text = text.to_s
  text = text.gsub("\004LINE\004") { "\r\n" }
  $speech_lasttext = text
  if $voice == "NVDA"
    $saystring.call(unicode(text), method)
  else
    ssml = "<pitch absmiddle=\"#{((($sapipitch || 50) / 5.0) - 10.0).to_i}\"/>"
    ssml += text.gsub("<", "&lt;").gsub(">", "&gt;")
    $sapispeakssml.call(unicode(ssml))
  end
  $speech_lasttime = Time.now.to_f
  return text
end

alias speech speak

def speech_stop
  (($voice != "NVDA") ? $sapistopspeech : $stopspeech).call
end

def speech_actived
  ($voice == "NVDA") ? false : (($sapiisspeaking.call == 1) ? true : false)
end

def speech_wait
  sleep 0.01 while speech_actived
end

def run(file, hide = false)
  env = 0
  env = "Windows".split(File::PATH_SEPARATOR) << nil
  env = env.pack("p*").unpack("L").first
  startinfo = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  startinfo = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0] if hide
  startinfo = startinfo.pack("LLLLLLLLLLLLSSLLLL")
  procinfo = [0, 0, 0, 0].pack("LLLL")
  pr = $createprocess.call(0, (file), 0, 0, 0, 0, 0, 0, startinfo, procinfo)
  procinfo[0, 4].unpack("L").first # pid
  return procinfo.unpack("llll")[0]
end

def getdirectory(type)
  dr = "\0" * 520
  $shgetfolderpath.call(0, type, 0, 0, dr)
  fdr = deunicode(dr)
  return fdr[0..fdr.index("\0") || -1]
end

DRAFT = "h2".freeze

def init
  $sockthread.exit if $sockthread != nil
  $sock = TCPSocket.new("srvapi.elten.link", 443)
  ctx = OpenSSL::SSL::SSLContext.new
  ctx.alpn_protocols = [DRAFT]
  $ssl = OpenSSL::SSL::SSLSocket.new($sock, ctx)
  $ssl.sync_close = true
  $ssl.hostname = "srvapi.elten.link"
  $ssl.connect
  $http = HTTP2::Client.new
  $httpqueue = []
  $ssl_mutex = Mutex.new
  $http.on(:frame) { |bytes|
    $httpqueue.push(bytes)
    $ssl_mutex.synchronize {
      while $httpqueue.size > 0
        bytes = $httpqueue[0]
        $httpqueue.delete_at(0)
        $ssl.print bytes
        $ssl.flush
      end
    }
  }
  $sockthread = Thread.new {
    while !$ssl.closed? && !$ssl.eof?
      data = $ssl.read_nonblock(1024)
      $http << data
    end
  }
  $http.on(:error) { |error| init if error.is_a?(Errno::ECONNRESET) or error.is_a?(SocketError) }
rescue Exception
end

class ERUploadProgress
  attr_reader :uploaded, :total, :percent

  def initialize(uploaded, total)
    @uploaded, @total = uploaded, total
    @percent = (uploaded.to_f / total.to_f * 100.0).floor
  end
end

class ERDownloadProgress
  attr_reader :downloaded, :total, :percent

  def initialize(downloaded, total)
    @downloaded, @total = downloaded, total
    @percent = (downloaded.to_f / total.to_f * 100.0).floor
  end
end

def downloadfile(source, destination, data = nil, &b)
  t = Thread.new {
    begin
      uri = URI.parse(source)
      sock = TCPSocket.new(uri.host, 443)
      ssl = OpenSSL::SSL::SSLSocket.new(sock, OpenSSL::SSL::SSLContext.new)
      ssl.connect
      headers = {}
      headers["User-Agent"] = "Elten #{$version} agent"
      headers["Connection"] = "close"
      headers["Accept-Encoding"] = "identity, chunked, *;q=0"
      hd = "GET " + uri.request_uri + " HTTP/1.1"
      hd += "\r\nHost: #{uri.host}"
      for k in headers.keys
        hd += "\r\n" + k + ": " + headers[k]
      end
      hd += "\r\n\r\n"
      ssl.write(hd)
      hd = ""
      l = ""
      while l != "\r\n"
        hd += (l = ssl.readline)
      end
      lines = hd.split("\r\n")
      code = 0
      ph = lines[0].split(" ")
      if ph[0].upcase != "HTTP/1.1"
        b.call(:error, data) if b != nil
      else
        headers = {}
        for l in lines[1..-1]
          nd = l.index(": ")
          headers[l[0...nd]] = l[nd + 2..-1]
        end
        headers["Transfer-Encoding"] ||= "identity"
        if headers["Location"] != nil
          downloadfile(headers["Location"], destination, data, &b)
          Thread::current.exit
        end
        status = ph[1].to_i
        if status < 200 || status >= 300
          b.call(:error, data) if b != nil
        else
          fp = File.open(destination, "wb")
          tim = Time.now.to_i
          total = (headers["Content-Length"] || 0).to_i
          downloaded = 0
          case headers["Transfer-Encoding"]
          when "identity"
            while !ssl.eof?
              dwn = ssl.read(16384)
              fp.write(dwn)
              downloaded += dwn.bytesize
              if Time.now.to_f - tim > 5 && total > 0
                tim = Time.now.to_f
                b.call(ERDownloadProgress.new(downloaded, total), data) if b != nil
              end
            end
            b.call(downloaded, data) if b != nil
          when "chunked"
            body = ""
            while !ssl.eof?
              cnt = ssl.readline.to_i(16)
              break if cnt == 0
              fp.write(ssl.read(cnt))
              downloaded += cnt
              ssl.read(2)
            end
            b.call(downloaded, data) if b != nil
          else
            b.call(:error, data)
          end
          fp.close
        end
      end
    rescue Exception
      log(2, "downloadfile worker error: " + $!.to_s + " " + $@.to_s)
    end
  }
end

def perequest(mod, param, post = nil, headers = {}, data = nil, ign = false, &b)
  t = Thread.new {
    begin
      sock = TCPSocket.new("srvapi.elten.link", 443)
      ssl = OpenSSL::SSL::SSLSocket.new(sock, OpenSSL::SSL::SSLContext.new)
      ssl.connect
      path = "/leg1/" + mod + ".php?" + param
      headers["User-Agent"] = "Elten #{$version} agent"
      headers["Connection"] = "close"
      headers["Accept-Encoding"] = "identity, deflate, chunked, *;q=0"
      met = "GET"
      if post != nil && post != ""
        met = "POST"
        headers["Content-Length"] = post.bytesize.to_s
      end
      hd = met + " " + path + " HTTP/1.1"
      hd += "\r\nHost: srvapi.elten.link"
      for k in headers.keys
        hd += "\r\n" + k + ": " + headers[k]
      end
      hd += "\r\n\r\n"
      ssl.write(hd)
      total = post.bytesize
      uploaded = 0
      tim = Time.now.to_f
      until post.empty?
        ch = post.slice!(0...16384)
        uploaded += ch.bytesize
        ssl.write(ch)
        if Time.now.to_f - tim > 5
          tim = Time.now.to_f
          b.call(ERUploadProgress.new(uploaded, total), data)
        end
      end
      resp = ""
      resp += ssl.read while !ssl.eof?
      ind = resp.index("\r\n\r\n")
      hd = resp[0...ind]
      lines = hd.split("\r\n")
      code = 0
      ph = lines[0].split(" ")
      if ph[0].upcase != "HTTP/1.1"
        b.call(:error, data)
      else
        status = ph[1].to_i
        if status < 200 || status >= 300
          b.call(:error, data)
        else
          headers = {}
          for l in lines[1..-1]
            nd = l.index(": ")
            headers[l[0...nd]] = l[nd + 2..-1]
          end
          bd = resp[ind + 4...-1]
          case headers["Transfer-Encoding"]
          when "identity"
            b.call(bd, data)
          when "deflate"
            b.call(Zlib::Inflate.inflate(bd), data)
          when "chunked"
            body = ""
            io = StringIO.new(bd)
            until io.eof?
              cnt = io.readline.to_i(16)
              break if cnt == 0
              body += io.read(cnt)
              io.read(2)
            end
            b.call(body, data)
          else
            b.call(:error, data)
          end
        end
      end
    rescue Exception
      log(2, "perequest worker error: " + $!.to_s + " " + $@.to_s)
    end
  }
end

def erequest(mod, param, post = nil, headers = {}, data = nil, ign = false, &b)
  return perequest(mod, param, post, headers, data, ign, &b) if (post != nil && post != "") && post.bytesize > 65536
  headers = {} if headers == nil
  headers["User-Agent"] = "Elten #{$version} agent"
  init if $http == nil
  $lastrep ||= Time.now.to_i
  init if $lastrep < Time.now.to_i - 20
  begin
    head = {
      ":scheme" => "https",
      ":authority" => "srvapi.elten.link:443",
      ":path" => "/leg1/#{mod}.php?#{param}"
    }
    if post == nil
      head[":method"] = "GET"
    else
      head[":method"] = "POST"
      head["content-length"] = post.bytesize.to_s
    end
    headers.keys.each { |k| head[k] = headers[k] }
    pst = post
    stream = $http.new_stream
    stream.headers(head, end_stream: (pst == nil || pst == ""))
    if pst != nil && pst != ""
      total = pst.bytesize
      uploaded = 0
      tim = Time.now.to_f
      i = 0
      until pst.empty?
        i += 1
        ch = pst.slice!(0...16384)
        uploaded += ch.bytesize
        stream.data(ch, end_stream: (pst.empty?))
        if Time.now.to_f - tim > 5
          tim = Time.now.to_f
          b.call(ERUploadProgress.new(uploaded, total), data)
        end
      end
    end
    body = ""
    stream.on(:data) { |ch| body += ch }
    stream.on(:half_close) { stream.close }
    stream.on(:close) { $eropened = nil; $lastrep = Time.now.to_i; b.call(body, data) }
  rescue Exception
    log(2, "Erequest error: " + $!.to_s + " " + $@.to_s) if !$!.is_a?(HTTP2::Error::ConnectionClosed)
    init
    retry if !ign
  end
end

def ejrequest(method, path, params, data = nil, &b)
  init if $http == nil
  $lastrep ||= Time.now.to_i
  init if $lastrep < Time.now.to_i - 20
  begin
    stream = $http.new_stream
    j = JSON.generate(params)
    head = {
      ":scheme" => "https",
      ":authority" => "api.elten.link:443",
      ":path" => path,
      "user-agent" => "Elten #{$version} agent",
      "content-type" => "application/json",
      ":method" => method,
      "content-length" => j.bytesize.to_s
    }
    stream.headers(head, end_stream: false)
    until j.empty?
      ch = j.slice!(0...4096)
      stream.data(ch, end_stream: (j.empty?))
    end
    body = ""
    stream.on(:headers) { |h| data["headers"] = h if data.is_a?(Hash) }
    stream.on(:data) { |ch| body += ch }
    stream.on(:half_close) { stream.close }
    stream.on(:close) {
      $eropened = nil
      $lastrep = Time.now.to_i
      b.call(body, data)
    }
  rescue Exception
    init
    retry
  end
end

class EltenSock
  def initialize
    @sock = TCPSocket.new("srvapi.elten.link", 80)
  end

  def write(wr)
    @sock.write(wr)
  end

  def read(rd = 1024)
    @sock.read(rd)
  end

  def close
    @sock.close
  end
end

def play(file, looper = false)
  f = nil
  snd = nil
  begin
    if file[0..3] != "http"
      return if $SoundThemeActivation == 0
      f = nil
      snd = getsound(file)
    else
      f = file
    end
    $plid ||= 0
    $players ||= []
    $plid = ($plid + 1) % 128
    plid = $plid
    if f != nil || snd != nil
      begin
        pl = Bass::Sound.new(f, 1, looper, false, snd)
        pl.volume = ($volume.to_f / 100.0)
        pl.play
        if looper
          $bgplayer.close if $bgplayer != nil
          $bgplayer = pl
        else
          $players[plid].close if $players[plid] != nil
          $players[plid] = pl
        end
      rescue Exception
        begin
          Bass.init($hwnd || 0)
        rescue Exception
        end
      end
    end
  rescue Exception
  end
end

def log(level, msg)
  ewrite({ "func" => "log", "level" => level, "msg" => msg, "time" => Time.now.to_f })
end

def decrypt(data, code = nil)
  pin = [data.size, data].pack("ip")
  pout = [0, nil].pack("ip")
  pcode = nil
  pcode = [code.size, code].pack("ip") if code != nil
  $cryptunprotectdata.call(pin, nil, pcode, nil, nil, 0, pout)
  s, t = pout.unpack("ii")
  m = "\0" * s
  $rtlmovememory.call(m, t, s)
  $localfree.call(t)
  return m
end

def crypt(data, code = nil)
  pin = [data.size, data].pack("ip")
  pout = [0, nil].pack("ip")
  pcode = nil
  pcode = [code.size, code].pack("ip") if code != nil
  $cryptprotectdata.call(pin, nil, pcode, nil, nil, 0, pout)
  s, t = pout.unpack("ii")
  m = "\0" * s
  $rtlmovememory.call(m, t, s)
  $localfree.call(t)
  return m
end

class SapiVoice
  attr_accessor :id, :name, :language, :age, :gender, :vendor

  def voiceid
    return "" if @id == nil
    return @id.split("\\").last
  end
end

def listsapivoices
  sz = $sapilistvoices.call(nil, 0)
  a = ([nil, nil, nil, nil, nil, nil] * sz).pack("pppppp" * sz)
  $sapilistvoices.call(a, sz)
  mems = a.unpack("iiiiii" * sz)
  voices = []
  for i in 0...mems.size / 6
    ms = mems[i * 6...i * 6 + 6]
    voice = SapiVoice.new
    for j in 0...6
      m = ms[j]
      next if m == 0
      len = $wcslen.call(m)
      ptr = "\0" * 2 * (len + 1)
      $wcscpy.call(ptr, m)
      val = deunicode(ptr)
      case j
      when 0
        voice.id = val
      when 1
        voice.name = val
      when 2
        voice.language = val
      when 3
        voice.age = val
      when 4
        voice.gender = val
      when 5
        voice.vendor = val
      end
    end
    voices.push(voice)
  end
  $sapifreevoices.call(a, sz)
  return voices
end

def listsapidevices
  sz = $sapilistdevices.call(nil, 0)
  a = ([nil] * sz).pack("p" * sz)
  $sapilistdevices.call(a, sz)
  mems = a.unpack("i" * sz)
  devices = []
  for m in mems
    len = $wcslen.call(m)
    ptr = "\0" * 2 * (len + 1)
    $wcscpy.call(ptr, m)
    devices.push(deunicode(ptr))
  end
  $sapifreedevices.call(a, sz)
  return devices
end

class SoundTheme
  attr_accessor :name
  attr_reader :file
  attr_reader :sounds

  def initialize(name, file = nil)
    @name = name
    @file = file
    @sounds = {}
  end

  def getsound(name)
    return nil if !name.is_a?(String)
    return @sounds[name.downcase]
  end
end

@@defaultsoundtheme = SoundTheme.new("")
@@soundtheme = nil

def load_soundtheme(file, loadSounds = true)
  return nil if !FileTest.exists?(file)
  size = File.size(file)
  return nil if size > 64 * 1024 ** 2 || size < 36
  io = StringIO.new(IO.binread(file))
  magic = "EltenSoundThemePackageFileCMPSMC"
  return nil if io.read(32) != magic
  io.read(8)
  sz = io.read(1).unpack("C").first
  st = SoundTheme.new(io.read(sz), file)
  sz = io.read(4).unpack("I").first
  return nil if size != sz + 32 + 8 + 1 + st.name.bytesize + 4
  if loadSounds
    zio = StringIO.new(Zlib::Inflate.inflate(io.read(sz)))
    while !zio.eof?
      sz = zio.read(1).unpack("C").first
      file = zio.read(sz)
      sz = zio.read(4).unpack("I").first
      content = zio.read(sz)
      st.sounds[file.downcase] = content
    end
  end
  return st
rescue Exception
  return nil
end

def use_soundtheme(file, default = false)
  if default == false && (file == "" || file == nil)
    @@soundtheme = @@defaultsoundtheme
    return true
  end
  st = load_soundtheme(file)
  if st != nil
    @@soundtheme = st
    @@defaultsoundtheme = st if default
  end
end

def getsound(file)
  if @@soundtheme != nil
    sound = @@soundtheme.getsound(file)
    return sound if sound != nil
  end
  if @@defaultsoundtheme != nil
    sound = @@defaultsoundtheme.getsound(file)
    return sound if sound != nil
  end
  return nil
end

def read_logindata
  magic = "EltenLoginCredentialsPRVDataFile"
  return [0, "", "", -1] if !FileTest.exists?($eltendata + "\\login.dat")
  str = IO.binread($eltendata + "\\login.dat")
  io = StringIO.new(str)
  return [0, "", "", -1] if io.read(magic.bytesize) != magic
  autologin = io.read(1).unpack("C").first
  name = io.read(io.read(4).unpack("I").first)
  token = io.read(io.read(4).unpack("I").first)
  tokenenc = io.read(1).unpack("c").first
  return [autologin, name, token, tokenenc]
rescue Exception
  return [0, "", "", -1]
end
