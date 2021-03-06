﻿# telnet options
$SE   = 0xF0
$NOP  = 0xF1
$DM   = 0xF2
$BRK  = 0xF3
$IP   = 0xF4
$AO   = 0xF5
$AYT  = 0xF6
$EC   = 0xF7
$EL   = 0xF8
$GA   = 0xF9
$SB   = 0xFA

$WILL = 0xFB
$WONT = 0xFC
$DO   = 0xFD
$DONT = 0xFE
$IAC  = 0xFF

$suppress_go_ahead      = 0x03
$status                 = 0x05
$echo                   = 0x01
$timing_mark            = 0x06
$terminal_type          = 0x18
$window_size            = 0x1F
$terminal_speed         = 0x20
$remote_flow_control    = 0x21
$linemode               = 0x22
$environment_variables  = 0x24

# escape sequence
$ESC = 0x1B

# global variables
$ENC = $null # function
$Q = new-object System.Collections.Queue
$stream = $null 
$byte = $null
$Ch = ""
$buf = New-Object System.Text.StringBuilder

$UTF8 = [System.Text.Encoding]::UTF8
$SJIS = [System.Text.Encoding]::Default
$EUCJP = [System.Text.Encoding]::GetEncoding("EUC-JP")

# font style
$fgcolor_default = $host.UI.RawUI.ForegroundColor
$bgcolor_default = $host.UI.RawUI.BackgroundColor
$fgcolor = $fgcolor_default
$bgcolor = $bgcolor_default

# screen
$cursor = New-Object System.Collections.Stack
$screen = New-Object System.Collections.Stack

###############################################################################
# Common
###############################################################################
function next {
    try {
        $script:byte = $stream.ReadByte()
        Write-Debug ("< " + $byte )
        $byte
    } catch {
        throw $_
    }
}
filter WriteByte {
    $stream.WriteByte($_)
    Write-Debug ("> " + $_)
}
filter output {
    Write-Host -NoNewline $_ -ForegroundColor $script:fgcolor -BackgroundColor $script:bgcolor
}

###############################################################################
#  Encoding
###############################################################################
function ENC_EUCJP {
}
function ENC_SJIS {
}
function ENC_UTF8 {
    switch ($byte) {
        { ($byte -band 0x80) -eq 0x00} {
            if ($byte -eq 0x0D) {
                $pos = Get-Cursor
                Move-Cursor 0 $pos.Y
                return
            }
            if ($byte -eq 0x0A) {
                $pos = Get-Cursor
                Move-Cursor $pos.X ($pos.Y + 1)
                return
            }
            if ($byte -eq 0x20 -and $Host.UI.RawUI.CursorPosition.X -eq $Host.UI.RawUI.BufferSize.Width - 1) {
                $pos = Get-Cursor
                Move-Cursor 0 ($pos.Y + 1)
                return
            }
            if ($byte -eq 0x00) { return }
            $Q.Enqueue($byte)
        }
        { ($byte -band 0xE0) -eq 0xC0} {
            $Q.Enqueue($byte)
            next | % { $Q.Enqueue($_) }
        }
        { ($byte -band 0xF0) -eq 0xE0} {
            $Q.Enqueue($byte)
            next | % { $Q.Enqueue($_) }
            next | % { $Q.Enqueue($_) }
        }
        { ($byte -band 0xF8) -eq 0xF0} {
            $Q.Enqueue($byte)
            next | % { $Q.Enqueue($_) }
            next | % { $Q.Enqueue($_) }
            next | % { $Q.Enqueue($_) }
        }
        default { throw "invalid UTF8." }
    }
    $script:Ch = $UTF8.GetString($Q.ToArray())
    $script:Ch | output
    $Q.Clear()
}

