module PaperTrail
  module Model

    def self.included(base)
      base.send :extend, ClassMethods
    end


    module ClassMethods
      # Declare this in your model to track every create, update, and destroy.  Each version of
      # the model is available in the `versions` association.
      #
      # Options:
      # :on           the events to track (optional; defaults to all of them).  Set to an array of
      #               `:create`, `:update`, `:destroy` as desired.
      # :class_name   the name of a custom Version class.  This class should inherit from Version.
      # :ignore       an array of attributes for which a new `Version` will not be created if only they change.
      # :only         inverse of `ignore` - a new `Version` will be created only for these attributes if supplied
      # :meta         a hash of extra data to store.  You must add a column to the `versions` table for each key.
      #               Values are objects or procs (which are called with `self`, i.e. the model with the paper
      #               trail).  See `PaperTrail::Controller.info_for_paper_trail` for how to store data from
      #               the controller.
      # :versions     the name to use for the versions association.  Default is `:versions`.
      def has_paper_trail(options = {})
        # Lazily include the instance methods so we don't clutter up
        # any more ActiveRecord models than we have to.
        send :include, InstanceMethods

        # The version this instance was reified from.
        attr_accessor :version

        class_attribute :version_class_name
        self.version_class_name = options[:class_name] || 'Version'

        class_attribute :ignore
        self.ignore = ([options[:ignore]].flatten.compact || []).map &:to_s

        class_attribute :only
        self.only = ([options[:only]].flatten.compact || []).map &:to_s

        class_attribute :meta
        self.meta = options[:meta] || {}

        class_attribute :track_columns
        self.track_columns = options[:track_columns] || true

        class_attribute :ignored_columns
        self.ignored_columns = options[:ignored_columns] || ['id', 'updated_at', 'created_at']

        class_attribute :paper_trail_enabled_for_model
        self.paper_trail_enabled_for_model = true

        class_attribute :versions_association_name
        self.versions_association_name = options[:versions] || :versions

        has_many self.versions_association_name,
                 :class_name => version_class_name,
                 :as         => :item,
                 :order      => "created_at ASC, #{self.version_class_name.constantize.primary_key} ASC"

        after_create  :record_create  if !options[:on] || options[:on].include?(:create)
        before_update :record_update  if !options[:on] || options[:on].include?(:update)
        after_destroy :record_destroy if !options[:on] || options[:on].include?(:destroy)
      end

      # Switches PaperTrail off for this class.
      def paper_trail_off
        self.paper_trail_enabled_for_model = false
      end

      # Switches PaperTrail on for this class.
      def paper_trail_on
        self.paper_trail_enabled_for_model = true
      end
    end

    # Wrap the following methods in a module so we can include them only in the
    # ActiveRecord models that declare `has_paper_trail`.
    module InstanceMethods
      # Returns true if this instance is the current, live one;
      # returns false if this instance came from a previous version.
      def live?
        version.nil?
      end

      # Returns who put the object into its current state.
      def originator
        version_class.with_item_keys(self.class.name, id).last.try :whodunnit
      end

      # Returns the object (not a Version) as it was at the given timestamp.
      def version_at(timestamp, reify_options={})
        # Because a version stores how its object looked *before* the change,
        # we need to look for the first version created *after* the timestamp.
        version = send(self.class.versions_association_name).after(timestamp).first
        version ? version.reify(reify_options) : self
      end

      # Returns the object (not a Version) as it was most recently.
      def previous_version
        preceding_version = version ? version.previous : send(self.class.versions_association_name).last
        preceding_version.try :reify
      end

      # Returns the object (not a Version) as it became next.
      def next_version
        # NOTE: if self (the item) was not reified from a version, i.e. it is the
        # "live" item, we return nil.  Perhaps we should return self instead?
        subsequent_version = version ? version.next : nil
        subsequent_version.reify if subsequent_version
      end

      # Executes the given method or block without creating a new version.
      def without_versioning(method = nil)
        paper_trail_was_enabled = self.paper_trail_enabled_for_model
        self.class.paper_trail_off
        method ? method.to_proc.call(self) : yield
      ensure
        self.class.paper_trail_on if paper_trail_was_enabled
      end

      private

      def version_class
        version_class_name.constantize
      end

      def record_create
        if switched_on?
          send(self.class.versions_association_name).create merge_metadata(:event => 'create', :whodunnit => PaperTrail.whodunnit)
        end
      end

      def record_update
        if switched_on? && changed_notably?
          data = {
            :event     => 'update',
            :object    => object_to_string(item_before_change),
            :whodunnit => PaperTrail.whodunnit
          }
          
          if version_class.column_names.include? 'object_changes'
            # The double negative (reject, !include?) preserves the hash structure of self.changes.
            data[:object_changes] = self.changes.reject do |key, value|
              !notably_changed.include?(key)
            end.to_yaml
          end
          send(self.class.versions_association_name).build merge_metadata(data)
        end
      end

      def record_destroy
        if switched_on? and not new_record?
          version_class.create merge_metadata(:item_id   => self.id,
                                              :item_type => self.class.base_class.name,
                                              :event     => 'destroy',
                                              :object    => object_to_string(item_before_change),
                                              :whodunnit => PaperTrail.whodunnit)
        end
        send(self.class.versions_association_name).send :load_target
      end

      def merge_metadata(data)
        # First we merge the model-level metadata in `meta`.
        meta.each do |k,v|
          data[k] =
            if v.respond_to?(:call)
              v.call(self)
            elsif v.is_a?(Symbol) && respond_to?(v)
              send(v)
            else
              v
            end
        end
        # Second we merge any extra data from the controller (if available).
        data.merge(PaperTrail.controller_info || {})
        
        column_changes = {}
        change_info = changes.dup
        change_info.reject! { |column_name, change_values|
          self.class.ignored_columns.include?(column_name)
        }

        change_info.each do |column_name, change_values|
          column_changes[column_name.to_sym] = {
            :after  => change_values[1],
            :before => change_values[0]
          }
        end
        
        data.merge(:columns => column_changes)
      end
      
      def m
        
      end

      def item_before_change
        previous = self.dup
        # `dup` clears timestamps so we add them back.
        all_timestamp_attributes.each do |column|
          previous[column] = send(column) if respond_to?(column) && !send(column).nil?
        end
        previous.tap do |prev|
          prev.id = id
          changed_attributes.each { |attr, before| prev[attr] = before }
        end
      end

      def object_to_string(object)
        object.attributes.to_yaml
      end

      def changed_notably?
        notably_changed.any?
      end

      def notably_changed
        self.class.only.empty? ? changed_and_not_ignored : (changed_and_not_ignored & self.class.only)
      end

      def changed_and_not_ignored
        changed - self.class.ignore
      end

      def switched_on?
        PaperTrail.enabled? && PaperTrail.enabled_for_controller? && self.class.paper_trail_enabled_for_model
      end
    end

  end
end
