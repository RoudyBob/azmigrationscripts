# Script to move a regional "basic" Azure LB to a zonal "standard" Azure LB
# NOTE: This currently only supports a single FE configuration and LBRule/Probe/BEPool setup
#
# Usage: .\AZLBMigration-v7.ps1 -subid a97a235d-55f9-4382-856a-e38f8b5b6d31 -lbname mylb -lbresourcegroup bobroud-testlb2
# 
# subid - The subscription ID for the Load Balancer you want to migrate
# lbname - Azure LB to move to Standard SKU / Regional Configuration
# lbresourcegroup - Resource group of Azure LB to move
#
# Bob Roudebush - Microsoft Azure CSA
# bobroud@microsoft.com

param(
        [Parameter(Mandatory=$true)]
        [string]$subid,
        [Parameter(Mandatory=$true)]
        [string]$lbname,
        [parameter(Mandatory=$true)]
        [string]$lbresourcegroup
    )

# ----------------------------------------------------------------------------------------#
# Populate these variables with values if testing, otherwise these come from parameters
# ----------------------------------------------------------------------------------------#
# $subid = "a97a235d-55f9-4382-856a-e38f8b5b6d31"                 # Azure Subscription ID
# $lbname = "bobroud-noZoneLB"                                    # Name of LB to Migrate to Standard Sku
# $lbresourcegroup = "bobroud-aztesting"                          # Name of Source LB Resource Group

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

# ------------------------------------------------------------------------------------ #
# Get Old LB Configuration
# ------------------------------------------------------------------------------------ #
Write-Host
Write-Host "Gathering Existing Load Balancer Configuration Settings for $lbname" -ForegroundColor White
$oldlb = Get-AzureRmLoadBalancer -ResourceGroupName $lbresourcegroup -Name $lbname
$oldbepoolconfig = Get-AzureRmLoadBalancerBackendAddressPoolConfig -LoadBalancer $oldlb
$oldfeipconfig = Get-AzureRmLoadBalancerFrontendIpConfig -LoadBalancer $oldlb
$oldnatpoolconfig = Get-AzureRmLoadBalancerInboundNatPoolConfig -LoadBalancer $oldlb
$oldnatruleconfig = Get-AzureRmLoadBalancerInboundNatRuleConfig -LoadBalancer $oldlb
$oldprobeconfig = Get-AzureRmLoadBalancerProbeConfig -LoadBalancer $oldlb 
$oldruleconfig = Get-AzureRmLoadBalancerRuleConfig -LoadBalancer $oldlb

# ------------------------------------------------------------------------------------ #
# Save Existing LB Configuration to Disk
# ------------------------------------------------------------------------------------ #
$outputfilename = $oldlb.name+"-configbackup.json"
Write-Host "Backing up Load Balancer configuration to"$outputfilename -ForegroundColor White
try {
  ConvertTo-Json -InputObject $oldlb -Depth 10 > $outputfilename -ErrorAction Stop
}
Catch {
  Write-Host "Unable to save VM configuration backup to current directory. Aborting." -ForegroundColor Red
}

# ------------------------------------------------------------------------------------ #
# Remove Old LB
# ------------------------------------------------------------------------------------ #
Write-Host "Deleting Load Balancer $($oldlb.Name)" -ForegroundColor Yellow
Remove-AzureRmLoadBalancer -ResourceGroupName $lbresourcegroup -Name $lbname -Force

