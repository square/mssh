require_relative '../lib/mcmd'

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
end
