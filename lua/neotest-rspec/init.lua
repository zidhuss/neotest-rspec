local async = require('neotest.async')
local lib = require('neotest.lib')
local logger = require('neotest.logging')

---@class neotest.Adapter
---@field name string
local NeotestAdapter = { name = 'neotest-rspec' }

---Find the project root directory given a current directory to work from.
---Should no root be found, the adapter can still be used in a non-project context if a test file matches.
---@async
---@param dir string @Directory to treat as cwd
---@return string | nil @Absolute root dir of test suite
NeotestAdapter.root = lib.files.match_root_pattern({ 'Gemfile', '.rspec' })

---@async
---@param file_path string
---@return boolean
function NeotestAdapter.is_test_file(file_path)
  return vim.endswith(file_path, '_spec.rb') and true or false
end

---Given a file path, parse all the tests within it.
---@async
---@param file_path string Absolute file path
---@return neotest.Tree | nil
function NeotestAdapter.discover_positions(path)
  local query = [[
  ((call
      method: (identifier) @func_name (#match? @func_name "^(describe|context)$")
      arguments: (argument_list (_) @namespace.name)
  )) @namespace.definition

  ((call
    method: (identifier) @func_name (#eq? @func_name "it")
    arguments: (argument_list (_) @test.name)
  )) @test.definition
    ]]
  return lib.treesitter.parse_positions(path, query, { nested_tests = true })
end

---@param args neotest.RunArgs
---@return neotest.RunSpec | nil
function NeotestAdapter.build_spec(args)
  local position = args.tree:data()
  local results_path = async.fn.tempname()
  local root = NeotestAdapter.root(position.path)

  local runner = vim.tbl_flatten({
    'bundle',
    'exec',
    'rspec',
  })
  local script_args = vim.tbl_flatten({
    '-f',
    'json',
    '-o',
    results_path,
  })

  if position.type == 'file' then
    table.insert(script_args, position.path)
  end
  -- TODO: Write command for single tests to improve performance in large RSpec files
  -- if position.type == 'test' or position.type == 'namespace' then
  --   table.insert(
  --     script_args,
  --     vim.tbl_flatten({
  --       '-e',
  --       position.name,
  --     })
  --   )
  -- end

  local command = vim.tbl_flatten({
    runner,
    script_args,
  })

  return {
    command = command,
    context = {
      results_path = results_path,
    },
  }
end

local function parse_json_output(data, output_file, tree)
  local tests = {}

  for _, value in tree:iter() do
    -- Link the neotest id to the RSpec output
    local test_id = value.id:gsub(value.path, ''):gsub('::', ' '):gsub('"', ''):gsub("'", ''):sub(2)

    -- Get the test result from the parsed data
    for _, result in pairs(data.examples) do
      if result.full_description == test_id then
        local status, name = result.status, result.description
        if not tests[value.id] then
          tests[value.id] = {
            status = status == 'pending' and 'skipped' or status,
            short = test_id .. ': ' .. status,
            output = output_file,
            location = result.line_number,
          }
          if result.exception then
            tests[value.id].short = tests[value.id].short .. '\n' .. result.exception.message
            tests[value.id].errors = result.exception.backtrace
          end
        end
      end
    end
  end

  return tests
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return neotest.Result[]
function NeotestAdapter.results(spec, result, tree)
  local output_file = spec.context.results_path

  local success, data = pcall(lib.files.read, output_file)
  if not success then
    logger.error('No test output file found ', output_file)
    return {}
  end

  local ok, parsed_data = pcall(vim.json.decode, data, { luanil = { object = true } })
  if not ok then
    logger.error('Failed to parse test output ', output_file)
    return {}
  end

  return parse_json_output(parsed_data, output_file, tree)
end

setmetatable(NeotestAdapter, {
  __call = function()
    return NeotestAdapter
  end,
})

return NeotestAdapter
