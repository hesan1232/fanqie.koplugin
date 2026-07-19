package.path = package.path .. ";../?.lua;../lib/?.lua;./?.lua"

local TestUtils = require("tests.test_utils")

local test_modules = {
    "tests.test_fanqie",
    "tests.test_content",
    "tests.test_cookie",
    "tests.test_crypto",
    "tests.test_client",
}

local all_passed = true

print("========================================")
print(" FanQie Plugin - Unit Tests")
print("========================================")
print()

for _, module_name in ipairs(test_modules) do
    print("----------------------------------------")
    local ok, test_module = pcall(require, module_name)
    if ok then
        print("Running: " .. test_module.name)
        print()
        local passed = TestUtils.run_tests(test_module.tests)
        if not passed then
            all_passed = false
        end
    else
        print("Error loading " .. module_name .. ": " .. test_module)
        all_passed = false
    end
    print()
end

print("========================================")
if all_passed then
    print("All tests passed! ✓")
else
    print("Some tests failed! ✗")
    os.exit(1)
end
print("========================================")