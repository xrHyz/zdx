# Deploy_FortiClient.ps1
# Se ejecuta post-reinicio via RunOnce
# Instala FortiClient 7.2.14.1296 y configura perfiles IPSec

$MsiUrl  = "https://www.dropbox.com/scl/fi/nxt2u8ptut9e2hpq3cyww/FortiClient.msi?rlkey=8izmhwn9ug9x8o5x5dj1i4q61&st=zzrpkqjf&dl=1"
$RegUrl  = "https://www.dropbox.com/scl/fi/hl5btczdbb426ltcsxb93/FortiClient_VPN.reg?rlkey=kek6vgky21vmgq3zx74q7x9gy&st=s1wflfml&dl=1"
$MsiFile = "C:\ProgramData\Fortinet\FortiClient.msi"
$RegFile = "C:\ProgramData\Fortinet\FortiClient_VPN.reg"
$LogFile = "C:\ProgramData\Fortinet\deploy_forticlient.log"

# Forzar TLS 1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Write-Log {
    param([string]$msg)
    $dir = Split-Path $LogFile
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    "$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) - $env:COMPUTERNAME - $msg" |
        Out-File -Append -FilePath $LogFile
}

function Show-Notification {
    param([string]$titulo, [string]$mensaje)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $notify.BalloonTipTitle = $titulo
        $notify.BalloonTipText = $mensaje
        $notify.Visible = $true
        $notify.ShowBalloonTip(15000)
        Start-Sleep -Seconds 15
        $notify.Dispose()
    } catch {
        Write-Log "ADVERTENCIA: No se pudo mostrar notificacion: $_"
    }
}

function Register-RunOnceRetry {
    $comando = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"C:\ProgramData\Fortinet\Deploy_FortiClient.ps1`""
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "FortiClientDeploy" -Value $comando -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "FortiClientDeploy" -Value $comando -Force -ErrorAction SilentlyContinue
    Write-Log "RunOnce re-registrado para proximo inicio de sesion"
}

function Clear-RunOnce {
    Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "FortiClientDeploy" -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "FortiClientDeploy" -Force -ErrorAction SilentlyContinue
    Write-Log "RunOnce eliminado correctamente"
}

function Clear-PendingReboot {
    reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" /v "PendingFileRenameOperations" /f 2>$null
    reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" /f 2>$null
    reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" /f 2>$null
    reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending" /f 2>$null
    Write-Log "Flags de reinicio pendiente limpiados"
}

Write-Log "========== INICIO INSTALACION POST-REINICIO =========="

Start-Sleep -Seconds 30

$esperaAleatoria = Get-Random -Minimum 5 -Maximum 60
Write-Log "Espera aleatoria de $esperaAleatoria segundos..."
Start-Sleep -Seconds $esperaAleatoria

# ============================================================
# PASO 0 — Limpiar flags de reinicio pendiente
# ============================================================
Write-Log "Limpiando flags de reinicio pendiente..."
Clear-PendingReboot

# ============================================================
# PASO 1 — Descargar MSI con reintentos
# ============================================================
Write-Log "Descargando MSI..."
$descargaExitosa = $false
$maxIntentos = 10

Register-RunOnceRetry

for ($i = 1; $i -le $maxIntentos; $i++) {
    try {
        $ping = Test-Connection "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $ping) {
            Write-Log "Intento $i - Sin conectividad, esperando 60 segundos..."
            Start-Sleep -Seconds 60
            continue
        }
        (New-Object System.Net.WebClient).DownloadFile($MsiUrl, $MsiFile)
        Write-Log "MSI descargado correctamente en intento $i"
        $descargaExitosa = $true
        break
    } catch {
        Write-Log "Intento $i fallido: $_"
        if ($i -lt $maxIntentos) {
            $espera = Get-Random -Minimum 30 -Maximum 120
            Write-Log "Esperando $espera segundos antes de reintentar..."
            Start-Sleep -Seconds $espera
        }
    }
}

if (-not $descargaExitosa) {
    Write-Log "ERROR: No se pudo descargar el MSI tras $maxIntentos intentos - reintentara en proximo inicio de sesion"
    Exit 1
}

# ============================================================
# PASO 2 — Instalar FortiClient
# ============================================================
Write-Log "Instalando FortiClient 7.2.14.1296..."
$install = Start-Process "msiexec.exe" `
    -ArgumentList "/i `"$MsiFile`" /quiet /norestart REBOOT=ReallySuppress" `
    -Wait -PassThru

if ($install.ExitCode -eq 0 -or $install.ExitCode -eq 3010) {
    Write-Log "Instalacion completada. ExitCode: $($install.ExitCode)"
} else {
    Write-Log "ERROR instalacion. ExitCode: $($install.ExitCode)"
    Remove-Item $MsiFile -Force -ErrorAction SilentlyContinue
    Exit 1
}