# ------------------------------------------------------------------------------------ #
# Create New Frontend IP Config for New LB using Old Values
# ------------------------------------------------------------------------------------ #
if ($oldfeipconfig.PrivateIpAddress -ne $null) {
  $newfeipconfig = New-AzureRmLoadBalancerFrontendIpConfig -Name $oldfeipconfig.Name -SubnetId $oldfeipconfig.Subnet.Id -PrivateIpAddress $oldfeipconfig.PrivateIpAddress
}
else {
  # Delete old Public IP Address
  $oldpip = Get-AzureRmPublicIpAddress -Name $oldfeipconfig.PublicIpAddress.Id.Split("/")[8] -ResourceGroupName $oldfeipconfig.PublicIpAddress.Id.Split("/")[4]
  Write-Host "Deleting Public IP Resource for Load Balancer $($oldlb.Name)" -ForegroundColor Yellow
  Remove-AzureRmPublicIpAddress -Name $oldpip.Name -ResourceGroupName $oldpip.ResourceGroupName -Force

  # Create New Public IP Address as "Standard" SKU
  $newpip = New-AzureRmPublicIpAddress -Name $oldpip.Name -ResourceGroupName $oldpip.ResourceGroupName -Location $oldpip.Location -Sku "Standard" `
  -AllocationMethod "Static" -Tag $oldpip.Tag -IdleTimeoutInMinutes $oldpip.IdleTimeoutInMinutes -DomainNameLabel $oldpip.DnsSettings.DomainNameLabel `
  -Zone $zone -WarningAction SilentlyContinue -ErrorAction Stop
  Write-Host "Recreating PIP: Address was $($oldpip.IpAddress) - new PIP Address is $($newpip.IpAddress)" -ForegroundColor Cyan
  Write-Host "Standard SKU Public IP Resources Must Use Static IP Address Allocation - PIP Set to Static IP" -ForegroundColor White

  $newfeipconfig = New-AzureRmLoadBalancerFrontendIpConfig -Name $oldfeipconfig.Name -PublicIpAddressId $newpip.Id
}

# ------------------------------------------------------------------------------------ #
# Create New Backend Pool for New LB - Note: Only handles single BE Pool Currently
# ------------------------------------------------------------------------------------ #
$newbepoolconfig = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name $oldbepoolconfig.Name 

# ------------------------------------------------------------------------------------ #
# NAT Rule Creation - Add all inbound NAT rules from old LB to new LB
# Note: Only supports one LB FrontendIP Configuration Currently
# ------------------------------------------------------------------------------------ #
$natrulecount = 0
$newnatrule = @()
foreach ($oldnatrule in $oldnatruleconfig) {
    $natrulecount = $natrulecount + 1
    if ($oldnatrule.EnableFloatingIP -eq $true) {
        $newnatrule += New-AzureRmLoadBalancerInboundNatRuleConfig -Name $oldnatrule.Name -FrontendIpConfiguration $newfeipconfig -Protocol $oldnatrule.Protocol `
        -FrontendPort $oldnatrule.FrontendPort -BackendPort $oldnatrule.BackendPort -IdleTimeoutInMinutes $oldnatrule.IdleTimeoutInMinutes -EnableFloatingIP
    }
    else {
        $newnatrule += New-AzureRmLoadBalancerInboundNatRuleConfig -Name $oldnatrule.Name -FrontendIpConfiguration $newfeipconfig -Protocol $oldnatrule.Protocol `
        -FrontendPort $oldnatrule.FrontendPort -BackendPort $oldnatrule.BackendPort -IdleTimeoutInMinutes $oldnatrule.IdleTimeoutInMinutes       
    }
}

# ------------------------------------------------------------------------------------ #
# Probe Creation - Add all probes from old LB to new LB
# Note: Need to work on Multiple FE/LBRule/Probe Configuration
# ------------------------------------------------------------------------------------ #
$probecount = 0
$newprobe = @()
foreach ($oldprobe in $oldprobeconfig) {
    $probecount = $probecount + 1
    if ($oldprobe.RequestPath -eq $null) {
        $newprobe += New-AzureRmLoadBalancerProbeConfig -Name $oldprobe.Name -Protocol $oldprobe.Protocol -Port $oldprobe.Port `
        -IntervalInSeconds $oldprobe.IntervalInSeconds -ProbeCount $oldprobe.NumberOfProbes
    }
    else {
        $newprobe += New-AzureRmLoadBalancerProbeConfig -Name $oldprobe.Name -RequestPath $oldprobe.RequestPath -Protocol $oldprobe.Protocol -Port $oldprobe.Port `
        -IntervalInSeconds $oldprobe.IntervalInSeconds -ProbeCount $oldprobe.NumberOfProbes
    }
}

