# frozen_string_literal: true

module ActionCableClient
  # The headers an upgrade request carries, as a plain hash of one value per
  # name. HTTP names are case-insensitive, so every lookup here is too, and a
  # name is written out exactly as the caller spelled it.
  module Headers
    def self.normalize(header)
      (header || {}).to_h { |name, value| [ name.to_s, value.to_s ] }
    end

    def self.get(header, name)
      _, value = header.find { |key, _| key.casecmp?(name) }
      value
    end

    # Sets one header, replacing whatever was there under any spelling of the
    # same name.
    def self.put(header, name, value)
      delete(header, name)
      header[name] = value
      header
    end

    def self.delete(header, name)
      header.delete_if { |key, _| key.casecmp?(name) }
      header
    end

    # Lays one set of headers over another, so a name in both takes the value
    # from the top.
    def self.merge(base, overrides)
      normalize(overrides).each_with_object(base.dup) { |(name, value), merged| put(merged, name, value) }
    end
  end
end
