# frozen_string_literal: true

require "json"
require "socket"
require "io/wait"

# A minimal client for QEMU's machine protocol (QMP) on a unix socket.
#
# The peer is a QEMU running untrusted guest code under TCG, so it is
# treated as hostile: one deadline covers the whole session (connect,
# greeting, every command), a message may be at most MAX_MESSAGE bytes,
# and anything that is not well-formed QMP raises. Asynchronous events
# are skipped.
#
# Connection failures (Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES)
# are raised unchanged so the caller can tell a stale socket from a
# misbehaving QEMU.
class QmpClient
  class Error < StandardError; end

  class Timeout < Error; end

  class CommandError < Error; end

  MAX_MESSAGE = 65_536

  # How long to wait before retrying a connect while QEMU's listen
  # backlog is full (QEMU serves one QMP client at a time).
  BUSY_RETRY_SECONDS = 0.05

  # Connects, reads the greeting and leaves negotiation mode, all within
  # timeout seconds. Later commands must finish within the same deadline.
  def initialize(path, timeout: 10)
    @deadline = now + timeout
    @buf = +"".b
    @id = 0
    @sock = connect(path)
    begin
      greeting = read_message
      fail Error, "QMP greeting expected, got #{abbrev(greeting)}" unless greeting.key?("QMP")
      execute("qmp_capabilities")
    rescue
      close
      raise
    end
  end

  # Runs one QMP command and returns its "return" value.
  def execute(command, arguments = nil)
    @id += 1
    request = {"execute" => command, "id" => @id}
    request["arguments"] = arguments if arguments
    send_message(request)

    reply = read_message
    fail Error, "unexpected QMP reply to #{command}: #{abbrev(reply)}" unless reply["id"] == @id
    if reply.key?("error")
      fail CommandError, "QMP #{command} failed: #{JSON.generate(reply["error"])}"
    end
    fail Error, "QMP reply to #{command} has no return: #{abbrev(reply)}" unless reply.key?("return")
    reply["return"]
  end

  def close
    @sock.close unless @sock.closed?
  end

  private

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def remaining
    left = @deadline - now
    fail Timeout, "QMP timed out" if left <= 0
    left
  end

  def connect(path)
    addr = Socket.sockaddr_un(path)
    loop do
      sock = Socket.new(:UNIX, :STREAM)
      begin
        sock.connect_nonblock(addr)
        return sock
      rescue Errno::EAGAIN
        # A unix socket never reports EINPROGRESS; EAGAIN means the
        # listen backlog is full.
        sock.close
        sleep [BUSY_RETRY_SECONDS, remaining].min
      rescue
        sock.close
        raise
      end
    end
  end

  def send_message(message)
    remaining
    @sock.write(JSON.generate(message) + "\n")
  rescue Errno::EPIPE, Errno::ECONNRESET
    fail Error, "QMP connection closed"
  end

  # Returns the next message that is not an event.
  def read_message
    loop do
      if (newline = @buf.index("\n"))
        message = parse(@buf.slice!(0..newline))
        return message unless message.key?("event")
      else
        fail Error, "QMP message longer than #{MAX_MESSAGE} bytes" if @buf.bytesize >= MAX_MESSAGE
        fill
      end
    end
  end

  def fill
    @buf << @sock.read_nonblock(MAX_MESSAGE - @buf.bytesize)
  rescue IO::WaitReadable
    fail Timeout, "QMP timed out" unless @sock.wait_readable(remaining)
  rescue EOFError, Errno::ECONNRESET
    fail Error, "QMP connection closed"
  end

  def parse(line)
    message = JSON.parse(line.force_encoding(Encoding::UTF_8))
    fail Error, "QMP message is not an object: #{abbrev(message)}" unless message.is_a?(Hash)
    message
  rescue JSON::ParserError
    fail Error, "QMP message is not JSON"
  end

  def abbrev(message)
    JSON.generate(message)[0, 200]
  end
end
