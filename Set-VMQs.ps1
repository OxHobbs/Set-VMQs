function Set-VMQs
{
    [CmdletBinding()]
    param
    (
        [String]$VMHost="localhost",

	    [System.Boolean]
	    $Hyperthreaded = $true
    )

    foreach ($vmh in $VMHost)
    {
        write-host "Executing on $vmh"

        Invoke-Command -ComputerName $VMHost -ScriptBlock {

        Function Test-IsHyperThreaded {
            param(
                $PhysicalCPU
            )
            if (($PhysicalCPU.NumberOfCores | Measure-Object -Sum).sum -ge ($PhysicalCPU.NumberOfLogicalProcessors | Measure-Object -Sum).sum) {
                return $false
            }
            return $true
        }

        Function Enable-VMQAdvanced {
            param(
                [string[]]$NICs
            )
            Get-NetAdapter $NICs | ? {$_.LinkSpeed -match "10 gbps"} | Get-NetAdapterAdvancedProperty -RegistryKeyword *vmq | `
                ? {$_.displayvalue -ne "Enabled"} | Set-NetAdapterAdvancedProperty -RegistryKeyword *vmq -RegistryValue 1
        }

        Function Set-VMQConfiguration {
            param(
                $NetAdapters,
                $CoreCountFactor,
                $MaxCores
            )
            $BaseProcessorNumber = 0
            foreach ($NetAdapter in $NetAdapters) {
                
                if ($BaseProcessorNumber -ge ($TotalCores * $CoreCountFactor)) {
                    $BaseProcessorNumber = 0
                }
                #$MaxProcessorNumber = Get-MaxProcessorNumber -BaseProcessorNumber $BaseProcessorNumber -MaxProcessorCores $MaxCores
                if ($BaseProcessorNumber -eq 0) {
                    $MaxProcessorNumber = Get-MaxProcessorNumber -BaseProcessorNumber $BaseProcessorNumber -MaxProcessorCores ($MaxCores - 1)
                    $NetAdapter | Set-NetAdapterVmq -BaseProcessorNumber ($BaseProcessorNumber + $CoreCountFactor) -MaxProcessors ($MaxCores - 1) -MaxProcessorNumber $MaxProcessorNumber
                    write-host "Setting VMQ net adapter $($NetAdapter.Name) to baseprocessornumber $($BaseProcessorNumber + $CoreCountFactor) and MaxProcessors to $($MaxCores - 1) with a MaxProcessorNumber of $MaxProcessorNumber"
                }
                else {
                    $MaxProcessorNumber = Get-MaxProcessorNumber -BaseProcessorNumber $BaseProcessorNumber -MaxProcessorCores $MaxCores
                    Write-Host "Setting VMQ net adapter $($NetAdapter.Name) to baseprocessornumber $BaseProcessorNumber and MaxProcessors to $MaxCores with a MaxProcessorNumber of $MaxProcessorNumber"
                    $NetAdapter | Set-NetAdapterVmq -BaseProcessorNumber $BaseProcessorNumber -MaxProcessors $MaxCores -MaxProcessorNumber $MaxProcessorNumber
                }
                $BaseProcessorNumber += $MaxCores * $CoreCountFactor
            }
        }

        Function Get-MaxProcessorNumber
        {
            param
            (
                $BaseProcessorNumber,
                $MaxProcessorCores,
                [bool]$IsHyperthreaded = $true
            )

            $multiplier = 0
            switch ($IsHyperthreaded)
            {
                $true {$multiplier = 2; break}
                $false {$multiplier = 1; break}
            }

            
            if ($BaseProcessorNumber -eq 0)
            {
                
                $adder = $multiplier * $MaxProcessorCores
                $top = $adder
                $MaxProcessorNumber =  (2..$top | ? {$_ % 2 -eq 0})[($MaxProcessorCores - 1)]
            }
            else
            {
                $adder = $multiplier * $MaxProcessorCores
                $top = $BaseProcessorNumber + $adder
                $MaxProcessorNumber =  ($BaseProcessorNumber..$top | ? {$_ % 2 -eq 0})[($MaxProcessorCores - 1)]
            }
            return $MaxProcessorNumber
        }

        Function Order-Adapters {
            param(
                $Teams
            )
            $Ordered = New-Object System.Collections.ArrayList
            $Teams | ? {($_.members).count -gt 1} | % {
                $_.members | % {
                    [void]($Ordered.Add($_))
                }
            }
            $Teams | ? {($_.members).count -le 1} | % {
                [void]($Ordered.Add($_.members))
            }
            return $Ordered
        }

        [array]$pCores = Get-CimInstance win32_processor
        $HyperThreaded = Test-IsHyperThreaded $pCores
        $TotalCores = ($pCores.NumberOfCores | Measure-Object -Sum).sum
        $CoresPerVMQ = $TotalCores / $pCores.Count
        $IncreaseFactor = 1

        if ($HyperThreaded) {
            $IncreaseFactor = 2
        }
        $MemberTeams = Get-NetLbfoTeam
        [string[]]$MemberNames = $MemberTeams | % {$_.Members}
        $10Gbs = Get-NetAdapter $MemberNames | ? {$_.LinkSpeed -match "10 gbps"} | % {$_.Name}
        0..$10Gbs.count | % {$regex += "$($10Gbs[$_])|"}
        $regex = $regex.Trim("|")
        $FilteredTeams = $MemberTeams | ? {$_.Members -match $regex}
        $OrderedNICNamess = Order-Adapters $FilteredTeams
    
        if (($OrderedNICNamess -eq $null) -or ([string]::IsNullOrEmpty($OrderedNICNamess))) {
            Write-Warning "No NetLbfoTeams detected."
            exit
        }

        Enable-VMQAdvanced -NICs $OrderedNICNamess

        $VMQAdapters = New-Object System.Collections.ArrayList
        foreach ($Nic in $OrderedNICNamess) {
            [void]($VMQAdapters.Add((Get-NetAdapter $Nic |  Get-NetAdapterVmq | ? {$_.Enabled -eq $true})))
        }
        if (($VMQAdapters -eq $null) -or ([string]::IsNullOrEmpty($VMQAdapters))) {
            Write-Warning "No NetAdapterVmq NICs found."
            Exit
        }
        #"Server: $VMHost"
        Set-VMQConfiguration -NetAdapters $VMQAdapters -CoreCountFactor $IncreaseFactor -MaxCores $CoresPerVMQ

        write-host "`n"}
    }
}