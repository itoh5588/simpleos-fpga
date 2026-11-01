param(
    [Parameter(Mandatory=$true)][string]$Image,
    [string]$Port = 'COM5',
    [switch]$StartOnly,
    [string]$ReceiveText = '',
    [int]$TimeoutMs = 10000
)
$ErrorActionPreference = 'Stop'
$bytes = [System.IO.File]::ReadAllBytes($Image)
if ($bytes.Length -lt 1 -or $bytes.Length -gt 8192) {
    throw 'RAM image must be 1..8192 bytes at origin 0x80000'
}
$packet = New-Object byte[] ($bytes.Length + 4)
$packet[0] = 87
$packet[1] = [byte]($bytes.Length -shr 8)
$packet[2] = [byte]($bytes.Length -band 255)
[Array]::Copy($bytes, 0, $packet, 3, $bytes.Length)
$checksum = 0
foreach ($value in $bytes) { $checksum = ($checksum + $value) -band 255 }
$packet[$packet.Length - 1] = [byte]$checksum
$serial = New-Object System.IO.Ports.SerialPort $Port,115200,None,8,One
$serial.Handshake = [System.IO.Ports.Handshake]::None
$serial.DtrEnable = $false
$serial.RtsEnable = $false
$serial.ReadTimeout = $TimeoutMs
$serial.WriteTimeout = $TimeoutMs
try {
    $serial.Open()
    $serial.DiscardInBuffer()
    $serial.Write($packet, 0, $packet.Length)
    $ack = $serial.ReadByte()
    if ($ack -eq 69) { throw "Loader rejected image" }
    if ($ack -ne 75) { throw "Unexpected response $ack; stop the running sample with BTN0 or JTAG reconfiguration before loading" }
    Write-Output ('LOADED {0} bytes, checksum {1:X2}' -f $bytes.Length,$checksum)
    $serial.Write([byte[]]@(82), 0, 1)
    foreach ($value in [System.Text.Encoding]::ASCII.GetBytes($ReceiveText)) {
        $serial.Write([byte[]]@($value), 0, 1)
        Start-Sleep -Milliseconds 10
    }
    if ($StartOnly) {
        Write-Output 'RUNNING; UART released on exit'
    } else {
        while ($true) {
            $value = $serial.ReadByte()
            if ($value -eq 4) { Write-Output 'HALT_OK'; break }
            if ($value -eq 21) { throw 'CPU fault, unmapped address or unsupported SYSCALL' }
            [Console]::Write([char]$value)
        }
    }
} finally {
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