###############################################################################
# IAC
###############################################################################
function IAC_SB {
    switch (next) {
        $terminal_type {
            next > $null # 0x01
            next > $null # IAC
            next > $null # SE
            $IAC, $SB, $terminal_type, 0x00, 
            0x78, 0x74, 0x65, 0x72, 0x6d, # xterm
            $IAC, $SE | WriteByte
        }
        default {
            throw "invalid SB sequence."
        }
    }
    $stream.flush()
}
function IAC_WILL {
    switch (next) {
        $suppress_go_ahead { <# through #> }
        $terminal_type { <# through #> }
        $echo { <# through #> }
        default {
            $IAC, $DONT, $byte | WriteByte
        }
    }
    $stream.flush()
}
function IAC_DO {
    switch (next) {
        $suppress_go_ahead { <# through #> }
        $terminal_type { <# through #> }
        $window_size {
            $w = $host.UI.RawUI.WindowSize.Width
            $h = $host.UI.RawUI.WindowSize.Height
            if (! $w) { $w = 0x50}
            if (! $h) { $h = 0x18}
            if ($w -gt 0xFF) { $w = 0xFF }
            if ($h -gt 0xFF) { $h = 0xFF }
            $IAC, $SB, $byte, 0x00, $w, 0x00, $h, $IAC, $SE | WriteByte
        }
        default {
            $IAC, $WONT, $byte | WriteByte
        }
    }
    $stream.flush()
}
function IAC {
    switch (next) {
        $NOP {}
        $SB { IAC_SB }
        $DO { IAC_DO }
        $WILL { IAC_WILL }
        $DONT {
            next > $null
            $IAC, $WONT, $byte | WriteByte
        }
        $WONT {
            next > $null
            $IAC, $WONT, $byte | WriteByte
        }
        default {
            throw "unknown IAC sequence."
        }
    }
}
function negotiation {
    $IAC, $WILL, $terminal_type | WriteByte
    $IAC, $DO, $suppress_go_ahead | WriteByte
    $IAC, $WILL, $suppress_go_ahead | WriteByte
    $IAC, $DO, $echo  | WriteByte
    $IAC, $WILL, $window_size  | WriteByte
    $stream.Flush()
}

###############################################################################
# CSI Screen
###############################################################################
function Get-Cursor {
    # バッファ全体ではなく、ウィンドウ中でのポジションを返す。
    $X = $Host.UI.RawUI.CursorPosition.X
    $Y = $Host.UI.RawUI.CursorPosition.Y - $Host.UI.RawUI.WindowPosition.Y
    return New-Object System.Management.Automation.Host.Coordinates($X, $Y)
}
function Set-Cursor {
    param($pos)
    # バッファ全体ではなく、ウィンドウ中でのポジションを設定する。
    if ($pos.X -ge $Host.UI.RawUI.WindowSize.Width) {
        $pos.X = $Host.UI.RawUI.WindowSize.Width - 1
    }
    $pos.Y = $pos.Y + $Host.UI.RawUI.WindowPosition.Y
    $Host.UI.RawUI.CursorPosition = $pos
}
function Move-Cursor {
    param($column, $line)
    # Set-Cursor を (X, Y) 形式で指定するためのオーバーロード
    $pos = New-Object System.Management.Automation.Host.Coordinates $column, $line
    Set-Cursor $pos
}
function Save-Cursor {
    param($pos)
    if ($pos -eq $null) { $pos = Get-Cursor }
    $script:cursor.push($pos) > $null
    return $pos
}
function Restore-Cursor {
    $pos = $script:cursor.Pop()
    $pos.Y += $Host.UI.RawUI.WindowPosition.Y
    $Host.UI.RawUI.CursorPosition = $pos
}
function Save-Screen()
{
    $rect = New-Object System.Management.Automation.Host.Rectangle
    $rect.Left   = 0
    $rect.Top    = $Host.UI.RawUI.CursorPosition.Y - $Host.UI.RawUI.WindowSize.Height
    $rect.Right  = $Host.UI.RawUI.WindowSize.Width
    $rect.Bottom = $Host.UI.RawUI.CursorPosition.Y
    if ($rect.Top -lt 0) { $rect.Top = 0 }
    $script:screen.push($Host.UI.RawUI.GetBufferContents($rect)) > $null
}
function Restore-Screen()
{
    $origin = New-Object System.Management.Automation.Host.Coordinates(0, 0)
    $scrn = $script:screen.Pop()
    $Host.UI.RawUI.SetBufferContents($origin, $scrn)
}

###############################################################################
# CSI
###############################################################################
function CSI_ICH {
    param($arguments)

}
function CSI_CUU {
    param($arguments)
    if ($arguments -eq $null) {
        $count = 1
    } else {
        $count = $arguments[0]
    }
    $pos = Get-Cursor
    $pos.Y -= $count
    Set-Cursor $pos
}
function CSI_CUD {
    param($arguments)
    if ($arguments -eq $null) {
        $count = 1
    } else {
        $count = $arguments[0]
    }
    $pos = Get-Cursor
    $pos.Y += $count
    Set-Cursor $pos
}
function CSI_CUR {
    param($arguments)
    if ($arguments -eq $null) {
        $count = 1
    } else {
        $count = $arguments[0]
    }
    $pos = Get-Cursor
    $pos.X += $count
    Set-Cursor $pos
}
function CSI_CUL {
    param($arguments)
    if ($arguments -eq $null) {
        $count = 1
    } else {
        $count = $arguments[0]
    }
    $pos = Get-Cursor
    $pos.X -= $count
    Set-Cursor $pos
}
function CSI_CUP {
    # CSI $l, $c H
    param($arguments)
    Save-Screen
    $pos = New-Object System.Management.Automation.Host.Coordinates(
        0,
        ($Host.UI.RawUI.WindowPosition.Y + $Host.UI.RawUI.WindowSize.Height)
        )
    $Host.UI.RawUI.WindowPosition = $pos
    if ($arguments -eq $null) {
        $l = 0
        $c = 0
    } else {
        $l = $arguments[0] - 1
        $c = $arguments[1] - 1
    }
    Move-Cursor $c $l

    Restore-Screen
}
function CSI_ED {
    # CSI J
    param($arguments)
    $mode = if ($arguments -eq $null) { 0 } else { $arguments[0] }
    switch ($mode) {
        0 {
            $pos = Save-Cursor
            " " * ($Host.UI.RawUI.CursorPosition.X - $pos.X) | output
            $lines = $Host.UI.RawUI.WindowPosition.Y + $Host.UI.RawUI.WindowSize.Height
            for ($i = $Host.UI.RawUI.CursorPosition.Y; $i -lt $lines; $i++) {
                "`r" | output
                " " * $Host.UI.RawUI.WindowSize.X | output
            }
            Restore-Cursor
        }
        1 {  }
        2 {
            $pos = Save-Cursor
            0..($Host.UI.RawUI.WindowSize.Height) | % {
                " " * $Host.UI.RawUI.WindowSize.Width | output
                #"_" * $Host.UI.RawUI.WindowSize.Width | write-host -ForegroundColor Yellow
            }
            Restore-Cursor
        }
        default { <# ignore #> }
    }
}
function CSI_EL {
    param($arguments)
    if ($arguments -eq $null) {
        $mode = 0
    } else {
        $mode = $arguments[0]
    }
    switch ($mode) {
        0 {
            $pos = Save-Cursor
            " " * ($Host.UI.RawUI.BufferSize.Width - $pos.X) | output
            Restore-Cursor
        }
        1 {  }
        2 {  }
        Default { <# ignore #> }
    }
}
function CSI_SGR {
    param($arguments)
    if ($arguments -eq $null) {
        $script:fgcolor = $script:fgcolor_default
        $script:bgcolor = $script:bgcolor_default
        return
    }
    for ($i = 0; $i -lt $arguments.Length; $i++) {
        switch ($arguments[$i]) {
            0 {
                $script:fgcolor = $script:fgcolor_default
                $script:bgcolor = $script:bgcolor_default
            }
            1 { } # bold
            2 { } # thin color
            3 { } # italic
            4 { } # underline
            5 { } # blink
            6 { } # speed blink
            7 {
                # color reverse
                $temp = $script:fgcolor
                $script:fgcolor = $script:bgcolor
                $script:bgcolor = $temp
            }
            8 { $script:fgcolor = $script:bgcolor } # display none
            9 { } # strike
            30 { $script:fgcolor = [ConsoleColor]::Black }
            31 { $script:fgcolor = [ConsoleColor]::Red }
            32 { $script:fgcolor = [ConsoleColor]::Green }
            33 { $script:fgcolor = [ConsoleColor]::Yellow }
            34 { $script:fgcolor = [ConsoleColor]::Blue }
            35 { $script:fgcolor = [ConsoleColor]::Magenta }
            36 { $script:fgcolor = [ConsoleColor]::Cyan }
            37 { $script:fgcolor = [ConsoleColor]::White }
            38 { }
            39 { $script:fgcolor = $fgcolor_default }

            40 { $script:bgcolor = [ConsoleColor]::Black }
            41 { $script:bgcolor = [ConsoleColor]::Red }
            42 { $script:bgcolor = [ConsoleColor]::Green }
            43 { $script:bgcolor = [ConsoleColor]::Yellow }
            44 { $script:bgcolor = [ConsoleColor]::Blue }
            45 { $script:bgcolor = [ConsoleColor]::Magenta }
            46 { $script:bgcolor = [ConsoleColor]::Cyan }
            47 { $script:bgcolor = [ConsoleColor]::White }
            48 { }
            49 { $script:bgcolor = $bgcolor_default }
            default { Write-Debug "SGR: $arg" }
        }
    }
}
function DEC {
    param($arguments)
}
function PARSE_NUMBER {
    if (-not (0x30 -le $byte -and $byte -le 0x39)) { return }
    $buf = ""
    while (0x30 -le $byte -and $byte -le 0x39) {
        $buf += [char]$byte
        next > $null
    }
    return +$buf
}
function PARSE_ARGUMENTS {
    PARSE_NUMBER
    while ([char]$byte -eq ";") {
        next > $null
        PARSE_NUMBER
    }
}
function CSI {
    next > $null
    $arguments = PARSE_ARGUMENTS
    switch ([char]$byte) {
        "@" { CSI_ICH $arguments }
        "A" { CSI_CUU $arguments }
        "B" { CSI_CUD $arguments }
        "C" { CSI_CUR $arguments }
        "D" { CSI_CUL $arguments }
        "K" { CSI_EL $arguments }
        "H" { CSI_CUP $arguments }
        "J" { CSI_ED $arguments }
        "m" { CSI_SGR $arguments }
        "?" {
            next > $null
            $arguments = PARSE_ARGUMENTS
            switch ([char]$byte) {
                "h" { DEC $arguments }
                default { <# ignore #> }
            }
        }
        "=" {
            next > $null
            $arguments = PARSE_ARGUMENTS
            switch ([char]$byte) {
                default { <# ignore #> }
            }
        }
        ">" {
            next > $null
            $arguments = PARSE_ARGUMENTS
            switch ([char]$byte) {
                default { <# ignore #> }
            }
        }
        "'" {
            next > $null
            $arguments = PARSE_ARGUMENTS
            switch ([char]$byte) {
                default { <# ignore #> }
            }
        }
        "!" {
            next > $null
            $arguments = PARSE_ARGUMENTS
            switch ([char]$byte) {
                default { <# ignore #> }
            }
        }
        " " {
            next > $null
            $arguments = PARSE_ARGUMENTS
            switch ([char]$byte) {
                default { <# ignore #> }
            }
        }
        default { <# ignore #> }
    }
}
function ESCAPE {
    $ch = [char](next)
    switch ($ch) {
        "[" { CSI }
        "]" {
            next > $null
            while ($byte -ne 0x07) { next > $null }
        }
        "=" { next > $null }
        default { <# ignore #> }
    }
}

###############################################################################
# Parse
###############################################################################
function Parse {
    next > $null
    switch ($byte) {
        $IAC { IAC }
        $ESC { ESCAPE }
        default { ENC_UTF8 }
    }
}
function interaction {
    $console = [System.Console]
    $console::TreatControlCAsInput = $true # trap Ctrl+C
    $Ctrl = [ConsoleModifiers]::Control
    while ($true) {
        while ($console::KeyAvailable) {
            $key = $console::ReadKey($true)
            switch ($key) {
                { $_.key -eq [ConsoleKey]::A -and $_.modifiers -band $Ctrl } { 0x01 | WriteByte }
                { $_.key -eq [ConsoleKey]::B -and $_.modifiers -band $Ctrl } { 0x02 | WriteByte }
                { $_.key -eq [ConsoleKey]::C -and $_.modifiers -band $Ctrl } { 0x03 | WriteByte }
                { $_.key -eq [ConsoleKey]::D -and $_.modifiers -band $Ctrl } { 0x04 | WriteByte }
                { $_.key -eq [ConsoleKey]::E -and $_.modifiers -band $Ctrl } { 0x05 | WriteByte }
                { $_.key -eq [ConsoleKey]::F -and $_.modifiers -band $Ctrl } { 0x06 | WriteByte }
                { $_.key -eq [ConsoleKey]::G -and $_.modifiers -band $Ctrl } { 0x07 | WriteByte }
                { $_.key -eq [ConsoleKey]::H -and $_.modifiers -band $Ctrl } { 0x08 | WriteByte }
                { $_.key -eq [ConsoleKey]::K -and $_.modifiers -band $Ctrl } { 0x0B | WriteByte }
                { $_.key -eq [ConsoleKey]::L -and $_.modifiers -band $Ctrl } { 0x0C | WriteByte }
                { $_.key -eq [ConsoleKey]::Q -and $_.modifiers -band $Ctrl } { 0x11 | WriteByte }
                { $_.key -eq [ConsoleKey]::U -and $_.modifiers -band $Ctrl } { 0x15 | WriteByte }
                { $_.key -eq [ConsoleKey]::W -and $_.modifiers -band $Ctrl } { 0x17 | WriteByte }
                { $_.key -eq [ConsoleKey]::Y -and $_.modifiers -band $Ctrl } { 0x19 | WriteByte }
                { $_.key -eq [ConsoleKey]::Z -and $_.modifiers -band $Ctrl } { 0x1A | WriteByte }
                { $_.key -eq [ConsoleKey]::Escape }     { 0x1B | WriteByte }
                { $_.key -eq [ConsoleKey]::Backspace }  { 0x08 | WriteByte }
                { $_.key -eq [ConsoleKey]::Delete }     { 0x7F | WriteByte }
                { $_.key -eq [ConsoleKey]::Home }       { 0x1B, 0x5B, 0x31, 0x7E | WriteByte }
                { $_.key -eq [ConsoleKey]::Insert }     { 0x1B, 0x5B, 0x32, 0x7E | WriteByte }
                { $_.key -eq [ConsoleKey]::End }        { 0x1B, 0x5B, 0x34, 0x7E | WriteByte }
                { $_.key -eq [ConsoleKey]::PageUp }     { 0x1B, 0x5B, 0x35, 0x7E | WriteByte }
                { $_.key -eq [ConsoleKey]::PageDown }   { 0x1B, 0x5B, 0x36, 0x7E | WriteByte }
                { $_.key -eq [ConsoleKey]::UpArrow }    { 0x1B, 0x5B, 0x41 | WriteByte }
                { $_.key -eq [ConsoleKey]::DownArrow }  { 0x1B, 0x5B, 0x42 | WriteByte }
                { $_.key -eq [ConsoleKey]::RightArrow } { 0x1B, 0x5B, 0x43 | WriteByte }
                { $_.key -eq [ConsoleKey]::LeftArrow }  { 0x1B, 0x5B, 0x44 | WriteByte }
                default { $UTF8.GetBytes($key.keyChar) | WriteByte }
            }
        }
        while ($stream.DataAvailable) {
            Parse
        }
        sleep -milliseconds 10
    }
}
function New-TelnetSession {
    param(
        [parameter(Mandatory=$true, Position=0)]
        [string]$IP,
        [parameter(Mandatory=$false, Position=1)]
        [int]$Port = 23,
        [parameter(Mandatory=$false, Position=2)]
        $Encoding = $UTF8,
        [parameter(Mandatory=$false, Position=3)]
        [int]$Timeout = 5000
    )
    try {
        $socket = new-object system.net.sockets.tcpclient($IP, $Port)
        $stream = $socket.GetStream()
        $stream.Readtimeout = $Timeout
        $stream.WriteTimeout = $Timeout

        switch ($encoding) {
            $UTF8 { $EUC = { ENC_UTF8 } }
            $SJIS { $ENC = { ENC_SJIS } }
            $EUCJP { $ENC = { ENC_EUCJP } }
            default { $EUC = { EUC_UTF8 } }
        }
        negotiation
        interaction
    } catch {
        $_ | format-list
    } finally {
        $socket.Close()
    }
}
Export-ModuleMember -Function New-TelnetSession
