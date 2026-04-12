$script:HVPreferredCommands = @(
    @{ Name = 'Add-ClusterDisk';                Module = 'FailoverClusters' }
    @{ Name = 'Add-ClusterNode';                Module = 'FailoverClusters' }
    @{ Name = 'Add-ClusterSharedVolume';        Module = 'FailoverClusters' }
    @{ Name = 'Get-Cluster';                    Module = 'FailoverClusters' }
    @{ Name = 'Get-ClusterAvailableDisk';       Module = 'FailoverClusters' }
    @{ Name = 'Get-ClusterGroup';               Module = 'FailoverClusters' }
    @{ Name = 'Get-ClusterGroupProperty';       Module = 'FailoverClusters' }
    @{ Name = 'Get-ClusterNetwork';             Module = 'FailoverClusters' }
    @{ Name = 'Get-ClusterNode';                Module = 'FailoverClusters' }
    @{ Name = 'Get-ClusterQuorum';              Module = 'FailoverClusters' }
    @{ Name = 'Get-ClusterResource';            Module = 'FailoverClusters' }
    @{ Name = 'Get-ClusterSharedVolume';        Module = 'FailoverClusters' }
    @{ Name = 'Get-ClusterSharedVolumeState';   Module = 'FailoverClusters' }
    @{ Name = 'Move-ClusterVirtualMachineRole'; Module = 'FailoverClusters' }
    @{ Name = 'New-Cluster';                    Module = 'FailoverClusters' }
    @{ Name = 'Remove-Cluster';                 Module = 'FailoverClusters' }
    @{ Name = 'Remove-ClusterNode';             Module = 'FailoverClusters' }
    @{ Name = 'Set-ClusterOwnerNode';           Module = 'FailoverClusters' }
    @{ Name = 'Set-ClusterQuorum';              Module = 'FailoverClusters' }
    @{ Name = 'Suspend-ClusterNode';            Module = 'FailoverClusters' }
    @{ Name = 'Get-VM';                         Module = 'Hyper-V' }
    @{ Name = 'Get-VMHost';                     Module = 'Hyper-V' }
    @{ Name = 'Measure-VMReplication';          Module = 'Hyper-V' }
    @{ Name = 'Set-VMHost';                     Module = 'Hyper-V' }
)

function Initialize-HVCommandAliases {
    <#
    .SYNOPSIS
        Pins ambiguous cmdlet names to the Hyper-V / FailoverClusters modules.
    .DESCRIPTION
        Some sessions load VMware cmdlets with overlapping names like Get-Cluster
        and Get-VMHost. Inside this module we always want the Windows cluster and
        Hyper-V implementations when they are available.
    #>
    [CmdletBinding()]
    param()

    $modulesToImport = $script:HVPreferredCommands |
        ForEach-Object { $_['Module'] } |
        Select-Object -Unique

    foreach ($moduleName in $modulesToImport) {
        if (-not (Get-Module -Name $moduleName) -and (Get-Module -ListAvailable -Name $moduleName)) {
            try {
                Import-Module $moduleName -ErrorAction Stop | Out-Null
            }
            catch {
                if (Get-Command Write-HVLog -ErrorAction SilentlyContinue) {
                    Write-HVLog -Message "Could not import preferred module '$moduleName': $($_.Exception.Message)" -Level 'WARN'
                }
            }
        }
    }

    foreach ($commandSpec in $script:HVPreferredCommands) {
        $qualified = '{0}\{1}' -f $commandSpec.Module, $commandSpec.Name
        $preferred = Get-Command $qualified -ErrorAction SilentlyContinue
        if (-not $preferred) {
            continue
        }

        $existing = Get-Command $commandSpec.Name -All -ErrorAction SilentlyContinue |
            Select-Object -First 1

        Set-Alias -Name $commandSpec.Name -Value $qualified -Scope Script -Force

        if ($existing -and
            $existing.Name -eq $commandSpec.Name -and
            $existing.CommandType -ne 'Alias' -and
            $existing.Source -ne $commandSpec.Module -and
            $existing.ModuleName -ne $commandSpec.Module -and
            (Get-Command Write-HVLog -ErrorAction SilentlyContinue)) {
            Write-HVLog -Message "Bound '$($commandSpec.Name)' to '$qualified' instead of '$($existing.Source)'." -Level 'WARN'
        }
    }
}
