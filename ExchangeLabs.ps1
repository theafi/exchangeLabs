
Install-Module -Name Az -AllowClobber 
Connect-AzAccount
$subscrName=(Get-AzSubscription).Name
Select-AzSubscription -SubscriptionName $subscrName # Comprobamos que la suscripción existe. Este script está diseñado para la prueba gratuita. Si tiene una suscripción Pay-as-you-go de Azure, le remito a este script https://gallery.technet.microsoft.com/scriptcenter/PowerShell-commands-for-5d0b899d
$rgName="exchangelabs"
$locName="westeurope"
New-AZResourceGroup -Name $rgName -Location $locName # Crearemos un nuevo grupo de recursos en Azure, que llamaremos "exchangelabs" y estará ubicado en Europa Occidental. Cambie los valores de arriba según su preferencia.
$saName=Read-Host "Escriba un nombre para la cuenta de almacenamiento"
New-AZStorageAccount -Name $saName -ResourceGroupName $rgName -Type Standard_LRS -Location $locName
# Creamos una subnet donde estarán conectadas las máquinas virtuales
$exSubnet=New-AZVirtualNetworkSubnetConfig -Name EXSrvrSubnet -AddressPrefix 10.0.0.0/24 
New-AZVirtualNetwork -Name EXSrvrVnet -ResourceGroupName $rgName -Location $locName -AddressPrefix 10.0.0.0/16 -Subnet $exSubnet -DNSServer 10.0.0.4
# Creamos estas reglas de seguridad, en las descripciones de abajo detallo lo que hacen
$rule1 = New-AZNetworkSecurityRuleConfig -Name "RDPTraffic" -Description "Permite conexión remota por RDP a las VMs de esta subnet" -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389
$rule2 = New-AZNetworkSecurityRuleConfig -Name "ExchangeSecureWebTraffic" -Description "Permite el tráfico HTTPS al servidor Exchange" -Access Allow -Protocol Tcp -Direction Inbound -Priority 101 -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix "10.0.0.5/32" -DestinationPortRange 443
$rule3 = New-AZNetworkSecurityRuleConfig -Name "IISTraffic" -Description "Permitimos el tráfico por el puerto 80. Necesitamos esto para poder crear el certificado con Let's Encrypt" -Access Allow -Protocol Tcp -Direction Inbound -Priority 102 -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix "10.0.0.5/32" -DestinationPortRange 80
$rule4 = New-AZNetworkSecurityRuleConfig -Name "SMTPTraffic" -Description "Permitiremos las conexiones por el puerto 25 para que funcione la entrega de correo en Exchange" -Access Allow -Protocol Tcp -Direction Inbound -Priority 103 -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix "10.0.0.5/32" -DestinationPortRange 25
New-AZNetworkSecurityGroup -Name EXSrvrSubnet -ResourceGroupName $rgName -Location $locName -SecurityRules $rule1, $rule2, $rule3, $rule4
# Ahora crearemos la red virtual. Devolvemos la red virtual y el grupo de seguridad que creamos a dos variables
$vnet=Get-AZVirtualNetwork -ResourceGroupName $rgName -Name EXSrvrVnet
$nsg=Get-AZNetworkSecurityGroup -Name EXSrvrSubnet -ResourceGroupName $rgName
# Y ahora la creamos
Set-AZVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name EXSrvrSubnet -AddressPrefix "10.0.0.0/24" -NetworkSecurityGroup $nsg
$vnet | Set-AzVirtualNetwork
# Crea un availability set para las máquinas virtuales del controlador de dominio
New-AZAvailabilitySet -ResourceGroupName $rgName -Name dcAvailabilitySet -Location $locName -Sku Aligned  -PlatformUpdateDomainCount 5 -PlatformFaultDomainCount 2
# Creamos la máquina virtual que ejercerá de controlador de dominio
$vnet=Get-AZVirtualNetwork -Name EXSrvrVnet -ResourceGroupName $rgName
$pip = New-AZPublicIpAddress -Name adVM-NIC -ResourceGroupName $rgName -Location $locName -AllocationMethod Dynamic # La IP pública será dinámica
$nic = New-AZNetworkInterface -Name adVM-NIC -ResourceGroupName $rgName -Location $locName -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pip.Id -PrivateIpAddress 10.0.0.4 # La IP privada tiene una máscara de red de 255.255.255.0 como previamente se definió
$avSet=Get-AZAvailabilitySet -Name dcAvailabilitySet -ResourceGroupName $rgName
$vm=New-AZVMConfig -VMName adVM -VMSize Standard_D1_v2 -AvailabilitySetId $avSet.Id # Standard_D1_v2 es una VM con 1 vCPU y 3.5GB de RAM, más que de sobra para un AD de laboratorio
# En el siguiente enlace vienen las distintas configuraciones de máquina virtual que permite Azure: https://docs.microsoft.com/en-us/azure/virtual-machines/windows/sizes-general
$vm=Set-AZVMOSDisk -VM $vm -Name adVM-OS -DiskSizeInGB 128 -CreateOption FromImage -StorageAccountType "Standard_LRS"
$diskConfig=New-AZDiskConfig -AccountType "Standard_LRS" -Location $locName -CreateOption Empty -DiskSizeGB 20
$dataDisk1=New-AZDisk -DiskName adVM-DataDisk1 -Disk $diskConfig -ResourceGroupName $rgName
$vm=Add-AZVMDataDisk -VM $vm -Name adVM-DataDisk1 -CreateOption Attach -ManagedDiskId $dataDisk1.Id -Lun 1
$cred=Get-Credential -Message "Escribe el nombre de usuario y contraseña para la cuenta de administrador local en adVM" # Creamos las credenciales a través de las cuales nos conectaremos por RDP y haremos las gestiones necesarias
$vm=Set-AZVMOperatingSystem -VM $vm -Windows -ComputerName adVM -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
$vm=Set-AZVMSourceImage -VM $vm -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus 2012-R2-Datacenter -Version "latest"
$vm=Add-AZVMNetworkInterface -VM $vm -Id $nic.Id
New-AZVM -ResourceGroupName $rgName -Location $locName -VM $vm


