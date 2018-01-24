# Script to move VMs from existing Availability Set into Availability Zones
#
# Usage: .\MoveVMtoAZ-v7.ps1 -subid a97a235d-55f9-4382-856a-e38f8b5b6d31 -vmname singlevm-ds2 -vmresourcegroup bobroud-aztest -zone 1
# 
# subid - The subscription ID for the VM you want to get the OS serial number
# asetname - Name of the Availability Set to Move VMs from
# vmresourcegroup - Resource Group of the Availability SEt to Move VMs from
# zone - Target Availability zone for the VM
#
# Bob Roudebush - Microsoft Azure CSA
# bobroud@microsoft.com

param(
    [Parameter(Mandatory=$true)]
    [string]$subid,
    [Parameter(Mandatory=$true)]
    [string]$vmname,
    [Parameter(Mandatory=$true)]
    [string]$vmresourcegroup,
    [Parameter(Mandatory=$true)]
    [string]$zone
)

# ----------------------------------------------------------------------------------------#
# Populate these variables with values if testing, otherwise these come from parameters
# ----------------------------------------------------------------------------------------#
# $subid = "a97a235d-55f9-4382-856a-e38f8b5b6d31"                  # Azure Subscription ID
# $vmname = "singlevm"                                             # Source Availability Set to Move to AZs
# $vmresourcegroup = "bobroud-aztest"                              # Source Availability Set Resource Group
# $zone = "1"                                                      # Destination Availability Zone for VM

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------------ #
# Try to Select Azure Subscription - Prompt to Login if Unsuccessful
# ------------------------------------------------------------------------------------ #
try {
  $sub = Select-AzureRmSubscription -SubscriptionId $subid -ErrorAction Stop
}
Catch {
  Login-AzureRmAccount
  Select-AzureRmSubscription -SubscriptionId $subid
}

function CreateDiskFromSnap {
  Param ($diskrg,$diskname,$zone)

  $snapsourcedisk = Get-AzureRmDisk -ResourceGroupName $diskrg -DiskName $diskname

  if ($snapsourcedisk.Sku.Name -eq $null) { 
      Write-Host "Azure PowerShell Cmdlet Version Not Supported - Update to Latest Version" -ForegroundColor Red
      Exit
  }

  $snapshotconfig =  New-AzureRmSnapshotConfig -SourceUri $snapsourcedisk.Id -CreateOption Copy -Location $snapsourcedisk.Location -SkuName $snapsourcedisk.Sku.Name
  $snapshotname = $snapsourcedisk.Name+"_snap"
  Write-Host "Creating snapshot of managed disk"$diskname -ForegroundColor Cyan
  $snapshot = New-AzureRmSnapshot -Snapshot $snapshotconfig -SnapshotName $snapshotname -ResourceGroupName $diskrg -ErrorAction Stop

  $newdiskconfig = New-AzureRmDiskConfig -SourceResourceId $snapshot.Id -Location $snapshot.Location -CreateOption Copy -Zone $zone -SkuName $snapshot.Sku.Name
  $newdiskname = $snapsourcedisk.Name+"_az"
  Write-Host "Creating new managed disk"$newdiskname -ForegroundColor Cyan
  $disk = New-AzureRmDisk -Disk $newdiskConfig -DiskName $newdiskname -ResourceGroupName $diskrg -ErrorAction Stop

  return $disk
}

