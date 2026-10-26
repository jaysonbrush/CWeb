# Chrome - PowerShell Browser Automation Module

## What This Is
A self-contained PowerShell library for automating Chrome browser via Selenium WebDriver. This is the **core module** - it provides direct PowerShell functions for browser control.

## When To Use This Module
Use this module in **automated PowerShell scripts** that run independently:
- Scheduled tasks
- Batch processing
- Headless automation
- Any script that doesn't need human interaction during execution

## Related Module
- **CWeb** (the folder above this one) - the shared browser server agents use. Use CWeb to work with Claude in a
  browser you're signed in to; use this module directly for scripts that run on their own.

## Quick Start

```powershell
# Load the module (from the CWeb folder)
. ".\browser\Browser-Functions.ps1"

# Start browser (visible)
$browser = Chrome-Start

# Start browser (headless/hidden)
$browser = Chrome-Start -Hidden $true

# Navigate
Chrome-Navigate -Browser $browser -Url "https://example.com"

# Interact with elements
Chrome-Click -Browser $browser -By CssSelector -Value "#submit-button"
Chrome-SendKeys -Browser $browser -By Id -Value "username" -Text "myuser" -Clear

# Get page info
$title = Chrome-GetTitle -Browser $browser
$html = Chrome-GetPageSource -Browser $browser

# Close browser
Chrome-Stop -Browser $browser
```

## All Available Functions (40)

### Browser Lifecycle
| Function | Description |
|----------|-------------|
| `Chrome-Start [-Hidden $true] [-Persist $true] [-ProfileName n] [-UserDataPath p] [-WorkRoot d] [-WindowName t]` | Launch Chrome. Returns `$browser` hashtable. Profiles and temp folders live in `-WorkRoot` (default `%USERPROFILE%\CWebData\scripts`); `-Persist $true` reuses `<WorkRoot>\<ProfileName>` (default `profile`) or `-UserDataPath`. |
| `Chrome-Stop -Browser $b` | Close browser and clean up temp files. |

### Navigation
| Function | Description |
|----------|-------------|
| `Chrome-Navigate -Browser $b -Url "..."` | Go to URL and wait for page load. |
| `Chrome-Back -Browser $b` | Browser back button. |
| `Chrome-Forward -Browser $b` | Browser forward button. |
| `Chrome-Refresh -Browser $b` | Reload current page. |

### Tabs
| Function | Description |
|----------|-------------|
| `Chrome-NewTab -Browser $b [-Url "..."] [-Name "..."]` | Open new tab. |
| `Chrome-SwitchTab -Browser $b -Name "..."` | Switch to named tab. |
| `Chrome-CloseTab -Browser $b` | Close current tab. |
| `Chrome-ListTabs -Browser $b` | Get list of tab names. |

### Page Information
| Function | Description |
|----------|-------------|
| `Chrome-GetTitle -Browser $b` | Get page title. |
| `Chrome-GetCurrentUrl -Browser $b` | Get current URL. |
| `Chrome-GetPageSource -Browser $b` | Get full HTML source. |
| `Chrome-GetPageText -Browser $b [-By <type> -Value "..."]` | Get readable text (whole page or element). |
| `Chrome-Screenshot -Browser $b -FilePath "..."` | Save screenshot to file. |
| `Chrome-GetAllLinks -Browser $b` | Get all links (href, text, title). |
| `Chrome-GetAllForms -Browser $b` | Get all forms and their fields. |

### Element Interaction
| Function | Description |
|----------|-------------|
| `Chrome-FindElement -Browser $b -By <type> -Value "..."` | Find single element. |
| `Chrome-FindElements -Browser $b -By <type> -Value "..."` | Find all matching elements. |
| `Chrome-Click -Browser $b -By <type> -Value "..."` | Click element. |
| `Chrome-SendKeys -Browser $b -By <type> -Value "..." -Text "..." [-Clear]` | Type into element. |
| `Chrome-GetText -Browser $b -By <type> -Value "..."` | Get element's text content. |
| `Chrome-GetAttribute -Browser $b -By <type> -Value "..." -Attribute "..."` | Get element attribute. |
| `Chrome-GetElementHtml -Browser $b -By <type> -Value "..."` | Get element's outer HTML. |
| `Chrome-GetElementInfo -Browser $b -By <type> -Value "..."` | Get full element details (attrs, size, position). |
| `Chrome-Hover -Browser $b -By <type> -Value "..."` | Mouse hover over element. |
| `Chrome-SelectOption -Browser $b -By <type> -Value "..." -SelectBy <Text|Value|Index> -Option "..."` | Select dropdown option. |

### Scrolling
| Function | Description |
|----------|-------------|
| `Chrome-Scroll -Browser $b -Direction <Up|Down|Top|Bottom>` | Scroll page. |
| `Chrome-Scroll -Browser $b -Direction ToElement -By <type> -Value "..."` | Scroll to element. |

### Frames
| Function | Description |
|----------|-------------|
| `Chrome-SwitchToFrame -Browser $b -FrameId "..." / -FrameName "..." / -FrameIndex N` | Switch into iframe. |
| `Chrome-SwitchToFrame -Browser $b -Default` | Switch back to main content. |

### Waiting
| Function | Description |
|----------|-------------|
| `Chrome-Wait -Browser $b [-TimeoutInSeconds 30]` | Wait for page load complete. |
| `Chrome-WaitForElement -Browser $b -By <type> -Value "..." [-TimeoutInSeconds 30]` | Wait for element to exist. |
| `Chrome-WaitForUrl -Browser $b [-Contains "..."] [-Matches "..."] [-Changed]` | Wait for URL condition. |

