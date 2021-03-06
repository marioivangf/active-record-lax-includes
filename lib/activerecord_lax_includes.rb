module ActiveRecordLaxIncludes
  def lax_includes
    Thread.current[:active_record_lax_includes_enabled] = true
    yield
  ensure
    Thread.current[:active_record_lax_includes_enabled] = false
  end

  def lax_includes_enabled?
    result = Thread.current[:active_record_lax_includes_enabled]
    if result.nil?
      result = Rails.configuration.respond_to?(:active_record_lax_includes_enabled) &&
                  Rails.configuration.active_record_lax_includes_enabled
    end
    result
  end

  module Base
    def association(name)
      association = association_instance_get(name)

      if association.nil?
        if reflection = self.class._reflect_on_association(name)
          association = reflection.association_class.new(self, reflection)
          association_instance_set(name, association)
        elsif !ActiveRecord.lax_includes_enabled?
          raise ActiveRecord::AssociationNotFoundError.new(self, name)
        end
      end

      association
    end
  end

  module Preloader
    private

    def preloaders_on(association, records, scope, options = {})
      case association
      when Hash
        preloaders_for_hash(association, records, scope, options)
      when Symbol
        preloaders_for_one(association, records, scope, options)
      when String
        preloaders_for_one(association.to_sym, records, scope, options)
      else
        raise ArgumentError, "#{association.inspect} was not recognised for preload"
      end
    end

    def preloaders_for_hash(association, records, scope, options = {})
      association.flat_map { |parent, child|
        loaders = preloaders_for_one parent, records, scope, options
        polymorphic = options[:polymorphic] || loaders.any? do |l|
          l.respond_to?(:reflection) && l.reflection.polymorphic?
        end

        recs = loaders.flat_map(&:preloaded_records).uniq
        loaders.concat Array.wrap(child).flat_map { |assoc|
          preloaders_on assoc, recs, scope, polymorphic: polymorphic
        }
        loaders
      }
    end

    def preloaders_for_one(association, records, scope, options = {})
      grouped = grouped_records(association, records)
      if !ActiveRecord.lax_includes_enabled? && records.any? && grouped.none? && !options[:polymorphic]
        raise ActiveRecord::AssociationNotFoundError.new(records.first, association)
      end

      grouped.flat_map do |reflection, klasses|
        klasses.map do |rhs_klass, rs|
          loader = preloader_for(reflection, rs, rhs_klass).new(rhs_klass, rs, reflection, scope)
          loader.run self
          loader
        end
      end
    end

    def grouped_records(association, records)
      h = {}
      records.each do |record|
        if record && assoc = record.association(association)
          klasses = h[assoc.reflection] ||= {}
          (klasses[assoc.klass] ||= []) << record
        end
      end
      h
    end
  end
end

require 'active_record'

ActiveRecord.send(:extend, ActiveRecordLaxIncludes)
ActiveRecord::Base.send(:prepend, ActiveRecordLaxIncludes::Base)
ActiveRecord::Associations::Preloader.send(:prepend, ActiveRecordLaxIncludes::Preloader)