function RecreateVM {
  Param ($name,$rg,$zone)

  # Check to see if VM is running. VM must be in a running state to query Storage Account Type for Premium Disks
  $oldvmstatus = Get-AzureRmVM -ResourceGroupName $rg -Name $name -Status | Select-Object @{n="Status"; e={$_.Statuses[1].Code}} 
  if ($oldvmstatus.Status -ne "PowerState/running") {
    Write-Host "VM is not Running. Please start the VM and re-run the script." -ForegroundColor Red
    Exit 
  }

  # Get Source VM Configuration and Store It
  $oldvm = Get-AzureRmVM -ResourceGroupName $rg -Name $name -WarningAction Stop
  $outputfilename = $name+"-configbackup.json"
  Write-Host "Backing up VM configuration to"$outputfilename -ForegroundColor Yellow
  
  try {
    ConvertTo-Json -InputObject $oldvm -Depth 10 > $outputfilename -ErrorAction Stop
  }
  Catch {
    Write-Host "Unable to save VM configuration backup to current directory. Aborting." -ForegroundColor Red
  }

  # Script Doesn't Deal with VMs Encrypted using ADE - Abort if Detected
  $osVolEncrypted = (Get-AzureRmVMDiskEncryptionStatus -ResourceGroupName $oldvm.ResourceGroupName -VMName $oldvm.Name -ErrorAction SilentlyContinue).OsVolumeEncrypted 
  $dataVolEncrypted = (Get-AzureRmVMDiskEncryptionStatus -ResourceGroupName $oldvm.ResourceGroupName -VMName $oldvm.Name -ErrorAction SilentlyContinue).DataVolumesEncrypted
  if ($osVolEncrypted -eq "Encrypted" -or $dataVolEncrypted -eq "Encrypted" ) {
    Write-Host "VM is Encrypted - Aborting Script" -ForegroundColor Red
    Exit
  }

  # Script is Designed to work with Managed Disk Only - Abort if Detected
  if ($oldvm.StorageProfile.OsDisk.ManagedDisk -eq $null) {
    Write-Host "VM is Using Unmanaged Disks - Aborting Script" -ForegroundColor Red
    Exit
  }

  Write-Host "Creating New VM Configuration" -ForegroundColor Cyan

  # ----------------------------------------------------------------------------------------#
  # Create VM Configuration for Destination VM - Provide Zone Info
  # ----------------------------------------------------------------------------------------#
  $SupportedZones = (Get-AzureRmComputeResourceSku | Where-Object {$_.Locations.Contains($oldvm.Location) -and ($_.Name -eq $oldvm.HardwareProfile.VmSize)}).LocationInfo.Zones
  if ($SupportedZones.Count -lt 1) {
    # If Resoruce API returns no zones for this VM Size, then it's not supported
    Write-Host "VM Size Not Supported by Availability Zones - Aborting Script" -ForegroundColor Red
    Exit
  }
  elseif (!($SupportedZones -contains $zone)) {
    # If the list of zones for this VM Size and Region doesn't contain the specified zone then abort
    Write-Host "Zone Specified Not Supported for this VM Size in this Region - Aborting Script" -ForegroundColor Red
    Exit
  }
  else {
    $newvmconfig = New-AzureRmVMConfig -VMName $name -VMSize $oldvm.HardwareProfile.VmSize -Zone $zone
    # Add any Tags from Old VM to New VM
    $newvmconfig.Tags = $oldvm.Tags

    Write-Host "VM Created in Availability Zone $($newvmconfig.Zones) in $($oldvm.location) " -ForegroundColor Green
  }

  # ----------------------------------------------------------------------------------------#
  # Create Storage Profiles for Destination VM
  # ----------------------------------------------------------------------------------------#

  # Stop Source VM If It's Not Stopped before Snapshots are Taken
  Write-Host "Stopping VM"$oldvm.Name -ForegroundColor Yellow
  Stop-AzureRmVM -Name $oldvm.Name -ResourceGroupName $oldvm.ResourceGroupName -Force

  # Create New OS Disk from Snapshot of Existing OS Disk
  $newdisk = CreateDiskFromSnap -diskrg $oldvm.StorageProfile.OsDisk.ManagedDisk.Id.Split("/")[4] -diskname $oldvm.StorageProfile.OsDisk.Name -zone $zone
  
  # Add OS Disk to New VM configuration using old values - Detect Windows/Linux
  If ($oldvm.StorageProfile.OsDisk.OsType -eq "Windows") {
    $newvmconfig | Set-AzureRmVmOSDisk -Name $newdisk.Name -CreateOption Attach -ManagedDiskId $newdisk.Id -StorageAccountType $newdisk.Sku.Name -Caching ($oldvm.StorageProfile.OsDisk.Caching) -DiskSizeInGB $newdisk.DiskSizeGB -Windows -ErrorAction Stop
  }
  ElseIf ($oldvm.StorageProfile.OsDisk.OsType -eq "Linux") {
    $newvmconfig | Set-AzureRmVmOSDisk -Name $newdisk.Name -CreateOption Attach -ManagedDiskId $newdisk.Id -StorageAccountType $newdisk.Sku.Name -Caching ($oldvm.StorageProfile.OsDisk.Caching) -DiskSizeInGB $newdisk.DiskSizeGB -Linux -ErrorAction Stop
  }

  # Iterate Through Each Data Disk and Add to New VM Configuration
  For ($i=0;$i -lt ($oldvm.StorageProfile.DataDisks.Count).ToInt32($null);$i++) {
    # Create New Data Disk from Snapshot of Existing Data Disk
    $newdisk = CreateDiskFromSnap -diskrg $oldvm.StorageProfile.DataDisks[$i].ManagedDisk.Id.Split("/")[4] -diskname $oldvm.StorageProfile.DataDisks[$i].Name -zone $zone
    
    # Add Data Disk to new VM Configuration Using Old Values
    $newvmconfig | Add-AzureRmVMDataDisk -Name $newdisk.Name -ManagedDiskId $newdisk.Id -StorageAccountType $newdisk.Sku.Name -Caching ($oldvm.StorageProfile.DataDisks[$i].Caching) -Lun ($oldvm.StorageProfile.DataDisks[$i].Lun) -DiskSizeInGB $newdisk.DiskSizeGB -CreateOption Attach -ErrorAction Stop
  } 

  # ----------------------------------------------------------------------------------------#
  # Delete Old VM Before NICs are Created
  # ----------------------------------------------------------------------------------------#
  Write-Host "Deleting VM Configuration prior to recreation in Availability Zone" -ForegroundColor Yellow
  Remove-AzureRmVM -Name $name -ResourceGroupName $rg -WarningAction Stop

  # ----------------------------------------------------------------------------------------#
  # Create NICs for Destination VM
  # ----------------------------------------------------------------------------------------#

  # Handle Multi-NIC VMs by Iterating Through Each Interface
  For ($i=0;$i -lt ($oldvm.NetworkProfile.NetworkInterfaces.Count).ToInt32($null);$i++) {
    # Get Old NIC Name and Resource Group from ID
    $nicname = ($oldvm.NetworkProfile.NetworkInterfaces[$i].id.Split("/")[8])
    $oldnicRG = ($oldvm.NetworkProfile.NetworkInterfaces[$i].Id.Split("/")[4])
    $newIPAddress = ""

    # Store NIC Configuration Temporary Variable
    $oldnic = Get-AzureRmNetworkInterface -Name $nicname -ResourceGroupName $oldnicRG

    # Delete Old NIC Prior to NIC/PIP Recreation
    Write-Host "Deleting Old NIC prior to NIC/PIP Recreation" -ForegroundColor Yellow
    Remove-AzureRmNetworkInterface -Name $nicname -ResourceGroupName $oldnicRG -Force

    # Check to See if Old VM Has a PIP Assigned
    If ($oldnic.IpConfigurations[0].PublicIpAddress.Id) {
      # Delete old PIP
      Write-Host "VM Has a Public IP Assigned - Recreating PIP in Availability Zone" -ForegroundColor Yellow
      $oldpip = Get-AzureRmPublicIpAddress -Name $oldnic.IpConfigurations[0].PublicIpAddress.Id.Split("/")[8] -ResourceGroupName $oldnic.IpConfigurations[0].PublicIpAddress.Id.Split("/")[4] 
      Remove-AzureRmPublicIpAddress -Name $oldpip.Name -ResourceGroupName $oldpip.ResourceGroupName -Force

      # Create new PIP as Standard SKU in AZ
      $newpip = New-AzureRmPublicIpAddress -Name $oldpip.Name -ResourceGroupName $oldpip.ResourceGroupName -Location $oldpip.Location -Sku "Standard" `
      -AllocationMethod "Static" -Tag $oldpip.Tag -IdleTimeoutInMinutes $oldpip.IdleTimeoutInMinutes -DomainNameLabel $oldpip.DnsSettings.DomainNameLabel `
      -Zone $zone -WarningAction SilentlyContinue -ErrorAction Stop
      Write-Host "Recreating PIP: Address was $($oldpip.IpAddress) - new PIP Address is $($newpip.IpAddress)" -ForegroundColor Cyan
      Write-Host "Standard SKU Public IP Resources Must Use Static IP Address Allocation - PIP Set to Static IP" -ForegroundColor White
    }
  
    # Check to See if Old VM NICs Had Static IP
    If ($oldnic.IpConfigurations[0].PrivateIpAllocationMethod -eq "Static") {
      Write-Host "Source NIC has Static IP Address ("$oldnic.IpConfigurations[0].PrivateIpAddress") - using same IP" -ForegroundColor Yellow
      $newIPAddress = $oldnic.IpConfigurations[0].PrivateIpAddress
    }

    # Check to See if Old VM NICs had NSG
    If ($oldnic.NetworkSecurityGroup -ne $null) {
      Write-Host "Source VM NIC had NSG Assigned - Attaching NSG to new VM NIC" -ForegroundColor Yellow 
    }
    # This Assumes one IP Configuration per NIC - WILL NOT COPY ADDITIONAL IP CONFIGS
    $nic = New-AzureRmNetworkInterface -Name $nicname -ResourceGroupName $rg -Location $oldvm.Location -SubnetId $oldnic.IpConfigurations[0].Subnet.Id `
    -NetworkSecurityGroupId $oldnic.NetworkSecurityGroup.Id -PrivateIpAddress $newIPAddress -PublicIpAddressId $newpip.Id `
    -Force -WarningAction SilentlyContinue -ErrorAction Stop
    
    If ($i -eq 0) {
      $newvmconfig | Add-AzureRmVMNetworkInterface -Id $nic.Id -Primary -WarningAction SilentlyContinue
    } Else {
      $newvmconfig | Add-AzureRmVMNetworkInterface -Id $nic.Id -WarningAction SilentlyContinue
    }
  }

  # ----------------------------------------------------------------------------------------#
  # Deploy Destination VM
  # ----------------------------------------------------------------------------------------#
  Write-Host "VM Configuration Creation Complete. Recreating VM." -ForegroundColor Green
  $vm = New-AzureRmVM -ResourceGroupName $rg -Location $oldvm.Location -VM $newvmconfig -ErrorAction Stop -WarningAction SilentlyContinue

  Return $vm
}

RecreateVM -name $vmname -rg $vmresourcegroup -zone $zone