# ------------------------------------------------------------------------------------ #
# LB Rule Creation - Add all LB Rules from old LB to new LB
# Note: Need to work on Multiple FE/LBRule/Probe Configuration
# ------------------------------------------------------------------------------------ #
$lbrulecount = 0
$newlbrule = @()
foreach ($oldrule in $oldruleconfig) {
    $lbrulecount = $lbrulecount + 1
    $newlbrule += New-AzureRmLoadBalancerRuleConfig -Name $oldrule.Name -Protocol $oldrule.Protocol -FrontendPort $oldrule.FrontendPort -BackendPort $oldrule.BackendPort `
    -LoadDistribution $oldrule.LoadDistribution -IdleTimeoutInMinutes $oldrule.IdleTimeoutInMinutes -FrontendIpConfiguration $newfeipconfig -BackendAddressPool $newbepoolconfig -Probe $newprobe[0] 
}

# ------------------------------------------------------------------------------------ #
# Create New Load Balancer - Set SKU to STANDARD
# ------------------------------------------------------------------------------------ #
Write-Host "Creating New Load Balancer with Standard SKU" -ForegroundColor Green
$newlb = New-AzureRmLoadBalancer -Location $oldlb.Location -ResourceGroupName $lbresourcegroup -Name $lbname -Sku "Standard" -FrontendIpConfiguration $newfeipconfig `
-BackendAddressPool $newbepoolconfig -InboundNatRule $newnatrule -LoadBalancingRule $newlbrule -Probe $newprobe -WarningAction SilentlyContinue

# ------------------------------------------------------------------------------------ #
# Rejoin VM NICs to New LB - Note: Only handles one BE Pool Currently
# ------------------------------------------------------------------------------------ #

# Step 1 - Migrate any PIPs Attached to Backend Pool VMs Prior to Reconnecting VMs to LB
# This is required, otherwise you get an error about PIP SKU mismatch between VMs / LB
# Go through old Backend Pool Config and Inspect each IP Config Listed

Write-Host "Migrating PIPs on any Backend VMs to Standard SKU" -ForegroundColor White
foreach ($BackendIpConfig in $oldbepoolconfig.BackendIpConfigurations) {
  # Pull NIC RG Name from IP Config
  $nicrgname = $BackendIpConfig.Id.Split("/")[4]
  # Pull NIC Name from IP Config
  $nicname = $BackendIpConfig.Id.Split("/")[8]
    
  # Get NIC Properties for each IP Config in old Backend Pool
  $nic = Get-AzureRmNetworkInterface -Name $nicname -ResourceGroupName $nicrgname
  
  foreach ($ipconfig in $nic.IpConfigurations) {
    # Check to see if NIC's IP Config has PIP Assigned
    if ($ipconfig.PublicIpAddress -ne $null) {
      Write-Host "$($nic.VirtualMachine.Id.Split("/")[8])/$($nic.Name) has a Public IP Assigned - Migrating Public IP to Standard SKU" -ForegroundColor Cyan
      # Disconnect Public IP Address from NIC and then delete old Public IP Address
      $oldpip = Get-AzureRmPublicIpAddress -Name $ipconfig.PublicIpAddress.Id.Split("/")[8] -ResourceGroupName $ipconfig.PublicIpAddress.Id.Split("/")[4]
      Write-Host "Disconnecting Public IP Resource $($oldpip.Name) from $($nic.VirtualMachine.Id.Split("/")[8])/$($nic.Name)" -ForegroundColor Yellow
      $ipconfig.PublicIpAddress = $null
      Set-AzureRmNetworkInterface -NetworkInterface $nic > $null

      Write-Host "Deleting Public IP Resource $($oldpip.Name) for $($nic.VirtualMachine.Id.Split("/")[8])/$($nic.Name)" -ForegroundColor Yellow
      Remove-AzureRmPublicIpAddress -Name $oldpip.Name -ResourceGroupName $oldpip.ResourceGroupName -Force

      # Create New Public IP Address as "Standard" SKU
      # For Standard SKU, AllocationMethod must be Static
      $newpip = New-AzureRmPublicIpAddress -Name $oldpip.Name -ResourceGroupName $oldpip.ResourceGroupName -Location $oldpip.Location -Sku "Standard" `
      -AllocationMethod Static -Tag $oldpip.Tag -IdleTimeoutInMinutes $oldpip.IdleTimeoutInMinutes -DomainNameLabel $oldpip.DnsSettings.DomainNameLabel `
      -WarningAction SilentlyContinue -ErrorAction Stop
      Write-Host "Recreating PIP: Address was $($oldpip.IpAddress) - new PIP Address is $($newpip.IpAddress)" -ForegroundColor Cyan
      
      # Replace Old PIP ID with New PIP ID in NIC Configuration
      $vnet = Get-AzureRmVirtualNetwork -Name $ipconfig.Subnet.Id.Split("/")[8] -ResourceGroupName $ipconfig.Subnet.Id.Split("/")[4]
      $subnet = Get-AzureRmVirtualNetworkSubnetConfig -Name $ipconfig.Subnet.Id.Split("/")[10] -VirtualNetwork $vnet
      if ($ipconfig.Primary) {
        Set-AzureRmNetworkInterfaceIpConfig -Name $ipconfig.Name -NetworkInterface $nic -Subnet $subnet -PublicIpAddress $newpip -PrivateIpAddress $ipconfig.PrivateIpAddress -Primary > $null
      }
      else {
        Set-AzureRmNetworkInterfaceIpConfig -Name $ipconfig.Name -NetworkInterface $nic -Subnet $subnet -PublicIpAddress $newpip -PrivateIpAddress $ipconfig.PrivateIpAddress > $null
      }

      Write-Host "Associating new Public IP Resource $($newpip.Name) to $($nic.VirtualMachine.Id.Split("/")[8])/$($nic.Name)" -ForegroundColor White
      Set-AzureRmNetworkInterface -NetworkInterface $nic > $null
    }
  }
}

# Step 2 - Rejoin VM NICs to Backend Pools and NAT Rules
# Go through Backend Pool Config and Inspect each IP Config Listed

Write-Host "Rejoining VM NICs from Backend Pool to New Load Balancer" -ForegroundColor White
foreach ($BackendIpConfig in $oldbepoolconfig.BackendIpConfigurations) {
    # Pull NIC RG Name from IP Config
    $nicrgname = $BackendIpConfig.Id.Split("/")[4]
    # Pull NIC Name from IP Config
    $nicname = $BackendIpConfig.Id.Split("/")[8]

    # Get NIC Properties for each IP Config in old Backend Pool
    $nic = Get-AzureRmNetworkInterface -Name $nicname -ResourceGroupName $nicrgname

    foreach ($ipconfig in $nic.IpConfigurations) {           
      # Parse NIC IP Configs and Find One That Matches IP Config from BE Pool  
      if ($ipconfig.Name -eq $BackendIpConfig.Id.Split("/")[10]) {
        # Pull VM Name from NIC Configuration
        $vmname = $nic.VirtualMachine.Id.Split("/")[8]
        Write-Host "  Assigning $nicname/$($ipconfig.Name) of $vmname to backend address pool $($newbepoolconfig.Name)" -ForegroundColor White
        # Add New LB BE Pool to NIC IP Config LB Backend Address Pools List
        $ipconfig.LoadBalancerBackendAddressPools.Add($newbepoolconfig)
        # Go Through Old Inbound NAT Rules Looking for Same NIC IP Config
        foreach ($oldnatrule in $oldnatruleconfig) {
            # If Current NIC IP Config Matches Old Inbound NAT Rule IP Config Then Add NAT Rule to NIC IP Config
            if ($ipconfig.Id -eq $oldnatrule.BackendIPConfiguration.Id) {
                # Need to find the Appropriate new NAT Rule by Matching NAT Rule Names
                foreach ($natrule in $newlb.InboundNatRules) {
                    if ($natrule.Name -eq $oldnatrule.Name) {
                        Write-Host "  Found NAT Rule Match for $($natrule.Name)...Assigning to $nicname/$($ipconfig.Name)" -ForegroundColor Green
                        # Add New NAT Rule to NIC IP Config LB Inbound NAT Rules List
                        $ipconfig.LoadBalancerInboundNatRules.Add($natrule)
                    }
                }
            }
        }
        # Once BE Address List and NAT Rules List are Updated, Push New NIC Config to Azure
        Set-AzureRmNetworkInterface -NetworkInterface $nic > $null
      }
    }
}
Write-Host "Load Balancer Recreation and VM NIC Assignment Complete" -ForegroundColor Green
Write-Host