# Ahora procederemos a crear la VM donde se alojará el Exchange Server

# Crearemos el nombre público de la máquina virtual. Esto nos ayudará cuando queramos configurar nuestro dominio para que apunte a este servidor de Exchange
$vmDNSName=Read-Host "Escribe un nombre de identificador global DNS único para esta máquina virtual. El nombre no puede contener puntos y debe estar compuesto únicamente de minúsculas y números" 
$dnsAvailability = Test-AZDnsAvailability -DomainQualifiedName $vmDNSName -Location $locName #Comprobamos que el nombre DNS está disponible
while($dnsAvailability -eq $false) {

    Write-Host "Ese nombre no está disponible. Inténtalo con otro."
    $vmDNSName=Read-Host "Escribe un nombre de identificador global DNS único para esta máquina virtual. El nombre no puede contener puntos y debe estar compuesto únicamente de minúsculas y números" 
    $dnsAvailability = Test-AZDnsAvailability -DomainQualifiedName $vmDNSName -Location $locName #Comprobamos que el nombre DNS está disponible

}
# Definimos el tipo de suscripción de Azure
Select-AzSubscription -SubscriptionName $subscrName
# Creamos un availability set para las máquinas virtuales de Exchange
New-AZAvailabilitySet -ResourceGroupName $rgName -Name exAvailabilitySet -Location $locName -Sku Aligned  -PlatformUpdateDomainCount 5 -PlatformFaultDomainCount 2
# Especificamos nombre y tamaño de la VM
$vmName="exVM"
$vmSize="Standard_D2_v2" # Standard_D2_v2 es una máquina con 2 vCPUs y 7GB de RAM. Puede que el Exchange se atragante un poco con esta configuración pero debido a limitaciones de la evaluación gratuita esto es lo que hay
$vnet=Get-AZVirtualNetwork -Name "EXSrvrVnet" -ResourceGroupName $rgName
$avSet=Get-AZAvailabilitySet -Name exAvailabilitySet -ResourceGroupName $rgName
$vm=New-AZVMConfig -VMName $vmName -VMSize $vmSize -AvailabilitySetId $avSet.Id
# Crearemos el NIC para la máquina virtual
$nicName=$vmName + "-NIC"
$pipName=$vmName + "-PublicIP"
$pip=New-AZPublicIpAddress -Name $pipName -ResourceGroupName $rgName -DomainNameLabel $vmDNSName -Location $locName -AllocationMethod Dynamic
$nic=New-AZNetworkInterface -Name $nicName -ResourceGroupName $rgName -Location $locName -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pip.Id -PrivateIpAddress "10.0.0.5"
# Creamos y configuramos la máquina virtual
$cred=Get-Credential -Message "Escribe el nombre de usuario y contraseña para la cuenta de administrador local en exVM."
$vm=Set-AZVMOSDisk -VM $vm -Name ($vmName +"-OS") -DiskSizeInGB 128 -CreateOption FromImage -StorageAccountType "Standard_LRS"
$vm=Set-AZVMOperatingSystem -VM $vm -Windows -ComputerName $vmName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
$vm=Set-AZVMSourceImage -VM $vm -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus 2012-R2-Datacenter -Version "latest"
$vm=Add-AZVMNetworkInterface -VM $vm -Id $nic.Id
New-AZVM -ResourceGroupName $rgName -Location $locName -VM $vm