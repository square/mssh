# -*- encoding: utf-8 -*-
Gem::Specification.new do |s|
  s.name        = 'mssh'
  s.version     = '0.0.12'
  s.platform    = Gem::Platform::RUBY
  s.authors     = ['Evan Miller']
  s.email       = ['github@squareup.com']
  s.summary     = 'Parallel ssh and command execution.'
  s.description = 'Simple library for running jobs and sshing to many hosts at once.'
  s.homepage    = 'http://github.com/square/mssh'

  s.required_rubygems_version = '>= 1.3.6'

  s.default_executable = %q{mssh}
  s.executables = %W{ mssh mcmd }


  s.files        = %w{lib/mcmd.rb lib/cli.rb bin/mcmd bin/mssh } + %w(README.md)
  s.extra_rdoc_files = ['LICENSE.md']
  s.rdoc_options = ['--charset=UTF-8']

  s.add_dependency 'json'
  s.add_dependency 'io-poll'
  s.add_development_dependency 'rspec'
  s.add_development_dependency 'rubocop', '0.40.0'
end

