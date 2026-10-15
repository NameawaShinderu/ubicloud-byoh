# frozen_string_literal: true

require_relative "../lib/qmp_client"
require "tmpdir"

RSpec.describe QmpClient do
  around do |example|
    Dir.mktmpdir("qmp") do |dir|
      @path = File.join(dir, "qmp.sock")
      example.run
    end
  end

  attr_reader :path

  def greeting
    %({"QMP": {"version": {"qemu": {"micro": 0, "minor": 2, "major": 8}}, "capabilities": ["oob"]}}\n)
  end

  # A QMP server on a real unix socket. The block gets the accepted
  # connection; requests it reads are collected in #requests.
  def serve
    @requests = []
    @server = UNIXServer.new(path)
    @thread = Thread.new do
      conn = @server.accept
      yield conn
    ensure
      conn&.close
    end
  end

  def read_request(conn)
    JSON.parse(conn.gets).tap { |req| @requests << req }
  end

  def reply(conn, id, value = {})
    conn.write(JSON.generate("return" => value, "id" => id) + "\n")
  end

  def handshake(conn)
    conn.write(greeting)
    reply(conn, read_request(conn)["id"])
  end

  after do
    @thread&.join(5)
    @server&.close
  end

  it "negotiates capabilities and runs commands, skipping events" do
    serve do |conn|
      sleep 0.05
      handshake(conn)
      req = read_request(conn)
      conn.write(%({"event": "POWERDOWN", "timestamp": {"seconds": 1, "microseconds": 2}}\n))
      reply(conn, req["id"], {"enabled" => false, "present" => false})
      req = read_request(conn)
      conn.write(%({"event": "A"}\n{"event": "B"}\n{"return": "ok", "id": #{req["id"]}}\n))
    end
    qmp = described_class.new(path, timeout: 5)
    expect(qmp.execute("query-kvm")).to eq({"enabled" => false, "present" => false})
    expect(qmp.execute("human-monitor-command", {"command-line" => "info jit"})).to eq("ok")
    qmp.close
    qmp.close
    expect(@requests).to eq([
      {"execute" => "qmp_capabilities", "id" => 1},
      {"execute" => "query-kvm", "id" => 2},
      {"execute" => "human-monitor-command", "id" => 3, "arguments" => {"command-line" => "info jit"}},
    ])
  end

  it "raises on a QMP error reply" do
    serve do |conn|
      handshake(conn)
      req = read_request(conn)
      conn.write(JSON.generate("error" => {"class" => "GenericError", "desc" => "no"}, "id" => req["id"]) + "\n")
    end
    qmp = described_class.new(path, timeout: 5)
    expect { qmp.execute("system_powerdown") }.to raise_error(QmpClient::CommandError, 'QMP system_powerdown failed: {"class":"GenericError","desc":"no"}')
  end

  it "raises on a reply to another request" do
    serve do |conn|
      handshake(conn)
      read_request(conn)
      reply(conn, 99)
    end
    qmp = described_class.new(path, timeout: 5)
    expect { qmp.execute("system_powerdown") }.to raise_error(QmpClient::Error, 'unexpected QMP reply to system_powerdown: {"return":{},"id":99}')
  end

  it "raises on a reply without return" do
    serve do |conn|
      handshake(conn)
      conn.write(%({"id": #{read_request(conn)["id"]}}\n))
    end
    qmp = described_class.new(path, timeout: 5)
    expect { qmp.execute("system_powerdown") }.to raise_error(QmpClient::Error, 'QMP reply to system_powerdown has no return: {"id":2}')
  end

  it "refuses a peer that does not greet like QMP and closes the socket" do
    serve { |conn| conn.write(%({"hello": 1}\n)) }
    expect(Socket).to receive(:new).and_wrap_original do |m, *args|
      m.call(*args).tap { |sock| @sock = sock }
    end
    expect { described_class.new(path, timeout: 5) }.to raise_error(QmpClient::Error, 'QMP greeting expected, got {"hello":1}')
    expect(@sock).to be_closed
  end

  it "times out when the greeting never comes" do
    serve { |conn| conn.read }
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { described_class.new(path, timeout: 0.3) }.to raise_error(QmpClient::Timeout, "QMP timed out")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be < 2
  end

  it "keeps one deadline for the whole session" do
    serve do |conn|
      handshake(conn)
      conn.read
    end
    qmp = described_class.new(path, timeout: 0.3)
    sleep 0.35
    expect { qmp.execute("system_powerdown") }.to raise_error(QmpClient::Timeout, "QMP timed out")
    qmp.close
  end

  it "raises when the peer closes the connection instead of replying" do
    serve do |conn|
      conn.write(greeting)
      read_request(conn)
    end
    expect { described_class.new(path, timeout: 5) }.to raise_error(QmpClient::Error, "QMP connection closed")
  end

  it "raises when the peer has gone before a command is sent" do
    serve { |conn| handshake(conn) }
    qmp = described_class.new(path, timeout: 5)
    @thread.join(5)
    expect { qmp.execute("system_powerdown") }.to raise_error(QmpClient::Error, "QMP connection closed")
  end

  it "refuses a message longer than the limit" do
    serve do |conn|
      conn.write("{" + " " * QmpClient::MAX_MESSAGE)
      # Wait for the client to hang up; it never reads the rest.
      conn.wait_readable(5)
    end
    expect { described_class.new(path, timeout: 5) }.to raise_error(QmpClient::Error, "QMP message longer than 65536 bytes")
  end

  it "accepts a message of exactly the limit" do
    serve do |conn|
      conn.write(greeting.sub("{", "{" + " " * (QmpClient::MAX_MESSAGE - greeting.bytesize)))
      reply(conn, read_request(conn)["id"])
    end
    expect(described_class.new(path, timeout: 5)).to be_a(described_class)
  end

  it "refuses a message that is not JSON" do
    serve { |conn| conn.write("QMP?\n") }
    expect { described_class.new(path, timeout: 5) }.to raise_error(QmpClient::Error, "QMP message is not JSON")
  end

  it "refuses a message that is not an object" do
    serve { |conn| conn.write("[1]\n") }
    expect { described_class.new(path, timeout: 5) }.to raise_error(QmpClient::Error, "QMP message is not an object: [1]")
  end

  it "raises ENOENT when there is no socket" do
    expect { described_class.new(path, timeout: 5) }.to raise_error(Errno::ENOENT)
  end

  it "raises ECONNREFUSED on a stale socket" do
    UNIXServer.new(path).close
    expect { described_class.new(path, timeout: 5) }.to raise_error(Errno::ECONNREFUSED)
  end

  describe "while QEMU serves another client" do
    # With a backlog of 0, one pending connection fills the queue, and a
    # non-blocking connect then fails with EAGAIN.
    before do
      @busy = UNIXServer.new(path)
      @busy.listen(0)
      @pending = UNIXSocket.new(path)
    end

    after do
      @pending.close
      @busy.close
    end

    it "retries until the deadline" do
      expect { described_class.new(path, timeout: 0.3) }.to raise_error(QmpClient::Timeout, "QMP timed out")
    end

    it "connects once the backlog drains" do
      @requests = []
      thread = Thread.new do
        sleep 0.2
        @busy.accept.close
        conn = @busy.accept
        handshake(conn)
        conn
      end
      expect(described_class.new(path, timeout: 5)).to be_a(described_class)
      thread.value.close
    end
  end
end
