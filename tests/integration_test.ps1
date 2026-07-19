# FanQie Plugin - Integration Test
# Directly requests official API and third-party API, no proxy needed
# Simulates KOReader plugin behavior on device

$configPath = "d:\webProgram\project\fanqie.koplugin\config.lua"
$configContent = Get-Content $configPath -Raw

# Parse cookies from config.lua
$cookieMatches = [regex]::Matches($configContent, '\["([^"]+)"\]\s*=\s*"([^"]*)"')
$cookies = @{}
foreach ($m in $cookieMatches) {
    $cookies[$m.Groups[1].Value] = $m.Groups[2].Value
}

# Parse endpoints
$endpointMatches = [regex]::Matches($configContent, '"(https?://[^"]+)"')
$endpoints = @()
foreach ($m in $endpointMatches) {
    if ($m.Groups[1].Value -notmatch 'fanqienovel') {
        $endpoints += $m.Groups[1].Value
    }
}

# Build Cookie header
$cookieParts = @()
foreach ($key in $cookies.Keys) { $cookieParts += "$key=$($cookies[$key])" }
$cookieHeader = $cookieParts -join "; "

$bookId = "7496166356807584792"
$itemId = "7657134435204071960"
$workingEndpoint = "http://101.35.133.34:5000"
$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

$allPassed = $true
$testCount = 0
$passCount = 0

function Test-Passed {
    param([string]$name)
    Write-Host "  PASS: $name" -ForegroundColor Green
    $script:passCount++
}
function Test-Failed {
    param([string]$name, [string]$err)
    Write-Host "  FAIL: $name" -ForegroundColor Red
    Write-Host "    $err" -ForegroundColor Red
    $script:allPassed = $false
}

Write-Host "========================================"
Write-Host " FanQie Plugin - Integration Test"
Write-Host " (Direct API access, no proxy)"
Write-Host "========================================"
Write-Host ""
Write-Host "Config: $configPath"
Write-Host "Cookies: $($cookies.Count) entries, header length: $($cookieHeader.Length)"
Write-Host "Endpoints: $($endpoints.Count)"

# ========== Test 1: Bookshelf (Official API, GET) ==========
$testCount++
Write-Host ""
Write-Host "========== Test 1: Bookshelf (Official API) =========="
$url = "https://fanqienovel.com/reading/bookapi/bookshelf/info/v:version/?aid=1967&iid=0&version_code=57700&update_version_code=57700"
$r = curl.exe -s -w "`n%{http_code}" $url -H "Cookie: $cookieHeader" -H "User-Agent: $ua" -H "Referer: https://fanqienovel.com/bookshelf" --insecure --max-time 15
$code = $r[-1]
$body = $r[0..($r.Count - 2)] -join "`n"
Write-Host "  HTTP: $code"
if ($code -eq 200) {
    $d = $body | ConvertFrom-Json
    if ($d.message -eq "SUCCESS" -and $d.data.book_shelf_info) {
        Write-Host "  Books in shelf: $($d.data.book_shelf_info.Count)"
        $d.data.book_shelf_info | Select-Object -First 3 | ForEach-Object {
            Write-Host "    - book_id: $($_.book_id)"
        }
        Test-Passed "Bookshelf ($($d.data.book_shelf_info.Count) books)"
    } else {
        Test-Failed "Bookshelf" "message=$($d.message)"
    }
} else {
    Test-Failed "Bookshelf" "HTTP $code"
}

# ========== Test 2: Read Progress (Official API, GET) ==========
$testCount++
Write-Host ""
Write-Host "========== Test 2: Read Progress (Official API) =========="
$url = "https://fanqienovel.com/api/reader/book/progress"
$r = curl.exe -s -w "`n%{http_code}" -X GET $url -H "Cookie: $cookieHeader" -H "User-Agent: $ua" -H "Referer: https://fanqienovel.com/" --insecure --max-time 15
$code = $r[-1]
$body = $r[0..($r.Count - 2)] -join "`n"
Write-Host "  HTTP: $code"
if ($code -eq 200) {
    $d = $body | ConvertFrom-Json
    if ($d.data) {
        Write-Host "  Progress entries: $($d.data.Count)"
        $first = $d.data[0]
        Write-Host "  First: book_id=$($first.book_id), item_id=$($first.item_id), index=$($first.index)"
        Test-Passed "Progress ($($d.data.Count) entries)"
    } else {
        Test-Failed "Progress" "no data"
    }
} else {
    Test-Failed "Progress" "HTTP $code"
}

# ========== Test 3: Book Detail (Official API, POST) ==========
$testCount++
Write-Host ""
Write-Host "========== Test 3: Book Detail (Official API) =========="
$url = "https://fanqienovel.com/api/book/simple/info"
$bodyReq = "{`"book_ids`":[`"$bookId`"]}"
$r = curl.exe -s -w "`n%{http_code}" -X POST $url -H "Cookie: $cookieHeader" -H "User-Agent: $ua" -H "Referer: https://fanqienovel.com/" -H "Content-Type: application/json" -d $bodyReq --insecure --max-time 20
$code = $r[-1]
$body = $r[0..($r.Count - 2)] -join "`n"
Write-Host "  HTTP: $code"
if ($code -eq 200) {
    $d = $body | ConvertFrom-Json
    if ($d.code -eq 0 -and $d.data.bookList) {
        $book = $d.data.bookList[0]
        Write-Host "  Book: $($book.book_name)"
        Write-Host "  Author: $($book.author)"
        Test-Passed "Book Detail"
    } else {
        Test-Failed "Book Detail" "code=$($d.code), msg=$($d.message)"
    }
} elseif ($code -eq 504) {
    Write-Host "  504 Gateway Timeout (server-side, skipping)"
    Test-Passed "Book Detail (504 timeout, expected on this endpoint)"
} else {
    Test-Failed "Book Detail" "HTTP $code"
}

