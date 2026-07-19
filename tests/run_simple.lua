local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*[/\\])") or "./"
package.path = package.path .. ";" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. script_dir .. "../lib/?.lua"

local function run_tests(test_module)
    local passed = 0
    local failed = 0
    print("Running: " .. test_module.name)
    for _, test in ipairs(test_module.tests) do
        local ok, err = pcall(test.func)
        if ok then
            print("  ✓ " .. test.name)
            passed = passed + 1
        else
            print("  ✗ " .. test.name)
            print("    Error: " .. tostring(err))
            failed = failed + 1
        end
    end
    print(string.format("  Passed: %d, Failed: %d\n", passed, failed))
    return failed == 0
end

local all_passed = true

print("========================================")
print(" FanQie Plugin - Simple Unit Tests")
print("========================================")
print()

local ok, test_cookie = pcall(require, "tests.test_cookie")
if ok then
    if not run_tests(test_cookie) then all_passed = false end
else
    print("Error loading test_cookie: " .. test_cookie .. "\n")
    all_passed = false
end

local ok, test_crypto = pcall(require, "tests.test_crypto")
if ok then
    if not run_tests(test_crypto) then all_passed = false end
else
    print("Error loading test_crypto: " .. test_crypto .. "\n")
    all_passed = false
end

local ok, test_fanqie = pcall(require, "tests.test_fanqie")
if ok then
    if not run_tests(test_fanqie) then all_passed = false end
else
    print("Error loading test_fanqie: " .. test_fanqie .. "\n")
    all_passed = false
end

local ok, test_content = pcall(require, "tests.test_content")
if ok then
    if not run_tests(test_content) then all_passed = false end
else
    print("Error loading test_content: " .. test_content .. "\n")
    all_passed = false
end

local ok, test_client = pcall(require, "tests.test_client")
if ok then
    if not run_tests(test_client) then all_passed = false end
else
    print("Error loading test_client: " .. test_client .. "\n")
    all_passed = false
end

print("========================================")
if all_passed then
    print("All tests passed! ✓")
else
    print("Some tests failed! ✗")
end
print("========================================")