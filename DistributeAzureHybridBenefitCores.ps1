##########################################################################################################
<#
.SYNOPSIS
    Author:     Martin Diewald
    Created:    October/November 2020
    Updated by:
    Updated:

.DESCRIPTION
    This script automates the process of enabling Azure Hybrid Use Benefit on all Windows VMs in All Subscriptions.
    
    The script updates the "LicenseType" of all Windows VMs in a given subscription, thus enabling Azure HUB.
    It excludes non-Windows Operating Systems and provides logging and totals for number of VMs that have been
    updated.
.VARIABLES
    AvailableCores
    StorageSubscription
    StorageRGName
    StorageAccountName
    ShareName
    ExportFile
#>
##########################################################################################################

<#
# This Runbook starts on a schedule. 
# Activate Param only for manual Runbook start
Param(
	          
        # Set $AvailableCores for the Cores that are available for Hybrid Benefit
	    [parameter(Mandatory=$false)]
	    [int] $AvailableCores,

	    [parameter(Mandatory=$false)]
	    [bool] $Simulation = $true

	)
#>

$ErrorActionPreference = "Stop"

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave –Scope Process

$ErrorActionPreference = "Stop"

$connection = Get-AutomationConnection -Name AzureRunAsConnection

# Wrap authentication in retry logic for transient network failures
$logonAttempt = 0
while(!($connectionResult) -And ($logonAttempt -le 10))
{
    $LogonAttempt++
    # Logging in to Azure...
    $connectionResult =    Connect-AzAccount `
                               -ServicePrincipal `
                               -Tenant $connection.TenantID `
                               -ApplicationId $connection.ApplicationID `
                               -CertificateThumbprint $connection.CertificateThumbprint

    Start-Sleep -Seconds 10
}

# Retrieve Variables from Automation Account

$AvailableCores = Get-AutomationVariable -Name AvailableCores
$StorageSubscription = Get-AutomationVariable -Name StorageSubscription
$StorageRGName = Get-AutomationVariable -Name StorageRGName
$StorageAccountName = Get-AutomationVariable -Name StorageAccountName
$ShareName = Get-AutomationVariable -Name ShareName
$ExportFile = Get-AutomationVariable -Name ExportFile

# Create TempTable for VM list
$TempTable = New-Object System.Data.DataTable
$TempTable.Columns.Add()
$TempTable.Columns[0].Columnname = "Subscription"
$TempTable.Columns.Add()
$TempTable.Columns[1].Columnname = "ResourceGroup"
$TempTable.Columns.Add()
$TempTable.Columns[2].Columnname = "VMName"
$TempTable.Columns.Add()
$TempTable.Columns[3].Columnname = "VMSize"
$TempTable.Columns.Add()
$TempTable.Columns[4].Columnname = "LicenseType"
$TempTable.Columns.Add()
$TempTable.Columns[5].Columnname = "Cores"

# Create ResultTable for Results
$Resulttable = $TempTable.Copy()
$ResultTable.Columns.Add()
$ResultTable.Columns[6].Columnname = "HUBEnabled"
$ResultTable.Columns.Add()
$ResultTable.Columns[7].Columnname = "Message"

$SumOfCoresHB = 0
$SumofCores = 0

$Subs = Get-AzSubscription

foreach($Sub in $Subs){
    Set-AzContext -SubscriptionObject $sub
    $vms = get-azvm

    foreach($vm in $vms){

       if ($vm.OSProfile.WindowsConfiguration){
           $Cores = (Get-AzVMSize -Location "West Europe" | Where-Object {$vm.HardwareProfile.VmSize -eq $_.Name}).NumberOfCores
           $temptable.Rows.Add($Sub.Name,$vm.ResourceGroupName,$vm.Name,$vm.HardwareProfile.VmSize,$vm.LicenseType,$Cores)
           $SumOfCores += $Cores

           if ($Vm.LicenseType -ne "None"){
               $SumofCoresHB += $Cores 
           }
        }
    }
}

