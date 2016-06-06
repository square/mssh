#!/usr/bin/ruby

require 'pp'
require 'rubygems'
require 'io/poll'

class MultipleCmd
  attr_accessor :global_timeout, :maxflight, :perchild_timeout, :commands
  attr_accessor :yield_wait, :yield_startcmd, :debug, :yield_proc_timeout
  attr_accessor :verbose, :poll_period, :max_read_size

  # TODO: move these to cattrs on MultipleCmd::SubProc
  attr_accessor :subproc_by_pid, :subproc_by_fd

  def initialize
    # these are re-initialized after every run
    @subproc_by_pid = {}
    @subproc_by_fd = {}
    @processed_commands = []
    # end items which are re-initialized

    self.commands = []
    self.perchild_timeout = 60
    self.global_timeout = 0
    self.maxflight = 200
    self.debug = false
    self.poll_period = 0.5 # shouldn't need adjusting
    self.max_read_size = 2**19 # 512k
  end

  def noshell_exec(cmd)
    if cmd.length == 1
      exec([cmd[0], cmd[0]])
    else
      exec([cmd[0], cmd[0]], *cmd[1..-1])
    end
  end

  # I should probably move this whole method
  # into SubProc and make the subproc_by_* into
  # class variables
  def add_subprocess(cmd)
    stdin_rd, stdin_wr = IO.pipe
    stdout_rd, stdout_wr = IO.pipe
    stderr_rd, stderr_wr = IO.pipe
    subproc = MultipleCmd::SubProc.new
    subproc.stdin_fd = stdin_wr
    subproc.stdout_fd = stdout_rd
    subproc.stderr_fd = stderr_rd
    subproc.command = cmd

    pid = fork
    if pid
      # parent
      # for mapping to subproc by pid
      subproc.pid = pid
      subproc_by_pid[pid] = subproc
      # for mapping to subproc by i/o handle (returned from select)
      subproc_by_fd[stdin_rd] = subproc
      subproc_by_fd[stdin_wr] = subproc
      subproc_by_fd[stdout_rd] = subproc
      subproc_by_fd[stdout_wr] = subproc
      subproc_by_fd[stderr_rd] = subproc
      subproc_by_fd[stderr_wr] = subproc

      yield_startcmd.call(subproc) unless yield_startcmd.nil?
    else
      # child
      # setup stdin, out, err
      STDIN.reopen(stdin_rd)
      STDOUT.reopen(stdout_wr)
      STDERR.reopen(stderr_wr)
      noshell_exec(cmd)
      raise "can't be reached!!. exec failed!!"
    end
  end

  def process_read_fds(read_fds)
    read_fds.each do |fd|
      # read available bytes, add to the subproc's read buf
      unless subproc_by_fd.key?(fd)
        raise "Select returned a fd which I have not seen! fd: #{fd.inspect}"
      end
      subproc = subproc_by_fd[fd]
      buf = ''
      begin
        buf = fd.sysread(4096)

        raise ' Impossible result from sysread()' if buf.nil?
        # no exception? bytes were read. append them.
        if fd == subproc.stdout_fd
          subproc.stdout_buf << buf
          # FIXME: if we've read > maxbuf, allow closing/ignoring the fd instead of hard kill
          if subproc.stdout_buf.bytesize > max_read_size
            # self.kill_process(subproc) # can't kill this here, need a way to mark-to-kill
          end
        elsif fd == subproc.stderr_fd
          subproc.stderr_buf << buf
          # FIXME: if we've read > maxbuf, allow closing/ignoring the fd instead of hard kill
          if subproc.stderr_buf.bytesize > max_read_size
            # self.kill_process(subproc) # "" above
          end
        end
      rescue SystemCallError, EOFError => ex
        puts "DEBUG: saw read exception #{ex}" if debug
        # clear out the read fd for this subproc
        # finalize read i/o
        # if we're reading, it was the process's stdout or stderr
        if fd == subproc.stdout_fd
          subproc.stdout_fd = nil
        elsif fd == subproc.stderr_fd
          subproc.stderr_fd = nil
        else
          raise "impossible: operating on a subproc where the fd isn't found, even though it's mapped"
        end
        begin
          fd.close
        rescue
          true
        end
      end
    end
  end # process_read_fds()

  def process_write_fds(write_fds)
    write_fds.each do |fd|
      raise "working on an unknown fd #{fd}" unless subproc_by_fd.key?(fd)
      subproc = subproc_by_fd[fd]
      buf = ''
      # add writing here, todo. not core feature
    end
  end

  def process_err_fds(err_fds)
  end

  # iterate and service fds in child procs, collect data and status
  def service_subprocess_io
    write_fds = subproc_by_pid.values.select { |x| !x.stdin_fd.nil? && !x.terminated }.map(&:stdin_fd)
    read_fds = subproc_by_pid.values.select { |x| !x.terminated }.map { |x| [x.stdout_fd, x.stderr_fd].select { |x| !x.nil? } }.flatten

    read_fds, write_fds, err_fds = IO.select_using_poll(read_fds, write_fds, nil, poll_period)

    process_read_fds(read_fds) unless read_fds.nil?
    process_write_fds(write_fds) unless write_fds.nil?
    process_err_fds(err_fds) unless err_fds.nil?
    # errors?
  end

  def process_timeouts
    now = Time.now.to_i
    subproc_by_pid.values.each do |p|
      next unless ((now - p.time_start) > perchild_timeout) && perchild_timeout > 0
      # expire this child process

      yield_proc_timeout.call(p) unless yield_proc_timeout.nil?
      kill_process(p)
    end
  end

  def kill_process(p)
    # do not remove from pid list until waited on
    subproc_by_fd.delete(p.stdin_fd)
    subproc_by_fd.delete(p.stdout_fd)
    subproc_by_fd.delete(p.stderr_fd)
    # must kill after deleting from maps
    # kill closes fds
    p.kill
  end

  def run
    @global_time_start = Time.now.to_i
    done = false
    until done
      # start up as many as maxflight processes
      while subproc_by_pid.length < maxflight && !@commands.empty?
        # take one from @commands and start it
        commands = @commands.shift
        add_subprocess(commands)
      end
      # service running processes
      service_subprocess_io
      # timeout overdue processes
      process_timeouts
      # service process cleanup
      wait
      puts "have #{subproc_by_pid.length} left to go" if debug
      # if we have nothing in flight (active pid)
      # and nothing pending on the input list
      # then we're done
      done = true if subproc_by_pid.length.zero? && @commands.empty?
    end

    data = return_rundata
    # these are re-initialized after every run
    subproc_by_pid = {}
    subproc_by_fd = {}
    @processed_commands = []
    # end items which are re-initialized
    data
  end

  def return_rundata
    data = []
    @processed_commands.each do |c|
      # FIXME: pass through the process object
      data << {
        :pid => c.pid,
        :write_buf_position => c.write_buf_position,
        :stdout_buf => c.stdout_buf,
        :stderr_buf => c.stderr_buf,
        :command => c.command,
        :time_start => c.time_start,
        :time_end => c.time_end,
        :retval => c.retval
      }
    end
    data
  end

  def wait
    possible_children = true
    just_reaped = []
    while possible_children
      begin
        pid = Process.waitpid(-1, Process::WNOHANG)
        if pid.nil?
          possible_children = false
        else
          # pid is now gone. remove from subproc_by_pid and
          # add to the processed commands list
          p = subproc_by_pid[pid]
          p.time_end = Time.now.to_i
          p.retval = $?
          subproc_by_pid.delete(pid)
          @processed_commands << p
          just_reaped << p
        end
      rescue Errno::ECHILD => ex
        # ECHILD. ignore.
        possible_children = false
      end
    end
    # We may have waited on a child before reading all its output. Collect those missing bits. No blocking.
    unless just_reaped.empty?
      read_fds = just_reaped.select { |x| !x.terminated }.map { |x| [x.stdout_fd, x.stderr_fd].select { |x| !x.nil? } }.flatten
      read_fds, write_fds, err_fds = IO.select_using_poll(read_fds, nil, nil, 0)
      process_read_fds(read_fds) unless read_fds.nil?
    end
    just_reaped.each do |p|
      yield_wait.call(p) unless yield_wait.nil?
    end
  end
end

class MultipleCmd::SubProc
  attr_accessor :stdin_fd, :stdout_fd, :stderr_fd, :write_buf_position
  attr_accessor :time_start, :time_end, :pid, :retval, :stdout_buf, :stderr_buf, :command, :terminated

  def initialize
    self.write_buf_position = 0
    self.time_start = Time.now.to_i
    self.stdout_buf = ''
    self.stderr_buf = ''
    self.terminated = false
  end

  # when a process has out-stayed its welcome
  def kill
    begin
      stdin_fd.close
    rescue
      true
    end
    begin
      stdout_fd.close
    rescue
      true
    end
    begin
      stderr_fd.close
    rescue
      true
    end
    # TODO: configurable sig?
    Process.kill('KILL', pid)
    self.terminated = true
  end

  # some heuristic to determine if this job was successful
  # for now, trust retval. Also check stderr?
  def success?
    retval.success?
  end
end
