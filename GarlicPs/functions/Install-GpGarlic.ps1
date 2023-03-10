<#
.SYNOPSIS
    🧄 Install GarlicOS!

.DESCRIPTION
    Automate installation of GarlicOS.

.PARAMETER LocalFile
    The full path of a copy of RG35XX-MicroSDCardImage.7z locally available. If not supplied, it is downloaded.

.PARAMETER GarlicURL
    The URL of the GarlicOS update file (RG35XX-MicroSDCardImage.7z), ex: https://www.patreon.com/file?h=76561333&i=13249827
	Note: With each new version of GarlicOS, old URLs become invalid. Ensure a valid one is being passed.

.PARAMETER TempPath
    Where files will be downloaded and decompressed to during the installation.

.PARAMETER TargetDeviceNumber
    The index of the target boot SD card device. Can be found using diskpart.exe or equivalent.

.PARAMETER ClearTempPath
    Whether to recursively empty the TempPath before using it. Recommended.

.PARAMETER BIOSPath
    Path to personal BIOS files that will be copied after installation.

.PARAMETER ROMPath
    Path to personal ROM files that will be copied after installation.

.PARAMETER ExpandPartitionThresholdMb
	The threshold in MB of unallocated space on the target disk.
	If exceeded, the ROM partition will be expanded to utilize the space.

.PARAMETER ROMDriveLetter
	If the ROM partition does not get assigned a drive letter on re-insert, assign it this one
	to make it accessible. If drive letter is already assigned, this value is ignored.

.PARAMETER 2ndSDDrive
	If using two SD cards, the drive letter of the FAT32 formatted drive for ROMs and BIOS files.
	Must be in a valid path format, i.e. 'X:\'

.EXAMPLE
    Install-GpGarlic -GarlicUrl "https://www.patreon.com/file?h=76561333&i=13249827" -TargetDeviceNumber 2 -ClearTempPath $true

	Fetches GarlicOS from a Patreon attachment URL and installs it on an SD card identified as Disk #2.
	Clears any files that may exist in the temp path.


.EXAMPLE
	Install-GpGarlic -LocalFile "C:\Users\lowlydba\Downloads\RG35XX-MicroSDCardImage.7z" -TargetDeviceNumber 1 -ClearTempPath $true -TempPath "C:\temp"

	Uses a local GarlicOS file and installs it on an SD card identified as Disk #1.
	Stores temp files in C:\temp.
	Clears any files that may already exist in C:\temp.

