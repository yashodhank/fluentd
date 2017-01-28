require_relative '../helper'
require 'fluent/test/driver/output'
require 'fluent/plugin/out_forward'
require 'flexmock/test_unit'

require 'fluent/test/driver/input'
require 'fluent/plugin/in_forward'

class ForwardOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    @d = nil
  end

  def teardown
    @d.instance_shutdown if @d
  end

  TARGET_HOST = '127.0.0.1'
  TARGET_PORT = unused_port
  CONFIG = %[
    send_timeout 51
    heartbeat_type udp
    <server>
      name test
      host #{TARGET_HOST}
      port #{TARGET_PORT}
    </server>
  ]

  TARGET_CONFIG = %[
    port #{TARGET_PORT}
    bind #{TARGET_HOST}
  ]

  def create_driver(conf=CONFIG)
    Fluent::Test::Driver::Output.new(Fluent::Plugin::ForwardOutput) {
      attr_reader :response_chunk_ids, :exceptions, :sent_chunk_ids

      def initialize
        super
        @sent_chunk_ids = []
        @response_chunk_ids = []
        @exceptions = []
      end

      def try_write(chunk)
        retval = super
        @sent_chunk_ids << chunk.unique_id
        retval
      end

      def read_ack_from_sock(sock, unpacker)
        retval = super
        @response_chunk_ids << retval
        retval
      rescue => e
        @exceptions << e
        raise e
      end
    }.configure(conf)
  end

  test 'configure' do
    @d = d = create_driver(%[
      self_hostname localhost
      <server>
        name test
        host #{TARGET_HOST}
        port #{TARGET_PORT}
      </server>
    ])
    nodes = d.instance.nodes
    assert_equal 60, d.instance.send_timeout
    assert_equal :tcp, d.instance.heartbeat_type
    assert_equal 1, nodes.length
    node = nodes.first
    assert_equal "test", node.name
    assert_equal '127.0.0.1', node.host
    assert_equal TARGET_PORT, node.port
  end

  test 'configure_traditional' do
    @d = d = create_driver(<<EOL)
      self_hostname localhost
      <server>
        name test
        host #{TARGET_HOST}
        port #{TARGET_PORT}
      </server>
      buffer_chunk_limit 10m
