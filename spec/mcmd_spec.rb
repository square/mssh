require_relative '../lib/mcmd'

# To run this test suite locally you must be able to ssh to localhost as the
# current user without a passphrase.
# Or you could help the maintainers out by figuring out a better way to mock.
describe MultipleCmd do
  Localhost = `hostname`

  describe '.run' do
    let(:targets) { ['localhost', 'localhost'] }
    let(:command) { "hostname" }
    let(:maxflight) { targets.size }
    let(:instance) do
      MultipleCmd.new.tap do |m|
        m.commands = targets.map { ["/bin/sh", "-c", command] }
        m.maxflight = maxflight
      end
    end

    subject(:run) { instance.run }

    context 'a simple command on multiple hosts' do
      it 'executes the command remotely' do
        result = run
        expect(result.size).to eq(2)
        first, second = result

        expect(first[:stdout_buf]).to eq(second[:stdout_buf])
        expect(first[:stderr_buf]).to eq(second[:stderr_buf])
        expect(first[:command]).to eq(second[:command])

        expect(first[:stdout_buf]).to eq(Localhost)
        expect(first[:stderr_buf]).to eq('')
        expect(first[:retval].pid).to eq(first[:pid])
        expect(first[:retval].exitstatus).to be(0)
        expect(first[:write_buf_position]).to be(0)
        expect(first[:command]).to eq(['/bin/sh', '-c', 'hostname'])
        expect(first[:time_start]).to be_within(0.1).of(Time.now.to_f)
        expect(first[:time_end]).to be_within(0.1).of(Time.now.to_f)
      end
    end

    context 'when maxflight is larger than the number of hosts' do
      let(:maxflight) { 1 }
      let(:command) { 'sleep 1' }

      it 'serializes the executions' do
        result = run
        expect(result.size).to eq(2)
        first, second = result
        # The first one starts
        expect(first[:time_start]).to be_within(0.1).of(Time.now.to_f - 2)
        # And takes a second
        expect(first[:time_end]).to be_within(0.1).of(Time.now.to_f - 1)
        # And the second one starts right around the time the first one ends
        expect(second[:time_start]).to be_within(0.1).of(first[:time_end])
        expect(second[:time_end]).to be_within(0.1).of(Time.now.to_f)
      end
    end
  end
end
