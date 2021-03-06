# frozen_string_literal: true

require "helper"
require "bridgetown-core/commands/new"

class TestNewCommand < BridgetownUnitTest
  def dir_contents(path)
    Dir["#{path}/**/*"].each do |file|
      file.gsub! path, ""
    end
  end

  def site_template
    File.expand_path("../lib/site_template", __dir__)
  end

  def site_template_source
    File.expand_path("../lib/site_template/src", __dir__)
  end

  context "when args contains a path" do
    setup do
      @path = "new-site"
      @args = [@path]
      @options = "--skip-yarn"
      @full_path = File.expand_path(@path, Dir.pwd)
      @full_path_source = File.expand_path("src", @full_path)
    end

    teardown do
      FileUtils.rm_r @full_path if File.directory?(@full_path)
    end

    should "create a new folder with Gemfile and package.json" do
      gemfile = File.join(@full_path, "Gemfile")
      packagejson = File.join(@full_path, "package.json")
      refute_exist @full_path
      capture_output { Bridgetown::Commands::New.process(@args, @options) }
      assert_exist gemfile
      assert_exist packagejson
      assert_match(%r!gem "bridgetown", "~> #{Bridgetown::VERSION}"!, File.read(gemfile))
      assert_match(%r!"start": "node start.js"!, File.read(packagejson))
    end

    should "display a success message" do
      output = capture_output { Bridgetown::Commands::New.process(@args, @options) }
      success_message = "Your new Bridgetown site was generated in" \
                        " #{@args.join(" ").cyan}."
      bundle_message = "Running bundle install in #{@full_path.cyan}... "
      skipped_yarn_message = "You'll probably also want to #{"yarn install".cyan}"

      assert_includes output, success_message
      assert_includes output, bundle_message
      assert_includes output, skipped_yarn_message
    end

    should "copy the static files in site template to the new directory" do
      static_template_files = dir_contents(site_template).reject do |f|
        File.extname(f) == ".erb"
      end
      static_template_files << "/Gemfile"

      capture_output { Bridgetown::Commands::New.process(@args, @options) }

      new_site_files = dir_contents(@full_path).reject do |f|
        f.end_with?("welcome-to-bridgetown.md")
      end

      assert_same_elements static_template_files, new_site_files
    end

    should "process any ERB files" do
      erb_template_files = dir_contents(site_template_source).select do |f|
        File.extname(f) == ".erb"
      end

      stubbed_date = "2013-01-01"
      allow_any_instance_of(Time).to receive(:strftime) { stubbed_date }

      erb_template_files.each do |f|
        f.chomp! ".erb"
        f.gsub! "0000-00-00", stubbed_date
      end

      capture_output { Bridgetown::Commands::New.process(@args, @options) }

      new_site_files = dir_contents(@full_path_source).select do |f|
        erb_template_files.include? f
      end

      assert_same_elements erb_template_files, new_site_files
    end

    should "force created folder" do
      capture_output { Bridgetown::Commands::New.process(@args, @options) }
      output = capture_output { Bridgetown::Commands::New.process(@args, @options + " --force") }
      assert_match %r!new Bridgetown site was generated in!, output
    end

    should "skip bundle install when opted to" do
      output = capture_output do
        Bridgetown::Commands::New.process(
          @args, @options + " --skip-bundle"
        )
      end
      bundle_message = "Bundle install skipped."
      assert_includes output, bundle_message
    end
  end

  context "when multiple args are given" do
    setup do
      @site_name_with_spaces = "new site name"
      @multiple_args = @site_name_with_spaces.split
      @options = "--skip-yarn"
    end

    teardown do
      FileUtils.rm_r File.expand_path(@site_name_with_spaces, Dir.pwd)
    end

    should "create a new directory" do
      refute_exist @site_name_with_spaces
      capture_output { Bridgetown::Commands::New.process(@multiple_args, @options) }
      assert_exist @site_name_with_spaces
    end
  end

  context "when no args are given" do
    setup do
      @empty_args = []
    end

    should "raise an ArgumentError" do
      exception = assert_raises ArgumentError do
        Bridgetown::Commands::New.process(@empty_args)
      end
      assert_equal "You must specify a path.", exception.message
    end
  end
end