EOL
    instance = d.instance
    assert instance.chunk_key_tag
    assert !instance.chunk_key_time
    assert_equal [], instance.chunk_keys
    assert{ instance.buffer.is_a?(Fluent::Plugin::MemoryBuffer) }
    assert_equal( 10*1024*1024, instance.buffer.chunk_limit_size )
  end

  test 'configure_udp_heartbeat' do
    @d = d = create_driver(CONFIG + "\nheartbeat_type udp")
    assert_equal :udp, d.instance.heartbeat_type
  end

  test 'configure_none_heartbeat' do
    @d = d = create_driver(CONFIG + "\nheartbeat_type none")
    assert_equal :none, d.instance.heartbeat_type
  end

  test 'configure_expire_dns_cache' do
    @d = d = create_driver(CONFIG + "\nexpire_dns_cache 5")
    assert_equal 5, d.instance.expire_dns_cache
  end

  test 'configure_dns_round_robin udp' do
    assert_raise(Fluent::ConfigError) do
      create_driver(CONFIG + "\nheartbeat_type udp\ndns_round_robin true")
    end
  end

  test 'configure_dns_round_robin tcp' do
    @d = d = create_driver(CONFIG + "\nheartbeat_type tcp\ndns_round_robin true")
    assert_equal true, d.instance.dns_round_robin
  end

  test 'configure_dns_round_robin none' do
    @d = d = create_driver(CONFIG + "\nheartbeat_type none\ndns_round_robin true")
    assert_equal true, d.instance.dns_round_robin
  end

  test 'configure_no_server' do
    assert_raise(Fluent::ConfigError, 'forward output plugin requires at least one <server> is required') do
      create_driver('')
    end
  end

  test 'configure with ignore_network_errors_at_startup' do
    normal_conf = config_element('match', '**', {}, [
        config_element('server', '', {'name' => 'test', 'host' => 'unexisting.yaaaaaaaaaaaaaay.host.example.com'})
      ])
    assert_raise SocketError do
      create_driver(normal_conf)
    end

    conf = config_element('match', '**', {'ignore_network_errors_at_startup' => 'true'}, [
        config_element('server', '', {'name' => 'test', 'host' => 'unexisting.yaaaaaaaaaaaaaay.host.example.com'})
      ])
    @d = d = create_driver(conf)
    expected_log = "failed to resolve node name when configured"
    expected_detail = 'server="test" error_class=SocketError'
    logs = d.logs
    assert{ logs.any?{|log| log.include?(expected_log) && log.include?(expected_detail) } }
  end

  test 'compress_default_value' do
    @d = d = create_driver
    assert_equal :text, d.instance.compress

    node = d.instance.nodes.first
    assert_equal :text, node.instance_variable_get(:@compress)
  end

  test 'set_compress_is_gzip' do
    @d = d = create_driver(CONFIG + %[compress gzip])
    assert_equal :gzip, d.instance.compress
    assert_equal :gzip, d.instance.buffer.compress

    node = d.instance.nodes.first
    assert_equal :gzip, node.instance_variable_get(:@compress)
  end

  test 'set_compress_is_gzip_in_buffer_section' do
    mock = flexmock($log)
    mock.should_receive(:log).with("buffer is compressed.  If you also want to save the bandwidth of a network, Add `compress` configuration in <match>")

    @d = d = create_driver(CONFIG + %[
       <buffer>
         type memory
         compress gzip
       </buffer>
     ])
    assert_equal :text, d.instance.compress
    assert_equal :gzip, d.instance.buffer.compress

    node = d.instance.nodes.first
    assert_equal :text, node.instance_variable_get(:@compress)
  end

  test 'phi_failure_detector disabled' do
    @d = d = create_driver(CONFIG + %[phi_failure_detector false \n phi_threshold 0])
    node = d.instance.nodes.first
    stub(node.failure).phi { raise 'Should not be called' }
    node.tick
    assert_equal node.available, true
  end

  test 'phi_failure_detector enabled' do
    @d = d = create_driver(CONFIG + %[phi_failure_detector true \n phi_threshold 0])
    node = d.instance.nodes.first
    node.tick
    assert_equal node.available, false
  end

  test 'require_ack_response is disabled in default' do
    @d = d = create_driver(CONFIG)
    assert_equal false, d.instance.require_ack_response
    assert_equal 190, d.instance.ack_response_timeout
  end

  test 'require_ack_response can be enabled' do
    @d = d = create_driver(CONFIG + %[
      require_ack_response true
      ack_response_timeout 2s
    ])
    assert d.instance.require_ack_response
    assert_equal 2, d.instance.ack_response_timeout
  end

  test 'send tags in str (utf-8 strings)' do
    target_input_driver = create_target_input_driver

    @d = d = create_driver(CONFIG + %[flush_interval 1s])

    time = event_time("2011-01-02 13:14:15 UTC")

    tag_in_utf8 = "test.utf8".encode("utf-8")
    tag_in_ascii = "test.ascii".encode("ascii-8bit")

    emit_events = [
      [tag_in_utf8, time, {"a" => 1}],
      [tag_in_ascii, time, {"a" => 2}],
    ]

    target_input_driver.run(expect_records: 2) do
      d.run do
        emit_events.each do |tag, t, record|
          d.feed(tag, t, record)
        end
      end
    end

    events = target_input_driver.events
    assert_equal_event_time(time, events[0][1])
    assert_equal ['test.utf8', time, emit_events[0][2]], events[0]
    assert_equal Encoding::UTF_8, events[0][0].encoding
    assert_equal_event_time(time, events[1][1])
    assert_equal ['test.ascii', time, emit_events[1][2]], events[1]
    assert_equal Encoding::UTF_8, events[1][0].encoding

    assert_empty d.instance.exceptions
  end

  test 'send_with_time_as_integer' do
    target_input_driver = create_target_input_driver

    @d = d = create_driver(CONFIG + %[flush_interval 1s])

    time = event_time("2011-01-02 13:14:15 UTC")

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    target_input_driver.run(expect_records: 2) do
      d.run(default_tag: 'test') do
        records.each do |record|
          d.feed(time, record)
        end
      end
    end

    events = target_input_driver.events
    assert_equal_event_time(time, events[0][1])
    assert_equal ['test', time, records[0]], events[0]
    assert_equal_event_time(time, events[1][1])
    assert_equal ['test', time, records[1]], events[1]

    assert_empty d.instance.exceptions
  end

  test 'send_without_time_as_integer' do
    target_input_driver = create_target_input_driver

    @d = d = create_driver(CONFIG + %[
      flush_interval 1s
      time_as_integer false
    ])

    time = event_time("2011-01-02 13:14:15 UTC")

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    target_input_driver.run(expect_records: 2) do
      d.run(default_tag: 'test') do
        records.each do |record|
          d.feed(time, record)
        end
      end
    end

    events = target_input_driver.events
    assert_equal_event_time(time, events[0][1])
    assert_equal ['test', time, records[0]], events[0]
    assert_equal_event_time(time, events[1][1])
    assert_equal ['test', time, records[1]], events[1]

    assert_empty d.instance.exceptions
  end

  test 'send_comprssed_message_pack_stream_if_compress_is_gzip' do
    target_input_driver = create_target_input_driver

    @d = d = create_driver(CONFIG + %[
      flush_interval 1s
      compress gzip
    ])

    time = event_time('2011-01-02 13:14:15 UTC')

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    target_input_driver.run(expect_records: 2) do
      d.run(default_tag: 'test') do
        records.each do |record|
          d.feed(time, record)
        end
      end
    end

    event_streams = target_input_driver.event_streams
    assert_true event_streams[0][1].is_a?(Fluent::CompressedMessagePackEventStream)

    events = target_input_driver.events
    assert_equal ['test', time, records[0]], events[0]
    assert_equal ['test', time, records[1]], events[1]
  end

  test 'send_to_a_node_supporting_responses' do
    target_input_driver = create_target_input_driver

    @d = d = create_driver(CONFIG + %[flush_interval 1s])

    time = event_time("2011-01-02 13:14:15 UTC")

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    target_input_driver.run(expect_records: 2) do
      d.run(default_tag: 'test') do
        records.each do |record|
          d.feed(time, record)
        end
      end
    end

    events = target_input_driver.events
    assert_equal ['test', time, records[0]], events[0]
    assert_equal ['test', time, records[1]], events[1]

    assert_empty d.instance.response_chunk_ids # not attempt to receive responses, so it's empty
    assert_empty d.instance.exceptions
  end

  test 'send_to_a_node_not_supporting_responses' do
    target_input_driver = create_target_input_driver

    @d = d = create_driver(CONFIG + %[flush_interval 1s])

    time = event_time("2011-01-02 13:14:15 UTC")

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    target_input_driver.run(expect_records: 2) do
      d.run(default_tag: 'test') do
        records.each do |record|
          d.feed(time, record)
        end
      end
    end

    events = target_input_driver.events
    assert_equal ['test', time, records[0]], events[0]
    assert_equal ['test', time, records[1]], events[1]

    assert_empty d.instance.response_chunk_ids # not attempt to receive responses, so it's empty
    assert_empty d.instance.exceptions
  end

  test 'a node supporting responses' do
    target_input_driver = create_target_input_driver

    @d = d = create_driver(CONFIG + %[
      require_ack_response true
      ack_response_timeout 1s
      <buffer tag>
        flush_mode immediate
        retry_type periodic
        retry_wait 30s
        flush_at_shutdown false # suppress errors in d.instance_shutdown
      </buffer>
    ])

    time = event_time("2011-01-02 13:14:15 UTC")

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    target_input_driver.run(expect_records: 2) do
      d.end_if{ d.instance.response_chunk_ids.length > 0 }
      d.run(default_tag: 'test', wait_flush_completion: false, shutdown: false) do
        d.feed([[time, records[0]], [time,records[1]]])
      end
    end

    events = target_input_driver.events
    assert_equal ['test', time, records[0]], events[0]
    assert_equal ['test', time, records[1]], events[1]

    assert_equal 1, d.instance.response_chunk_ids.size
    assert_equal d.instance.sent_chunk_ids.first, d.instance.response_chunk_ids.first
    assert_empty d.instance.exceptions
  end

  test 'a destination node not supporting responses by just ignoring' do
    target_input_driver = create_target_input_driver(response_stub: ->(_option) { nil }, disconnect: false)

    @d = d = create_driver(CONFIG + %[
      require_ack_response true
      ack_response_timeout 1s
      <buffer tag>
        flush_mode immediate
        retry_type periodic
        retry_wait 30s
        flush_at_shutdown false # suppress errors in d.instance_shutdown
      </buffer>
    ])

    node = d.instance.nodes.first
    delayed_commit_timeout_value = nil

    time = event_time("2011-01-02 13:14:15 UTC")

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    target_input_driver.end_if{ d.instance.rollback_count > 0 }
    target_input_driver.end_if{ !node.available }
    target_input_driver.run(expect_records: 2, timeout: 25) do
      d.run(default_tag: 'test', timeout: 20, wait_flush_completion: false, shutdown: false) do
        delayed_commit_timeout_value = d.instance.delayed_commit_timeout
        d.feed([[time, records[0]], [time,records[1]]])
      end
    end

    assert_equal (1 + 2), delayed_commit_timeout_value

    events = target_input_driver.events
    assert_equal ['test', time, records[0]], events[0]
    assert_equal ['test', time, records[1]], events[1]

    assert{ d.instance.rollback_count > 0 }

    logs = d.instance.log.logs
    assert{ logs.any?{|log| log.include?("no response from node. regard it as unavailable.") } }
  end

  test 'a destination node not supporting responses by disconnection' do
    target_input_driver = create_target_input_driver(response_stub: ->(_option) { nil }, disconnect: true)

    @d = d = create_driver(CONFIG + %[
      require_ack_response true
      ack_response_timeout 5s
      <buffer tag>
        flush_mode immediate
        retry_type periodic
        retry_wait 30s
        flush_at_shutdown false # suppress errors in d.instance_shutdown
      </buffer>
    ])

    node = d.instance.nodes.first
    delayed_commit_timeout_value = nil

    time = event_time("2011-01-02 13:14:15 UTC")

    records = [
      {"a" => 1},
      {"a" => 2}
    ]
    target_input_driver.end_if{ d.instance.rollback_count > 0 }
    target_input_driver.end_if{ !node.available }
    target_input_driver.run(expect_records: 2, timeout: 25) do
      d.run(default_tag: 'test', timeout: 20, wait_flush_completion: false, shutdown: false) do
        delayed_commit_timeout_value = d.instance.delayed_commit_timeout
        d.feed([[time, records[0]], [time,records[1]]])
      end
    end

    assert_equal (5 + 2), delayed_commit_timeout_value

    events = target_input_driver.events
    assert_equal ['test', time, records[0]], events[0]
    assert_equal ['test', time, records[1]], events[1]

    assert{ d.instance.rollback_count > 0 }

    logs = d.instance.log.logs
    assert{ logs.any?{|log| log.include?("no response from node. regard it as unavailable.") } }
  end

  test 'authentication_with_shared_key' do
    input_conf = TARGET_CONFIG + %[
                   <security>
                     self_hostname in.localhost
                     shared_key fluentd-sharedkey
                     <client>
                       host 127.0.0.1
                     </client>
                   </security>
                 ]
    target_input_driver = create_target_input_driver(conf: input_conf)

    output_conf = %[
      send_timeout 51
      <security>
        self_hostname localhost
        shared_key fluentd-sharedkey
      </security>
      <server>
        name test
        host #{TARGET_HOST}
        port #{TARGET_PORT}
        shared_key fluentd-sharedkey
      </server>
    ]
    @d = d = create_driver(output_conf)

    time = event_time("2011-01-02 13:14:15 UTC")
    records = [
      {"a" => 1},
      {"a" => 2}
    ]

    target_input_driver.run(expect_records: 2, timeout: 15) do
      d.run(default_tag: 'test') do
        records.each do |record|
          d.feed(time, record)
        end
      end
    end

    events = target_input_driver.events
    assert{ events != [] }
    assert_equal(['test', time, records[0]], events[0])
    assert_equal(['test', time, records[1]], events[1])
  end

  test 'authentication_with_user_auth' do
    input_conf = TARGET_CONFIG + %[
                   <security>
                     self_hostname in.localhost
                     shared_key fluentd-sharedkey
                     user_auth true
                     <user>
                       username fluentd
                       password fluentd
                     </user>
                     <client>
                       host 127.0.0.1
                     </client>
                   </security>
                 ]
    target_input_driver = create_target_input_driver(conf: input_conf)

    output_conf = %[
      send_timeout 51
      <security>
        self_hostname localhost
        shared_key fluentd-sharedkey
      </security>
      <server>
        name test
        host #{TARGET_HOST}
        port #{TARGET_PORT}
        shared_key fluentd-sharedkey
        username fluentd
        password fluentd
      </server>
    ]
    @d = d = create_driver(output_conf)

    time = event_time("2011-01-02 13:14:15 UTC")
    records = [
      {"a" => 1},
      {"a" => 2}
    ]

    target_input_driver.run(expect_records: 2, timeout: 15) do
      d.run(default_tag: 'test') do
        records.each do |record|
          d.feed(time, record)
        end
      end
    end

    events = target_input_driver.events
    assert{ events != [] }
    assert_equal(['test', time, records[0]], events[0])
    assert_equal(['test', time, records[1]], events[1])
  end

  def create_target_input_driver(response_stub: nil, disconnect: false, conf: TARGET_CONFIG)
    require 'fluent/plugin/in_forward'

    # TODO: Support actual TCP heartbeat test
    Fluent::Test::Driver::Input.new(Fluent::Plugin::ForwardInput) {
      if response_stub.nil?
        # do nothing because in_forward responds for ack option in default
      else
        define_method(:response) do |options|
          return response_stub.(options)
        end
      end
    }.configure(conf)
  end

  test 'heartbeat_type_none' do
    @d = d = create_driver(CONFIG + "\nheartbeat_type none")
    node = d.instance.nodes.first
    assert_equal Fluent::Plugin::ForwardOutput::NoneHeartbeatNode, node.class

    d.instance_start
    assert_nil d.instance.instance_variable_get(:@loop)   # no HeartbeatHandler, or HeartbeatRequestTimer
    assert_nil d.instance.instance_variable_get(:@thread) # no HeartbeatHandler, or HeartbeatRequestTimer

    stub(node.failure).phi { raise 'Should not be called' }
    node.tick
    assert_equal node.available, true
  end

  test 'heartbeat_type_udp' do
    @d = d = create_driver(CONFIG + "\nheartbeat_type udp")

    d.instance_start
    usock = d.instance.instance_variable_get(:@usock)
    servers = d.instance.instance_variable_get(:@_servers)
    timers = d.instance.instance_variable_get(:@_timers)
    assert_equal UDPSocket, usock.class
    assert servers.find{|s| s.title == :out_forward_heartbeat_receiver }
    assert timers.include?(:out_forward_heartbeat_request)

    mock(usock).send("\0", 0, Socket.pack_sockaddr_in(TARGET_PORT, '127.0.0.1')).once
    d.instance.send(:on_timer)
  end

  test 'acts_as_secondary' do
    i = Fluent::Plugin::ForwardOutput.new
    conf = config_element(
      'match',
      'primary.**',
      {'@type' => 'forward'},
      [
        config_element('server', '', {'host' => '127.0.0.1'}),
        config_element('secondary', '', {}, [
            config_element('server', '', {'host' => '192.168.1.2'}),
            config_element('server', '', {'host' => '192.168.1.3'})
          ]),
      ]
    )
    assert_nothing_raised do
      i.configure(conf)
    end
  end
end
