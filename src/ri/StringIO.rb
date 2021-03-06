class StringIO < IO
  attr_accessor :string, :pos

  def initialize(str = "")
    @string = str
    @pos = 0
  end

  def read(size)
    return "" if size == 0
    r = @string[@pos...@pos + size]
    if @pos + size > @string.bytesize
      @pos = @string.bytesize
    else
      @pos += size
    end
    return r
  end

  def seek(o)
    @pos = o
    @pos = @string.size if @pos > @string.size
  end

  def binmode
    return self
  end

  def getc
    return nil if @pos >= @string.size
    read(1).unpack("c").first
  end

  def eof?
    return false if @pos < @string.size
    true
  end
end
