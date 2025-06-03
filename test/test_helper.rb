require 'simplecov'
require 'simplecov-cobertura'

SimpleCov.command_name 'Unit Tests'

SimpleCov.formatter = SimpleCov::Formatter::CoberturaFormatter

SimpleCov.start do
  coverage_dir 'coverage'
  minimum_coverage 0
end
