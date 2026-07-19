local TestUtils = {}

function TestUtils.trim(str)
    if not str then return "" end
    return str:gsub("^%s+", ""):gsub("%s+$", "")
end

function TestUtils.assert_equal(expected, actual, message)
    if expected ~= actual then
        error(string.format("%s: Expected '%s', got '%s'", message or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

function TestUtils.assert_not_nil(value, message)
    if value == nil then
        error(message or "Value is nil")
    end
end

function TestUtils.assert_nil(value, message)
    if value ~= nil then
        error(string.format("%s: Expected nil, got '%s'", message or "Assertion failed", tostring(value)))
    end
end

function TestUtils.assert_true(value, message)
    if not value then
        error(message or "Value is not true")
    end
end

function TestUtils.assert_false(value, message)
    if value then
        error(message or "Value is not false")
    end
end

function TestUtils.assert_contains(str, pattern, message)
    if not str:find(pattern, 1, true) then
        error(string.format("%s: String '%s' does not contain '%s'", message or "Assertion failed", tostring(str), tostring(pattern)))
    end
end

function TestUtils.assert_not_contains(str, pattern, message)
    if str:find(pattern, 1, true) then
        error(string.format("%s: String '%s' should not contain '%s'", message or "Assertion failed", tostring(str), tostring(pattern)))
    end
end

function TestUtils.run_test(name, test_func)
    local ok, err = pcall(test_func)
    if ok then
        print("✓ " .. name)
        return true
    else
        print("✗ " .. name)
        print("  Error: " .. tostring(err))
        return false
    end
end

function TestUtils.run_tests(tests)
    local passed = 0
    local failed = 0
    for i, test in ipairs(tests) do
        if TestUtils.run_test(test.name, test.func) then
            passed = passed + 1
        else
            failed = failed + 1
        end
    end
    print("\n---")
    print(string.format("Passed: %d, Failed: %d", passed, failed))
    return failed == 0
end

function TestUtils.mock_module(name, mock)
    package.loaded[name] = mock
end

function TestUtils.unmock_module(name)
    package.loaded[name] = nil
end

return TestUtils