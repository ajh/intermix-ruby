require 'pty'
require 'terminfo'

module Intermix

  # This class represents a running program inside the terminal emulator
  class Program
    attr_accessor :parser, :screen, :input, :output, :pid, :size_rows, :size_cols, :command

    # one of: :not_started, :running, :exited
    attr_accessor :state

    def self.logger
      @logger ||= Logger.new 'log/program.log'
    end

    def self.code_to_s(c)
      "#{[c].pack('U').inspect}(0x%02X)" % c
    end

    def initialize(size_rows, size_cols, command)
      self.parser = TtyOutputParser.new
      self.size_rows = size_rows
      self.size_cols = size_cols
      self.state = :not_started
      self.command = command

      ObjectSpace.define_finalizer(self) do
        kill
      end
    end

    # Run the program
    def run
      self.output, self.input, self.pid = PTY.spawn command
      TermInfo.tiocswinsz output, size_rows, size_cols

      self.screen = Screen.new size_rows, size_cols, TermInfo.new(ENV['TERM'], output)
      hook_up_parser_to_screen parser, screen

      self.state = :running

      true
    end

    # Run this often to get the latest update from the program.
    #
    # This'll update the screen via the configured parser callbakcs.
    def update
      state == :running or return
      parser << output.read_nonblock(100)

    rescue IO::WaitReadable
      nil

    rescue EOFError, Errno::EIO
      self.state = :exited
      self.class.logger.error $!.inspect
    end

    def kill(signal="TERM")
      self.class.logger.info "killing pid #{pid}"
      Process.kill(signal, pid)
    end

    private

    # Define callbacks to hook up the parser to the screen
    def hook_up_parser_to_screen(parser, screen)
      parser.configure_callbacks do |config|
        config.handle_print do |code|
          screen.print code
        end

        config.handle_csi_dispatch do |sequence|
          self.class.logger.debug "csi_dispatch sequence: #{sequence.inspect}"
          sequence or next

          if sequence.capname == 'sgr' && sequence.param_name == 'normal'
            screen.pen.bold = false
          elsif sequence.capname == 'bold'
            screen.pen.bold = true
          elsif sequence.capname == 'smcup'
            screen.save_cursor
            screen.alternate_screen_buffer
          elsif sequence.capname == 'rmcup'
            screen.save_cursor
            screen.normal_screen_buffer
          elsif sequence.capname == 'elr'
            screen.erase_in_line
          else
            self.class.logger.debug "unhandled csi_dispatch sequence: #{sequence.inspect}"
          end
        end

        config.handle_esc_dispatch do |sequence|
          self.class.logger.debug "esc_dispatch sequence: #{sequence.inspect}"
          self.class.logger.debug "unhandled esc_dispatch sequence: #{sequence.inspect}"
        end

        config.handle_execute do |sequence|
          self.class.logger.debug "execute sequence: #{sequence.inspect}"
          sequence or next

          if sequence.capname == 'cr'
            screen.pen.move_left full: true
          elsif sequence.capname == 'nl'
            screen.pen.move_down
          elsif sequence.long_name == 'backspace'
            screen.pen.move_left
          else
            self.class.logger.debug "unhandled execute sequence: #{sequence.inspect}"
          end
        end
      end
    end

    # Not using now, but maybe I will?
    #def alive?
      #Process.kill(0, @pid)
      #true
    #rescue Errno::ESRCH, Errno::ENOENT
      #false
    #end
  end
end
