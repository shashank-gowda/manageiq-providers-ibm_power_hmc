class ManageIQ::Providers::IbmPowerHmc::InfraManager::EventCatcher::Stream
  def initialize(ems, options = {})
    @ems                = ems
    @stop_polling       = false
    @options            = options
    @serviceable_poller = serviceable_event_poller
  end

  def start
    @stop_polling = false
  end

  def stop
    @stop_polling = true
  end

  # Continuous polling loop — runs until stop() is called.
  # Each iteration calls both pollers in sequence:
  #   - poll_uom_events        : called every iteration, frequency driven by HMC response time
  #   - poll_serviceable_events: called every iteration but internally throttled to
  #                              once every ServiceableEventPoller::POLL_INTERVAL seconds (600s)
  def poll(&)
    @ems.with_provider_connection do |connection|
      until @stop_polling
        events = poll_uom_events(connection, &)
        poll_serviceable_events(connection)
        sleep(@options[:poll_sleep]) if events.blank?
      end
    end
  end

  private

  # Fetches UOM events (ADD_URI, MODIFY_URI, DELETE_URI) from the HMC on every call.
  def poll_uom_events(connection, &)
    events = connection.next_events(false).select { |event| event.type.in?(%w[ADD_URI MODIFY_URI DELETE_URI]) }
    events.each(&)
    events
  rescue IbmPowerHmc::Connection::HttpError => err
    $ibm_power_hmc_log.error("querying hmc events failed: #{err}")
    []
  rescue => err
    $ibm_power_hmc_log.error("#{err.class}: #{err.message}")
    []
  end

  # Delegates to ServiceableEventPoller — no-op if POLL_INTERVAL has not elapsed.
  def poll_serviceable_events(connection)
    @serviceable_poller.poll(connection)
  rescue => err
    $ibm_power_hmc_log.error("serviceable events poll failed: #{err.class}: #{err.message}")
  end

  def serviceable_event_poller
    self.class.module_parent::ServiceableEventPoller.new(@ems)
  end
end