#>
#Requires -RunAsAdministrator
function Install-GpGarlic {
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	param (
		[Parameter (Mandatory = $true, ParameterSetName = "local")]
		[string]$LocalFile,
		[Parameter (Mandatory = $true, ParameterSetName = "remote")]
		[string]$GarlicURL,
		[Parameter (Mandatory = $false)]
		[string]$TempPath = (Join-Path -Path ([System.IO.Path]::GetTempPath()) "\GarlicPs"),
		[Parameter (Mandatory = $true)]
		[ValidateRange(1, 99)]
		[int]$TargetDeviceNumber,
		[Parameter (Mandatory = $false)]
		[bool]$ClearTempPath = $true,
		[Parameter (Mandatory = $false)]
		[string]$BIOSPath,
		[Parameter (Mandatory = $false)]
		[string]$ROMPath,
		[Parameter (Mandatory = $false)]
		[string]$ROMDriveLetter = "R",
		[Parameter (Mandatory = $false)]
		[ValidateScript({ Test-Path -Path $_ })]
		[string]$2ndSDDrive
	)
	process {
		$garlicPath = Join-Path -Path $TempPath -ChildPath "\GarlicOS"
		$GarlicInstallZipName = "RG35XX-MicroSDCardImage.7z"

		## Get disk info
		# Balena is case sensitive, so get the deviceId from its util to avoid issues
		$targetBalenaDrive = Get-GpBalenaDrive -TargetDeviceNumber $TargetDeviceNumber

		# Cleanup/Create temp path for Garlic extraction
		New-GpTemp -TempPath $TempPath -ClearTempPath $ClearTempPath -GarlicPath $garlicPath

		## Step 1 - Download & extract GarlicOS
		if ($LocalFile -eq "") {
			$garlicInstallUri = $GarlicURL
			$garlicZipPath = Invoke-GpDownload -TempPath $TempPath -GarlicZip $GarlicInstallZipName -GarlicUri $garlicInstallUri
		}
		else {
			$garlicZipPath = $LocalFile
		}

		# Extract the archive
		Expand-Gp7Zip -ArchivePath $garlicZipPath -TargetPath $garlicPath

		## Step 2 - Flash garlic.img to SD
		$garlicImgPath = Join-Path -Path $garlicPath -ChildPath "garlic.img"
		if ($PSCmdlet.ShouldContinue($targetBalenaDrive, "Flash device with GarlicOS image? This will format and erase any existing data on the device:")) {
			Invoke-GpBalenaFlash -ImgPath $garlicImgPath -TargetDrive $targetBalenaDrive
		}

		## Step 3 - Eject and re-insert SD
		Write-Output ""
		Write-Output "Safely eject the SD card, then re-insert it."
		Read-Host "Press enter to continue"

		## Step 4 - Configure FAT32 partition if needed, doesn't always auto-assign drive
		try {
			$ROMVolumeFriendlyName = "GARLICROM"
			$targetDiskPartitions = Get-Partition -DiskNumber $TargetDeviceNumber
			$ROMPartition = $targetDiskPartitions[-1] # Feels hacky, maybe a better way to identify other than its index as last partition?
			if (!(Get-Partition -DiskNumber $TargetDeviceNumber -PartitionNumber $ROMPartition.PartitionNumber).DriveLetter) {
				# Assign drive letter to ROM partition
				Write-Verbose -Message "Setting drive #$TargetDeviceNumber, partition #$($ROMPartition.PartitionNumber) to drive letter '$ROMDriveLetter' with friendly name '$ROMVolumeFriendlyName'."
				Set-Partition -DiskNumber $TargetDeviceNumber -PartitionNumber $ROMPartition.PartitionNumber -NewDriveLetter $ROMDriveLetter
			}
			else {
				Write-Verbose -Message "Found default ROM partition as volume '$ROMDriveLetter'"

			}
			if (!((Get-Volume -DriveLetter $ROMDriveLetter).FileSystemLabel)) {
				Write-Verbose -Message "Adding friendly name '$ROMVolumeFriendlyName' to '$ROMDriveLetter' drive"
				Set-Volume -DriveLetter $ROMDriveLetter -NewFileSystemLabel $ROMVolumeFriendlyName
			}
			$ROMDrivePath = (Get-PSDrive -Name $ROMDriveLetter).Root
		}
		catch {
			Write-Error -Message "Error auto-assigning drive letter to default ROM partition: $($_.Exception.Message)"
		}

		## Step 5 - Copy ROM & BIOS data to 2nd SD Card
		if ($2ndSDDrive -ne '') {
			Write-Verbose -Message "Copying ROM and BIOS data from '$ROMDrivePath' to '$2ndSDDrive'"
			$GarlicROMPath = Join-Path -Path $ROMDrivePath -ChildPath "Roms"
			$GarlicBIOSPath = Join-Path -Path $ROMDrivePath -ChildPath "BIOS"
			Copy-GpGarlicFiles -BIOSPath $GarlicBIOSPath -ROMPath $GarlicROMPath -Destination $2ndSDDrive
		}

		## Step 6 - Copy personal files
		Copy-GpPersonalFiles -BIOSPath $BIOSPath -ROMPath $ROMPath -Destination $ROMDrivePath

		## Tada!
		Invoke-GpThanks -Action "installed"
	}
}
