
$: << File.expand_path(File.dirname(__FILE__)+"/../lib/")

require 'termcontroller'

class Target

  def initialize
    keymap = { :ctrl_c => :quit }
    @ctrl = Termcontroller::Controller.new(self, keymap)
    @c = " "
    @col = 1
  end

  # If a method exists in the target class passed to Controller.new
  # that matches the keymap, then it is called directly.
  #
  # In this case `quit` is defined in the map above,
  # while `char` is a default.
  #
  # If nothing is mapped, then `handle_input` will return the
  # symbol instead, as shown for `mouse_down`.
  #
  def quit    = (@running = false)
  def char(c) = (@c = c)

  def call
    @running = true
    col = 1
    while @running
      cmd = @ctrl.handle_input
      case cmd.first
      when :mouse_down
        print "\e[5;1H#{cmd.inspect}"
        print "\e[#{cmd[3]};#{cmd[2]}H"
        if cmd[1] & 3 == 0
          # left
          print "\e[4#{col}m#{@c}\e[49m"
          print "\e[1;1H[DRAWING] "
        elsif cmd[1] & 3 == 2
          # right
          print " "
          print "\e[1;1H[ERASING] "
        end
      end
    end
  end
end


print "\e[2J"   # Clear screen
print "\e[4;1HHold left button and move mouse to draw; Hold right button and move to clear"
print "\e[3;1HPress any letter to set a character to fill with on draw."
print "\e[2;1HCtrl+c to quit"
Target.new.call
print "\e[2J"   # Clear screen
print "\e[1;1H" # Move top left
