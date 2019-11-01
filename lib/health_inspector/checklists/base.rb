# encoding: UTF-8
require 'pathname'
require 'ffi_yajl'
require 'parallel'
require 'inflecto'
require 'json'

module HealthInspector
  module Checklists
    class Base
      include Color

      class << self
        def title
          Inflecto.humanize(underscored_class).downcase
        end
      end

      def self.run(knife)
        new(knife).run
      end

      def self.option
        Inflecto.dasherize(underscored_class).to_sym
      end

      def self.underscored_class
        Inflecto.underscore(Inflecto.demodulize(self.to_s))
      end

      def initialize(knife)
        @context = Context.new(knife)
      end

      def ui
        @context.knife.ui
      end

      def server_items
        fail NotImplementedError, 'You must implement this method in a subclass'
      end

      def local_items
        fail NotImplementedError, 'You must implement this method in a subclass'
      end

      def all_item_names
        (server_items + local_items).uniq.sort
      end

      def run
        banner "Inspecting #{self.class.title}" unless format_json?

        results = []
        items = [] if format_json?

        finish = lambda do |_, _, item|
         format_json? ? items << item.to_h : print_item(item)
         results << item.errors.empty?
        end

        Parallel.each(all_item_names, finish: finish) do |name|
          item = load_item(name).tap(&:validate)
          OpenStruct.new(name: item.name, server: item.server, local: item.local, errors: item.errors.to_a)
        end

        puts JSON.pretty_generate(items) if format_json?

        !results.include?(false)
      end

      def print_item(item)
       failures = item.errors
       failures.empty? ? print_success(item.name) : print_failures(item.name, failures)
      end

      def banner(message)
        ui.msg ''
        ui.msg message
        ui.msg '-' * 80
      end

      def print_success(subject)
        if $stdout.tty?
          ui.msg color('bright pass', "✓") + " #{subject}"
        else
          ui.msg "Success #{subject}"
        end
      end

      def print_failures(subject, failures)
        ui.msg color('bright fail', "- #{subject}")

        failures.each do |message|
          if message.is_a? Hash
            puts color('bright yellow', "  has the following values mismatched on the server and repo\n")
            print_failures_from_hash(message)
          else
            puts color('bright yellow', "  #{message}")
          end
        end
      end

      def print_failures_from_hash(message, depth = 2)
        message.keys.each do |key|
          print_key(key, depth)

          if message[key].include? 'server'
            print_value_diff(message[key], depth)
            message[key].delete_if { |k, _| k == 'server' || 'local' }
            print_failures_from_hash(message[key], depth + 1) unless message[key].empty?
          else
            print_failures_from_hash(message[key], depth + 1)
          end
        end
      end

      def print_key(key, depth)
        ui.msg indent(color('bright yellow', "#{key} : "), depth)
      end

      def print_value_diff(value, depth)
        print indent(color('bright fail', 'server value = '), depth + 1)
        print value['server']
        print "\n"
        print indent(color('bright fail', 'local value  = '), depth + 1)
        print value['local']
        print "\n\n"
      end

      def load_ruby_or_json_from_local(chef_class, folder, name)
        path_template = "#{@context.repo_path}/#{folder}/**/#{name}.%s"
        ruby_pathname = Pathname.glob(path_template % 'rb')
        json_pathname = Pathname.glob(path_template % 'json')
        js_pathname   = Pathname.glob(path_template % 'js')

        if !ruby_pathname.empty?
          instance = chef_class.new
          instance.from_file(ruby_pathname.first.to_s)
        elsif !json_pathname.empty?
          parsed_json = FFI_Yajl::Parser.parse(json_pathname.first.read)
          instance = load_instance_from(parsed_json, chef_class)
        elsif !js_pathname.empty?
          parsed_json = FFI_Yajl::Parser.parse(js_pathname.first.read)
          instance = load_instance_from(parsed_json, chef_class)
        end

        instance ? instance.to_hash : nil
      rescue IOError
        nil
      end

      def indent(string, depth)
        (' ' * 2 * depth) + string
      end

      private

      # This supports both Chef 11 and 12+ (assuming the public API still has
      # #from_hash
      def load_instance_from(parsed_json, chef_class)
        if Gem::Version.new(Chef::VERSION) < Gem::Version.new('12.0.0')
          chef_class.json_create(parsed_json)
        else
          chef_class.from_hash(parsed_json)
        end
      end

      def format_json?
        @context.knife.config[:format] != 'json'
      end
    end
  end
end
