require 'ostruct'
require 'json'
require 'solve'

# Taken from http://stackoverflow.com/a/25990044
class ::Hash
  def deep_merge(second)
    merger = proc { |key, v1, v2|
      Hash === v1 && Hash === v2 ?
        v1.merge(v2, &merger) :
        [:undefined, nil, :nil].include?(v2) ? v1 : v2
    }
    self.merge(second, &merger)
  end
end

module Berktacular

  # This class represents a Berksfile

  class Berksfile

    # @!attribute [r] name
    #   @return [String] the name of the environment.
    # @!attribute [r] description
    #   @return [String] a description of the enviroment.
    # @!attribute [r] installed
    #   @return [Hash] a hash of installed cookbook directories.
    # @!attribute [r] missing_deps
    #   @return [Hash] a hash of cookbooks missing dependencies after calling verify.
    attr_reader :name, :description, :installed, :missing_deps

    # Creates a new Berksfile from a chef environment file.
    #
    # @param environment [Hash] a parsed JSON chef environment config.
    # @option opts [String] :github_token (nil) the github token to use.
    # @option opts [True,False] :upgrade (False) whether or not to check for upgraded cookbooks.
    # @option opts [True,False] :verbose (False) be more verbose.
    # @option opts [Array<String>] :source_list additional Berkshelf API sources to include in the
    #   generated Berksfile.
    def initialize( env_path, opts = {})
      @opts = {
        upgrade:       opts.has_key?(:upgrade)      ? opts[:upgrade]      : false,
        github_token:  opts.has_key?(:github_token) ? opts[:github_token] : nil,
        verbose:       opts.has_key?(:verbose)      ? opts[:verbose]      : false,
        source_list:   opts.has_key?(:source_list)  ? opts[:source_list]  : [],
        multi_cookbook_dir:  opts.has_key?(:multi_cookbook_dir) ? opts[:multi_cookbook_dir] : nil,
        versions_only:  opts.has_key?(:versions_only) ? opts[:versions_only] : false,
        max_depth:      opts.has_key?(:max_depth) ? opts[:max_depth] : 10,
        parent_env_dir: opts.has_key?(:parent_env_dir) ? opts[:parent_env_dir] : nil
      }
      @counter  = 0
      @env_hash =  expand_env_file(env_path)

      @name               = @env_hash['name']               || nil
      @description        = @env_hash['description']        || nil
      @cookbook_versions  = @env_hash['cookbook_versions']  || {}
      @cookbook_locations = @env_hash['cookbook_locations'] || {}
      @installed = {}
      # only connect once, pass the client to each cookbook.  and only if needed
      connect_to_git if @opts[:upgrade]
      @opts[:source_list] = (@opts[:source_list] + ["https://api.berkshelf.com"]).uniq
    end

    # @return [Hash] representation of the env_file.
    def env_file
      if @opts[:upgrade]
        cookbooks.each do |book|
          @env_hash['cookbook_versions'][book.name] = book.version_specifier
        end
      end
      @env_hash
    end

    # @return [String] representation of the env_file in pretty json.
    def env_file_json
      if @opts[:upgrade]
        cookbooks.each do |book|
          @env_hash['cookbook_versions'][book.name] = book.version_specifier
        end
      end
      JSON.pretty_generate(@env_hash)
    end

    # @param workdir [String] the directory in which to install.  If nil, Berktacular.best_temp_dir is used.
    # @return [String] the directory path where the cookbooks were installed.
    def install(workdir = nil)
      if workdir
        FileUtils.mkdir_p(workdir)
      else
        workdir = Berktacular.best_temp_dir
      end
      unless @installed[workdir]
        # remove the Berksfile.lock if it exists (it shouldn't).
        berksfile = File.join(workdir, "Berksfile")
        lck       = berksfile + ".lock"
        cookbooks = File.join(workdir, "cookbooks")
        FileUtils.rm(lck) if File.exists? lck
        File.write(berksfile, self)
        Berktacular.run_command("berks vendor --berksfile #{berksfile} #{cookbooks}")
        @installed[workdir] = {berksfile: berksfile, lck: lck, cookbooks: cookbooks}
      end
      workdir
    end

    # @params workdir [String] the directory in which to install.  If nil, Berktacular.best_temp_dir is used.
    # @return [True,False] the status of the verify.
    def verify(workdir = nil)
      require 'ridley'
      @missing_deps = {}
      workdir       = install(workdir)
      versions      = {}
      dependencies  = {}
      Dir["#{@installed[workdir][:cookbooks]}/*"].each do |cookbook_dir|
        next unless File.directory?(cookbook_dir)
        metadata_candidates = ['rb', 'json'].map {|ext| File.join(cookbook_dir, "metadata.#{ext}") }
        metadata_path = metadata_candidates.find {|f| File.exists?(f) }
        raise "Metadata file not found: #{metadata_candidates}" if metadata_path.nil?
        metadata =
          metadata_path =~ /\.json$/ ? metadata_from_json(IO.read(metadata_path)) :
            Ridley::Chef::Cookbook::Metadata.from_file(metadata_path)
        cookbook_name = metadata.name
        name_from_path = File.basename(cookbook_dir)
        unless cookbook_name == name_from_path
          if cookbook_name.empty?
            puts "Cookbook #{name_from_path} has no name specified in metadata.rb"
            cookbook_name = name_from_path
          else
            warn "Cookbook name from metadata.rb does not match the directory name!",
                 "metadata.rb: '#{cookbook_name}'",
                 "cookbook directory name: '#{name_from_path}'"
          end
        end
        versions[cookbook_name] = metadata.version
        dependencies[cookbook_name] = metadata.dependencies
      end
      errors = false
      dependencies.each do |name, deps|
        deps.each do |dep_name, constraint|
          actual_version = versions[dep_name]
          if !actual_version
            @missing_deps[name] = "#{name}-#{versions[name]} depends on #{dep_name} which was not installed!"
            warn @missing_deps[name]
            errors = true
          elsif constraint != []  # some cookbooks have '[]' as a dependency in their json metadata
            constraint_obj = begin
              Semverse::Constraint.new(constraint)
            rescue Semverse::InvalidConstraintFormat => ex
              warn "Could not parse version constraint '#{constraint}' " +
                   "for dependency '#{dep_name}' of cookbook '#{name}'"
              raise ex
            end

            unless constraint_obj.satisfies?(actual_version)
              @missing_deps[name] = "#{name}-#{versions[name]} depends on #{dep_name} #{constraint} but #{dep_name} is #{actual_version}!"
              warn @missing_deps[name]
              errors = true
            end
          end
        end
      end
      !errors
    end

    # @param berks_conf [String] path to the berkshelf config file to use.
    # @param knife_conf [String] path to the knife config file to use.
    # @param workdir [String] Path to use as the working directory.
    #   @default Berktacular.best_temp_dir
    # @return [True] or raise on error.
    def upload(berks_conf, knife_conf, workdir=nil)
      raise "No berks config, required for upload" unless berks_conf && File.exists?(berks_conf)
      raise "No knife config, required for upload" unless knife_conf && File.exists?(knife_conf)
      workdir       = install(workdir)
      new_env_file  = File.join(workdir, @name + ".json")
      File.write(new_env_file, env_file_json)
      Berktacular.run_command("berks upload --berksfile #{@installed[workdir][:berksfile]} -c #{berks_conf}")
      Berktacular.run_command("knife environment from file #{new_env_file} -c #{knife_conf}")
    end

    # param workdir [String,nil] the workdir to remove.  If nil, remove all installed working directories.
    def clean(workdir = nil)
      if workdir
        Fileutils.rm_r(workdir)
        @installed.delete(workdir)
      else
        # clean them all
        @installed.keys.each { |d| FileUtils.rm_r(d) }
        @installed = {}
      end
    end

    # @param [IO] where to write the data.
    def print_berksfile( io = STDOUT )
      io.puts to_s
    end

    # @return [String] the berksfile as a String object
    def to_s
      str = ''
      str << "# Name: '#{@name}'\n" if @name
      str << "# Description: #{@description}\n\n" if @description
      str << "# This file is auto-generated, changes will be overwritten\n"
      str << "# Modify the .json environment file and regenerate this Berksfile to make changes.\n\n"

      @opts[:source_list].each do |source_url|
        str << "source '#{source_url}'\n"
      end
      str << "\n"
      cookbooks.each { |l| str << l.to_s << "\n" }
      str
    end

    # @return [Array] a list of Cookbook objects for this environment.
    def cookbooks
      @cookbooks ||= @cookbook_versions.sort.map do |book, version|
        Cookbook.new(book, version, @cookbook_locations[book], @opts)
      end
    end

    # print out the cookbooks that have newer version available on github.
    def check_updates
      connect_to_git
      cookbooks.each do |b|
        candidates = b.check_updates
        next unless candidates.any?
        puts "Cookbook: #{b.name} (auto upgrade: #{b.auto_upgrade ? 'enabled' : 'disabled'})",
             "\tCurrent: #{b.version_number}",
             "\tUpdates: #{candidates.join(", ")}"
      end
    end

    private

    # connect to github using the token in @opts[:github_token].
    # @return [Octokit::Client] a connected github client.
    def connect_to_git
      raise "No token given, can't connect to git" unless @opts[:github_token]
      puts "Connecting to git with supplied github_token" if @opts[:verbose]
      require 'octokit'
      @opts[:git_client] ||= Octokit::Client.new(
        access_token: @opts[:github_token],
        auto_paginate: true
      )
    end

    # recursively expand env_file @opts[:max_depth] times.
    # @return [Hash] of merged env_file
    def expand_env_file(env_file)
      raise "Exceeded max depth!" if @counter > @opts[:max_depth]
      @counter += 1
      env = {}
      if File.exists?(env_file)
        env = JSON.parse( File.read(env_file) )
      else
        raise "Environment file '#{env_file}' does not exist!"
      end
      if env.has_key?("parent")
        parent_env_dir = @opts[:parent_env_dir].nil? ? File.dirname(env_file) : @opts[:parent_env_dir]
        parent = env["parent"]
        if !File.exists?(parent)
          parent = File.join(
            parent_env_dir,
            parent
          )
        end
        env = expand_env_file( parent ).deep_merge( env )
      end
      env
    end

    def metadata_from_json(json_str)
      OpenStruct.new(JSON.parse(json_str))
    end

  end
end
