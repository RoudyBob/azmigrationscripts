# azmigrationscripts
Scripts for Migrating Azure VMs/LBs to Azure Availability Zones

Migration of VM-based applications from Availability Sets to Availability Zones is a two-step process. 

1. Convert the Software Load Balancer used by VMs in the Availability Set from the Basic SKU to the new Standard SKU which supports Availability Zones. If VMs are not load balanced by a load balancer, they are behind a 3rd party load balancer or the Azure load balancer is already a “Standard SKU” load balancer, this step may not be required.

2. Migrate VMs to specific Availability Zones in an Azure region by deleting the VM definition and recreating it in the new zone. This process is different depending on whether the VM is in an Azure load balancer (see step #1 above) or not.

Caution: As these scripts to delete and re-create resources to convert them from Basic to Standard SKUs (for load balancers) or from regional VMs to VMs in specific zones (for VMs), they are potentially destructive. If an issue with the script does not allow it to succeed fully, the resource (LB or VM) may not get re-created correctly. Please backup your resource definitions and test thoroughly before using.
