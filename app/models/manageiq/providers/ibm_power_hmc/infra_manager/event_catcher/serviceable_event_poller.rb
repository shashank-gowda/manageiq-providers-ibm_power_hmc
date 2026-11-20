require 'net/http'
require 'uri'
require 'json'
require_relative '../utility/xml_to_json_transformer'

# Encapsulates the periodic polling of IBM HMC Serviceable Events.
#
# Called from Stream#poll on each loop iteration; responsible for:
#   1. Deciding whether the configured poll interval has elapsed.
#   2. Fetching raw XML from the HMC via +connection.fetch_serviceable_events_xml+.
#   3. Parsing each feed entry and persisting an EmsEvent record via EmsEvent.add_queue.
#
class ManageIQ::Providers::IbmPowerHmc::InfraManager::EventCatcher::ServiceableEventPoller
  POLL_INTERVAL = 600 # seconds between successive serviceable-event fetches

  def initialize(ems)
    @ems          = ems
    @last_poll    = Time.now.utc.to_i - POLL_INTERVAL
    # Tracks keys queued in previous poll cycles that may not yet be visible
    # through the API (e.g. still being processed by the worker queue).
    # Prevents re-queueing between the moment a record is enqueued and the
    # moment it becomes visible in the REST API response.
    @pending_keys = Set.new
  end

  # Poll serviceable events if the interval has elapsed.
  #
  # @param connection [IbmPowerHmc::Connection]  active HMC connection from Stream#poll
  def poll(connection)
    now = Time.now.utc.to_i
    return unless now >= @last_poll + POLL_INTERVAL

    @last_poll = now
    fetch_and_process(connection)
  end

  private

  def fetch_and_process(connection)
    sem_xml = connection.serviceable_events_search
    return if sem_xml.blank?

    feed = ManageIQ::Providers::IbmPowerHmc::InfraManager::XmlToJsonTransformer.transform(sem_xml)
    process_entries(feed)
  end

  def process_entries(feed)
    entries = feed.dig("feed", "entries") || []
    return if entries.empty?

    # ── ONE bulk SELECT for the entire batch ──────────────────────────────────
    # Fetch message + last_reported_timestamp for all already-persisted
    # ServiceableEvents for this EMS.  The first level is the composite key
    # "prob_uuid_problem_state" (message); the second level is the set of
    # last_reported_timestamp values already stored for that message.  An event
    # already exists only when BOTH match, so a change of only
    # lastReportedTimestamp upstream is detected as a new version.
    # message => Set of timestamp keys already stored
    existing_keys = Hash.new { |h, k| h[k] = Set.new }
    EmsEvent.where(:ems_id => @ems.id, :event_type => "ServiceableEvent", :source => "IBM_POWER_HMC")
            .pluck(:message, :last_reported_timestamp)
            .each { |msg, ts| existing_keys[msg] << ts_key(ts) }

    entries.each { |entry| upsert_entry(entry, existing_keys) }
  end

  # Process a single feed entry using the pre-fetched key set.
  # No DB reads happen here — all decisions are made from the in-memory set.
  def upsert_entry(entry, existing_keys)
    sem       = entry.dig("content", "ServiceableEvent") || {}
    entry_id  = entry["id"]
    published = entry["published"]

    # ── Mapped columns ────────────────────────────────────────────────────────
    # message   → Problem UUID + "_" + Problem State (e.g. d8d65290-..._OPEN)
    # host_name → Failing Console MTMS  (machtype-model*serial)
    # vm_name   → Partition Name
    prob_uuid     = extract_value(sem["problemUuid"])
    problem_state = extract_value(sem["problemState"])
    failing_mtms  = build_failing_mtms(sem)
    lpar_name     = extract_value(sem["partitionName"])

    sem_data = {
      :problem_uuid              => prob_uuid,
      :problem_number            => sem.dig("problemNumber", "_value"),
      :problem_state             => problem_state,
      :event_severity            => sem.dig("eventSeverity", "_value"),
      :reference_code            => sem.dig("referenceCode", "_value"),
      :reference_code_extension  => extract_value(sem["referenceCodeExtension"]),
      :system_reference_code     => extract_value(sem["systemReferenceCode"]),
      :notification_type         => sem.dig("notificationType", "_value"),
      :notification_status       => extract_value(sem["notificationStatus"]),
      :symptom_string            => sem.dig("symptomString", "_value"),
      :short_description         => sem.dig("shortDescription", "_value"),
      :duplicate_count           => sem.dig("duplicateCount", "_value"),
      :platform_log_id           => sem.dig("platformLogId", "_value"),
      :approval_state            => extract_value(sem["ApprovalState"]),
      :call_home_enabled         => extract_value(sem["callHomeEnabled"]),
      :post_action               => extract_value(sem["postAction"]),
      :hw_record                 => extract_value(sem["problemManagementHardwareRecord"]),
      :total_events              => extract_value(sem["totalEvents"]),
      :syslog_id                 => extract_value(sem["sysLogId"]),
      :primary_timestamp         => extract_value(sem["primaryTimestamp"]),
      :created_timestamp         => extract_value(sem["createdTimestamp"]),
      :first_reported_timestamp  => extract_value(sem["firstReportedTimestamp"]),
      :last_reported_timestamp   => extract_value(sem["lastReportedTimestamp"]),
      :failing_mtms              => failing_mtms,
      :reporting_console_host    => sem.dig("reportingConsoleNode", "hostName"),
      :partition_id              => extract_value(sem["partitionId"]),
      :partition_name            => lpar_name,
      :partition_hostname        => extract_value(sem["partitionHostName"]),
      :partition_os_type         => extract_value(sem["partitionOSType"]),
      :frus                      => sem.dig("fieldReplaceableUnits", "FieldReplaceableUnit"),
      :src_extension_data        => sem["srcExtnData"],
      :extended_error_files      => sem.dig("extendedErrorData", "ExtendedFileData"),
      :service_history           => sem.dig("serviceHistoryData", "ServiceHistory")
    }

    # lastReportedTimestamp is epoch milliseconds, stored as an integer in
    # event_streams.last_reported_timestamp.
    last_reported = parse_epoch_ms(sem["lastReportedTimestamp"])

    event_hash = {
      :event_type              => "ServiceableEvent",
      :source                  => "IBM_POWER_HMC",
      :ems_ref                 => entry_id,
      :timestamp               => published,
      :last_reported_timestamp => last_reported,
      :message                 => "#{prob_uuid}_#{problem_state}",
      :host_name               => failing_mtms,
      :vm_name                 => lpar_name,
      :full_data               => sem_data,
      :ems_id                  => @ems.id
    }

    # In-memory check — no DB hit.  First level: message
    # ("prob_uuid_problem_state"); second level: last_reported_timestamp.
    message_key = "#{prob_uuid}_#{problem_state}"
    ts          = ts_key(last_reported)
    return if existing_keys.key?(message_key) && existing_keys[message_key].include?(ts)

    EmsEvent.add_queue('add', @ems.id, event_hash)
    existing_keys[message_key] << ts
  end

  # Canonical string used to compare last_reported_timestamp values.
  def ts_key(value)
    value&.to_s
  end

  # Parse an epoch-milliseconds node into an Integer; nil when absent/invalid.
  def parse_epoch_ms(node)
    str = extract_value(node).to_s.strip
    str.match?(/\A\d+\z/) ? str.to_i : nil
  end

  # Extract the plain string value from a transformer node.
  # Plain leaf elements are already a String (or nil).
  def extract_value(node)
    node.kind_of?(Hash) ? node["_value"] : node
  end

  # Build the Failing Console MTMS string from the transformer-produced SEM hash.
  # The transformer converts the XML directly to nested string-keyed hashes, so
  # failingManagedSystemNode/managedTypeModelSerial/{MachineType,Model,SerialNumber}
  # are already present — we just concatenate them the same way the SDK does.
  # Returns nil when the node is absent entirely.
  def build_failing_mtms(sem)
    node     = sem.dig("failingManagedSystemNode", "managedTypeModelSerial") || {}
    machtype = extract_value(node["MachineType"])
    model    = extract_value(node["Model"])
    serial   = extract_value(node["SerialNumber"])
    return nil if machtype.nil? && model.nil? && serial.nil?

    "#{machtype}-#{model}*#{serial}"
  end
end