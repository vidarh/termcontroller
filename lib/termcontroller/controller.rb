# coding: utf-8

require 'io/console'

# # Controller
#
# This is way too ill defined. The purpose is to be able to have a
# separate thread handle the keyboard processing asynchronously,
# reading from the input, and for an application to then be able to
# call into it to read a command, or to have the controller dispatch
# the command directly to a specified target object based on the
# key bindings.
#
# It works well enough to e.g. allow temporarily pausing the processing
# and then dispatching "binding.pry" and re-enable the processing when
# it returns.
#
# FIXME: Should probably treat this as a singleton.
#
#

require 'keyboard_map'

module Termcontroller
  class Controller

    attr_reader :lastcmd,:lastkey,:lastchar
    attr_accessor :mode

    @@con = IO.console

    # Pause *any* Controller instance
    @@pause = false
    def self.pause!
      old = @@pause
      @@pause = true
      @@con.cooked do
        yield
      end
    ensure
      @@pause = old
    end

    def paused?
      @mode == :pause || @@pause
    end

    def initialize(target, keybindings)
      @target = target
      @keybindings = keybindings
      @buf = ""
      @commands = Queue.new
      @mode = :cooked

      @kb = KeyboardMap.new
      @@con = @con = IO.console
      raise if !@con

      at_exit do
        cleanup
      end

      trap("CONT") { resume }

    @t = Thread.new { readloop }
  end

  def setup
    STDOUT.print "\e[?2004h" # Enable bracketed paste
    STDOUT.print "\e[?1000h" # Enable mouse reporting
    STDOUT.print "\e[?1006h" # Enable extended reporting
  end

  def cleanup
    STDOUT.print "\e[?2004l" #Disable bracketed paste
    STDOUT.print "\e[?1000l" #Disable mouse reporting
  end

  def readloop
    loop do
      if paused?
        sleep(0.05)
      elsif @mode == :cooked
        read_input
      else
        fill_buf
      end
    end
  end

  def pause
    old = @mode
    @mode = :pause
    sleep(0.1)
    IO.console.cooked!
    yield
  rescue Interrupt
  ensure
    @mode = old
  end

  def fill_buf(timeout=0.1)
    if paused?
      sleep(0.1)
      Thread.pass
      return
    end
    @con.raw!
    return if !IO.select([$stdin],nil,nil,0.1)
    str = $stdin.read_nonblock(4096)
    str.force_encoding("utf-8")
    @buf << str
  rescue IO::WaitReadable
  end

  def getc(timeout=0.1)
    if !paused?
      while @buf.empty?
        fill_buf
      end
      @buf.slice!(0) if !paused? && @mode == :cooked
    else
      sleep(0.1)
      Thread.pass
      return nil
    end
  rescue Interrupt
  end

  def raw
    @mode = :raw
    yield
  rescue Interrupt
  ensure
    @mode = :cooked
  end

  def read_char
    sleep(0.01) if @buf.empty?
    @buf.slice!(0)
  rescue Interrupt
  end

  def get_command
    map = @keybindings
    loop do
      c = nil
      char = getc
      return nil if !char

      c1 = Array(@kb.call(char)).first
      c = map[c1.to_sym] if c1

      if c.nil? && c1.kind_of?(String)
        return [:insert_char, c1]
      end

      if c.nil?
        if c1
          @lastchar = c1.to_sym
          args = c1.respond_to?(:args) ? c1.args : []
          return Array(c1.to_sym).concat(args || [])
        else
          @lastchar = char.inspect
          return nil
        end
      end

      if c.kind_of?(Hash)
        map = c
      else
        @lastchar = c1.to_sym.to_s.split("_").join(" ")
        @lastchar += " (#{c.to_s})" if c.to_s != @lastchar
        return c
      end
    end
  end

  def do_command(c)
    return nil if !c
    if @target.respond_to?(Array(c).first)
      @lastcmd = c
      @target.instance_eval { send(*Array(c)) }
    else
      @lastchar = "Unbound: #{Array(c).first.inspect}"
    end
  end

  def read_input
    c = get_command
    if !c
      Thread.pass
      return
    end
    if Array(c).first == :insert_char
      # FIXME: Attempt to combine multiple :insert_char into one.
      #Probably should happen in get_command
      #while (c2 = get_command) && Array(c2).first == :insert_char
      #  c.last << c2.last
      #end
      #@commands << c
      #c = c2
      #return nil if !c
    end
    @commands << c
  end

  def next_command
    @commands.pop
  end

  def handle_input(prefix="",timeout=0.1)
    if c = next_command
      do_command(c)
    end
    return c
  end

  def pry(e=nil)
    pause do
      cleanup
      puts ANSI.cls
      binding.pry
    end
    setup
  end

  def suspend
    pause do
      yield if block_given?
      Process.kill("STOP", 0)
    end
  end

  def resume
    @mode = :cooked
    setup
    @commands << [:resume]
  end
end
end

at_exit do
  #
  # FIXME: This is a workaround for Controller putting
  # STDIN into nonblocking mode and not cleaning up, which
  # causes all kind of problems with a variety of tools (more,
  # docker etc.) which expect it to be blocking.
  Termcontroller::Controller.pause! do
    stdin_flags = STDIN.fcntl(Fcntl::F_GETFL)
    STDIN.fcntl(Fcntl::F_SETFL, stdin_flags & ~Fcntl::O_NONBLOCK) #
    IO.console.cooked!
  end
end
