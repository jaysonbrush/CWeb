# Chrome - PowerShell Browser Automation

A self-contained Chrome browser automation library using Selenium WebDriver for PowerShell.

## Requirements

- **PowerShell 7+** (required for Selenium 4.x compatibility)
  ```powershell
  winget install Microsoft.PowerShell
  ```
- **Windows 10/11** (win64)

## Quick Start

```powershell
# Load the functions
. .\Browser-Functions.ps1

# Start a visible browser
$browser = Chrome-Start

# Navigate to a URL
Chrome-Navigate -Browser $browser -Url "https://example.com"

# Open a new tab
Chrome-NewTab -Browser $browser -Url "https://google.com" -Name "search"

# Switch between tabs
Chrome-SwitchTab -Browser $browser -Name "main"
Chrome-SwitchTab -Browser $browser -Name "search"

# Close the browser
Chrome-Stop -Browser $browser
```

## Components

| Component | Description |
|-----------|-------------|
| `Browser-Functions.ps1` | Browser control functions (full list in `CLAUDE.md`) |
| `Update-Browser.ps1` | Updates Chrome, ChromeDriver, and Selenium |
| `Test-Browser.ps1` | Quick test script to verify setup |
| `chrome-win64/` | Chrome for Testing browser |
| `chromedriver-win64/` | ChromeDriver executable |
| `Selenium/` | Selenium WebDriver DLLs |
| `version.json` | Tracks installed versions |

## Available Functions

### Browser Control
| Function | Description |
|----------|-------------|
| `Chrome-Start [-Hidden]` | Launch Chrome browser (use `-Hidden` for headless) |
| `Chrome-Stop -Browser $b` | Close browser and cleanup |

### Navigation
| Function | Description |
|----------|-------------|
| `Chrome-Navigate -Browser $b -Url "..."` | Navigate to URL |
| `Chrome-Back -Browser $b` | Go back in history |
| `Chrome-Forward -Browser $b` | Go forward in history |
| `Chrome-Refresh -Browser $b` | Refresh current page |

### Tab Management
| Function | Description |
|----------|-------------|
| `Chrome-NewTab -Browser $b [-Url "..."] [-Name "..."]` | Open new tab |
| `Chrome-SwitchTab -Browser $b -Name "..."` | Switch to named tab |
| `Chrome-CloseTab -Browser $b` | Close current tab |
| `Chrome-ListTabs -Browser $b` | List all named tabs |

### Page Information
| Function | Description |
|----------|-------------|
| `Chrome-GetPageSource -Browser $b` | Get HTML source of current page |
| `Chrome-GetCurrentUrl -Browser $b` | Get current URL |
| `Chrome-GetTitle -Browser $b` | Get page title |
| `Chrome-Screenshot -Browser $b -FilePath "..."` | Save screenshot to file |

### Element Interaction
| Function | Description |
|----------|-------------|
| `Chrome-FindElement -Browser $b -By <type> -Value "..."` | Find single element |
| `Chrome-FindElements -Browser $b -By <type> -Value "..."` | Find multiple elements |
| `Chrome-Click -Browser $b -By <type> -Value "..."` | Click an element |
| `Chrome-SendKeys -Browser $b -By <type> -Value "..." -Text "..." [-Clear]` | Type text into element |
| `Chrome-GetText -Browser $b -By <type> -Value "..."` | Get text content of element |
| `Chrome-GetAttribute -Browser $b -By <type> -Value "..." -Attribute "..."` | Get element attribute |
| `Chrome-Hover -Browser $b -By <type> -Value "..."` | Mouse hover over element |
| `Chrome-SelectOption -Browser $b -By <type> -Value "..." -SelectBy <Text\|Value\|Index> -Option "..."` | Select dropdown option |

### Frames
| Function | Description |
|----------|-------------|
| `Chrome-SwitchToFrame -Browser $b -FrameId "..." / -FrameName "..." / -FrameIndex N` | Switch to iframe |
| `Chrome-SwitchToFrame -Browser $b -Default` | Switch back to main content |

### Waiting
| Function | Description |
|----------|-------------|
| `Chrome-Wait -Browser $b [-TimeoutInSeconds 30]` | Wait for page load |
| `Chrome-WaitForElement -Browser $b -By <type> -Value "..." [-TimeoutInSeconds 30]` | Wait for element to exist |

### JavaScript
| Function | Description |
|----------|-------------|
| `Chrome-ExecuteScript -Browser $b -Script "..." [-Arguments @()]` | Run JavaScript on page |

**Locator Types (-By parameter):** `Id`, `Name`, `ClassName`, `TagName`, `CssSelector`, `XPath`, `LinkText`, `PartialLinkText`

## Headless Mode

For background/automated tasks, use headless mode:

```powershell
$browser = Chrome-Start -Hidden $true
Chrome-Navigate -Browser $browser -Url "https://example.com"
# ... automation tasks ...
Chrome-Stop -Browser $browser
```

## Updating Components

```powershell
# Update Chrome and ChromeDriver to latest stable
.\Update-Browser.ps1

# Update everything including Selenium
.\Update-Browser.ps1 -UpdateSelenium

# Preview changes without applying
.\Update-Browser.ps1 -UpdateSelenium -WhatIf
```

## Related: CWeb

This module is the core of **CWeb** (the folder above this one), the shared browser server Claude agents use while
you handle logins and sensitive input. Scripts that use this module directly keep their profiles in
`<CWeb data folder>\scripts` (default `%LOCALAPPDATA%\CWeb\scripts`). On a new machine, run CWeb's `Setup-CWeb.cmd`
first: it downloads the pinned Chrome, ChromeDriver and Selenium this module needs.