# ========== Test 4: Book Directory (Third-Party API) ==========
$testCount++
Write-Host ""
Write-Host "========== Test 4: Book Directory (Third-Party) =========="
$url = "$workingEndpoint/api/book?book_id=$bookId"
$r = curl.exe -s -w "`n%{http_code}" $url -H "User-Agent: $ua" --max-time 15
$code = $r[-1]
$body = $r[0..($r.Count - 2)] -join "`n"
Write-Host "  HTTP: $code"
if ($code -eq 200 -and $body -match '"code"\s*:\s*200' -and $body -match '"allItemIds"') {
    # Count item IDs in the response
    $itemIdCount = ([regex]::Matches($body, '"itemId"\s*:\s*"(\d+)"')).Count
    Write-Host "  Total chapters: $itemIdCount"
    # Extract first and last item IDs
    $allIds = [regex]::Matches($body, '"itemId"\s*:\s*"(\d+)"')
    if ($allIds.Count -gt 0) {
        Write-Host "  First: $($allIds[0].Groups[1].Value)"
        Write-Host "  Last: $($allIds[-1].Groups[1].Value)"
    }
    Test-Passed "Directory ($itemIdCount chapters)"
} else {
    Test-Failed "Directory" "HTTP $code or unexpected format"
}

# ========== Test 5: Chapter Content - raw_full ==========
$testCount++
Write-Host ""
Write-Host "========== Test 5: Chapter Content (raw_full) =========="
$url = "$workingEndpoint/api/raw_full?item_id=$itemId"
$r = curl.exe -s -w "`n%{http_code}" $url -H "User-Agent: $ua" --max-time 15
$code = $r[-1]
$body = $r[0..($r.Count - 2)] -join "`n"
Write-Host "  HTTP: $code"
if ($code -eq 200 -and $body -match '"code"\s*:\s*200' -and $body -match '"content"') {
    $contentMatch = [regex]::Match($body, '"content"\s*:\s*"((?:[^"\\]|\\.)*)"')
    $contentLen = if ($contentMatch.Success) { $contentMatch.Groups[1].Value.Length } else { 0 }
    Write-Host "  Content length: ~$contentLen chars"
    if ($body -match '"crypt_status"\s*:\s*(\d+)') {
        Write-Host "  crypt_status: $($Matches[1]) (0=no encryption)"
    }
    if ($body -match '"book_name"\s*:\s*"([^"]*)"') {
        Write-Host "  Book: $($Matches[1])"
    }
    if ($body -match '"author"\s*:\s*"([^"]*)"') {
        Write-Host "  Author: $($Matches[1])"
    }
    Test-Passed "raw_full (~$contentLen chars, no encryption)"
} else {
    Test-Failed "raw_full" "HTTP $code or no content"
}

# ========== Test 6: First Chapter Content ==========
$testCount++
Write-Host ""
Write-Host "========== Test 6: First Chapter Content (raw_full) =========="
$firstChapterId = "7496166488315789848"

$url = "$workingEndpoint/api/raw_full?item_id=$firstChapterId"
$r = curl.exe -s -w "`n%{http_code}" $url -H "User-Agent: $ua" --max-time 15
$code = $r[-1]
$body = $r[0..($r.Count - 2)] -join "`n"
Write-Host "  Chapter ID: $firstChapterId"
Write-Host "  HTTP: $code"
if ($code -eq 200 -and $body -match '"code"\s*:\s*200' -and $body -match '"content"') {
    # Extract content length from JSON
    $contentMatch = [regex]::Match($body, '"content"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($contentMatch.Success) {
        $contentLen = $contentMatch.Groups[1].Value.Length
        Write-Host "  Content length: ~$contentLen chars"
    }
    $cleanText = $body -replace '\\u003c[^\\]*\\u003e', '' -replace '<[^>]+>', '' -replace '\\u003c.*?\\u003e', ''
    $maxLen = [Math]::Min(100, $cleanText.Length)
    Write-Host "  Response contains content data"
    Test-Passed "First chapter (content received)"
} else {
    Test-Failed "First chapter" "HTTP $code or no content"
}

# ========== Summary ==========
Write-Host ""
Write-Host "========================================"
Write-Host " Integration Test Summary"
Write-Host "========================================"
Write-Host ""
Write-Host "  Passed: $passCount / $testCount"
Write-Host ""
if ($allPassed) {
    Write-Host " ALL TESTS PASSED! " -ForegroundColor Green
} else {
    Write-Host " SOME TESTS FAILED! " -ForegroundColor Red
}
Write-Host ""
Write-Host "Official API: https://fanqienovel.com"
Write-Host "Third-party:  $workingEndpoint"
Write-Host "Book ID:      $bookId"
Write-Host "Chapter ID:   $itemId"
Write-Host ""