module SHUtils

  module Helpers
    def set_default(key, value, hash)
      hash[key] = value if hash[key].nil?
    end
    def dry_run?
      !ENV['DRY_RUN'].nil?
    end
  end

  module Log
    def debug?
      !ENV['DEBUG'].nil?
    end

    def error(msg, exit_if_err = 0)
      $stderr.puts "\e[91mERROR:\e[0m #{msg}"
      exit exit_if_err if exit_if_err != 0
    end

    def warn(msg)
      $stderr.puts "\e[93mWARN:\e[0m #{msg}"
    end

    def info(msg)
      $stdout.puts "INFO: #{msg}"
    end

    def debug(msg, debug = false)
      if ENV["DEBUG"] or debug
        $stdout.puts "DEBUG: #{msg}"
      end
    end
  end

  # FIXME: this should go away by porting the official fileutils
  module FileUtils

    def self.readable?(file)
      File.open(file) {}
      true
    rescue Errno::EACCES
      false
    end

    # Remove all the entries in a directory recursively
    #
    # FIXME: mruby does not have fileutils right now
    #
    def self.rm_rf(path)
      if File.symlink?(path) or !File.directory?(path)
        File.delete(path)
        return
      end

      return unless File.exist?(path)

      list_dir(path).each do |p|
        if dry_run?
          info "DRY RUN: Removing file/dir #{p}"
          next
        end

        if File.directory?(p)
          Dir.rmdir(p)
        else
          File.delete(p)
        end
      end
    end

    # Code from ruby/lib/tmpdir.rb
    def self.mktmpdir(prefix_suffix=nil, *rest)
      path = Tmpname.create(prefix_suffix || "d", *rest) {|n| Dir.mkdir(n, 0700)}
      if block_given?
        begin
          yield path
        ensure
          # FIXME: mruby-io File does not currently have stat
          #stat = File.stat(File.dirname(path))
          #if stat.world_writable? and !stat.sticky?
          #  raise ArgumentError, "parent directory is world writable but not sticky"
          #end
          rm_rf
        end
      else
        path
      end
    end
  end

  # Code from ruby/lib/tmpdir.rb, ported to be mruby compatible
  #
  # NOTE: Do not assume the behaviour is going to be the same.
  module Tmpname # :nodoc:

    def self.make_tmpname(prefix_suffix, n)
      case prefix_suffix
      when String
        prefix = prefix_suffix
        suffix = ""
      when Array
        prefix = prefix_suffix[0]
        suffix = prefix_suffix[1]
      else
        raise ArgumentError, "unexpected prefix_suffix: #{prefix_suffix.inspect}"
      end
      t = Time.now.to_f
      #path = "#{prefix}#{t}-#{$$}-#{rand(0x100000000).to_s(36)}"
      path = "#{prefix}#{t}-#{$$}-#{rand(429496729).to_s(36)}"
      path << "-#{n}" if n
      path << suffix
    end

    def self.create(basename, *rest)
      opts = nil
      opts = rest[-1] if rest[-1].is_a?(Hash)
        
      if opts
        opts = opts.dup if rest.pop.equal?(opts)
        max_try = opts.delete(:max_try)
        opts = [opts]
      else
        opts = []
      end

      tmpdir, = *rest
      tmpdir ||= Dir.tmpdir
      n = nil

      begin
        path = File.join(tmpdir, make_tmpname(basename, n))
        yield(path, n, *opts)
      rescue Errno::EEXIST
        n ||= 0
        n += 1
        retry if !max_try or n < max_try
        raise "cannot generate temporary name using `#{basename}' under `#{tmpdir}'"
      end
      path
    end
  end

  module CLI
    extend Log
    extend Helpers 

    # Run a shell command
    #
    # Options:
    #
    # :ignore_output - Redirect stderr and stdout to /dev/null
    # :exit_if_err   - Raise an exception if the command fails
    #
    def self.cmd(str, opts = {})
      set_default :ignore_output, !debug?, opts
      set_default :exit_if_err, true, opts

      cmd_string = str
      if opts[:ignore_output] == true
        cmd_string += " > /dev/null 2>&1"
      end

      if dry_run?
        info "DRY RUN: #{cmd_string}"
        ok = true
      else
        #out = system(cmd_string)
        debug cmd_string
        ok = system(cmd_string)
      end

      #debug out unless opts[:ignore_output]

      if opts[:exit_if_err] and !ok and !dry_run?
        if opts[:exit_if_err].is_a?(String)
          raise opts[:exit_if_err]
        else
          raise "Command '#{cmd_string}' failed. Aborting."
        end
      end

      ok
    end

  end

  module PKG
    def self.pkg_installed?(pkg)
      system("dpkg-query --show #{pkg} > /dev/null 2>&1")
    end

    def self.requires_pkg!(pkg)
      unless pkg_installed?(pkg)
        error "Debian package '#{pkg}' is required but not installed."
        raise "Run 'lxc-ghe prepare' first"
      end
    end

    # Install a Debian package via apt-get
    #
    def self.pkg(names, opts = {})
      pkgs = names
      if names.is_a?(String)
        pkgs = [names]
      end

      pkgs.each do |name|
        if pkg_installed?(name)
          debug "Package #{name} already installed, skipping"
          pkgs.delete name
        end
      end

      info "Installing package(s) #{pkgs.join(' ')}..."

      opts_str = opts.to_a.map { |o| "#{o[0]} #{o[1]}" }
      cmd_str = "DEBIAN_FRONTEND=noninteractive apt-get install -y"

      if !opts.empty?
        cmd_str += " #{opts_str.join(" ")}"
      end

      cmd "#{cmd_str} #{pkgs.join(' ')}",
          :exit_if_err => "Installing package(s) #{pkgs.join(' ')}."
    end

  end

end
