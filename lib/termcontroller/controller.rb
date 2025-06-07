# coding utf-8

require 'io/console'
require 'fcntl'

# # Controller
#
# This is way too ill defined. The purpose is to be able to have a
# separate thread handle the keyboard processing asynchronously,
# reading from the input, and for an application to then be able to
# call into it to read a command, or to have the controller dispatch
# the command directly to a specified target object based on the
# key bindings.
#
# Note that *currently* `#handle_input` will block on retrieving a
# command with no timeout. This is because Re is the only current
# client of this class, and *currently* does not have a need for
# anything async. That *will* change, as Re will eventually start
# receiving evented updates. Current "hack" to work around this:
# push things into the `commands` queue. This may well be the ongoing
# way to do it, and I might consider breaking it out.
#
# It works well enough to e.g. allow temporarily pausing the processing
# and then dispatching "binding.pry" and re-enable the processing when
# it returns.
#
# That said there are lots of hacks in here that needs to be cleaned up
#
# FIXME: Should probably treat this as a singleton.
#
#

require 'keyboard_map'

module Termcontroller
  DOUBLE_CLICK_INTERVAL=0.5

  class Controller
    @@controllers = []

    attr_reader :lastcmd, :commands

    def initialize(target=nil, keybindings={})
      @m = Mutex.new

      @target = target
      @target_stack = []

      @keybindings = keybindings
      @buf = ""
      @commands = Queue.new
      @mode = :cooked

      @kb = KeyboardMap.new
      @con = IO.console
      raise if !@con

      at_exit { quit }
      trap("CONT")  { resume }
      trap("WINCH") { @commands << :resize }

      setup

      @t = Thread.new { readloop }

      @@controllers << @t

    end

    def paused?; @mode == :pause; end

    def push_target(t)
      @target_stack << @target
      @target = t
    end

    def pop_target
      t = @target
      @target = @target_stack.pop
      t
    end


    #
    # Pause processing so you can read directly from stdin
    # yourself. E.g. to use Readline, or to suspend
    #
    def pause
      @m.synchronize do
        old = @mode
        begin
          @mode = :pause
          IO.console.cooked!
          cleanup
          r = yield
          r
        rescue Interrupt
        ensure
          @mode = old
          setup
        end
      end
    end

    # FIXME: The first event after the yield
    # appears to fail to pass the mapping.
    # Maybe move the mapping to the client thread?
    def raw
      keybindings = @keybindings
      @keybindings = {}
      push_target(nil)
      yield
    rescue Interrupt
    ensure
      @keybindings = keybindings
      pop_target
    end

    def handle_input
      if c = @commands.pop
        do_command(c)
      end
      return Array(c)
    end

    # USE WITH CAUTION. This will pause processing,
    # yield to the provided block if any, and then send
    # SIGSTOP to the process.
    #
    # This is meant to allow for handling ctrl-z to
    # suspend in processes that need to be able to
    # reset the terminal to a better state before stopping.
    #
    # FIXME: It seems like it does not work as expected.
    #
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

    def hide_cursor
      STDOUT.print "\e[?25l"   # Hide cursor
    end

    def show_cursor
      STDOUT.print "\e[?25h"   # Show cursor
    end

    private # # ########################################################

    def setup
      STDOUT.print "\e[?2004h" # Enable bracketed paste
      STDOUT.print "\e[?1000h" # Enable mouse reporting
      STDOUT.print "\e[?1002h" # Enable mouse *move when clicked* reporting
      STDOUT.print "\e[?1006h" # Enable extended reporting
      hide_cursor
      @con.raw!
    end

    def cleanup
      # Some programs, like more and docker struggles if the terminal
      # is not returned to blocking mode
      stdin_flags = STDIN.fcntl(Fcntl::F_GETFL)
      STDIN.fcntl(Fcntl::F_SETFL, stdin_flags & ~Fcntl::O_NONBLOCK) #

      @con.cooked!
      STDOUT.print "\e[?2004l" #Disable bracketed paste
      STDOUT.print "\e[?1000l" #Disable mouse reporting
      show_cursor
    end

    def quit
      @@controllers.each {|t| t.kill }
      cleanup
    end


    def fill_buf
      # We do this to ensure the other thread gets a chance
      sleep(0.01)

      @m.synchronize do
        @con.raw!
        return if !IO.select([$stdin],nil,nil,0.1)
        str = $stdin.read_nonblock(4096)

        # FIXME...
        str.force_encoding("utf-8")
        @buf << str
      end
    rescue IO::WaitReadable
    end


    def getc
      while @buf.empty?
        fill_buf
      end
      @buf.slice!(0) if !paused? && @mode == :cooked
    rescue Interrupt
    end

    # We do this because @keybindings can be changed
    # on the main thread if the client changes the bindings,
    # e.g. by calling `#raw`. This is the *only* sanctioned
    # way to look up the binding.
    #
    def map(key, map = @keybindings)
      map && key ? map[key.to_sym] : nil
    end

    def get_command
      # Keep track of compound mapping
      cmap = nil
      cmdstr = ""

      loop do
        c = nil
        char = getc
        return nil if !char

        a = Array(@kb.call(char))
        c1 = a.first

        if c1 == :mouse_up
          t  = Time.now
          dt = @lastclick ? t - @lastclick : 999
          if dt < DOUBLE_CLICK_INTERVAL
            c1 = :mouse_doubleclick
          else
            c1 = :mouse_click
          end
          @lastclick = t
        end

        c = map(c1, cmap || @keybindings)

        if c.nil? && c1.kind_of?(String)
          return [:char, c1]
        end

        if c.nil?
          if c1
            args = c1.respond_to?(:args) ? c1.args : []
            @lastcmd = cmdstr + c1.to_sym.to_s
            return Array(c1.to_sym).concat(args || [])
          else
            @lastcmd = cmdstr + char.inspect
            return nil
          end
        end

        str = c1.to_sym.to_s.split("_").join(" ")
        if cmdstr.empty?
          cmdstr = str
        else
          cmdstr += " + " + str
        end

        if c.kind_of?(Hash) # Compound mapping
          cmap = c
        else
          @lastcmd = cmdstr + " (#{c.to_s})" if c.to_s != @lastcmd
          return c
        end
      end
    end

    def read_input
      c = get_command
      if !c
        Thread.pass
        return
      end

      @commands << c
    end

    def readloop
      loop do
        if @mode == :cooked
          read_input
        else
          fill_buf
        end
      end
    end

    def do_command(c)
      return nil if !c || !@target
      a = Array(c)
      if @target.respond_to?(a.first)
        @target.instance_eval { send(*a) }
      else
        @lastcmd = "Unbound: #{a.first.inspect}"
      end
    end

  end
end
