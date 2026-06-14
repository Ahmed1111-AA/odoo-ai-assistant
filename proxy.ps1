# Odoo CORS Proxy Server with TOTP Support (PowerShell)
# Forwards requests from localhost:3001 to the Odoo instance,
# adding CORS headers and managing session cookies.
# Supports two-step login: password + TOTP code.

param(
    [int]$Port = 3001,
    [string]$OdooUrl = ""  # No hardcoded default — pass via -OdooUrl or use X-Odoo-Target-Url header
)

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:${Port}/")
$listener.Start()

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Odoo CORS Proxy Server (TOTP-enabled)" -ForegroundColor Green
Write-Host "  Listening on: http://localhost:${Port}" -ForegroundColor Yellow
Write-Host "  Proxying to:  $OdooUrl" -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

# Cookie jar to persist session cookies across requests (using CookieContainer)
$script:cookieContainer = [System.Net.CookieContainer]::new()

function Send-Proxy-Request {
    param(
        [string]$Method,
        [string]$TargetUrl,
        [string]$Body,
        [string]$ContentType = "application/json"
    )

    $webRequest = [System.Net.HttpWebRequest]::Create($TargetUrl)
    $webRequest.Method = $Method
    $webRequest.ContentType = $ContentType
    $webRequest.CookieContainer = $script:cookieContainer
    $webRequest.AllowAutoRedirect = $false
    $webRequest.UserAgent = "OdooAIAssistant/1.0"

    if ($Body.Length -gt 0) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $webRequest.ContentLength = $bytes.Length
        $reqStream = $webRequest.GetRequestStream()
        $reqStream.Write($bytes, 0, $bytes.Length)
        $reqStream.Close()
    }

    try {
        $webResponse = $webRequest.GetResponse()
    } catch [System.Net.WebException] {
        $webResponse = $_.Exception.Response
    }

    return $webResponse
}

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        # Handle CORS
        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $response.Headers.Add("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, X-Odoo-Target-Url, x-api-key, anthropic-version")

        # Resolve target Odoo URL dynamically
        $targetOdooUrl = $request.Headers["X-Odoo-Target-Url"]
        if (-not $targetOdooUrl) {
            $targetOdooUrl = $OdooUrl
        }
        $targetOdooUrl = $targetOdooUrl.TrimEnd('/')

        if ($request.HttpMethod -eq "OPTIONS") {
            $response.StatusCode = 204
            $response.Close()
            continue
        }

        $path = $request.Url.AbsolutePath
        $reader = [System.IO.StreamReader]::new($request.InputStream)
        $body = $reader.ReadToEnd()
        $reader.Close()

        # --- Special endpoint: Anthropic API forwarder -------------------
        if ($path -eq "/proxy/anthropic/v1/messages") {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Forwarding to Anthropic Messages API" -ForegroundColor Cyan
            
            $apiKey = $request.Headers["x-api-key"]
            $anthropicVersion = $request.Headers["anthropic-version"]
            
            $webRequest = [System.Net.HttpWebRequest]::Create("https://api.anthropic.com/v1/messages")
            $webRequest.Method = "POST"
            $webRequest.ContentType = "application/json"
            $webRequest.Headers.Add("x-api-key", $apiKey)
            $webRequest.Headers.Add("anthropic-version", $anthropicVersion)
            $webRequest.UserAgent = "OdooAIAssistant/1.0"
            
            if ($body.Length -gt 0) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                $webRequest.ContentLength = $bytes.Length
                $reqStream = $webRequest.GetRequestStream()
                $reqStream.Write($bytes, 0, $bytes.Length)
                $reqStream.Close()
            }
            
            try {
                $webResponse = $webRequest.GetResponse()
            } catch [System.Net.WebException] {
                $webResponse = $_.Exception.Response
            }
            
            if ($webResponse) {
                $respStream = $webResponse.GetResponseStream()
                $respReader = [System.IO.StreamReader]::new($respStream)
                $respBody = $respReader.ReadToEnd()
                $respReader.Close()
                $webResponse.Close()
                
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($respBody)
                $response.ContentType = "application/json"
                $response.StatusCode = [int]$webResponse.StatusCode
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } else {
                $errMsg = '{"error": "No response from Anthropic API"}'
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
                $response.StatusCode = 502
                $response.ContentType = "application/json"
                $response.ContentLength64 = $errBytes.Length
                $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
            }
            $response.Close()
            continue
        }

        # --- Special endpoint: /proxy/login-totp ------------------------
        # This performs the full 2-step Odoo web login (password + TOTP)
        # using form POSTs instead of JSON-RPC, which is required for TOTP.
        if ($path -eq "/proxy/login-totp") {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] TOTP LOGIN FLOW STARTED" -ForegroundColor Cyan

            $payload = $body | ConvertFrom-Json
            $db = $payload.db
            $login = $payload.login
            $password = $payload.password
            $totpCode = $payload.totp_code
            if ($payload.odoo_url) {
                $targetOdooUrl = $payload.odoo_url.TrimEnd('/')
            }

            # Reset cookie jar for fresh login
            $script:cookieContainer = [System.Net.CookieContainer]::new()

            # Step 1: GET the login page to get the CSRF token
            Write-Host "  Step 1: Fetching login page for CSRF token..." -ForegroundColor Gray
            $loginPageReq = [System.Net.HttpWebRequest]::Create("${targetOdooUrl}/web/login")
            $loginPageReq.Method = "GET"
            $loginPageReq.CookieContainer = $script:cookieContainer
            $loginPageReq.AllowAutoRedirect = $false
            $loginPageReq.UserAgent = "OdooAIAssistant/1.0"

            try {
                $loginPageResp = $loginPageReq.GetResponse()
                $loginPageStream = $loginPageResp.GetResponseStream()
                $loginPageReader = [System.IO.StreamReader]::new($loginPageStream)
                $loginPageHtml = $loginPageReader.ReadToEnd()
                $loginPageReader.Close()
                $loginPageResp.Close()
            } catch [System.Net.WebException] {
                $loginPageResp = $_.Exception.Response
                if ($loginPageResp) {
                    $loginPageStream = $loginPageResp.GetResponseStream()
                    $loginPageReader = [System.IO.StreamReader]::new($loginPageStream)
                    $loginPageHtml = $loginPageReader.ReadToEnd()
                    $loginPageReader.Close()
                    $loginPageResp.Close()
                } else {
                    $loginPageHtml = ""
                }
            }

            # Extract CSRF token
            $csrfMatch = [regex]::Match($loginPageHtml, 'name="csrf_token"\s+value="([^"]+)"')
            if (-not $csrfMatch.Success) {
                $csrfMatch = [regex]::Match($loginPageHtml, "csrf_token['\s]*[:=]\s*['\x22]([^'\x22]+)['\x22]")
            }
            $csrfToken = if ($csrfMatch.Success) { $csrfMatch.Groups[1].Value } else { "" }
            Write-Host "  CSRF Token: $($csrfToken.Substring(0, [Math]::Min(20, $csrfToken.Length)))..." -ForegroundColor DarkYellow

            # Step 2: POST login credentials
            Write-Host "  Step 2: Submitting credentials..." -ForegroundColor Gray
            $formBody = "db=$([System.Uri]::EscapeDataString($db))&login=$([System.Uri]::EscapeDataString($login))&password=$([System.Uri]::EscapeDataString($password))&csrf_token=$([System.Uri]::EscapeDataString($csrfToken))"

            $loginResp = Send-Proxy-Request -Method "POST" -TargetUrl "${targetOdooUrl}/web/login" -Body $formBody -ContentType "application/x-www-form-urlencoded"

            if ($loginResp) {
                $loginRespStream = $loginResp.GetResponseStream()
                $loginRespReader = [System.IO.StreamReader]::new($loginRespStream)
                $loginRespBody = $loginRespReader.ReadToEnd()
                $loginRespReader.Close()
                $location = $loginResp.Headers["Location"]
                $statusCode = [int]$loginResp.StatusCode
                $loginResp.Close()

                Write-Host "  Login response: $statusCode, Location: $location" -ForegroundColor Gray

                # Check if redirected to TOTP page
                $needsTotp = $location -match "totp" -or $loginRespBody -match "totp" -or $loginRespBody -match "Two-factor"

                if ($needsTotp -and $totpCode) {
                    # Step 3: Follow redirect to TOTP page if needed
                    if ($location) {
                        $totpUrl = if ($location.StartsWith("http")) { $location } else { "${targetOdooUrl}${location}" }
                    } else {
                        $totpUrl = "${targetOdooUrl}/web/login/totp"
                    }

                    Write-Host "  Step 3: Fetching TOTP page for CSRF..." -ForegroundColor Gray
                    $totpPageReq = [System.Net.HttpWebRequest]::Create($totpUrl)
                    $totpPageReq.Method = "GET"
                    $totpPageReq.CookieContainer = $script:cookieContainer
                    $totpPageReq.AllowAutoRedirect = $true
                    $totpPageReq.UserAgent = "OdooAIAssistant/1.0"

                    try {
                        $totpPageResp = $totpPageReq.GetResponse()
                        $totpPageStream = $totpPageResp.GetResponseStream()
                        $totpPageReader = [System.IO.StreamReader]::new($totpPageStream)
                        $totpPageHtml = $totpPageReader.ReadToEnd()
                        $totpPageReader.Close()
                        $totpPageResp.Close()
                    } catch {
                        $totpPageHtml = ""
                    }

                    # Extract CSRF token from TOTP page
                    $csrfMatch2 = [regex]::Match($totpPageHtml, 'name="csrf_token"\s+value="([^"]+)"')
                    $csrfToken2 = if ($csrfMatch2.Success) { $csrfMatch2.Groups[1].Value } else { $csrfToken }

                    # Step 4: Submit TOTP code
                    Write-Host "  Step 4: Submitting TOTP code..." -ForegroundColor Gray
                    $totpFormBody = "totp_token=$([System.Uri]::EscapeDataString($totpCode))&csrf_token=$([System.Uri]::EscapeDataString($csrfToken2))"

                    $totpResp = Send-Proxy-Request -Method "POST" -TargetUrl "${targetOdooUrl}/web/login/totp" -Body $totpFormBody -ContentType "application/x-www-form-urlencoded"

                    if ($totpResp) {
                        $totpRespStream = $totpResp.GetResponseStream()
                        $totpRespReader = [System.IO.StreamReader]::new($totpRespStream)
                        $totpRespBody = $totpRespReader.ReadToEnd()
                        $totpRespReader.Close()
                        $totpLocation = $totpResp.Headers["Location"]
                        $totpStatus = [int]$totpResp.StatusCode
                        $totpResp.Close()

                        Write-Host "  TOTP response: $totpStatus, Location: $totpLocation" -ForegroundColor Gray

                        # If redirected to /web or /odoo, login succeeded!
                        if ($totpLocation -match "/web|/odoo" -or $totpStatus -eq 303 -or $totpStatus -eq 302) {
                            # Follow redirect to establish full session
                            $finalUrl = if ($totpLocation.StartsWith("http")) { $totpLocation } else { "${targetOdooUrl}${totpLocation}" }
                            $finalReq = [System.Net.HttpWebRequest]::Create($finalUrl)
                            $finalReq.Method = "GET"
                            $finalReq.CookieContainer = $script:cookieContainer
                            $finalReq.AllowAutoRedirect = $true
                            $finalReq.UserAgent = "OdooAIAssistant/1.0"
                            try {
                                $finalResp = $finalReq.GetResponse()
                                $finalResp.Close()
                            } catch {}

                            # Now get session info via JSON-RPC
                            $sessionCheckBody = '{"jsonrpc":"2.0","method":"call","id":99,"params":{}}'
                            $sessResp = Send-Proxy-Request -Method "POST" -TargetUrl "${targetOdooUrl}/web/session/get_session_info" -Body $sessionCheckBody
                            if ($sessResp) {
                                $sessStream = $sessResp.GetResponseStream()
                                $sessReader = [System.IO.StreamReader]::new($sessStream)
                                $sessBody = $sessReader.ReadToEnd()
                                $sessReader.Close()
                                $sessResp.Close()

                                Write-Host "  SESSION INFO: $($sessBody.Substring(0, [Math]::Min(200, $sessBody.Length)))" -ForegroundColor Green

                                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($sessBody)
                                $response.ContentType = "application/json"
                                $response.StatusCode = 200
                                $response.ContentLength64 = $respBytes.Length
                                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                                $response.Close()
                                continue
                            }
                        }

                        # TOTP failed — check for error in body
                        $errorMsg = if ($totpRespBody -match "Invalid.*code|wrong.*code|incorrect") { "Invalid TOTP code" } else { "TOTP verification failed (status: $totpStatus)" }
                        $errJson = @{jsonrpc="2.0";id=1;error=@{message=$errorMsg}} | ConvertTo-Json -Depth 3
                        $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
                        $response.ContentType = "application/json"
                        $response.StatusCode = 200
                        $response.ContentLength64 = $errBytes.Length
                        $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                        $response.Close()
                        Write-Host "  TOTP FAILED: $errorMsg" -ForegroundColor Red
                        continue
                    }
                } elseif ($needsTotp -and -not $totpCode) {
                    # TOTP required but no code provided
                    $errJson = @{jsonrpc="2.0";id=1;result=@{uid=$null;totp_required=$true;message="Two-Factor Authentication required. Please enter your 6-digit TOTP code."}} | ConvertTo-Json -Depth 3
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
                    $response.ContentType = "application/json"
                    $response.StatusCode = 200
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                    $response.Close()
                    Write-Host "  TOTP REQUIRED (no code provided)" -ForegroundColor Yellow
                    continue
                } elseif (-not $needsTotp -and ($statusCode -eq 303 -or $statusCode -eq 302)) {
                    # Login succeeded without TOTP
                    Write-Host "  LOGIN SUCCESS (no TOTP needed)" -ForegroundColor Green
                    $sessionCheckBody = '{"jsonrpc":"2.0","method":"call","id":99,"params":{}}'
                    $sessResp = Send-Proxy-Request -Method "POST" -TargetUrl "${targetOdooUrl}/web/session/get_session_info" -Body $sessionCheckBody
                    if ($sessResp) {
                        $sessStream = $sessResp.GetResponseStream()
                        $sessReader = [System.IO.StreamReader]::new($sessStream)
                        $sessBody = $sessReader.ReadToEnd()
                        $sessReader.Close()
                        $sessResp.Close()

                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($sessBody)
                        $response.ContentType = "application/json"
                        $response.StatusCode = 200
                        $response.ContentLength64 = $respBytes.Length
                        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                        $response.Close()
                        continue
                    }
                }

                # Login failed (wrong credentials)
                $errJson = @{jsonrpc="2.0";id=1;result=@{uid=$null;message="Login failed. Check credentials."}} | ConvertTo-Json -Depth 3
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
                $response.ContentType = "application/json"
                $response.StatusCode = 200
                $response.ContentLength64 = $errBytes.Length
                $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                $response.Close()
                Write-Host "  LOGIN FAILED" -ForegroundColor Red
                continue
            }

            $errJson = '{"jsonrpc":"2.0","id":1,"error":{"message":"No response from Odoo"}}'
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
            $response.ContentType = "application/json"
            $response.StatusCode = 502
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
            $response.Close()
            continue
        }

        # --- Standard JSON-RPC proxy ------------------------------------
        $targetUrl = "${targetOdooUrl}${path}"
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($request.HttpMethod) $path -> $targetUrl" -ForegroundColor Gray

        $webResponse = Send-Proxy-Request -Method $request.HttpMethod -TargetUrl $targetUrl -Body $body

        if ($webResponse) {
            $respStream = $webResponse.GetResponseStream()
            $respReader = [System.IO.StreamReader]::new($respStream)
            $respBody = $respReader.ReadToEnd()
            $respReader.Close()
            $webResponse.Close()

            $respBytes = [System.Text.Encoding]::UTF8.GetBytes($respBody)
            $response.ContentType = "application/json"
            $response.StatusCode = [int]$webResponse.StatusCode
            $response.ContentLength64 = $respBytes.Length
            $response.OutputStream.Write($respBytes, 0, $respBytes.Length)

            if ($path -match "authenticate") {
                $parsed = $respBody | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($parsed.result.uid) {
                    Write-Host "  AUTH SUCCESS: uid=$($parsed.result.uid)" -ForegroundColor Green
                } else {
                    Write-Host "  AUTH FAILED (uid null - likely TOTP)" -ForegroundColor Yellow
                }
            }
        } else {
            $errMsg = '{"error": "No response from Odoo server"}'
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
            $response.StatusCode = 502
            $response.ContentType = "application/json"
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
            Write-Host "  ERROR: No response from upstream" -ForegroundColor Red
        }

        $response.Close()
    } catch {
        Write-Host "Error: $_" -ForegroundColor Red
    }
}
