require 'optparse'
require_relative './mcmd'

##
# Implements what is shared
# between mssh and mcmd.
class CommonCli
  attr_accessor :options, :result, :command_to_target, :targets
  attr_writer   :extra_options

  def initialize(defaults)
    @options = defaults
    @options[:hostname_token] = 'HOSTNAME'
  end

  ##
  # Parses a list of arguments, and yells
  # at us if any are wrong.
  def parse(argv)

    @defs = Hash[@options.map{|k,v| [k, " (default: #{v})"] } ]

    optparse = OptionParser.new do |opts|
      opts.on('-r', '--range RANGE', 'currently takes a CSV list' + @defs[:range].to_s ) do |arg|
        @options[:range] = arg
      end
      opts.on('--hostlist x,y,z', Array, 'List of hostnames to execute on' + @defs[:hostlist].to_s) do |arg|
        @options[:hostlist] = arg
      end
      opts.on('-f', '--file FILE', 'List of hostnames in a FILE use (/dev/stdin) for reading from stdin' + @defs[:file].to_s) do |arg|
        @options[:file] = arg
      end
      opts.on('-m', '--maxflight 200', 'How many subprocesses? 50 by default' + @defs[:maxflight].to_s) do |arg|
        @options[:maxflight] = arg
      end
      opts.on('-t', '--timeout 60', 'How many seconds may each individual process take? 0 for no timeout' + @defs[:timeout].to_s) do |arg|
        @options[:timeout] = arg
      end
      opts.on('-g', '--global_timeout 0', 'How many seconds for the whole shebang 0 for no timeout' + @defs[:global_timeout].to_s) do |arg|
        @options[:global_timeout] = arg
      end
      opts.on('-c', '--collapse', "Collapse similar output " + @defs[:collapse].to_s) do |arg|
        @options[:collapse] = arg
      end
      opts.on('-v', '--verbose', "Verbose output" + @defs[:verbose].to_s) do |arg|
        @options[:verbose] = arg
      end
      opts.on('-d', '--debug', "Debug output" + @defs[:debug].to_s) do |arg|
        @options[:debug] = arg
      end
      opts.on('--json', "Output results as JSON" + @defs[:json_out].to_s) do |arg|
        @options[:json_out] = arg
      end
      opts.on('--hntoken HOSTNAME', "Token used for HOSTNAME substitution" + @defs[:hostname_token].to_s) do |arg|
        @options[:hostname_token] = arg
      end

      @extra_options.call(opts, @options) if !@extra_options.nil?

      # option to merge stdin/stdout into one buf? how should this work?
      # option to ignore as-we-go yield output - this is off by default now except for success/fail
    end

    optparse.parse! argv

    if options[:range] || options[:collapse]
      require 'rangeclient'
      @rangeclient = Range::Client.new
    end

    ## Get targets from -r or -f or --hostlist
    @targets = []
    if (options[:range].nil? and options[:file].nil? and options[:hostlist].nil?)
      raise "Error, need -r or -f or --hostlist option"
    end

    if (!options[:range].nil?)
      @targets.push *@rangeclient.expand(options[:range])
    end

    if (!options[:file].nil?)
      targets_fd = File.open(options[:file])
      targets_fd.read.each_line { |x| @targets << x.chomp }
    end

    if (!options[:hostlist].nil?)
      @targets.push *options[:hostlist]
    end

    raise "no targets specified. Check your -r, -f or --hostlist inputs" if @targets.size.zero?
    raise "need command to run"                                          if argv.size.zero?
    raise "too many arguments"                                           if argv.size != 1

    @command = argv.first

  end

  def runcmd

    m = MultipleCmd.new

    # We let the caller build the command
    m.commands = @targets.map do |t|
      yield(@command.gsub(@options[:hostname_token], t), t)
    end

    @command_to_target = Hash.new
    @targets.size.times do |i|
      @command_to_target[m.commands[i].object_id] = @targets[i]
    end

    m.yield_startcmd = lambda { |p| puts "#{@command_to_target[p.command.object_id]}: starting" } if @options[:verbose]
    m.yield_wait     = lambda { |p| puts "#{p.success? ? 'SUCCESS' : 'FAILURE'} #{@command_to_target[p.command.object_id]}: '#{p.stdout_buf}'" } if @options[:verbose]
    # todo, from mssh m.yield_wait = lambda { |p| puts "#{@command_to_target[p.command.object_id]}: finished" } if @options[:verbose]

    # was commented out in mcmd already: m.yield_proc_timeout = lambda { |p| puts "am killing #{p.inspect}"}

    m.perchild_timeout = @options[:timeout].to_i
    m.global_timeout   = @options[:global_timeout].to_i
    m.maxflight        = @options[:maxflight].to_i
    m.verbose          = @options[:verbose]
    m.debug            = @options[:debug]

    return m.run
  end

  def output result

    ## Print as JSON array
    if (@options[:json_out])
      require 'json'
      puts JSON.generate(result)
      return
    end

    # Concat stdout / stderr -> :all_buf
    result.each do |r|
      r[:all_buf] = ""
      r[:all_buf] += r[:stdout_buf].chomp if(!r[:stdout_buf].nil?)
      r[:all_buf] += r[:stderr_buf].chomp if(!r[:stderr_buf].nil?)
    end

    ## Collapse similar results
    if @options[:collapse]
      stdout_matches_success = Hash.new
      stdout_matches_failure = Hash.new
      result.each do |r|

        if r[:retval].success?
          stdout_matches_success[r[:all_buf]] = [] if stdout_matches_success[r[:all_buf]].nil?
          stdout_matches_success[r[:all_buf]] << @command_to_target[r[:command].object_id]
        else
          stdout_matches_failure[r[:all_buf]] = [] if stdout_matches_failure[r[:all_buf]].nil?
          stdout_matches_failure[r[:all_buf]] << @command_to_target[r[:command].object_id]
        end
      end
      # output => [targets ...]
      stdout_matches_success.each_pair do |k,v|
        hosts = @rangeclient.compress v
        # puts "#{hosts}: '#{k.chomp}'"
        puts "SUCCESS: #{hosts}: #{k}"
      end
      stdout_matches_failure.each_pair do |k,v|
        hosts = @rangeclient.compress v
        puts "FAILURE: #{hosts}: #{k}"
      end

    ## Dont collapse similar resutls
    else
      result.each do |r|
        target = @command_to_target[r[:command].object_id]
        if (r[:retval].success?)
            puts "#{target}:SUCCESS: #{r[:all_buf]}\n"
        else
            exit_code = r[:retval].exitstatus.to_s if(!r[:retval].nil?)
            puts "#{target}:FAILURE[#{exit_code}]: #{r[:all_buf]}\n"
        end
      end
    end

  end
end
