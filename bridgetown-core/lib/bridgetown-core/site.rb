# frozen_string_literal: true

module Bridgetown
  class Site
    attr_reader   :root_dir, :source, :dest, :cache_dir, :config
    attr_accessor :layouts, :pages, :static_files,
                  :exclude, :include, :lsi, :highlighter, :permalink_style,
                  :time, :future, :unpublished, :plugins, :limit_posts,
                  :keep_files, :baseurl, :data, :file_read_opts,
                  :plugin_manager

    attr_accessor :converters, :generators, :reader
    attr_reader   :regenerator, :liquid_renderer, :components_load_paths,
                  :includes_load_paths

    # Public: Initialize a new Site.
    #
    # config - A Hash containing site configuration details.
    def initialize(config)
      # Source and destination may not be changed after the site has been created.
      @root_dir        = File.expand_path(config["root_dir"]).freeze
      @source          = File.expand_path(config["source"]).freeze
      @dest            = File.expand_path(config["destination"]).freeze

      self.config = config

      @cache_dir       = in_root_dir(config["cache_dir"])
      @reader          = Reader.new(self)
      @regenerator     = Regenerator.new(self)
      @liquid_renderer = LiquidRenderer.new(self)

      Bridgetown.sites << self

      reset
      setup

      Bridgetown::Hooks.trigger :site, :after_init, self
    end

    # Public: Set the site's configuration. This handles side-effects caused by
    # changing values in the configuration.
    #
    # config - a Bridgetown::Configuration, containing the new configuration.
    #
    # Returns the new configuration.
    def config=(config)
      @config = config.clone

      %w(lsi highlighter baseurl exclude include future unpublished
         limit_posts keep_files).each do |opt|
        send("#{opt}=", config[opt])
      end

      configure_cache
      configure_plugins
      configure_component_paths
      configure_include_paths
      configure_file_read_opts

      self.permalink_style = config["permalink"].to_sym

      @config
    end

    # Public: Read, process, and write this Site to output.
    #
    # Returns nothing.
    def process
      reset
      read
      generate
      render
      cleanup
      write
      print_stats if config["profile"]
    end

    def print_stats
      Bridgetown.logger.info @liquid_renderer.stats_table
    end

    # rubocop:disable Metrics/MethodLength
    #
    # Reset Site details.
    #
    # Returns nothing
    def reset
      self.time = if config["time"]
                    Utils.parse_date(config["time"].to_s, "Invalid time in bridgetown.config.yml.")
                  else
                    Time.now
                  end
      self.layouts = {}
      self.pages = []
      self.static_files = []
      self.data = {}
      @post_attr_hash = {}
      @site_data = nil
      @collections = nil
      @documents = nil
      @docs_to_write = nil
      @regenerator.clear_cache
      @liquid_renderer.reset
      @site_cleaner = nil
      frontmatter_defaults.reset

      raise ArgumentError, "limit_posts must be a non-negative number" if limit_posts.negative?

      Bridgetown::Cache.clear_if_config_changed config
      Bridgetown::Hooks.trigger :site, :after_reset, self
    end
    # rubocop:enable Metrics/MethodLength

    # Load necessary libraries, plugins, converters, and generators.
    #
    # Returns nothing.
    def setup
      ensure_not_in_dest

      plugin_manager.conscientious_require

      self.converters = instantiate_subclasses(Bridgetown::Converter)
      self.generators = instantiate_subclasses(Bridgetown::Generator)
    end

    # Check that the destination dir isn't the source dir or a directory
    # parent to the source dir.
    def ensure_not_in_dest
      dest_pathname = Pathname.new(dest)
      Pathname.new(source).ascend do |path|
        if path == dest_pathname
          raise Errors::FatalException,
                "Destination directory cannot be or contain the Source directory."
        end
      end
    end

    # The list of collections and their corresponding Bridgetown::Collection instances.
    # If config['collections'] is set, a new instance is created
    # for each item in the collection, a new hash is returned otherwise.
    #
    # Returns a Hash containing collection name-to-instance pairs.
    def collections
      @collections ||= collection_names.each_with_object({}) do |name, hsh|
        hsh[name] = Bridgetown::Collection.new(self, name)
      end
    end

    # The list of collection names.
    #
    # Returns an array of collection names from the configuration,
    #   or an empty array if the `collections` key is not set.
    def collection_names
      case config["collections"]
      when Hash
        config["collections"].keys
      when Array
        config["collections"]
      when nil
        []
      else
        raise ArgumentError, "Your `collections` key must be a hash or an array."
      end
    end

    # Read Site data from disk and load it into internal data structures.
    #
    # Returns nothing.
    def read
      reader.read
      limit_posts!
      Bridgetown::Hooks.trigger :site, :post_read, self
    end

    # Run each of the Generators.
    #
    # Returns nothing.
    def generate
      generators.each do |generator|
        start = Time.now
        generator.generate(self)
        Bridgetown.logger.debug "Generating:",
                                "#{generator.class} finished in #{Time.now - start} seconds."
      end
    end

    # Render the site to the destination.
    #
    # Returns nothing.
    def render
      payload = site_payload

      Bridgetown::Hooks.trigger :site, :pre_render, self, payload

      execute_inline_ruby_for_layouts!

      render_docs(payload)
      render_pages(payload)

      Bridgetown::Hooks.trigger :site, :post_render, self, payload
    end

    # Remove orphaned files and empty directories in destination.
    #
    # Returns nothing.
    def cleanup
      site_cleaner.cleanup!
    end

    # Write static files, pages, and posts.
    #
    # Returns nothing.
    def write
      each_site_file do |item|
        item.write(dest) if regenerator.regenerate?(item)
      end
      regenerator.write_metadata
      Bridgetown::Hooks.trigger :site, :post_write, self
    end

    def posts
      collections["posts"] ||= Collection.new(self, "posts")
    end

    # Construct a Hash of Posts indexed by the specified Post attribute.
    #
    # post_attr - The String name of the Post attribute.
    #
    # Examples
    #
    #   post_attr_hash('categories')
    #   # => { 'tech' => [<Post A>, <Post B>],
    #   #      'ruby' => [<Post B>] }
    #
    # Returns the Hash: { attr => posts } where
    #   attr  - One of the values for the requested attribute.
    #   posts - The Array of Posts with the given attr value.
    def post_attr_hash(post_attr)
      # Build a hash map based on the specified post attribute ( post attr =>
      # array of posts ) then sort each array in reverse order.
      @post_attr_hash[post_attr] ||= begin
        hash = Hash.new { |h, key| h[key] = [] }
        posts.docs.each do |p|
          p.data[post_attr]&.each { |t| hash[t] << p }
        end
        hash.each_value { |posts| posts.sort!.reverse! }
        hash
      end
    end

    def tags
      post_attr_hash("tags")
    end

    def categories
      post_attr_hash("categories")
    end

    # Prepare site data for site payload. The method maintains backward compatibility
    # if the key 'data' is already used in bridgetown.config.yml.
    #
    # Returns the Hash to be hooked to site.data.
    def site_data
      @site_data ||= (config["data"] || data)
    end

    def metadata
      data["site_metadata"] || {}
    end

    # The Hash payload containing site-wide data.
    #
    # Returns the Hash: { "site" => data } where data is a Hash with keys:
    #   "time"       - The Time as specified in the configuration or the
    #                  current time if none was specified.
    #   "posts"      - The Array of Posts, sorted chronologically by post date
    #                  and then title.
    #   "pages"      - The Array of all Pages.
    #   "html_pages" - The Array of HTML Pages.
    #   "categories" - The Hash of category values and Posts.
    #                  See Site#post_attr_hash for type info.
    #   "tags"       - The Hash of tag values and Posts.
    #                  See Site#post_attr_hash for type info.
    def site_payload
      Drops::UnifiedPayloadDrop.new self
    end
    alias_method :to_liquid, :site_payload

    # Get the implementation class for the given Converter.
    # Returns the Converter instance implementing the given Converter.
    # klass - The Class of the Converter to fetch.
    def find_converter_instance(klass)
      @find_converter_instance ||= {}
      @find_converter_instance[klass] ||= begin
        converters.find { |converter| converter.instance_of?(klass) } || \
          raise("No Converters found for #{klass}")
      end
    end

    # klass - class or module containing the subclasses.
    # Returns array of instances of subclasses of parameter.
    # Create array of instances of the subclasses of the class or module
    # passed in as argument.

    def instantiate_subclasses(klass)
      klass.descendants.sort.map do |c|
        c.new(config)
      end
    end

    # Get the to be written documents
    #
    # Returns an Array of Documents which should be written
    def docs_to_write
      documents.select(&:write?)
    end

    # Get all the documents
    #
    # Returns an Array of all Documents
    def documents
      collections.each_with_object(Set.new) do |(_, collection), set|
        set.merge(collection.docs).merge(collection.files)
      end.to_a
    end

    def each_site_file
      %w(pages static_files docs_to_write).each do |type|
        send(type).each do |item|
          yield item
        end
      end
    end

    # Returns the FrontmatterDefaults or creates a new FrontmatterDefaults
    # if it doesn't already exist.
    #
    # Returns The FrontmatterDefaults
    def frontmatter_defaults
      @frontmatter_defaults ||= FrontmatterDefaults.new(self)
    end

    # Whether to perform a full rebuild without incremental regeneration
    #
    # Returns a Boolean: true for a full rebuild, false for normal build
    def incremental?(override = {})
      override["incremental"] || config["incremental"]
    end

    # Returns the publisher or creates a new publisher if it doesn't
    # already exist.
    #
    # Returns The Publisher
    def publisher
      @publisher ||= Publisher.new(self)
    end

    # Public: Prefix a given path with the root directory.
    #
    # paths - (optional) path elements to a file or directory within the
    #         root directory
    #
    # Returns a path which is prefixed with the root_dir directory.
    def in_root_dir(*paths)
      paths.reduce(root_dir) do |base, path|
        Bridgetown.sanitized_path(base, path)
      end
    end

    # Public: Prefix a given path with the source directory.
    #
    # paths - (optional) path elements to a file or directory within the
    #         source directory
    #
    # Returns a path which is prefixed with the source directory.
    def in_source_dir(*paths)
      paths.reduce(source) do |base, path|
        Bridgetown.sanitized_path(base, path)
      end
    end

    # Public: Prefix a given path with the destination directory.
    #
    # paths - (optional) path elements to a file or directory within the
    #         destination directory
    #
    # Returns a path which is prefixed with the destination directory.
    def in_dest_dir(*paths)
      paths.reduce(dest) do |base, path|
        Bridgetown.sanitized_path(base, path)
      end
    end

    # Public: Prefix a given path with the cache directory.
    #
    # paths - (optional) path elements to a file or directory within the
    #         cache directory
    #
    # Returns a path which is prefixed with the cache directory.
    def in_cache_dir(*paths)
      paths.reduce(cache_dir) do |base, path|
        Bridgetown.sanitized_path(base, path)
      end
    end

    # Public: The full path to the directory that houses all the collections registered
    # with the current site.
    #
    # Returns the source directory or the absolute path to the custom collections_dir
    def collections_path
      dir_str = config["collections_dir"]
      @collections_path ||= dir_str.empty? ? source : in_source_dir(dir_str)
    end

    private

    # Limits the current posts; removes the posts which exceed the limit_posts
    #
    # Returns nothing
    def limit_posts!
      if limit_posts.positive?
        limit = posts.docs.length < limit_posts ? posts.docs.length : limit_posts
        posts.docs = posts.docs[-limit, limit]
      end
    end

    # Returns the Cleaner or creates a new Cleaner if it doesn't
    # already exist.
    #
    # Returns The Cleaner
    def site_cleaner
      @site_cleaner ||= Cleaner.new(self)
    end

    # Disable Marshaling cache to disk in Safe Mode
    def configure_cache
      Bridgetown::Cache.cache_dir = in_root_dir(config["cache_dir"], "Bridgetown/Cache")
      Bridgetown::Cache.disable_disk_cache! if config["disable_disk_cache"]
    end

    def configure_plugins
      self.plugin_manager = Bridgetown::PluginManager.new(self)
      self.plugins        = plugin_manager.plugins_path
    end

    def configure_component_paths
      @components_load_paths = config["components_dir"].then do |dir|
        dir.is_a?(Array) ? dir : [dir]
      end
      @components_load_paths.map! do |dir|
        if !!(dir =~ %r!^\.\.?\/!)
          # allow ./dir or ../../dir type options
          File.expand_path(dir.to_s, root_dir)
        else
          in_source_dir(dir.to_s)
        end
      end
    end

    def configure_include_paths
      @includes_load_paths = Array(in_source_dir(config["includes_dir"].to_s))
    end

    def configure_file_read_opts
      self.file_read_opts = {}
      file_read_opts[:encoding] = config["encoding"] if config["encoding"]
      self.file_read_opts = Bridgetown::Utils.merged_file_read_opts(self, {})
    end

    def execute_inline_ruby_for_layouts!
      return unless config.should_execute_inline_ruby?

      layouts.each_value do |layout|
        Bridgetown::Utils::RubyExec.search_data_for_ruby_code(layout, self)
      end
    end

    def render_docs(payload)
      collections.each_value do |collection|
        collection.docs.each do |document|
          render_regenerated(document, payload)
        end
      end
    end

    def render_pages(payload)
      pages.each do |page|
        render_regenerated(page, payload)
      end
    end

    def render_regenerated(document, payload)
      return unless regenerator.regenerate?(document)

      document.output = Bridgetown::Renderer.new(self, document, payload).run
      document.trigger_hooks(:post_render)
    end
  end
end