write-output "Number of Cores installed: $SumOfCores"
write-output "Existing Cores with Hybrid Benefit: $SumOfCoresHB"
write-output "Number of available Cores: $AvailableCores"
$DistributeCores = $AvailableCores - $SumofCoresHB
write-output "Number of Cores to distribute: $DistributeCores"

$TempTable = $TempTable | Sort-Object -Property Cores -Descending

if($DistributeCores -lt 0){
    $TempTable = $TempTable | Sort-Object -Property Cores -Ascending
}

if($DistributeCores -eq 0){
    write-error "No Cores to correct"
}

$AssignedCores = 0

foreach($line in $TempTable){

    Set-AzContext -Subscription $line.Subscription 
    $vm = get-azvm -ResourceGroupName $line.ResourceGroup -Name $line.VMName
    $ResultTableLine = $line.ItemArray
    $update = $false
    if($simulation){
        write-output "Simulation On"
        $update = $true #But no change in $vm.LicenseType
        $vm.LicenseType = $vm.LicenseType
    }else{
        $CheckCores = [int]$AssignedCores + [int]$line.Cores
        if($vm.LicenseType -ne "Windows_Server" -and $vm.LicenseType -ne "Windows_Client" -and $AvailableCores -ge $CheckCores){
            $vm.LicenseType = "Windows_Server"
            $update = $true
            write-output "Hybrid Benefit will be enabled for VM " $line.vmname
        }else{
            if(($vm.LicenseType -eq "Windows_Server" -or $vm.LicenseType -eq "Windows_Client") -and $AvailableCores -lt $CheckCores){
                $vm.LicenseType = "None"
                $update = $true
                write-output "Hybrid Benefit will be disabled for VM " $line.vmname
            }
        }
    }
    if($update){
        write-output "Updating" $line.vmname
        $AzureHUB = Update-AzVM -ResourceGroupName $line.ResourceGroup -VM $vm -ErrorVariable UpdateVMFailed -ErrorAction SilentlyContinue

        if($UpdateVMFailed) {
            # Failed to enabled HUB, unhandled error
            $ResultTableline += "Error"
            $ResultTableline += "Failed to set LicenseType: $($UpdateVMFailed.Exception)"

        } else {

            if($AzureHUB.IsSuccessStatusCode -eq $True) {
                # Successfully enabled HUB
                if ($vm.LicenseType -eq "Windows_Server"){
                    $ResultTableline += "Set"
                    $ResultTableline += "HUB Enabled Successfully"
                    $AssignedCores += $line.Cores

                }else {
                    $ResultTableline += "Removed"
                    $ResultTableline += "HUB Disabled Successfully"
                    $AssignedCores += $line.Cores
                }
                                        
            } elseif($AzureHUB.StatusCode.value__ -eq 409) {
                # Marketplace VM Image with additional software, such as SQL Server
                # See Notes Section at top of this page for reference on 409 Error:
                # https://docs.microsoft.com/en-us/azure/virtual-machines/windows/hybrid-use-benefit-licensing
                $ResultTableline += "Error"
                $ResultTableline += "Marketplace VM, NOT compatible with Azure HUB"
                                            
            } else {
                # Failed to enabled HUB, unhandled error
                $ResultTableline += "Error"
                $ResultTableline += "Failed to set LicenseType: $($AzureHUB.StatusCode)"
            }
        }
    }
 
    else{
        $ResultTableline += "Not Changed"
        $ResultTableline += "HUB change not necessary"
    }
    $resulttable.rows.Add($ResultTableLine)
}

write-output "Writing Resultfile"

$Datum = get-date -format "ddMMyyyy HHMMss"
$filename = $Exportfile + $Datum + ".xlsx"
$tempfile = ".\"+ $Exportfile + ".xlsx"

$resulttable | Export-Excel -Path $tempfile

set-azcontext -Subscription $StorageSubscription

$storageAcct = Get-AzStorageAccount `
    -ResourceGroupName $StorageRGName `
    -Name $storageAccountName

Set-AzStorageFileContent `
   -Context $storageAcct.Context `
   -ShareName $shareName `
   -Source $tempfile `
   -Path $filename `
   -Force

write-output "File $filename written to fileshare $sharename in Storage Account $storageAccountName"
