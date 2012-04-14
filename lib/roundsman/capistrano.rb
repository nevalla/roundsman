require 'json'
require 'tempfile'
require 'delegate'

::Capistrano::Configuration.instance(:must_exist).load do

  namespace :roundsman do

    unless respond_to?(:set_default)
      def set_default(name, *args, &block)
        @_defaults ||= []
        @_overridden_defaults ||= []
        @_defaults << name
        if exists?(name)
          @_overridden_defaults << name
        else
          set(name, *args, &block)
        end
      end
    end

    set_default :ruby_version, "1.9.3-p125"
    set_default :cookbooks_directory, ["config/cookbooks"]
    set_default :stream_chef_output, true
    set_default :care_about_ruby_version, true
    set_default :chef_directory, "/tmp/chef"
    set_default :chef_version, "~> 0.10.8"
    set_default :copyfile_disable, false

    set_default :ruby_dependencies, %w(git-core curl build-essential bison openssl
        libreadline6 libreadline6-dev zlib1g zlib1g-dev libssl-dev
        libyaml-dev libxml2-dev libxslt-dev autoconf libc6-dev ncurses-dev
        vim wget tree)

    set_default :ruby_install_dir, "/usr/local"

    set_default :ruby_install_script, <<-BASH
      set -e
      cd #{chef_directory}
      rm -rf ruby-build
      git clone -q git://github.com/sstephenson/ruby-build.git
      cd ruby-build
      ./install.sh
      ruby-build #{fetch(:ruby_version)} #{fetch(:ruby_install_dir)}
    BASH

    desc "Lists configuration"
    task :configuration do
      @_defaults.sort.each do |name|
        display_name = ":#{name},".ljust(30)
        if variables[name].is_a?(Proc)
          value = "<block>"
        else
          value = fetch(name).inspect
          value = "#{value[0..40]}... (truncated)" if value.length > 40
        end
        overridden = @_overridden_defaults.include?(name) ? "(overridden)" : ""
        puts "set #{display_name} #{value} #{overridden}"
      end
    end

    desc "Installs ruby."
    task :install_ruby, :except => { :no_release => true } do
      put fetch(:ruby_install_script), chef_directory("install_ruby.sh"), :via => :scp
      _root "bash #{chef_directory("install_ruby.sh")}"
    end

    desc "Installs the dependencies needed for Ruby"
    task :install_dependencies, :except => { :no_release => true } do
      ensure_supported_distro
      _root "aptitude -yq update"
      _root "aptitude -yq install #{fetch(:ruby_dependencies).join(' ')}"
    end

    desc "Installs chef"
    task :install_chef, :except => { :no_release => true } do
      _root "gem uninstall -xaI chef || true"
      _root "gem install chef -v #{fetch(:chef_version).inspect} --quiet --no-ri --no-rdoc"
      _root "gem install ruby-shadow --quiet --no-ri --no-rdoc"
    end

    desc "Checks if the ruby version installed matches the version specified"
    task :check_ruby_version do
      abort if install_ruby?
    end

    def chef(*run_list)
      ensure_cookbooks_exist(run_list)
      if install_ruby?
        install_dependencies
        install_ruby
      end
      install_chef if install_chef?
      generate_config
      generate_attributes(run_list)
      copy_cookbooks
      _root "chef-solo -c #{chef_directory("solo.rb")} -j #{chef_directory("solo.json")}"
    end

    def ensure_cookbooks_exist(run_list)
      abort "You must specify at least one recipe when running roundsman.chef" if run_list.empty?
      abort "No cookbooks found in #{fetch(:cookbooks_directory)}" if cookbooks_paths.empty?
    end

    def ensure_supported_distro
      unless @ensured_supported_distro
        logger.info "Using Linux distribution #{distribution}"
        abort "This distribution is not (yet) supported." unless distribution.include?("Ubuntu")
        @ensured_supported_distro = true
      end
    end

    def ensure_chef_directory
      unless @ensured_chef_directory
        _run "mkdir -p #{fetch(:chef_directory)}"
        _root "chown -R #{user} #{fetch(:chef_directory)}"
        @ensured_chef_directory = true
      end
    end

    def cookbooks_paths
      Array(fetch(:cookbooks_directory)).select { |path| File.exist?(path) }
    end

    def install_ruby?
      installed_version = capture("ruby --version || true").strip
      if installed_version.include?("not found")
        logger.info "No version of Ruby could be found."
        return true
      end
      required_version = fetch(:ruby_version).gsub("-", "")
      if installed_version.include?(required_version)
        if fetch(:care_about_ruby_version)
          logger.info "Ruby #{installed_version} matches the required version: #{required_version}."
          return false
        else
          logger.info "Already installed Ruby #{installed_version}, not #{required_version}. Set :care_about_ruby_version if you want to fix this."
          return false
        end
      else
        logger.info "Ruby version mismatch. Installed version: #{installed_version}, required is #{required_version}"
        return true
      end
    end

    def install_chef?
      required_version = fetch(:chef_version).inspect
      output = capture("gem list -i -v #{required_version} || true").strip
      output == "false"
    end

    def distribution
      @distribution ||= capture("cat /etc/issue").strip
    end

    def chef_directory(*path)
      ensure_chef_directory
      File.join(fetch(:chef_directory), *path)
    end

    def _root(command, *args)
      _run("#{sudo} #{command}", *args)
    end

    def _run(*args)
      if fetch(:stream_chef_output)
        stream *args
      else
        run *args
      end
    end

    def generate_config
      cookbook_string = cookbooks_paths.map { |c| "File.join(root, #{c.to_s.inspect})" }.join(', ')
      solo_rb = <<-RUBY
        root = File.expand_path(File.dirname(__FILE__))
        file_cache_path File.join(root, "cache")
        cookbook_path [ #{cookbook_string} ]
      RUBY
      put solo_rb, chef_directory("solo.rb"), :via => :scp
    end

    def generate_attributes(run_list)
      attrs = remove_procs_from_hash variables.dup
      attrs[:run_list] = run_list
      put attrs.to_json, chef_directory("solo.json"), :via => :scp
    end

    # Recursively removes procs from hashes. Procs can exist because you specified them like this:
    #
    #     set(:root_password) { Capistrano::CLI.password_prompt("Root password: ") }
    def remove_procs_from_hash(hash)
      new_hash = {}
      hash.each do |key, value|
        new_value = value.respond_to?(:call) ? value.call : value
        if new_value.is_a?(Hash)
          new_value = remove_procs_from_hash(new_value)
        end
        unless new_value.class.to_s.include?("Capistrano") # skip capistrano tasks
          new_hash[key] = new_value
        end
      end
      new_hash
    end

    def copy_cookbooks
      tar_file = Tempfile.new("cookbooks.tar")
      begin
        tar_file.close
        env_vars = fetch(:copyfile_disable) && RUBY_PLATFORM.downcase.include?('darwin') ? "COPYFILE_DISABLE=true" : ""
        system "#{env_vars} tar -cjf #{tar_file.path} #{cookbooks_paths.join(' ')}"
        upload tar_file.path, chef_directory("cookbooks.tar"), :via => :scp
        _run "cd #{chef_directory} && tar -xjf cookbooks.tar"
      ensure
        tar_file.unlink
      end
    end

  end

end
