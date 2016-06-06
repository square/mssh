require_relative '../lib/mcmd'
require 'fileutils'

describe MultipleCmd do
  let(:instance) { MultipleCmd.new }

  describe '#noshell_exec' do
    subject { instance.noshell_exec(cmd) }

    context 'when the command is a single string' do
      let(:cmd) { ['date'] }

      it 'runs just that command with the command name as ARGV[0]' do
        expect(instance).to receive(:exec).with(%w(date date))
        subject
      end
    end

    context 'when the command is multiple strings' do
      let(:cmd) { ['/bin/sh', '-c', 'date'] }

      it 'runs command[0] and passes the rest as arguments' do
        expect(instance).to receive(:exec).with(
          ['/bin/sh', '/bin/sh'],
          '-c',
          'date'
        )
        subject
      end
    end
  end

  describe '#add_subprocess' do
    subject { instance.add_subprocess(cmd) }

    let(:cmd) { ['/bin/bash', '-c', "ps -o ppid -p $$ | tail -n 1 > #{tracking_file}"] }
    let(:tracking_file) { File.expand_path("#{__FILE__}.tmp") }

    # Clean up after ourselves
    around do |example|
      begin
        FileUtils.touch(tracking_file)
        example.call
      ensure
        FileUtils.rm_f(tracking_file)
      end
    end

    it 'forks the current process' do
      subject
      sleep 0.1 # let the child spawn and write to the file
      # Expect that the current process' id has been found by the child and written
      expect(File.read(tracking_file).to_i).to eq($$)
    end
  end
end