### JavaScript & Alerts
| Function | Description |
|----------|-------------|
| `Chrome-ExecuteScript -Browser $b -Script "..." [-Arguments @()]` | Execute JavaScript on page. |
| `Chrome-AcceptAlert -Browser $b [-PromptText "..."]` | Accept JS alert/confirm/prompt. |
| `Chrome-DismissAlert -Browser $b` | Dismiss JS alert/confirm. |
| `Chrome-GetAlertText -Browser $b` | Get alert dialog text. |

### Cookies
| Function | Description |
|----------|-------------|
| `Chrome-GetCookies -Browser $b [-Name "..."]` | Get all cookies or specific one. |
| `Chrome-SetCookie -Browser $b -Name "..." -Value "..." [-Domain] [-Path]` | Set a cookie. |
| `Chrome-DeleteCookie -Browser $b [-Name "..."]` | Delete cookie(s). |

### Window Management
| Function | Description |
|----------|-------------|
| `Chrome-GetWindowSize -Browser $b` | Get window dimensions. |
| `Chrome-SetWindowSize -Browser $b -Width N -Height N` | Set window size. |
| `Chrome-Maximize -Browser $b` | Maximize window. |

## Locator Types (-By parameter)
- `Id` - Element ID attribute
- `Name` - Element name attribute
- `ClassName` - CSS class name
- `TagName` - HTML tag (div, input, etc.)
- `CssSelector` - CSS selector (recommended)
- `XPath` - XPath expression
- `LinkText` - Exact link text
- `PartialLinkText` - Partial link text match

## Example: Login Automation

```powershell
. "<CWeb>\browser\Browser-Functions.ps1"

$browser = Chrome-Start -Hidden $true

try {
    # Navigate to login page
    Chrome-Navigate -Browser $browser -Url "https://example.com/login"

    # Enter credentials
    Chrome-SendKeys -Browser $browser -By Id -Value "username" -Text $env:USERNAME -Clear
    Chrome-SendKeys -Browser $browser -By Id -Value "password" -Text $password -Clear

    # Submit
    Chrome-Click -Browser $browser -By CssSelector -Value "button[type='submit']"

    # Wait for redirect
    Chrome-WaitForElement -Browser $browser -By Id -Value "dashboard" -TimeoutInSeconds 10

    # Verify login success
    $title = Chrome-GetTitle -Browser $browser
    if ($title -match "Dashboard") {
        Write-Host "Login successful"
    }
} finally {
    Chrome-Stop -Browser $browser
}
```

## File Structure

```
<CWeb>\browser\
├── Browser-Functions.ps1    # Main library (load this)
├── Update-Browser.ps1       # Update Chrome/ChromeDriver/Selenium
├── Test-Browser.ps1         # Quick test script
├── version.json            # Current component versions
├── README.md               # User documentation
├── CLAUDE.md               # This file
├── chrome-win64/           # Chrome for Testing browser
├── chromedriver-win64/     # ChromeDriver executable
└── Selenium/               # Selenium WebDriver DLLs
```

## Updating Components

```powershell
# Update Chrome and ChromeDriver to latest stable
.\Update-Browser.ps1

# Update everything including Selenium
.\Update-Browser.ps1 -UpdateSelenium

# Preview without changing anything
.\Update-Browser.ps1 -UpdateSelenium -WhatIf

# Check versions
Get-Content .\version.json | ConvertFrom-Json
```

- **Stop every CWeb instance first** (each status page's **Stop server**). Chrome's files and the Selenium DLL are
  locked while one runs. `browser\chrome-win64\`, `chromedriver-win64\`, `Selenium\` and `backup\` are not in git;
  a fresh checkout gets them by running this updater with `-UpdateSelenium`.
- The updater backs up the current Chrome, ChromeDriver and Selenium to `.\backup\` first, and keeps the last 3.
- The backup is labelled with the version in `version.json`, which can lag behind the files if a previous run failed.
- Opening the saved profile with a newer Chrome upgrades it one way. If you roll back, the server sets the profile
  aside and starts fresh, so the user has to log in again.
- **Selenium 4.4x+ renamed its DLL** to `Selenium.WebDriver.dll` (was `WebDriver.dll`) and added a `net8.0` build.
  The updater installs the `net8.0` one (falling back to `netstandard2.0`) and keeps only one WebDriver DLL in
  `Selenium\`. `Chrome-Start` and the server's startup check accept either name.
- After updating, start an instance (the `test` instance is safest) and check the user agent's Chrome version,
  `navigator.webdriver === false`, and `{"action":"keepalive"}`.

## Requirements
- PowerShell 7+ (required for Selenium 4.x)
- Windows 10/11

## Technical Notes
- Browser returns a hashtable with: Driver, Service, Tabs, TempPath, UserDataPath
- Without `-Persist`, a throwaway profile is created per session in `-WorkRoot` and deleted on Chrome-Stop
- Chrome starts with background throttling off (`--disable-background-timer-throttling`, `--disable-renderer-backgrounding`, `--disable-backgrounding-occluded-windows`)
- Uses `$PSScriptRoot` for portable relative paths
- Selenium loaded via `Add-Type -Path` (handles already-loaded DLLs gracefully)
