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

    # ── Fetch existing events from the ManageIQ REST API ─────────────────────
    # Scoped to this EMS (ems_id filter) and paginated to cover all records.
    api_resources = fetch_api_event_streams

    # Build a Set of known message keys from the API response.
    # Presence of "#{prob_uuid}_#{problem_state}" means the record already exists.
    api_message_keys = api_resources.each_with_object(Set.new) do |resource, set|
      set << resource["message"] if resource["message"]
    end

    # Retire any pending keys that are now confirmed visible in the API —
    # they have been persisted and no longer need in-memory protection.
    @pending_keys.subtract(api_message_keys)

    # queued_keys tracks message keys added during this batch so that duplicate
    # HMC entries within the same feed are not queued more than once.
    queued_keys = Set.new

    entries.each { |entry| upsert_entry(entry, api_message_keys, queued_keys) }
  end

  # Process a single feed entry using the pre-fetched API message key set.
  # No DB reads happen here — presence of the message key means the record exists.
  def upsert_entry(entry, api_message_keys, queued_keys)
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
      :problem_uuid         => prob_uuid,
      :problem_number       => sem.dig("problemNumber", "_value"),
      :problem_state        => problem_state,
      :event_severity       => sem.dig("eventSeverity", "_value"),
      :reference_code       => sem.dig("referenceCode", "_value"),
      :notification_type    => sem.dig("notificationType", "_value"),
      :symptom_string       => sem.dig("symptomString", "_value"),
      :short_description    => sem.dig("shortDescription", "_value"),
      :duplicate_count      => sem.dig("duplicateCount", "_value"),
      :platform_log_id      => sem.dig("platformLogId", "_value"),
      :failing_mtms         => failing_mtms,
      :partition_name       => lpar_name,
      :src_extension_data   => sem["srcExtnData"],
      :extended_error_files => sem.dig("extendedErrorData", "ExtendedFileData"),
      :service_history      => sem.dig("serviceHistoryData", "ServiceHistory")
    }

    event_hash = {
      :event_type => "ServiceableEvent",
      :source     => "IBM_POWER_HMC",
      :ems_ref    => entry_id,
      :timestamp  => published,
      :message    => "#{prob_uuid}_#{problem_state}",
      :host_name  => failing_mtms,
      :vm_name    => lpar_name,
      :full_data  => sem_data,
      :ems_id     => @ems.id
    }

    # O(1) membership check — skip if the key is known via any of three guards:
    #   1. api_message_keys — already persisted and visible in the REST API.
    #   2. @pending_keys    — queued in a previous poll but not yet visible in API.
    #   3. queued_keys      — queued earlier in this same batch (intra-batch duplicate).
    message_key = "#{prob_uuid}_#{problem_state}"

    return if api_message_keys.include?(message_key) ||
              @pending_keys.include?(message_key)     ||
              queued_keys.include?(message_key)

    queued_keys   << message_key
    @pending_keys << message_key
    EmsEvent.add_queue('add', @ems.id, event_hash)
  end

  # Call the ManageIQ REST API to retrieve all ServiceableEvent streams for
  # this specific EMS, paginating through all pages.
  #
  # Base URL is derived from the provider's own hostname — no hardcoding.
  # Scoping by ems_id ensures events from other providers do not pollute the key set.
  #
  # @return [Array] complete list of resource hashes, or [] on error
  def fetch_api_event_streams
    base_url  = "https://#{@ems.hostname}"
    page_size = 500
    offset    = 0
    all_resources = []

    loop do
      uri = URI("#{base_url}/api/event_streams")
      uri.query = URI.encode_www_form(
        [
          ["expand",   "resources"],
          ["limit",    page_size],
          ["offset",   offset],
          ["filter[]", "event_type='ServiceableEvent'"],
          ["filter[]", "ems_id=#{@ems.id}"]
        ]
      )

      req           = Net::HTTP::Get.new(uri)
      req["Accept"] = "application/json"

      validate_ssl = @ems.security_protocol == "ssl-no-validation"
      response     = Net::HTTP.start(uri.host, uri.port, :use_ssl => false) do |http|
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE unless validate_ssl
        http.request(req)
      end

      data      = JSON.parse(response.body)
      page      = data["resources"] || []
      all_resources.concat(page)

      # Stop when the page is smaller than the requested size — no more pages.
      break if page.size < page_size

      offset += page_size
    end

    all_resources
  rescue => e
    $ibm_power_hmc_log.error("ServiceableEventPoller: REST API call failed — #{e.class}: #{e.message}")
    []
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