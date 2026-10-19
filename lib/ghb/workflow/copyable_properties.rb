# frozen_string_literal: true

module GHB
  module CopyableProperties
    def copy_properties(object, properties = self.class::COPYABLE_PROPERTIES)
      return if object.nil?

      properties.each do |property|
        raise(ArgumentError, "#{object.class} does not have a #{property} property") unless object.respond_to?(property)

        public_send(:"#{property}=", object.public_send(property))
      end
    end
  end
end
