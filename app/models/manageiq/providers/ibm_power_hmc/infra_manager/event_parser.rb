module ManageIQ::Providers::IbmPowerHmc::InfraManager::EventParser
  def self.event_to_hash(event, ems_id)
    event_hash = {
      :event_type => event.type,
      :source     => 'IBM_POWER_HMC',
      :ems_ref    => event.id,
      :timestamp  => event.published,
      :message    => event.detail,

      # Serialize IbmPowerHmc::Event
      :full_data  => {
        :data     => event.data,
        :detail   => event.detail,
        :usertask => event.usertask
      },

      :ems_id => ems_id
    }

    elems = URI(event.data).path.split('/')
    type, uuid = elems[-2], elems[-1]

    # Check if the URI also contains /ManagedSystem/{uuid}/
    if elems.length >= 4 && elems[-4] == "ManagedSystem"
      host_uuid = elems[-3]
    end

    case type
    when "ManagedSystem"
      event_hash[:host_ems_ref] = uuid
    when "LogicalPartition", "VirtualIOServer"
      event_hash[:vm_ems_ref]   = uuid
      event_hash[:host_ems_ref] = host_uuid unless host_uuid.nil?
    when "VirtualSwitch", "VirtualNetwork", "SharedProcessorPool", "SharedMemoryPool"
      event_hash[:host_ems_ref] = host_uuid unless host_uuid.nil?
    when "UserTask"
      event_hash[:message] = event.usertask["key"]
    end

    event_hash
  end

  # Build an event_hash for a single Serviceable Event (SEM) feed entry.
  #
  # @param entry  [Hash]    one element from feed["feed"]["entries"] as produced
  #                         by XmlToJsonTransformer
  # @param ems_id [Integer] id of the owning ExtManagementSystem record
  # @return [Hash]          event_hash ready to pass to EmsEvent.add
  def self.sem_entry_to_hash(entry, ems_id)
    sem       = entry.dig("content", "ServiceableEvent") || {}
    prob_num  = sem.dig("problemNumber", "_value")
    entry_id  = entry["id"]
    published = entry["published"]

    {
      :event_type => "ServiceableEvent",
      :source     => "IBM_POWER_HMC",
      :ems_ref    => entry_id,
      :timestamp  => published,
      :message    => "ServiceableEvent problemNumber=#{prob_num}",

      # Store complete SEM payload for downstream processing/comparison
      :full_data  => entry,

      :ems_id => ems_id
    }
  end
  
  def self.custom_event(event, ems_id)
    return nil if event.detail&.include?('"messageID":"FCS.0021"')
    
    return nil unless event.type == "MODIFY_URI"

    event_type, matched_pairs = resolve_modify_uri_event_type(event)
    return nil if event_type.nil?

    # Build message from the matched attribute key:value pairs from EventValue
    message = matched_pairs.map { |k, v| "#{k}:#{v}" }.join(',')

    event_hash = {
      :event_type => event_type,
      :source     => 'IBM_POWER_HMC',
      :ems_ref    => event.id,
      :timestamp  => event.published,
      :message    => message,
      :full_data  => {:data => event.data, :detail => event.detail},
      :ems_id     => ems_id
    }

    elems = URI(event.data).path.split('/')
    type, uuid = elems[-2], elems[-1]

    if elems.length >= 4 && elems[-4] == "ManagedSystem"
      host_uuid = elems[-3]
    end

    case type
    when "ManagedSystem"
      event_hash[:host_ems_ref] = uuid
    when "LogicalPartition", "VirtualIOServer"
      event_hash[:vm_ems_ref]   = uuid
      event_hash[:host_ems_ref] = host_uuid unless host_uuid.nil?
    end

    event_hash
  end

  # Parses event.detail and event.value for a MODIFY_URI event.
  # Returns [event_type_string, matched_value_pairs_hash] when a watched
  # attribute matches a trigger value, or [nil, nil] when no override applies.
  def self.resolve_modify_uri_event_type(event)

    detail_attrs = event.detail.to_s.split(',').map(&:strip)

    raw_value = event.value.to_s

    value_pairs = raw_value
                    .split(',')
                    .map { |pair| pair.split(':', 2) }
                    .tap { |pairs| _log.info("resolve_modify_uri_event_type: split pairs=#{pairs.inspect}") }
                    .select { |kv| kv.length == 2 }
                    .to_h

    overrides = Settings.ems.ems_ibm_power_hmc.modify_uri_attribute_overrides.to_h
    overrides.each do |attr, config|
      attr   = attr.to_s
      config = config.to_h
      matched = detail_attrs.include?(attr)
      _log.info("resolve_modify_uri_event_type: checking attr=#{attr} present=#{matched}")
      next unless matched

      attr_value = value_pairs[attr]
      if config[:values].any? { |v| v.to_s.casecmp?(attr_value.to_s) }
        return ["MODIFY_URI_#{config[:suffix]}", {attr => attr_value}]
      end
    end

    [nil, nil]
  end
end