Remove-Item $MsiFile -Force -ErrorAction SilentlyContinue

# ============================================================
# PASO 3 — Esperar servicios
# ============================================================
Write-Log "Esperando servicios FortiClient..."
$intentos = 0
do {
    Start-Sleep -Seconds 5
    $intentos++
    $servicio = Get-Service "FA_Scheduler" -ErrorAction SilentlyContinue
} while ($servicio.Status -ne "Running" -and $intentos -lt 12)
Write-Log "Servicios activos tras $($intentos * 5) segundos"

# ============================================================
# PASO 4 — Descargar .reg con reintentos
# ============================================================
Write-Log "Descargando perfiles VPN..."
$descargaRegExitosa = $false

for ($i = 1; $i -le $maxIntentos; $i++) {
    try {
        $ping = Test-Connection "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $ping) {
            Write-Log "Intento $i - Sin conectividad, esperando 60 segundos..."
            Start-Sleep -Seconds 60
            continue
        }
        (New-Object System.Net.WebClient).DownloadFile($RegUrl, $RegFile)
        Write-Log "Archivo .reg descargado en intento $i"
        $descargaRegExitosa = $true
        break
    } catch {
        Write-Log "Intento $i fallido descarga .reg: $_"
        if ($i -lt $maxIntentos) {
            $espera = Get-Random -Minimum 30 -Maximum 120
            Write-Log "Esperando $espera segundos antes de reintentar..."
            Start-Sleep -Seconds $espera
        }
    }
}

if (-not $descargaRegExitosa) {
    Write-Log "ERROR: No se pudo descargar el .reg tras $maxIntentos intentos - reintentara en proximo inicio de sesion"
    Exit 1
}

# ============================================================
# PASO 5 — Importar perfiles VPN
# ============================================================
Stop-Process -Name "FortiClient","FortiSettings","FortiTray" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

reg add "HKLM\SOFTWARE\Fortinet\FortiClient\FA_UI" /v "password_enabled" /t REG_DWORD /d 0 /f 2>$null
reg add "HKLM\SOFTWARE\Fortinet\FortiClient\FA_UI" /v "password" /t REG_SZ /d "" /f 2>$null
Write-Log "Password protection deshabilitado"

$reg = Start-Process "regedit.exe" -ArgumentList "/s `"$RegFile`"" -Wait -PassThru
if ($reg.ExitCode -eq 0) {
    Write-Log "Perfiles importados correctamente"
} else {
    Write-Log "ERROR importando perfiles. ExitCode: $($reg.ExitCode)"
    Exit 1
}

Remove-Item $RegFile -Force -ErrorAction SilentlyContinue

# ============================================================
# PASO 6 — Reiniciar servicios
# ============================================================
Stop-Service "FA_Scheduler" -Force -ErrorAction SilentlyContinue
Stop-Service "FortiClient"  -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Start-Service "FA_Scheduler" -ErrorAction SilentlyContinue
Start-Service "FortiClient"  -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Write-Log "Servicios reiniciados"

# ============================================================
# PASO 7 — Lanzar FortiTray
# ============================================================
$fortitray = "C:\Program Files\Fortinet\FortiClient\FortiTray.exe"
if (Test-Path $fortitray) {
    Start-Process $fortitray
    Write-Log "FortiTray lanzado"
}

# ============================================================
# PASO 8 — Detectar reinicio requerido y notificar
# ============================================================
$reinicioNecesario = ($install.ExitCode -eq 3010)
$adaptador = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object {
        $_.InterfaceDescription -like "*Fortinet*" -or
        $_.InterfaceDescription -like "*FortiClient*"
    }

if (-not $adaptador) {
    $reinicioNecesario = $true
    Write-Log "Adaptador de red virtual no detectado - reinicio requerido"
}

if ($reinicioNecesario) {
    Write-Log "REINICIO REQUERIDO en $env:COMPUTERNAME"
    Show-Notification `
        -titulo "Corporación VNET  -  Soporte IT" `
        -mensaje "La actualización se ha completado en su equipo. Para finalizar el proceso es necesario reiniciar. Por favor guarde su trabajo y reinicie cuando pueda. Ante cualquier inconveniente, comuniquese con Soporte IT."
} else {
    Write-Log "Despliegue completado sin reinicio adicional"
    Show-Notification `
        -titulo "Corporación VNET  -  Soporte IT" `
        -mensaje "La actualización se ha completado exitosamente en su equipo. Ante cualquier inconveniente, comuniquese con Soporte IT. Feliz dia!"
}

# ============================================================
# PASO 9 — Limpieza final
# ============================================================
Clear-RunOnce
Remove-Item "C:\ProgramData\Fortinet\Deploy_FortiClient.ps1" -Force -ErrorAction SilentlyContinue

Write-Log "========== DESPLIEGUE COMPLETADO EN $env:COMPUTERNAME =========="
Exit 0
